#!/usr/bin/env bash
# Same per-case driver as run-single-cases.sh, for any suite file.
# usage: run-single-cases-generic.sh <repo-root> <suite-file> <case> [case...]
set -u
ROOT=$1; SUITE=$2; shift 2
BODY="$ROOT/tests/.single-case-body.sh"
grep -v '^test_[a-z_]*$' "$ROOT/tests/$SUITE" > "$BODY"
# shellcheck disable=SC1090
. "$BODY"
rc=0
for t in "$@"; do
  printf '\n--- %s ---\n' "$t"
  ( "$t" ) || rc=1
done
rm -f "$BODY"
exit "$rc"
