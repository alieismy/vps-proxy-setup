# shellcheck shell=bash
# Platform detection (requirements NFR-03, detailed design 3).
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

VPS_PLATFORM_REASON=''

# os-release is parsed, never sourced: it is data, not a script.
os_release_value() {
  local key="$1" file="${2:-/etc/os-release}" line value
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

# platform_ok: Debian 13 amd64 under systemd, not in a container. On failure
# VPS_PLATFORM_REASON says why.
platform_ok() {
  local id version arch pid1 virt
  id="$(os_release_value ID || true)"
  version="$(os_release_value VERSION_ID || true)"
  if [ "$id" != debian ] || [ "$version" != 13 ]; then
    VPS_PLATFORM_REASON="系统是 ${id:-未知} ${version:-未知}，只支持 Debian 13"
    return 1
  fi
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [ "$arch" != amd64 ]; then
    VPS_PLATFORM_REASON="架构是 ${arch:-未知}，只支持 amd64"
    return 1
  fi
  pid1="$(cat /proc/1/comm 2>/dev/null || true)"
  if [ "$pid1" != systemd ]; then
    VPS_PLATFORM_REASON='PID 1 不是 systemd'
    return 1
  fi
  # systemd-detect-virt prints "none" and exits non-zero outside a container.
  # Anything else, including a missing command, counts as not supported.
  virt="$(systemd-detect-virt --container 2>/dev/null || true)"
  if [ "$virt" != none ]; then
    VPS_PLATFORM_REASON="运行在容器中（${virt:-无法判定}）"
    return 1
  fi
  return 0
}

check_platform_gate() {
  if platform_ok; then
    report PASS platform 'Debian 13 amd64，systemd，不在容器中'
  else
    report FAIL platform "$VPS_PLATFORM_REASON"
    stop_at_gate
  fi
}

check_root_gate() {
  if [ "$(id -u)" -eq 0 ]; then
    report PASS root '以 root 运行'
  else
    report FAIL root '必须以 root 运行'
    stop_at_gate
  fi
}
