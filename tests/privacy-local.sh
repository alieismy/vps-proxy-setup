#!/usr/bin/env bash
# Scan the repository for identifiers that cannot be listed in it: provider
# names, production targets, real addresses (detailed design 9.1, 11). Run it
# before pushing, with a list kept outside the repository, one fixed string per
# line; empty lines and lines starting with # are ignored. Matching ignores
# case. Only locations are printed, never the matched text.
#
#   bash tests/privacy-local.sh /path/outside/the/repository/private-list.txt

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail 'usage: bash tests/privacy-local.sh <private list>'
list="$(readlink -f -- "$1")" || fail "cannot resolve $1"
[ -f "$list" ] && [ -r "$list" ] || fail "cannot read $1"
case "$list" in
  "$(pwd -P)"/*) fail 'the private list must be outside the repository' ;;
esac
patterns="$(mktemp)"
trap 'rm -f -- "$patterns"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$list" >"$patterns" || fail 'the private list has no entries'

found=0
# Working tree: tracked files and new files not yet added.
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  if lines="$(grep -niIF -f "$patterns" -- "$file" | cut -d: -f1)" && [ -n "$lines" ]; then
    printf '[x] %s: line %s\n' "$file" "$(tr '\n' ' ' <<<"$lines")"
    found=1
  fi
done < <(git ls-files -co --exclude-standard -z)

# History: every commit reachable from a ref is pushed with it. Messages and
# changes are scanned; only commit IDs are printed.
# The text is read whole first: grep -q stopping early would kill git show with
# SIGPIPE, and pipefail would turn a match into a miss (detailed design 8).
while IFS= read -r commit; do
  text="$(git show --format='%B' --no-color "$commit")"
  if grep -qiF -f "$patterns" <<<"$text"; then
    printf '[x] commit %s\n' "$commit"
    found=1
  fi
done < <(git rev-list --all)

[ "$found" -eq 0 ] || fail 'entries of the private list appear above'
printf '[+] no entry of the private list in the working tree or the history\n'
