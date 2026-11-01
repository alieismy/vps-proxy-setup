# shellcheck shell=bash
# Shared constants, reporting and small helpers. Sourced by bin/vps-proxy-setup.
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

readonly VPS_EXIT_OK=0
readonly VPS_EXIT_FAIL=1
readonly VPS_EXIT_USAGE=2
readonly VPS_EXIT_INTERNAL=3

# Files of this tool on the VPS (detailed design 2.8).
readonly VPS_ETC_DIR=/etc/vps-proxy-setup
readonly VPS_TARGET_DIR="$VPS_ETC_DIR/target-check"
readonly VPS_DEPLOY_CONF="$VPS_ETC_DIR/deploy.conf"
readonly VPS_TOKEN_FILE="$VPS_ETC_DIR/tunnel-token"
readonly VPS_HANDOFF_FILE="$VPS_ETC_DIR/handoff"
readonly VPS_LOCK_FILE=/run/vps-proxy-setup.lock

# Fixed ports (detailed design 2.8).
readonly VPS_PORT_REALITY=443
readonly VPS_PORT_FORWARDER=20443
readonly VPS_PORT_SUB=2096
readonly VPS_PORT_CFD_METRICS=20241
readonly VPS_PORT_XUI_API=62789
readonly VPS_PORT_XRAY_METRICS=11111
# Loopback ports the tool uses; the panel port comes from vps-hardening.
readonly VPS_LOOPBACK_PORTS=("$VPS_PORT_FORWARDER" "$VPS_PORT_SUB" "$VPS_PORT_CFD_METRICS" \
  "$VPS_PORT_XUI_API" "$VPS_PORT_XRAY_METRICS")

# 3X-UI locations (detailed design 4.1, 4.2).
readonly VPS_XUI_DIR=/usr/local/x-ui
readonly VPS_XUI_BIN=/usr/local/x-ui/x-ui
readonly VPS_XUI_XRAY=/usr/local/x-ui/bin/xray-linux-amd64
readonly VPS_XUI_SCRIPT=/usr/bin/x-ui
readonly VPS_XUI_UNIT_FILE=/etc/systemd/system/x-ui.service
readonly VPS_XUI_DB_DIR=/etc/x-ui
readonly VPS_XUI_DB="$VPS_XUI_DB_DIR/x-ui.db"
readonly VPS_XUI_ENV_FILES=(/etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui)

# vps-hardening (requirements A-1).
readonly VPS_HARDENING_BIN=/usr/local/bin/vps-hardening
readonly VPS_HARDENING_STATE=/var/lib/vps-hardening/state
readonly VPS_CLOUDFLARED_BIN=/usr/local/bin/cloudflared
readonly VPS_CFD_UNIT=vps-proxy-setup-cloudflared.service

VPS_COUNT_PASS=0
VPS_COUNT_FAIL=0
VPS_COUNT_WARN=0
VPS_COUNT_SKIP=0

# report LEVEL ID MESSAGE...
# LEVEL is PASS, FAIL, WARN, SKIP or INFO. IDs are stable; tests match on them.
report() {
  local level="$1" id="$2"
  shift 2
  case "$level" in
    PASS) VPS_COUNT_PASS=$((VPS_COUNT_PASS + 1)) ;;
    FAIL) VPS_COUNT_FAIL=$((VPS_COUNT_FAIL + 1)) ;;
    WARN) VPS_COUNT_WARN=$((VPS_COUNT_WARN + 1)) ;;
    SKIP) VPS_COUNT_SKIP=$((VPS_COUNT_SKIP + 1)) ;;
    INFO) ;;
    *) internal_error "未知的报告级别：$level" ;;
  esac
  printf '[%s] %-30s %s\n' "$level" "$id" "$*"
}

report_summary() {
  printf '\n结果：%d 项通过，%d 项不符合，%d 项警告，%d 项跳过。\n' \
    "$VPS_COUNT_PASS" "$VPS_COUNT_FAIL" "$VPS_COUNT_WARN" "$VPS_COUNT_SKIP"
}

# Print the summary and exit. Exiting here, rather than returning a status,
# keeps a FAIL result from being mistaken for an internal error by the ERR trap.
finish_checks() {
  report_summary
  if [ "$VPS_COUNT_FAIL" -eq 0 ]; then
    exit "$VPS_EXIT_OK"
  fi
  exit "$VPS_EXIT_FAIL"
}

# A gate check failed: nothing after it runs (detailed design 3).
stop_at_gate() {
  report_summary
  exit "$VPS_EXIT_FAIL"
}

usage_error() {
  printf '[x] %s\n' "$*" >&2
  printf '    用法见 vps-proxy-setup --help\n' >&2
  exit "$VPS_EXIT_USAGE"
}

# A command refused before it changed anything.
refuse() {
  printf '[x] %s\n' "$*" >&2
  exit "$VPS_EXIT_FAIL"
}

internal_error() {
  printf '[x] 内部错误：%s\n' "$*" >&2
  exit "$VPS_EXIT_INTERNAL"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Read-only commands still get a bound so a hung service cannot stall a check
# (detailed design 8: systemctl, ss and fail2ban-client 30 seconds).
bounded() {
  timeout --kill-after=5 30 "$@"
}

# Private scratch directory and other paths removed on exit. Call in the main
# shell, never inside $(...), or the variables would not reach the trap.
VPS_TMP=''
VPS_CLEANUP=()
vps_tmp_init() {
  if [ -z "$VPS_TMP" ]; then
    VPS_TMP="$(mktemp -d /tmp/vps-proxy-setup.XXXXXXXX)" || internal_error '无法创建临时目录'
  fi
}

# Said on stderr when the process exits before a command clears it: an
# internal error or a signal ended the command before its result was in place.
VPS_EXIT_NOTE=''

vps_cleanup() {
  local path
  [ -z "$VPS_EXIT_NOTE" ] || printf '%s\n' "$VPS_EXIT_NOTE" >&2 || true
  for path in "${VPS_CLEANUP[@]}"; do
    rm -f -- "$path"
  done
  [ -z "$VPS_TMP" ] || rm -rf -- "$VPS_TMP"
}

# take_lock: the deploy lock (detailed design 2.1). The descriptor stays open
# until the process exits, which releases the lock.
take_lock() {
  exec {VPS_LOCK_FD}>>"$VPS_LOCK_FILE" || refuse "无法打开锁文件 $VPS_LOCK_FILE"
  flock -n "$VPS_LOCK_FD" || refuse '另一个 vps-proxy-setup 部署或安装正在进行；请等它结束后再试'
}

join_by() {
  local sep="$1" first=1 item
  shift
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$sep" "$item"
    fi
  done
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

is_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}
