#!/usr/bin/env bash
set -u
EV=/tmp/no-mistakes-evidence/01M2ES3XDFDCDTSH4R85C432Z4
BASE=/tmp/fm-base-b182d0f
TGT=/tmp/fm-target-99f67cc
NEWTEST=$TGT/tests/fm-watch-arm.test.sh
run() { # <label> <tree> <file> <case> [src]
  local label=$1; shift
  /tmp/fm-focused-run.sh "$@" > "$EV/$label.log" 2>&1
  printf '%s\t%s\n' "$label" "exit=$?" >> "$EV/before-after-summary.tsv"
}
: > "$EV/before-after-summary.tsv"
for c in test_repeated_rearm_cannot_starve_the_watcher_lock test_arm_inside_handling_keeps_the_episode_retirable test_midloop_recovery_discovery_announces_the_generation_once; do
  run "base-bin__$c" "$BASE" fm-watch-arm.test.sh "$c" "$NEWTEST"
done
for c in test_repeated_rearm_cannot_starve_the_watcher_lock test_arm_inside_handling_keeps_the_episode_retirable test_midloop_recovery_discovery_announces_the_generation_once; do
  run "target-bin__$c" "$TGT" fm-watch-arm.test.sh "$c" "$NEWTEST"
done
# CI regression the intent describes: the ORIGINAL pr-check case (base test file) against the FIXED bin/
run "target-bin__ORIGINAL-case__test_rejected_metacharacter_bytes_are_inert" "$TGT" fm-pr-check-security.test.sh test_rejected_metacharacter_bytes_are_inert "$BASE/tests/fm-pr-check-security.test.sh"
# Corrected pr-check case against the fixed bin/
run "target-bin__test_rejected_metacharacter_bytes_are_inert" "$TGT" fm-pr-check-security.test.sh test_rejected_metacharacter_bytes_are_inert
echo "chain done $(date -Is)"
