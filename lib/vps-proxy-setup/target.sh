# shellcheck shell=bash
# target-check (detailed design 2.7, 5): checks a candidate REALITY target from
# this VPS and publishes the result for the preflight item target.checked.
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

readonly VPS_PROBE_HOST_DEFAULT=vps-proxy-setup-probe.invalid
readonly VPS_TLS_TIMEOUT=15
readonly VPS_TLS_ATTEMPTS=5
readonly VPS_BODY_MAX=4194304
# The check items of a complete record, in output order.
readonly VPS_TARGET_ITEMS=(root deps resolve tls.handshake tls.version tls.alpn tls.cert tls.group \
  http.root probe.host probe.authority)
readonly VPS_TARGET_RECORD_KEYS=(format version time target probe_host summary result)
readonly VPS_TARGET_MAX_AGE=$((7 * 24 * 3600))

# Results of the record kept for the file, as "check.ID=LEVEL" lines.
VPS_TC_LINES=()

tc_report() {
  local level="$1" id="$2"
  report "$@"
  VPS_TC_LINES+=("check.$id=$level")
}

tc_skip_rest() {
  local reason="$1" id
  shift
  for id in "$@"; do
    tc_report SKIP "$id" "$reason"
  done
}

# tls_probe HOST: one TLS handshake to HOST:443 with SNI HOST, offering h2 and
# http/1.1 and X25519MLKEM768 first. Prints openssl's output; returns its status.
tls_probe() {
  timeout --kill-after=2 "$VPS_TLS_TIMEOUT" openssl s_client -connect "$1:443" -servername "$1" \
    -verify_hostname "$1" -alpn h2,http/1.1 -groups X25519MLKEM768:X25519:secp256r1:secp384r1 \
    -showcerts </dev/null 2>&1
}

now_ms() {
  local ns
  ns="$(date +%s%N)"
  printf '%d\n' $((ns / 1000000))
}

# http_fetch PROTO HOST_HEADER OUT_PREFIX: GET https://TARGET/ without following
# redirects. Writes at most VPS_BODY_MAX bytes of the body to OUT_PREFIX.body
# and prints "STATUS SHA256 REDIRECT_URL" (redirect may be empty). Returns 1
# when curl fails, and 2 when PROTO is h2 but the response came over another
# version: --http2 falls back to HTTP/1.1 when ALPN does not select h2.
http_fetch() {
  local proto="$1" host="$2" out="$3" meta status rest version redirect hash rc=0
  # head stops the transfer at VPS_BODY_MAX (detailed design 5) and curl then
  # ends with 23, a write error. The status goes to stderr, which carries
  # nothing else without --show-error. --noproxy keeps these requests direct,
  # like the TLS probe, when https_proxy is inherited. -q, which must come
  # first, skips .curlrc: a "location" there would follow the redirects.
  local -a opts=(-q --silent --noproxy '*' --max-time "$VPS_TLS_TIMEOUT" --connect-timeout "$VPS_TLS_TIMEOUT"
    --proto '=https' --output - --write-out '%{stderr}%{http_code} %{http_version} %{redirect_url}')
  if [ "$proto" = h2 ]; then
    opts+=(--http2)
  else
    opts+=(--http1.1)
  fi
  [ "$VPS_TC_INSECURE" -eq 0 ] || opts+=(--insecure)
  [ "$host" = "$VPS_TC_TARGET" ] || opts+=(--header "Host: $host")
  curl "${opts[@]}" "https://$VPS_TC_TARGET/" 2>"$out.meta" | head -c "$VPS_BODY_MAX" >"$out.body" || rc=$?
  case "$rc" in
    0) ;;
    23) [ "$(wc -c <"$out.body")" -eq "$VPS_BODY_MAX" ] || return 1 ;;
    *) return 1 ;;
  esac
  meta="$(<"$out.meta")"
  status="${meta%% *}"
  rest="${meta#* }"
  version="${rest%% *}"
  redirect="${rest#* }"
  [ "$redirect" != "$rest" ] || redirect=''
  [ "$proto" != h2 ] || [ "$version" = 2 ] || return 2
  hash="$(sha256sum <"$out.body")" || return 1
  printf '%s %s %s\n' "$status" "${hash%% *}" "$redirect"
}

# url_host URL: the lower-case host of an absolute http(s) URL.
url_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest%%\?*}"
  rest="${rest##*@}"
  rest="${rest%:*}"
  printf '%s\n' "${rest,,}"
}

# A gate stop is a result, not an interruption, so it clears the exit note.
tc_check_root_deps() {
  local cmd missing=()
  if [ "$(id -u)" -ne 0 ]; then
    tc_report FAIL root '必须以 root 运行'
    VPS_EXIT_NOTE=''
    stop_at_gate
  fi
  tc_report PASS root '以 root 运行'
  for cmd in curl openssl getent sha256sum timeout; do
    have "$cmd" || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    tc_report FAIL deps "缺少命令：$(join_by ' ' "${missing[@]}")；请安装 curl openssl libc-bin coreutils"
    VPS_EXIT_NOTE=''
    stop_at_gate
  fi
  tc_report PASS deps '依赖的命令齐全'
}

# fetch_failed STATUS WHAT: the reason, from http_fetch's STATUS, that the
# request WHAT gave no usable response.
fetch_failed() {
  if [ "$1" -eq 2 ]; then
    printf '%s没有协商到 HTTP/2（curl 改用了别的版本）' "$2"
  else
    printf '%s失败' "$2"
  fi
}

# probe_judge ID PROTO: the cross-authority probe of detailed design 5.
probe_judge() {
  local id="$1" proto="$2" base1 base2 probe rc=0
  local s1 h1 s2 h2 sp hp
  local clean='只能发现交叉路由，结果干净不证明隔离'
  base1="$(http_fetch "$proto" "$VPS_TC_TARGET" "$VPS_TMP/$id.base1")" &&
    base2="$(http_fetch "$proto" "$VPS_TC_TARGET" "$VPS_TMP/$id.base2")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    tc_report WARN "$id" "$(fetch_failed "$rc" '以目标为 Host 的基准请求')，无法比较"
    return 0
  fi
  probe="$(http_fetch "$proto" "$VPS_TC_PROBE" "$VPS_TMP/$id.probe")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    tc_report WARN "$id" "$(fetch_failed "$rc" "探测请求（Host 为 $VPS_TC_PROBE）")，无法判定"
    return 0
  fi
  read -r s1 h1 _ <<<"$base1"
  read -r s2 h2 _ <<<"$base2"
  read -r sp hp _ <<<"$probe"
  if [[ "$sp" != 2?? ]]; then
    tc_report PASS "$id" "探测请求返回 $sp；$clean"
  elif [ "$hp" = "$h1" ] || [ "$hp" = "$h2" ]; then
    tc_report PASS "$id" "探测请求返回 $sp，内容与基准相同；$clean"
  elif [ "$h1" = "$h2" ]; then
    tc_report FAIL "$id" "按 Host 返回了别的内容（探测 $sp，基准 $s1），可能交叉路由"
  else
    tc_report WARN "$id" "探测请求返回 $sp，但两次基准的内容不同（动态页面），无法按内容比较"
  fi
}

# Publish the record: a temporary file in the same directory, then a rename,
# so a reader sees the old or the new record and never a partial one.
tc_publish() {
  local tmp line result=PASS
  [ "$VPS_COUNT_FAIL" -eq 0 ] || result=FAIL
  # Each failure below says itself that nothing was published.
  if ! { [ -d "$VPS_ETC_DIR" ] || mkdir -m 0700 -- "$VPS_ETC_DIR"; } 2>/dev/null ||
    ! { [ -d "$VPS_TARGET_DIR" ] || mkdir -m 0700 -- "$VPS_TARGET_DIR"; } 2>/dev/null; then
    VPS_EXIT_NOTE=''
    printf '[x] 无法创建 %s，结果未发布\n' "$VPS_TARGET_DIR" >&2
    return 1
  fi
  tmp="$(mktemp -- "$VPS_TARGET_DIR/.$VPS_TC_TARGET.XXXXXXXX" 2>/dev/null)" || {
    VPS_EXIT_NOTE=''
    printf '[x] 无法在 %s 中写入，结果未发布\n' "$VPS_TARGET_DIR" >&2
    return 1
  }
  VPS_CLEANUP+=("$tmp")
  # From here the exit note depends on whether the rename below has happened.
  VPS_EXIT_NOTE_TMP="$tmp"
  if ! {
    {
      printf 'format=1\nversion=%s\ntime=%s\ntarget=%s\nprobe_host=%s\n' \
        "$VPS_VERSION" "$VPS_TC_TIME" "$VPS_TC_TARGET" "$VPS_TC_PROBE"
      for line in "${VPS_TC_LINES[@]}"; do
        printf '%s\n' "$line"
      done
      printf 'summary=pass:%d fail:%d warn:%d skip:%d\nresult=%s\n' \
        "$VPS_COUNT_PASS" "$VPS_COUNT_FAIL" "$VPS_COUNT_WARN" "$VPS_COUNT_SKIP" "$result"
    } >"$tmp" 2>/dev/null && chmod 0600 -- "$tmp" 2>/dev/null &&
      mv -f -- "$tmp" "$VPS_TARGET_DIR/$VPS_TC_TARGET" 2>/dev/null
  }; then
    VPS_EXIT_NOTE=''
    printf '[x] 写入 %s 失败，结果未发布\n' "$VPS_TARGET_DIR/$VPS_TC_TARGET" >&2
    return 1
  fi
  printf '\n结果已写入 %s\n' "$VPS_TARGET_DIR/$VPS_TC_TARGET"
}

cmd_target_check() {
  local arg resolved addrs out ms list sorted min med max status ok=0 first='' version alpn verify
  local cert issuer enddate group root redirect rest fetch_rc
  local -a times=() addr_list=()
  VPS_TC_TARGET=''
  VPS_TC_PROBE="$VPS_PROBE_HOST_DEFAULT"
  VPS_TC_INSECURE=0
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --probe-host=*)
        shift
        set -- --probe-host "${arg#*=}" "$@"
        continue
        ;;
      --probe-host)
        [ "$#" -ge 2 ] || usage_error '--probe-host 缺少取值'
        VPS_TC_PROBE="$2"
        shift 2
        ;;
      -*) usage_error "未知参数：$arg" ;;
      *)
        [ -z "$VPS_TC_TARGET" ] || usage_error "多余的参数：$arg"
        VPS_TC_TARGET="$arg"
        shift
        ;;
    esac
  done
  [ -n "$VPS_TC_TARGET" ] || usage_error 'target-check 缺少主机名'
  hostname_reason "$VPS_TC_TARGET" 2 || usage_error "主机名不合法：$VPS_REASON"
  hostname_reason "$VPS_TC_PROBE" 2 || usage_error "--probe-host 不合法：$VPS_REASON"
  [ "$VPS_TC_PROBE" != "$VPS_TC_TARGET" ] || usage_error '--probe-host 不能与目标相同'

  # From the end of the argument checks until the record is renamed into
  # place, an internal error or a signal leaves the old record, and the exit
  # says so (detailed design 2.7).
  VPS_EXIT_NOTE="[x] target-check 中途结束，结果未发布；$VPS_TARGET_DIR/$VPS_TC_TARGET 本次未更新"
  tc_check_root_deps
  vps_tmp_init
  VPS_TC_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  resolved="$(getent ahosts -- "$VPS_TC_TARGET" 2>/dev/null)" || resolved=''
  addrs="$(awk '!seen[$1]++ { print $1 }' <<<"$resolved")"
  if [ -z "$addrs" ]; then
    tc_report FAIL resolve "解析不到 $VPS_TC_TARGET 的地址"
    tc_skip_rest '解析失败' tls.handshake tls.version tls.alpn tls.cert tls.group http.root probe.host probe.authority
  else
    mapfile -t addr_list <<<"$addrs"
    tc_report INFO resolve "地址：$(join_by ' ' "${addr_list[@]}")；是否在共享 CDN 上、是否与本机同一网络，按文档查询网络归属"
    for _ in $(seq "$VPS_TLS_ATTEMPTS"); do
      ms="$(now_ms)"
      if out="$(tls_probe "$VPS_TC_TARGET")" && [[ "$out" == *$'\nNew, TLS'* || "$out" == 'New, TLS'* ]]; then
        times+=($(($(now_ms) - ms)))
        ok=$((ok + 1))
        [ -n "$first" ] || first="$out"
      fi
    done
    if [ "$ok" -eq 0 ]; then
      tc_report FAIL tls.handshake "$VPS_TLS_ATTEMPTS 次 TLS 握手全部失败"
      tc_skip_rest '握手失败' tls.version tls.alpn tls.cert tls.group http.root probe.host probe.authority
    else
      sorted="$(printf '%s\n' "${times[@]}" | sort -n)"
      min="$(head -n 1 <<<"$sorted")"
      max="$(tail -n 1 <<<"$sorted")"
      med="$(sed -n "$(((ok + 1) / 2))p" <<<"$sorted")"
      list="握手耗时最小 ${min} ms，中位数 ${med} ms，最大 ${max} ms"
      if [ "$ok" -lt "$VPS_TLS_ATTEMPTS" ]; then
        tc_report WARN tls.handshake "$VPS_TLS_ATTEMPTS 次中 $ok 次成功；$list"
      else
        tc_report PASS tls.handshake "$VPS_TLS_ATTEMPTS 次都成功；$list"
      fi

      # sed quits at the first match itself: head closing the pipe early could
      # kill sed with SIGPIPE under pipefail (detailed design 8).
      version="$(sed -n 's/^New, \(TLSv[0-9.]*\), Cipher is .*/\1/p;T;q' <<<"$first")"
      if [ "$version" = TLSv1.3 ]; then
        tc_report PASS tls.version 'TLS 1.3'
      else
        tc_report FAIL tls.version "协商的是 ${version:-未知}，不是 TLS 1.3"
      fi
      alpn="$(sed -n 's/^ALPN protocol: //p;T;q' <<<"$first")"
      if [ "$alpn" = h2 ]; then
        tc_report PASS tls.alpn '提供 h2,http/1.1 时协商到 h2'
      else
        tc_report FAIL tls.alpn "提供 h2,http/1.1 时协商到的不是 h2（${alpn:-没有协商 ALPN}）"
      fi
      verify="$(sed -n 's/^ *Verify return code: //p' <<<"$first" | tail -n 1)"
      cert="$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p;/-----END CERTIFICATE-----/q' <<<"$first")"
      issuer="$(openssl x509 -noout -issuer <<<"$cert" 2>/dev/null)" || issuer=''
      enddate="$(openssl x509 -noout -enddate <<<"$cert" 2>/dev/null)" || enddate=''
      issuer="${issuer#issuer=}"
      enddate="${enddate#notAfter=}"
      if [ "${verify%% *}" = 0 ]; then
        tc_report PASS tls.cert "证书链和主机名有效；签发者 ${issuer:-未知}，到期 ${enddate:-未知}"
      else
        VPS_TC_INSECURE=1
        tc_report FAIL tls.cert "证书无效（${verify:-没有验证结果}）；签发者 ${issuer:-未知}，到期 ${enddate:-未知}"
      fi
      group="$(sed -n 's/^Negotiated TLS1\.3 group: //p;T;q' <<<"$first")"
      [ -n "$group" ] || group="$(sed -n 's/^\(Server\|Peer\) Temp Key: \([^,]*\).*/\2/p;T;q' <<<"$first")"
      tc_report INFO tls.group "提供 X25519MLKEM768 时协商到 ${group:-未知}（不判定）"

      fetch_rc=0
      root="$(http_fetch h2 "$VPS_TC_TARGET" "$VPS_TMP/root")" || fetch_rc=$?
      if [ "$fetch_rc" -eq 0 ]; then
        read -r status _ redirect <<<"$root"
        case "$status" in
          2??) tc_report PASS http.root "/ 返回 $status" ;;
          3??)
            if [ -z "$redirect" ]; then
              tc_report WARN http.root "/ 返回 $status，但没有跳转地址"
            elif [ "$(url_host "$redirect")" = "$VPS_TC_TARGET" ]; then
              rest="${redirect#*://}"
              rest="/${rest#*/}"
              [ "$rest" != "/${redirect#*://}" ] || rest=/
              tc_report PASS http.root "/ 返回 $status，跳转到同一主机名的 $rest"
            else
              tc_report FAIL http.root "/ 返回 $status，跳转到别的主机名 $(url_host "$redirect")"
            fi
            ;;
          *) tc_report WARN http.root "/ 返回 $status" ;;
        esac
      else
        tc_report WARN http.root "$(fetch_failed "$fetch_rc" '经 h2 请求 / ')"
      fi
      probe_judge probe.host http1.1
      probe_judge probe.authority h2
    fi
  fi

  if tc_publish; then
    finish_checks
  fi
  report_summary
  exit "$VPS_EXIT_FAIL"
}

# target_record_check FILE TARGET: whether FILE is a valid record (detailed
# design 2.7). Sets VPS_TR_STATE to "pass", "fail" or "invalid", with
# VPS_TR_REASON, VPS_TR_AGE (seconds) and VPS_TR_WARNS (item IDs with WARN).
VPS_TR_STATE=''
VPS_TR_REASON=''
VPS_TR_AGE=0
VPS_TR_WARNS=''
target_record_check() {
  local file="$1" target="$2" attrs line key value id level when now
  local pass=0 fail=0 warn=0 skip=0
  local -A rec=() items=()
  VPS_TR_STATE=invalid
  VPS_TR_WARNS=''
  VPS_TR_AGE=0
  if [ -L "$file" ] || [ ! -e "$file" ]; then
    VPS_TR_REASON='没有核实结果'
    return 0
  fi
  attrs="$(file_attrs "$file")" || attrs=''
  if [ "$attrs" != 'regular file|0|600' ]; then
    VPS_TR_REASON='结果文件不是属于 root、权限 0600 的普通文件'
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *)
        VPS_TR_REASON='结果文件格式不可识别'
        return 0
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      check.*)
        id="${key#check.}"
        if [ -n "${items[$id]+set}" ]; then
          VPS_TR_REASON="结果文件中检查项 $id 重复"
          return 0
        fi
        items[$id]="$value"
        ;;
      *)
        if [ -n "${rec[$key]+set}" ]; then
          VPS_TR_REASON="结果文件中 $key 重复"
          return 0
        fi
        rec[$key]="$value"
        ;;
    esac
  done <"$file"
  for key in "${VPS_TARGET_RECORD_KEYS[@]}"; do
    if [ -z "${rec[$key]+set}" ]; then
      VPS_TR_REASON="结果文件缺少 $key（可能被截断）"
      return 0
    fi
  done
  if [ "${rec[format]}" != 1 ]; then
    VPS_TR_REASON='结果文件的格式未知'
    return 0
  fi
  if [ "${rec[target]}" != "$target" ]; then
    VPS_TR_REASON='结果文件中的目标与输入不一致'
    return 0
  fi
  when="$(date -u -d "${rec[time]}" +%s 2>/dev/null)" || when=''
  now="$(date -u +%s)"
  if ! is_uint "$when" || ! [[ "${rec[time]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    [ "$when" -gt "$now" ]; then
    VPS_TR_REASON='结果文件的时间无效或晚于本机当前时间'
    return 0
  fi
  for id in "${VPS_TARGET_ITEMS[@]}"; do
    level="${items[$id]-}"
    case "$level" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      WARN)
        warn=$((warn + 1))
        VPS_TR_WARNS+="${VPS_TR_WARNS:+ }$id"
        ;;
      SKIP) skip=$((skip + 1)) ;;
      INFO) ;;
      *)
        VPS_TR_REASON="结果文件缺少检查项 $id"
        return 0
        ;;
    esac
  done
  if [ "${#items[@]}" -ne "${#VPS_TARGET_ITEMS[@]}" ]; then
    VPS_TR_REASON='结果文件中有未知的检查项'
    return 0
  fi
  if [ "${rec[summary]}" != "pass:$pass fail:$fail warn:$warn skip:$skip" ]; then
    VPS_TR_REASON='结果文件的汇总与检查项不一致'
    return 0
  fi
  VPS_TR_AGE=$((now - when))
  if [ "${rec[result]}" = PASS ] && [ "$fail" -eq 0 ]; then
    VPS_TR_STATE=pass
  elif [ "${rec[result]}" = FAIL ] && [ "$fail" -gt 0 ]; then
    VPS_TR_STATE=fail
    VPS_TR_REASON='核实结果不通过'
  else
    VPS_TR_REASON='结果文件的结论与检查项不一致'
  fi
}
