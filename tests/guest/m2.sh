#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Guest side of the M2 VM tests (detailed design 9, 19; verification plan
# VT-10 to VT-13, VT-15, VT-16, VT-18). Sources tests/guest/m1.sh for its helpers and the phases of
# the main configuration; tests/vm.py runs one phase per SSH session. The
# guest is the main configuration with the namespaces, the stand-in and a
# fresh target-check result of the m1 phase network and the phase m2-prep.

# shellcheck source=m1.sh
. "${BASH_SOURCE[0]%/*}/m1.sh"

readonly INSTALLED_LIB=/usr/local/lib/vps-proxy-setup
readonly M2_INPUT="$PRIVATE/m2.input"
readonly TUNING_DROPIN=/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf
# Where the 3X-UI installer downloads the release archive (install.sh v3.11.0,
# install_x-ui: the parent of /usr/local/x-ui).
readonly XUI_ARCHIVE_TMP=/usr/local/x-ui-linux-amd64.tar.gz
readonly FETCH_ITEMS=(fetch.tag fetch.installer fetch.archive fetch.unit fetch.script)
readonly INSTALL_ITEMS=(xui.install xui.version xui.files xui.unit xui.env xui.service xui.ipl tuning.kept
  panel.listen)
readonly PREWRITE_ITEMS=(fresh.version fresh.inbounds fresh.clients fresh.settings target.checked install.result
  api.token)
readonly WRITE_ITEMS=(keys.x25519 keys.short-id write.settings write.forwarder write.reality write.template
  write.clients)
readonly XRAY_CONFIG=/usr/local/x-ui/bin/config.json

# A failure of a driver itself, told apart from the refusal under test (exit 1).
driver_fail() {
  printf 'driver: %s\n' "$*" >&2
  exit 2
}

# deploy_yes NAME CMD...: CMD on a pseudo-terminal, answering yes to the
# confirmation of detailed design 2.5.
deploy_yes() {
  TTY_INPUT=yes capture_tty "$@"
}

# No private scratch directory of the tool is left behind (detailed design 2.6).
expect_no_tmp() {
  [ -z "$(find /tmp -maxdepth 1 -name 'vps-proxy-setup.*' -print -quit)" ] ||
    fail "$1: the tool left a scratch directory in /tmp"
}

# A digest of the same length with every hex digit changed.
other_hex() {
  tr '0-9a-f' '1-9a-f0' <<<"$1"
}

# pin_of PATH: the pinned digest of an installed 3X-UI file.
pin_of() {
  vps_fn xui_pin_lines | awk -v path="$1" '$2 == path { print $1 }'
}

phase_m2_prep() {
  settle
  trust_ca on
  capture m2-target-check "$TOOL" target-check target.example
  expect_rc m2-target-check 0
  write_input "$M2_INPUT"
}

# vt11_case NAME ITEM PIN: deploy with the pinned value PIN changed in a copy of
# pins.sh, bound over the installed one in a private mount namespace. It must
# stop at step 2 with ITEM failing, before any change (VT-11). A changed pin
# stands for a changed download: the comparison is the same.
vt11_case() {
  local name="vt11-$1" item="$2" pin="$3" pins="$PRIVATE/pins-$1.sh"
  [ "$(grep -cF -- "'$pin'" "$INSTALLED_LIB/pins.sh")" = 1 ] || fail "$name: the pin is not in pins.sh once"
  sed "s/'$pin'/'$(other_hex "$pin")'/" "$INSTALLED_LIB/pins.sh" >"$pins"
  chmod 0644 "$pins"
  ! cmp -s "$pins" "$INSTALLED_LIB/pins.sh" || fail "$name: the pin was not changed"
  TTY_INPUT=yes observe "$name" capture_tty "${BOUND[@]}" "$pins" "$INSTALLED_LIB/pins.sh" \
    "$TOOL" deploy --input "$M2_INPUT"
  expect_rc "$name" 1
  expect_clean "$name"
  expect_err "$name" '[x] 第 2 步未完成：主机未改动'
  expect_fails "$name" "$item"
  expect_no_secret "$name"
  expect_no_tmp "$name"
}

phase_vt11() {
  settle
  vt11_case commit fetch.tag "$(vps_fn pin_value VPS_PIN_XUI_COMMIT)"
  vt11_case archive fetch.archive "$(vps_fn pin_value VPS_PIN_XUI_TARBALL_SHA256)"
  vt11_case script fetch.script "$(pin_of /usr/bin/x-ui)"
  vt11_case unit fetch.unit "$(pin_of /etc/systemd/system/x-ui.service)"
}

# VT-10 and VT-16 through the deploy entry; VT-13 on its output.
phase_vt10() {
  local port tuning out
  settle
  port="$(state_value panel_port)"
  tuning="$(sha256sum <"$TUNING_DROPIN")"
  deploy_yes vt10 "$TOOL" deploy --input "$M2_INPUT"
  collect_markers
  expect_rc vt10 1
  expect_clean vt10
  expect_err vt10 '输入 yes 继续'
  expect_err vt10 '[x] 第 1～6 步完成'
  expect_report vt10 PASS "${PREFLIGHT_PASS[@]}" "${FETCH_ITEMS[@]}" "${INSTALL_ITEMS[@]}" "${PREWRITE_ITEMS[@]}" \
    "${WRITE_ITEMS[@]}"
  expect_fails vt10
  expect_no_secret vt10
  expect_no_tmp vt10

  # The expected results of VT-10, judged here rather than from the tool's items.
  out="$(/usr/local/x-ui/x-ui -v)"
  [ "$out" = "$(vps_fn pin_value VPS_PIN_XUI_VERSION)" ] || fail "VT-10: x-ui -v printed $out"
  vps_fn xui_pin_lines | sha256sum -c - >"$phase_dir/vt10-digests.txt" || fail 'VT-10: an installed file differs from its pin'
  ss -Hltn "sport = :$port" >"$phase_dir/vt10-panel-listen.txt"
  [ "$(vps_fn port_state "$port")" = loopback ] || fail 'VT-10: the panel listens beyond loopback'
  [ -z "$(find /etc/fail2ban -name '3x-ipl*' -print -quit 2>/dev/null)" ] || fail 'VT-10: 3x-ipl files exist'
  if fail2ban-client status 2>/dev/null | grep -q '3x-ipl'; then
    fail 'VT-10: the 3x-ipl jail is loaded'
  fi
  [ "$(sha256sum <"$TUNING_DROPIN")" = "$tuning" ] || fail 'VT-10: 90-proxy-vps.conf changed'
  [ -s "$XUI_RESULT" ] || fail 'VT-10: no install result to scan against'
  vt16_judge vt10 off
  scan_markers
}

# vt16_db NAME IPV6: VT-16 on the read-only database, independent of the
# tool's own items. Only judgments and the digest of the shortId are archived.
vt16_db() {
  local name="$1" state uri
  state="$(vps_fn xui_db_state)" || fail "$name: database not readable"
  uri="$(vps_fn xui_db_uri "$state")" || fail "$name: database not readable"
  python3 - "$uri" "$phase_dir/$name-vt16-db.txt" "$phase_dir/$name-sid-digest.txt" "$2" <<'PY'
import hashlib, json, re, sqlite3, sys

uri, out, sid_out, ipv6 = sys.argv[1:5]
target, sub_host, node_ip, users = 'target.example', 'sub.proxy.example', '192.0.2.1', ['alice', 'bob']
uuid_re = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
lines, fails = [], []


def check(ok, what):
    lines.append(('PASS ' if ok else 'FAIL ') + what)
    if not ok:
        fails.append(what)


def obj(text):
    try:
        value = json.loads(text or 'null')
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


con = sqlite3.connect(uri, uri=True, timeout=5)
con.row_factory = sqlite3.Row
ins = [dict(r) for r in con.execute('SELECT * FROM inbounds ORDER BY id')]
real = [i for i in ins if i['protocol'] == 'vless']
fwd = [i for i in ins if i['protocol'] == 'tunnel']
check(len(ins) == 2 and len(real) == 1 and len(fwd) == 1, f'inbounds: one vless and one tunnel ({len(ins)} in all)')
if real and fwd:
    r, f = real[0], fwd[0]
    rs, rset = obj(r['stream_settings']), obj(r['settings'])
    rr = rs.get('realitySettings') or {}
    check(r['port'] == 443 and r['listen'] == '' and r['enable'] == 1 and r['node_id'] is None,
          'REALITY: 443 on all addresses, enabled, local')
    check(rs.get('network') == 'tcp' and rs.get('security') == 'reality', 'REALITY: tcp with reality')
    check(rr.get('target') == '127.0.0.1:20443' and 'dest' not in rr, 'REALITY: target 127.0.0.1:20443')
    check(rr.get('serverNames') == [target], 'REALITY: serverNames is the target only')
    sids = rr.get('shortIds')
    ok_sid = (isinstance(sids, list) and len(sids) == 1 and isinstance(sids[0], str)
              and re.fullmatch('[0-9a-f]{16}', sids[0]) is not None)
    check(ok_sid, 'REALITY: one shortId of 16 lowercase hex characters')
    if ok_sid:
        with open(sid_out, 'w') as fh:
            fh.write(hashlib.sha256(sids[0].encode()).hexdigest() + '\n')
    rk = rr.get('settings') or {}
    check(bool(rr.get('privateKey')) and bool(rk.get('publicKey')), 'REALITY: key pair present')
    check(rk.get('fingerprint') == 'chrome' and rr.get('xver', 0) == 0, 'REALITY: fingerprint chrome, xver 0')
    check(rset.get('decryption') == 'none' and r['disable_flow'] == 0, 'REALITY: decryption none, flow allowed')
    check(r['share_addr_strategy'] == 'custom' and r['share_addr'] == node_ip and r['exclude_from_sub'] == 0,
          'REALITY: shared as the node IPv4, in the subscription')
    fs, sn = obj(f['settings']), obj(f['sniffing'])
    check(f['port'] == 20443 and f['listen'] == '127.0.0.1' and f['enable'] == 1 and f['node_id'] is None,
          'forwarder: 127.0.0.1:20443, enabled, local')
    check(fs.get('rewriteAddress') == '127.0.0.1' and fs.get('rewritePort') == 443
          and fs.get('allowedNetwork') == 'tcp' and not fs.get('followRedirect')
          and not ({'address', 'port', 'network'} & set(fs)), 'forwarder: to 127.0.0.1:443 over tcp')
    check(sn.get('enabled') is True and sn.get('destOverride') == ['tls'] and not sn.get('routeOnly')
          and not sn.get('metadataOnly'), 'forwarder: sniffing tls only')

    rows = con.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'").fetchall()
    check(len(rows) == 1, 'template: one xrayTemplateConfig')
    t = obj(rows[0][0]) if rows else {}
    want = [{'type': 'field', 'inboundTag': [f['tag']], 'domain': ['full:' + target], 'outboundTag': 'direct'},
            {'type': 'field', 'inboundTag': [f['tag']], 'outboundTag': 'blocked'},
            {'type': 'field', 'inboundTag': [r['tag']], 'domain': ['geosite:cn'], 'outboundTag': 'blocked'},
            {'type': 'field', 'inboundTag': [r['tag']], 'ip': ['geoip:cn'], 'outboundTag': 'blocked'}]
    rules = (t.get('routing') or {}).get('rules') or []
    check(rules[:4] == want, 'template: rules 1 to 4 of solution design 7.4 with the real tags')
    # The rules of the default template of 3X-UI v3.11.0 follow unchanged (detailed design 17).
    default = [{'inboundTag': ['api'], 'outboundTag': 'api', 'type': 'field'},
               {'ip': ['geoip:private'], 'outboundTag': 'blocked', 'type': 'field'},
               {'outboundTag': 'blocked', 'protocol': ['bittorrent'], 'type': 'field'}]
    if ipv6 == 'off':
        check(rules[4:] == default, 'template: the default rules follow')
        check(all(o.get('tag') != 'ai-ipv6' for o in t.get('outbounds') or []), 'template: no ai-ipv6 outbound')
    check((t.get('routing') or {}).get('domainStrategy', 'AsIs') == 'AsIs', 'template: domainStrategy AsIs')
    check([o.get('tag') for o in t.get('outbounds') or []][:2] == ['direct', 'blocked'],
          'template: direct is the first outbound')

    cl = [dict(c) for c in con.execute('SELECT * FROM clients ORDER BY id')]
    check([c['email'] for c in cl] == users, 'clients: the users of the input, in order')
    check(all(c['flow'] == 'xtls-rprx-vision' and c['limit_ip'] == 0 and c['enable'] == 1 for c in cl),
          'clients: Vision, no IP limit, enabled')
    check(len({c['uuid'] for c in cl}) == len(cl) and all(re.fullmatch(uuid_re, c['uuid'] or '') for c in cl),
          'clients: distinct UUIDs')
    check(len({c['sub_id'] for c in cl}) == len(cl) and all(c['sub_id'] for c in cl),
          'clients: distinct subscription IDs')
    links = [tuple(x) for x in con.execute('SELECT c.email, ci.inbound_id FROM client_inbounds ci '
                                           'JOIN clients c ON c.id = ci.client_id ORDER BY c.id, ci.inbound_id')]
    check(links == [(u, r['id']) for u in users], 'clients: each linked to the REALITY inbound only')

settings = {}
for key, value in con.execute('SELECT key, value FROM settings'):
    settings.setdefault(key, []).append(value)


def one(key):
    values = settings.get(key, [])
    return values[0] if len(values) == 1 else None


expect = {'subEnable': 'true', 'subListen': '127.0.0.1', 'subPort': '2096', 'subDomain': sub_host,
          'subCertFile': '', 'subKeyFile': '', 'subClashEnable': 'true', 'subClashEnableRouting': 'true',
          'subJsonEnable': 'false', 'subInfoNodeEnable': 'false', 'subUpdates': '12',
          'remarkTemplate': '{{INBOUND}}'}
bad = [k for k, v in expect.items() if one(k) != v]
check(not bad, 'settings: the table of solution design 7.5' + (f' (differ: {" ".join(bad)})' if bad else ''))
sp, cp = one('subPath') or '', one('subClashPath') or ''
check(re.fullmatch('/[a-z0-9]{16}/', sp) is not None and re.fullmatch('/[a-z0-9]{16}/', cp) is not None,
      'settings: the random subscription paths are kept')
check(one('subURI') == 'https://' + sub_host + sp and one('subClashURI') == 'https://' + sub_host + cp,
      'settings: subURI and subClashURI hold the paths')
con.close()
with open(out, 'w') as fh:
    fh.write(''.join(line + '\n' for line in lines))
print(''.join(line + '\n' for line in lines), end='')
sys.exit(1 if fails else 0)
PY
}

# vt16_config MODE: the configuration 3X-UI generated for Xray against the
# database (detailed design 17). MODE info only counts the users already in it;
# MODE full judges it.
vt16_config() {
  local state uri
  state="$(vps_fn xui_db_state)" && uri="$(vps_fn xui_db_uri "$state")" || return 1
  python3 - "$uri" "$XRAY_CONFIG" "$1" <<'PY'
import json, sqlite3, sys

uri, path, mode = sys.argv[1:4]
con = sqlite3.connect(uri, uri=True, timeout=5)
con.row_factory = sqlite3.Row
db = {r['protocol']: dict(r) for r in con.execute('SELECT * FROM inbounds')}
tpl = json.loads(con.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'").fetchone()[0])
emails = [r[0] for r in con.execute('SELECT email FROM clients ORDER BY id')]
con.close()
with open(path) as fh:
    cfg = json.load(fh)
by_tag = {i.get('tag'): i for i in cfg.get('inbounds') or []}
real, fwd = by_tag.get(db['vless']['tag']), by_tag.get(db['tunnel']['tag'])
clients = ((real or {}).get('settings') or {}).get('clients') or []
if mode == 'info':
    print(f'users in the generated configuration: {len(clients)}')
    sys.exit(0)
fails = []


def check(ok, what):
    print(('PASS ' if ok else 'FAIL ') + what)
    if not ok:
        fails.append(what)


check(real is not None and real.get('port') == 443, 'generated: the REALITY inbound on 443')
check(fwd is not None and fwd.get('port') == 20443 and fwd.get('listen') == '127.0.0.1',
      'generated: the forwarder on 127.0.0.1:20443')
check(sorted(c.get('email') for c in clients) == sorted(emails)
      and all(c.get('flow') == 'xtls-rprx-vision' for c in clients), 'generated: every user, with Vision')
rr_db = (json.loads(db['vless']['stream_settings']).get('realitySettings') or {})
rr = ((real or {}).get('streamSettings') or {}).get('realitySettings') or {}
check(all(rr.get(k) == rr_db.get(k) for k in ('target', 'serverNames', 'shortIds', 'privateKey')),
      'generated: REALITY target, serverNames, shortIds and key as in the database')
check(((cfg.get('routing') or {}).get('rules') or [])[:4] == tpl['routing']['rules'][:4],
      'generated: rules 1 to 4 as in the template')
check([o.get('tag') for o in cfg.get('outbounds') or []][:1] == ['direct'], 'generated: direct first')
sys.exit(1 if fails else 0)
PY
}

# vt16_judge NAME IPV6: the database, then the generated configuration. 3X-UI
# may give new users to the running Xray without rewriting the file, so the
# file is judged after a restart of x-ui, as step 7 will do; the count before
# is kept as evidence.
vt16_judge() {
  local name="$1"
  vt16_db "$name" "$2" || fail "$name: VT-16 database checks failed"
  vt16_config info >"$phase_dir/$name-vt16-config-before.txt" 2>&1 || true
  systemctl restart x-ui.service
  wait_xui_stable
  vt16_config full | tee "$phase_dir/$name-vt16-config.txt" || fail "$name: VT-16 generated configuration checks failed"
}

# The seam of detailed design 19 for VT-12 and VT-13, run through deploy_fn:
# the real steps 2 and 3; the filter over the whole real installer output (the
# credentials come before its last 20 lines) and the end shown; one installed
# file replaced; the real step 4. Exit status 2 means the driver itself failed.
# shellcheck disable=SC2031 # runs inside deploy_fn, where deploy_install sets VPS_INSTALL_LOG
vt12_steps() {
  trap vps_cleanup EXIT
  VPS_PANEL_PORT="$(state_value panel_port)"
  vps_tmp_init
  deploy_prefetch
  deploy_install || { printf 'driver: the installer exited with %s\n' "$?" >&2; exit 2; }
  install -m 0600 "$VPS_INSTALL_LOG" "$PRIVATE/vt12-install.log"
  install_log_filtered >"$PRIVATE/vt13-filtered.txt" || true
  printf '== install_log_tail\n' >&2
  install_log_tail
  printf '== step 4\n' >&2
  python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-1] ^= 1; open(p, "wb").write(b)' \
    /usr/bin/x-ui
  deploy_verify_install
  printf 'driver: step 4 did not stop\n' >&2
  exit 2
}

phase_vt12() {
  local port i listen_rows raw kept lines
  settle
  port="$(state_value panel_port)"
  capture vt12 deploy_fn vt12_steps
  collect_markers
  expect_rc vt12 1
  expect_clean vt12
  expect_report vt12 PASS "${FETCH_ITEMS[@]}" xui.version
  expect_fails vt12 xui.files
  expect_err vt12 '[x] 第 4 步未完成'
  expect_err vt12 'SR-9'
  if grep -qE '^\[[A-Z]+\] (xui\.unit|panel\.listen) ' "$phase_dir/vt12.out"; then
    fail 'vt12: step 4 went on after the file check'
  fi
  # Nothing written: the panel still listens where the installer left it.
  for i in $(seq 30); do
    listening "$port" && break
    sleep 1
  done
  ss -Hltn "sport = :$port" >"$phase_dir/vt12-panel-listen.txt"
  [ "$(vps_fn port_state "$port")" = exposed ] || fail 'vt12: the panel listen address was changed'
  listen_rows="$(python3 - "file:$XUI_DB?mode=ro" <<'PY'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1], uri=True, timeout=5)
print(con.execute("SELECT COUNT(*) FROM settings WHERE key = 'webListen' AND value <> ''").fetchone()[0])
PY
  )"
  [ "$listen_rows" = 0 ] || fail 'vt12: webListen was written'

  # VT-13 on the real output of the installer: it holds the credentials, the
  # whole of it filtered and the end shown do not. Only counts are archived.
  raw="$(grep -cF -f "$PRIVATE/markers" "$PRIVATE/vt12-install.log" || true)"
  kept="$(grep -cF -f "$PRIVATE/markers" "$PRIVATE/vt13-filtered.txt" || true)"
  lines="$(wc -l <"$PRIVATE/vt13-filtered.txt")"
  printf 'installer output: %s lines with a test secret; filtered: %s lines, %s with a test secret\n' \
    "$raw" "$lines" "$kept" | tee "$phase_dir/vt13-filter.txt"
  [ "$raw" -gt 0 ] || fail 'vt13: the installer output holds none of the credentials; the filter test would prove nothing'
  [ "$kept" = 0 ] || fail 'vt13: the filtered installer output holds a test secret'
  [ "$lines" -gt 0 ] || fail 'vt13: the filter removed every line'
  sed -n '/^== install_log_tail$/,/^== step 4$/p' "$phase_dir/vt12.err" >"$phase_dir/vt13-tail.txt"
  grep -q '^    ' "$phase_dir/vt13-tail.txt" || fail 'vt13: the filtered end of the installer output is empty'
  expect_no_secret vt12
  expect_no_tmp vt12
  scan_markers
}

# VT-13 with a failing installer: the release archive cannot be written where
# the installer downloads it, after its package step (install.sh v3.11.0).
phase_vt13_fail() {
  settle
  install -d -m 0755 "$XUI_ARCHIVE_TMP"
  deploy_yes vt13-fail "$TOOL" deploy --input "$M2_INPUT"
  collect_markers
  expect_rc vt13-fail 1
  expect_clean vt13-fail
  expect_report vt13-fail PASS "${FETCH_ITEMS[@]}"
  expect_fails vt13-fail
  expect_err vt13-fail '[x] 安装器失败'
  expect_err vt13-fail 'Download x-ui'
  expect_err vt13-fail '[x] 第 3 步未完成'
  if grep -qE '^\[[A-Z]+\] xui\.install ' "$phase_dir/vt13-fail.out"; then
    fail 'vt13-fail: the failed installer was reported as finished'
  fi
  expect_no_secret vt13-fail
  expect_no_tmp vt13-fail
  scan_markers
}

# vt15_inject CASE: the change of VT-15, made by the driver through the real
# API with the install token, between steps 4 and 5 (detailed design 19).
# shellcheck disable=SC2031 # runs inside deploy_fn, where the module sets these
vt15_inject() {
  local id
  jq -n '{enable: true, remark: "vt15", listen: "127.0.0.1", port: 8443, protocol: "vless",
    settings: {clients: [], decryption: "none", encryption: "none"},
    streamSettings: {network: "tcp", security: "none"}, sniffing: {enabled: false}}' >"$VPS_TMP/vt15-inbound.json"
  case "$1" in
    inbound)
      api_write POST inbounds/add "$VPS_TMP/vt15-inbound.json" application/json '(.id | type) == "number"' ||
        driver_fail "inbounds/add: $? (HTTP $VPS_API_HTTP)"
      ;;
    client)
      # A user needs an inbound: add both, detach the user, delete the inbound.
      api_write POST inbounds/add "$VPS_TMP/vt15-inbound.json" application/json '(.id | type) == "number"' ||
        driver_fail "inbounds/add: $? (HTTP $VPS_API_HTTP)"
      id="$(jq '.obj.id' "$VPS_API_OUT")"
      jq -n --argjson id "$id" '{client: {email: "vt15", enable: true, limitIp: 0, totalGB: 0, expiryTime: 0,
        tgId: 0}, inboundIds: [$id]}' >"$VPS_TMP/vt15-client.json"
      api_write POST clients/add "$VPS_TMP/vt15-client.json" application/json true ||
        driver_fail "clients/add: $? (HTTP $VPS_API_HTTP)"
      jq -n --argjson id "$id" '{inboundIds: [$id]}' >"$VPS_TMP/vt15-detach.json"
      api_write POST clients/vt15/detach "$VPS_TMP/vt15-detach.json" application/json true ||
        driver_fail "detach: $? (HTTP $VPS_API_HTTP)"
      api_write POST "inbounds/del/$id" '' '' true || driver_fail "inbounds/del: $? (HTTP $VPS_API_HTTP)"
      ;;
    settings)
      api_read POST setting/all 'type == "object"' || driver_fail "setting/all (HTTP $VPS_API_HTTP)"
      jq --argjson view "$VPS_VIEW_KEYS" '.obj | delpaths([$view[] | [.]]) | .subDomain = "other.proxy.example"' \
        "$VPS_API_OUT" >"$VPS_TMP/vt15-settings.json"
      api_write POST setting/update "$VPS_TMP/vt15-settings.json" application/json true ||
        driver_fail "setting/update: $? (HTTP $VPS_API_HTTP)"
      ;;
    *) driver_fail "unknown case $1" ;;
  esac
}

# The driver of VT-15, run through deploy_fn: the real steps 2 to 4, the
# change, database digests with a control pair, then the real step 5, which
# must refuse.
# shellcheck disable=SC2031 # runs inside deploy_fn, where the module sets these
vt15_steps() {
  trap vps_cleanup EXIT
  # The modules are loaded here already; loading them again in vps_fn would
  # redefine their read-only variables and fail.
  vps_fn() { ("$@"); }
  parse_deploy_args --input "$M2_INPUT"
  load_deploy_inputs
  VPS_PANEL_PORT="$(state_value panel_port)"
  vps_tmp_init
  deploy_prefetch
  deploy_install || driver_fail "the installer exited with $?"
  deploy_verify_install
  install_result_read || driver_fail "install result: $VPS_REASON"
  vt15_inject "$1"
  sleep 5
  db_digest "$phase_dir/db-vt15-c1.json"
  sleep 10
  db_digest "$phase_dir/db-vt15-before.json"
  printf '== step 5\n'
  deploy_prewrite
  driver_fail 'step 5 did not stop'
}

# VT-15 CASE ITEM: step 5 refuses with only ITEM failing, before any write and
# without the API reads that can write; the database is unchanged and the
# input and install result are kept.
vt15_case() {
  local name="vt15-$1" db
  settle
  capture "$name" deploy_fn vt15_steps "$1"
  db_digest "$phase_dir/db-vt15-after.json"
  collect_markers
  expect_rc "$name" 1
  expect_clean "$name"
  expect_err "$name" '[x] 第 5 步未完成'
  expect_fails "$name" "$2"
  if sed -n '/^== step 5$/,$p' "$phase_dir/$name.out" | grep -qE '^\[[A-Z]+\] (install\.result|api\.token|keys\.|write\.)'; then
    fail "$name: step 5 went on after the refusal"
  fi
  for db in c1 before after; do
    jq -e '.state == "ro"' "$phase_dir/db-vt15-$db.json" >/dev/null || fail "$name: digest $db not taken read-only"
  done
  dbcmp vt15-before vt15-after vt15-c1 vt15-before || fail "$name: the database changed in step 5"
  [ -s "$XUI_RESULT" ] || fail "$name: the install result is gone"
  [ -s "$M2_INPUT" ] || fail "$name: the input file is gone"
  expect_no_secret "$name"
  expect_no_tmp "$name"
  scan_markers
}

phase_vt15_inbound() { vt15_case inbound fresh.inbounds; }
phase_vt15_client() { vt15_case client fresh.clients; }
phase_vt15_settings() { vt15_case settings fresh.settings; }

# The driver of VT-18 for users, run through deploy_fn: the whole deploy, with
# the request function replaced so that the second clients/add is refused
# (MODE refused), or is sent and its response lost (MODE lost) (detailed
# design 19). The confirmation is answered on stdin.
# shellcheck disable=SC2031 # runs inside deploy_fn, where the module sets these
vt18_users() {
  trap vps_cleanup EXIT
  VT18_MODE="$1"
  VT18_N=0
  eval "vt18_api_call() $(declare -f api_call | sed 1d)"
  # shellcheck disable=SC2329 # replaces the function of the module
  api_call() {
    if [ "$2" = clients/add ]; then
      VT18_N=$((VT18_N + 1))
      if [ "$VT18_N" -eq 2 ] && [ "$VT18_MODE" = refused ]; then
        VPS_API_OUT="$VPS_TMP/api-response"
        printf '{"success":false,"msg":"vt18","obj":null}\n' >"$VPS_API_OUT"
        VPS_API_HTTP=200
        return 0
      fi
      if [ "$VT18_N" -eq 2 ]; then
        vt18_api_call "$@" || true
        VPS_API_HTTP=000
        return 1
      fi
    fi
    vt18_api_call "$@"
  }
  cmd_deploy --input "$M2_INPUT" <<<yes
}

# vt18_db_users: the users in the database, one per line.
vt18_db_users() {
  local state uri
  state="$(vps_fn xui_db_state)" || fail 'database not readable'
  uri="$(vps_fn xui_db_uri "$state")" || fail 'database not readable'
  python3 - "$uri" <<'PY'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1], uri=True, timeout=5)
for (email,) in con.execute('SELECT email FROM clients ORDER BY id'):
    print(email)
for (protocol,) in con.execute('SELECT protocol FROM inbounds ORDER BY id'):
    print('inbound', protocol)
PY
}

# VT-18 with the second user's request refused or its response lost: the deploy
# stops and says what is written; nothing is undone.
vt18_case() {
  local name="vt18-$1" users
  settle
  capture "$name" deploy_fn vt18_users "$1"
  collect_markers
  expect_rc "$name" 1
  expect_clean "$name"
  expect_err "$name" '[x] 第 6 步未完成'
  expect_err "$name" '已写入：订阅设置、转发入站、REALITY 入站、Xray 模板、使用者 alice；其后的写入未执行'
  expect_err "$name" "$2"
  expect_fails "$name" write.clients
  users="$(vt18_db_users)"
  printf '%s\n' "$users" >"$phase_dir/$name-db.txt"
  [ "$users" = "$3" ] || fail "$name: the database holds [$(tr '\n' ' ' <<<"$users")]"
  vt16_db "$name-partial" off >/dev/null || true
  expect_no_secret "$name"
  expect_no_tmp "$name"
  scan_markers
}

phase_vt18_refused() {
  vt18_case refused '创建使用者 bob被拒绝' $'alice\ninbound tunnel\ninbound vless'
}

# A lost response: the user was written, and the deploy says the result is unknown.
phase_vt18_lost() {
  vt18_case lost '创建使用者 bob的结果未知，可能已经写入' $'alice\nbob\ninbound tunnel\ninbound vless'
}

# The drivers of VT-18 for the shortId: the generator replaced by one that
# fails, then by one that prints upper-case hex. Nothing is written before the
# shortId is checked, so the second run starts at step 5 on the same host.
vt18_sid_fail() {
  trap vps_cleanup EXIT
  # shellcheck disable=SC2329 # replaces the function of the module
  new_short_id() { return 1; }
  cmd_deploy --input "$M2_INPUT" <<<yes
}

vt18_sid_upper() {
  trap vps_cleanup EXIT
  # shellcheck disable=SC2329 # replaces the function of the module
  new_short_id() { printf '0123456789ABCDEF\n'; }
  parse_deploy_args --input "$M2_INPUT"
  load_deploy_inputs
  VPS_PANEL_PORT="$(state_value panel_port)"
  vps_tmp_init
  deploy_prewrite
  deploy_write
  driver_fail 'step 6 did not stop'
}

phase_vt18_short_id() {
  local name db
  settle
  for name in vt18-sid-fail vt18-sid-upper; do
    capture "$name" deploy_fn "${name//-/_}"
    collect_markers
    expect_rc "$name" 1
    expect_clean "$name"
    expect_err "$name" '[x] 第 6 步未完成：shortId 生成失败，REALITY 入站未创建。还没有写入业务配置'
    expect_fails "$name" keys.short-id
    db="$(vt18_db_users)"
    [ -z "$db" ] || fail "$name: the database holds [$(tr '\n' ' ' <<<"$db")]"
    expect_no_secret "$name"
    expect_no_tmp "$name"
  done
  scan_markers
}

main "$@"
