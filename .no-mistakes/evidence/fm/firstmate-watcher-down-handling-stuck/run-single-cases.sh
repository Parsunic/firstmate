#!/usr/bin/env bash
# Run named cases from tests/fm-watch-arm.test.sh one at a time.
#
# The shipped suite calls fail(), which exits the whole file, so the first
# failure hides every later case. This driver copies the suite's body (its
# bottom-of-file invocation lines are the only bare `test_*` lines, so dropping
# those leaves definitions only) next to the real helpers, then calls each named
# case in its own subshell - so every named case reports its own verdict.
#
# usage: run-single-cases.sh <repo-root> <case> [case...]
set -u
ROOT=$1; shift
BODY="$ROOT/tests/.single-case-body.sh"
grep -v '^test_[a-z_]*$' "$ROOT/tests/fm-watch-arm.test.sh" > "$BODY"
cleanup() { rm -f "$BODY"; }
trap cleanup EXIT
# shellcheck disable=SC1090
. "$BODY"
rc=0
for t in "$@"; do
  printf '\n--- %s ---\n' "$t"
  ( "$t" ) || rc=1
done
exit "$rc"
