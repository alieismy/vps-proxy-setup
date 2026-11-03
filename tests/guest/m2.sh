#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Guest side of the M2 VM tests (detailed design 9, 19; verification plan
# VT-10 to VT-13, VT-15 to VT-18, VT-20 to VT-34, VT-70, VT-71). Sources
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

# VT-33 ④: the main configuration has no usable IPv6, so the preflight of a
# deploy with FR-13 enabled reports ipv6.egress and stops before the
# confirmation, with the state summary unchanged (FR-12).
phase_vt33_preflight() {
  settle
  write_input "$PRIVATE/vt33.input" ipv6_ai_egress=on
  observe vt33-preflight capture_tty "$TOOL" deploy --input "$PRIVATE/vt33.input"
  expect_rc vt33-preflight 1
  expect_clean vt33-preflight
  expect_err vt33-preflight '[x] 预检不通过，主机未改动'
  expect_fails vt33-preflight ipv6.egress
  expect_text vt33-preflight '没有可用的 IPv6 出站前提'
  expect_no_secret vt33-preflight
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
    else:
        # FR-13 (detailed design 4.4): the sixth rule; the outbound appended,
        # with the finalRules of direct; no dns.
        ai_rule = {'type': 'field', 'inboundTag': [r['tag']], 'domain': ['geosite:openai', 'geosite:anthropic'],
                   'outboundTag': 'ai-ipv6'}
        check(rules[5:6] == [ai_rule] and rules[6:] == default[1:],
              'template: the FR-13 rule sixth, then the other default rules')
        obs = t.get('outbounds') or []
        final = [(o.get('settings') or {}).get('finalRules') for o in obs if o.get('tag') == 'direct'][:1]
        ai = {'tag': 'ai-ipv6', 'protocol': 'freedom', 'settings': {'finalRules': final[0] if final else None},
              'streamSettings': {'sockopt': {'domainStrategy': 'ForceIPv6v4'}}}
        check(bool(final and final[0]) and obs[-1:] == [ai] and [o.get('tag') for o in obs].count('ai-ipv6') == 1,
              'template: one ai-ipv6 outbound, last, with the finalRules of direct')
        check('dns' not in t, 'template: no dns')
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

# vt16_config MODE [IPV6]: the configuration 3X-UI generated for Xray against
# the database (detailed design 17). MODE info only counts the users already in
# it; MODE full judges it, with IPV6 on also the FR-13 rule and outbound.
vt16_config() {
  local state uri
  state="$(vps_fn xui_db_state)" && uri="$(vps_fn xui_db_uri "$state")" || return 1
  python3 - "$uri" "$XRAY_CONFIG" "$1" "${2-off}" <<'PY'
import json, sqlite3, sys

uri, path, mode, ipv6 = sys.argv[1:5]
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
n = 6 if ipv6 == 'on' else 5
check(((cfg.get('routing') or {}).get('rules') or [])[:n] == tpl['routing']['rules'][:n],
      'generated: the api rule and rules 1 to 4' + (' and the FR-13 rule' if n == 6 else '') + ' as in the template')
if ipv6 == 'on':
    ai = [o for o in cfg.get('outbounds') or [] if o.get('tag') == 'ai-ipv6']
    check(len(ai) == 1 and ai == [o for o in tpl.get('outbounds') or [] if o.get('tag') == 'ai-ipv6'],
          'generated: the ai-ipv6 outbound as in the template')
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
  vt16_config full "$2" | tee "$phase_dir/$name-vt16-config.txt" ||
    fail "$name: VT-16 generated configuration checks failed"
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

# fr13_says_off NAME: both FR-13 items of that check output are SKIP and say
# that FR-13 is off (VT-33).
fr13_says_off() {
  [ "$(grep -cE '^\[SKIP\] (routing\.ai-ipv6|ipv6\.egress) +未启用 FR-13（ipv6_ai_egress=off）$' \
    "$phase_dir/$1.out")" = 2 ] || fail "VT-33 $1: the two FR-13 items of check do not say that FR-13 is off"
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
  fr13_says_off check
  scan_markers
}

# One VT-71 injection of M2 on its own overlay of the deployed disk (detailed
# design 9.6); tests/vm.py compares the check result with the baseline. The
# injections named ai-* run on the disk deployed with FR-13 enabled, after
# fr13-boot (9.11).
phase_vt71() {
  local name="$1" reality fwd
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
    # VT-33 ③: the outbound and the rule of FR-13 as deploy writes them with
    # FR-13 enabled, on this host deployed with it off.
    ai-ipv6-off)
      reality="$(xray_tag 443)"
      [ -n "$reality" ] || driver_fail 'no single inbound on 443'
      template_edit '.routing.rules |= .[:5] + [{type: "field", inboundTag: ["'"$reality"'"],
          domain: ["geosite:openai", "geosite:anthropic"], outboundTag: "ai-ipv6"}] + .[5:]
        | .outbounds += [{tag: "ai-ipv6", protocol: "freedom",
          settings: {finalRules: [.outbounds[] | select(.tag == "direct")][0].settings.finalRules},
          streamSettings: {sockopt: {domainStrategy: "ForceIPv6v4"}}}]'
      ;;
    outbound-blocked)
      template_edit '.outbounds |= map(if .tag == "blocked" then {tag, protocol: "freedom"} else . end)'
      ;;
    # FR-13 (verification plan VT-71): each value is one Xray accepts.
    ai-strategy)
      template_edit '.outbounds |= map(if .tag == "ai-ipv6"
        then .streamSettings.sockopt.domainStrategy = "UseIPv6v4" else . end)'
      ;;
    ai-send-through)
      template_edit '.outbounds |= map(if .tag == "ai-ipv6" then .sendThrough = "'"$GUEST6"'" else . end)'
      ;;
    ai-happy-eyeballs)
      template_edit '.outbounds |= map(if .tag == "ai-ipv6"
        then .streamSettings.sockopt.happyEyeballs = {tryDelayMs: 250, prioritizeIPv6: true} else . end)'
      ;;
    ai-final-rules)
      template_edit '.outbounds |= map(if .tag == "ai-ipv6"
        then .settings.finalRules = [{action: "allow", ip: ["'"$BLOCKED6"'"]}] + .settings.finalRules else . end)'
      ;;
    ai-inbound-tag)
      fwd="$(xray_tag 20443)"
      [ -n "$fwd" ] || driver_fail 'no single inbound on 20443'
      template_edit '.routing.rules |= map(if .outboundTag == "ai-ipv6" then .inboundTag = ["'"$fwd"'"] else . end)'
      ;;
    ai-category)
      template_edit '.routing.rules |= map(if .outboundTag == "ai-ipv6" then .domain = ["geosite:openai"] else . end)'
      ;;
    ai-rule-last)
      template_edit '.routing.rules |= [.[] | select(.outboundTag != "ai-ipv6")]
        + [.[] | select(.outboundTag == "ai-ipv6")]'
      ;;
    ai-outbound-first)
      template_edit '.outbounds |= [.[] | select(.tag == "ai-ipv6")] + [.[] | select(.tag != "ai-ipv6")]'
      ;;
    ai-dns) template_edit '.dns = {servers: ["localhost"], queryStrategy: "UseIPv4"}' ;;
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

# full_deploy NAME INPUT: deploy steps 1 to 7; without step 8 (M3) the run
# ends with exit 1 after step 7.
full_deploy() {
  settle
  keeper_start
  deploy_yes "$1" "$TOOL" deploy --input "$2"
  keeper_stop
  collect_markers
  expect_rc "$1" 1
  expect_clean "$1"
  expect_err "$1" '[x] 第 1～7 步完成'
  expect_fails "$1"
  expect_no_secret "$1"
  wait_xui_stable
  scan_markers
}

phase_sni_deploy() { full_deploy sni-deploy "$M2_INPUT"; }

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

# mihomo_up NAME PORT [drop-mlkem | hosts JSON]: Mihomo in the client namespace
# with the proxies of alice's Mihomo subscription as they are (without
# support-x25519mlkem768 for drop-mlkem; with hosts, its own hosts table
# JSON, name -> addresses, as a client resolves names with its own DNS), in
# global mode with GLOBAL set to
# her node, so that no client rule decides the outcome (verification plan
# 3.6). Mixed port PORT, controller PORT+2000, both on loopback of the
# namespace. The configuration holds her UUID, so it stays private.
mihomo_up() {
  local name="$1" port="$2" dir="$PRIVATE/mihomo-$1" unit="vps-mihomo-$1" i code
  rm -rf "$dir"
  install -d -m 0700 "$dir"
  sub_get alice mihomoUrl "$dir/subscription.yaml"
  python3 - "$dir" "$port" "${3-}" "${4-}" <<'PY' || driver_fail "mihomo $name: no configuration from the subscription"
import json, os, sys
import yaml

d, port, mode, hosts = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(os.path.join(d, 'subscription.yaml'), encoding='utf-8') as f:
    proxies = yaml.safe_load(f)['proxies']
assert len(proxies) == 1, 'not one proxy'
if mode == 'drop-mlkem':
    proxies[0].get('reality-opts', {}).pop('support-x25519mlkem768', None)
conf = {'mixed-port': port, 'allow-lan': False, 'mode': 'global', 'log-level': 'info', 'ipv6': False,
        'external-controller': f'127.0.0.1:{port + 2000}', 'profile': {'store-selected': False},
        'proxies': proxies, 'rules': []}
if mode == 'hosts':
    conf['hosts'] = json.loads(hosts)
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

# sni_prep RULE: the test-environment deviations, through the panel with
# the handoff credentials (verification plan 3.4): the stand-in exception RULE
# first in the finalRules of direct and, with FR-13, of ai-ipv6, so that the
# two stay equal (3.6); and the Xray access log (4.4). Saving the template
# restarts Xray.
sni_prep() {
  local fwd reality rule="$1"
  grep -qE '^443/tcp +ALLOW' <(ufw status) || fail 'UFW does not allow 443/tcp'
  panel_login
  template_edit '.log.access = "'"$XRAY_ACCESS"'"
    | .outbounds |= map(if .tag == "direct" or .tag == "ai-ipv6"
      then .settings.finalRules = ['"$rule"'] + .settings.finalRules else . end)'
  wait_port 443 exposed
  wait_port 20443 loopback
  wait_xui_stable
  for _ in $(seq 60); do
    [ ! -e "$XRAY_ACCESS" ] || break
    sleep 1
  done
  jq -e --arg a "$XRAY_ACCESS" --argjson r "$rule" '.log.access == $a
    and ([.outbounds[] | select(.tag == "direct") | .settings.finalRules[0]] == [$r])
    and all(.outbounds[] | select(.tag == "ai-ipv6"); .settings.finalRules[0] == $r)' "$XRAY_CONFIG" >/dev/null ||
    fail 'the generated Xray config does not have the access log and the stand-in exception'
  [ -f "$XRAY_ACCESS" ] || fail "Xray did not create $XRAY_ACCESS"
  reality="$(xray_tag 443)"
  fwd="$(xray_tag 20443)"
  [ -n "$reality" ] && [ -n "$fwd" ] || fail 'no single inbound on 443 and on 20443'
  printf '%s\n' "REALITY inbound tag: $reality" "forwarder tag: $fwd" \
    "deviation: the finalRules of direct, and of ai-ipv6 if present, begin with $rule (verification plan 3.6)" \
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

phase_sni_prep() { sni_prep "$STANDIN_RULE"; }

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

# VT-30 and VT-31 (D22): the test vectors come from the geo data the release
# bundles, chosen at run time (verification plan 3.7), so the repository names
# none: the first domain of type Domain or Full in geosite:cn and the second
# address of the first IPv4 block of geoip:cn (tests/guest/geodat.py). The
# choice depends only on the files, so each phase makes it again.
readonly GEO_DIR="${XRAY_CONFIG%/*}"

# geo_pick site|ip CODE: the vector of that list, on standard output.
geo_pick() {
  local file=geosite.dat
  [ "$1" = ip ] && file=geoip.dat
  python3 "$BUNDLE/tests/guest/geodat.py" "$1" "$GEO_DIR/$file" "$2" ||
    driver_fail "no test vector for $1 $2 in the bundled $file"
}

# route_test CASE INBOUND_TAG FIELD VALUE: one query to the panel's route test
# (POST panel/api/xray/routeTest, detailed design 19), which asks the running
# core which outbound it would pick, without sending traffic. FIELD is domain
# or ip. The answer goes to routes.jsonl. The form ends without a newline: the
# panel takes form values as sent, and a newline after the last one would
# make the tag one that no rule names.
route_test() {
  jq -jn --arg t "$2" --arg f "$3" --arg v "$4" '"\($f)=\($v | @uri)&port=443&network=tcp&inboundTag=\($t | @uri)"' \
    >"$PRIVATE/route-test-form"
  panel_api POST xray/routeTest "$PRIVATE/route-test-form" application/x-www-form-urlencoded
  jq -c --arg c "$1" --arg f "$3" --arg v "$4" '{case: $c, query: "\($f) \($v)", matched: .obj.matched,
    outboundTag: .obj.outboundTag}' "$PANEL_OUT" >>"$phase_dir/routes.jsonl"
}

# route_is CASE MATCHED TAG: the answer of that case.
route_is() {
  jq -se --arg c "$1" --argjson m "$2" --arg t "$3" '[.[] | select(.case == $c)]
    | length == 1 and .[0].matched == $m and .[0].outboundTag == $t' "$phase_dir/routes.jsonl" >/dev/null
}

# VT-30: from the REALITY inbound, the geosite:cn domain and the geoip:cn
# literal go to blocked (rules 3 and 4); the control probe.example either
# matches a rule to direct, or matches none and takes the first outbound of
# the generated config, which must be direct. From the forwarder,
# target.example goes to direct and other.example to blocked (rules 1 and 2).
phase_vt30() {
  local reality fwd cn_domain cn_ipv4
  reality="$(xray_tag 443)"
  fwd="$(xray_tag 20443)"
  cn_domain="$(geo_pick site cn)"
  cn_ipv4="$(geo_pick ip cn)"
  (cd "$GEO_DIR" && sha256sum geosite.dat geoip.dat) >"$phase_dir/vt30-geodata.txt"
  panel_login
  rm -f "$phase_dir/routes.jsonl"
  route_test cn-domain "$reality" domain "$cn_domain"
  route_test cn-ipv4 "$reality" ip "$cn_ipv4"
  route_test control "$reality" domain probe.example
  route_test forwarder-target "$fwd" domain target.example
  route_test forwarder-other "$fwd" domain other.example
  jq -r '"\(.case) (\(.query)): matched \(.matched), outbound \(if .outboundTag == "" then "none" else .outboundTag end)"' \
    "$phase_dir/routes.jsonl" >"$phase_dir/vt30.txt"
  printf 'first outbound of the generated config: %s\n' "$(jq -r '.outbounds[0].tag' "$XRAY_CONFIG")" \
    >>"$phase_dir/vt30.txt"
  route_is cn-domain true blocked || fail "VT-30: $cn_domain from the REALITY inbound is not routed to blocked"
  route_is cn-ipv4 true blocked || fail "VT-30: $cn_ipv4 from the REALITY inbound is not routed to blocked"
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
  local reality cn_domain
  reality="$(xray_tag 443)"
  cn_domain="$(geo_pick site cn)"
  mihomo_up main 7890
  edge_begin vt31
  client_curl vt31-cn -x http://127.0.0.1:7890 "https://$cn_domain/"
  local cn_rc="$CURL_RC" cn_code="$CURL_HTTP"
  client_curl vt31-probe -x http://127.0.0.1:7890 http://probe.example/
  edge_end
  mihomo_log main
  printf '%s\n' "$cn_domain: curl exit $cn_rc, HTTP $cn_code" "probe.example: curl exit $CURL_RC, HTTP $CURL_HTTP" \
    >"$phase_dir/vt31.txt"
  { [ "$cn_rc" != 0 ] || [ "$cn_code" != 200 ]; } || fail "VT-31: $cn_domain was reached over the node"
  grep -qF "accepted tcp:$cn_domain:443 [$reality -> blocked]" "$phase_dir/vt31-access.txt" ||
    fail "VT-31: the access log does not show $cn_domain routed from the REALITY inbound to blocked"
  [ "$(grep -cF "tcp:$cn_domain:" "$phase_dir/vt31-access.txt")" = \
    "$(grep -cF "tcp:$cn_domain:443 [$reality -> blocked]" "$phase_dir/vt31-access.txt")" ] ||
    fail "VT-31: $cn_domain was also routed elsewhere"
  { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] && grep -qx 'stand-in probe.example' "$phase_dir/vt31-probe.body"; } ||
    fail 'VT-31: http://probe.example/ over the node failed'
  grep -qF "accepted tcp:probe.example:80 [$reality >> direct]" "$phase_dir/vt31-access.txt" ||
    fail 'VT-31: the access log does not show probe.example from the REALITY inbound to direct'
}

# ---------------------------------------------------------------------------
# FR-13 (detailed design 9.9 to 9.11; verification plan 3.3, 3.6, 4.5): the
# overlay with an IPv6 /64 on the stand-in's veth, deployed with FR-13 enabled
# (and once with it off); the dual-stack stand-in; the egress isolation;
# VT-32 to VT-34; VT-16 on that overlay. The cases, the regressions and the
# FR-13 injections of VT-71 boot overlays of the deployed disk.

# The guest's end of the stand-in's veth (phase network of m1.sh).
readonly GUEST4=198.51.100.1
readonly GUEST6=2001:db8:0:6::1
readonly STANDIN6=2001:db8:0:6::2
readonly GUEST6_EXTRA=2001:db8:0:6::3
readonly UDP_ECHO_PORT=7
readonly FR13_INPUT="$PRIVATE/fr13.input"
# The exception of verification plan 3.6 on this overlay: both stand-in
# addresses, first in the finalRules of direct and of ai-ipv6.
readonly STANDIN_RULE6='{"action":"allow","ip":["198.51.100.2","2001:db8:0:6::2"]}'
readonly HOSTS_MARK='# vps-fr13'
readonly ISOLATION_CHAIN=VPS-ISOLATION
# The Xray error log of VT-34, a test deviation like the access log. 3X-UI
# keeps only the file name and puts it in its log folder, the folder of the
# access log.
readonly XRAY_ERROR=/var/log/x-ui/error.log
# VT-34: an address on the /64 that is not the stand-in's. The exception of
# verification plan 3.6 names only the stand-in, so the finalRules of
# ai-ipv6 block it as a private address.
readonly BLOCKED6=2001:db8:0:6::9

# IPv6 on the stand-in's veth only: no router advertisements, no temporary
# addresses, no duplicate address detection, so that the one global address
# is usable at once. The guest's IPv6 default route points into the stand-in
# namespace; the client namespace stays IPv4 only (verification plan 3.3).
phase_fr13_net() {
  local conf
  for conf in accept_ra=0 autoconf=0 use_tempaddr=0 disable_ipv6=0; do
    sysctl -q -w "net.ipv6.conf.vps-standin0.$conf"
    ip netns exec vpsns-standin sysctl -q -w "net.ipv6.conf.eth0.$conf"
  done
  ip netns exec vpsns-standin sysctl -q -w net.ipv6.conf.all.disable_ipv6=0
  ip -6 addr add "$GUEST6/64" dev vps-standin0 nodad
  ip -n vpsns-standin -6 addr add "$STANDIN6/64" dev eth0 nodad
  ip -6 route add default via "$STANDIN6" dev vps-standin0
  capture ping6 ping -6 -c 1 -W 5 "$STANDIN6"
  expect_rc ping6 0
  { ip -br addr; echo '== -6 route'; ip -6 route; } >"$phase_dir/addresses.txt"
  [ "$(vps_fn ipv6_egress_facts)" = '1 0 1' ] || fail 'the guest does not have exactly one usable IPv6 address and route'
}

# A new boot of the disk deployed with FR-13 enabled, before the cases and
# each VT-71 injection: the namespaces again, and the guest's IPv6. The
# stand-in starts in fr13-prep.
phase_fr13_boot() {
  settle
  test_namespaces
  capture client-ping ip netns exec vpsns-client ping -c 1 -W 5 192.0.2.1
  expect_rc client-ping 0
  phase_fr13_net
  wait_xui_stable
}

phase_fr13_deploy() {
  write_input "$FR13_INPUT" ipv6_ai_egress=on
  full_deploy fr13-deploy "$FR13_INPUT"
}

# VT-16 on the overlay with FR-13 enabled (verification plan 4.5), right after
# the deploy, before fr13-prep saves the template again: as on the main
# configuration, with the FR-13 rule sixth and the ai-ipv6 outbound last.
phase_fr13_vt16() {
  collect_markers
  vt16_judge fr13 on
  scan_markers
}

# fr13_hosts NAME [4|6|ADDRESS]...: /etc/hosts maps NAME to the stand-in's
# IPv4 address, its IPv6 address, another address, or, with nothing given,
# to nothing; the lines carry HOSTS_MARK. Go reads the hosts file again at
# most every five seconds, so the core sees the change after the wait.
fr13_hosts() {
  local name="$1" kind
  grep -vF -- " $name $HOSTS_MARK" /etc/hosts >"$PRIVATE/hosts.new" || true
  for kind in "${@:2}"; do
    case "$kind" in
      4) printf '%s %s %s\n' "$STANDIN" "$name" "$HOSTS_MARK" ;;
      6) printf '%s %s %s\n' "$STANDIN6" "$name" "$HOSTS_MARK" ;;
      *) printf '%s %s %s\n' "$kind" "$name" "$HOSTS_MARK" ;;
    esac >>"$PRIVATE/hosts.new"
  done
  cat "$PRIVATE/hosts.new" >/etc/hosts
  sleep 6
}

# The dual-stack stand-in (verification plan 3.6), serving the two test
# domains, and the deviations with both stand-in addresses.
phase_fr13_prep() {
  local openai anthropic
  openai="$(geo_pick site openai)"
  anthropic="$(geo_pick site anthropic)"
  standin strict --listen6 "$STANDIN6" --udp-port "$UDP_ECHO_PORT" --host "$openai" --host "$anthropic"
  sni_prep "$STANDIN_RULE6"
  capture standin-http4 curl -q -fsS --noproxy '*' --max-time 10 -o /dev/null -H 'Host: probe.example' \
    "http://$STANDIN/"
  expect_rc standin-http4 0
  capture standin-http6 curl -q -fsS --noproxy '*' --max-time 10 -o /dev/null -H 'Host: probe.example' \
    "http://[$STANDIN6]/"
  expect_rc standin-http6 0
  { ls -l /etc/resolv.conf; cat /etc/resolv.conf; } >"$phase_dir/resolv.txt" 2>&1
  printf '%s\n' 'deviation: new connections of the guest through the user-network uplink are rejected and counted during the FR-13 cases (verification plan 3.6)' \
    >>"$phase_dir/deviations.txt"
}

# isolation_on: verification plan 3.6. New connections that the guest opens
# through the user-network uplink, DNS queries included, are logged, rejected
# and counted, port 53 apart from the rest. Connections the runner forwards
# in are not new in that direction. Zeroes the counters.
#
# The rejected DNS queries come from systemd-resolved, which hides who asked
# it (runs 41488828274 and 41571076881). So the isolation also starts two
# diagnostics, as units that outlive the phase's session until the next
# isolation_on: a capture of the queries that local processes send to the
# resolver stub on loopback, and every 0.2 s the sockets to port 53 with
# their processes. isolation_counts archives both; they are not judged. It
# also sets the resolver's log level to debug, which names what is looked
# up, also for clients that ask over D-Bus or Varlink rather than port 53;
# isolation_judge reads that log.
ISOLATION_SINCE=''
readonly DNS_DIAG_UNITS=(vps-dnsdiag-capture vps-dnsdiag-sockets)
isolation_on() {
  local up cmd unit
  up="$(ip -j -4 route show default | jq -r 'if length == 1 then .[0].dev else empty end')"
  [ -n "$up" ] || driver_fail 'no single IPv4 default route for the egress isolation'
  for cmd in iptables ip6tables; do
    if "$cmd" -w -N "$ISOLATION_CHAIN" 2>/dev/null; then
      "$cmd" -w -A "$ISOLATION_CHAIN" -j LOG --log-prefix 'vps-isolation: ' --log-uid
      "$cmd" -w -A "$ISOLATION_CHAIN" -p udp --dport 53 -j REJECT
      "$cmd" -w -A "$ISOLATION_CHAIN" -p tcp --dport 53 -j REJECT
      "$cmd" -w -A "$ISOLATION_CHAIN" -j REJECT
      "$cmd" -w -I OUTPUT 1 -o "$up" -m conntrack --ctstate NEW -j "$ISOLATION_CHAIN"
    fi
    "$cmd" -w -Z "$ISOLATION_CHAIN"
  done
  # Debian's apt-listchanges.timer starts apt-listchanges.service every hour
  # until the service has fetched its database; in run 41580793882 those
  # fetches made systemd-resolved send 504 rejected DNS queries. Like the
  # time sync, it stops for the cases.
  systemctl stop apt-listchanges.timer apt-listchanges.service 2>/dev/null || true
  for unit in "${DNS_DIAG_UNITS[@]}"; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl reset-failed "$unit" 2>/dev/null || true
  done
  rm -f "$PRIVATE/dnsdiag.pcap" "$PRIVATE/dnsdiag.err" "$PRIVATE/dnsdiag-sockets.txt"
  systemd-run --quiet --unit vps-dnsdiag-capture -p "StandardError=file:$PRIVATE/dnsdiag.err" -- \
    tcpdump -Z root -i lo -nn -U -w "$PRIVATE/dnsdiag.pcap" 'port 53'
  systemd-run --quiet --unit vps-dnsdiag-sockets -p "StandardOutput=file:$PRIVATE/dnsdiag-sockets.txt" -- \
    bash -c 'while :; do ss -Htunap "( dport = :53 )" 2>/dev/null || true; sleep 0.2; done'
  for _ in $(seq 50); do
    ! grep -qs 'listening on' "$PRIVATE/dnsdiag.err" || break
    sleep 0.2
  done
  grep -qs 'listening on' "$PRIVATE/dnsdiag.err" || driver_fail 'the DNS capture on loopback did not start'
  resolvectl log-level debug
  [ "$(resolvectl log-level)" = debug ] || driver_fail 'the log level of systemd-resolved is not debug'
  ISOLATION_SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
}

# isolation_counts NAME: "DNS OTHER" rejected since isolation_on, written with
# the logged packets to NAME-isolation.txt; the diagnostics so far to
# NAME-dns-queries.txt (one line per query to the stub),
# NAME-dns-sockets.txt (the sampled sockets without their local address,
# counted) and NAME-resolved.txt (the resolver's log).
isolation_counts() {
  local cmd dns=0 other=0 packets
  for cmd in iptables ip6tables; do
    mapfile -t packets < <("$cmd" -w -L "$ISOLATION_CHAIN" -v -x -n | awk 'NR > 2 { print $1 }')
    [ "${#packets[@]}" = 4 ] || driver_fail "the $cmd isolation chain does not have four rules"
    dns=$((dns + packets[1] + packets[2]))
    other=$((other + packets[3]))
  done
  {
    printf 'rejected since %s: DNS %s, other %s\n' "$ISOLATION_SINCE" "$dns" "$other"
    journalctl -q -k --since "$ISOLATION_SINCE" -g 'vps-isolation: ' -o short-iso 2>/dev/null || true
  } >"$phase_dir/$1-isolation.txt"
  tcpdump -nn -tt -r "$PRIVATE/dnsdiag.pcap" 'dst port 53' >"$phase_dir/$1-dns-queries.txt" 2>/dev/null || true
  awk '{ $5 = ""; print }' "$PRIVATE/dnsdiag-sockets.txt" 2>/dev/null | sort | uniq -c >"$phase_dir/$1-dns-sockets.txt" || true
  journalctl -q -u systemd-resolved --since "$ISOLATION_SINCE" -o short-iso >"$phase_dir/$1-resolved.txt" 2>/dev/null || true
  [ "$(resolvectl log-level)" = debug ] || driver_fail 'systemd-resolved left the debug level during the cases'
  [ -z "$(journalctl -q --since "$ISOLATION_SINCE" -g '^Suppressed [0-9]+ messages from .*systemd-resolved' 2>/dev/null)" ] ||
    driver_fail 'the journal suppressed messages of systemd-resolved, so its log is incomplete'
  printf '%s %s\n' "$dns" "$other"
}

# isolation_judge LABEL NAME DOMAIN...: the egress isolation as the owner
# decided on 2026-11-02 (detailed design 9.10). systemd-resolved sends every
# DNS query of the guest upstream, so the DNS count cannot tell the cases
# from background lookups, such as the public-IP check that 3X-UI's status
# task runs every few minutes. The isolation passes when it rejected nothing
# but DNS and the resolver's log since isolation_on has no lookup of any of
# the test domains DOMAIN; the rejected DNS queries and the names asked for
# are archived, not judged.
isolation_judge() {
  local label="$1" name="$2" n domain
  n="$(isolation_counts "$name")"
  [ "${n#* }" = 0 ] || fail "$label: the egress isolation rejected ${n#* } connections other than DNS"
  for domain in "${@:3}"; do
    ! resolved_asked "$name" "$domain" || fail "$label: systemd-resolved was asked for $domain"
  done
}

# resolved_asked NAME DOMAIN: whether the resolver's log that
# isolation_counts NAME archived has a lookup of DOMAIN.
resolved_asked() {
  grep -qiF -- "Looking up RR for $2 IN " "$phase_dir/$1-resolved.txt"
}

# fr13_begin NAME / fr13_end: edge_begin and edge_end for the dual-stack
# stand-in: the new access log lines and stand-in records, and on the
# guest's veth towards the stand-in the SYNs to the HTTP port and the UDP
# datagrams to each of its two addresses. tcpdump's tcp[] does not reach into
# IPv6, so SYNs are taken from the decoded flags. Every REALITY handshake
# also makes the node reach its target, target.example on the stand-in's
# IPv4 port 443, through the forwarder; those SYNs are counted apart. With
# the error log of VT-34 on, also its new outbound lines.
EDGE_ERROR=-1
fr13_begin() {
  EDGE_NAME="$1"
  EDGE_ACCESS="$(stat -c %s "$XRAY_ACCESS")"
  EDGE_ERROR=-1
  [ ! -f "$XRAY_ERROR" ] || EDGE_ERROR="$(stat -c %s "$XRAY_ERROR")"
  EDGE_STANDIN="$(stat -c %s "$EVIDENCE/standin/connections.jsonl")"
  tcpdump -Z root -i vps-standin0 -nn -U -w "$PRIVATE/edge-$1.pcap" "host $STANDIN or host $STANDIN6" \
    2>"$PRIVATE/edge-$1.err" &
  EDGE_PID=$!
  for _ in $(seq 50); do
    ! grep -q 'listening on' "$PRIVATE/edge-$1.err" || return 0
    sleep 0.2
  done
  driver_fail 'tcpdump did not start'
}

fr13_end() {
  local n="$EDGE_NAME" kind address
  sleep 3
  kill -INT "$EDGE_PID"
  wait "$EDGE_PID" || true
  [ "$(stat -c %s "$XRAY_ACCESS")" -ge "$EDGE_ACCESS" ] || driver_fail "$n: the access log shrank during the case"
  tail -c "+$((EDGE_ACCESS + 1))" "$XRAY_ACCESS" >"$phase_dir/$n-access.txt"
  tail -c "+$((EDGE_STANDIN + 1))" "$EVIDENCE/standin/connections.jsonl" | grep -v '"event"' \
    >"$phase_dir/$n-standin.jsonl" || true
  if [ "$EDGE_ERROR" -ge 0 ]; then
    [ "$(stat -c %s "$XRAY_ERROR")" -ge "$EDGE_ERROR" ] || driver_fail "$n: the error log shrank during the case"
    # Only the outbound side, which the judgments of VT-34 read.
    tail -c "+$((EDGE_ERROR + 1))" "$XRAY_ERROR" |
      grep -E '\] (app/proxyman/outbound|proxy/freedom|transport/internet): ' >"$phase_dir/$n-error.txt" || true
  fi
  for kind in 4 6; do
    address="$STANDIN"
    [ "$kind" = 4 ] || address="$STANDIN6"
    tcpdump -nn -tt -r "$PRIVATE/edge-$n.pcap" "tcp and dst host $address and dst port 80" 2>/dev/null |
      awk '/Flags \[S\],/' >"$phase_dir/$n-syn$kind.txt"
    tcpdump -nn -tt -r "$PRIVATE/edge-$n.pcap" "udp and dst host $address" >"$phase_dir/$n-udp$kind.txt" 2>/dev/null
  done
  tcpdump -nn -tt -r "$PRIVATE/edge-$n.pcap" "tcp and dst host $STANDIN and dst port 443" 2>/dev/null |
    awk '/Flags \[S\],/' >"$phase_dir/$n-syn4-target.txt"
  printf 'access log %s lines, stand-in %s records; SYN to port 80 on IPv4 %s, on IPv6 %s; UDP to IPv4 %s, to IPv6 %s; SYN to the target on IPv4 port 443 %s\n' \
    "$(grep -c . "$phase_dir/$n-access.txt")" "$(grep -c . "$phase_dir/$n-standin.jsonl")" \
    "$(grep -c . "$phase_dir/$n-syn4.txt")" "$(grep -c . "$phase_dir/$n-syn6.txt")" \
    "$(grep -c . "$phase_dir/$n-udp4.txt")" "$(grep -c . "$phase_dir/$n-udp6.txt")" \
    "$(grep -c . "$phase_dir/$n-syn4-target.txt")" >"$phase_dir/$n-edge.txt"
}

# fr13_get CASE NAME COUNT: COUNT plain HTTP requests for NAME over the node
# (Mihomo in global mode, as in VT-20); writes CASE.txt with one line per
# request and sets FR13_OK to how many got 200 with the stand-in's body for
# NAME.
FR13_OK=0
fr13_get() {
  local i
  FR13_OK=0
  : >"$phase_dir/$1.txt"
  for i in $(seq "$3"); do
    client_curl "$1-$i" -x http://127.0.0.1:7890 "http://$2/"
    printf '%s: curl exit %s, HTTP %s\n' "$i" "$CURL_RC" "$CURL_HTTP" >>"$phase_dir/$1.txt"
    if [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] && grep -qxF "stand-in $2" "$phase_dir/$1-$i.body"; then
      FR13_OK=$((FR13_OK + 1))
    fi
  done
}

# fr13_tcp LABEL CASE NAME COUNT FAMILY [SOURCE]: the judgment of one case
# that succeeds over TCP: the stand-in's HTTP service got exactly COUNT
# connections for NAME, all on its address of FAMILY (4 or 6) and from SOURCE
# (default the guest's address of that family on the veth); no SYN went to
# its HTTP port of the other family; every other TCP connection to the
# stand-in is the node reaching its target (target.example on IPv4 port 443,
# see fr13_end); the access log routed each request from the REALITY inbound
# to ai-ipv6.
fr13_tcp() {
  local label="$1 $2" case="$2" name="$3" count="$4" reality address source other
  if [ "$5" = 6 ]; then
    address="$STANDIN6" source="${6:-$GUEST6}" other=4
  else
    address="$STANDIN" source="${6:-$GUEST4}" other=6
  fi
  reality="$(xray_tag 443)"
  jq -se --arg h "$name" --argjson c "$count" --arg l "$address:80" --arg s "$source" '[.[] | select(.plain)]
    | length == $c and all(.[]; .local == $l and (.peer | sub(":[0-9]+$"; "")) == $s
      and .requests[0].host == $h and .requests[0].status == 200)' "$phase_dir/$case-standin.jsonl" >/dev/null ||
    fail "$label: the stand-in did not get exactly $count HTTP connections for $name on $address from $source"
  fr13_only_target "$label" "$case"
  [ ! -s "$phase_dir/$case-syn$other.txt" ] || fail "$label: a SYN went to the stand-in's IPv$other HTTP port"
  [ "$(grep -cF "accepted tcp:$name:80 [$reality -> ai-ipv6]" "$phase_dir/$case-access.txt")" = "$count" ] ||
    fail "$label: the access log does not route each request for $name from the REALITY inbound to ai-ipv6"
}

# fr13_only_target LABEL CASE: every TCP connection of the case to the
# stand-in other than its HTTP service is the node reaching its target.
fr13_only_target() {
  jq -se --arg t "$STANDIN:443" 'all(.[] | select((.plain or .udp) | not); .local == $t and .sni == "target.example")' \
    "$phase_dir/$2-standin.jsonl" >/dev/null ||
    fail "$1: the stand-in got a TCP connection that is neither HTTP nor the node reaching its target"
}

# VT-32, TCP. The route test first; then the two test domains on both
# stand-in addresses, ten requests each; one of them on the IPv6 address
# only, ten requests; check; a second address on the /64, check and one
# request. The egress isolation is on throughout; tests/vm.py judges the two
# check results.
phase_vt32() {
  local reality fwd openai anthropic seen
  reality="$(xray_tag 443)"
  fwd="$(xray_tag 20443)"
  openai="$(geo_pick site openai)"
  anthropic="$(geo_pick site anthropic)"
  printf '%s\n' "geosite:openai: $openai" "geosite:anthropic: $anthropic" >"$phase_dir/vt32-domains.txt"
  stop_time_sync
  isolation_on
  panel_login
  rm -f "$phase_dir/routes.jsonl"
  route_test openai "$reality" domain "$openai"
  route_test anthropic "$reality" domain "$anthropic"
  route_test forwarder "$fwd" domain "$openai"
  jq -r '"\(.case) (\(.query)): matched \(.matched), outbound \(if .outboundTag == "" then "none" else .outboundTag end)"' \
    "$phase_dir/routes.jsonl" >"$phase_dir/vt32-routes.txt"
  route_is openai true ai-ipv6 || fail "VT-32: $openai from the REALITY inbound is not routed to ai-ipv6"
  route_is anthropic true ai-ipv6 || fail "VT-32: $anthropic from the REALITY inbound is not routed to ai-ipv6"
  route_is forwarder true blocked || fail "VT-32: $openai from the forwarder is not routed to blocked"

  fr13_hosts "$openai" 4 6
  fr13_hosts "$anthropic" 4 6
  mihomo_up main 7890
  fr13_begin vt32-dual-openai
  fr13_get vt32-dual-openai "$openai" 10
  fr13_end
  [ "$FR13_OK" = 10 ] || fail "VT-32: $FR13_OK of 10 requests for $openai (both addresses) succeeded"
  fr13_tcp VT-32 vt32-dual-openai "$openai" 10 6
  fr13_begin vt32-dual-anthropic
  fr13_get vt32-dual-anthropic "$anthropic" 10
  fr13_end
  [ "$FR13_OK" = 10 ] || fail "VT-32: $FR13_OK of 10 requests for $anthropic (both addresses) succeeded"
  fr13_tcp VT-32 vt32-dual-anthropic "$anthropic" 10 6

  fr13_hosts "$anthropic" 6
  fr13_begin vt32-v6only
  fr13_get vt32-v6only "$anthropic" 10
  fr13_end
  [ "$FR13_OK" = 10 ] || fail "VT-32: $FR13_OK of 10 requests for $anthropic (IPv6 only) succeeded"
  fr13_tcp VT-32 vt32-v6only "$anthropic" 10 6
  mihomo_log main

  m2_check check
  isolation_judge VT-32 vt32 "$openai" "$anthropic"

  ip -6 addr add "$GUEST6_EXTRA/64" dev vps-standin0 nodad
  m2_check check-extra
  fr13_begin vt32-extra
  fr13_get vt32-extra "$openai" 1
  fr13_end
  [ "$FR13_OK" = 1 ] || fail "VT-32: the request for $openai after the second address failed"
  seen="$(jq -rs '[.[] | select(.plain) | .peer | sub(":[0-9]+$"; "")] | unique | join(" ")' \
    "$phase_dir/vt32-extra-standin.jsonl")"
  printf 'source address seen by the stand-in with two addresses on the /64: %s\n' "$seen" \
    >"$phase_dir/vt32-extra.txt"
  case "$seen" in
    "$GUEST6" | "$GUEST6_EXTRA") fr13_tcp VT-32 vt32-extra "$openai" 1 6 "$seen" ;;
    *) fail "VT-32: after the second address the stand-in saw the source $seen" ;;
  esac
  isolation_judge 'VT-32 after the second address' vt32-extra "$openai" "$anthropic"
}

# VT-32, UDP: tests/guest/udpsend.py sends ten datagrams to each test domain,
# on both stand-in addresses, as a domain through Mihomo's SOCKS5 UDP to the
# stand-in's echo port. Mihomo resolves the destination of UDP itself before
# it sends (ResolveUDP in adapter/outbound/vless.go at v1.19.33) and does not
# read the guest's hosts file, so it gets the two names in its own hosts
# table, as a client with its own DNS would. The node then receives an IP
# literal, which the FR-13 rule does not match: judged as accepted in D40
# (requirements), not as verification plan 4.5 expects. Every UDP line of the
# access log is a stand-in address from the REALITY inbound to blocked, by the
# template's geoip:private rule, since the stand-ins are private addresses (a
# public address falls through to direct); none names a test domain, and no
# datagram reaches the stand-in. A test domain in the access log means
# Mihomo has stopped resolving UDP itself: review D40.
phase_vt32_udp() {
  local openai anthropic
  openai="$(geo_pick site openai)"
  anthropic="$(geo_pick site anthropic)"
  stop_time_sync
  isolation_on
  fr13_hosts "$openai" 4 6
  fr13_hosts "$anthropic" 4 6
  mihomo_up main 7890 hosts "$(fr13_udp_hosts "$openai" "$anthropic")"
  fr13_begin vt32-udp
  fr13_udp_send vt32-udp "$openai" "$anthropic"
  fr13_end
  mihomo_log main
  isolation_judge 'VT-32 UDP' vt32-udp "$openai" "$anthropic"
  fr13_udp_judge 'VT-32 UDP' vt32-udp "$openai" "$anthropic"
}

# fr13_udp_hosts NAME...: Mihomo's hosts table for the UDP cases, each NAME
# to both stand-in addresses.
fr13_udp_hosts() {
  printf '%s\n' "$@" | jq -cRn --arg v4 "$STANDIN" --arg v6 "$STANDIN6" '[inputs | {(.): [$v4, $v6]}] | add'
}

# fr13_udp_send CASE NAME...: ten datagrams to each NAME, as a domain, through
# Mihomo's SOCKS5 UDP to the stand-in's echo port; one line per NAME in
# CASE.jsonl.
fr13_udp_send() {
  local case="$1" name
  for name in "${@:2}"; do
    ip netns exec vpsns-client python3 "$BUNDLE/tests/guest/udpsend.py" --proxy 127.0.0.1:7890 --host "$name" \
      --port "$UDP_ECHO_PORT" --count 10 >>"$phase_dir/$case.jsonl"
  done
}

# fr13_udp_judge LABEL CASE NAME...: the behaviour accepted in D40 (see
# phase_vt32_udp): the client sent ten datagrams to each NAME; the node never
# received a NAME as the destination; every UDP line of the access log, at
# least two, is a stand-in address from the REALITY inbound to blocked; no
# datagram reached the stand-in or shows in the capture.
fr13_udp_judge() {
  local label="$1" case="$2" name reality total literal
  reality="$(xray_tag 443)"
  grep -F ' accepted udp:' "$phase_dir/$case-access.txt" | sed -E 's/^.* accepted //' | sort | uniq -c \
    >"$phase_dir/$case-node.txt" || true
  for name in "${@:3}"; do
    jq -se --arg h "$name" '[.[] | select(.host == $h)] | length == 1 and .[0].sent == 10 and (.[0] | has("error") | not)' \
      "$phase_dir/$case.jsonl" >/dev/null || fail "$label: the client did not send ten datagrams to $name"
    ! grep -qF " accepted udp:$name:" "$phase_dir/$case-access.txt" ||
      fail "$label: the node received $name as the destination; Mihomo no longer resolves UDP itself, review D40"
  done
  total="$(grep -cF ' accepted udp:' "$phase_dir/$case-access.txt" || true)"
  literal="$(grep -cF -e " accepted udp:$STANDIN:$UDP_ECHO_PORT [$reality -> blocked]" \
    -e " accepted udp:[$STANDIN6]:$UDP_ECHO_PORT [$reality -> blocked]" "$phase_dir/$case-access.txt" || true)"
  [ "$total" -ge 2 ] && [ "$literal" = "$total" ] ||
    fail "$label: not every UDP line of the access log ($literal of $total, at least 2) is a stand-in address to blocked"
  jq -se 'all(.[]; .udp | not)' "$phase_dir/$case-standin.jsonl" >/dev/null ||
    fail "$label: a datagram reached the stand-in"
  [ ! -s "$phase_dir/$case-udp4.txt" ] && [ ! -s "$phase_dir/$case-udp6.txt" ] ||
    fail "$label: the capture has a datagram to the stand-in"
}

# fr13_one_address: VT-32 leaves a second address on the /64; the cases after
# it start again from one address and one default route.
fr13_one_address() {
  if grep -qF " $GUEST6_EXTRA/" <(ip -6 addr show dev vps-standin0); then
    ip -6 addr del "$GUEST6_EXTRA/64" dev vps-standin0
  fi
  [ "$(vps_fn ipv6_egress_facts)" = '1 0 1' ] ||
    driver_fail 'the guest does not have exactly one usable IPv6 address and route'
}

# VT-33 ①, on the overlay with FR-13 enabled. The route test of the two
# stand-in literals from the REALITY inbound does not give ai-ipv6; a test
# domain with only the IPv4 stand-in in the hosts file still goes to ai-ipv6,
# which reaches it over IPv4 (ForceIPv6v4 falls back when there is no IPv6
# address); probe.example goes to direct and the geosite:cn domain of VT-30
# to blocked, by the access log. The egress isolation is on throughout.
phase_vt33() {
  local reality openai cn_domain cn_rc cn_code
  reality="$(xray_tag 443)"
  openai="$(geo_pick site openai)"
  cn_domain="$(geo_pick site cn)"
  printf '%s\n' "geosite:openai: $openai" "geosite:cn: $cn_domain" >"$phase_dir/vt33-domains.txt"
  fr13_one_address
  stop_time_sync
  isolation_on
  panel_login
  rm -f "$phase_dir/routes.jsonl"
  route_test literal4 "$reality" ip "$STANDIN"
  route_test literal6 "$reality" ip "$STANDIN6"
  jq -r '"\(.case) (\(.query)): matched \(.matched), outbound \(if .outboundTag == "" then "none" else .outboundTag end)"' \
    "$phase_dir/routes.jsonl" >"$phase_dir/vt33-routes.txt"
  jq -se 'length == 2 and all(.[]; .outboundTag != "ai-ipv6")' "$phase_dir/routes.jsonl" >/dev/null ||
    fail 'VT-33: a stand-in literal from the REALITY inbound would go to ai-ipv6'

  fr13_hosts "$openai" 4
  mihomo_up main 7890
  fr13_begin vt33-v4only
  fr13_get vt33-v4only "$openai" 10
  fr13_end
  [ "$FR13_OK" = 10 ] || fail "VT-33: $FR13_OK of 10 requests for $openai (IPv4 only) succeeded"
  fr13_tcp VT-33 vt33-v4only "$openai" 10 4

  fr13_begin vt33-others
  client_curl vt33-cn -x http://127.0.0.1:7890 "https://$cn_domain/"
  cn_rc="$CURL_RC" cn_code="$CURL_HTTP"
  client_curl vt33-probe -x http://127.0.0.1:7890 http://probe.example/
  fr13_end
  mihomo_log main
  printf '%s\n' "$cn_domain: curl exit $cn_rc, HTTP $cn_code" "probe.example: curl exit $CURL_RC, HTTP $CURL_HTTP" \
    >"$phase_dir/vt33-others.txt"
  { [ "$cn_rc" != 0 ] || [ "$cn_code" != 200 ]; } || fail "VT-33: $cn_domain was reached over the node"
  grep -qF "accepted tcp:$cn_domain:443 [$reality -> blocked]" "$phase_dir/vt33-others-access.txt" ||
    fail "VT-33: the access log does not show $cn_domain routed from the REALITY inbound to blocked"
  [ "$(grep -cF "tcp:$cn_domain:" "$phase_dir/vt33-others-access.txt")" = \
    "$(grep -cF "tcp:$cn_domain:443 [$reality -> blocked]" "$phase_dir/vt33-others-access.txt")" ] ||
    fail "VT-33: $cn_domain was also routed elsewhere"
  { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ] && grep -qx 'stand-in probe.example' "$phase_dir/vt33-probe.body"; } ||
    fail 'VT-33: http://probe.example/ over the node failed'
  grep -qF "accepted tcp:probe.example:80 [$reality >> direct]" "$phase_dir/vt33-others-access.txt" ||
    fail 'VT-33: the access log does not show probe.example from the REALITY inbound to direct'
  isolation_judge VT-33 vt33 "$openai"
}

# VT-33 ②: the same overlay deployed with FR-13 off.
phase_fr13_off_deploy() { full_deploy fr13-off-deploy "$M2_INPUT"; }

# The database part of VT-16 on that deploy, for its shortId digest: the two
# deploys of the job compare their shortIds (tests/vm.py).
phase_fr13_off_vt16() {
  collect_markers
  vt16_db fr13-off off || fail 'fr13-off: VT-16 database checks failed'
  scan_markers
}

# Neither the template nor the generated config has the outbound or the rule
# of FR-13. A test domain with both stand-in addresses goes to direct, by the
# access log. Its address family is recorded, not judged: direct has no
# domain strategy of its own, and the system's choice between the two
# families is not part of FR-13. tests/vm.py judges check against the M2
# baseline; here, that its two FR-13 items say that FR-13 is off.
phase_vt33_off() {
  local reality openai
  reality="$(xray_tag 443)"
  openai="$(geo_pick site openai)"
  printf 'geosite:openai: %s\n' "$openai" >"$phase_dir/vt33-off-domains.txt"
  stop_time_sync
  isolation_on
  panel_login
  panel_api POST xray/
  jq -e '.obj | fromjson | .xraySetting | ([.outbounds[]? | select(.tag == "ai-ipv6")] | length == 0)
    and ([.routing.rules[]? | select(.outboundTag == "ai-ipv6")] | length == 0)' "$PANEL_OUT" >/dev/null ||
    fail 'VT-33: the Xray template has the outbound or the rule of FR-13'
  jq -e '([.outbounds[] | select(.tag == "ai-ipv6")] | length == 0)
    and ([.routing.rules[] | select(.outboundTag == "ai-ipv6")] | length == 0)' "$XRAY_CONFIG" >/dev/null ||
    fail 'VT-33: the generated Xray config has the outbound or the rule of FR-13'

  fr13_hosts "$openai" 4 6
  mihomo_up main 7890
  fr13_begin vt33-off
  fr13_get vt33-off "$openai" 10
  fr13_end
  mihomo_log main
  jq -r '[.[] | select(.plain) | .local] | group_by(.) | map("\(length) on \(.[0])") | join(", ")' -s \
    "$phase_dir/vt33-off-standin.jsonl" >"$phase_dir/vt33-off-family.txt"
  [ "$FR13_OK" = 10 ] || fail "VT-33: $FR13_OK of 10 requests for $openai succeeded with FR-13 off"
  jq -se --arg h "$openai" --arg a "$STANDIN:80" --arg b "$STANDIN6:80" '[.[] | select(.plain)]
    | length == 10 and all(.[]; (.local == $a or .local == $b) and .requests[0].host == $h)' \
    "$phase_dir/vt33-off-standin.jsonl" >/dev/null ||
    fail "VT-33: the stand-in did not get exactly 10 HTTP connections for $openai with FR-13 off"
  fr13_only_target 'VT-33 vt33-off' vt33-off
  [ "$(grep -cF "accepted tcp:$openai:80 [$reality >> direct]" "$phase_dir/vt33-off-access.txt")" = 10 ] ||
    fail "VT-33: with FR-13 off the access log does not route each request for $openai to direct"
  m2_check check
  fr13_says_off check
  isolation_judge 'VT-33 with FR-13 off' vt33-off "$openai"
}

# standin6_filter -I|-D TARGET...: insert or delete the rule of the stand-in's
# namespace that answers TCP to its IPv6 HTTP port with TARGET.
standin6_filter() {
  local op="$1"
  shift
  ip netns exec vpsns-standin ip6tables -w "$op" INPUT -p tcp -d "$STANDIN6" --dport 80 "$@"
}

# error_line_has CASE TEXT...: one outbound line of the case's Xray error log
# has every TEXT.
error_line_has() {
  local line text
  while IFS= read -r line; do
    for text in "${@:2}"; do
      [[ "$line" == *"$text"* ]] || continue 2
    done
    return 0
  done <"$phase_dir/$1-error.txt"
  return 1
}

# vt34_case CASE NAME MAX_TIME TEXT...: one request for NAME over the node,
# which curl gives up after MAX_TIME seconds; it must fail. The stand-in's
# HTTP service got no connection on either address, no SYN went to its IPv4
# HTTP port, every other TCP connection is the node reaching its target, the
# access log routed the request from the REALITY inbound to ai-ipv6, and one
# outbound line of the Xray error log has every TEXT. The first TEXT is
# awaited for up to a minute after curl returns: a failed lookup is logged
# when the resolver gives up.
vt34_case() {
  local case="$1" name="$2" reality
  reality="$(xray_tag 443)"
  fr13_begin "$case"
  client_curl "$case" --max-time "$3" -x http://127.0.0.1:7890 "http://$name/"
  for _ in $(seq 60); do
    ! grep -qF -- "$4" <(tail -c "+$((EDGE_ERROR + 1))" "$XRAY_ERROR") || break
    sleep 1
  done
  fr13_end
  ! { [ "$CURL_RC" = 0 ] && [ "$CURL_HTTP" = 200 ]; } || fail "VT-34 $case: the request for $name succeeded"
  jq -se '[.[] | select(.plain)] | length == 0' "$phase_dir/$case-standin.jsonl" >/dev/null ||
    fail "VT-34 $case: the stand-in's HTTP service got a connection"
  fr13_only_target "VT-34 $case" "$case"
  [ ! -s "$phase_dir/$case-syn4.txt" ] || fail "VT-34 $case: a SYN went to the stand-in's IPv4 HTTP port"
  grep -qF "accepted tcp:$name:80 [$reality -> ai-ipv6]" "$phase_dir/$case-access.txt" ||
    fail "VT-34 $case: the access log does not route the request for $name from the REALITY inbound to ai-ipv6"
  error_line_has "$case" "${@:4}" || fail "VT-34 $case: no outbound line of the Xray error log has: ${*:4}"
}

# VT-34, on the overlay with FR-13 enabled. The Xray error log goes on at Info
# first, a test deviation: the outbound logs its failures at that level. A
# test domain with both stand-in addresses then fails in each case: the IPv6
# stand-in refuses; it drops (Xray dials five times, up to 16 s each, so the
# client waits longer than that); the AAAA is another address of the /64,
# which the finalRules of ai-ipv6 block; the guest has no IPv6 address or
# route, where UDP is judged as in VT-32 (D40), a test domain with only the
# IPv4 stand-in still succeeds over IPv4, and tests/vm.py judges check; no
# hosts record, where the lookup goes to DNS, which the egress isolation
# rejects. Before that last case the isolation passes as in isolation_judge;
# in it, the isolation rejects DNS queries and nothing else, and the
# resolver's log has the lookup of the test domain.
phase_vt34() {
  local openai anthropic n
  openai="$(geo_pick site openai)"
  anthropic="$(geo_pick site anthropic)"
  printf '%s\n' "geosite:openai: $openai" "geosite:anthropic: $anthropic" >"$phase_dir/vt34-domains.txt"
  fr13_one_address
  stop_time_sync
  panel_login
  template_edit '.log.error = "'"$XRAY_ERROR"'" | .log.loglevel = "info"'
  wait_port 443 exposed
  wait_port 20443 loopback
  wait_xui_stable
  for _ in $(seq 60); do
    [ ! -e "$XRAY_ERROR" ] || break
    sleep 1
  done
  jq -e --arg e "$XRAY_ERROR" '.log.error == $e and .log.loglevel == "info"' "$XRAY_CONFIG" >/dev/null ||
    fail 'the generated Xray config does not have the error log at Info'
  [ -f "$XRAY_ERROR" ] || fail "Xray did not create $XRAY_ERROR"
  printf '%s\n' "deviation: the Xray error log is on at $XRAY_ERROR with loglevel info (VT-34)" \
    >"$phase_dir/deviations.txt"
  isolation_on
  fr13_hosts "$openai" 4 6
  mihomo_up main 7890

  standin6_filter -I -j REJECT --reject-with tcp-reset
  vt34_case vt34-refused "$openai" 20 "failed to open connection to tcp:$openai:80" "[$STANDIN6]:80" \
    'connection refused'
  standin6_filter -D -j REJECT --reject-with tcp-reset
  standin6_filter -I -j DROP
  vt34_case vt34-dropped "$openai" 120 "failed to open connection to tcp:$openai:80" "[$STANDIN6]:80" 'i/o timeout'
  standin6_filter -D -j DROP
  fr13_hosts "$openai" 4 "$BLOCKED6"
  vt34_case vt34-blocked "$openai" 20 "blocked target: tcp:[$BLOCKED6]:80"
  isolation_judge VT-34 vt34 "$openai" "$anthropic"

  fr13_hosts "$openai" 4 6
  fr13_hosts "$anthropic" 4
  ip -6 route del default via "$STANDIN6" dev vps-standin0
  ip -6 addr del "$GUEST6/64" dev vps-standin0
  [ "$(vps_fn ipv6_egress_facts)" = '0 0 0' ] || driver_fail 'the guest still has an IPv6 address or route'
  vt34_case vt34-noipv6 "$openai" 20 "failed to open connection to tcp:$openai:80" "[$STANDIN6]:80" \
    'network is unreachable'
  fr13_begin vt34-noipv6-v4only
  fr13_get vt34-noipv6-v4only "$anthropic" 10
  fr13_end
  [ "$FR13_OK" = 10 ] || fail "VT-34: without IPv6, $FR13_OK of 10 requests for $anthropic (IPv4 only) succeeded"
  fr13_tcp VT-34 vt34-noipv6-v4only "$anthropic" 10 4
  m2_check check-noipv6
  mihomo_up main 7890 hosts "$(fr13_udp_hosts "$openai" "$anthropic")"
  fr13_begin vt34-noipv6-udp
  fr13_udp_send vt34-noipv6-udp "$openai" "$anthropic"
  fr13_end
  fr13_udp_judge 'VT-34 UDP' vt34-noipv6-udp "$openai" "$anthropic"
  mihomo_log main
  ip -6 addr add "$GUEST6/64" dev vps-standin0 nodad
  ip -6 route add default via "$STANDIN6" dev vps-standin0
  [ "$(vps_fn ipv6_egress_facts)" = '1 0 1' ] || driver_fail 'the IPv6 address and route did not come back'
  isolation_judge 'VT-34 without IPv6' vt34-noipv6 "$openai" "$anthropic"

  mihomo_up main 7890
  fr13_hosts "$openai"
  isolation_on
  vt34_case vt34-nodns "$openai" 20 "failed to get IP address for domain $openai"
  n="$(isolation_counts vt34-nodns)"
  [ "${n% *}" -gt 0 ] && [ "${n#* }" = 0 ] ||
    fail "VT-34 vt34-nodns: the egress isolation rejected ${n% *} DNS queries and ${n#* } other connections; expected DNS queries only"
  resolved_asked vt34-nodns "$openai" || fail "VT-34 vt34-nodns: the resolver's log has no lookup of $openai"
  ! resolved_asked vt34-nodns "$anthropic" || fail "VT-34 vt34-nodns: systemd-resolved was asked for $anthropic"
}

main "$@"
