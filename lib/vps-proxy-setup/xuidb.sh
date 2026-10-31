# shellcheck shell=bash
# Read-only snapshot of the 3X-UI database (detailed design 4.1). One sqlite3
# call, one statement, one read transaction, one JSON document; every database
# item is judged on that document. Secrets stay inside the sqlite3 process:
# the statement selects named columns, removes the REALITY private key and
# shortIds, and turns the subscription paths into booleans and lengths.
# Globals defined here are read by the other modules, which ShellCheck checks separately.
# shellcheck disable=SC2034

# Setting keys the checks read, and those whose values may leave sqlite3.
readonly VPS_XUI_SETTING_KEYS="'webListen','webPort','subEnable','subListen','subPort','subDomain',\
'subCertFile','subKeyFile','subURI','subClashURI','subPath','subClashPath','subClashEnable',\
'subClashEnableRouting','subClashRules','subJsonEnable','subInfoNodeEnable','subUpdates',\
'remarkTemplate','xrayTemplateConfig'"
readonly VPS_XUI_SETTING_PLAIN="'webListen','webPort','subEnable','subListen','subPort','subDomain',\
'subCertFile','subKeyFile','subClashEnable','subClashEnableRouting','subJsonEnable',\
'subInfoNodeEnable','subUpdates','remarkTemplate'"

# jx COLUMN PATH: the JSON value at PATH in a text column holding JSON, or NULL.
# json() outside CASE keeps the value JSON inside json_object.
jx() {
  printf "json(CASE WHEN json_valid(%s) THEN %s -> '%s' END)" "$1" "$1" "$2"
}
# jt COLUMN PATH: the JSON type at PATH ('null' for a JSON null), NULL if absent.
jt() {
  printf "(CASE WHEN json_valid(%s) THEN json_type(%s, '%s') END)" "$1" "$1" "$2"
}

xui_snapshot_sql() {
  local s=settings ss=stream_settings sn=sniffing r='$.realitySettings'
  cat <<EOF
WITH t AS (SELECT value AS v FROM settings WHERE key = 'xrayTemplateConfig' LIMIT 1),
p AS (SELECT
  COALESCE((SELECT value FROM settings WHERE key = 'subPath' LIMIT 1), '/sub/') AS sp,
  COALESCE((SELECT value FROM settings WHERE key = 'subClashPath' LIMIT 1), '/clash/') AS cp,
  COALESCE((SELECT value FROM settings WHERE key = 'subURI' LIMIT 1), '') AS uri,
  COALESCE((SELECT value FROM settings WHERE key = 'subClashURI' LIMIT 1), '') AS curi,
  COALESCE((SELECT value FROM settings WHERE key = 'subDomain' LIMIT 1), '') AS dom)
SELECT json_object(
 'settings', (SELECT json_group_object(key, json_object('n', n, 'v', v)) FROM (
    SELECT key, count(*) AS n, CASE WHEN key IN ($VPS_XUI_SETTING_PLAIN) THEN max(value) END AS v
    FROM settings WHERE key IN ($VPS_XUI_SETTING_KEYS) GROUP BY key)),
 'sub', (SELECT json_object(
    'path_default', sp = '/sub/',
    'path_len', CASE WHEN sp GLOB '/*/' THEN length(sp) - 2 ELSE -1 END,
    'clash_path_default', cp = '/clash/',
    'clash_path_len', CASE WHEN cp GLOB '/*/' THEN length(cp) - 2 ELSE -1 END,
    'uri_ok', uri = 'https://' || dom || sp,
    'clash_uri_ok', curi = 'https://' || dom || cp) FROM p),
 'rules_hex', (SELECT hex(value) FROM settings WHERE key = 'subClashRules' LIMIT 1),
 'template', json_object(
    'n', (SELECT count(*) FROM settings WHERE key = 'xrayTemplateConfig'),
    'valid', (SELECT json_valid(v) FROM t),
    'has_dns', (SELECT CASE WHEN json_valid(v) THEN json_type(v, '\$.dns') IS NOT NULL END FROM t),
    'domainStrategy_type', (SELECT $(jt v '$.routing.domainStrategy') FROM t),
    'domainStrategy', (SELECT $(jx v '$.routing.domainStrategy') FROM t),
    'rules', (SELECT $(jx v '$.routing.rules') FROM t),
    'outbounds_type', (SELECT $(jt v '$.outbounds') FROM t),
    'outbounds', (SELECT json_group_array(json_object(
        'tag', o.value ->> '\$.tag',
        'protocol', o.value ->> '\$.protocol',
        'keys', json(CASE WHEN o.value ->> '\$.tag' IN ('direct', 'ai-ipv6') THEN
          (SELECT json_group_array(k.key ORDER BY k.key) FROM json_each(o.value) k) END),
        'settings_keys', json(CASE WHEN o.value ->> '\$.tag' IN ('direct', 'ai-ipv6') THEN
          (SELECT json_group_array(k.key ORDER BY k.key) FROM json_each(o.value, '\$.settings') k) END),
        'finalRules', json(CASE WHEN o.value ->> '\$.tag' IN ('direct', 'ai-ipv6') THEN
          o.value -> '\$.settings.finalRules' END),
        'streamSettings', json(CASE WHEN o.value ->> '\$.tag' IN ('direct', 'ai-ipv6') THEN
          o.value -> '\$.streamSettings' END)) ORDER BY o.key)
      FROM t, json_each(CASE WHEN json_valid(t.v) AND json_type(t.v, '\$.outbounds') = 'array'
        THEN t.v END, '\$.outbounds') o)),
 'inbounds', (SELECT json_group_array(json_object(
    'id', id, 'protocol', protocol, 'port', port, 'listen', listen, 'enable', enable,
    'node_id', node_id, 'tag', tag, 'share_addr_strategy', share_addr_strategy,
    'share_addr', share_addr, 'exclude_from_sub', exclude_from_sub, 'disable_flow', disable_flow,
    'settings_valid', json_valid($s),
    'decryption', $(jx $s '$.decryption'),
    'address_t', $(jt $s '$.address'), 'address', $(jx $s '$.address'),
    'rewriteAddress_t', $(jt $s '$.rewriteAddress'), 'rewriteAddress', $(jx $s '$.rewriteAddress'),
    'port_t', $(jt $s '$.port'), 'port_v', $(jx $s '$.port'),
    'rewritePort_t', $(jt $s '$.rewritePort'), 'rewritePort', $(jx $s '$.rewritePort'),
    'network_t', $(jt $s '$.network'), 'network_v', $(jx $s '$.network'),
    'allowedNetwork_t', $(jt $s '$.allowedNetwork'), 'allowedNetwork', $(jx $s '$.allowedNetwork'),
    'followRedirect', $(jx $s '$.followRedirect'),
    'stream_valid', json_valid($ss),
    'network', $(jx $ss '$.network'),
    'security', $(jx $ss '$.security'),
    'r_target_t', $(jt $ss "$r.target"), 'r_target', $(jx $ss "$r.target"),
    'r_dest_t', $(jt $ss "$r.dest"), 'r_dest', $(jx $ss "$r.dest"),
    'r_serverNames', $(jx $ss "$r.serverNames"),
    'r_xver', $(jx $ss "$r.xver"),
    'r_fingerprint', $(jx $ss "$r.settings.fingerprint"),
    'r_pk_nonempty', CASE WHEN json_valid($ss) THEN
      coalesce(length(json_extract($ss, '$r.privateKey')), 0) > 0 END,
    'r_sid_t', $(jt $ss "$r.shortIds"),
    'r_sid_count', CASE WHEN json_valid($ss) AND json_type($ss, '$r.shortIds') = 'array'
      THEN json_array_length($ss, '$r.shortIds') END,
    'r_sid0_t', $(jt $ss "$r.shortIds[0]"),
    'r_sid0_len', CASE WHEN json_valid($ss) THEN length(json_extract($ss, '$r.shortIds[0]')) END,
    'r_sid0_hex', CASE WHEN json_valid($ss) THEN
      json_extract($ss, '$r.shortIds[0]') NOT GLOB '*[^0-9a-fA-F]*' END,
    'sniff_valid', json_valid($sn),
    'sniff_enabled', $(jx $sn '$.enabled'),
    'sniff_dest', $(jx $sn '$.destOverride'),
    'sniff_routeOnly', $(jx $sn '$.routeOnly'),
    'sniff_metadataOnly', $(jx $sn '$.metadataOnly')) ORDER BY id) FROM inbounds),
 'clients', (SELECT json_group_array(json_object('email', email, 'enable', enable, 'flow', flow,
    'limit_ip', limit_ip) ORDER BY id) FROM clients),
 'links', (SELECT json_group_array(json_object('email', c.email, 'inbound_id', ci.inbound_id,
    'flow_override', ci.flow_override) ORDER BY ci.inbound_id, c.id)
    FROM client_inbounds ci JOIN clients c ON c.id = ci.client_id),
 'hosts', (SELECT json_group_array(json_object('inbound_id', inbound_id, 'disabled', is_disabled,
    'address', address, 'mihomo_x25519', mihomo_x25519) ORDER BY id) FROM hosts),
 'api_tokens', (SELECT json_group_array(name ORDER BY name) FROM api_tokens WHERE enabled)
);
EOF
}

# xui_sqlite URI SQL: the read-only sqlite3 call of detailed design 4.1. The
# test driver of VT-72 loads this function to prove writes are refused.
xui_sqlite() {
  timeout --kill-after=5 30 sqlite3 -readonly -safe -batch -bail -init /dev/null \
    -cmd '.timeout 5000' "$1" "$2"
}

# The managed state around a read: "ACTIVE SUB MAINPID WAL SHM JOURNAL". The
# properties are parsed by name: systemctl prints them in its own order.
xui_db_state() {
  local out line active='' sub='' pid='' wal=0 shm=0 journal=0
  out="$(bounded systemctl show -p ActiveState -p SubState -p MainPID -- x-ui.service 2>/dev/null)" ||
    return 1
  while IFS= read -r line; do
    case "$line" in
      ActiveState=*) active="${line#*=}" ;;
      SubState=*) sub="${line#*=}" ;;
      MainPID=*) pid="${line#*=}" ;;
    esac
  done <<<"$out"
  [ -n "$active" ] && [ -n "$sub" ] && [ -n "$pid" ] || return 1
  [ ! -e "$VPS_XUI_DB-wal" ] || wal=1
  [ ! -e "$VPS_XUI_DB-shm" ] || shm=1
  [ ! -e "$VPS_XUI_DB-journal" ] || journal=1
  printf '%s %s %s %s %s %s\n' "$active" "$sub" "$pid" "$wal" "$shm" "$journal"
}

# xui_db_uri STATE: the open mode for the state, or 1 with VPS_REASON set
# (the table in detailed design 4.1).
xui_db_uri() {
  local active sub wal shm journal
  read -r active sub _ wal shm journal <<<"$1"
  if [ "$journal" = 1 ]; then
    VPS_REASON='有 -journal，不尝试恢复可能的热日志'
    return 1
  fi
  if [ "$active" = active ] && [ "$sub" = running ] && [ "$wal" = 1 ] && [ "$shm" = 1 ]; then
    printf 'file:%s?mode=ro\n' "$VPS_XUI_DB"
    return 0
  fi
  if { [ "$active" = inactive ] || [ "$active" = failed ]; } && { [ "$sub" = dead ] || [ "$sub" = failed ]; } &&
    [ "$wal" = 0 ] && [ "$shm" = 0 ]; then
    printf 'file:%s?mode=ro&immutable=1\n' "$VPS_XUI_DB"
    return 0
  fi
  VPS_REASON="x-ui 处于 $active/$sub，-wal、-shm 存在与否为 $wal/$shm，不满足读取前提"
  return 1
}

# xui_snapshot: sets VPS_XUI_SNAPSHOT, or returns 1 with VPS_REASON set.
VPS_XUI_SNAPSHOT=''
xui_snapshot() {
  local before after uri out
  VPS_XUI_SNAPSHOT=''
  if [ ! -f "$VPS_XUI_DB" ]; then
    VPS_REASON="没有 $VPS_XUI_DB"
    return 1
  fi
  if ! before="$(xui_db_state)"; then
    VPS_REASON='无法读取 x-ui 的服务状态'
    return 1
  fi
  uri="$(xui_db_uri "$before")" || return 1
  if ! out="$(xui_sqlite "$uri" "$(xui_snapshot_sql)" 2>/dev/null)"; then
    VPS_REASON='sqlite3 报错或超时'
    return 1
  fi
  if ! after="$(xui_db_state)" || [ "$after" != "$before" ]; then
    VPS_REASON='读取期间 x-ui 的状态或侧文件发生变化，本次结果不可靠'
    return 1
  fi
  if ! jq -e 'type == "object" and (.inbounds | type) == "array" and (.template | type) == "object"' \
    <<<"$out" >/dev/null 2>&1; then
    VPS_REASON='快照无效'
    return 1
  fi
  VPS_XUI_SNAPSHOT="$out"
}
