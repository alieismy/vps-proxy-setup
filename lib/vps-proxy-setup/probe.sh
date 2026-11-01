# shellcheck shell=bash
# Read-only probes of the host (detailed design 7): listening ports, unit
# properties, file attributes and digests, the vps-hardening record and
# verify, the package manager locks and the local IPv6 configuration.
# Nothing here may change files, services or rules.

pkg_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]
}

# systemd knows a unit file for the unit (it may be disabled or stopped).
unit_known() {
  local state
  state="$(bounded systemctl show -p LoadState --value -- "$1" 2>/dev/null)" || return 1
  [ -n "$state" ] && [ "$state" != not-found ]
}

# unit_prop UNIT PROPERTY: the effective value after drop-ins.
unit_prop() {
  bounded systemctl show -p "$2" --value -- "$1" 2>/dev/null
}

file_sha256() {
  local out
  out="$(sha256sum -- "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${out%% *}"
}

# file_attrs PATH: "TYPE|UID|MODE" without following a symlink.
file_attrs() {
  stat -c '%F|%u|%a' -- "$1" 2>/dev/null
}

# TCP listeners as "ADDRESS PORT" lines. The callers run in $(...), where the
# cache would not survive; tcp_listeners_load fills it in the calling shell, so
# the port checks after it share one ss read. ss is read whole: a reader that
# stops early would kill it with SIGPIPE (detailed design 8).
VPS_SS_CACHE=''
VPS_SS_READ=0
tcp_listeners_load() {
  VPS_SS_READ=0
  # On failure the cache stays empty and each port check reports it.
  tcp_listeners >/dev/null || true
}
tcp_listeners() {
  local out line local_addr addr port
  if [ "$VPS_SS_READ" -eq 0 ]; then
    out="$(bounded ss -Hltn 2>/dev/null)" || return 1
    VPS_SS_CACHE=''
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Columns: State Recv-Q Send-Q Local:Port Peer:Port [Process]
      read -r _ _ _ local_addr _ <<<"$line"
      port="${local_addr##*:}"
      addr="${local_addr%:*}"
      addr="${addr#[}"
      addr="${addr%]}"
      addr="${addr%%%*}"
      VPS_SS_CACHE+="$addr $port"$'\n'
    done <<<"$out"
    VPS_SS_READ=1
  fi
  printf '%s' "$VPS_SS_CACHE"
}

# listen_addrs PORT: the addresses with a TCP listener on PORT, one per line.
listen_addrs() {
  local list
  list="$(tcp_listeners)" || return 1
  awk -v port="$1" '$2 == port { print $1 }' <<<"$list"
}

is_loopback_addr() {
  case "$1" in
    127.* | ::1) return 0 ;;
  esac
  return 1
}

# port_state PORT: prints "none", "loopback" (only loopback listeners) or
# "exposed" (some listener outside loopback). Returns 1 when ss fails.
port_state() {
  local addrs addr seen=0
  addrs="$(listen_addrs "$1")" || return 1
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    seen=1
    if ! is_loopback_addr "$addr"; then
      printf 'exposed\n'
      return 0
    fi
  done <<<"$addrs"
  if [ "$seen" -eq 1 ]; then
    printf 'loopback\n'
  else
    printf 'none\n'
  fi
}

# hardening_state_get KEY: the first line of the key in the vps-hardening
# state file, as its own state_get reads it (detailed design 8, 14).
hardening_state_get() {
  [ -r "$VPS_HARDENING_STATE" ] || return 1
  KEY="$1" awk 'index($0, ENVIRON["KEY"] "=") == 1 && !seen { print substr($0, length(ENVIRON["KEY"]) + 2); seen = 1 }' \
    "$VPS_HARDENING_STATE"
}

hardening_version() {
  local out
  out="$(timeout --kill-after=5 30 "$VPS_HARDENING_BIN" --version 2>/dev/null)" || return 1
  case "$out" in
    'vps-hardening '*) printf '%s\n' "${out#vps-hardening }" ;;
    *) return 1 ;;
  esac
}

# hardening_verify_status: the exit status of vps-hardening verify (NFR-04).
# Its output is not transcribed.
hardening_verify_status() {
  local status=0
  timeout --kill-after=5 120 "$VPS_HARDENING_BIN" verify >/dev/null 2>&1 || status=$?
  printf '%d\n' "$status"
}

# Lock holders, plus apt or dpkg processes between taking locks; the same
# method as vps-hardening (detailed design 3).
package_manager_busy() {
  local lock locks name
  locks="$(lslocks -n -o PATH 2>/dev/null)" || locks=''
  for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock /run/unattended-upgrades.lock; do
    if grep -qxF -- "$lock" <<<"$locks"; then
      return 0
    fi
  done
  # One name per call: pgrep matches nothing when the whole pattern is longer
  # than 15 characters, even for an alternation of short names.
  for name in apt apt-get aptitude dpkg; do
    if pgrep -x -- "$name" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# ipv6_egress_facts: "USABLE TEMPORARY ROUTES" for the local IPv6 premise of
# FR-13 (detailed design 4.2 ipv6.egress). A usable address is global, on an
# interface that is UP, outside fc00::/7 and not tentative, dadfailed or
# deprecated; routes count only unicast defaults. The field names of ip -j
# are confirmed in M2 (DO-2). Returns 1 when ip or its output fails.
ipv6_egress_facts() {
  local addrs routes usable temporary count
  addrs="$(bounded ip -j -6 addr show 2>/dev/null)" || return 1
  routes="$(bounded ip -j -6 route show default 2>/dev/null)" || return 1
  usable="$(jq -r '
    [ .[] | select((.flags // []) | index("UP")) | .addr_info[]?
      | select(.family == "inet6" and .scope == "global")
      | select(.local | ascii_downcase | test("^f[cd][0-9a-f][0-9a-f]:") | not)
      | select((.tentative // false) or (.dadfailed // false) or (.deprecated // false) | not) ]
    | "\(length) \([ .[] | select(.temporary // false) ] | length)"' <<<"$addrs" 2>/dev/null)" ||
    return 1
  count="$(jq -r '[ .[] | select(.dst == "default") | select((has("type") | not) or .type == "unicast") ] | length' \
    <<<"$routes" 2>/dev/null)" || return 1
  read -r usable temporary <<<"$usable"
  is_uint "$usable" && is_uint "$temporary" && is_uint "$count" || return 1
  printf '%s %s %s\n' "$usable" "$temporary" "$count"
}

# check_ipv6_egress ENABLED: the shared judgement of preflight and check.
check_ipv6_egress() {
  local facts usable temporary routes
  if [ "$1" != on ]; then
    report SKIP ipv6.egress '未启用 FR-13（ipv6_ai_egress=off）'
    return 0
  fi
  if ! facts="$(ipv6_egress_facts)"; then
    report FAIL ipv6.egress '无法读取本机的 IPv6 地址或路由'
    return 0
  fi
  read -r usable temporary routes <<<"$facts"
  if [ "$usable" -eq 0 ] || [ "$routes" -eq 0 ]; then
    report FAIL ipv6.egress "没有可用的 IPv6 出站前提：可用的全局地址 $usable 个，单播默认路由 $routes 条；启用 FR-13 时有 IPv6 地址的 AI 域名会全部连接失败"
  elif [ "$usable" -gt 1 ]; then
    report WARN ipv6.egress "可用的全局地址 $usable 个（其中临时地址 $temporary 个），单播默认路由 $routes 条；不固定源地址，出口可能随源地址选择变化"
  else
    report PASS ipv6.egress "可用的全局地址 1 个，单播默认路由 $routes 条（只说明本机配置，不说明 IPv6 业务可达）"
  fi
}
