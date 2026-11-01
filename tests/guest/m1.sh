#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/../../lib/vps-proxy-setup
# Guest side of the M1 VM tests (detailed design 9; verification plan VT-01 to
# VT-05, VT-71 to VT-76, VT-80 and VT-81). Runs as root inside a disposable
# QEMU guest; tests/vm.py runs one phase per SSH session and judges the check
# results of VT-71 against the baseline. Adapted from vps-hardening's
# tests/guest/m1.sh.

set -Eeuo pipefail
umask 077
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
LC_ALL=C
DEBIAN_FRONTEND=noninteractive
export PATH LC_ALL DEBIAN_FRONTEND

readonly BUNDLE=/opt/vps-bundle
readonly LIB="$BUNDLE/lib/vps-proxy-setup"
readonly FIXTURES="$BUNDLE/fixtures"
readonly TOOL=/usr/local/bin/vps-proxy-setup
readonly VH=/usr/local/bin/vps-hardening
readonly EVIDENCE=/root/vps-evidence
# Never archived: the test token, the panel credentials, values read from the
# 3X-UI database and the test CA.
readonly PRIVATE=/root/vps-private
readonly CA_DIR="$PRIVATE/ca"
readonly CA_TRUSTED=/usr/local/share/ca-certificates/vps-proxy-setup-test-ca.crt
readonly XUI_DB=/etc/x-ui/x-ui.db
readonly XUI_RESULT=/etc/x-ui/install-result.env
readonly STANDIN=198.51.100.2
# Plan bandwidth for vps-tuning in Mbps; any value in its range will do here.
readonly TUNING_PORT=100
# A flag (two regional indicators) and text; the second also has CJK characters.
readonly REMARK_JP=$'\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5 Tokyo-01'
readonly REMARK_SG=$'\xf0\x9f\x87\xb8\xf0\x9f\x87\xac \xe6\x96\xb0\xe5\x8a\xa0\xe5\x9d\xa1-01'
readonly PREFLIGHT_PASS=(root platform deps apt.idle hardening.state hardening.version hardening.panel-port
  hardening.verify new-host.xui new-host.xui-db new-host.cloudflared new-host.state ports.free tuning.dropin
  target.checked)

phase_dir=''
obs_pause=0
capture_pid=''

log() { printf '[+] %s\n' "$*"; }
fail() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

# vps_fn FUNC ARGS...: a function of the tool's read-only modules in a
# subshell; the VT-72 driver loads the read functions this way (detailed
# design 9.3).
vps_fn() {
  (
    . "$LIB/common.sh"
    . "$LIB/pins.sh"
    . "$LIB/probe.sh"
    . "$LIB/xuidb.sh"
    "$@"
  )
}

# pin_value NAME: a pinned value of pins.sh, through vps_fn.
pin_value() {
  printf '%s
' "${!1}"
}

state_value() {
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' /var/lib/vps-hardening/state
}

tool_version() {
  sed -n "s/^readonly VPS_VERSION='\(.*\)'$/\1/p" "$BUNDLE/bin/vps-proxy-setup"
}

# capture NAME CMD...: run CMD with stdin from /dev/null; keep stdout, stderr
# and the exit status.
capture() {
  local name="$1" rc=0
  shift
  "$@" </dev/null >"$phase_dir/$name.out" 2>"$phase_dir/$name.err" || rc=$?
  printf '%s\n' "$rc" >"$phase_dir/$name.rc"
  log "$name: exit $rc"
  sed 's/^/    /' "$phase_dir/$name.out" "$phase_dir/$name.err"
}

# on_tty ERR CMD...: CMD on a new pseudo-terminal, as deploy requires. The
# only input is end of file. The command's stderr goes to the file ERR instead
# of the terminal, so the two streams can be told apart. CMD is executed
# directly: it cannot be a shell function.
on_tty() {
  timeout --kill-after=10 600 python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(f, 2)
    os.close(f)
    os.execvp(sys.argv[2], sys.argv[2:])
os.write(fd, b"\x04")
out = bytearray()
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
sys.stdout.buffer.write(bytes(out).replace(b"\r\n", b"\n"))
sys.stdout.flush()
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
' "$@"
}

capture_tty() {
  local name="$1" rc=0
  shift
  on_tty "$phase_dir/$name.err" "$@" >"$phase_dir/$name.out" || rc=$?
  printf '%s\n' "$rc" >"$phase_dir/$name.rc"
  log "$name (terminal): exit $rc"
  sed 's/^/    /' "$phase_dir/$name.out" "$phase_dir/$name.err"
}

# "${BOUND[@]}" FILE TARGET CMD...: run CMD with FILE over TARGET, visible only
# in a private mount namespace. A command, not a function, so that on_tty can
# run it.
# shellcheck disable=SC2016 # expanded by sh
readonly BOUND=(unshare --mount --propagation private -- sh -c 'mount --bind "$1" "$2" && shift 2 && exec "$@"' sh)

expect_rc() {
  local got
  got="$(cat "$phase_dir/$1.rc")"
  [ "$got" = "$2" ] || fail "$1: exit status $got, expected $2"
}

# expect_report NAME LEVEL ID...
expect_report() {
  local name="$1" level="$2" id
  shift 2
  for id in "$@"; do
    grep -qE "^\[$level\] ${id//./\\.}( |$)" "$phase_dir/$name.out" || fail "$name: no [$level] $id line"
  done
}

# expect_fails NAME ID...: exactly these items FAIL.
expect_fails() {
  local name="$1" got want
  shift
  got="$(sed -n 's/^\[FAIL\] \([^ ]*\).*/\1/p' "$phase_dir/$name.out" | sort)"
  want="$(printf '%s\n' "$@" | sed '/^$/d' | sort)"
  [ "$got" = "$want" ] || fail "$name: FAIL items are [$(tr '\n' ' ' <<<"$got")], expected [$*]"
}

expect_text() {
  grep -qF -- "$2" "$phase_dir/$1.out" || fail "$1: stdout lacks: $2"
}

expect_err() {
  grep -qF -- "$2" "$phase_dir/$1.err" || fail "$1: stderr lacks: $2"
}

# expect_clean NAME: no internal error (exit status 3, detailed design 2.2).
expect_clean() {
  if grep -qF '内部错误' "$phase_dir/$1.out" "$phase_dir/$1.err"; then
    fail "$1: internal error"
  fi
}

# expect_no_secret NAME: none of the test secrets in the output (VT-03, VT-74).
expect_no_secret() {
  [ -s "$PRIVATE/markers" ] || return 0
  if grep -qF -f "$PRIVATE/markers" "$phase_dir/$1.out" "$phase_dir/$1.err"; then
    fail "$1: a test secret appears in the output"
  fi
}

# Everything a read-only command must leave as it was (verification plan 4,
# detailed design 9.4). Excluded: /etc/resolv.conf and /etc/adjtime; the
# content of the 3X-UI database files, compared by db_digest instead; the
# panel's metrics file, which it rewrites every minute; rule counters.
snapshot() {
  local name="$1" unit
  {
    echo '== /etc metadata'
    find /etc -xdev -printf '%M %u:%g %p -> %l\n' | sort || echo "find exit $?"
    echo '== /etc content'
    find /etc -xdev -type f ! -path /etc/resolv.conf ! -path /etc/adjtime ! -path '/etc/x-ui/x-ui.db*' \
      ! -path /etc/x-ui/system_metrics.gob -print0 | sort -z | xargs -0 -r sha256sum || echo "sha256sum exit $?"
    echo '== ufw'
    ufw status verbose || echo "ufw exit $?"
    echo '== nft'
    nft -s list ruleset || echo "nft exit $?"
    echo '== units'
    for unit in x-ui.service fail2ban.service ufw.service cloudflared.service vps-proxy-setup-cloudflared.service \
      cloudflared-update.timer; do
      printf '%s %s %s\n' "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
        "$(systemctl is-active "$unit" 2>/dev/null || true)"
    done
    echo '== listeners'
    ss -Hltnu | awk '{ print $1, $5 }' | sort -u || echo "ss exit $?"
    echo '== packages'
    dpkg-query -W -f '${Package}:${Architecture} ${Version} ${db:Status-Abbrev}\n' || echo "dpkg-query exit $?"
  } >"$phase_dir/snap-$name.txt" 2>&1
  db_digest "$phase_dir/db-$name.json"
}

# db_digest OUT: schema, row and column digests of the 3X-UI database, read in
# one transaction with the open mode the tool itself chooses for the current
# state (detailed design 4.1). Values never leave Python; only digests do.
db_digest() {
  local out="$1" state uri
  if [ ! -e "$XUI_DB" ]; then
    printf '{"state": "absent"}\n' >"$out"
    return 0
  fi
  if ! state="$(vps_fn xui_db_state)" || ! uri="$(vps_fn xui_db_uri "$state")"; then
    printf '{"state": "unreadable"}\n' >"$out"
    return 0
  fi
  python3 - "$uri" "$out" <<'PY'
import hashlib, json, sqlite3, sys

uri, out = sys.argv[1], sys.argv[2]


def digest(values):
    return hashlib.sha256(json.dumps(values, default=lambda v: v.hex()).encode()).hexdigest()


con = sqlite3.connect(uri, uri=True, timeout=5, isolation_level=None)
try:
    con.execute('BEGIN')
    schema = con.execute('SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name').fetchall()
    result = {'state': 'immutable' if 'immutable=1' in uri else 'ro', 'schema': digest(schema), 'tables': {}}
    tables = con.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
                         'ORDER BY name').fetchall()
    for (table,) in tables:
        quoted = '"' + table.replace('"', '""') + '"'
        columns = [row[1] for row in con.execute(f'PRAGMA table_info({quoted})')]
        rows = con.execute(f'SELECT rowid, * FROM {quoted} ORDER BY rowid').fetchall()
        entry = {'<rows>': len(rows), '<rowid>': digest([r[0] for r in rows])}
        for i, column in enumerate(columns, 1):
            entry[column] = digest([r[i] for r in rows])
        result['tables'][table] = entry
    con.execute('ROLLBACK')
finally:
    con.close()
with open(out, 'w') as f:
    json.dump(result, f, indent=1, sort_keys=True)
PY
}

# dbcmp A B [C1 C2]...: the database columns that differ between snapshots A
# and B must also differ within one of the control pairs, which x-ui wrote on
# its own while nothing else ran.
dbcmp() {
  local args=() name
  for name in "$@"; do
    args+=("$phase_dir/db-$name.json")
  done
  python3 - "$phase_dir/dbcmp-$1-$2.json" "${args[@]}" <<'PY'
import json, sys

report, a, b, controls = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]


def load(path):
    with open(path) as f:
        return json.load(f)


def changed(x, y):
    if x.get('state') != y.get('state'):
        return {'<state>'}
    out = {'<schema>'} if x.get('schema') != y.get('schema') else set()
    tx, ty = x.get('tables', {}), y.get('tables', {})
    for table in set(tx) | set(ty):
        cx, cy = tx.get(table, {}), ty.get(table, {})
        out |= {f'{table}.{c}' for c in set(cx) | set(cy) if cx.get(c) != cy.get(c)}
    return out


got = changed(load(a), load(b))
allowed = set()
for i in range(0, len(controls), 2):
    allowed |= changed(load(controls[i]), load(controls[i + 1]))
unexplained = sorted(got - allowed)
with open(report, 'w') as f:
    json.dump({'changed': sorted(got), 'written by x-ui (controls)': sorted(allowed),
               'unexplained': unexplained}, f, indent=1)
if unexplained:
    print('database columns changed:', ' '.join(unexplained), file=sys.stderr)
    sys.exit(1)
PY
}

# observe_begin NAME / observe_end NAME [ALLOW]: snapshots around commands.
# While x-ui runs, a control pair before the commands shows what x-ui writes on
# its own (detailed design 9.4).
observe_begin() {
  obs_pause=0
  [ "$(systemctl is-active x-ui.service 2>/dev/null || true)" != active ] || obs_pause=10
  snapshot "$1-c1"
  sleep "$obs_pause"
  snapshot "$1-before"
}

# ALLOW is a regex for /etc lines the commands may change (target-check's results).
observe_end() {
  local name="$1" allow="${2-}" unexplained
  snapshot "$name-after"
  if ! diff -u "$phase_dir/snap-$name-before.txt" "$phase_dir/snap-$name-after.txt" \
    >"$phase_dir/snap-$name.diff"; then
    unexplained="$(awk 'NR > 2 && /^[-+]/' "$phase_dir/snap-$name.diff")"
    [ -z "$allow" ] || unexplained="$(grep -vE -- "$allow" <<<"$unexplained" || true)"
    if [ -n "$unexplained" ]; then
      printf '%s\n' "$unexplained"
      fail "$name: the state changed"
    fi
  fi
  if ! dbcmp "$name-before" "$name-after" "$name-c1" "$name-before"; then
    # One more control pair after the commands, for writes x-ui makes less often.
    [ "$obs_pause" -gt 0 ] || fail "$name: the database changed"
    sleep "$obs_pause"
    snapshot "$name-c2"
    dbcmp "$name-before" "$name-after" "$name-c1" "$name-before" "$name-after" "$name-c2" ||
      fail "$name: the database changed beyond what x-ui writes on its own"
  fi
  log "$name: state unchanged"
}

# observe NAME CAPTURE CMD...: CAPTURE (capture or capture_tty) NAME CMD between snapshots.
observe() {
  local name="$1" how="$2"
  shift 2
  observe_begin "$name"
  "$how" "$name" "$@"
  observe_end "$name"
}

apt_busy() {
  local locks name
  # One name per call: pgrep -x rejects patterns longer than 15 characters.
  for name in apt apt-get aptitude dpkg apt.systemd.dai; do
    pgrep -x -- "$name" >/dev/null && return 0
  done
  pgrep -f '^/usr/bin/python3 /usr/bin/unattended-upgrade( |$)' >/dev/null && return 0
  locks="$(lslocks -n -o PATH 2>/dev/null)" || locks=''
  grep -qE '^/var/(lib/dpkg/lock(-frontend)?|lib/apt/lists/lock|cache/apt/archives/lock)$' <<<"$locks"
}

# Wait for first-boot work and for package runs already started. The APT
# timers stay enabled and running, as vps-hardening verify requires after
# apply (uu.timers); drop-ins in /run make the services they start no-ops
# until the next boot, so no package run changes the host during a test, and
# /etc stays as it is. The tool's own apt.idle judgement must agree.
settle() {
  local rc=0 deadline unit
  cloud-init status --wait >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0 | 2) ;;
    *) fail "cloud-init status $rc" ;;
  esac
  for unit in apt-daily.service apt-daily-upgrade.service; do
    install -d -m 0755 "/run/systemd/system/$unit.d"
    printf '[Service]\nExecStart=\nExecStart=/bin/true\n' >"/run/systemd/system/$unit.d/vps-test.conf"
  done
  systemctl daemon-reload
  deadline=$((SECONDS + 1200))
  while apt_busy || vps_fn package_manager_busy; do
    [ "$SECONDS" -lt "$deadline" ] || fail 'package manager still busy after 20 minutes'
    sleep 5
  done
}

# Package indexes without translations, AppStream or command-not-found data.
reduced_update() {
  local opts=(-o Acquire::Languages=none) target dump
  dump="$(apt-config dump)"
  for target in DEP-11 DEP-11-icons-small DEP-11-icons DEP-11-icons-hidpi CNF; do
    if grep -q "^Acquire::IndexTargets::deb::$target::MetaKey " <<<"$dump"; then
      opts+=(-o "Acquire::IndexTargets::deb::$target::DefaultEnabled=false")
    fi
  done
  apt-get -q "${opts[@]}" update
}

fixture_check() {
  (cd "$FIXTURES" && sha256sum --quiet -c SHA256SUMS) || fail 'fixture files differ from their pinned digests'
}

listening() {
  local out
  out="$(ss -Hltn "sport = :$1")"
  [ -n "$out" ]
}

side() {
  if [ -e "$XUI_DB-$1" ]; then printf 1; else printf 0; fi
}

# x-ui running with its panel listening and the WAL side files in place: the
# state in which the tool reads the database with mode=ro.
wait_xui_stable() {
  local port i
  port="$(state_value panel_port)"
  for i in $(seq 90); do
    if [ "$(systemctl is-active x-ui.service 2>/dev/null || true)" = active ] && listening "$port" &&
      [ -e "$XUI_DB-wal" ] && [ -e "$XUI_DB-shm" ]; then
      break
    fi
    [ "$i" -lt 90 ] || fail 'x-ui did not reach a running state with its panel listening'
    sleep 1
  done
  # Xray's api and metrics listeners follow; the check judges them (listen.api,
  # listen.metrics), so they are only waited for here.
  for i in $(seq 30); do
    if listening 62789 && listening 11111; then
      break
    fi
    sleep 1
  done
  sleep 3
}

# Wait until x-ui is stopped; 1 if side files are still there afterwards.
wait_xui_stopped() {
  local i
  for i in $(seq 60); do
    case "$(systemctl is-active x-ui.service 2>/dev/null || true)" in
      inactive | failed) break ;;
    esac
    sleep 1
  done
  for i in $(seq 15); do
    [ -e "$XUI_DB-wal" ] || [ -e "$XUI_DB-shm" ] || return 0
    sleep 1
  done
  return 1
}

# stop_xui NAME: stop x-ui and keep which side files it leaves (DO-1). If any
# remain, check must refuse that state and leave it as it was; the driver then
# folds the WAL into the database as the last connection, which removes both
# side files: the stopped state the immutable read is for (detailed design 4.1).
stop_xui() {
  local name="$1" ext
  systemctl stop x-ui.service
  wait_xui_stopped || true
  case "$(systemctl is-active x-ui.service 2>/dev/null || true)" in
    inactive | failed) ;;
    *) fail 'x-ui did not stop' ;;
  esac
  {
    systemctl show -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus x-ui.service
    for ext in wal shm journal; do
      [ ! -e "$XUI_DB-$ext" ] || stat -c '%n %s bytes' -- "$XUI_DB-$ext"
    done
  } >"$phase_dir/$name-stopped.txt"
  log "$name: after stop: $(tr '\n' ' ' <"$phase_dir/$name-stopped.txt")"
  [ "$(side wal)$(side shm)" != 00 ] || return 0
  observe "$name-sides" capture "$TOOL" check
  expect_rc "$name-sides" 1
  expect_clean "$name-sides"
  expect_report "$name-sides" FAIL xui.db
  expect_text "$name-sides" '不满足读取前提'
  sqlite3 -batch -init /dev/null "$XUI_DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  [ "$(side wal)$(side shm)" = 00 ] || fail 'side files remain after the driver checkpoint'
}

record_platform() {
  local pkg
  {
    cat /etc/os-release
    uname -a
    for pkg in sqlite3 libsqlite3-0 jq curl openssl iproute2 systemd util-linux python3 python3-h2 tcpdump \
      ufw fail2ban nftables unattended-upgrades cloud-init; do
      dpkg-query -W -f '${Package} ${Version} ${db:Status-Abbrev}\n' "$pkg" 2>/dev/null || echo "$pkg not installed"
    done
  } >"$phase_dir/platform.txt"
  cat "$phase_dir/platform.txt"
}

# ---------------------------------------------------------------------------
# Main configuration (verification plan 3.2, detailed design 9.2)

phase_prepare() {
  settle
  reduced_update
  # The tool's dependencies (its deps item names them) and the test's own tools.
  apt-get -q install -y --no-install-recommends sqlite3 jq tcpdump python3-h2
  record_platform
}

phase_tuning() {
  settle
  fixture_check
  bash "$FIXTURES/vps-tuning-install.sh" --no-launch
  dvt --version | tee "$phase_dir/dvt-version.txt"
  # Loading the modules is a precondition of the VM, as in vps-tuning's own
  # tests; no kernel capability is faked.
  modprobe tcp_bbr
  modprobe sch_fq
  dvt preflight --port "$TUNING_PORT"
  dvt apply --port "$TUNING_PORT"
}

phase_tuning_verify() {
  settle
  dvt verify
  [ -f /etc/systemd/system/x-ui.service.d/90-proxy-vps.conf ] ||
    fail 'vps-tuning did not create x-ui.service.d/90-proxy-vps.conf'
}

phase_hardening_install() {
  settle
  fixture_check
  bash "$FIXTURES/vps-hardening-install.sh"
  [ "$("$VH" --version)" = 'vps-hardening 0.1.1' ] || fail 'vps-hardening is not 0.1.1'
}

installed_files() {
  find /usr/local/bin/vps-proxy-setup /usr/local/lib/vps-proxy-setup /usr/local/share/vps-proxy-setup \
    -printf '%M %u:%g %p\n' | sort
  find /usr/local/bin/vps-proxy-setup /usr/local/lib/vps-proxy-setup /usr/local/share/vps-proxy-setup -type f \
    -print0 | sort -z | xargs -0 sha256sum
}

# The release installer from a local asset directory (detailed design 2.9):
# a copy of install.sh bound to the SHA256SUMS of these assets, as a release
# would bind it. The tests use the installed command.
phase_installer() {
  local rel=/opt/vps-release bound="$PRIVATE/install-bound.sh" tampered="$PRIVATE/release-tampered" digest file
  local version
  version="$(tool_version)"
  rm -rf "$rel" "$tampered"
  install -d -m 0755 "$rel"
  install -m 0644 "$BUNDLE/bin/vps-proxy-setup" "$rel/vps-proxy-setup"
  for file in "$LIB"/*.sh; do
    install -m 0644 "$file" "$rel/"
  done
  (cd "$rel" && sha256sum -- * >"$PRIVATE/SHA256SUMS") && mv "$PRIVATE/SHA256SUMS" "$rel/SHA256SUMS"
  chmod 0644 "$rel/SHA256SUMS"
  cp "$rel/SHA256SUMS" "$phase_dir/SHA256SUMS"
  digest="$(sha256sum <"$rel/SHA256SUMS")"
  digest="${digest%% *}"
  sed "s/^EXPECTED_MANIFEST_SHA256=''\$/EXPECTED_MANIFEST_SHA256='$digest'/" "$BUNDLE/install.sh" >"$bound"
  grep -qx "EXPECTED_MANIFEST_SHA256='$digest'" "$bound" || fail 'could not bind the manifest digest'

  capture unbound bash "$BUNDLE/install.sh" --source-dir "$rel"
  expect_rc unbound 1
  expect_err unbound '没有绑定发行版'
  [ ! -e "$TOOL" ] || fail 'the unbound installer left a command behind'

  capture relative bash "$bound" --source-dir opt/vps-release
  expect_rc relative 2

  capture install bash "$bound" --source-dir "$rel"
  expect_rc install 0
  expect_text install '安装没有执行 deploy、check 或 target-check'
  [ "$("$TOOL" --version)" = "vps-proxy-setup $version" ] || fail 'installed version differs'
  [ "$(stat -c '%U:%G %a' "$TOOL")" = 'root:root 755' ] || fail 'command owner or mode'
  [ "$(stat -c '%U:%G %a' /usr/local/lib/vps-proxy-setup)" = 'root:root 755' ] || fail 'module directory owner or mode'
  [ "$(stat -c '%U:%G %a' /usr/local/share/vps-proxy-setup)" = 'root:root 755' ] || fail 'data directory owner or mode'
  [ -z "$(find /usr/local/lib/vps-proxy-setup -type f ! -perm 0644)" ] || fail 'a module is not 0644'
  installed_files >"$phase_dir/installed.txt"

  capture again bash "$bound" --source-dir "$rel"
  expect_rc again 0
  expect_text again '未做变更'

  cp -a "$rel" "$tampered"
  printf '# tampered\n' >>"$tampered/check.sh"
  capture tampered bash "$bound" --source-dir "$tampered"
  expect_rc tampered 1
  expect_err tampered 'check.sh 未通过 SHA-256 校验'
  installed_files >"$phase_dir/installed-after.txt"
  cmp -s "$phase_dir/installed.txt" "$phase_dir/installed-after.txt" || fail 'a refused install changed the files'
  log "installer: installed $version, unchanged when run again, tampered asset refused"
}

phase_main_config() {
  local allows
  settle
  [ "$(state_value status)" = applied ] || fail 'vps-hardening is not applied'
  log "vps-hardening panel port $(state_value panel_port)"
  capture hardening-verify "$VH" verify
  expect_rc hardening-verify 0
  capture ufw ufw status verbose
  allows="$(grep -E 'ALLOW' "$phase_dir/ufw.out" || true)"
  { [ -n "$allows" ] && ! grep -vqE '^22/tcp ' <<<"$allows"; } || fail 'UFW allows more than 22/tcp'
  capture dvt-verify dvt verify
  expect_rc dvt-verify 0
  [ ! -e /etc/vps-proxy-setup ] && [ ! -e /usr/local/x-ui ] && [ ! -e /etc/x-ui ] ||
    fail 'the main configuration is not a new host'
  log 'main configuration: tuned, hardened and confirmed, UFW allows 22/tcp only, tool installed'
}

# ---------------------------------------------------------------------------
# Namespaces, stand-in and test inputs (detailed design 9.2)

# netns_pair NS HOST_IF HOST_ADDR NS_ADDR: a namespace joined to the guest by a
# veth pair. IPv6 stays off on both ends: M1 has no IPv6 (verification plan
# 3.3), and neighbour discovery would only add noise to the capture of VT-80.
netns_pair() {
  local ns="$1" host_if="$2"
  ip netns add "$ns"
  ip link add "$host_if" type veth peer name eth0 netns "$ns"
  sysctl -q -w "net.ipv6.conf.$host_if.disable_ipv6=1"
  ip netns exec "$ns" sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ip addr add "$3/24" dev "$host_if"
  ip link set "$host_if" up
  ip -n "$ns" addr add "$4/24" dev eth0
  ip -n "$ns" link set lo up
  ip -n "$ns" link set eth0 up
}

make_test_ca() {
  rm -rf "$CA_DIR"
  install -d -m 0700 "$CA_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3 \
    -subj '/CN=vps-proxy-setup test CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj '/CN=target.example' \
    -keyout "$CA_DIR/leaf.key" -out "$CA_DIR/leaf.csr" 2>/dev/null
  printf '%s\n' 'subjectAltName=DNS:target.example,DNS:other.example' 'extendedKeyUsage=serverAuth' \
    'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' >"$CA_DIR/leaf.ext"
  openssl x509 -req -in "$CA_DIR/leaf.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial -days 3 \
    -extfile "$CA_DIR/leaf.ext" -out "$CA_DIR/leaf.crt" 2>/dev/null
  cat "$CA_DIR/leaf.crt" "$CA_DIR/ca.crt" >"$CA_DIR/chain.crt"
}

# trust_ca on|off (detailed design 9.2).
trust_ca() {
  if [ "$1" = on ]; then
    install -m 0644 "$CA_DIR/ca.crt" "$CA_TRUSTED"
  else
    rm -f "$CA_TRUSTED"
  fi
  update-ca-certificates --fresh >/dev/null 2>&1
}

# standin strict|cross [--large]: (re)start the stand-in with that routing.
standin() {
  local i out
  systemctl stop vps-standin.service 2>/dev/null || true
  systemctl reset-failed vps-standin.service 2>/dev/null || true
  install -d -m 0700 "$EVIDENCE/standin"
  systemd-run --quiet --unit vps-standin -- ip netns exec vpsns-standin python3 "$BUNDLE/tests/guest/standin.py" \
    --mode "$1" "${@:2}" --cert "$CA_DIR/chain.crt" --key "$CA_DIR/leaf.key" --log "$EVIDENCE/standin/connections.jsonl"
  for i in $(seq 50); do
    out="$(ip netns exec vpsns-standin ss -Hltn 'sport = :443')"
    [ -z "$out" ] || return 0
    [ "$i" -lt 50 ] || break
    sleep 0.2
  done
  fail "the stand-in did not start ($*)"
}

# A random Tunnel token in the format of detailed design 2.4 (verification
# plan 3.4), a variant whose t is not a UUID, and the leak markers.
make_token() {
  [ ! -s "$PRIVATE/token" ] || return 0
  python3 - "$PRIVATE" <<'PY'
import base64, json, os, secrets, sys, uuid

d = sys.argv[1]
parts = {'a': secrets.token_hex(16), 't': str(uuid.uuid4()), 's': base64.b64encode(secrets.token_bytes(32)).decode()}


def encode(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


for name, value in (('token', encode(parts)), ('token-bad-t', encode(dict(parts, t='not-a-uuid'))),
                    ('token-markers', '\n'.join([encode(parts)] + list(parts.values())))):
    fd = os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(value + '\n')
PY
  cp "$PRIVATE/token-markers" "$PRIVATE/markers"
}

# write_input FILE [KEY=VALUE]...: a valid input file with all seven keys, each
# KEY=VALUE replacing a value; the value <absent> leaves the key out.
write_input() {
  local file="$1" pair key
  local -A value=([sub_host]=sub.proxy.example [node_ip]=192.0.2.1 [target]=target.example [remark]="$REMARK_JP"
    [users]='alice,bob' [ipv6_ai_egress]=off [tunnel_token]="$(cat "$PRIVATE/token")")
  shift
  for pair in "$@"; do
    value[${pair%%=*}]="${pair#*=}"
  done
  rm -f "$file"
  : >"$file"
  chmod 0600 "$file"
  for key in sub_host node_ip target remark users ipv6_ai_egress tunnel_token; do
    [ "${value[$key]}" = '<absent>' ] || printf '%s=%s\n' "$key" "${value[$key]}" >>"$file"
  done
}

phase_network() {
  settle
  netns_pair vpsns-client vps-client0 192.0.2.1 192.0.2.2
  netns_pair vpsns-standin vps-standin0 198.51.100.1 "$STANDIN"
  grep -qF ' target.example ' /etc/hosts ||
    printf '%s target.example other.example probe.example\n' "$STANDIN" >>/etc/hosts
  # VT-04 and VT-05 need an unprivileged account; cloud-init's default user has uid 1000.
  id -nu 1000 >/dev/null 2>&1 || useradd --create-home --uid 1000 --shell /bin/bash vpstest
  make_test_ca
  trust_ca on
  standin strict
  # In M1 the client namespace only has to reach the node address (detailed design 9.2).
  capture client-ping ip netns exec vpsns-client ping -c 1 -W 5 192.0.2.1
  expect_rc client-ping 0
  ip -br addr >"$phase_dir/addresses.txt"
  make_token
}

# ---------------------------------------------------------------------------
# VT-80 and VT-81: target-check against the stand-in

stop_time_sync() {
  local unit
  : >"$PRIVATE/time-sync-stopped"
  for unit in systemd-timesyncd.service chrony.service; do
    if systemctl is-active --quiet "$unit"; then
      systemctl stop "$unit"
      printf '%s\n' "$unit" >>"$PRIVATE/time-sync-stopped"
    fi
  done
}

start_time_sync() {
  local unit
  while IFS= read -r unit; do
    systemctl start "$unit"
  done <"$PRIVATE/time-sync-stopped"
}

# The capture keeps headers only; the test driver's own SSH session is left out.
start_capture() {
  tcpdump -Z root -i any -nn -U -w "$PRIVATE/vt80.pcap" '(tcp or udp) and not (host 10.0.2.2 and tcp port 22)' \
    2>"$phase_dir/tcpdump.err" &
  capture_pid=$!
  for _ in $(seq 50); do
    if grep -q 'listening on' "$phase_dir/tcpdump.err"; then
      return 0
    fi
    sleep 0.2
  done
  fail 'tcpdump did not start'
}

stop_capture() {
  sleep 1
  kill -INT "$capture_pid"
  wait "$capture_pid" || true
  tcpdump -nn -tt -r "$PRIVATE/vt80.pcap" >"$PRIVATE/vt80-capture.txt" 2>/dev/null
}

record_ok() {
  local file="/etc/vps-proxy-setup/target-check/target.example"
  [ "$(stat -c '%F %u %a' /etc/vps-proxy-setup)" = 'directory 0 700' ] || fail 'result directory mode'
  [ "$(stat -c '%F %u %a' /etc/vps-proxy-setup/target-check)" = 'directory 0 700' ] || fail 'result directory mode'
  [ "$(stat -c '%F %u %a' "$file")" = 'regular file 0 600' ] || fail 'result file mode'
  { grep -qx 'format=1' "$file" && grep -qx 'target=target.example' "$file" && grep -qx "result=$1" "$file"; } ||
    fail "the result file does not say result=$1"
  cp "$file" "$phase_dir/record-$2.txt"
}

# target_case NAME RC CMD_ARGS...: target-check between snapshots; only its
# result file may change.
target_case() {
  local name="$1" rc="$2"
  shift 2
  observe_begin "$name"
  capture "$name" "$TOOL" target-check "$@"
  # The two directories and the result file; any other file there is a change.
  observe_end "$name" '/etc/vps-proxy-setup(/target-check(/target\.example)?)?( |$)'
  expect_rc "$name" "$rc"
  expect_clean "$name"
  expect_report "$name" INFO resolve tls.group
  expect_text "$name" "$STANDIN"
}

# Every TCP and UDP packet of the capture is between the guest and
# 198.51.100.2:443; the stand-in saw only the SNI target.example, and in
# cross mode Host and :authority other.example (DO-8). Only time, addresses
# and ports of the capture are archived (verification plan 6).
judge_capture() {
  python3 - "$PRIVATE/vt80-capture.txt" "$EVIDENCE/standin/connections.jsonl" "$phase_dir/capture-summary.json" \
    "$phase_dir/capture-flows.txt" <<'PY'
import json, re, sys

capture, standin, out, flows = sys.argv[1:]
flow = re.compile(r'\bIP6? (\S+) > (\S+?): ')
peer = '198.51.100.2.443'
unexpected, syn, packets, kept = [], 0, 0, []
for line in open(capture):
    packets += 1
    m = flow.search(line)
    src, dst = m.groups() if m else ('?', '?')
    kept.append(f'{line.split()[0]} {src} > {dst}\n')
    if not ((src == peer and dst.startswith('198.51.100.1.')) or (dst == peer and src.startswith('198.51.100.1.'))):
        unexpected.append(f'{line.split()[0]} {src} > {dst}')
    elif dst == peer and 'Flags [S]' in line:
        syn += 1
with open(flows, 'w') as f:
    f.writelines(kept)
records = [json.loads(l) for l in open(standin) if l.strip()]
conns = [r for r in records if 'peer' in r]
snis = sorted({str(r.get('sni')) for r in conns})
cross = [q for r in conns if r.get('mode') == 'cross' for q in r['requests']]
summary = {'packets': packets, 'connections_to_standin': syn, 'unexpected': unexpected,
           'standin_connections': len(conns), 'standin_sni': snis,
           'cross_h1_hosts': sorted({q.get('host') for q in cross if q['proto'] == 'http/1.1'}),
           'cross_h2_authorities': sorted({q.get('authority') for q in cross if q['proto'] == 'h2'}),
           'cross_h2_host_headers': sorted({str(q.get('host')) for q in cross if q['proto'] == 'h2'})}
with open(out, 'w') as f:
    json.dump(summary, f, indent=1)
print(json.dumps(summary, indent=1))
problems = []
if unexpected:
    problems.append('packets other than to 198.51.100.2:443')
if syn == 0:
    problems.append('no connection to the stand-in captured')
if snis != ['target.example']:
    problems.append('an SNI other than target.example')
if 'other.example' not in summary['cross_h1_hosts']:
    problems.append('the stand-in did not receive Host: other.example over HTTP/1.1')
if 'other.example' not in summary['cross_h2_authorities']:
    problems.append('the stand-in did not receive :authority other.example over HTTP/2')
if problems:
    sys.exit('; '.join(problems))
PY
}

phase_vt80() {
  settle
  stop_time_sync
  : >"$EVIDENCE/standin/connections.jsonl"
  standin strict
  start_capture

  trust_ca on
  target_case vt80-trusted 0 target.example
  expect_report vt80-trusted PASS root deps tls.handshake tls.version tls.alpn tls.cert http.root probe.host \
    probe.authority
  record_ok PASS trusted

  # VT-80: without the test CA the certificate is invalid; the HTTP checks still run.
  trust_ca off
  target_case vt80-untrusted 1 target.example
  expect_fails vt80-untrusted tls.cert
  expect_report vt80-untrusted PASS tls.handshake tls.version tls.alpn http.root probe.host probe.authority
  record_ok FAIL untrusted
  trust_ca on

  # VT-81: the probes are clean against strict SNI routing and find cross routing.
  target_case vt81-strict 0 target.example --probe-host other.example
  expect_report vt81-strict PASS probe.host probe.authority
  standin cross
  target_case vt81-cross 1 target.example --probe-host other.example
  expect_fails vt81-cross probe.host probe.authority
  expect_text vt81-cross '可能交叉路由'
  record_ok FAIL cross
  # The default probe host is unknown to the stand-in: 404, which passes.
  target_case vt81-cross-default 0 target.example
  expect_report vt81-cross-default PASS probe.host probe.authority
  standin strict

  stop_capture
  start_time_sync
  judge_capture

  # The 4 MiB read limit (detailed design 5), after the capture: with cross
  # routing, the bodies of the two hosts share their first 4 MiB and differ
  # after it. Both probes compare equal only if each read stops at 4 MiB; one
  # byte more and they would fail. The stand-in also saw no body read to the end.
  standin cross --large
  target_case vt81-large 0 target.example --probe-host other.example
  expect_report vt81-large PASS http.root probe.host probe.authority
  [ "$(grep -cE '^\[PASS\] probe\.(host|authority) +探测请求返回 200，内容与基准相同' "$phase_dir/vt81-large.out")" -eq 2 ] ||
    fail 'vt81-large: the probes did not compare equal on the first 4 MiB'
  jq -s -e '[.[] | select(.large == true) | .requests[]] | length > 0 and all(.complete == false)' \
    "$EVIDENCE/standin/connections.jsonl" >/dev/null || fail 'vt81-large: a body was sent to the end'
  standin strict
}

# ---------------------------------------------------------------------------
# VT-01 to VT-05: the preflight of deploy

phase_vt01() {
  local input="$PRIVATE/vt01.input"
  settle
  trust_ca on
  capture vt01-target-check "$TOOL" target-check target.example
  expect_rc vt01-target-check 0
  write_input "$input"

  observe vt01 capture_tty "$TOOL" deploy --input "$input"
  expect_rc vt01 1
  expect_clean vt01
  expect_err vt01 '[x] 预检通过；之后的步骤在 M2 实现，主机未改动'
  expect_report vt01 PASS "${PREFLIGHT_PASS[@]}"
  expect_report vt01 WARN inputs.node_ip
  expect_report vt01 INFO inputs.sub_host inputs.target inputs.remark inputs.users inputs.ipv6_ai_egress \
    inputs.tunnel_token
  expect_report vt01 SKIP ipv6.egress
  expect_fails vt01
  expect_text vt01 "$REMARK_JP"
  expect_no_secret vt01

  # Not on a terminal: refused before anything else, exit status 2.
  observe vt01-notty capture "$TOOL" deploy --input "$input"
  expect_rc vt01-notty 2
  expect_err vt01-notty 'deploy 必须在交互终端中运行'
  expect_no_secret vt01-notty
}

# vt03_bad NAME KEY yes|no [KEY=VALUE]...: deploy (--migrate when yes) refuses
# the input with exit status 2, names the key and echoes no secret.
vt03_bad() {
  local name="vt03-$1" key="$2" migrate="$3" file
  shift 3
  file="$PRIVATE/$name.input"
  write_input "$file" "$@"
  if [ "$migrate" = yes ]; then
    capture_tty "$name" "$TOOL" deploy --migrate --input "$file"
  else
    capture_tty "$name" "$TOOL" deploy --input "$file"
  fi
  expect_rc "$name" 2
  expect_clean "$name"
  expect_err "$name" "[x] 输入 $key："
  expect_no_secret "$name"
  only_gates "$name"
}

# only_gates NAME: deploy stopped after the root and platform gates, before
# any check that follows the inputs (detailed design 2.5).
only_gates() {
  expect_report "$1" PASS root platform
  # One reader for the whole file: grep -q in a pipe could end the writer early.
  if awk '/^\[(PASS|FAIL|WARN|SKIP|INFO)\] / && !/^\[PASS\] (root|platform) / { found = 1 } END { exit !found }' \
    "$phase_dir/$1.out"; then
    fail "$1: checks ran after the input was refused"
  fi
}

phase_vt03() {
  local file="$PRIVATE/vt03-remark.input"
  settle
  observe_begin vt03
  vt03_bad sub-host-labels sub_host no sub_host=proxy.example
  vt03_bad sub-host-empty sub_host no sub_host=
  vt03_bad node-ip-hostname node_ip no node_ip=node.proxy.example
  vt03_bad node-ip-private node_ip no node_ip=10.1.2.3
  vt03_bad target-same target no target=sub.proxy.example
  vt03_bad target-labels target no target=target
  vt03_bad remark-flag remark no remark=Tokyo-01
  vt03_bad users-duplicate users no users=alice,alice
  vt03_bad users-email users no users=alice@proxy.example
  vt03_bad ipv6 ipv6_ai_egress no ipv6_ai_egress=yes
  vt03_bad token-base64 tunnel_token no 'tunnel_token=not base64!'
  vt03_bad token-uuid tunnel_token no "tunnel_token=$(cat "$PRIVATE/token-bad-t")"
  vt03_bad migrate-remark remark yes users='<absent>'
  # A valid UTF-8 remark with a flag and CJK characters is accepted.
  write_input "$file" "remark=$REMARK_SG"
  capture_tty vt03-remark "$TOOL" deploy --input "$file"
  expect_rc vt03-remark 1
  expect_clean vt03-remark
  expect_err vt03-remark '预检通过'
  expect_report vt03-remark INFO inputs.remark
  expect_text vt03-remark "$REMARK_SG"
  if grep -qF '[x] 输入' "$phase_dir/vt03-remark.err"; then
    fail 'vt03-remark: a valid remark was refused'
  fi
  observe_end vt03
}

# vt04_case NAME TEXT FILE: deploy refuses the input file with exit status 2.
vt04_case() {
  local name="vt04-$1"
  capture_tty "$name" "$TOOL" deploy --input "$3"
  expect_rc "$name" 2
  expect_clean "$name"
  expect_err "$name" "[x] 输入文件：$2"
  expect_no_secret "$name"
  only_gates "$name"
}

phase_vt04() {
  local f="$PRIVATE/vt04.input" user mode
  user="$(id -nu 1000)"
  settle
  observe_begin vt04
  write_input "$f"
  chown "$user" "$f"
  vt04_case owner '必须属于 root' "$f"
  for mode in 0644 0640 0400; do
    write_input "$f"
    chmod "$mode" "$f"
    vt04_case "mode-$mode" "权限必须是 0600，现在是 $mode" "$f"
  done
  write_input "$f"
  ln -sfn "$f" "$PRIVATE/vt04-link.input"
  vt04_case symlink '不能是符号链接' "$PRIVATE/vt04-link.input"
  observe_end vt04
}

phase_vt05() {
  local input="$PRIVATE/vt01.input" user
  user="$(id -nu 1000)"
  settle
  write_input "$input"

  observe vt05-user capture_tty runuser -u "$user" -- "$TOOL" deploy --input "$input"
  expect_rc vt05-user 1
  expect_fails vt05-user root
  if grep -qE '^\[[A-Z]+\] (platform|inputs\.)' "$phase_dir/vt05-user.out"; then
    fail 'vt05-user: checks ran after the root gate'
  fi

  printf 'PRETTY_NAME="Ubuntu 24.04 LTS"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$PRIVATE/os-release"
  chmod 0644 "$PRIVATE/os-release"
  observe vt05-platform capture_tty "${BOUND[@]}" "$PRIVATE/os-release" /etc/os-release "$TOOL" deploy --input "$input"
  expect_rc vt05-platform 1
  expect_fails vt05-platform platform
  expect_report vt05-platform PASS root
  if grep -qE '^\[[A-Z]+\] inputs\.' "$phase_dir/vt05-platform.out"; then
    fail 'vt05-platform: checks ran after the platform gate'
  fi

  grep -v '^panel_port=' /var/lib/vps-hardening/state >"$PRIVATE/state-no-port"
  observe vt05-panel-port capture_tty "${BOUND[@]}" "$PRIVATE/state-no-port" /var/lib/vps-hardening/state \
    "$TOOL" deploy --input "$input"
  expect_rc vt05-panel-port 1
  expect_clean vt05-panel-port
  expect_report vt05-panel-port FAIL hardening.panel-port
  expect_err vt05-panel-port '预检不通过，主机未改动'
}

# On its own overlay: a UFW rule outside the vps-hardening record.
phase_vt05_verify() {
  settle
  ufw allow 8080/tcp
  observe vt05-verify capture_tty "$TOOL" deploy --input "$PRIVATE/vt01.input"
  expect_rc vt05-verify 1
  expect_clean vt05-verify
  expect_fails vt05-verify hardening.verify
  expect_err vt05-verify '预检不通过，主机未改动'
}

# existing_host NAME ID: on an existing host S1-S3 the preflight stops with ID
# failing (VT-02).
existing_host() {
  observe "$1" capture_tty "$TOOL" deploy --input "$PRIVATE/vt01.input"
  expect_rc "$1" 1
  expect_clean "$1"
  expect_report "$1" FAIL "$2"
  expect_err "$1" '预检不通过，主机未改动'
  expect_no_secret "$1"
}

# 3X-UI as deploy will install it (detailed design 9.2 S1), with the digests
# of VO-1 checked on the installed copies.
install_xui() {
  local rc=0 port
  port="$(state_value panel_port)"
  fixture_check
  XUI_NONINTERACTIVE=1 XUI_PANEL_PORT="$port" XUI_ENABLE_FAIL2BAN=false XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
    bash "$FIXTURES/3x-ui-install.sh" "$(vps_fn pin_value VPS_PIN_XUI_TAG)" </dev/null \
    >"$PRIVATE/xui-install.log" 2>&1 || rc=$?
  # Lines that could carry the generated credentials stay private.
  grep -viE 'user|pass|token|path|url|http|key|secret' "$PRIVATE/xui-install.log" >"$phase_dir/xui-install.log" || true
  [ "$rc" -eq 0 ] || fail "3X-UI install.sh exit $rc"
  vps_fn xui_pin_lines | sha256sum -c - | tee "$phase_dir/vo1-installed.txt" ||
    fail '3X-UI files differ from the pinned digests (VO-1)'
  collect_markers
}

# Called through vps_fn only, which loads pins.sh.
# shellcheck disable=SC2031
xui_pin_lines() {
  local i
  for i in "${!VPS_PIN_XUI_FILES[@]}"; do
    printf '%s  %s\n' "${VPS_PIN_XUI_SHA256[$i]}" "${VPS_PIN_XUI_FILES[$i]}"
  done
}

phase_s1() {
  settle
  install_xui
  existing_host vt02-s1 new-host.xui
}

phase_s2() {
  settle
  install -d -m 0755 /etc/x-ui
  sqlite3 "$XUI_DB" 'CREATE TABLE vt02 (x); DROP TABLE vt02;'
  existing_host vt02-s2 new-host.xui-db
  expect_fails vt02-s2 new-host.xui-db
}

phase_s3() {
  local file="$PRIVATE/cloudflared" size sha version
  settle
  version="$(vps_fn pin_value VPS_PIN_CLOUDFLARED_VERSION)"
  size="$(vps_fn pin_value VPS_PIN_CLOUDFLARED_SIZE)"
  sha="$(vps_fn pin_value VPS_PIN_CLOUDFLARED_SHA256)"
  curl --fail --silent --show-error --location --proto '=https' --max-time 300 -o "$file" \
    "https://github.com/cloudflare/cloudflared/releases/download/$version/cloudflared-linux-amd64"
  [ "$(stat -c %s "$file")" = "$size" ] || fail 'cloudflared size differs from the pin'
  printf '%s  %s\n' "$sha" "$file" | sha256sum -c - || fail 'cloudflared digest differs from the pin'
  install -m 0755 "$file" /usr/local/bin/cloudflared
  existing_host vt02-s3 new-host.cloudflared
  expect_fails vt02-s3 new-host.cloudflared
}

# ---------------------------------------------------------------------------
# VT-71 to VT-76: check on an S1 host (detailed design 9.3, 9.5)

# Leak markers (verification plan 3.4, VT-74): the install result and secret
# values of the database, at least 8 characters so that they cannot match by
# chance. They stay in PRIVATE; tests/vm.py reads them for its own scan.
collect_markers() {
  {
    [ ! -s "$PRIVATE/token-markers" ] || cat "$PRIVATE/token-markers"
    [ ! -r "$XUI_RESULT" ] ||
      sed -n 's/^XUI_\(USERNAME\|PASSWORD\|WEB_BASE_PATH\|ACCESS_URL\|API_TOKEN\)=//p' "$XUI_RESULT"
    [ ! -e "$XUI_DB" ] || db_secret_values
  } | sed 's#^/##; s#/$##' | awk 'length($0) >= 8' | sort -u >"$PRIVATE/markers"
  printf '%s markers\n' "$(wc -l <"$PRIVATE/markers")" >"$phase_dir/markers.txt"
}

db_secret_values() {
  local state uri
  state="$(vps_fn xui_db_state)" && uri="$(vps_fn xui_db_uri "$state")" || return 0
  python3 - "$uri" <<'PY'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1], uri=True, timeout=5)
queries = ["SELECT value FROM settings WHERE key IN ('webBasePath', 'subPath', 'subClashPath', 'subJsonPath', "
           "'secret', 'subURI', 'subClashURI', 'subJsonURI')",
           'SELECT username FROM users', 'SELECT password FROM users', 'SELECT uuid FROM clients',
           'SELECT sub_id FROM clients', 'SELECT token FROM api_tokens']
for query in queries:
    try:
        for (value,) in con.execute(query):
            if isinstance(value, str) and value:
                print(value)
    except sqlite3.Error:
        pass
con.close()
PY
}

# VT-74 over the whole evidence of this guest.
scan_markers() {
  local hits
  [ -s "$PRIVATE/markers" ] || fail 'no leak markers collected'
  hits="$(grep -rlF -f "$PRIVATE/markers" "$EVIDENCE" || true)"
  [ -z "$hits" ] || fail "test secrets found in: $hits"
  log "no test secret in $EVIDENCE"
}

phase_xui() {
  local f="$phase_dir/formats.txt" drop
  settle
  install_xui
  # DO-2: the formats the checks parse, as this platform prints them.
  {
    echo '== x-ui -v'
    /usr/local/x-ui/x-ui -v
    echo '== xray version'
    /usr/local/x-ui/bin/xray-linux-amd64 version
    echo '== systemctl show x-ui.service'
    systemctl show -p ExecStart -p WorkingDirectory -p Environment -p EnvironmentFiles -p User -p FragmentPath \
      -p DropInPaths -p NeedDaemonReload x-ui.service
    echo '== drop-ins'
    for drop in /etc/systemd/system/x-ui.service.d/*.conf; do
      echo "-- $drop"
      cat "$drop"
    done
    echo '== ss -Hltne -4'
    ss -Hltne -4
    echo '== ss -Hltne -6'
    ss -Hltne -6
    echo '== fail2ban-client status'
    fail2ban-client status
    echo '== /etc/x-ui'
    ls -la /etc/x-ui
  } >"$f" 2>&1 || true
  # Detailed design 9.5: the panel part of deploy step 4, then a restart.
  /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null
  systemctl restart x-ui.service
  wait_xui_stable
  python3 -c 'import sqlite3, sys; print("journal_mode", sqlite3.connect(sys.argv[1], uri=True).execute("PRAGMA journal_mode").fetchone()[0])' \
    "file:$XUI_DB?mode=ro" >>"$f"
  scan_markers
}

phase_baseline() {
  local n
  settle
  wait_xui_stable
  collect_markers
  observe_begin check
  capture check-1 "$TOOL" check
  capture check-2 "$TOOL" check
  capture check-3 "$TOOL" check
  observe_end check
  for n in 1 2 3; do
    expect_rc "check-$n" 1
    expect_clean "check-$n"
  done
  # VT-76: three runs in the same state, byte for byte.
  { cmp "$phase_dir/check-1.out" "$phase_dir/check-2.out" && cmp "$phase_dir/check-1.out" "$phase_dir/check-3.out"; } ||
    fail 'VT-76: the three check runs differ'
  # VT-75: a usage error.
  observe check-usage capture "$TOOL" check extra
  expect_rc check-usage 2
  expect_err check-usage 'check 不接受参数'
  scan_markers
}

# VT-73: the program replaced by one that reports another version, in a
# private mount namespace.
phase_vt73() {
  settle
  wait_xui_stable
  printf '#!/bin/sh\necho 9.9.9\n' >"$PRIVATE/fake-x-ui"
  chmod 0755 "$PRIVATE/fake-x-ui"
  observe vt73 capture "${BOUND[@]}" "$PRIVATE/fake-x-ui" /usr/local/x-ui/x-ui "$TOOL" check
  expect_rc vt73 1
  expect_clean vt73
  expect_report vt73 FAIL xui.version xui.files
  expect_report vt73 SKIP xui.db
  scan_markers
}

# The writes of detailed design 9.3 for VT-72: each open mode of 4.1, through
# the tool's own read function, must refuse to create a table.
write_refused() {
  local name="$1" uri="$2" rc=0
  vps_fn xui_sqlite "$uri" 'CREATE TABLE vt72_probe (x);' >"$phase_dir/$name.out" 2>&1 || rc=$?
  { [ "$rc" -ne 0 ] && grep -qi 'readonly' "$phase_dir/$name.out"; } || fail "$name: the write was not refused as read-only"
  log "$name: refused ($(head -c 200 "$phase_dir/$name.out" | tr '\n' ' '))"
}

no_probe_table() {
  python3 -c 'import sqlite3, sys; sys.exit(sqlite3.connect(sys.argv[1], uri=True).execute("SELECT count(*) FROM sqlite_master WHERE name = ?", ("vt72_probe",)).fetchone()[0])' \
    "$1" || fail 'the probe table exists'
}

# DO-1: check while x-ui stops or starts. A control without check shows what
# stopping leaves behind; check must leave the same, and its result is a
# snapshot or a stated refusal, never an internal error.
db_race() {
  local delay n action out=race.txt rc line control
  for n in 1 2 3; do
    wait_xui_stable
    systemctl stop x-ui.service
    wait_xui_stopped || true
    printf 'control stop %s: wal=%s shm=%s\n' "$n" "$(side wal)" "$(side shm)" >>"$phase_dir/$out"
    systemctl start x-ui.service
  done
  control="$(sed -n 's/^control stop [0-9]: //p' "$phase_dir/$out" | sort -u)"
  for action in stop start; do
    for delay in 0 0.2 0.4 0.6 0.8 1.0 1.5 2.0; do
      if [ "$action" = stop ]; then
        wait_xui_stable
      else
        systemctl stop x-ui.service
        wait_xui_stopped || true
      fi
      (
        sleep "$delay"
        systemctl "$action" x-ui.service
      ) &
      capture "race-$action-$delay" "$TOOL" check
      wait "$!"
      rc="$(cat "$phase_dir/race-$action-$delay.rc")"
      line="$(grep -E '^\[[A-Z]+\] xui\.db ' "$phase_dir/race-$action-$delay.out" || true)"
      if [ "$action" = stop ]; then
        wait_xui_stopped || true
        printf '%s %s: rc=%s wal=%s shm=%s %s\n' "$action" "$delay" "$rc" "$(side wal)" "$(side shm)" "$line" \
          >>"$phase_dir/$out"
        [ "wal=$(side wal) shm=$(side shm)" = "$control" ] || fail "DO-1: check during stop ($delay s) left other side files than stopping alone"
        systemctl start x-ui.service
      else
        printf '%s %s: rc=%s %s\n' "$action" "$delay" "$rc" "$line" >>"$phase_dir/$out"
      fi
      [ "$rc" = 1 ] || fail "DO-1: check during $action ($delay s) exited $rc"
      case "$line" in
        '[PASS] xui.db '* | '[FAIL] xui.db '*) ;;
        *) fail "DO-1: check during $action ($delay s) has no xui.db result" ;;
      esac
    done
  done
  cat "$phase_dir/$out"
}

phase_vt72() {
  local before
  settle
  wait_xui_stable
  install -d -m 0700 /etc/x-ui/.x-ui-backup-vt72
  printf 'vt72\n' >/etc/x-ui/.x-ui-backup-vt72/marker

  # Running: read with mode=ro.
  write_refused write-ro "file:$XUI_DB?mode=ro"
  observe vt72-running capture "$TOOL" check
  expect_rc vt72-running 1
  expect_clean vt72-running
  expect_report vt72-running PASS xui.db xui.service
  [ -f /etc/x-ui/.x-ui-backup-vt72/marker ] || fail 'the backup directory is gone'

  # Stopped: read with immutable=1; the file itself must not change.
  stop_xui vt72
  write_refused write-immutable "file:$XUI_DB?mode=ro&immutable=1"
  no_probe_table "file:$XUI_DB?mode=ro&immutable=1"
  before="$(sha256sum <"$XUI_DB")"
  observe vt72-stopped capture "$TOOL" check
  expect_rc vt72-stopped 1
  expect_clean vt72-stopped
  expect_report vt72-stopped PASS xui.db
  expect_report vt72-stopped FAIL xui.service
  [ "$(sha256sum <"$XUI_DB")" = "$before" ] || fail 'the database file changed'
  [ "$(side wal)$(side shm)" = 00 ] || fail 'check created side files'
  [ -f /etc/x-ui/.x-ui-backup-vt72/marker ] || fail 'the backup directory is gone'
  systemctl start x-ui.service
  db_race
  wait_xui_stable
  no_probe_table "file:$XUI_DB?mode=ro"
}

# VT-75: an empty -wal without -shm while x-ui is stopped.
phase_vt75() {
  local db wal
  settle
  # vt72 runs before on the same disk and may have stopped with x-ui stopped.
  systemctl start x-ui.service
  wait_xui_stable
  stop_xui vt75
  : >"$XUI_DB-wal"
  db="$(sha256sum <"$XUI_DB")"
  wal="$(sha256sum <"$XUI_DB-wal")"
  observe vt75 capture "$TOOL" check
  expect_rc vt75 1
  expect_clean vt75
  expect_report vt75 FAIL xui.db
  expect_text vt75 '不满足读取前提'
  [ "$(sha256sum <"$XUI_DB")" = "$db" ] && [ "$(sha256sum <"$XUI_DB-wal")" = "$wal" ] ||
    fail 'the database or the -wal file changed'
  [ "$(side shm)" = 0 ] || fail 'check created -shm'
  rm -f "$XUI_DB-wal"
  systemctl start x-ui.service
  wait_xui_stable
}

# Panel API of detailed design 15.1 with the install result's token: loopback
# only, no proxy, no redirects. Responses stay in PRIVATE.
api_env() {
  local port base token
  port="$(sed -n 's/^XUI_PANEL_PORT=//p' "$XUI_RESULT")"
  base="$(sed -n 's/^XUI_WEB_BASE_PATH=//p' "$XUI_RESULT")"
  token="$(sed -n 's/^XUI_API_TOKEN=//p' "$XUI_RESULT")"
  # printf %q leaves these characters alone; anything else would be escaped.
  [[ "$port $base $token" =~ ^[0-9]+\ [A-Za-z0-9/_.~-]*\ [A-Za-z0-9._~+/=:-]+$ ]] ||
    fail 'the install result is not in the expected plain form'
  base="${base#/}"
  base="${base%/}"
  printf 'http://127.0.0.1:%s%s/panel/api' "$port" "${base:+/$base}" >"$PRIVATE/api-base"
  printf 'Authorization: Bearer %s\n' "$token" >"$PRIVATE/api-header"
}

api_post() {
  local path="$1" out="$2" status
  shift 2
  status="$(curl --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 30 -o "$out" \
    -w '%{http_code}' -H @"$PRIVATE/api-header" -X POST "$@" "$(cat "$PRIVATE/api-base")/$path")" || status=000
  printf '%s\n' "$status"
}

# api_setting JQ_FILTER: read all settings, change them, write them all back
# (setting/update is not a PATCH, detailed design 14).
api_setting() {
  local status
  api_env
  status="$(api_post setting/all "$PRIVATE/all.json")"
  { [ "$status" = 200 ] && jq -e '.success == true and (.obj | type) == "object"' "$PRIVATE/all.json" >/dev/null; } ||
    fail "setting/all: HTTP $status or not a success"
  jq -c ".obj | $1" "$PRIVATE/all.json" >"$PRIVATE/update.json"
  status="$(api_post setting/update "$PRIVATE/update-response.json" -H 'Content-Type: application/json' \
    --data-binary @"$PRIVATE/update.json")"
  printf 'setting/update %s: HTTP %s, success %s\n' "$1" "$status" \
    "$(jq -c '.success' "$PRIVATE/update-response.json" 2>/dev/null || echo '?')" | tee -a "$phase_dir/api.txt"
  { [ "$status" = 200 ] && jq -e '.success == true' "$PRIVATE/update-response.json" >/dev/null; } ||
    fail "setting/update $1 was not accepted"
}

# One VT-71 injection on its own overlay (detailed design 9.5); tests/vm.py
# compares the check result with the baseline.
phase_inject() {
  local name="$1"
  settle
  wait_xui_stable
  case "$name" in
    x-ui-script)
      python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-1] ^= 1; open(p, "wb").write(b)' \
        /usr/bin/x-ui
      ;;
    unit-env)
      printf '[Service]\nEnvironment=XUI_DB_FOLDER=/var/tmp\n' >/etc/systemd/system/x-ui.service.d/99-vt71.conf
      chmod 0644 /etc/systemd/system/x-ui.service.d/99-vt71.conf
      systemctl daemon-reload
      ;;
    env-file)
      : >/etc/default/x-ui
      chmod 0644 /etc/default/x-ui
      ;;
    disabled) systemctl disable x-ui.service ;;
    listen-all)
      /usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 >/dev/null
      systemctl restart x-ui.service
      wait_xui_stable
      ;;
    ipl)
      printf '[3x-ipl]\nenabled = true\n' >/etc/fail2ban/jail.d/3x-ipl.conf
      chmod 0644 /etc/fail2ban/jail.d/3x-ipl.conf
      ;;
    sub-json) api_setting '.subJsonEnable = true' ;;
    sub-info-node) api_setting '.subInfoNodeEnable = true' ;;
    sub-updates) api_setting '.subUpdates = 6' ;;
    sub-enable) api_setting '.subEnable = false' ;;
    sub-cert)
      # A key pair of the guest's own; nothing is published.
      install -d -m 0700 /root/vps-fixture
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3 -subj '/CN=sub.proxy.example' \
        -keyout /root/vps-fixture/sub.key -out /root/vps-fixture/sub.crt 2>/dev/null
      api_setting '.subCertFile = "/root/vps-fixture/sub.crt" | .subKeyFile = "/root/vps-fixture/sub.key"'
      ;;
    sub-path) api_setting '.subPath = "/sub/"' ;;
    acme)
      install -d -m 0700 /root/.acme.sh
      printf '#!/bin/sh\n' >/root/.acme.sh/acme.sh
      chmod 0755 /root/.acme.sh/acme.sh
      ;;
    cf-credentials)
      install -d -m 0700 /root/.cloudflared
      printf 'test\n' >/root/.cloudflared/cert.pem
      ;;
    ufw-rule) ufw allow 8080/tcp ;;
    *) fail "unknown injection: $name" ;;
  esac
  observe check capture "$TOOL" check
  expect_rc check 1
  expect_clean check
  scan_markers
}

main() {
  local phase="${1-}"
  [ "$(id -u)" -eq 0 ] || fail 'run as root'
  phase_dir="$EVIDENCE/$(IFS=-; printf '%s' "$*")"
  install -d -m 0700 "$EVIDENCE" "$PRIVATE"
  rm -rf "$phase_dir"
  install -d -m 0700 "$phase_dir"
  case "$phase" in
    prepare) phase_prepare ;;
    tuning) phase_tuning ;;
    tuning-verify) phase_tuning_verify ;;
    hardening-install) phase_hardening_install ;;
    installer) phase_installer ;;
    main-config) phase_main_config ;;
    network) phase_network ;;
    vt80) phase_vt80 ;;
    vt01) phase_vt01 ;;
    vt03) phase_vt03 ;;
    vt04) phase_vt04 ;;
    vt05) phase_vt05 ;;
    vt05-verify) phase_vt05_verify ;;
    s1) phase_s1 ;;
    s2) phase_s2 ;;
    s3) phase_s3 ;;
    xui) phase_xui ;;
    baseline) phase_baseline ;;
    vt73) phase_vt73 ;;
    vt72) phase_vt72 ;;
    vt75) phase_vt75 ;;
    inject) phase_inject "${2:?injection name}" ;;
    *) fail "unknown phase: $phase" ;;
  esac
  log "phase $* passed"
}

main "$@"
