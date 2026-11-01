# shellcheck shell=bash
# Deploy inputs (detailed design 2.4): the input file, interactive reading and
# the validation of each value. Every input is validated before any host check;
# a bad value ends deploy with VPS_EXIT_USAGE and its value is never echoed.
# target-check reuses hostname_reason.
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

# In the order of the table in detailed design 2.4, which is also the order of
# the interactive prompts.
readonly VPS_INPUT_KEYS=(sub_host node_ip target remark users ipv6_ai_egress tunnel_token)
readonly VPS_INPUT_MAX_BYTES=65536
readonly VPS_MAX_USERS=8

declare -A VPS_IN=()
VPS_IN_FILE=''
VPS_IN_MIGRATE=0
# Reason set by the *_reason validators when they return 1.
VPS_REASON=''

# Address blocks node_ip may not be in, and the documentation blocks it may be
# in with a preflight warning (detailed design 2.4, verification plan 3.3).
readonly VPS_IPV4_REJECTED=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
  172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4)
readonly VPS_IPV4_DOCUMENTATION=(192.0.2.0/24 198.51.100.0/24 203.0.113.0/24)

# Last bytes of the UTF-8 encodings of the regional indicators U+1F1E6..U+1F1FF,
# which all start with F0 9F 87 (detailed design 8).
readonly VPS_RI_PREFIX=$'\xf0\x9f\x87'
readonly VPS_RI_LAST=$'\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'

input_label() {
  case "$1" in
    sub_host) printf '订阅主机名' ;;
    node_ip) printf '节点的公网 IPv4' ;;
    target) printf 'REALITY 的 target 主机名' ;;
    remark) printf '入站备注（以国旗开头）' ;;
    users) printf '使用者代号（逗号分隔）' ;;
    ipv6_ai_egress) printf 'AI 服务经 IPv6 出站（on 或 off）' ;;
    tunnel_token) printf 'Cloudflare Tunnel 的令牌（不回显）' ;;
  esac
}

# Keys deploy --migrate does not accept: migration writes no settings (FR-09).
input_key_allowed() {
  local key="$1" k
  if [ "$VPS_IN_MIGRATE" -eq 1 ]; then
    case "$key" in remark | users) return 1 ;; esac
  fi
  for k in "${VPS_INPUT_KEYS[@]}"; do
    [ "$k" != "$key" ] || return 0
  done
  return 1
}

input_file_error() {
  printf '[x] 输入文件：%s\n' "$*" >&2
  exit "$VPS_EXIT_USAGE"
}

parse_deploy_args() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --input=*)
        shift
        set -- --input "${arg#*=}" "$@"
        continue
        ;;
      --input)
        [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--input 缺少取值'
        [ -z "$VPS_IN_FILE" ] || usage_error '--input 只能给一次'
        VPS_IN_FILE="$2"
        shift 2
        ;;
      --migrate)
        VPS_IN_MIGRATE=1
        shift
        ;;
      *)
        usage_error "未知参数：$arg"
        ;;
    esac
  done
}

# The commands input validation needs. They are checked again by deps after
# the inputs, but without them the inputs cannot be judged at all.
require_input_tools() {
  local cmd missing=()
  for cmd in base64 jq iconv stat; do
    have "$cmd" || missing+=("$cmd")
  done
  [ "${#missing[@]}" -eq 0 ] ||
    refuse "缺少命令 $(join_by ' ' "${missing[@]}")，无法校验输入；请先安装 coreutils jq libc-bin"
}

# read_input_file FILE: parse the file into VPS_IN (detailed design 2.4). The
# file is opened once; its attributes are checked on the open descriptor and
# the content is read from that descriptor, so it cannot be swapped between
# the check and the read. The content may hold the Tunnel token, so it stays
# in variables: no temporary files, no here-strings (detailed design 8).
read_input_file() {
  local file="$1" fd attrs link_attrs content size n=0 line rest key value errors=0
  local -a st
  local -A seen=()
  [ ! -L "$file" ] || input_file_error '不能是符号链接'
  [ -e "$file" ] || input_file_error '不存在'
  # Checked again on the descriptor below. This check only keeps the open from
  # waiting for the writer of a FIFO while the deploy lock is held; it does not
  # close the window for a replacement, which the descriptor checks catch.
  [ -f "$file" ] || input_file_error '不是普通文件'
  # exec without a command keeps all of its redirections; the group limits
  # 2>/dev/null to the open, or every later message would be lost.
  { exec {fd}<"$file"; } 2>/dev/null || input_file_error '无法打开'
  # /proc/$$/fd names the descriptor of this shell; -L follows it to the open file.
  attrs="$(stat -L -c '%d:%i|%F|%u|%a|%s' "/proc/$$/fd/$fd" 2>/dev/null)" ||
    input_file_error '无法读取属性'
  link_attrs="$(stat -c '%d:%i|%F' -- "$file" 2>/dev/null)" || link_attrs=''
  IFS='|' read -r -a st <<<"$attrs"
  [ "$link_attrs" = "${st[0]}|${st[1]}" ] || input_file_error '在打开前后被替换，或不是普通文件'
  [ "${st[1]}" = 'regular file' ] || input_file_error '不是普通文件'
  [ "${st[2]}" = 0 ] || input_file_error '必须属于 root'
  [ "${st[3]}" = 600 ] || input_file_error "权限必须是 0600，现在是 0${st[3]}"
  size="${st[4]}"
  [ "$size" -le "$VPS_INPUT_MAX_BYTES" ] || input_file_error '超过 64 KiB'
  # Bash drops NUL bytes from command substitution with a warning; the length
  # check below finds them, so the warning is not shown.
  { content="$(cat <&"$fd" && printf x)"; } 2>/dev/null || input_file_error '读取失败'
  exec {fd}<&-
  content="${content%x}"
  [ "${#content}" -eq "$size" ] || input_file_error '含 NUL 字节，或在读取时被改动'
  case "$content" in
    *$'\r'*) input_file_error '含 CR（CRLF 换行的文件不接受）' ;;
  esac
  printf '%s' "$content" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 ||
    input_file_error '不是合法的 UTF-8'

  rest="$content"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$rest" ]; then
      rest=''
    else
      rest="${rest#*$'\n'}"
    fi
    n=$((n + 1))
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *)
        printf '[x] 输入文件：第 %d 行不是 键=值\n' "$n" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if ! input_key_allowed "$key"; then
      # A line holding only a token parses as an unknown key: name the key only
      # when it cannot be a secret.
      if [[ "$key" =~ ^(remark|users)$ ]]; then
        printf '[x] 输入 %s：迁移不写设置，不接受这一项；请确认用的是迁移的输入文件\n' "$key" >&2
      elif [[ "$key" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        printf '[x] 输入文件：第 %d 行的键 %s 未知\n' "$n" "$key" >&2
      else
        printf '[x] 输入文件：第 %d 行的键未知\n' "$n" >&2
      fi
      errors=$((errors + 1))
      continue
    fi
    if [ -n "${seen[$key]-}" ]; then
      printf '[x] 输入 %s：在第 %s、%d 行重复\n' "$key" "${seen[$key]}" "$n" >&2
      errors=$((errors + 1))
      continue
    fi
    seen[$key]="$n"
    VPS_IN[$key]="$value"
  done
  [ "$errors" -eq 0 ] || exit "$VPS_EXIT_USAGE"
}

# Ask for every input the file did not give. Prompts go to stderr.
read_missing_inputs() {
  local key value
  for key in "${VPS_INPUT_KEYS[@]}"; do
    input_key_allowed "$key" || continue
    [ -z "${VPS_IN[$key]+set}" ] || continue
    value=''
    printf '%s：' "$(input_label "$key")" >&2
    if [ "$key" = tunnel_token ]; then
      IFS= read -rs value || value=''
      printf '\n' >&2
    else
      IFS= read -r value || value=''
    fi
    VPS_IN[$key]="$value"
  done
}

# hostname_reason NAME MIN_LABELS: lower-case host name (detailed design 2.4).
hostname_reason() {
  local name="$1" min="$2" rest label count=0
  if [ -z "$name" ]; then
    VPS_REASON='为空'
    return 1
  fi
  if [ "${#name}" -gt 253 ]; then
    VPS_REASON='超过 253 个字符'
    return 1
  fi
  if ! [[ "$name" =~ ^[a-z0-9.-]+$ ]]; then
    VPS_REASON='只能包含小写字母、数字、连字符和点'
    return 1
  fi
  case "$name" in
    *.)
      VPS_REASON='不能以点结尾'
      return 1
      ;;
  esac
  rest="$name"
  while :; do
    label="${rest%%.*}"
    count=$((count + 1))
    if [ -z "$label" ] || [ "${#label}" -gt 63 ]; then
      VPS_REASON='每一段须为 1～63 个字符'
      return 1
    fi
    case "$label" in
      -* | *-)
        VPS_REASON='每一段不能以连字符开头或结尾'
        return 1
        ;;
    esac
    [ "$label" != "$rest" ] || break
    rest="${rest#*.}"
  done
  if [ "$count" -lt "$min" ]; then
    VPS_REASON="至少需要 $min 段"
    return 1
  fi
  # A numeric last label covers every IPv4 literal form, and no top-level
  # domain is numeric.
  if [[ "$label" =~ ^[0-9]+$ ]]; then
    VPS_REASON='不能是 IP 地址'
    return 1
  fi
  return 0
}

# ipv4_to_int ADDR: dotted decimal already checked by ipv4_reason.
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%d' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# ipv4_in ADDR CIDR...: ADDR is in one of the blocks.
ipv4_in() {
  local addr cidr net bits mask
  addr="$(ipv4_to_int "$1")"
  shift
  for cidr in "$@"; do
    net="$(ipv4_to_int "${cidr%/*}")"
    bits="${cidr#*/}"
    mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
    [ $((addr & mask)) -ne $((net & mask)) ] || return 0
  done
  return 1
}

ipv4_reason() {
  local octet
  if ! [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
    VPS_REASON='不是点分十进制的 IPv4 地址（每段不带前导零）'
    return 1
  fi
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    if [ "$octet" -gt 255 ]; then
      VPS_REASON='每一段须为 0～255'
      return 1
    fi
  done
  if ipv4_in "$1" "${VPS_IPV4_REJECTED[@]}"; then
    VPS_REASON='是保留、私有、共享、回环、链路本地或组播地址，不能作为节点的公网地址'
    return 1
  fi
  return 0
}

ipv4_is_documentation() {
  ipv4_in "$1" "${VPS_IPV4_DOCUMENTATION[@]}"
}

ri_last_byte() {
  [ "${#1}" -eq 1 ] && [[ "$VPS_RI_LAST" == *"$1"* ]]
}

remark_reason() {
  local v="$1"
  if [ -z "$v" ]; then
    VPS_REASON='为空'
    return 1
  fi
  if ! printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    VPS_REASON='不是合法的 UTF-8'
    return 1
  fi
  if [ "${#v}" -gt 64 ]; then
    VPS_REASON='超过 64 字节'
    return 1
  fi
  case "$v" in
    *[[:cntrl:]]*)
      VPS_REASON='含控制字符'
      return 1
      ;;
    ' '* | *' ')
      VPS_REASON='首尾不能是空格'
      return 1
      ;;
  esac
  if [ "${v:0:3}" != "$VPS_RI_PREFIX" ] || [ "${v:4:3}" != "$VPS_RI_PREFIX" ] ||
    ! ri_last_byte "${v:3:1}" || ! ri_last_byte "${v:7:1}"; then
    VPS_REASON='须以国旗（两个区域指示符）开头，例如 🇺🇸 LA-Reality'
    return 1
  fi
  return 0
}

users_reason() {
  local rest="$1," item count=0 codes=' '
  if [ -z "$1" ]; then
    VPS_REASON='为空'
    return 1
  fi
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    rest="${rest#*,}"
    count=$((count + 1))
    if ! [[ "$item" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
      VPS_REASON="第 $count 个代号不合规：须为 1～32 个小写字母、数字、下划线或连字符，以字母或数字开头"
      return 1
    fi
    case "$codes" in
      *" $item "*)
        VPS_REASON="代号 $item 重复"
        return 1
        ;;
    esac
    codes+="$item "
  done
  if [ "$count" -gt "$VPS_MAX_USERS" ]; then
    VPS_REASON="最多 $VPS_MAX_USERS 个，现在是 $count 个"
    return 1
  fi
  return 0
}

# The token format of cloudflared 2026.10.5 (detailed design 2.4, 14). The
# program prints one verdict; the decoded token reaches jq only on stdin.
readonly VPS_TOKEN_JQ='
  if length != 1 or (.[0] | type) != "object" then "object"
  else .[0] |
    if (.a | type) != "string" or (.a | length) == 0 then "a"
    elif (.t | type) != "string" or (.t | test("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$") | not) then "t"
    elif (.s | type) != "string" or (.s | test("^[A-Za-z0-9+/]+={0,2}$") | not) or (.s | length) % 4 != 0 then "s"
    elif ((.s | length) / 4 * 3 - (if (.s | endswith("==")) then 2 elif (.s | endswith("=")) then 1 else 0 end)) < 32 then "s-short"
    else "ok" end
  end'

token_reason() {
  local tok="$1" verdict
  if [ -z "$tok" ]; then
    VPS_REASON='为空'
    return 1
  fi
  if ! [[ "$tok" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || [ $((${#tok} % 4)) -ne 0 ]; then
    VPS_REASON='不是标准 Base64'
    return 1
  fi
  verdict="$(printf '%s' "$tok" | base64 -d 2>/dev/null | jq -rs "$VPS_TOKEN_JQ" 2>/dev/null)" ||
    verdict=object
  case "$verdict" in
    ok) return 0 ;;
    a) VPS_REASON='解码后的 a 不是非空字符串' ;;
    t) VPS_REASON='解码后的 t 不是 UUID 格式' ;;
    s) VPS_REASON='解码后的 s 不是标准 Base64' ;;
    s-short) VPS_REASON='解码后的 s 不足 32 字节' ;;
    *) VPS_REASON='解码后不是 JSON 对象' ;;
  esac
  return 1
}

# validate_inputs: one line per bad key, then VPS_EXIT_USAGE. No host check
# has run yet (detailed design 2.4).
validate_inputs() {
  local key errors=0 ok
  for key in "${VPS_INPUT_KEYS[@]}"; do
    input_key_allowed "$key" || continue
    ok=1
    case "$key" in
      sub_host) hostname_reason "${VPS_IN[$key]}" 3 || ok=0 ;;
      node_ip) ipv4_reason "${VPS_IN[$key]}" || ok=0 ;;
      target)
        if ! hostname_reason "${VPS_IN[$key]}" 2; then
          ok=0
        elif [ "${VPS_IN[target]}" = "${VPS_IN[sub_host]}" ]; then
          VPS_REASON='不能与订阅主机名相同'
          ok=0
        fi
        ;;
      remark) remark_reason "${VPS_IN[$key]}" || ok=0 ;;
      users) users_reason "${VPS_IN[$key]}" || ok=0 ;;
      ipv6_ai_egress)
        case "${VPS_IN[$key]}" in
          on | off) ;;
          *)
            VPS_REASON='须为 on 或 off'
            ok=0
            ;;
        esac
        ;;
      tunnel_token) token_reason "${VPS_IN[$key]}" || ok=0 ;;
    esac
    if [ "$ok" -eq 0 ]; then
      printf '[x] 输入 %s：%s\n' "$key" "$VPS_REASON" >&2
      errors=$((errors + 1))
    fi
  done
  [ "$errors" -eq 0 ] || exit "$VPS_EXIT_USAGE"
}

load_deploy_inputs() {
  require_input_tools
  if [ -n "$VPS_IN_FILE" ]; then
    read_input_file "$VPS_IN_FILE"
  fi
  read_missing_inputs
  validate_inputs
}
