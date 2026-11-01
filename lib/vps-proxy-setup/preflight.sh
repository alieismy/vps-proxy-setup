# shellcheck shell=bash
# Preflight items of deploy and deploy --migrate (detailed design 3). The gate
# items root and platform run before the lock and the inputs; everything here
# runs after the inputs were validated and only reads the host (FR-12).
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

readonly VPS_PREFLIGHT_DEPS=(curl jq sqlite3 openssl ss ip systemctl sha256sum base64 iconv timeout \
  flock getent lslocks)
readonly VPS_TUNING_DROPIN=/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf

# Panel port from the vps-hardening record, set by pf_panel_port when valid.
VPS_PANEL_PORT=''

dep_package() {
  case "$1" in
    ss | ip) printf 'iproute2' ;;
    systemctl) printf 'systemd' ;;
    sha256sum | base64 | timeout) printf 'coreutils' ;;
    iconv | getent) printf 'libc-bin' ;;
    flock | lslocks) printf 'util-linux' ;;
    *) printf '%s' "$1" ;;
  esac
}

# missing_deps CMD...: report the commands that are not available and the
# Debian packages that provide them.
deps_report() {
  local id="$1" cmd pkgs=() missing=()
  shift
  for cmd in "$@"; do
    if ! have "$cmd"; then
      missing+=("$cmd")
      pkgs+=("$(dep_package "$cmd")")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    report PASS "$id" '依赖的命令齐全'
    return 0
  fi
  mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
  report FAIL "$id" "缺少命令：$(join_by ' ' "${missing[@]}")；请安装 $(join_by ' ' "${pkgs[@]}")"
  return 1
}

node_ip_local() {
  local out
  out="$(bounded ip -j -4 addr show 2>/dev/null)" || return 1
  ADDR="$1" jq -e '[ .[].addr_info[]? | select(.local == env.ADDR) ] | length > 0' <<<"$out" >/dev/null 2>&1
}

pf_inputs() {
  local key value
  for key in "${VPS_INPUT_KEYS[@]}"; do
    input_key_allowed "$key" || continue
    value="${VPS_IN[$key]}"
    case "$key" in
      tunnel_token) report INFO inputs.tunnel_token '已提供' ;;
      node_ip)
        if ipv4_is_documentation "$value"; then
          report WARN inputs.node_ip "$value（文档地址段，只用于测试）"
        elif ! node_ip_local "$value"; then
          report WARN inputs.node_ip "$value（不在本机任何接口上：可能是 1:1 NAT，也可能填错，请核对）"
        else
          report INFO inputs.node_ip "$value"
        fi
        ;;
      *) report INFO "inputs.$key" "$value" ;;
    esac
  done
}

pf_apt_idle() {
  if package_manager_busy; then
    report FAIL apt.idle '包管理器正在运行（dpkg、apt 或 unattended-upgrades）；请等它结束后再试'
  else
    report PASS apt.idle '包管理器空闲'
  fi
}

pf_hardening() {
  local status version tested found=0 port verify_status
  status="$(hardening_state_get status)" || status=''
  if [ "$status" = applied ]; then
    report PASS hardening.state 'vps-hardening 已应用并确认'
  elif [ ! -r "$VPS_HARDENING_STATE" ]; then
    report FAIL hardening.state "读不到 $VPS_HARDENING_STATE；请先用 vps-hardening 加固并确认"
  else
    report FAIL hardening.state "vps-hardening 的状态是 ${status:-空}，不是 applied"
  fi

  if version="$(hardening_version)"; then
    for tested in "${VPS_PIN_HARDENING_TESTED[@]}"; do
      [ "$version" != "$tested" ] || found=1
    done
    if [ "$found" -eq 1 ]; then
      report PASS hardening.version "vps-hardening $version"
    else
      report WARN hardening.version "vps-hardening $version 不在测试过的版本（$(join_by ' ' "${VPS_PIN_HARDENING_TESTED[@]}")）中"
    fi
  else
    report WARN hardening.version "无法从 $VPS_HARDENING_BIN 读取版本"
  fi

  port="$(hardening_state_get panel_port)" || port=''
  if ! is_port "$port"; then
    report FAIL hardening.panel-port '加固记录中没有有效的面板端口（panel_port）'
  elif [ "$port" -eq 22 ] || [ "$port" -eq "$VPS_PORT_REALITY" ] ||
    [[ " ${VPS_LOOPBACK_PORTS[*]} " == *" $port "* ]]; then
    report FAIL hardening.panel-port "面板端口 $port 与 SSH 或本工具使用的端口冲突"
  else
    VPS_PANEL_PORT="$port"
    report PASS hardening.panel-port "面板端口 $port"
  fi

  verify_status="$(hardening_verify_status)"
  if [ "$verify_status" -eq 0 ]; then
    report PASS hardening.verify 'vps-hardening verify 通过'
  else
    report FAIL hardening.verify "vps-hardening verify 的退出码为 $verify_status；请执行它查看不符合项"
  fi
}

pf_new_host() {
  local found=() path unit
  for path in "$VPS_XUI_DIR" "$VPS_XUI_SCRIPT" "${VPS_XUI_ENV_FILES[@]}"; do
    [ ! -e "$path" ] || found+=("$path")
  done
  unit_known x-ui.service && found+=(x-ui.service)
  if [ "${#found[@]}" -eq 0 ]; then
    report PASS new-host.xui '没有 3X-UI 的程序、单元或环境文件'
  else
    report FAIL new-host.xui "已有 3X-UI：$(join_by ' ' "${found[@]}")；本工具只部署到新机"
  fi

  if [ -e "$VPS_XUI_DB_DIR" ]; then
    report FAIL new-host.xui-db "已有 $VPS_XUI_DB_DIR；本工具只部署到新机"
  else
    report PASS new-host.xui-db "没有 $VPS_XUI_DB_DIR"
  fi

  found=()
  [ ! -e "$VPS_CLOUDFLARED_BIN" ] || found+=("$VPS_CLOUDFLARED_BIN")
  have cloudflared && found+=("$(command -v cloudflared)")
  pkg_installed cloudflared && found+=('软件包 cloudflared')
  for unit in cloudflared.service "$VPS_CFD_UNIT" cloudflared-update.timer; do
    unit_known "$unit" && found+=("$unit")
  done
  [ ! -e /etc/cloudflared ] || found+=(/etc/cloudflared)
  if [ "${#found[@]}" -eq 0 ]; then
    report PASS new-host.cloudflared '没有 cloudflared'
  else
    report FAIL new-host.cloudflared "已有 cloudflared：$(join_by ' ' "${found[@]}")；本工具只部署到新机"
  fi

  if [ ! -e "$VPS_ETC_DIR" ] && [ ! -L "$VPS_ETC_DIR" ]; then
    report PASS new-host.state '没有部署过'
  elif etc_dir_only_target_checks; then
    report PASS new-host.state "$VPS_ETC_DIR 中只有 target-check 的结果"
  else
    report FAIL new-host.state "$VPS_ETC_DIR 中有部署留下的内容，或者属主、权限不对；本工具只部署到新机"
  fi
}

# The tool's directory holds nothing but target-check results (detailed
# design 3 new-host.state).
etc_dir_only_target_checks() {
  local entries others
  [ "$(file_attrs "$VPS_ETC_DIR")" = 'directory|0|700' ] || return 1
  entries="$(find "$VPS_ETC_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)" || return 1
  [ -z "$entries" ] && return 0
  [ "$entries" = target-check ] || return 1
  [ "$(file_attrs "$VPS_TARGET_DIR")" = 'directory|0|700' ] || return 1
  others="$(find "$VPS_TARGET_DIR" -mindepth 1 -maxdepth 1 ! -type f -printf '%f\n' 2>/dev/null)" || return 1
  [ -z "$others" ]
}

pf_ports_free() {
  local port state busy=() ports=("$VPS_PORT_REALITY" "${VPS_LOOPBACK_PORTS[@]}")
  [ -z "$VPS_PANEL_PORT" ] || ports+=("$VPS_PANEL_PORT")
  tcp_listeners_load
  for port in "${ports[@]}"; do
    if ! state="$(port_state "$port")"; then
      report FAIL ports.free '无法读取监听端口（ss）'
      return 0
    fi
    [ "$state" = none ] || busy+=("$port")
  done
  if [ "${#busy[@]}" -eq 0 ]; then
    report PASS ports.free "要用的端口都空闲：$(join_by ' ' "${ports[@]}")"
  else
    report FAIL ports.free "已被占用：$(join_by ' ' "${busy[@]}")"
  fi
}

pf_tuning_dropin() {
  if [ -e "$VPS_TUNING_DROPIN" ]; then
    report PASS tuning.dropin "有 $VPS_TUNING_DROPIN"
  else
    report WARN tuning.dropin "没有 $VPS_TUNING_DROPIN：之后 vps-tuning 的严格验证需要它，请先按 README 的顺序完成调优"
  fi
}

pf_target_checked() {
  local target="${VPS_IN[target]}" days notes=''
  target_record_check "$VPS_TARGET_DIR/$target" "$target"
  case "$VPS_TR_STATE" in
    pass)
      days=$((VPS_TR_AGE / 86400))
      [ -z "$VPS_TR_WARNS" ] || notes="；核实结果中有警告：$VPS_TR_WARNS"
      if [ "$VPS_TR_AGE" -gt "$VPS_TARGET_MAX_AGE" ]; then
        report WARN target.checked "$target 的核实结果是 $days 天前的，早于 7 天，建议重新执行 target-check$notes"
      elif [ -n "$notes" ]; then
        report WARN target.checked "$target 在本机核实通过（$days 天前）$notes"
      else
        report PASS target.checked "$target 在本机核实通过（$days 天前）"
      fi
      ;;
    *)
      report FAIL target.checked "$target：$VPS_TR_REASON；请先在本机执行 vps-proxy-setup target-check $target"
      ;;
  esac
}

run_preflight() {
  pf_inputs
  deps_report deps "${VPS_PREFLIGHT_DEPS[@]}" || true
  pf_apt_idle
  pf_hardening
  pf_new_host
  pf_ports_free
  pf_tuning_dropin
  pf_target_checked
  check_ipv6_egress "${VPS_IN[ipv6_ai_egress]}"
}
