#!/usr/bin/env bash
# Static checks that need no VM (detailed design 9.1): shell syntax, Python
# syntax, the installer's asset lists and version, LF line endings, secret
# patterns, and the privacy scan of VT-97. CI runs ShellCheck separately from
# a pinned container image (.github/workflows/static.yml). Provider names and
# production targets cannot be listed here; tests/privacy-local.sh scans for
# them with a list kept outside the repository.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

# Tracked files plus new ones not yet added, so the checks also run before a commit.
mapfile -t all_files < <(git ls-files -co --exclude-standard)

mapfile -t shell_files < <(printf '%s\n' "${all_files[@]}" | grep -E '^(bin/|lib/.*\.sh$|tests/.*\.sh$|install\.sh$)')
[ "${#shell_files[@]}" -gt 0 ] || fail 'no shell files found'
for file in "${shell_files[@]}"; do
  bash -n "$file" || fail "bash -n: $file"
done
printf '[+] bash -n: %d files\n' "${#shell_files[@]}"

mapfile -t python_files < <(printf '%s\n' "${all_files[@]}" | grep -E '\.py$' || true)
if [ "${#python_files[@]}" -gt 0 ]; then
  python3 -B -c 'import ast, sys; [ast.parse(open(p, encoding="utf-8").read(), p) for p in sys.argv[1:]]' \
    "${python_files[@]}"
fi
printf '[+] Python syntax: %d files\n' "${#python_files[@]}"

# The command sources every module, and the installer installs exactly the
# command, those modules and the data files, at the command's version
# (detailed design 2.9).
# shellcheck disable=SC2016 # the pattern matches a literal $VPS_LIB_DIR
sourced="$(sed -n 's|^\. "\$VPS_LIB_DIR/\(.*\)"$|\1|p' bin/vps-proxy-setup | sort)"
modules="$(printf '%s\n' "${all_files[@]}" | sed -n 's|^lib/vps-proxy-setup/\([^/]*\.sh\)$|\1|p' | sort)"
[ "$sourced" = "$modules" ] || fail 'bin/vps-proxy-setup does not source exactly the modules in lib/vps-proxy-setup'
assets="$(sed -n '/^assets=(/,/^)/s/^  \([^ ]*\)$/\1/p' install.sh | sort)"
[ "$assets" = "$(printf '%s\n' vps-proxy-setup "$sourced" | sort)" ] ||
  fail 'install.sh assets differ from the command and its modules'
data_assets="$(sed -n '/^data_assets=(/,/)/s/^  \([^ ]*\)$/\1/p' install.sh | sort)"
data_files="$(printf '%s\n' "${all_files[@]}" | sed -n 's|^share/vps-proxy-setup/\([^/]*\)$|\1|p' | sort)"
[ "$data_assets" = "$data_files" ] || fail 'install.sh data_assets differ from share/vps-proxy-setup'
version="$(sed -n "s/^readonly VPS_VERSION='\(.*\)'$/\1/p" bin/vps-proxy-setup)"
if ! grep -qx "INSTALLER_VERSION='$version'" install.sh || ! grep -qx "RELEASE_TAG='v$version'" install.sh; then
  fail "install.sh version differs from VPS_VERSION $version"
fi
printf '[+] installer assets and version\n'

# no_match MESSAGE GIT_GREP_ARGS...: git grep over tracked and untracked files
# exits 0 on a match and 1 on none; any other status means it did not scan,
# which must not pass. --no-recurse-submodules: with submodule.recurse=true,
# git grep refuses --untracked.
no_match() {
  local message="$1" rc=0
  shift
  git grep --untracked --no-recurse-submodules "$@" || rc=$?
  case "$rc" in
    0) fail "$message" ;;
    1) ;;
    *) fail "git grep exited with $rc; the scan did not run" ;;
  esac
}

no_match 'files above contain CR characters; the repository uses LF only' -lI $'\r' -- .
printf '[+] LF line endings\n'

# Private keys and common token formats.
no_match 'lines above look like secrets' -nIE \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e 'gh[pousr]_[A-Za-z0-9]{36}' \
  -e 'github_pat_[A-Za-z0-9_]{22,}' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
  -e 'sk-[A-Za-z0-9_-]{32,}' -- .
printf '[+] no secret patterns\n'

# VT-97: addresses, UUIDs, domains and local paths (detailed design 9.1). The
# domain check knows a fixed set of top-level domains; .sh and .go are left out
# because they collide with file names here, so it is a screen, not a proof.
python3 -B - tests/privacy-allow.txt "${all_files[@]}" <<'PY'
import ipaddress
import re
import sys

allow_file, files = sys.argv[1], sys.argv[2:]
allowed_domains, cidr_exceptions = [], {}
for number, line in enumerate(open(allow_file, encoding='utf-8'), 1):
    words = line.split('#', 1)[0].split()
    if not words:
        continue
    if words[0] == 'domain' and len(words) == 2:
        allowed_domains.append(words[1].lower())
    elif words[0] == 'cidr' and len(words) >= 3:
        cidr_exceptions[words[1]] = set(words[2:])
    else:
        sys.exit(f'{allow_file}:{number}: not "domain HOST" or "cidr CIDR FILE..."')

V4_ALLOWED = [ipaddress.ip_network(n) for n in
              ('127.0.0.0/8', '10.0.0.0/8', '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24')]
V6_DOC = ipaddress.ip_network('2001:db8::/32')
TLDS = {'com', 'net', 'org', 'io', 'dev', 'app', 'ai', 'co', 'me', 'info', 'xyz', 'top', 'cloud', 'cn',
        'ru', 'ir', 'uk', 'de', 'jp', 'us', 'eu', 'biz', 'site', 'online', 'tech', 'pro', 'club', 'vip',
        'shop', 'link', 'one', 'live', 'tv', 'cc', 'ws', 'la', 'in', 'hk', 'tw', 'sg', 'kr', 'fr', 'nl',
        'se', 'ch', 'au', 'ca', 'br', 'example', 'test', 'invalid', 'localhost', 'local', 'internal'}
RESERVED = ('example', 'example.com', 'example.net', 'example.org')

ipv4 = re.compile(r'(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(/\d{1,2})?(?![\w.])')
ipv6 = re.compile(r'(?<![\w:.])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})(/\d{1,3})?(?![\w:])')
host = re.compile(r'(?<![\w.@-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,24})(?![\w-])')
uuid = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
# A drive letter or a home directory followed by a path component.
local_path = re.compile(r'(?<![\w])[A-Za-z]:[\\/][\w.-]|/(?:home|Users)/[\w.-]')


def domain_ok(name):
    name = name.lower()
    if name.split('.')[-1] in ('test', 'invalid'):
        return True
    for base in RESERVED + tuple(allowed_domains):
        if name == base or name.endswith('.' + base):
            return True
    return False


problems = []
for path in files:
    if path == allow_file:
        continue
    try:
        text = open(path, encoding='utf-8').read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for number, line in enumerate(text.splitlines(), 1):
        where = f'{path}:{number}'
        for m in ipv4.finditer(line):
            try:
                address = ipaddress.ip_address(m.group(1))
            except ValueError:
                continue
            text_cidr = m.group(0)
            if str(address) == '0.0.0.0' and m.group(2) is None:
                continue
            if any(address in n for n in V4_ALLOWED):
                continue
            if path in cidr_exceptions.get(text_cidr, ()):
                continue
            problems.append(f'{where}: IPv4 {text_cidr}')
        for m in ipv6.finditer(line):
            token = m.group(1)
            if '::' not in token and token.count(':') != 7:
                continue
            try:
                address = ipaddress.ip_address(token)
            except ValueError:
                continue
            if token in ('::', '::1') or address in V6_DOC:
                continue
            if path in cidr_exceptions.get(m.group(0), ()):
                continue
            problems.append(f'{where}: IPv6 {m.group(0)}')
        for m in host.finditer(line):
            name = m.group(1)
            if name.split('.')[-1].lower() in TLDS and not domain_ok(name):
                problems.append(f'{where}: domain {name}')
        if uuid.search(line):
            problems.append(f'{where}: UUID-shaped string')
        if local_path.search(line):
            problems.append(f'{where}: local path')
if problems:
    print('\n'.join(problems), file=sys.stderr)
    sys.exit(1)
PY
printf '[+] privacy scan (VT-97)\n'
