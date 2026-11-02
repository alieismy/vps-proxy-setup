#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Guest side of the M2 VM tests (detailed design 9, 19; verification plan
# VT-10 to VT-13, VT-15 to VT-18, VT-20 to VT-31, VT-70, VT-71). Sources
# tests/guest/m1.sh for its helpers and the phases of the main configuration; tests/vm.py runs one phase per SSH session. The
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
readonly FINISH_ITEMS=(finish.restart finish.sub finish.handoff finish.token finish.record finish.cleanup)
readonly XRAY_CONFIG=/usr/local/x-ui/bin/config.json
readonly HANDOFF=/etc/vps-proxy-setup/handoff
readonly DEPLOY_CONF=/etc/vps-proxy-setup/deploy.conf
readonly TARGET_RECORD=/etc/vps-proxy-setup/target-check/target.example
# The copy of the install result that keeper_start keeps (collect_markers reads it).
readonly RESULT_COPY="$PRIVATE/install-result.env"

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

# Step 7 deletes the install result. A copy kept while it exists gives the
# leak markers and the token that VT-17 must see refused.
KEEPER_PID=''
keeper_start() {
  rm -f "$RESULT_COPY" "$RESULT_COPY.tmp"
  (
    while :; do
      if [ -s "$XUI_RESULT" ] && cp "$XUI_RESULT" "$RESULT_COPY.tmp" 2>/dev/null; then
        mv -f "$RESULT_COPY.tmp" "$RESULT_COPY"
      fi
      sleep 1
    done
  ) &
  KEEPER_PID=$!
}

keeper_stop() {
  kill "$KEEPER_PID" 2>/dev/null || true
  wait "$KEEPER_PID" 2>/dev/null || true
  rm -f "$RESULT_COPY.tmp"
  [ -s "$RESULT_COPY" ] || fail 'no copy of the install result was kept'
}

# token_http: the HTTP status the install token gets now, on the path that
# step 5 read with it.
token_http() {
  local port base token
  port="$(sed -n 's/^XUI_PANEL_PORT=//p' "$RESULT_COPY")"
  base="$(sed -n 's/^XUI_WEB_BASE_PATH=//p' "$RESULT_COPY")"
  token="$(sed -n 's/^XUI_API_TOKEN=//p' "$RESULT_COPY")"
  {
    printf 'url = "http://127.0.0.1:%s/%s/panel/api/setting/apiTokens"\n' "$port" "${base#/}"
    printf 'header = "Authorization: Bearer %s"\n' "$token"
  } | curl -q -s --noproxy '*' --max-time 30 -o /dev/null -w '%{http_code}' -K - || true
}

# vt17_judge NAME: VT-17 after a complete step 7, judged here rather than from
# the tool's items: the install token is refused and has no row; the install
# result and the input file are gone; the handoff is a root 0600 file with the
# panel credentials and each user's addresses; the subscription server
# listens on loopback only; deploy.conf holds the keys of detailed design 2.8.
# Only judgments are archived.
vt17_judge() {
  local name="$1" code state uri
  [ ! -e "$XUI_RESULT" ] || fail "$name: the install result is still there"
  [ ! -e "$M2_INPUT" ] || fail "$name: the input file is still there"
  code="$(token_http)"
  [ "$code" = 401 ] || fail "$name: the install token got HTTP $code"
  [ "$(vps_fn port_state 2096)" = loopback ] || fail "$name: the subscription server listens beyond loopback"
  [ "$(stat -c '%F|%u|%a' /etc/vps-proxy-setup)" = 'directory|0|700' ] ||
    fail "$name: /etc/vps-proxy-setup is not a root directory with mode 0700"
  state="$(vps_fn xui_db_state)" || fail "$name: database not readable"
  uri="$(vps_fn xui_db_uri "$state")" || fail "$name: database not readable"
  python3 - "$uri" "$HANDOFF" "$DEPLOY_CONF" "$RESULT_COPY" "$TARGET_RECORD" "$(tool_version)" \
    "$(vps_fn pin_value VPS_PIN_XUI_VERSION)" "$(vps_fn pin_value VPS_PIN_CLOUDFLARED_VERSION)" \
    >"$phase_dir/$name-vt17.txt" <<'PY' || { cat "$phase_dir/$name-vt17.txt"; fail "$name: VT-17 checks failed"; }
import json, os, re, sqlite3, stat, sys

uri, handoff, conf, result, record, tool, xui, cfd = sys.argv[1:9]
lines, fails = [], []


def check(ok, what):
    lines.append(('PASS ' if ok else 'FAIL ') + what)
    if not ok:
        fails.append(what)


def root_0600(path):
    st = os.lstat(path)
    return stat.S_ISREG(st.st_mode) and st.st_uid == 0 and stat.S_IMODE(st.st_mode) == 0o600


def pairs(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            key, _, value = line.rstrip('\n').partition('=')
            out.setdefault(key, value)
    return out


con = sqlite3.connect(uri, uri=True, timeout=5)
check(con.execute('SELECT count(*) FROM api_tokens').fetchone()[0] == 0, 'database: no API token left')
paths = dict(con.execute("SELECT key, value FROM settings WHERE key IN ('subPath', 'subClashPath')").fetchall())
clients = con.execute('SELECT email, sub_id FROM clients ORDER BY id').fetchall()
con.close()


def url(key, sub_id):
    return 'https://sub.proxy.example/' + paths.get(key, '').strip('/') + '/' + sub_id


res = pairs(result)
check(root_0600(handoff), 'handoff: a root file with mode 0600')
with open(handoff) as fh:
    h = json.load(fh)
p = h.get('panel') or {}
check(set(h) == {'format', 'panel', 'users'} and h['format'] == 1
      and set(p) == {'username', 'password', 'webBasePath', 'port'}, 'handoff: format 1 with the fields of 15.2')
check(p.get('username') == res.get('XUI_USERNAME') and p.get('password') == res.get('XUI_PASSWORD'),
      'handoff: the panel credentials of the install result')
check(p.get('webBasePath') == '/' + res.get('XUI_WEB_BASE_PATH', '').strip('/') + '/'
      and p.get('port') == int(res.get('XUI_PANEL_PORT', '0')), 'handoff: webBasePath and panel port')
want = [{'email': e, 'subscriptionUrl': url('subPath', s), 'mihomoUrl': url('subClashPath', s)} for e, s in clients]
check([e for e, _ in clients] == ['alice', 'bob'] and h.get('users') == want,
      "handoff: each user's two addresses under https://<sub_host>/ with the kept paths")

check(root_0600(conf), 'deploy.conf: a root file with mode 0600')
rec = pairs(conf)
expect = {'tool_version': tool, 'xui_version': xui, 'cloudflared_version': cfd, 'mode': 'deploy',
          'sub_host': 'sub.proxy.example', 'node_ip': '192.0.2.1', 'target': 'target.example',
          'target_check_time': pairs(record).get('time'), 'ipv6_ai_egress': 'off'}
check(set(rec) == set(expect) | {'deployed_at'} and all(rec[k] == v for k, v in expect.items()),
      'deploy.conf: the keys of detailed design 2.8 with the values of this deploy')
check(re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', rec.get('deployed_at', '')) is not None,
      'deploy.conf: deployed_at in UTC')
print(''.join(line + '\n' for line in lines), end='')
sys.exit(1 if fails else 0)
PY
  log "$name: VT-17 checks passed"
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

# VT-10, VT-16 and VT-17 through the deploy entry; VT-13 on its output.
phase_vt10() {
  local port tuning out
  settle
  port="$(state_value panel_port)"
  tuning="$(sha256sum <"$TUNING_DROPIN")"
  keeper_start
  deploy_yes vt10 "$TOOL" deploy --input "$M2_INPUT"
  keeper_stop
  collect_markers
  expect_rc vt10 1
  expect_clean vt10
  expect_err vt10 '输入 yes 继续'
  expect_err vt10 '[x] 第 1～7 步完成'
  expect_report vt10 PASS "${PREFLIGHT_PASS[@]}" "${FETCH_ITEMS[@]}" "${INSTALL_ITEMS[@]}" "${PREWRITE_ITEMS[@]}" \
    "${WRITE_ITEMS[@]}" "${FINISH_ITEMS[@]}"
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
  vt17_judge vt10
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
    # The rules of the default template of 3X-UI v3.11.0 (detailed design 17). Every
    # template save keeps the api rule first (EnsureStatsRouting).
    default = [{'inboundTag': ['api'], 'outboundTag': 'api', 'type': 'field'},
               {'ip': ['geoip:private'], 'outboundTag': 'blocked', 'type': 'field'},
               {'outboundTag': 'blocked', 'protocol': ['bittorrent'], 'type': 'field'}]
    check(rules[:1] == default[:1] and rules[1:5] == want,
          'template: the api rule, then rules 1 to 4 of solution design 7.4 with the real tags')
    if ipv6 == 'off':
        check(rules[5:] == default[1:], 'template: the other default rules follow')
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
check(((cfg.get('routing') or {}).get('rules') or [])[:5] == tpl['routing']['rules'][:5],
      'generated: the api rule and rules 1 to 4 as in the template')
check([o.get('tag') for o in cfg.get('outbounds') or []][:1] == ['direct'], 'generated: direct first')
sys.exit(1 if fails else 0)
PY
}

# vt16_judge NAME IPV6: the database, then the generated configuration. 3X-UI
# may give new users to the running Xray without rewriting the file, and the
# panel restart of step 7 does not restart Xray (SIGHUP, main.go), so the file
# is judged after a restart of x-ui; the count before is kept as evidence.
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

# The driver of VT-17 for the token, run through deploy_fn: the whole deploy,
# with the request function replaced so that the response to the token delete
# is lost, after the request was sent (MODE lost) or without sending it (MODE
# unsent) (detailed design 19). The confirmation is answered on stdin.
# shellcheck disable=SC2031,SC2034 # runs inside deploy_fn; the module reads VPS_VERSION
vt17_token() {
  trap vps_cleanup EXIT
  VPS_VERSION="$(tool_version)"
  VT17_MODE="$1"
  eval "vt17_api_call() $(declare -f api_call | sed 1d)"
  # shellcheck disable=SC2329 # replaces the function of the module
  api_call() {
    if [[ "$2" == setting/apiTokens/delete/* ]]; then
      [ "$VT17_MODE" = unsent ] || vt17_api_call "$@" || true
      VPS_API_HTTP=000
      return 1
    fi
    vt17_api_call "$@"
  }
  cmd_deploy --input "$M2_INPUT" <<<yes
}

# A lost response to a delete that took effect: step 7 proves the revocation
# by the refused token and the missing row, and completes.
phase_vt17_lost() {
  local name=vt17-lost
  settle
  keeper_start
  capture "$name" deploy_fn vt17_token lost
  keeper_stop
  collect_markers
  expect_rc "$name" 1
  expect_clean "$name"
  expect_err "$name" '[x] 第 1～7 步完成'
  expect_report "$name" PASS "${WRITE_ITEMS[@]}" "${FINISH_ITEMS[@]}"
  expect_fails "$name"
  vt17_judge "$name"
  expect_no_secret "$name"
  expect_no_tmp "$name"
  scan_markers
}

# A lost response to a delete that never arrived: the token still works, so
# step 7 must not call it revoked; it stops and keeps the install result and
# the input file (detailed design 15.3).
phase_vt17_unsent() {
  local name=vt17-unsent code
  settle
  keeper_start
  capture "$name" deploy_fn vt17_token unsent
  keeper_stop
  collect_markers
  expect_rc "$name" 1
  expect_clean "$name"
  expect_err "$name" '[x] 第 7 步未完成：安装 token 的撤销结果未知'
  expect_report "$name" PASS finish.restart finish.sub finish.handoff
  expect_fails "$name" finish.token
  code="$(token_http)"
  [ "$code" = 200 ] || fail "$name: the install token got HTTP $code; it should still be valid"
  [ -s "$XUI_RESULT" ] || fail "$name: the install result is gone"
  [ -s "$M2_INPUT" ] || fail "$name: the input file is gone"
  [ -s "$HANDOFF" ] || fail "$name: no handoff"
  [ ! -e "$DEPLOY_CONF" ] || fail "$name: deploy.conf was written"
  expect_no_secret "$name"
  expect_no_tmp "$name"
  scan_markers
}

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

# VT-18, continued: the documented cleanup (solution design 7.3), after which
# the preflight passes with 90-proxy-vps.conf in place, a new deploy completes
# and the strict verification of vps-tuning passes. Removing
# /etc/vps-proxy-setup also removes the target-check result, so target-check
# runs again against the stand-in, as the preflight asks.
vt18_redeploy() {
  local tuning saved="$PRIVATE/90-proxy-vps.conf"
  tuning="$(sha256sum <"$TUNING_DROPIN")"
  cp -p "$TUNING_DROPIN" "$saved"
  printf 'y\n' | x-ui uninstall >"$phase_dir/vt18-uninstall.txt" 2>&1 || true
  [ ! -e /usr/local/x-ui ] && [ ! -e /etc/x-ui ] || fail 'vt18: x-ui uninstall left 3X-UI behind'
  install -d -m 0755 "${TUNING_DROPIN%/*}"
  cp -p "$saved" "$TUNING_DROPIN"
  rm -rf /etc/vps-proxy-setup
  systemctl daemon-reload
  [ "$(sha256sum <"$TUNING_DROPIN")" = "$tuning" ] || fail 'vt18: 90-proxy-vps.conf was not restored'

  netns_pair vpsns-standin vps-standin0 198.51.100.1 "$STANDIN"
  standin strict
  capture vt18-target-check "$TOOL" target-check target.example
  expect_rc vt18-target-check 0
  write_input "$M2_INPUT"
  # The preflight alone: end of file at the confirmation cancels.
  capture_tty vt18-preflight "$TOOL" deploy --input "$M2_INPUT"
  expect_rc vt18-preflight 1
  expect_err vt18-preflight '[x] 已取消，主机未改动'
  expect_report vt18-preflight PASS "${PREFLIGHT_PASS[@]}"
  expect_fails vt18-preflight

  keeper_start
  deploy_yes vt18-redeploy "$TOOL" deploy --input "$M2_INPUT"
  keeper_stop
  # The secrets of the first deploy stay markers too.
  cp "$PRIVATE/markers" "$PRIVATE/markers-first"
  collect_markers
  sort -u -o "$PRIVATE/markers" "$PRIVATE/markers" "$PRIVATE/markers-first"
  expect_rc vt18-redeploy 1
  expect_clean vt18-redeploy
  expect_err vt18-redeploy '[x] 第 1～7 步完成'
  expect_report vt18-redeploy PASS "${FETCH_ITEMS[@]}" "${INSTALL_ITEMS[@]}" "${PREWRITE_ITEMS[@]}" \
    "${WRITE_ITEMS[@]}" "${FINISH_ITEMS[@]}"
  expect_fails vt18-redeploy
  vt16_db vt18-redeploy off >/dev/null || fail 'vt18-redeploy: VT-16 database checks failed'
  vt17_judge vt18-redeploy
  [ "$(sha256sum <"$TUNING_DROPIN")" = "$tuning" ] || fail 'vt18-redeploy: 90-proxy-vps.conf changed'
  capture vt18-tuning-strict env REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS=x-ui.service dvt verify
  expect_rc vt18-tuning-strict 0
  expect_no_secret vt18-redeploy
  expect_no_tmp vt18-redeploy
  scan_markers
}

phase_vt18_refused() {
  vt18_case refused '创建使用者 bob被拒绝' $'alice\ninbound tunnel\ninbound vless'
  vt18_redeploy
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

# --- VT-70 and VT-71 at M2 (detailed design 9.6) ------------------------------

# The panel session of the VT-71 drivers. Step 7 revokes the install token, so
# the drivers log in with the credentials of the handoff file, as the
# administrator would (verification plan 2). At the fixed commit, GET
# <webBasePath>csrf-token starts a session and returns its CSRF token; POST
# <webBasePath>login takes the form fields username and password with that
# token in X-CSRF-Token; the session keeps the token after the login, and the
# API accepts the session cookie, with the token on unsafe methods
# (internal/web/controller/index.go, controller/api.go, session/csrf.go).
# The credentials, webBasePath and token stay in $PRIVATE and reach curl as a
# config on stdin, never as arguments.
readonly PANEL_JAR="$PRIVATE/panel-cookies"
readonly PANEL_OUT="$PRIVATE/panel-response.json"
PANEL_HTTP=000

# panel_request PATH EXTRA_CONFIG [CURL_ARGS...]: one request to the panel on
# loopback in the session; EXTRA_CONFIG, when not empty, is a private file of
# further config lines. Sets PANEL_HTTP; the response is in PANEL_OUT.
panel_request() {
  local path="$1" extra="$2" code
  shift 2
  rm -f "$PANEL_OUT"
  code="$({
    printf 'url = "%s%s"\n' "$(cat "$PRIVATE/panel-base")" "$path"
    if [ -s "$PRIVATE/panel-csrf" ]; then
      printf 'header = "X-CSRF-Token: %s"\n' "$(cat "$PRIVATE/panel-csrf")"
    fi
    if [ -n "$extra" ]; then cat "$extra"; fi
  } | curl -q --silent --noproxy '*' --proto '=http' --connect-timeout 5 --max-time 60 \
    -b "$PANEL_JAR" -c "$PANEL_JAR" -o "$PANEL_OUT" -w '%{http_code}' "$@" -K -)" || code=000
  PANEL_HTTP="$code"
}

panel_login() {
  local port base user pass
  port="$(jq -r '.panel.port' "$HANDOFF")"
  base="$(jq -r '.panel.webBasePath' "$HANDOFF")"
  user="$(jq -r '.panel.username' "$HANDOFF")"
  pass="$(jq -r '.panel.password' "$HANDOFF")"
  # Plain forms only, so that nothing needs quoting in the curl config.
  [[ "$port" =~ ^[0-9]+$ && "$base" =~ ^/[A-Za-z0-9]+/$ && "$user" =~ ^[A-Za-z0-9]+$ && "$pass" =~ ^[A-Za-z0-9]+$ ]] ||
    driver_fail 'the panel fields of the handoff are not in the expected plain form'
  printf 'http://127.0.0.1:%s%s' "$port" "$base" >"$PRIVATE/panel-base"
  rm -f "$PANEL_JAR" "$PRIVATE/panel-csrf"
  panel_request csrf-token ''
  { [ "$PANEL_HTTP" = 200 ] &&
    jq -e '.success == true and (.obj | type == "string" and test("^[A-Za-z0-9_=+/.-]+$"))' "$PANEL_OUT" >/dev/null; } ||
    driver_fail "csrf-token: HTTP $PANEL_HTTP"
  jq -j '.obj' "$PANEL_OUT" >"$PRIVATE/panel-csrf"
  printf 'data-urlencode = "username=%s"\ndata-urlencode = "password=%s"\n' "$user" "$pass" >"$PRIVATE/panel-login"
  panel_request login "$PRIVATE/panel-login"
  rm -f "$PRIVATE/panel-login"
  { [ "$PANEL_HTTP" = 200 ] && jq -e '.success == true' "$PANEL_OUT" >/dev/null; } ||
    driver_fail "login: HTTP $PANEL_HTTP or refused"
  log 'logged in to the panel with the handoff credentials'
}

# panel_api METHOD PATH [BODY_FILE [CONTENT_TYPE]]: one API request in the
# session; HTTP 200 with success true, or the driver fails.
panel_api() {
  local method="$1" path="$2" body="${3-}" ctype="${4-application/json}"
  local -a data=()
  [ -z "$body" ] || data=(-H "Content-Type: $ctype" --data-binary "@$body")
  panel_request "panel/api/$path" '' -X "$method" "${data[@]}"
  { [ "$PANEL_HTTP" = 200 ] && jq -e '.success == true' "$PANEL_OUT" >/dev/null 2>&1; } ||
    driver_fail "$method $path: HTTP $PANEL_HTTP, success $(jq -c '.success' "$PANEL_OUT" 2>/dev/null || echo '?')"
  printf '%s %s: HTTP %s, success\n' "$method" "$path" "$PANEL_HTTP" >>"$phase_dir/api.txt"
}

# panel_setting FILTER: all settings read, changed by the jq FILTER and
# written back whole, as at M1 (setting/update is not a PATCH, 15.1).
panel_setting() {
  panel_api POST setting/all
  jq -c ".obj | $1" "$PANEL_OUT" >"$PRIVATE/setting-update.json"
  panel_api POST setting/update "$PRIVATE/setting-update.json"
}

# inbound_edit PROTOCOL FILTER: the deployed inbound with that protocol, as the
# list returns it, changed by the jq FILTER and posted back whole, as the
# panel's form does. On this path upstream keeps the stored users and the
# enable flag (UpdateInbound in internal/web/service/inbound.go).
inbound_edit() {
  local id
  panel_api GET inbounds/list
  id="$(jq -r --arg p "$1" '[.obj[] | select(.protocol == $p) | .id] | if length == 1 then .[0] else "" end' \
    "$PANEL_OUT")"
  [ -n "$id" ] || driver_fail "not one $1 inbound"
  jq --argjson id "$id" ".obj[] | select(.id == \$id) | del(.clientStats) | $2" "$PANEL_OUT" \
    >"$PRIVATE/inbound-update.json"
  panel_api POST "inbounds/update/$id" "$PRIVATE/inbound-update.json"
}

# inbound_id PROTOCOL: sets INBOUND_ID to the deployed inbound with that protocol.
INBOUND_ID=''
inbound_id() {
  panel_api GET inbounds/list
  INBOUND_ID="$(jq -r --arg p "$1" '[.obj[] | select(.protocol == $p) | .id] | if length == 1 then .[0] else "" end' \
    "$PANEL_OUT")"
  [ -n "$INBOUND_ID" ] || driver_fail "not one $1 inbound"
}

# client_edit EMAIL FILTER: the user as clients/get returns it, changed by the
# jq FILTER and posted back to clients/update. clients/get returns the stored
# record, whose id (a number), reverse and allowedIPs (strings) do not bind
# to the client that clients/update takes, so they are left out; without id
# the panel keeps the stored UUID, and without keepAlive the stored value.
client_edit() {
  panel_api GET "clients/get/$1"
  jq ".obj.client | del(.id, .uuid, .reverse, .allowedIPs, .keepAlive) | $2" "$PANEL_OUT" \
    >"$PRIVATE/client-update.json"
  panel_api POST "clients/update/$1" "$PRIVATE/client-update.json"
}

# template_edit FILTER: the Xray template changed by the jq FILTER and saved
# through xray/update, as deploy step 6 writes it. The save restarts Xray when
# it runs (15.1).
template_edit() {
  panel_api POST xray/
  jq '.obj | fromjson' "$PANEL_OUT" >"$PRIVATE/template-read.json"
  jq -rn --slurpfile r "$PRIVATE/template-read.json" '"xraySetting=" + ($r[0].xraySetting | '"$1"' | tojson | @uri)
    + "&outboundTestUrl=" + ($r[0].outboundTestUrl | @uri)' >"$PRIVATE/template-form"
  panel_api POST xray/update "$PRIVATE/template-form" application/x-www-form-urlencoded
}

# wait_port PORT STATE: until port_state of the tool prints STATE. 90 s: a
# change that the running core does not take is applied by the panel's job
# that restarts Xray every 30 seconds when a restart is pending.
wait_port() {
  local i
  for i in $(seq 90); do
    [ "$(vps_fn port_state "$1")" != "$2" ] || return 0
    sleep 1
  done
  driver_fail "port $1 did not become $2"
}

# m2_check NAME: one check run in the current state; tests/vm.py judges it.
m2_check() {
  capture "$1" "$TOOL" check
  expect_rc "$1" 1
  expect_clean "$1"
  expect_no_secret "$1"
}

# VT-70 right after a complete deploy, in the same boot. This disk is the
# base of the baseline and of each VT-71 injection.
phase_vt70_deploy() {
  settle
  keeper_start
  deploy_yes vt70-deploy "$TOOL" deploy --input "$M2_INPUT"
  keeper_stop
  collect_markers
  expect_rc vt70-deploy 1
  expect_clean vt70-deploy
  expect_err vt70-deploy '[x] 第 1～7 步完成'
  expect_fails vt70-deploy
  expect_no_secret vt70-deploy
  wait_xui_stable
  m2_check check
  scan_markers
}

# The baseline of VT-71 at M2, after a new boot of the deployed disk, as in
# each injection: check between state snapshots, so the run also shows that it
# leaves the deployed host as it was; and the listeners of 443 by address
# family, for listen.reality (DO-2).
phase_vt70() {
  settle
  wait_xui_stable
  collect_markers
  observe check m2_check
  { ss -Hltne -4 'sport = :443'; echo '== -6'; ss -Hltne -6 'sport = :443'; } >"$phase_dir/listen-443.txt" 2>&1
  scan_markers
}

# One VT-71 injection of M2 on its own overlay of the deployed disk (detailed
# design 9.6); tests/vm.py compares the check result with the baseline.
phase_vt71() {
  local name="$1"
  settle
  wait_xui_stable
  case "$name" in
    install-result | state-perms | record-node-ip) ;;
    *) panel_login ;;
  esac
  case "$name" in
    inbound-extra)
      jq -n '{enable: true, remark: "vt71", listen: "127.0.0.1", port: 8443, protocol: "vless",
        settings: {clients: [], decryption: "none", encryption: "none"},
        streamSettings: {network: "tcp", security: "none"}, sniffing: {enabled: false}}' >"$PRIVATE/vt71-inbound.json"
      panel_api POST inbounds/add "$PRIVATE/vt71-inbound.json"
      ;;
    reality-disabled)
      inbound_id vless
      printf '{"enable":false}\n' >"$PRIVATE/vt71-enable.json"
      panel_api POST "inbounds/setEnable/$INBOUND_ID" "$PRIVATE/vt71-enable.json"
      wait_port 443 none
      ;;
    server-names) inbound_edit vless '.streamSettings.realitySettings.serverNames += ["other.example"]' ;;
    share-host) inbound_edit vless '.shareAddr = "node.example"' ;;
    exclude-sub) inbound_edit vless '.excludeFromSub = true' ;;
    host-domain)
      inbound_id vless
      jq -n --argjson id "$INBOUND_ID" '{inboundIds: [$id], hosts: ["cdn.example"], remark: "vt71",
        security: "same"}' >"$PRIVATE/vt71-host.json"
      panel_api POST hosts/add "$PRIVATE/vt71-host.json"
      ;;
    forwarder-dest) inbound_edit tunnel '.sniffing.destOverride = ["tls", "http"]' ;;
    forwarder-target) inbound_edit tunnel '.settings.rewriteAddress = "target.example" | .sniffing.routeOnly = true' ;;
    forwarder-listen)
      inbound_edit tunnel '.listen = "0.0.0.0"'
      wait_port 20443 exposed
      ;;
    rules-order) template_edit '.routing.rules |= .[:1] + [.[2], .[1]] + .[3:]' ;;
    rules-cn) template_edit '.routing.rules |= del(.[3])' ;;
    outbound-blocked)
      template_edit '.outbounds |= map(if .tag == "blocked" then {tag, protocol: "freedom"} else . end)'
      ;;
    api-listen)
      template_edit '.inbounds |= map(if .tag == "api" then .listen = "0.0.0.0" else . end)'
      wait_port 62789 exposed
      ;;
    metrics-listen)
      template_edit '.metrics.listen = "0.0.0.0:11111"'
      wait_port 11111 exposed
      ;;
    client-flow) client_edit bob '.flow = ""' ;;
    client-limit-ip) client_edit alice '.limitIp = 2' ;;
    sub-listen)
      panel_setting '.subListen = "0.0.0.0"'
      panel_api POST setting/restartPanel
      wait_port 2096 exposed
      ;;
    sub-domain) panel_setting '.subDomain = ""' ;;
    sub-uri) panel_setting '.subURI = "https://other.proxy.example" + .subPath' ;;
    sub-clash) panel_setting '.subClashEnableRouting = false' ;;
    sub-remark) panel_setting '.remarkTemplate = "{{INBOUND}}-{{EMAIL}}"' ;;
    api-token)
      printf '{"name":"vt71","scope":"monitor"}\n' >"$PRIVATE/vt71-token.json"
      panel_api POST setting/apiTokens/create "$PRIVATE/vt71-token.json"
      ;;
    install-result) install -m 0600 /dev/null "$XUI_RESULT" ;;
    state-perms) chmod 0644 "$DEPLOY_CONF" ;;
    record-node-ip) sed -i 's/^node_ip=.*/node_ip=192.0.2.9/' "$DEPLOY_CONF" ;;
    *) fail "unknown injection: $name" ;;
  esac
  # Xray applies inbound and template changes after the response: wait for
  # the listeners that the injection does not move.
  [ "$name" = reality-disabled ] || wait_port 443 exposed
  [ "$name" = forwarder-listen ] || wait_port 20443 loopback
  wait_xui_stable
  collect_markers
  m2_check check
  scan_markers
}

# ---------------------------------------------------------------------------
# REALITY and the forwarding boundary: VT-20 to VT-29 (detailed design 9.7,
# 17; verification plan 3.3, 3.6, 4.4). The probes come from the client
# namespace to the node address on 443.

readonly MIHOMO_GZ="$FIXTURES/mihomo-linux-amd64-compatible-v1.19.33.gz"
readonly MIHOMO=/opt/vps-mihomo/mihomo
readonly XRAY_ACCESS=/var/log/x-ui/access.log
readonly NODE_IP=192.0.2.1
readonly SUB_PORT=2096
# The test exception of verification plan 3.6: the direct outbound lets the
# stand-in through, ahead of the template's geoip:private block.
readonly STANDIN_RULE='{"action":"allow","ip":["198.51.100.2"]}'

phase_sni_deploy() {
  settle
  keeper_start
  deploy_yes sni-deploy "$TOOL" deploy --input "$M2_INPUT"
  keeper_stop
  collect_markers
  expect_rc sni-deploy 1
  expect_clean sni-deploy
  expect_err sni-deploy '[x] 第 1～7 步完成'
  expect_fails sni-deploy
  expect_no_secret sni-deploy
  wait_xui_stable
  scan_markers
}

# xray_tag PORT: the tag of the inbound on PORT in the generated config.
xray_tag() {
  jq -r --argjson p "$1" '[.inbounds[] | select(.port == $p) | .tag] | if length == 1 then .[0] else "" end' \
    "$XRAY_CONFIG"
}

# sub_get EMAIL FIELD OUT: the user's subscription at the handoff address
# (subscriptionUrl or mihomoUrl), fetched on loopback with the subscription
# host as Host, as deploy step 7 does. The address reaches curl on stdin.
sub_get() {
  local url code
  url="$(jq -r --arg e "$1" --arg f "$2" '.users[] | select(.email == $e) | .[$f]' "$HANDOFF")"
  [[ "$url" =~ ^https://([a-z0-9.-]+)(/[A-Za-z0-9/_-]+)$ ]] || driver_fail "$2 of $1 is not in the expected form"
  code="$({
    printf 'url = "http://127.0.0.1:%s%s"\n' "$SUB_PORT" "${BASH_REMATCH[2]}"
    printf 'header = "Host: %s"\n' "${BASH_REMATCH[1]}"
  } | curl -q --silent --noproxy '*' --proto '=http' --max-time 30 -o "$3" -w '%{http_code}' -K -)" || code=000
  [ "$code" = 200 ] || driver_fail "$2 of $1: HTTP $code"
}

# mihomo_up NAME PORT [drop-mlkem]: Mihomo in the client namespace with the
# proxies of alice's Mihomo subscription as they are (without
# support-x25519mlkem768 for drop-mlkem), in global mode with GLOBAL set to
# her node, so that no client rule decides the outcome (verification plan
# 3.6). Mixed port PORT, controller PORT+2000, both on loopback of the
# namespace. The configuration holds her UUID, so it stays private.
mihomo_up() {
  local name="$1" port="$2" dir="$PRIVATE/mihomo-$1" unit="vps-mihomo-$1" i code
  rm -rf "$dir"
  install -d -m 0700 "$dir"
  sub_get alice mihomoUrl "$dir/subscription.yaml"
  python3 - "$dir" "$port" "${3-}" <<'PY' || driver_fail "mihomo $name: no configuration from the subscription"
import json, os, sys
import yaml

d, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(os.path.join(d, 'subscription.yaml'), encoding='utf-8') as f:
    proxies = yaml.safe_load(f)['proxies']
assert len(proxies) == 1, 'not one proxy'
if mode == 'drop-mlkem':
    proxies[0].get('reality-opts', {}).pop('support-x25519mlkem768', None)
conf = {'mixed-port': port, 'allow-lan': False, 'mode': 'global', 'log-level': 'info', 'ipv6': False,
        'external-controller': f'127.0.0.1:{port + 2000}', 'profile': {'store-selected': False},
        'proxies': proxies, 'rules': []}
fd = os.open(os.path.join(d, 'config.yaml'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    yaml.safe_dump(conf, f, allow_unicode=True, sort_keys=False)
with open(os.path.join(d, 'select.json'), 'w', encoding='utf-8') as f:
    json.dump({'name': proxies[0]['name']}, f, ensure_ascii=False)
PY
  systemctl stop "$unit" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemd-run --quiet --unit "$unit" -- ip netns exec vpsns-client "$MIHOMO" -d "$dir"
  for i in $(seq 50); do
    [ -z "$(ip netns exec vpsns-client ss -Hltn "sport = :$((port + 2000))")" ] || break
    [ "$i" -lt 50 ] || driver_fail "mihomo $name did not start"
    sleep 0.3
  done
  code="$(ip netns exec vpsns-client curl -q -s -o /dev/null -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/json' --data-binary "@$dir/select.json" \
    "http://127.0.0.1:$((port + 2000))/proxies/GLOBAL")" || code=000
  [ "$code" = 204 ] || driver_fail "mihomo $name: selecting the node in GLOBAL gave HTTP $code"
  ip netns exec vpsns-client curl -q -s "http://127.0.0.1:$((port + 2000))/proxies/GLOBAL" |
    jq -e --slurpfile s "$dir/select.json" '.now == $s[0].name' >/dev/null ||
    driver_fail "mihomo $name: GLOBAL is not the node"
}

# mihomo_log NAME: Mihomo's log lines (no UUID or key: it names the node and
# the server address) for the evidence.
mihomo_log() {
  journalctl -q -o cat -u "vps-mihomo-$1" >"$phase_dir/mihomo-$1.log" 2>&1 || true
}

# client_curl NAME [CURL_ARGS...]: curl in the client namespace. The body goes
# to NAME.body, curl's stderr to NAME.err; sets CURL_RC and CURL_HTTP.
CURL_RC=0
CURL_HTTP=000
client_curl() {
  local name="$1"
  shift
  CURL_RC=0
  CURL_HTTP="$(ip netns exec vpsns-client curl -q -sS --max-time 20 -o "$phase_dir/$name.body" \
    -w '%{http_code}' "$@" 2>"$phase_dir/$name.err")" || CURL_RC=$?
  printf 'curl exit %s, HTTP %s\n' "$CURL_RC" "${CURL_HTTP:=000}" >"$phase_dir/$name.result"
}

# edge_begin NAME / edge_end: the three places of verification plan 4.4 around
# one case: the new lines of the Xray access log and of the stand-in's
# connection log, and the SYNs to the stand-in on the guest's veth towards it.
EDGE_NAME=''
EDGE_PID=''
EDGE_ACCESS=0
EDGE_STANDIN=0
edge_begin() {
  EDGE_NAME="$1"
  EDGE_ACCESS="$(stat -c %s "$XRAY_ACCESS")"
  EDGE_STANDIN="$(stat -c %s "$EVIDENCE/standin/connections.jsonl")"
  tcpdump -Z root -i vps-standin0 -nn -U -w "$PRIVATE/edge-$1.pcap" "tcp and host $STANDIN" \
    2>"$PRIVATE/edge-$1.err" &
  EDGE_PID=$!
  for _ in $(seq 50); do
    ! grep -q 'listening on' "$PRIVATE/edge-$1.err" || return 0
    sleep 0.2
  done
  driver_fail 'tcpdump did not start'
}

edge_end() {
  local n="$EDGE_NAME"
  # The access log is written as each connection is routed; the stand-in logs
  # a connection when it ends.
  sleep 3
  kill -INT "$EDGE_PID"
  wait "$EDGE_PID" || true
  [ "$(stat -c %s "$XRAY_ACCESS")" -ge "$EDGE_ACCESS" ] || driver_fail "$n: the access log shrank during the case"
  tail -c "+$((EDGE_ACCESS + 1))" "$XRAY_ACCESS" >"$phase_dir/$n-access.txt"
  tail -c "+$((EDGE_STANDIN + 1))" "$EVIDENCE/standin/connections.jsonl" | grep -v '"event"' \
    >"$phase_dir/$n-standin.jsonl" || true
  tcpdump -nn -tt -r "$PRIVATE/edge-$n.pcap" \
    "tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn and dst host $STANDIN" >"$phase_dir/$n-syn.txt" 2>/dev/null
  printf 'access log %s lines, stand-in %s connections, %s SYN to the stand-in\n' \
    "$(grep -c . "$phase_dir/$n-access.txt")" "$(grep -c . "$phase_dir/$n-standin.jsonl")" \
    "$(grep -c . "$phase_dir/$n-syn.txt")" >"$phase_dir/$n-edge.txt"
}

# A forwarder line in the access log names the rewritten destination
# 127.0.0.1:443, which the tunnel inbound sets before sniffing; the dispatcher
# adds only the route. So the route tag is the forwarder's decision on the
# SNI, and the SNI itself is evidenced by the stand-in's log.
#
# edge_blocked NAME: the connection did not cross the boundary. The forwarder
# routed it to blocked, the stand-in has no connection, and no SYN went to
# the stand-in. A client that got nothing is not enough (FR-02).
edge_blocked() {
  local fwd
  fwd="$(xray_tag 20443)"
  grep -qF "[$fwd -> blocked]" "$phase_dir/$1-access.txt" ||
    fail "$1: the access log has no forwarder connection routed to blocked"
  ! grep -qF "[$fwd -> direct]" "$phase_dir/$1-access.txt" || fail "$1: the forwarder routed a connection to direct"
  [ ! -s "$phase_dir/$1-standin.jsonl" ] || fail "$1: the stand-in got a connection"
  [ ! -s "$phase_dir/$1-syn.txt" ] || fail "$1: a SYN went to the stand-in"
}

# The test-environment deviations, through the panel with
# the handoff credentials (verification plan 3.4): the stand-in exception in
# the direct outbound (3.6) and the Xray access log (4.4). Saving the template
# restarts Xray.
phase_sni_prep() {
  local fwd reality
  grep -qE '^443/tcp +ALLOW' <(ufw status) || fail 'UFW does not allow 443/tcp'
  panel_login
  template_edit '.log.access = "'"$XRAY_ACCESS"'"
    | .outbounds |= map(if .tag == "direct" then .settings.finalRules = ['"$STANDIN_RULE"'] + .settings.finalRules
      else . end)'
  wait_port 443 exposed
  wait_port 20443 loopback
  wait_xui_stable
  for _ in $(seq 60); do
    [ ! -e "$XRAY_ACCESS" ] || break
    sleep 1
  done
  jq -e --arg a "$XRAY_ACCESS" --argjson r "$STANDIN_RULE" '.log.access == $a
    and ([.outbounds[] | select(.tag == "direct") | .settings.finalRules[0]] == [$r])' "$XRAY_CONFIG" >/dev/null ||
    fail 'the generated Xray config does not have the access log and the stand-in exception'
  [ -f "$XRAY_ACCESS" ] || fail "Xray did not create $XRAY_ACCESS"
  reality="$(xray_tag 443)"
  fwd="$(xray_tag 20443)"
  [ -n "$reality" ] && [ -n "$fwd" ] || fail 'no single inbound on 443 and on 20443'
  printf '%s\n' "REALITY inbound tag: $reality" "forwarder tag: $fwd" \
    'deviation: the direct outbound lets 198.51.100.2 through first (verification plan 3.6)' \
    "deviation: the Xray access log is on at $XRAY_ACCESS (verification plan 4.4)" \
    'deviation: UFW allows 443/tcp, added with vps-hardening ports (verification plan 3.3)' \
    'deviation: Mihomo runs in global mode with only the proxy of the subscription (verification plan 3.6)' \
    >"$phase_dir/deviations.txt"
  fixture_check
  install -d -m 0755 "${MIHOMO%/*}"
  gunzip -c "$MIHOMO_GZ" >"$MIHOMO.tmp"
  chmod 0755 "$MIHOMO.tmp"
  mv -f "$MIHOMO.tmp" "$MIHOMO"
  "$MIHOMO" -v >"$phase_dir/mihomo-version.txt"
  python3 -c 'import yaml' || fail 'python3-yaml is missing'
  capture client-443 ip netns exec vpsns-client timeout 5 bash -c "exec 3<>/dev/tcp/$NODE_IP/443"
  expect_rc client-443 0
}

# VT-20: alice's Mihomo subscription carries Vision, the chrome fingerprint and
# ML-KEM; with it as is, Mihomo reaches probe.example over the node, in HTTP
# and HTTPS, routed to direct from the REALITY inbound.
phase_vt20() {
  local reality
  reality="$(xray_tag 443)"
  mihomo_up main 7890
  python3 - "$PRIVATE/mihomo-main/subscription.yaml" "$NODE_IP" >"$phase_dir/vt20-proxy.json" <<'PY' ||
import json, sys
import yaml

with open(sys.argv[1], encoding='utf-8') as f:
    p = yaml.safe_load(f)['proxies'][0]
ro = p.get('reality-opts') or {}
summary = {k: p.get(k) for k in ('type', 'server', 'port', 'network', 'tls', 'flow', 'client-fingerprint',
                                 'servername')}
summary['reality-opts keys'] = sorted(ro)
summary['support-x25519mlkem768'] = ro.get('support-x25519mlkem768')
print(json.dumps(summary, ensure_ascii=False, indent=2))
ok = (p.get('type') == 'vless' and p.get('server') == sys.argv[2] and p.get('port') == 443
      and p.get('flow') == 'xtls-rprx-vision' and p.get('client-fingerprint') == 'chrome'
      and p.get('servername') == 'target.example' and ro.get('support-x25519mlkem768') is True
      and {'public-key', 'short-id'} <= set(ro))
sys.exit(0 if ok else 1)
PY
    fail 'VT-20: the proxy of the Mihomo subscription is not as expected'
  edge_begin vt20
  client_curl vt20-http -x http://127.0.0.1:7890 http://probe.example/
  local http_rc="$CURL_RC" http_code="$CURL_HTTP"
  client_curl vt20-https -x http://127.0.0.1:7890 https://probe.example/
  edge_end
  mihomo_log main
  { [ "$http_rc" = 0 ] && [ "$http_code" = 200 ] && grep -qx 'stand-in probe.example' "$phase_dir/vt20-http.body"; } ||
    fail 'VT-20: http://probe.example/ over the node failed'
  { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] &&
    grep -qx 'stand-in probe.example' "$phase_dir/vt20-https.body"; } ||
    fail 'VT-20: https://probe.example/ over the node failed'
  { grep -qF "accepted tcp:probe.example:80 [$reality >> direct]" "$phase_dir/vt20-access.txt" &&
    grep -qF "accepted tcp:probe.example:443 [$reality >> direct]" "$phase_dir/vt20-access.txt"; } ||
    fail 'VT-20: the access log does not show both requests from the REALITY inbound to direct'
  jq -se 'any(.[]; .plain == true and any(.requests[]; .host == "probe.example" and .status == 200))
    and any(.[]; .sni == "probe.example" and any(.requests[]; .status == 200))' \
    "$phase_dir/vt20-standin.jsonl" >/dev/null || fail 'VT-20: the stand-in did not serve probe.example twice'
}

# VT-21: the same proxy without support-x25519mlkem768 does not get through
# (an upstream behaviour, a negative case).
phase_vt21() {
  mihomo_up no-mlkem 7891 drop-mlkem
  edge_begin vt21
  client_curl vt21-http -x http://127.0.0.1:7891 http://probe.example/
  edge_end
  mihomo_log no-mlkem
  systemctl stop vps-mihomo-no-mlkem 2>/dev/null || true
  ! grep -qx 'stand-in probe.example' "$phase_dir/vt21-http.body" 2>/dev/null ||
    fail 'VT-21: probe.example was reached without support-x25519mlkem768'
  ! jq -se 'any(.[]; any(.requests[]; .host == "probe.example"))' "$phase_dir/vt21-standin.jsonl" >/dev/null ||
    fail 'VT-21: the stand-in served probe.example'
}

# VT-22: the node of the subscriptions is the input IPv4 address, and its name
# is the inbound remark, compared as UTF-8 bytes.
phase_vt22() {
  sub_get alice mihomoUrl "$PRIVATE/vt22-mihomo.yaml"
  sub_get alice subscriptionUrl "$PRIVATE/vt22-plain.txt"
  python3 - "$PRIVATE/vt22-mihomo.yaml" "$PRIVATE/vt22-plain.txt" "$NODE_IP" "$REMARK_JP" \
    >"$phase_dir/vt22.txt" <<'PY' || fail 'VT-22: the node address or name is not as expected'
import base64, os, re, sys, urllib.parse
import yaml

mihomo, plain, node = sys.argv[1], sys.argv[2], sys.argv[3]
remark = os.fsencode(sys.argv[4])
with open(mihomo, encoding='utf-8') as f:
    proxies = yaml.safe_load(f)['proxies']
with open(plain, 'rb') as f:
    links = [l for l in base64.b64decode(b''.join(f.read().split())).decode().splitlines() if l.startswith('vless://')]
m = re.match(r'^vless://[^@]+@([^:/?#]+):([0-9]+)\?[^#]*#(.*)$', links[0]) if len(links) == 1 else None
results = {
    'mihomo: one proxy': len(proxies) == 1,
    'mihomo: server is the node IPv4': len(proxies) == 1 and proxies[0].get('server') == node,
    'mihomo: name is the remark (UTF-8 bytes)': len(proxies) == 1 and proxies[0].get('name', '').encode() == remark,
    'plain: one VLESS link': m is not None,
    'plain: host is the node IPv4': m is not None and m.group(1) == node,
    'plain: name is the remark (UTF-8 bytes)': m is not None and urllib.parse.unquote_to_bytes(m.group(3)) == remark,
}
for k, v in results.items():
    print(('PASS ' if v else 'FAIL ') + k)
sys.exit(0 if all(results.values()) else 1)
PY
}

# VT-23: other.example as SNI does not reach the stand-in.
phase_vt23() {
  edge_begin vt23
  client_curl vt23 --resolve "other.example:443:$NODE_IP" https://other.example/
  edge_end
  ! grep -q 'stand-in' "$phase_dir/vt23.body" 2>/dev/null || fail 'VT-23: the client got stand-in content'
  edge_blocked vt23
}

# VT-24: a ClientHello without SNI.
phase_vt24() {
  edge_begin vt24
  ip netns exec vpsns-client timeout 15 openssl s_client -connect "$NODE_IP:443" -noservername \
    </dev/null >"$phase_dir/vt24.out" 2>&1 || true
  edge_end
  ! grep -q 'vps-proxy-setup test CA' "$phase_dir/vt24.out" || fail 'VT-24: the client got the stand-in certificate'
  edge_blocked vt24
}

# VT-25: input that is not TLS: plain HTTP with Host target.example, which
# shows that destOverride has only tls; and random bytes.
phase_vt25() {
  edge_begin vt25-http
  ip netns exec vpsns-client timeout 10 bash -c "exec 3<>/dev/tcp/$NODE_IP/443 &&
    printf 'GET / HTTP/1.1\r\nHost: target.example\r\nConnection: close\r\n\r\n' >&3 && cat <&3" \
    >"$phase_dir/vt25-http.out" 2>&1 || true
  edge_end
  ! grep -q 'stand-in' "$phase_dir/vt25-http.out" || fail 'VT-25: plain HTTP got stand-in content'
  edge_blocked vt25-http
  edge_begin vt25-random
  ip netns exec vpsns-client timeout 10 bash -c "exec 3<>/dev/tcp/$NODE_IP/443 && head -c 600 /dev/urandom >&3 &&
    cat <&3" >/dev/null 2>&1 || true
  edge_end
  edge_blocked vt25-random
}

# VT-26: target.example as SNI with an ordinary ClientHello is forwarded: the
# client gets the stand-in's certificate and content, and the stand-in has
# the connection.
phase_vt26() {
  local fwd
  fwd="$(xray_tag 20443)"
  edge_begin vt26
  client_curl vt26 --resolve "target.example:443:$NODE_IP" https://target.example/
  ip netns exec vpsns-client timeout 15 openssl s_client -connect "$NODE_IP:443" -servername target.example \
    </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer >"$phase_dir/vt26-cert.txt" 2>&1 || true
  edge_end
  { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] && grep -qx 'stand-in target.example' "$phase_dir/vt26.body"; } ||
    fail 'VT-26: the client did not get the stand-in content over a verified certificate'
  grep -q 'issuer=CN *= *vps-proxy-setup test CA' "$phase_dir/vt26-cert.txt" ||
    fail 'VT-26: the certificate is not the stand-in one'
  grep -qF "[$fwd -> direct]" "$phase_dir/vt26-access.txt" ||
    fail 'VT-26: the access log does not show the forwarder routing to direct'
  ! grep -qF "[$fwd -> blocked]" "$phase_dir/vt26-access.txt" || fail 'VT-26: the forwarder routed a connection to blocked'
  jq -se 'any(.[]; .sni == "target.example" and any(.requests[]; .status == 200))' "$phase_dir/vt26-standin.jsonl" \
    >/dev/null || fail 'VT-26: the stand-in has no served connection for target.example'
  [ -s "$phase_dir/vt26-syn.txt" ] || fail 'VT-26: no SYN to the stand-in'
}

# VT-27 SHAPE: twenty unauthenticated connections with SNI target.example
# whose ClientHello tests/guest/hello.py reshapes: split into TLS records,
# sent in four segments with pauses of up to 300 ms, or large with ML-KEM in
# one send. Every large one must be forwarded to the stand-in. The other two
# shapes are judged against the behaviour accepted in requirements D39
# (solution design 4.4 and SR-3): the forwarder's TLS sniffing reads only the
# first record, so every one is routed to blocked and none reaches the
# stand-in. If they start getting through, Xray's sniffing has changed and D39
# is due for review. Never retried (verification plan 6).
phase_vt27() {
  local shape="${1-}" fwd out n ok direct blocked served syn
  case "$shape" in
    records | segments | large) ;;
    *) driver_fail "unknown VT-27 shape: $shape" ;;
  esac
  fwd="$(xray_tag 20443)"
  out="$phase_dir/vt27-$shape"
  edge_begin "vt27-$shape"
  ip netns exec vpsns-client python3 "$BUNDLE/tests/guest/hello.py" --host "$NODE_IP" --shape "$shape" --count 20 \
    >"$out.jsonl" 2>"$out.err" || true
  edge_end
  n="$(grep -c . "$out.jsonl")" || true
  [ "$n" = 20 ] || driver_fail "VT-27 $shape: $n attempts recorded"
  # The driver itself: the ClientHello went out in the intended shape. A
  # connection the server closes partway shows a prefix of the plan.
  case "$shape" in
    records) jq -se 'all(.[]; .records >= 3 and .sent == .planned)' "$out.jsonl" >/dev/null ;;
    segments) jq -se 'all(.[]; (.planned | length) == 4 and (.sent | length) >= 1
        and .sent == .planned[0:(.sent | length)] and ((.sent | length) == 4 or has("error"))
        and ([.gaps, [0.1, 0.2, 0.3]] | transpose | all(.[0] == null or .[0] >= .[1])))' "$out.jsonl" >/dev/null ;;
    large) jq -se 'all(.[]; (.groups | index("X25519MLKEM768")) != null and .sent == .planned
        and (.planned | length) == 1)' "$out.jsonl" >/dev/null ;;
  esac || driver_fail "VT-27 $shape: the ClientHello was not sent in that shape"
  ok="$(jq -s '[.[] | select(.ok)] | length' "$out.jsonl")"
  direct="$(grep -cF "[$fwd -> direct]" "$out-access.txt")" || true
  blocked="$(grep -cF "[$fwd -> blocked]" "$out-access.txt")" || true
  served="$(jq -s '[.[] | select(.sni == "target.example" and any(.requests[]; .status == 200))] | length' \
    "$out-standin.jsonl")"
  syn="$(grep -c . "$out-syn.txt")" || true
  printf '%s\n' "$shape: client got the body $ok of $n" "forwarder to direct $direct, to blocked $blocked" \
    "stand-in served $served, SYN to the stand-in $syn" \
    "pieces sent of $(jq -s '.[0].planned | length' "$out.jsonl"): $(jq -rs '[.[] | .sent | length] | group_by(.)
      | map("\(.[0]) in \(length)") | join(", ")' "$out.jsonl")" >"$out.txt"
  if [ "$shape" = large ]; then
    { [ "$ok" = 20 ] && [ "$direct" -ge 20 ] && [ "$blocked" = 0 ] && [ "$served" -ge 20 ] && [ "$syn" -ge 20 ]; } ||
      fail "VT-27 $shape: not every connection was forwarded ($(paste -sd ';' "$out.txt"))"
  else
    { [ "$ok" = 0 ] && [ "$direct" = 0 ] && [ "$blocked" -ge 20 ] && [ "$served" = 0 ] && [ "$syn" = 0 ]; } ||
      fail "VT-27 $shape: differs from the behaviour accepted in requirements D39 ($(paste -sd ';' "$out.txt"))"
  fi
}

# VT-28: cross-authority probes over the node, SNI target.example with
# Host: other.example over HTTP/1.1 and :authority other.example over h2 (curl
# turns the Host header into :authority, detailed design 10, DO-8). With the
# stand-in routing by SNI, the client must not get other.example's content.
# Against the stand-in routing by Host the probes are only recorded: they show
# that the boundary does not look inside TLS (detailed design 17).
phase_vt28() {
  local fwd mode proto
  fwd="$(xray_tag 20443)"
  for mode in strict cross; do
    standin "$mode"
    edge_begin "vt28-$mode"
    for proto in http1.1 http2; do
      client_curl "vt28-$mode-$proto" "--$proto" --resolve "target.example:443:$NODE_IP" -H 'Host: other.example' \
        https://target.example/
    done
    edge_end
    # The driver itself: both probes went over the forwarder to the stand-in
    # with SNI target.example and authority other.example.
    { grep -qF "[$fwd -> direct]" "$phase_dir/vt28-$mode-access.txt" &&
      jq -se 'any(.[]; .sni == "target.example" and any(.requests[]; .proto == "http/1.1" and .host == "other.example"))
        and any(.[]; .sni == "target.example" and any(.requests[]; .proto == "h2" and .authority == "other.example"))' \
        "$phase_dir/vt28-$mode-standin.jsonl" >/dev/null; } ||
      { standin strict; driver_fail "VT-28 $mode: the probes did not reach the stand-in as intended"; }
    for proto in http1.1 http2; do
      printf '%s %s: %s, body %s\n' "$mode" "$proto" "$(cat "$phase_dir/vt28-$mode-$proto.result")" \
        "$(head -c 64 "$phase_dir/vt28-$mode-$proto.body" | tr -c '[:print:]' ' ')"
    done >>"$phase_dir/vt28.txt"
  done
  standin strict
  for proto in http1.1 http2; do
    ! grep -q 'stand-in other.example' "$phase_dir/vt28-strict-$proto.body" ||
      fail "VT-28: $proto with Host other.example got other.example's content from the stand-in routing by SNI"
  done
}

# vt29_side NAME ADDRESS [PREFIX...]: the handshake and the response of the
# stand-in at ADDRESS:443 with SNI target.example, as key=value lines in
# NAME.txt; PREFIX runs the commands in a namespace.
vt29_side() {
  local name="$1" addr="$2" out="$phase_dir/vt29-$1" code version size connect app first
  shift 2
  "$@" timeout 15 openssl s_client -connect "$addr:443" -servername target.example -alpn h2,http/1.1 \
    </dev/null >"$out.tls" 2>&1 || true
  read -r code version size connect app first < <("$@" curl -q -sS --noproxy '*' --max-time 20 \
    --resolve "target.example:443:$addr" -o "$out.body" \
    -w '%{http_code} %{http_version} %{size_download} %{time_connect} %{time_appconnect} %{time_starttransfer}\n' \
    https://target.example/ 2>"$out.curl-err" || true)
  {
    printf 'protocol=%s\n' "$(sed -n 's/^ *Protocol *: *//p' "$out.tls" | head -1)"
    printf 'cipher=%s\n' "$(sed -n 's/^New, [^,]*, Cipher is //p' "$out.tls" | head -1)"
    printf 'group=%s\n' "$(sed -n 's/^Negotiated TLS1.3 group: //p' "$out.tls" | head -1)"
    printf 'alpn=%s\n' "$(sed -n 's/^ALPN protocol: //p' "$out.tls" | head -1)"
    printf 'verify=%s\n' "$(sed -n 's/^Verify return code: //p' "$out.tls" | head -1)"
    printf 'certificate_sha256=%s\n' "$(openssl x509 -noout -fingerprint -sha256 <"$out.tls" 2>/dev/null | sed 's/.*=//')"
    printf 'http_status=%s\n' "${code-}"
    printf 'http_version=%s\n' "${version-}"
    printf 'body_bytes=%s\n' "${size-}"
    printf 'body_sha256=%s\n' "$(sha256sum <"$out.body" 2>/dev/null | cut -d' ' -f1)"
  } >"$out.txt"
  printf '%s: connect %s s, TLS done %s s, first byte %s s\n' "$name" "${connect-}" "${app-}" "${first-}" \
    >>"$phase_dir/vt29-timings.txt"
}

# VT-29: the stand-in reached from the guest directly and over the node's 443,
# both with SNI target.example, compared. Only recorded (verification plan
# VT-29); the phase fails only if a side could not be measured.
phase_vt29() {
  local key d n
  vt29_side direct "$STANDIN"
  vt29_side node "$NODE_IP" ip netns exec vpsns-client
  for key in protocol cipher group alpn verify certificate_sha256 http_status http_version body_bytes body_sha256; do
    d="$(sed -n "s/^$key=//p" "$phase_dir/vt29-direct.txt")"
    n="$(sed -n "s/^$key=//p" "$phase_dir/vt29-node.txt")"
    if [ "$d" = "$n" ]; then
      printf '%s: same (%s)\n' "$key" "$d"
    else
      printf '%s: direct %s, node %s\n' "$key" "$d" "$n"
    fi
  done >"$phase_dir/vt29.txt"
  for d in direct node; do
    { grep -qx 'protocol=TLSv1.3' "$phase_dir/vt29-$d.txt" && grep -qx 'http_status=200' "$phase_dir/vt29-$d.txt"; } ||
      fail "VT-29: the $d side could not be measured"
  done
}

# VT-30 and VT-31 (D22): a domain in the bundled geosite:cn and an IPv4
# address in the bundled geoip:cn. Both are in the upstream lists the release
# bundles; that the bundled copies hold them is what VT-30 shows.
readonly CN_DOMAIN=www.baidu.com
readonly CN_IPV4=223.5.5.5

# route_test CASE INBOUND_TAG FIELD VALUE: one query to the panel's route test
# (POST panel/api/xray/routeTest, detailed design 19), which asks the running
# core which outbound it would pick, without sending traffic. FIELD is domain
# or ip. The answer goes to vt30.jsonl. The form ends without a newline: the
# panel takes form values as sent, and a newline after the last one would
# make the tag one that no rule names.
route_test() {
  jq -jn --arg t "$2" --arg f "$3" --arg v "$4" '"\($f)=\($v | @uri)&port=443&network=tcp&inboundTag=\($t | @uri)"' \
    >"$PRIVATE/route-test-form"
  panel_api POST xray/routeTest "$PRIVATE/route-test-form" application/x-www-form-urlencoded
  jq -c --arg c "$1" --arg f "$3" --arg v "$4" '{case: $c, query: "\($f) \($v)", matched: .obj.matched,
    outboundTag: .obj.outboundTag}' "$PANEL_OUT" >>"$phase_dir/vt30.jsonl"
}

# route_is CASE MATCHED TAG: the answer of that case.
route_is() {
  jq -se --arg c "$1" --argjson m "$2" --arg t "$3" '[.[] | select(.case == $c)]
    | length == 1 and .[0].matched == $m and .[0].outboundTag == $t' "$phase_dir/vt30.jsonl" >/dev/null
}

# VT-30: from the REALITY inbound, the geosite:cn domain and the geoip:cn
# literal go to blocked (rules 3 and 4); the control probe.example either
# matches a rule to direct, or matches none and takes the first outbound of
# the generated config, which must be direct. From the forwarder,
# target.example goes to direct and other.example to blocked (rules 1 and 2).
phase_vt30() {
  local reality fwd
  reality="$(xray_tag 443)"
  fwd="$(xray_tag 20443)"
  panel_login
  rm -f "$phase_dir/vt30.jsonl"
  route_test cn-domain "$reality" domain "$CN_DOMAIN"
  route_test cn-ipv4 "$reality" ip "$CN_IPV4"
  route_test control "$reality" domain probe.example
  route_test forwarder-target "$fwd" domain target.example
  route_test forwarder-other "$fwd" domain other.example
  jq -r '"\(.case) (\(.query)): matched \(.matched), outbound \(if .outboundTag == "" then "none" else .outboundTag end)"' \
    "$phase_dir/vt30.jsonl" >"$phase_dir/vt30.txt"
  printf 'first outbound of the generated config: %s\n' "$(jq -r '.outbounds[0].tag' "$XRAY_CONFIG")" \
    >>"$phase_dir/vt30.txt"
  route_is cn-domain true blocked || fail "VT-30: $CN_DOMAIN from the REALITY inbound is not routed to blocked"
  route_is cn-ipv4 true blocked || fail "VT-30: $CN_IPV4 from the REALITY inbound is not routed to blocked"
  { route_is control true direct ||
    { route_is control false '' && jq -e '.outbounds[0].tag == "direct"' "$XRAY_CONFIG" >/dev/null; }; } ||
    fail 'VT-30: probe.example from the REALITY inbound would not go to direct'
  route_is forwarder-target true direct || fail 'VT-30: target.example from the forwarder is not routed to direct'
  route_is forwarder-other true blocked || fail 'VT-30: other.example from the forwarder is not routed to blocked'
}

# VT-31: Mihomo in global mode over the node, as in VT-20. The geosite:cn
# domain fails, routed from the REALITY inbound to blocked by a rule;
# probe.example gets through, to direct.
phase_vt31() {
  local reality
  reality="$(xray_tag 443)"
  mihomo_up main 7890
  edge_begin vt31
  client_curl vt31-cn -x http://127.0.0.1:7890 "https://$CN_DOMAIN/"
  local cn_rc="$CURL_RC" cn_code="$CURL_HTTP"
  client_curl vt31-probe -x http://127.0.0.1:7890 http://probe.example/
  edge_end
  mihomo_log main
  printf '%s\n' "$CN_DOMAIN: curl exit $cn_rc, HTTP $cn_code" "probe.example: curl exit $CURL_RC, HTTP $CURL_HTTP" \
    >"$phase_dir/vt31.txt"
  { [ "$cn_rc" != 0 ] || [ "$cn_code" != 200 ]; } || fail "VT-31: $CN_DOMAIN was reached over the node"
  grep -qF "accepted tcp:$CN_DOMAIN:443 [$reality -> blocked]" "$phase_dir/vt31-access.txt" ||
    fail "VT-31: the access log does not show $CN_DOMAIN routed from the REALITY inbound to blocked"
  [ "$(grep -cF "tcp:$CN_DOMAIN:" "$phase_dir/vt31-access.txt")" = \
    "$(grep -cF "tcp:$CN_DOMAIN:443 [$reality -> blocked]" "$phase_dir/vt31-access.txt")" ] ||
    fail "VT-31: $CN_DOMAIN was also routed elsewhere"
  { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] && grep -qx 'stand-in probe.example' "$phase_dir/vt31-probe.body"; } ||
    fail 'VT-31: http://probe.example/ over the node failed'
  grep -qF "accepted tcp:probe.example:80 [$reality >> direct]" "$phase_dir/vt31-access.txt" ||
    fail 'VT-31: the access log does not show probe.example from the REALITY inbound to direct'
}

main "$@"
