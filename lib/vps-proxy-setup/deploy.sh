# shellcheck shell=bash
# deploy (detailed design 2.5, 16.1). After the preflight and the
# administrator's confirmation: fetch and verify the 3X-UI files (step 2), run
# the verified installer (step 3) and verify what it installed (step 4). The
# steps after 4 come later in M2 and in M3.
# Globals defined here are read by the tests through the module, which
# ShellCheck checks separately.
# shellcheck disable=SC2034

readonly VPS_GH_REPO='MHSanaei/3x-ui'
readonly VPS_GH_API="https://api.github.com/repos/$VPS_GH_REPO"
readonly VPS_GH_RAW="https://raw.githubusercontent.com/$VPS_GH_REPO"
readonly VPS_GH_RELEASE="https://github.com/$VPS_GH_REPO/releases/download"
readonly VPS_XUI_ARCHIVE='x-ui-linux-amd64.tar.gz'
# Members of the archive that the installer uses on Debian (detailed design 6).
readonly VPS_XUI_ARCHIVE_UNIT='x-ui/x-ui.service.debian'
# Operating bounds chosen here, not measured performance: the archive is about
# 80 MB, and the installer also runs apt-get.
readonly VPS_FETCH_TIMEOUT=900
readonly VPS_API_TIMEOUT=30
readonly VPS_INSTALL_TIMEOUT=1800
readonly VPS_PANEL_WAIT=60

# Set by the steps; the tests call the steps through the module (detailed
# design 19) and read these.
VPS_PREFETCH_DIR=''
VPS_INSTALL_LOG=''
VPS_TUNING_BEFORE=''

# deploy_stop STEP MESSAGE: the step did not complete. MESSAGE says what state
# the host is left in and what to do next (detailed design 16.1).
deploy_stop() {
  printf '[x] 第 %s 步未完成：%s\n' "$1" "$2" >&2
  exit "$VPS_EXIT_FAIL"
}

# The documented cleanup of solution design 7.3; nothing is rolled back (FR-12).
readonly VPS_CLEANUP_HINT='这台主机已部分安装 3X-UI，不会自动回滚。请按清理步骤处理（方案设计第 7.3 节：x-ui uninstall 之后恢复 vps-tuning 的 90-proxy-vps.conf，删除 /etc/vps-proxy-setup/），预检和 vps-tuning 的严格验证都通过后再部署'

deploy_step() {
  printf '\n== 第 %s 步：%s\n' "$1" "$2"
}

# The change plan and the confirmation (detailed design 2.5). Anything but
# "yes" cancels with the host unchanged.
deploy_confirm() {
  local answer=''
  {
    printf '\n预检通过。将要改动这台主机：\n'
    printf '  - 从 GitHub 取得 3X-UI %s 的安装器、发布包和 x-ui.sh，按固定的提交和摘要核对，不符就停止\n' "$VPS_PIN_XUI_TAG"
    printf '  - 以非交互方式运行安装器：面板端口 %s，不启用 IP Limit，SQLite，不配置 SSL；它会安装软件包并启动 x-ui\n' "$VPS_PANEL_PORT"
    printf '  - 核对所装的文件，把面板改为只监听 127.0.0.1 并重启\n'
    printf '  - 写入订阅设置、REALITY 入站（target %s）、转发入站、路由和使用者\n' "${VPS_IN[target]}"
    printf '不会开放端口，也不会改动 UFW。第 3 步起失败时不自动回滚，要按清理步骤处理。\n'
    printf '输入 yes 继续，其他输入取消：'
  } >&2
  IFS= read -r answer || answer=''
  if [ "$answer" != yes ]; then
    printf '[x] 已取消，主机未改动\n' >&2
    exit "$VPS_EXIT_FAIL"
  fi
}

# Time passed while the administrator read the plan: the host must still be new
# and the ports free (detailed design 16.1 step 1).
deploy_recheck() {
  local before="$VPS_COUNT_FAIL"
  printf '\n== 再次核对主机\n'
  pf_apt_idle
  pf_new_host
  pf_ports_free
  [ "$VPS_COUNT_FAIL" -eq "$before" ] || deploy_stop 1 '确认之后主机有变化，主机未改动'
}

# fetch URL FILE: download over HTTPS only, redirects included. -q, which must
# come first, skips .curlrc.
fetch() {
  curl -q --fail --silent --location --proto '=https' --proto-redir '=https' --connect-timeout 15 \
    --max-time "$VPS_FETCH_TIMEOUT" --output "$2" -- "$1" 2>/dev/null
}

# xui_tag_commit: the commit that the pinned tag points to, from the GitHub
# API. An annotated tag is followed to its commit.
xui_tag_commit() {
  local json type sha i
  json="$(curl -q --fail --silent --proto '=https' --connect-timeout 15 --max-time "$VPS_API_TIMEOUT" \
    -H 'Accept: application/vnd.github+json' -- "$VPS_GH_API/git/ref/tags/$VPS_PIN_XUI_TAG" 2>/dev/null)" ||
    return 1
  for i in 1 2; do
    type="$(jq -r '.object.type // empty' <<<"$json" 2>/dev/null)" || return 1
    sha="$(jq -r '.object.sha // empty' <<<"$json" 2>/dev/null)" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    if [ "$type" = commit ]; then
      printf '%s\n' "$sha"
      return 0
    fi
    [ "$type" = tag ] && [ "$i" -eq 1 ] || return 1
    json="$(curl -q --fail --silent --proto '=https' --connect-timeout 15 --max-time "$VPS_API_TIMEOUT" \
      -H 'Accept: application/vnd.github+json' -- "$VPS_GH_API/git/tags/$sha" 2>/dev/null)" || return 1
  done
  return 1
}

# fetch_item ID URL FILE SHA256 [SIZE]: download and compare with the pin.
fetch_item() {
  local id="$1" url="$2" file="$3" want="$4" size="${5-}" got
  if ! fetch "$url" "$file"; then
    report FAIL "$id" "下载失败：${url##*/}"
    return 0
  fi
  if [ -n "$size" ] && [ "$(stat -c %s -- "$file")" != "$size" ]; then
    report FAIL "$id" "${url##*/} 的大小不是固定的 $size 字节"
    return 0
  fi
  got="$(file_sha256 "$file")" || got=''
  if [ "$got" = "$want" ]; then
    report PASS "$id" "${url##*/} 与固定的摘要一致"
  else
    report FAIL "$id" "${url##*/} 与固定的摘要不符"
  fi
}

# archive_member_sha256 ARCHIVE MEMBER: tar reads the whole archive, so the
# pipe is never cut short.
archive_member_sha256() {
  local out
  out="$(tar -xzOf "$1" -- "$2" 2>/dev/null | sha256sum)" || return 1
  printf '%s\n' "${out%% *}"
}

# Step 2: nothing is run or installed until every file matches its pin
# (detailed design 16.1, VT-11).
deploy_prefetch() {
  local before="$VPS_COUNT_FAIL" commit unit_sha unit_pin script_pin
  # Assigned on their own, so that a missing pin is an internal error.
  unit_pin="$(pin_sha256_of "$VPS_XUI_UNIT_FILE")"
  script_pin="$(pin_sha256_of "$VPS_XUI_SCRIPT")"
  VPS_PREFETCH_DIR="$VPS_TMP/prefetch"
  mkdir -m 0700 -- "$VPS_PREFETCH_DIR"
  if ! commit="$(xui_tag_commit)"; then
    report FAIL fetch.tag "无法从 GitHub 读取 $VPS_PIN_XUI_TAG 指向的提交"
  elif [ "$commit" != "$VPS_PIN_XUI_COMMIT" ]; then
    report FAIL fetch.tag "$VPS_PIN_XUI_TAG 指向的提交不是固定的 $VPS_PIN_XUI_COMMIT（tag 可能被移动）"
  else
    report PASS fetch.tag "$VPS_PIN_XUI_TAG 指向固定的提交 $VPS_PIN_XUI_COMMIT"
  fi
  [ "$VPS_COUNT_FAIL" -eq "$before" ] || deploy_stop 2 '主机未改动'

  fetch_item fetch.installer "$VPS_GH_RAW/$VPS_PIN_XUI_COMMIT/install.sh" "$VPS_PREFETCH_DIR/install.sh" \
    "$VPS_PIN_XUI_INSTALL_SHA256"
  fetch_item fetch.archive "$VPS_GH_RELEASE/$VPS_PIN_XUI_TAG/$VPS_XUI_ARCHIVE" \
    "$VPS_PREFETCH_DIR/$VPS_XUI_ARCHIVE" "$VPS_PIN_XUI_TARBALL_SHA256" "$VPS_PIN_XUI_TARBALL_SIZE"
  # The installer takes the unit from the archive and x-ui.sh from the tag
  # path; both are compared with the digests of the installed copies.
  if [ "$VPS_COUNT_FAIL" -eq "$before" ]; then
    unit_sha="$(archive_member_sha256 "$VPS_PREFETCH_DIR/$VPS_XUI_ARCHIVE" "$VPS_XUI_ARCHIVE_UNIT")" || unit_sha=''
    if [ "$unit_sha" = "$unit_pin" ]; then
      report PASS fetch.unit "发布包中的 ${VPS_XUI_ARCHIVE_UNIT#*/} 与固定的摘要一致"
    else
      report FAIL fetch.unit "发布包中的 ${VPS_XUI_ARCHIVE_UNIT#*/} 与固定的摘要不符"
    fi
  fi
  fetch_item fetch.script "$VPS_GH_RAW/$VPS_PIN_XUI_TAG/x-ui.sh" "$VPS_PREFETCH_DIR/x-ui.sh" "$script_pin"
  [ "$VPS_COUNT_FAIL" -eq "$before" ] || deploy_stop 2 '主机未改动'
}

# pin_sha256_of PATH: the pinned digest of an installed file.
pin_sha256_of() {
  local i
  for i in "${!VPS_PIN_XUI_FILES[@]}"; do
    if [ "${VPS_PIN_XUI_FILES[$i]}" = "$1" ]; then
      printf '%s\n' "${VPS_PIN_XUI_SHA256[$i]}"
      return 0
    fi
  done
  internal_error "没有 $1 的固定摘要"
}

# "absent", or "TYPE|UID|MODE|SHA256" of the vps-tuning drop-in.
tuning_dropin_state() {
  local attrs sum
  if [ ! -e "$VPS_TUNING_DROPIN" ] && [ ! -L "$VPS_TUNING_DROPIN" ]; then
    printf 'absent\n'
    return 0
  fi
  attrs="$(file_attrs "$VPS_TUNING_DROPIN")" || attrs='?'
  sum="$(file_sha256 "$VPS_TUNING_DROPIN")" || sum='?'
  printf '%s|%s\n' "$attrs" "$sum"
}

# Step 3: the verified installer, non-interactive. Its output holds the panel
# credentials and the API token, so it goes to a private file (detailed design
# 15.2). Inherited XUI_* variables are removed: some move the install folder,
# the unit or the database (detailed design 14). DEBIAN_FRONTEND keeps the
# installer's apt-get from asking on the terminal. Returns the installer's status.
# --foreground keeps the installer and its children in the terminal's process
# group, so that Ctrl-C stops them too; the shell's own trap runs only after
# timeout returns. On the time bound only the installer itself is signalled.
deploy_install() {
  local var rc=0
  local -a unset_xui=()
  VPS_TUNING_BEFORE="$(tuning_dropin_state)"
  VPS_INSTALL_LOG="$VPS_TMP/install.log"
  for var in $(compgen -e); do
    [[ "$var" != XUI_* ]] || unset_xui+=(-u "$var")
  done
  timeout --foreground --kill-after=30 "$VPS_INSTALL_TIMEOUT" env "${unset_xui[@]}" \
    DEBIAN_FRONTEND=noninteractive XUI_NONINTERACTIVE=1 XUI_PANEL_PORT="$VPS_PANEL_PORT" \
    XUI_ENABLE_FAIL2BAN=false XUI_DB_TYPE=sqlite XUI_SSL_MODE=none bash "$VPS_PREFETCH_DIR/install.sh" "$VPS_PIN_XUI_TAG" </dev/null >"$VPS_INSTALL_LOG" 2>&1 || rc=$?
  return "$rc"
}

# install_result_values: the secret values of the install result, if the
# installer got that far, for leaving out the lines that hold them. They go
# from here to grep through a pipe only.
install_result_values() {
  local file="$VPS_XUI_DB_DIR/install-result.env"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  sed -n 's/^XUI_\(USERNAME\|PASSWORD\|WEB_BASE_PATH\|API_TOKEN\)=//p' -- "$file" 2>/dev/null |
    sed 's#^/##; s#/$##' | awk 'length($0) >= 8'
}

# The end of the installer's output without the lines that carry credentials,
# the access URL or the token (VT-13): every line with one of the words the
# installer prints them after, and every line with one of the values.
install_log_tail() {
  {
    sed 's/\x1b\[[0-9;]*m//g' -- "$VPS_INSTALL_LOG" 2>/dev/null |
      grep -viE 'user|pass|token|path|url|http|key|secret|dsn' |
      grep -vF -f <(install_result_values) | tail -n 20 | sed 's/^/    /'
  } >&2 || true
}

# wait_panel_loopback: after the restart, the panel listens on loopback only.
# Prints "loopback", "exposed" or "none" as last seen.
wait_panel_loopback() {
  local deadline state=none
  deadline=$((SECONDS + VPS_PANEL_WAIT))
  while :; do
    tcp_listeners_load
    state="$(port_state "$VPS_PANEL_PORT")" || state=none
    [ "$state" != loopback ] || break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 2
  done
  printf '%s\n' "$state"
}

# Step 4: the installed files before anything else; a mismatch means a
# replaced file has already run as root (solution design SR-9, VT-12). Then
# the panel moves to loopback.
deploy_verify_install() {
  local before="$VPS_COUNT_FAIL" after state
  ck_xui_program
  if [ "$VPS_XUI_FILES_OK" -ne 1 ]; then
    deploy_stop 4 '所装的文件与固定的摘要不符。安装器已经以 root 运行过它们：请把这台主机按可能被入侵处理，不要继续使用，重装系统后再部署（方案设计 SR-9）。业务设置未写入；卸载 3X-UI 不能消除这个风险'
  fi
  ck_xui_unit
  ck_xui_env_service_ipl
  after="$(tuning_dropin_state)"
  if [ "$after" = "$VPS_TUNING_BEFORE" ]; then
    report PASS tuning.kept '90-proxy-vps.conf 与安装前相同'
  else
    report FAIL tuning.kept '90-proxy-vps.conf 与安装前不同'
  fi
  [ "$VPS_COUNT_FAIL" -eq "$before" ] || deploy_stop 4 "$VPS_CLEANUP_HINT"

  if ! timeout --kill-after=5 30 "$VPS_XUI_BIN" setting -listenIP 127.0.0.1 </dev/null >/dev/null 2>&1; then
    deploy_stop 4 "x-ui setting -listenIP 失败。$VPS_CLEANUP_HINT"
  fi
  bounded systemctl restart x-ui.service </dev/null >/dev/null 2>&1 ||
    deploy_stop 4 "重启 x-ui 失败。$VPS_CLEANUP_HINT"
  state="$(wait_panel_loopback)"
  case "$state" in
    loopback) report PASS panel.listen "面板只监听回环地址的 $VPS_PANEL_PORT" ;;
    exposed) report FAIL panel.listen "面板端口 $VPS_PANEL_PORT 在回环地址之外也有监听" ;;
    *) report FAIL panel.listen "重启后 $VPS_PANEL_WAIT 秒内面板端口 $VPS_PANEL_PORT 没有监听" ;;
  esac
  [ "$VPS_COUNT_FAIL" -eq "$before" ] || deploy_stop 4 "$VPS_CLEANUP_HINT"
}

cmd_deploy() {
  parse_deploy_args "$@"
  check_root_gate
  check_platform_gate
  take_lock
  load_deploy_inputs
  run_preflight
  report_summary
  if [ "$VPS_COUNT_FAIL" -gt 0 ]; then
    printf '[x] 预检不通过，主机未改动\n' >&2
    exit "$VPS_EXIT_FAIL"
  fi
  if [ "$VPS_IN_MIGRATE" -eq 1 ]; then
    printf '[x] 预检通过；deploy --migrate 的后续步骤尚未实现，主机未改动\n' >&2
    exit "$VPS_EXIT_FAIL"
  fi
  deploy_confirm
  deploy_recheck
  vps_tmp_init

  deploy_step 2 '取得并核对 3X-UI 的文件'
  deploy_prefetch

  deploy_step 3 "安装 3X-UI $VPS_PIN_XUI_VERSION"
  if ! deploy_install; then
    printf '[x] 安装器失败；它的输出末尾（去掉了含凭据的行）：\n' >&2
    install_log_tail
    deploy_stop 3 "$VPS_CLEANUP_HINT"
  fi
  report PASS xui.install '安装器正常结束'

  deploy_step 4 '核对安装结果'
  deploy_verify_install

  printf '\n[x] 第 1～4 步完成：3X-UI 已安装并核对，面板只监听 127.0.0.1。第 5 步起尚未实现（M2 开发中）；输入文件保留\n' >&2
  exit "$VPS_EXIT_FAIL"
}
