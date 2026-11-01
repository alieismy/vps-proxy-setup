# shellcheck shell=bash
# check (detailed design 2.6, 4): read-only checks of 3X-UI, the subscription,
# the listening ports, cloudflared and the hardening. It takes no lock and
# writes no file; snapshots and responses stay in variables.
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

readonly VPS_CHECK_DEPS=(sqlite3 jq curl ss ip systemctl sha256sum od timeout)
readonly VPS_RECORD_KEYS=(tool_version xui_version cloudflared_version mode deployed_at sub_host \
  node_ip target target_check_time ipv6_ai_egress)
readonly VPS_CF_CERT_DIRS=(/root/.cloudflared /root/.cloudflare-warp /root/cloudflare-warp \
  /etc/cloudflared /usr/local/etc/cloudflared)
readonly VPS_RULES_FILE_NAME=clash-rules.yaml
readonly VPS_CFD_UNIT_NAME=vps-proxy-setup-cloudflared.service

# Judgements of the database items on one snapshot (detailed design 4.2).
# Output: an object from item ID to [LEVEL, MESSAGE], plus "_panel" and
# "_fwd_port" for the items that also need ss.
# shellcheck disable=SC2016 # a jq program; the $names are jq variables
readonly VPS_CHECK_JQ='
def v($l; $m): [$l, $m];
def verdict($bad; $ok): if ($bad | length) == 0 then v("PASS"; $ok) else v("FAIL"; $bad | join("；")) end;
def bool_of: if type == "string" and IN("1","t","T","TRUE","true","True") then true
  elif type == "string" and IN("0","f","F","FALSE","false","False") then false else null end;
def int_of: if type == "string" and test("^[+-]?[0-9]+$") then tonumber else null end;
def hostname_ok($min): type == "string" and length <= 253
  and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")
  and ((split(".") | length) >= $min) and ((split(".") | last | test("^[0-9]+$")) | not);
def ipv4_ok: type == "string"
  and test("^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$");
def ip_literal: ipv4_ok or (type == "string" and contains(":") and test("^[0-9A-Fa-f:.]+$"));
def norm_rule: if type != "object" then null
  else (if has("type") then (if .type == "field" then del(.type) else . + {"__type": .type} end) else . end)
     | (if has("enabled") and .enabled == true then del(.enabled) else . end) end;

($snap.settings // {}) as $set |
def raw($k): ($set[$k] // {"n": 0});
def sval($k): raw($k) as $r | if $r.n == 0 then $defaults[$k] else $r.v end;
def bval($k): raw($k) as $r | (if $r.n == 0 or $r.v == "" then $defaults[$k] else $r.v end) | bool_of;
def ival($k): raw($k) as $r | (if $r.n == 0 or $r.v == "" then $defaults[$k] else $r.v end) | int_of;
def flag($k; $want; $ok): bval($k) as $b
  | if $b == null then v("FAIL"; "\($k) 的值无效") elif $b == $want then v("PASS"; $ok)
    else v("FAIL"; "\($k) 不是 \($want)") end;

$snap.inbounds as $inb |
([ $inb[] | select(.protocol == "vless" and .port == 443) ] | if length == 1 then .[0] else null end) as $r |
([ $inb[] | select(.protocol == "tunnel") ] | if length == 1 then .[0] else null end) as $f |
$snap.template as $t |
(if $t.n == 0 then $default_outbounds else ($t.outbounds // []) end) as $obs |
(if $t.n > 0 and $t.valid == 1 and ($t.rules | type) == "array" then $t.rules else [] end) as $rules_all |
([ $rules_all[] | select((type == "object" and .enabled == false) | not) ]) as $rules |
"没有 REALITY 入站（由 inbounds.set 报告）" as $no_r |
"没有转发入站（由 inbounds.set 报告）" as $no_f |
($r.r_serverNames[0]? // null) as $sni |

{
"_panel": {"listen": sval("webListen"), "port": ival("webPort")},
"_fwd_port": ($f.port // null),
"_sub_domain": (sval("subDomain") | if hostname_ok(2) then . else "" end),

"inbounds.set":
  ((($inb | length) == 2
    and ([ $inb[] | select(.protocol == "vless" and .port == 443 and .listen == "" and .enable == 1 and .node_id == null) ] | length) == 1
    and ([ $inb[] | select(.protocol == "tunnel" and .listen == "127.0.0.1" and .enable == 1 and .node_id == null) ] | length) == 1) as $ok
  | if $ok then v("PASS"; "REALITY 入站（vless/443，所有地址）和转发入站（tunnel，127.0.0.1）各一个，都已启用")
    elif ($inb | length) == 0 then v("FAIL"; "没有入站")
    else v("FAIL"; "入站不符合：\($inb | map("\(.protocol)/\(.port)") | join("，"))") end),

"reality.settings":
  (if $r == null then v("SKIP"; $no_r) elif $f == null then v("SKIP"; $no_f)
   else ("127.0.0.1:\($f.port)") as $want | verdict([
     (if $r.stream_valid != 1 then "streamSettings 不是有效的 JSON" else empty end),
     (if $r.network != "tcp" then "network 不是 tcp" else empty end),
     (if $r.security != "reality" then "security 不是 reality" else empty end),
     (if ($r.r_target_t != null) == ($r.r_dest_t != null) then "target 和 dest 须恰有一个"
      elif (($r.r_target // $r.r_dest) != $want) then "target 不是 \($want)" else empty end),
     (if ($r.r_serverNames | type) != "array" or ($r.r_serverNames | length) != 1
        or ($r.r_serverNames[0] | hostname_ok(2) | not) then "serverNames 须正好一项合法的主机名" else empty end),
     (if $r.r_sid_count != 1 or $r.r_sid0_t != "text" or $r.r_sid0_len < 2 or $r.r_sid0_len > 16
        or ($r.r_sid0_len % 2) != 0 or $r.r_sid0_hex != 1 then "shortIds 须正好一项 2～16 位、长度为偶数的十六进制" else empty end),
     (if $r.r_pk_nonempty != 1 then "私钥为空" else empty end),
     (if $r.r_fingerprint != "chrome" then "settings.fingerprint 不是 chrome" else empty end),
     (if $r.r_xver != null and $r.r_xver != 0 then "xver 不是 0" else empty end),
     (if $r.decryption != "none" then "decryption 不是 none" else empty end),
     (if $r.disable_flow != 0 then "disable_flow 不是 0" else empty end)
   ]; "REALITY 设置符合方案设计第 7.4 节") end),

"reality.share":
  (if $r == null then v("SKIP"; $no_r) else verdict([
     (if $r.share_addr_strategy != "custom" then "share_addr_strategy 不是 custom" else empty end),
     (if ($r.share_addr | ipv4_ok | not) then "share_addr 不是 IPv4 字面量" else empty end),
     (if $r.exclude_from_sub != 0 then "exclude_from_sub 不是 0" else empty end)
   ]; "订阅中的节点地址是 IPv4 字面量 \($r.share_addr)") end),

"reality.hosts":
  (if $r == null then v("SKIP"; $no_r)
   else [ $snap.hosts[] | select(.inbound_id == $r.id and .disabled == 0) ] as $hs
   | [ $hs[] | select((.address | ip_literal | not) or .mihomo_x25519 == 1) ] as $bad
   | if ($bad | length) == 0 then v("PASS"; "未停用的主机 \($hs | length) 个，没有不合规的")
     else v("FAIL"; "未停用的主机中有 \($bad | length) 个地址不是 IP 字面量或打开了 mihomo_x25519") end end),

"forwarder.settings":
  (if $f == null then v("SKIP"; $no_f) elif $r == null then v("SKIP"; $no_r)
   else (($r.r_target // $r.r_dest // "") | tostring | split(":") | last | tonumber? // null) as $tp
   | verdict([
     (if $tp == null or $f.port != $tp then "端口不等于 REALITY target 中的端口" else empty end),
     (if $f.settings_valid != 1 then "settings 不是有效的 JSON" else empty end),
     (if ($f.address_t != null) == ($f.rewriteAddress_t != null) then "rewriteAddress 和旧名 address 须恰有一个"
      elif (($f.rewriteAddress // $f.address) != "127.0.0.1") then "rewriteAddress 不是 127.0.0.1" else empty end),
     (if ($f.port_t != null) == ($f.rewritePort_t != null) then "rewritePort 和旧名 port 须恰有一个"
      elif (($f.rewritePort // $f.port_v) != 443) then "rewritePort 不是 443" else empty end),
     (if $f.network_t != null and $f.allowedNetwork_t != null then "allowedNetwork 和旧名 network 至多一个"
      elif (($f.allowedNetwork // $f.network_v // "tcp") != "tcp") then "allowedNetwork 不是 tcp" else empty end),
     (if ($f.followRedirect // false) != false then "followRedirect 不是假" else empty end),
     (if $f.sniff_valid != 1 or $f.sniff_enabled != true then "sniffing 未启用" else empty end),
     (if $f.sniff_dest != ["tls"] then "destOverride 不是 [\"tls\"]" else empty end),
     (if ($f.sniff_routeOnly // false) != false or ($f.sniff_metadataOnly // false) != false
      then "routeOnly 或 metadataOnly 不是假" else empty end),
     (if ($f.security // "none") != "none" then "转发入站有传输层安全" else empty end)
   ]; "转发入站只在嗅探到 TLS 时改写到 127.0.0.1:443") end),

"routing.rules":
  (if $r == null then v("SKIP"; $no_r) elif $f == null then v("SKIP"; $no_f)
   elif $t.n == 0 then v("FAIL"; "设置表中没有 xrayTemplateConfig（模板仍是默认值）")
   elif $t.valid != 1 then v("FAIL"; "xrayTemplateConfig 不是有效的 JSON")
   elif $t.domainStrategy_type != null and $t.domainStrategy != "AsIs" then v("FAIL"; "routing.domainStrategy 不是 AsIs")
   elif ($t.rules | type) != "array" then v("FAIL"; "模板中没有 routing.rules")
   else [ {"inboundTag": [$f.tag], "domain": ["full:\($sni)"], "outboundTag": "direct"},
          {"inboundTag": [$f.tag], "outboundTag": "blocked"},
          {"inboundTag": [$r.tag], "domain": ["geosite:cn"], "outboundTag": "blocked"},
          {"inboundTag": [$r.tag], "ip": ["geoip:cn"], "outboundTag": "blocked"} ] as $want
   | [ range(0; 4) as $i | select(($rules[$i] | norm_rule) != $want[$i]) | $i + 1 | tostring ] as $bad
   | if ($bad | length) == 0 then v("PASS"; "前四条规则依次是方案设计第 7.4 节的规则 1～4")
     else v("FAIL"; "第 \($bad | join("、")) 条规则不是方案设计第 7.4 节的对应规则") end end),

"routing.outbounds":
  (if $t.n > 0 and $t.valid != 1 then v("FAIL"; "xrayTemplateConfig 不是有效的 JSON")
   elif $t.n > 0 and $t.outbounds_type != "array" then v("FAIL"; "模板中没有 outbounds 数组")
   else ([ $obs[] | select(.tag == "direct" and .protocol == "freedom") ] | length) as $d
   | ([ $obs[] | select(.tag == "blocked" and .protocol == "blackhole") ] | length) as $b
   | if $d == 1 and $b == 1 then v("PASS"; "direct（freedom）和 blocked（blackhole）各一个\(if $t.n == 0 then "（默认模板）" else "" end)")
     else v("FAIL"; "direct（freedom）有 \($d) 个、blocked（blackhole）有 \($b) 个，须各一个") end end),

"routing.ai-ipv6":
  (if $rec == null or (($rec.ipv6_ai_egress // "") | IN("on", "off") | not)
   then v("SKIP"; "部署记录缺失或 ipv6_ai_egress 无效（由 record.consistent 报告）")
   else [ $obs[] | select(.tag == "ai-ipv6") ] as $ai
   | [ $rules_all[] | select(.outboundTag? == "ai-ipv6") ] as $air
   | if $rec.ipv6_ai_egress == "off" then
       (if ($ai | length) > 0 or ($air | length) > 0 then v("FAIL"; "未启用 FR-13，模板中却有 ai-ipv6 出站或指向它的规则")
        else v("SKIP"; "未启用 FR-13（ipv6_ai_egress=off）") end)
     elif $r == null then v("SKIP"; $no_r)
     elif $t.n > 0 and $t.valid != 1 then v("FAIL"; "xrayTemplateConfig 不是有效的 JSON")
     else ([ $obs[] | select(.tag == "direct") ][0].finalRules) as $dfr
     | ($rules[4] | norm_rule) as $r5
     | verdict([
       (if ($ai | length) != 1 then "标签为 ai-ipv6 的出站不正好一个"
        else $ai[0] as $o
        | (if $o.keys != ["protocol", "settings", "streamSettings", "tag"] then "ai-ipv6 出站的字段不是 tag、protocol、settings、streamSettings" else empty end),
          (if $o.protocol != "freedom" then "ai-ipv6 出站的协议不是 freedom" else empty end),
          (if $o.settings_keys != ["finalRules"] or $o.finalRules != $dfr then "ai-ipv6 出站的 settings 不是只有与 direct 相同的 finalRules" else empty end),
          (if $o.streamSettings != {"sockopt": {"domainStrategy": "ForceIPv6v4"}} then "ai-ipv6 出站的 streamSettings 不是只有 sockopt.domainStrategy=ForceIPv6v4" else empty end)
        end),
       (if ($obs[0].tag // null) != "direct" then "第一个出站不是 direct" else empty end),
       (if ($r5 | type) != "object" or ($r5 | del(.domain)) != {"inboundTag": [$r.tag], "outboundTag": "ai-ipv6"}
          or ($r5.domain | type) != "array" or ($r5.domain | sort) != ["geosite:anthropic", "geosite:openai"]
        then "第五条规则不是 REALITY 入站的 geosite:openai、geosite:anthropic 到 ai-ipv6" else empty end),
       (if ([ $rules[] | select(.outboundTag? == "ai-ipv6") ] | length) > 1 then "还有别的规则指向 ai-ipv6" else empty end),
       (if $t.has_dns == 1 then "模板中有 dns" else empty end)
     ]; "ai-ipv6 出站和第五条规则符合详细设计第 4.4 节（只核对配置，不核对私有地址屏蔽的内容）") end end),

"clients.count":
  (if $r == null then v("SKIP"; $no_r)
   else [ $snap.links[] | select(.inbound_id == $r.id) | .email ] as $codes
   | [ $snap.clients[] | select(.email | IN($codes[])) ] as $cl
   | if ($cl | length) == 0 then v("WARN"; "没有关联到 REALITY 入站的使用者")
     else v("INFO"; "使用者 \($cl | length) 个：\($cl | map(.email + (if .enable == 1 then "" else "（停用）" end)) | join("、"))") end end),

"clients.flow":
  (if $r == null then v("SKIP"; $no_r)
   else [ $snap.links[] | select(.inbound_id == $r.id) | . as $l
          | ($snap.clients[] | select(.email == $l.email)) as $c
          | select($c.flow != "xtls-rprx-vision" or (($l.flow_override // "") | IN("", "xtls-rprx-vision") | not))
          | $l.email ] | unique as $bad
   | if ($bad | length) == 0 then v("PASS"; "关联的使用者的 flow 都是 xtls-rprx-vision")
     else v("FAIL"; "flow 不是 xtls-rprx-vision：\($bad | join("、"))") end end),

"clients.limit-ip":
  ([ $snap.clients[] | select(.limit_ip != 0) | .email ] as $bad
   | if ($bad | length) > 0 then v("FAIL"; "IP Limit 不为 0：\($bad | join("、"))")
     elif ($snap.clients | length) == 0 then v("PASS"; "没有使用者")
     else v("PASS"; "使用者的 IP Limit 都是 0") end),

"sub.enable": flag("subEnable"; true; "订阅服务已启用"),
"sub.listen":
  (if sval("subListen") == "127.0.0.1" and ival("subPort") == 2096 then v("PASS"; "订阅只监听 127.0.0.1:2096")
   else v("FAIL"; "订阅监听的不是 127.0.0.1:2096（subListen \(sval("subListen") | if . == "" then "为空，即所有地址" else . end)，subPort \(ival("subPort") // "无效")）") end),
"sub.cert":
  (if sval("subCertFile") == "" and sval("subKeyFile") == "" then v("PASS"; "订阅不挂证书（HTTPS 由 Cloudflare 边缘提供）")
   else v("FAIL"; "subCertFile 或 subKeyFile 不为空") end),
"sub.domain":
  (if (sval("subDomain") | hostname_ok(2)) then v("PASS"; "订阅主机名 \(sval("subDomain"))")
   else v("FAIL"; "subDomain 为空或不是合法的主机名") end),
"sub.uri":
  (if $snap.sub.uri_ok == 1 and $snap.sub.clash_uri_ok == 1 then v("PASS"; "subURI、subClashURI 是 https:// 加订阅主机名加路径")
   else v("FAIL"; "subURI 或 subClashURI 不等于 https:// 加 subDomain 加对应的路径") end),
"sub.paths":
  ($snap.sub as $s | verdict([
     (if $s.path_default == 1 then "subPath 是默认值" elif $s.path_len < 16 then "subPath 两个斜杠之间少于 16 个字符" else empty end),
     (if $s.clash_path_default == 1 then "subClashPath 是默认值" elif $s.clash_path_len < 16 then "subClashPath 两个斜杠之间少于 16 个字符" else empty end)
   ]; "订阅路径不是默认值，长度不少于 16 个字符（不证明是随机生成的）")),
"sub.clash":
  ([ bval("subClashEnable"), bval("subClashEnableRouting") ] as $b
   | if $b == [true, true] then v("PASS"; "Clash 订阅及其路由规则已启用")
     else v("FAIL"; "subClashEnable 或 subClashEnableRouting 不为真") end),
"sub.rules":
  (if $rules_hex == null then v("SKIP"; "还没有规则文本（M2）")
   elif ($snap.rules_hex // "") == $rules_hex then v("PASS"; "subClashRules 与发布的规则文本逐字节相同")
   else v("FAIL"; "subClashRules 与发布的规则文本不同") end),
"sub.json": flag("subJsonEnable"; false; "JSON 订阅未启用"),
"sub.info-node": flag("subInfoNodeEnable"; false; "订阅信息节点未启用"),
"sub.updates":
  (if ival("subUpdates") == 12 then v("PASS"; "订阅更新间隔 12 小时")
   else v("FAIL"; "subUpdates 不是 12") end),
"sub.remark":
  (if sval("remarkTemplate") == "{{INBOUND}}" then v("PASS"; "remarkTemplate 是 {{INBOUND}}")
   else v("FAIL"; "remarkTemplate 不是 {{INBOUND}}") end),

"secrets.api-tokens":
  (($snap.api_tokens // []) as $tok
   | if ($tok | length) == 0 then v("PASS"; "没有启用的 API token")
     else v("WARN"; "启用的 API token \($tok | length) 个：\($tok | join("、"))") end),

"record.consistent":
  (if $rec == null then null
   elif $r == null then v("SKIP"; $no_r)
   else verdict([
     (if sval("subDomain") != $rec.sub_host then "sub_host 与 subDomain 不一致" else empty end),
     (if $sni != $rec.target then "target 与 serverNames 不一致" else empty end),
     (if $r.share_addr != $rec.node_ip then "node_ip 与 share_addr 不一致" else empty end)
   ]; "部署记录与数据库一致") end)
}'

# Settings defaults of 3X-UI v3.11.0 for the keys above (detailed design 4.1;
# internal/web/service/setting.go at the fixed commit).
readonly VPS_XUI_DEFAULTS='{"webListen":"","webPort":"2053","subEnable":"true","subListen":"",
"subPort":"2096","subDomain":"","subCertFile":"","subKeyFile":"","subClashEnable":"false",
"subClashEnableRouting":"false","subJsonEnable":"false","subInfoNodeEnable":"false","subUpdates":"12",
"remarkTemplate":"{{INBOUND}}-{{EMAIL}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D"}'
# The outbounds of the default template (internal/web/service/config.json at
# the fixed commit), in the shape of the snapshot.
readonly VPS_XUI_DEFAULT_OUTBOUNDS='[{"tag":"direct","protocol":"freedom",
"keys":["protocol","settings","tag"],"settings_keys":["finalRules"],
"finalRules":[{"action":"block","ip":["geoip:private"]},{"action":"allow"}],"streamSettings":null},
{"tag":"blocked","protocol":"blackhole","keys":null,"settings_keys":null,"finalRules":null,"streamSettings":null}]'

# Parsed deploy record as JSON, or nothing; VPS_REASON says why.
VPS_RECORD_JSON=''
read_deploy_record() {
  local line key value args=() k
  local -A rec=()
  VPS_RECORD_JSON=''
  if [ -L "$VPS_DEPLOY_CONF" ] || [ ! -f "$VPS_DEPLOY_CONF" ]; then
    VPS_REASON="没有 $VPS_DEPLOY_CONF"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *)
        VPS_REASON='部署记录中有不是 键=值 的行'
        return 1
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if [ -n "${rec[$key]+set}" ]; then
      VPS_REASON="部署记录中 $key 重复"
      return 1
    fi
    rec[$key]="$value"
  done <"$VPS_DEPLOY_CONF"
  for k in "${VPS_RECORD_KEYS[@]}"; do
    if [ -z "${rec[$k]+set}" ]; then
      VPS_REASON="部署记录缺少 $k"
      return 1
    fi
    args+=(--arg "$k" "${rec[$k]}")
  done
  VPS_RECORD_JSON="$(jq -cn "${args[@]}" '$ARGS.named')"
}

ck_xui_program() {
  local out i path want got bad=() pending=()
  if out="$(timeout --kill-after=5 10 "$VPS_XUI_BIN" -v 2>/dev/null)" && [ "$out" = "$VPS_PIN_XUI_VERSION" ]; then
    report PASS xui.version "3X-UI $VPS_PIN_XUI_VERSION"
    VPS_XUI_VERSION_OK=1
  elif [ ! -e "$VPS_XUI_BIN" ]; then
    report FAIL xui.version "没有 $VPS_XUI_BIN"
  else
    report FAIL xui.version "$VPS_XUI_BIN -v 失败或不是 $VPS_PIN_XUI_VERSION"
  fi

  for i in "${!VPS_PIN_XUI_FILES[@]}"; do
    path="${VPS_PIN_XUI_FILES[$i]}"
    want="${VPS_PIN_XUI_SHA256[$i]}"
    got="$(file_sha256 "$path")" || got=''
    if [ -z "$got" ]; then
      bad+=("$path（不存在或不可读）")
    elif [ -z "$want" ]; then
      pending+=("$path")
    elif [ "$got" != "$want" ]; then
      bad+=("$path")
    fi
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    report FAIL xui.files "与固定的摘要不符：$(join_by ' ' "${bad[@]}")"
  elif [ "${#pending[@]}" -gt 0 ]; then
    report FAIL xui.files "还没有固定的摘要（验证计划 VO-1）：$(join_by ' ' "${pending[@]}")"
  else
    report PASS xui.files '程序文件与固定的摘要一致'
  fi
}

ck_xui_unit() {
  local out line exec='' execs=0 wd='' env='' envfiles='' user='' bad=()
  if ! out="$(bounded systemctl show -p ExecStart -p WorkingDirectory -p Environment \
    -p EnvironmentFiles -p User -- x-ui.service 2>/dev/null)"; then
    report FAIL xui.unit '无法读取 x-ui.service 的属性'
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      ExecStart=*)
        exec="${line#*=}"
        execs=$((execs + 1))
        ;;
      WorkingDirectory=*) wd="${line#*=}" ;;
      Environment=*) env="${line#*=}" ;;
      EnvironmentFiles=*) envfiles="${line#*=}" ;;
      User=*) user="${line#*=}" ;;
    esac
  done <<<"$out"
  # One command with no arguments; systemctl prints "{ path=... ; argv[]=... ; ... }"
  # for each command. The exact format is confirmed in M1 (DO-2).
  if [ "$execs" -ne 1 ] || [[ "$exec" != "{ path=$VPS_XUI_BIN ; argv[]=$VPS_XUI_BIN ; "* ]] ||
    [[ "${exec#*\{}" == *'{'* ]]; then
    bad+=('ExecStart')
  fi
  [ "${wd%/}" = "$VPS_XUI_DIR" ] || bad+=('WorkingDirectory')
  [ "$env" = 'XRAY_VMESS_AEAD_FORCED=false' ] || bad+=('Environment')
  [ "$envfiles" = '/etc/default/x-ui (ignore_errors=yes)' ] || bad+=('EnvironmentFiles')
  [ -z "$user" ] || [ "$user" = root ] || bad+=('User')
  if [ "${#bad[@]}" -eq 0 ]; then
    report PASS xui.unit 'x-ui.service 的生效属性符合固定版本'
  else
    report FAIL xui.unit "x-ui.service 的生效属性不符：$(join_by ' ' "${bad[@]}")"
  fi
}

ck_xui_env_service_ipl() {
  local path found=() enabled active out jails file note=''
  for path in "${VPS_XUI_ENV_FILES[@]}"; do
    [ ! -e "$path" ] || found+=("$path")
  done
  if [ "${#found[@]}" -eq 0 ]; then
    report PASS xui.env '没有 3X-UI 的环境文件'
  else
    report FAIL xui.env "有环境文件：$(join_by ' ' "${found[@]}")；它可以改变数据库和程序的位置"
  fi

  enabled="$(bounded systemctl is-enabled -- x-ui.service 2>/dev/null)" || true
  active="$(bounded systemctl is-active -- x-ui.service 2>/dev/null)" || true
  if [ "$enabled" = enabled ] && [ "$active" = active ]; then
    report PASS xui.service 'x-ui.service 已启用，正在运行'
  else
    report FAIL xui.service "x-ui.service 是 ${enabled:-未知}、${active:-未知}"
  fi

  found=()
  for file in filter.d/3x-ipl.conf action.d/3x-ipl.conf jail.d/3x-ipl.conf; do
    [ ! -e "/etc/fail2ban/$file" ] || found+=("/etc/fail2ban/$file")
  done
  if have fail2ban-client && out="$(bounded fail2ban-client status 2>/dev/null)"; then
    jails="$(sed -n 's/.*Jail list:[[:space:]]*//p' <<<"$out")"
    if [[ ", $jails, " == *', 3x-ipl, '* ]]; then
      found+=('jail 3x-ipl')
    fi
  else
    note='（fail2ban 没有运行，只按文件判定）'
  fi
  if [ "${#found[@]}" -eq 0 ]; then
    report PASS xui.ipl "没有 3X-UI 的 IP Limit$note"
  else
    report FAIL xui.ipl "IP Limit 已启用：$(join_by ' ' "${found[@]}")$note"
  fi
}

# Database items as SKIP when the snapshot is unusable (FR-07, VT-73).
VPS_DB_ITEMS=(panel.listen inbounds.set reality.settings reality.share reality.hosts forwarder.settings \
  routing.rules routing.outbounds routing.ai-ipv6 clients.count clients.flow clients.limit-ip \
  sub.enable sub.listen sub.cert sub.domain sub.uri sub.paths sub.clash sub.rules sub.json sub.info-node \
  sub.updates sub.remark)

# db_verdict ID: print the verdict of a database item from VPS_VERDICTS.
db_verdict() {
  local level message
  level="$(jq -r --arg id "$1" '.[$id][0] // empty' <<<"$VPS_VERDICTS")"
  message="$(jq -r --arg id "$1" '.[$id][1] // empty' <<<"$VPS_VERDICTS")"
  [ -n "$level" ] || internal_error "数据库检查项 $1 没有结果"
  report "$level" "$1" "$message"
}

ck_panel_listen() {
  local listen port hport state
  listen="$(jq -r '._panel.listen // ""' <<<"$VPS_VERDICTS")"
  port="$(jq -r '._panel.port // ""' <<<"$VPS_VERDICTS")"
  hport="$(hardening_state_get panel_port)" || hport=''
  if ! is_port "$hport"; then
    report FAIL panel.listen '加固记录中没有有效的面板端口'
  elif [ "$listen" != 127.0.0.1 ]; then
    report FAIL panel.listen "webListen 不是 127.0.0.1"
  elif [ "$port" != "$hport" ]; then
    report FAIL panel.listen "webPort ${port:-无效} 不等于加固记录的面板端口 $hport"
  elif ! state="$(port_state "$hport")"; then
    report FAIL panel.listen '无法读取监听端口（ss）'
  elif [ "$state" = loopback ]; then
    report PASS panel.listen "面板只监听回环地址的 $hport"
  elif [ "$state" = none ]; then
    report FAIL panel.listen "面板端口 $hport 没有监听"
  else
    report FAIL panel.listen "面板端口 $hport 在回环地址之外也有监听"
  fi
}

# loopback_item ID PORT WHAT: the port listens, and only on loopback.
loopback_item() {
  local state
  if ! state="$(port_state "$2")"; then
    report FAIL "$1" '无法读取监听端口（ss）'
  elif [ "$state" = loopback ]; then
    report PASS "$1" "$3 $2 只监听回环地址"
  elif [ "$state" = none ]; then
    report FAIL "$1" "$3 $2 没有监听"
  else
    report FAIL "$1" "$3 $2 在回环地址之外也有监听"
  fi
}

# ss lines for one address family, as "ADDRESS PORT EXTRA" for port 443.
reality_listeners() {
  local out line local_addr addr port
  out="$(bounded ss -Hltne "$1" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r _ _ _ local_addr _ <<<"$line"
    port="${local_addr##*:}"
    [ "$port" = "$VPS_PORT_REALITY" ] || continue
    addr="${local_addr%:*}"
    addr="${addr#[}"
    addr="${addr%]}"
    printf '%s %s\n' "$addr" "$line"
  done <<<"$out"
}

# listen.reality (detailed design 4.2, 4.4): IPv4 is accepted by an IPv4
# wildcard socket, or by an IPv6 wildcard socket with v6only=0; a host with a
# public IPv6 address also needs the IPv6 wildcard. ss output is confirmed in M2 (DO-2).
ck_listen_reality() {
  local v4 v6 facts usable v4ok=0 v6wild=0 v6only='' line families=IPv4
  if ! v4="$(reality_listeners -4)" || ! v6="$(reality_listeners -6)"; then
    report FAIL listen.reality '无法按地址族读取监听端口（ss）'
    return 0
  fi
  while IFS= read -r line; do
    case "${line%% *}" in 0.0.0.0 | '*') v4ok=1 ;; esac
  done <<<"$v4"
  while IFS= read -r line; do
    case "${line%% *}" in
      :: | '*')
        v6wild=1
        case "$line" in
          *v6only:0*) v6only=0 ;;
          *v6only:1*) v6only=1 ;;
        esac
        ;;
    esac
  done <<<"$v6"
  if [ "$v4ok" -eq 0 ] && [ "$v6wild" -eq 1 ]; then
    if [ "$v6only" = 0 ]; then
      v4ok=1
    elif [ -z "$v6only" ]; then
      report FAIL listen.reality '443 只有 IPv6 通配监听，无法确认 v6only，无法确认能接收 IPv4'
      return 0
    fi
  fi
  if ! facts="$(ipv6_egress_facts)"; then
    report FAIL listen.reality '无法读取本机的 IPv6 地址'
    return 0
  fi
  read -r usable _ _ <<<"$facts"
  if [ "$v4ok" -eq 0 ]; then
    report FAIL listen.reality '443/tcp 没有可接受 IPv4 的通配监听'
  elif [ "$usable" -gt 0 ] && [ "$v6wild" -eq 0 ]; then
    report FAIL listen.reality '本机有公网 IPv6 地址，但 443/tcp 没有 IPv6 通配监听'
  else
    [ "$v6wild" -eq 0 ] || families='IPv4 和 IPv6'
    report PASS listen.reality "443/tcp 可接受 $families（只说明本机监听）"
  fi
}

ck_secrets_absent() {
  local dir found=()
  if [ -e "$VPS_XUI_DB_DIR/install-result.env" ]; then
    report FAIL secrets.install-result "存在 $VPS_XUI_DB_DIR/install-result.env（含面板凭据和 API token）"
  else
    report PASS secrets.install-result '没有安装结果文件'
  fi
  if [ "$VPS_DB_OK" -eq 1 ]; then
    db_verdict secrets.api-tokens
  else
    report SKIP secrets.api-tokens '数据库不可读（由 xui.db 报告）'
  fi
  if [ -e "$VPS_HANDOFF_FILE" ]; then
    report WARN secrets.handoff "$VPS_HANDOFF_FILE 仍在；取走其中的凭据和订阅地址之后请删除"
  else
    report PASS secrets.handoff '没有待取走的交接文件'
  fi
  if [ -e /root/.acme.sh ] || have acme.sh; then
    report FAIL absent.acme '有 acme.sh；本工具不在 VPS 上签发证书'
  else
    report PASS absent.acme '没有 acme.sh'
  fi
  for dir in "${VPS_CF_CERT_DIRS[@]}"; do
    [ ! -e "$dir/cert.pem" ] || found+=("$dir/cert.pem")
  done
  if [ "${#found[@]}" -eq 0 ]; then
    report PASS absent.cf-credentials '默认目录中没有 cloudflared 的账户证书'
  else
    report FAIL absent.cf-credentials "有 cloudflared 的账户证书：$(join_by ' ' "${found[@]}")；VPS 上只应有 Tunnel 的令牌"
  fi
}

ck_state_perms() {
  local entries
  if [ ! -e "$VPS_ETC_DIR" ] && [ ! -L "$VPS_ETC_DIR" ]; then
    report SKIP state.perms "没有 $VPS_ETC_DIR"
    return 0
  fi
  if [ "$(file_attrs "$VPS_ETC_DIR")" != 'directory|0|700' ]; then
    report FAIL state.perms "$VPS_ETC_DIR 不是属于 root、权限 0700 的目录"
    return 0
  fi
  # Anything other than root-owned 0600 files and the 0700 target-check directory.
  entries="$(find "$VPS_ETC_DIR" -mindepth 1 \
    ! \( -type f -user 0 -perm 0600 \) ! \( -path "$VPS_TARGET_DIR" -type d -user 0 -perm 0700 \) \
    -printf '%P\n' 2>/dev/null)" || entries='(无法列出)'
  if [ -z "$entries" ]; then
    report PASS state.perms "$VPS_ETC_DIR 及其中的文件属于 root，权限正确"
  else
    report FAIL state.perms "$VPS_ETC_DIR 中有属主或权限不对的项：$(tr '\n' ' ' <<<"$entries")"
  fi
}

ck_record() {
  if [ -z "$VPS_RECORD_JSON" ]; then
    report FAIL record.consistent "$VPS_RECORD_ERR"
    return 0
  fi
  if ! jq -e '.ipv6_ai_egress | IN("on", "off")' <<<"$VPS_RECORD_JSON" >/dev/null; then
    report FAIL record.consistent '部署记录中 ipv6_ai_egress 不是 on 或 off'
    return 0
  fi
  if [ "$VPS_DB_OK" -eq 0 ]; then
    report SKIP record.consistent '数据库不可读（由 xui.db 报告）'
    return 0
  fi
  db_verdict record.consistent
}

ck_cloudflared() {
  local attrs got props line frag='' dropins='' reload='' exec='' enabled active pid uid ready share
  attrs="$(file_attrs "$VPS_CLOUDFLARED_BIN")" || attrs=''
  got="$(file_sha256 "$VPS_CLOUDFLARED_BIN")" || got=''
  if [ -z "$got" ]; then
    report FAIL cfd.files "没有 $VPS_CLOUDFLARED_BIN"
  elif [ "$got" != "$VPS_PIN_CLOUDFLARED_SHA256" ]; then
    report FAIL cfd.files "$VPS_CLOUDFLARED_BIN 与固定的摘要不符"
  elif [ "$attrs" != 'regular file|0|755' ]; then
    report FAIL cfd.files "$VPS_CLOUDFLARED_BIN 不是属于 root、权限 0755 的普通文件"
  else
    report PASS cfd.files "cloudflared $VPS_PIN_CLOUDFLARED_VERSION"
  fi

  share="$VPS_SHARE_DIR/$VPS_CFD_UNIT_NAME"
  props="$(bounded systemctl show -p FragmentPath -p DropInPaths -p NeedDaemonReload -p ExecStart \
    -- "$VPS_CFD_UNIT_NAME" 2>/dev/null)" || props=''
  while IFS= read -r line; do
    case "$line" in
      FragmentPath=*) frag="${line#*=}" ;;
      DropInPaths=*) dropins="${line#*=}" ;;
      NeedDaemonReload=*) reload="${line#*=}" ;;
      ExecStart=*) exec="${line#*=}" ;;
    esac
  done <<<"$props"
  if [ ! -f "$share" ]; then
    report FAIL cfd.unit '本版本还没有发布 cloudflared 的服务单元（M3）'
  elif ! cmp -s -- "$share" "/etc/systemd/system/$VPS_CFD_UNIT_NAME"; then
    report FAIL cfd.unit "/etc/systemd/system/$VPS_CFD_UNIT_NAME 与发布的文件不同或不存在"
  elif [ "$frag" != "/etc/systemd/system/$VPS_CFD_UNIT_NAME" ] || [ -n "$dropins" ] || [ "$reload" != no ]; then
    report FAIL cfd.unit 'systemd 加载的单元不是正式路径上的文件，或有 drop-in，或需要 daemon-reload'
  else
    # The loaded ExecStart, DynamicUser and LoadCredential are checked from M3 (18.1).
    report FAIL cfd.unit '管理器加载的字段核对在 M3 实现'
  fi

  enabled="$(bounded systemctl is-enabled -- "$VPS_CFD_UNIT_NAME" 2>/dev/null)" || true
  active="$(bounded systemctl is-active -- "$VPS_CFD_UNIT_NAME" 2>/dev/null)" || true
  pid="$(unit_prop "$VPS_CFD_UNIT_NAME" MainPID)" || pid=''
  if [ "$enabled" != enabled ] || [ "$active" != active ]; then
    report FAIL cfd.service "$VPS_CFD_UNIT_NAME 是 ${enabled:-未知}、${active:-未知}"
  elif ! is_uint "$pid" || [ "$pid" -eq 0 ] || ! uid="$(awk '$1 == "Uid:" { print $3 }' "/proc/$pid/status" 2>/dev/null)" ||
    [ -z "$uid" ]; then
    report FAIL cfd.service 'MainPID 无效或进程已消失'
  elif [ "$uid" -eq 0 ]; then
    report FAIL cfd.service 'cloudflared 以 root 运行'
  else
    # The arguments of the current process are checked from M3 (18.2).
    report FAIL cfd.service '当前进程参数的核对在 M3 实现'
  fi

  if [ -z "$exec" ] || [ -z "$frag" ]; then
    report FAIL cfd.autoupdate "没有 $VPS_CFD_UNIT_NAME，无法确认带 --no-autoupdate 运行"
  elif [[ "$exec" != *' --no-autoupdate '* ]]; then
    report FAIL cfd.autoupdate '单元的 ExecStart 中没有 --no-autoupdate'
  elif update_unit_enabled cloudflared-update.timer || update_unit_enabled cloudflared-update.service; then
    report FAIL cfd.autoupdate 'cloudflared-update 的定时器或服务已加载并启用'
  else
    report PASS cfd.autoupdate '带 --no-autoupdate 运行，没有自动更新的定时器'
  fi

  attrs="$(file_attrs "$VPS_TOKEN_FILE")" || attrs=''
  if [ "$attrs" != 'regular file|0|600' ] || [ ! -s "$VPS_TOKEN_FILE" ]; then
    report FAIL cfd.token "$VPS_TOKEN_FILE 不是属于 root、权限 0600 的非空普通文件"
  else
    report PASS cfd.token 'Tunnel 的令牌文件属于 root，权限 0600（不读取内容）'
  fi

  loopback_item cfd.metrics "$VPS_PORT_CFD_METRICS" 'cloudflared metrics'

  # --noproxy: curl also sends loopback requests to an inherited http_proxy.
  if ready="$(curl -sS --noproxy '*' --max-time 5 -w '\n%{http_code}' \
    "http://127.0.0.1:$VPS_PORT_CFD_METRICS/ready" 2>/dev/null)" &&
    [ "${ready##*$'\n'}" = 200 ] &&
    jq -e '.readyConnections > 0' <<<"${ready%$'\n'*}" >/dev/null 2>&1; then
    report PASS cfd.ready 'cloudflared 已就绪，有连接'
  else
    report FAIL cfd.ready '/ready 不是 200，或者 readyConnections 不大于 0'
  fi

  ck_cfd_routes
}

update_unit_enabled() {
  local state
  unit_known "$1" || return 1
  state="$(bounded systemctl is-enabled -- "$1" 2>/dev/null)" || true
  [ "$state" = enabled ]
}

# cfd.routes (detailed design 4.2): two ingress rules, the subscription and a
# 4xx catch-all. The private-network and other routes are DO-4 (M3). The host
# name is subDomain, or the record's sub_host when the database is unreadable;
# only a valid host name is printed.
ck_cfd_routes() {
  local cfg host='' verdict
  if [ "$VPS_DB_OK" -eq 1 ]; then
    host="$(jq -r '._sub_domain' <<<"$VPS_VERDICTS")"
  elif [ -n "$VPS_RECORD_JSON" ]; then
    host="$(jq -r '.sub_host' <<<"$VPS_RECORD_JSON")"
    hostname_reason "$host" 3 || host=''
  fi
  if [ -z "$host" ]; then
    report FAIL cfd.routes '没有可核对的订阅主机名'
    return 0
  fi
  if ! cfg="$(curl -sS --noproxy '*' --max-time 5 "http://127.0.0.1:$VPS_PORT_CFD_METRICS/config" 2>/dev/null)"; then
    report FAIL cfd.routes '/config 读取失败'
    return 0
  fi
  verdict="$(HOST="$host" SVC="http://127.0.0.1:$VPS_PORT_SUB" jq -r '
    (.config.ingress // null) as $in
    | if ($in | type) != "array" or ($in | length) != 2 then "bad"
      elif ($in[0] | type) != "object" or $in[0].hostname != env.HOST or $in[0].service != env.SVC
        or ($in[0] | has("path") | not) or $in[0].path != null
        or ($in[0].originRequest | type) != "object" or $in[0].originRequest.httpHostHeader != "" then "bad"
      elif ($in[1] | type) != "object" or $in[1].hostname != "" or ($in[1] | has("path") | not) or $in[1].path != null
        or (($in[1].service // "") | test("^http_status:4[0-9][0-9]$") | not) then "bad"
      else "ok" end' <<<"$cfg" 2>/dev/null)" || verdict=bad
  if [ "$verdict" = ok ]; then
    report PASS cfd.routes "生效路由只有 $host 到 http://127.0.0.1:$VPS_PORT_SUB 和 4xx 兜底"
  else
    report FAIL cfd.routes "/config 中的路由不是 $host 到 http://127.0.0.1:$VPS_PORT_SUB 加 4xx 兜底，或结构无效"
  fi
}

cmd_check() {
  local id rules_hex='null' share_rules status forwarder_port
  [ "$#" -eq 0 ] || usage_error 'check 不接受参数'
  check_root_gate
  check_platform_gate
  deps_report deps "${VPS_CHECK_DEPS[@]}" || stop_at_gate
  tcp_listeners_load

  VPS_XUI_VERSION_OK=0
  ck_xui_program
  ck_xui_unit
  ck_xui_env_service_ipl

  VPS_DB_OK=0
  VPS_VERDICTS='{}'
  VPS_RECORD_ERR=''
  read_deploy_record || VPS_RECORD_ERR="$VPS_REASON"
  if [ "$VPS_XUI_VERSION_OK" -ne 1 ]; then
    report SKIP xui.db '3X-UI 的版本不符，不读取数据库（由 xui.version 报告）'
  elif ! xui_snapshot; then
    report FAIL xui.db "$VPS_REASON"
  elif id="$(jq -r '[.settings // {} | to_entries[] | select(.value.n > 1) | .key] | join(" ")' \
    <<<"$VPS_XUI_SNAPSHOT")" && [ -n "$id" ]; then
    report FAIL xui.db "设置表中这些键有多行：$id"
  else
    share_rules="$VPS_SHARE_DIR/$VPS_RULES_FILE_NAME"
    if [ -f "$share_rules" ]; then
      rules_hex="\"$(od -An -v -tx1 -- "$share_rules" | tr -d ' \n' | tr 'a-f' 'A-F')\""
    fi
    VPS_VERDICTS="$(jq -c -n --argjson snap "$VPS_XUI_SNAPSHOT" --argjson defaults "$VPS_XUI_DEFAULTS" \
      --argjson default_outbounds "$VPS_XUI_DEFAULT_OUTBOUNDS" --argjson rules_hex "$rules_hex" \
      --argjson rec "${VPS_RECORD_JSON:-null}" "$VPS_CHECK_JQ")" || internal_error '数据库检查项的判定失败'
    VPS_DB_OK=1
    report PASS xui.db '数据库只读快照有效'
  fi

  for id in "${VPS_DB_ITEMS[@]}"; do
    if [ "$VPS_DB_OK" -ne 1 ]; then
      report SKIP "$id" '数据库不可读（由 xui.version 或 xui.db 报告）'
    elif [ "$id" = panel.listen ]; then
      ck_panel_listen
    else
      db_verdict "$id"
    fi
    if [ "$id" = routing.ai-ipv6 ]; then
      if [ -z "$VPS_RECORD_JSON" ] || ! status="$(jq -r '.ipv6_ai_egress | select(IN("on", "off"))' \
        <<<"$VPS_RECORD_JSON")" || [ -z "$status" ]; then
        report SKIP ipv6.egress '部署记录缺失或 ipv6_ai_egress 无效（由 record.consistent 报告）'
      else
        check_ipv6_egress "$status"
      fi
    fi
  done

  ck_listen_reality
  forwarder_port="$(jq -r '._fwd_port // empty' <<<"$VPS_VERDICTS")"
  is_port "$forwarder_port" || forwarder_port="$VPS_PORT_FORWARDER"
  loopback_item listen.forwarder "$forwarder_port" '转发入站'
  loopback_item listen.sub "$VPS_PORT_SUB" '订阅服务'
  loopback_item listen.api "$VPS_PORT_XUI_API" '3X-UI 的 api 入站'
  loopback_item listen.metrics "$VPS_PORT_XRAY_METRICS" 'Xray metrics'

  ck_secrets_absent
  ck_state_perms
  ck_record
  ck_cloudflared

  status="$(hardening_verify_status)"
  if [ "$status" -eq 0 ]; then
    report PASS hardening.verify 'vps-hardening verify 通过'
  else
    report FAIL hardening.verify "vps-hardening verify 的退出码为 $status"
  fi
  finish_checks
}
