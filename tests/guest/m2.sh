#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Guest side of the M2 VM tests (detailed design 9, 19; verification plan
# VT-10 to VT-13). Sources tests/guest/m1.sh for its helpers and the phases of
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

# VT-10 through the deploy entry; VT-13 on its output.
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
  expect_err vt10 '[x] 第 1～4 步完成'
  expect_report vt10 PASS "${PREFLIGHT_PASS[@]}" "${FETCH_ITEMS[@]}" "${INSTALL_ITEMS[@]}"
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
  scan_markers
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

main "$@"
