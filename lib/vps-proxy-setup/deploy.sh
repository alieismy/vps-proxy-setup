# shellcheck shell=bash
# deploy (detailed design 2.5, 16.1). After the preflight and the
# administrator's confirmation: fetch and verify the 3X-UI files (step 2), run
# the verified installer (step 3), verify what it installed (step 4), check
# that nothing is configured yet (step 5) and write the configuration through
# the panel API (step 6). The steps after 6 come later in M2 and in M3.
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
readonly VPS_CLEANUP_HINT='这台主机可能已部分安装 3X-UI，不会自动回滚。请按清理步骤处理（方案设计第 7.3 节：x-ui uninstall 之后恢复 vps-tuning 的 90-proxy-vps.conf，删除 /etc/vps-proxy-setup/），预检和 vps-tuning 的严格验证都通过后再部署'

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

# The installer's output without colours and without the lines that carry
# credentials, the access URL or the token (VT-13): every line with one of the
# words the installer prints them after, and every line with one of the values.
install_log_filtered() {
  sed 's/\x1b\[[0-9;]*m//g' -- "$VPS_INSTALL_LOG" 2>/dev/null |
    grep -viE 'user|pass|token|path|url|http|key|secret|dsn' |
    grep -vF -f <(install_result_values)
}

# The end of the filtered output, on stderr.
install_log_tail() {
  { install_log_filtered | tail -n 20 | sed 's/^/    /'; } >&2 || true
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

# --- Steps 5 and 6: the panel API (detailed design 15) ------------------------

readonly VPS_FORWARDER_REMARK='vps-proxy-setup-forwarder'
readonly VPS_AI_TAG='ai-ipv6'
# Keys that step 6 writes, and the template. On a new install none of them is
# in the settings table, so each has its built-in default. The subscription
# paths are random from the first start and are kept (16.1 step 6).
readonly VPS_WRITTEN_KEYS='subEnable subListen subPort subDomain subCertFile subKeyFile subURI subClashURI
subClashEnable subClashEnableRouting subClashRules subJsonEnable subInfoNodeEnable subUpdates remarkTemplate
xrayTemplateConfig'
# Fields of the settings view that are not settings (15.1).
readonly VPS_VIEW_KEYS='["hasTgBotToken","hasTwoFactorToken","hasLdapPassword","hasApiToken","hasWarpSecret",
"hasNordSecret","hasSmtpPassword","hasDiscordBotToken"]'
# covers($want): every field of $want is in the input with the same value;
# arrays and scalars compare whole. The panel adds fields of its own.
# shellcheck disable=SC2016 # jq code
readonly VPS_JQ_COVERS='def covers($want): . as $got
  | if ($want | type) == "object" then
      ($got | type) == "object" and
        all($want | to_entries[]; . as $e | ($got | has($e.key)) and ($got[$e.key] | covers($e.value)))
    else $got == $want end;'

# Install result and token, in memory only (15.2).
VPS_XUI_USER=''
VPS_XUI_PASS=''
VPS_XUI_BASE=''
VPS_XUI_TOKEN=''
VPS_TOKEN_ID=''
# The last API call.
VPS_API_HTTP=''
VPS_API_OUT=''
# What step 6 created, for the step reports and the tests.
VPS_FWD_ID=''
VPS_FWD_TAG=''
VPS_REALITY_ID=''
VPS_REALITY_TAG=''
VPS_DONE=()

# install_result_read: the fields of 15.2 from install-result.env, read once
# from one descriptor, without source or eval. Only the plain forms that the
# installer's random values have are accepted; the panel port must be the one
# vps-hardening recorded. Sets VPS_REASON on failure, never with a value.
install_result_read() {
  local file="$VPS_XUI_DB_DIR/install-result.env" fd attrs content rest line key
  local -A got=()
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    VPS_REASON='没有安装结果，或者它不是普通文件'
    return 1
  fi
  if ! { exec {fd}<"$file"; } 2>/dev/null; then
    VPS_REASON='无法打开安装结果'
    return 1
  fi
  attrs="$(stat -L -c '%F|%u|%a' "/proc/$$/fd/$fd" 2>/dev/null)" || attrs=''
  if [ "$attrs" != 'regular file|0|600' ]; then
    exec {fd}<&-
    VPS_REASON='安装结果不是属于 root、权限 0600 的普通文件'
    return 1
  fi
  { content="$(cat <&"$fd")"; } 2>/dev/null || content=''
  exec {fd}<&-
  # Split by parameter expansion: a here-string could put the secrets in a
  # temporary file (detailed design 8).
  rest="$content"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$rest" ]; then rest=''; else rest="${rest#*$'\n'}"; fi
    key="${line%%=*}"
    case "$key" in
      XUI_USERNAME | XUI_PASSWORD | XUI_PANEL_PORT | XUI_WEB_BASE_PATH | XUI_API_TOKEN) ;;
      *) continue ;;
    esac
    if [ -n "${got[$key]+x}" ]; then
      VPS_REASON="安装结果中 $key 重复"
      return 1
    fi
    got[$key]="${line#*=}"
  done
  for key in XUI_USERNAME XUI_PASSWORD; do
    if ! [[ "${got[$key]-}" =~ ^[A-Za-z0-9]{10}$ ]]; then
      VPS_REASON="安装结果中 $key 不是 10 个字母数字"
      return 1
    fi
  done
  if ! [[ "${got[XUI_WEB_BASE_PATH]-}" =~ ^[A-Za-z0-9]{18}$ ]]; then
    VPS_REASON='安装结果中 XUI_WEB_BASE_PATH 不是 18 个字母数字'
    return 1
  fi
  if ! [[ "${got[XUI_API_TOKEN]-}" =~ ^[A-Za-z0-9]{48}$ ]]; then
    VPS_REASON='安装结果中 XUI_API_TOKEN 不是 48 个字母数字'
    return 1
  fi
  if [ "${got[XUI_PANEL_PORT]-}" != "$VPS_PANEL_PORT" ]; then
    VPS_REASON='安装结果中的面板端口不是 vps-hardening 记录的端口'
    return 1
  fi
  VPS_XUI_USER="${got[XUI_USERNAME]}"
  VPS_XUI_PASS="${got[XUI_PASSWORD]}"
  VPS_XUI_BASE="${got[XUI_WEB_BASE_PATH]}"
  VPS_XUI_TOKEN="${got[XUI_API_TOKEN]}"
}

# api_call METHOD PATH [BODY_FILE [CONTENT_TYPE]]: one request to the panel on
# loopback (15.1). The URL holds webBasePath and the header the token, so both
# reach curl as a config on stdin, never as arguments. No proxy, no redirects,
# no retry. The response goes to the private file VPS_API_OUT and VPS_API_HTTP
# is the status. Returns 1 when no response came (connection failure or time
# bound): for a write the result is then unknown. The tests replace this
# function to lose a response or fail a request (detailed design 19).
api_call() {
  local method="$1" path="$2" body="${3-}" ctype="${4-application/json}" code
  local -a data=()
  VPS_API_OUT="$VPS_TMP/api-response"
  rm -f -- "$VPS_API_OUT"
  [ -z "$body" ] || data=(-H "Content-Type: $ctype" --data-binary "@$body")
  VPS_API_HTTP=000
  if ! code="$({
    printf 'url = "http://127.0.0.1:%s/%s/panel/api/%s"\n' "$VPS_PANEL_PORT" "$VPS_XUI_BASE" "$path"
    printf 'header = "Authorization: Bearer %s"\n' "$VPS_XUI_TOKEN"
  } | curl -q --silent --noproxy '*' --proto '=http' --connect-timeout 5 --max-time 30 -X "$method" \
    "${data[@]}" -o "$VPS_API_OUT" -w '%{http_code}' -K - 2>/dev/null)"; then
    return 1
  fi
  VPS_API_HTTP="$code"
}

# api_ok JQ: HTTP 200, "success" true and "obj" passing the jq test JQ. The
# message text is never used to decide (15.1).
api_ok() {
  [ "$VPS_API_HTTP" = 200 ] && jq -e "(.success == true) and (.obj | $1)" -- "$VPS_API_OUT" >/dev/null 2>&1
}

# api_read METHOD PATH JQ: a read, tried once more after a connection failure
# (15.3). Only for paths without a write side effect in the current state.
api_read() {
  api_call "$1" "$2" || api_call "$1" "$2" || return 1
  api_ok "$3"
}

# api_write METHOD PATH BODY CONTENT_TYPE JQ: a write, sent once (15.3).
# Returns 0 on success, 1 on a clear refusal, 2 when the result is unknown: no
# response, or a response that is neither a success nor a refusal.
api_write() {
  api_call "$1" "$2" "$3" "$4" || return 2
  if api_ok "$5"; then
    return 0
  fi
  if [ "$VPS_API_HTTP" = 200 ] && jq -e '.success == false' -- "$VPS_API_OUT" >/dev/null 2>&1; then
    return 1
  fi
  case "$VPS_API_HTTP" in
    4[0-9][0-9]) return 1 ;;
  esac
  return 2
}

# write_stop REASON: step 6 stops; says what is written (16.1).
write_stop() {
  local done='还没有写入业务配置'
  [ "${#VPS_DONE[@]}" -eq 0 ] || done="已写入：$(join_by '、' "${VPS_DONE[@]}")；其后的写入未执行"
  deploy_stop 6 "$1。$done。$VPS_CLEANUP_HINT"
}

# write_failed ITEM WHAT STATUS: report a write that did not succeed.
write_failed() {
  if [ "$3" -eq 1 ]; then
    report FAIL "$1" "$2被拒绝（HTTP $VPS_API_HTTP）"
    write_stop "$2被拒绝"
  fi
  report FAIL "$1" "$2的结果未知（HTTP $VPS_API_HTTP），可能已经写入"
  write_stop "$2的结果未知，可能已经写入，要在面板中核对"
}

# Step 5: before any business write (16.1, VT-15). What decides a refusal comes
# from the read-only snapshot of 4.1; POST /xray/, which can write, is not
# called on this path. Input and install result are kept on a refusal.
deploy_prewrite() {
  local before="$VPS_COUNT_FAIL" out n present
  if out="$(timeout --kill-after=5 10 "$VPS_XUI_BIN" -v 2>/dev/null)" && [ "$out" = "$VPS_PIN_XUI_VERSION" ]; then
    report PASS fresh.version "3X-UI $VPS_PIN_XUI_VERSION"
  else
    report FAIL fresh.version "$VPS_XUI_BIN -v 失败或不是 $VPS_PIN_XUI_VERSION"
  fi
  if ! xui_snapshot; then
    report FAIL fresh.db "无法读取数据库：$VPS_REASON"
    deploy_stop 5 "未写入业务配置；输入文件和安装结果保留。$VPS_CLEANUP_HINT"
  fi
  n="$(jq '.inbounds | length' <<<"$VPS_XUI_SNAPSHOT")"
  if [ "$n" = 0 ]; then
    report PASS fresh.inbounds '没有入站'
  else
    report FAIL fresh.inbounds "已有 $n 个入站"
  fi
  n="$(jq '.clients | length' <<<"$VPS_XUI_SNAPSHOT")"
  if [ "$n" = 0 ]; then
    report PASS fresh.clients '没有使用者'
  else
    report FAIL fresh.clients "已有 $n 个使用者"
  fi
  present="$(jq -r --arg keys "$VPS_WRITTEN_KEYS" \
    '($keys | split("\\s+"; null)) as $k | [(.settings // {}) | keys[] | select(IN($k[]))] | join(" ")' \
    <<<"$VPS_XUI_SNAPSHOT")"
  if [ -z "$present" ]; then
    report PASS fresh.settings '订阅设置和 Xray 模板仍是新装的默认值'
  else
    report FAIL fresh.settings "设置表中已有：$present"
  fi
  pf_target_checked
  [ "$VPS_COUNT_FAIL" -eq "$before" ] ||
    deploy_stop 5 "这台主机已有业务配置，或者 target 的核实结果失效；未写入业务配置，输入文件和安装结果保留。$VPS_CLEANUP_HINT"

  if install_result_read; then
    report PASS install.result '安装结果的格式符合预期'
  else
    report FAIL install.result "$VPS_REASON"
    deploy_stop 5 "未写入业务配置；输入文件和安装结果保留。$VPS_CLEANUP_HINT"
  fi
  # The fresh install has exactly one token: "install", enabled, admin.
  if ! api_read GET setting/apiTokens 'type == "array"'; then
    report FAIL api.token "无法用安装 token 列出 token（HTTP $VPS_API_HTTP）"
    deploy_stop 5 "未写入业务配置；输入文件和安装结果保留。$VPS_CLEANUP_HINT"
  fi
  VPS_TOKEN_ID="$(jq -r '.obj | if length == 1 and .[0].name == "install" and .[0].enabled == true
    and .[0].scope == "admin" and (.[0].id | type) == "number" then .[0].id else empty end' -- "$VPS_API_OUT")"
  if [ -z "$VPS_TOKEN_ID" ]; then
    report FAIL api.token "token 不是唯一一个启用的 admin 范围的 install（共 $(jq '.obj | length' -- "$VPS_API_OUT") 个）"
    deploy_stop 5 "未写入业务配置；输入文件和安装结果保留。$VPS_CLEANUP_HINT"
  fi
  report PASS api.token '安装 token 可用，是唯一一个 admin 范围的 token'
}

# new_short_id: 16 lowercase hex characters from OpenSSL's random source (15.1,
# requirements D28). The tests replace this function (VT-18).
new_short_id() {
  openssl rand -hex 8 2>/dev/null
}

# key_is_x25519 FIELD: the field of the key response is base64url for 32
# bytes. The key goes through pipes only.
key_is_x25519() {
  local n
  n="$(jq -r --arg f "$1" '.obj[$f]' -- "$VPS_TMP/x25519.json" | tr -d '\n' | tr '_-' '/+' |
    { IFS= read -r k || true; [[ "$k" =~ ^[A-Za-z0-9+/]{43}$ ]] && printf '%s=' "$k"; } | base64 -d 2>/dev/null | wc -c)"
  [ "$n" = 32 ]
}

# inbound_add ITEM WHAT BODY: create one inbound, then find it again in the
# list by the ID of the response and compare what was sent (15.1). Sets
# VPS_NEW_ID and VPS_NEW_TAG.
VPS_NEW_ID=''
VPS_NEW_TAG=''
inbound_add() {
  local item="$1" what="$2" body="$3" rc=0 id
  api_write POST inbounds/add "$body" application/json '(.id | type) == "number"' || rc=$?
  [ "$rc" -eq 0 ] || write_failed "$item" "创建$what" "$rc"
  id="$(jq '.obj.id' -- "$VPS_API_OUT")"
  if ! api_read GET inbounds/list 'type == "array"'; then
    report FAIL "$item" "创建$what之后无法读取入站（HTTP $VPS_API_HTTP）"
    VPS_DONE+=("$what（未核对）")
    write_stop "无法核对$what"
  fi
  if ! jq -e --argjson id "$id" --slurpfile want "$body" "$VPS_JQ_COVERS"'
    [.obj[] | select(.id == $id)] | length == 1 and (.[0].tag | type) == "string" and (.[0].tag != "")
      and (.[0] | covers($want[0] | del(.nodeId, .settings.clients)))' -- "$VPS_API_OUT" >/dev/null; then
    report FAIL "$item" "$what读回与请求不一致"
    VPS_DONE+=("$what（读回不一致）")
    write_stop "$what读回与请求不一致"
  fi
  VPS_NEW_ID="$id"
  VPS_NEW_TAG="$(jq -r --argjson id "$id" '.obj[] | select(.id == $id) | .tag' -- "$VPS_API_OUT")"
  VPS_DONE+=("$what")
}

# Step 6: the business configuration (16.1, 15.1, 17; 4.4 for FR-13). Each
# write is checked by reading it back; a failure stops with what is written
# so far, and nothing is undone (FR-12, VT-18).
deploy_write() {
  local target="${VPS_IN[target]}" sub_host="${VPS_IN[sub_host]}" ipv6="${VPS_IN[ipv6_ai_egress]}"
  local rc=0 sid email n

  # Reads first; after step 5 /xray/ reads without writing (14).
  if ! api_read POST setting/all 'type == "object"'; then
    report FAIL write.settings "无法读取设置（HTTP $VPS_API_HTTP）"
    write_stop '无法读取设置'
  fi
  install -m 0600 -- "$VPS_API_OUT" "$VPS_TMP/settings-read.json"
  if ! api_read POST xray/ 'type == "string" and (fromjson? | (.xraySetting | type) == "object"
      and (.outboundTestUrl | type) == "string")'; then
    report FAIL write.template "无法读取 Xray 模板（HTTP $VPS_API_HTTP）"
    write_stop '无法读取 Xray 模板'
  fi
  jq '.obj | fromjson' -- "$VPS_API_OUT" >"$VPS_TMP/template-read.json"
  # The default template of the fixed version (14): one direct freedom, one
  # blocked blackhole, AsIs; with FR-13 also no dns (4.2 routing.ai-ipv6).
  if ! jq -e --arg ipv6 "$ipv6" '.xraySetting
      | ([.outbounds[]? | select(.tag == "direct" and .protocol == "freedom")] | length == 1)
      and ([.outbounds[]? | select(.tag == "blocked" and .protocol == "blackhole")] | length == 1)
      and (.outbounds[0].tag == "direct")
      and ([.outbounds[]? | select(.tag == "'"$VPS_AI_TAG"'")] | length == 0)
      and ((.routing.domainStrategy // "AsIs") == "AsIs")
      and ((.routing.rules // []) | type == "array")
      and ($ipv6 == "off" or (has("dns") | not))' -- "$VPS_TMP/template-read.json" >/dev/null; then
    report FAIL write.template 'Xray 模板不是固定版本的默认模板'
    write_stop 'Xray 模板不是预期的默认模板'
  fi

  # Keys: the pair from the panel's Xray, the shortId here (15.1). Both stay in
  # the private directory and in memory.
  if ! api_read GET server/getNewX25519Cert '(.privateKey | type) == "string" and (.publicKey | type) == "string"'; then
    report FAIL keys.x25519 "无法生成 REALITY 密钥对（HTTP $VPS_API_HTTP）"
    write_stop '无法生成 REALITY 密钥对'
  fi
  install -m 0600 -- "$VPS_API_OUT" "$VPS_TMP/x25519.json"
  if ! key_is_x25519 privateKey || ! key_is_x25519 publicKey; then
    report FAIL keys.x25519 'REALITY 密钥对不是 32 字节的 base64url'
    write_stop 'REALITY 密钥对无效'
  fi
  report PASS keys.x25519 'REALITY 密钥对由面板生成'
  if ! sid="$(new_short_id)" || ! [[ "$sid" =~ ^[0-9a-f]{16}$ ]]; then
    report FAIL keys.short-id 'openssl rand -hex 8 失败，或输出不是 16 个小写十六进制字符'
    write_stop 'shortId 生成失败，REALITY 入站未创建'
  fi
  report PASS keys.short-id 'shortId 由 openssl rand -hex 8 生成'

  # Subscription settings: setting/update replaces every setting, so the
  # whole view goes back with only these keys changed (15.1, solution design
  # 7.5). subClashRules waits for the rule text (DO-9) and keeps its default.
  jq --arg dom "$sub_host" --argjson view "$VPS_VIEW_KEYS" '.obj | delpaths([$view[] | [.]])
    | .subEnable = true | .subListen = "127.0.0.1" | .subPort = '"$VPS_PORT_SUB"' | .subDomain = $dom
    | .subCertFile = "" | .subKeyFile = "" | .subClashEnable = true | .subClashEnableRouting = true
    | .subJsonEnable = false | .subInfoNodeEnable = false | .subUpdates = 12 | .remarkTemplate = "{{INBOUND}}"
    | .subURI = ("https://" + $dom + .subPath) | .subClashURI = ("https://" + $dom + .subClashPath)' \
    -- "$VPS_TMP/settings-read.json" >"$VPS_TMP/settings-write.json"
  api_write POST setting/update "$VPS_TMP/settings-write.json" application/json 'true' || rc=$?
  [ "$rc" -eq 0 ] || write_failed write.settings '写订阅设置' "$rc"
  if ! api_read POST setting/all 'type == "object"'; then
    report FAIL write.settings "写入后无法读取设置（HTTP $VPS_API_HTTP）"
    VPS_DONE+=('订阅设置（未核对）')
    write_stop '无法核对订阅设置'
  fi
  n="$(jq -r --argjson view "$VPS_VIEW_KEYS" --slurpfile want "$VPS_TMP/settings-write.json" '.obj
    | delpaths([$view[] | [.]]) as $got | [($want[0] | keys[]) as $k | select($got[$k] != $want[0][$k]) | $k]
      + [$got | keys[] | . as $k | select($want[0] | has($k) | not)] | join(" ")' -- "$VPS_API_OUT")"
  if [ -n "$n" ]; then
    report FAIL write.settings "读回与写入不一致的设置：$n"
    VPS_DONE+=('订阅设置（读回不一致）')
    write_stop '订阅设置读回与写入不一致'
  fi
  report PASS write.settings "订阅设置已写入并读回一致（订阅主机名 $sub_host，127.0.0.1:$VPS_PORT_SUB）"
  VPS_DONE+=('订阅设置')

  # The loopback forwarder, then REALITY (17).
  jq -n --arg remark "$VPS_FORWARDER_REMARK" '{enable: true, remark: $remark, listen: "127.0.0.1",
    port: '"$VPS_PORT_FORWARDER"', protocol: "tunnel", expiryTime: 0, total: 0, nodeId: null,
    settings: {rewriteAddress: "127.0.0.1", rewritePort: 443, allowedNetwork: "tcp", followRedirect: false},
    streamSettings: {network: "tcp", security: "none", tcpSettings: {acceptProxyProtocol: false,
      header: {type: "none"}}},
    sniffing: {enabled: true, destOverride: ["tls"], metadataOnly: false, routeOnly: false}}' \
    >"$VPS_TMP/forwarder.json"
  inbound_add write.forwarder 转发入站 "$VPS_TMP/forwarder.json"
  VPS_FWD_ID="$VPS_NEW_ID"
  VPS_FWD_TAG="$VPS_NEW_TAG"
  report PASS write.forwarder "转发入站已创建并读回一致（127.0.0.1:$VPS_PORT_FORWARDER，tag $VPS_FWD_TAG）"

  # The shortId reaches jq on stdin, the keys from the private file (8, 15.1).
  printf '%s' "$sid" | jq -Rs --slurpfile k "$VPS_TMP/x25519.json" --arg remark "${VPS_IN[remark]}" \
    --arg target "$target" --arg node "${VPS_IN[node_ip]}" '. as $sid | {enable: true, remark: $remark,
    listen: "", port: '"$VPS_PORT_REALITY"', protocol: "vless", expiryTime: 0, total: 0, nodeId: null,
    shareAddrStrategy: "custom", shareAddr: $node, excludeFromSub: false, disableFlow: false,
    settings: {clients: [], decryption: "none", encryption: "none"},
    streamSettings: {network: "tcp", security: "reality",
      tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}},
      realitySettings: {show: false, xver: 0, target: "127.0.0.1:'"$VPS_PORT_FORWARDER"'",
        serverNames: [$target], privateKey: $k[0].obj.privateKey, shortIds: [$sid],
        settings: {publicKey: $k[0].obj.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}}},
    sniffing: {enabled: false}}' >"$VPS_TMP/reality.json"
  sid=''
  inbound_add write.reality 'REALITY 入站' "$VPS_TMP/reality.json"
  VPS_REALITY_ID="$VPS_NEW_ID"
  VPS_REALITY_TAG="$VPS_NEW_TAG"
  report PASS write.reality "REALITY 入站已创建并读回一致（443，target $target，tag $VPS_REALITY_TAG）"

  deploy_write_template
  deploy_write_clients
}

# The routing of solution design 7.4 with the real tags, in front of the
# template's own rules; with FR-13 the outbound and rule of 4.4. Before that
# write, the panel's own Xray must load the FR-13 rule (16.1 step 6, 14).
deploy_write_template() {
  local target="${VPS_IN[target]}" ipv6="${VPS_IN[ipv6_ai_egress]}" rc=0
  jq --arg fwd "$VPS_FWD_TAG" --arg real "$VPS_REALITY_TAG" --arg target "$target" --arg ipv6 "$ipv6" \
    --arg ai "$VPS_AI_TAG" '.xraySetting
    | (.outbounds[] | select(.tag == "direct") | .settings.finalRules) as $final
    | .routing.rules = ([
        {type: "field", inboundTag: [$fwd], domain: ["full:" + $target], outboundTag: "direct"},
        {type: "field", inboundTag: [$fwd], outboundTag: "blocked"},
        {type: "field", inboundTag: [$real], domain: ["geosite:cn"], outboundTag: "blocked"},
        {type: "field", inboundTag: [$real], ip: ["geoip:cn"], outboundTag: "blocked"}]
      + (if $ipv6 == "on" then [{type: "field", inboundTag: [$real],
          domain: ["geosite:openai", "geosite:anthropic"], outboundTag: $ai}] else [] end)
      + (.routing.rules // []))
    | if $ipv6 == "on" then .outbounds += [{tag: $ai, protocol: "freedom", settings: {finalRules: $final},
        streamSettings: {sockopt: {domainStrategy: "ForceIPv6v4"}}}] else . end' \
    -- "$VPS_TMP/template-read.json" >"$VPS_TMP/template-write.json"

  if [ "$ipv6" = on ]; then
    jq --arg ai "$VPS_AI_TAG" '{log: {loglevel: "none"}, outbounds: [.outbounds[] | select(.tag == $ai)],
      routing: {rules: [.routing.rules[] | select(.outboundTag == $ai)]}}' \
      -- "$VPS_TMP/template-write.json" >"$VPS_TMP/ai-test.json"
    if XRAY_LOCATION_ASSET="$VPS_XUI_DIR/bin" timeout --kill-after=5 30 "$VPS_XUI_XRAY" run -test \
      -c "$VPS_TMP/ai-test.json" </dev/null >/dev/null 2>&1; then
      report PASS template.geosite '自带的 Xray 能加载 geosite:openai、geosite:anthropic 的规则'
    else
      report FAIL template.geosite '自带的 Xray 不能加载 geosite:openai、geosite:anthropic 的规则（geosite.dat 可能缺少类别）'
      write_stop 'FR-13 的规则无法加载，Xray 模板未写入'
    fi
  fi

  jq -rn --rawfile x "$VPS_TMP/template-write.json" --slurpfile r "$VPS_TMP/template-read.json" \
    '"xraySetting=" + ($x | rtrimstr("\n") | @uri) + "&outboundTestUrl=" + ($r[0].outboundTestUrl | @uri)' \
    >"$VPS_TMP/template-form"
  api_write POST xray/update "$VPS_TMP/template-form" application/x-www-form-urlencoded 'true' || rc=$?
  [ "$rc" -eq 0 ] || write_failed write.template '写 Xray 模板' "$rc"
  if ! api_read POST xray/ 'type == "string"' ||
    ! jq -e --slurpfile want "$VPS_TMP/template-write.json" --slurpfile r "$VPS_TMP/template-read.json" \
      '.obj | fromjson | .xraySetting == $want[0] and .outboundTestUrl == $r[0].outboundTestUrl' \
      -- "$VPS_API_OUT" >/dev/null 2>&1; then
    report FAIL write.template "Xray 模板读回与写入不一致（HTTP $VPS_API_HTTP）"
    VPS_DONE+=('Xray 模板（读回不一致）')
    write_stop 'Xray 模板读回与写入不一致'
  fi
  if [ "$ipv6" = on ]; then
    report PASS write.template "路由已写入并读回一致：方案设计第 7.4 节的四条规则和 FR-13 的第五条"
  else
    report PASS write.template '路由已写入并读回一致：方案设计第 7.4 节的四条规则'
  fi
  VPS_DONE+=('Xray 模板')
}

# One user at a time, each read back (15.1). The UUID and subscription ID come
# from the panel and must differ between users; they stay in the private
# directory for step 7.
deploy_write_clients() {
  local email rc emails=() n
  IFS=, read -r -a emails <<<"${VPS_IN[users]}"
  : >"$VPS_TMP/clients.jsonl"
  for email in "${emails[@]}"; do
    jq -n --arg email "$email" --argjson id "$VPS_REALITY_ID" '{client: {email: $email, enable: true,
      flow: "xtls-rprx-vision", limitIp: 0, totalGB: 0, expiryTime: 0, tgId: 0}, inboundIds: [$id]}' \
      >"$VPS_TMP/client.json"
    rc=0
    api_write POST clients/add "$VPS_TMP/client.json" application/json 'true' || rc=$?
    [ "$rc" -eq 0 ] || write_failed write.clients "创建使用者 $email" "$rc"
    if ! api_read GET "clients/get/$email" '(.client | type) == "object" and (.inboundIds | type) == "array"' ||
      ! jq -e --arg email "$email" --argjson id "$VPS_REALITY_ID" '.obj | .client.email == $email
        and .client.enable == true and .client.flow == "xtls-rprx-vision" and .inboundIds == [$id]
        and (.client.uuid | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
        and (.client.subId | type == "string" and length > 0)' -- "$VPS_API_OUT" >/dev/null 2>&1; then
      report FAIL write.clients "使用者 $email 读回与请求不一致（HTTP $VPS_API_HTTP）"
      VPS_DONE+=("使用者 $email（读回不一致）")
      write_stop "使用者 $email 读回与请求不一致"
    fi
    jq -c '{email: .obj.client.email, uuid: .obj.client.uuid, subId: .obj.client.subId}' -- "$VPS_API_OUT" \
      >>"$VPS_TMP/clients.jsonl"
    VPS_DONE+=("使用者 $email")
  done
  n="${#emails[@]}"
  if ! jq -se --argjson n "$n" 'length == $n and (map(.uuid) | unique | length) == $n
      and (map(.subId) | unique | length) == $n' -- "$VPS_TMP/clients.jsonl" >/dev/null; then
    report FAIL write.clients '使用者的 UUID 或订阅 ID 有重复'
    write_stop '使用者的 UUID 或订阅 ID 有重复'
  fi
  report PASS write.clients "$n 个使用者已创建并读回一致：${VPS_IN[users]}"
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

  deploy_step 5 '写入前核对'
  deploy_prewrite

  deploy_step 6 '写入业务配置'
  deploy_write

  printf '\n[x] 第 1～6 步完成：业务配置已写入并读回一致。第 7 步起尚未实现（M2 开发中）：面板未重启，订阅仍按旧设置监听，安装 token 未撤销；输入文件和安装结果保留\n' >&2
  exit "$VPS_EXIT_FAIL"
}
