#!/usr/bin/env bash
# Focused single-case runner: <tree> <test-file-basename> <test-name> [source-test-file]
# Copies the test file (optionally taken from another tree, so the NEW regression
# test can be run against the OLD bin/) into <tree>/tests with the trailing
# invocation block stripped and only <test-name> invoked. ROOT resolves from the
# tree's own tests/lib.sh, so bin/ under <tree> is what actually runs.
set -u
tree=$1 file=$2 name=$3 src=${4:-$1/tests/$2}
out="$tree/tests/.focused-$name.test.sh"
awk '!/^test_[a-z_0-9]+$/' "$src" > "$out"
printf '\n%s\n' "$name" >> "$out"
chmod +x "$out"
echo "## tree=$tree bin/fm-watch.sh reopen-call-count=$(grep -c fm_recovery_marker_reopen_announced "$tree/bin/fm-watch.sh") case=$name"
echo "## started $(date -Is) load=$(cut -d' ' -f1-3 /proc/loadavg)"
start=$(date +%s)
bash "$out"
rc=$?
echo "## exit=$rc elapsed=$(( $(date +%s) - start ))s"
exit $rc
