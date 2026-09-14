#!/usr/bin/env bash
# End-user transcript of the reported defect through the executable interface:
#   durable wake with no watcher -> arm (announces) -> drain prints the ack pair
#   -> arm again inside the handling window -> run the EXACT printed ack -> arm again.
# Prints state/.watcher-down, the lock holder and the queue after every step.
# Usage: fm-transcript.sh <tree>
set -u
tree=$1
cd "$tree/tests" || exit 1
# shellcheck disable=SC1091
. ./wake-helpers.sh
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-transcript)
dir=$(make_case transcript); home=$dir/home; state=$dir/state; fakebin=$dir/fakebin; mkdir -p "$home/data"
ARM_PID=
echo "tree=$tree  (bin/fm-watch.sh calls fm_recovery_marker_reopen_announced: $(grep -c fm_recovery_marker_reopen_announced "$ROOT/bin/fm-watch.sh") times)"
show() {
  local m lp live
  m=$(cat "$state/.watcher-down" 2>/dev/null || echo '<absent>')
  lp=$(cat "$state/.watch.lock/pid" 2>/dev/null || echo '-')
  if [ "$lp" != - ] && is_live_non_zombie "$lp"; then live=ALIVE; else live=none; fi
  printf '    => state/.watcher-down=%s | lock pid=%s (%s) | queue rows=%s\n' "$m" "$lp" "$live" "$(wc -l < "$state/.wake-queue" 2>/dev/null | tr -d ' ' || echo 0)"
}
arm() {  # <label>
  local out="$dir/$1.out" pid start i=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --restart > "$out" 2>&1 &
  pid=$!; start=$(date +%s)
  while [ $i -lt 150 ]; do is_live_non_zombie "$pid" || break; sleep 0.1; i=$((i+1)); done
  if is_live_non_zombie "$pid"; then
    echo "  $1: watcher STILL RUNNING after $(( $(date +%s)-start ))s -> it is supervising (holds the lock)"
  else
    wait "$pid" 2>/dev/null; echo "  $1: watcher EXITED (rc=$?) after $(( $(date +%s)-start ))s"
  fi
  sed 's/^/      | /' "$out"
  ARM_PID=$pid
}
stop_arm() { if [ -n "$ARM_PID" ] && is_live_non_zombie "$ARM_PID"; then kill -TERM "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; echo "  (sent SIGTERM to the supervising watcher so the next arm is a fresh start)"; fi; ARM_PID=; }

echo "STEP 0: a durable wake arrives while no watcher is live (bin/fm-wake-lib.sh fm_wake_append)"
append_wake "$state" check startup-network 'check: startup-network'; show
echo "STEP 1: bin/fm-watch-arm.sh --restart (first arm after the down stretch)"
arm arm-1; show
echo "STEP 2: bin/fm-wake-drain.sh (the handling turn drains; note the printed acknowledgement)"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"; echo "  drain rc=$?"
sed 's/^/      | /' "$dir/drain.err"; show
ack=$(sed -n 's/^WAKE_ACK_REQUIRED:.*run bin\/fm-wake-drain.sh \(.*\)$/\1/p' "$dir/drain.err")
echo "STEP 3: bin/fm-watch-arm.sh --restart while the handling turn is still running (the Claude Stop boundary)"
arm arm-2; show
echo "STEP 4: run the EXACT acknowledgement the drain printed: bin/fm-wake-drain.sh $ack"
# shellcheck disable=SC2086
FM_STATE_OVERRIDE="$state" "$DRAIN" $ack > "$dir/ack.out" 2> "$dir/ack.err"; echo "  ack rc=$?"
sed 's/^/      | /' "$dir/ack.err" "$dir/ack.out"; show
echo "STEP 5: bin/fm-watch-arm.sh --restart after the acknowledgement"
stop_arm; arm arm-3; show
echo "STEP 6: one more bin/fm-watch-arm.sh --restart (does the episode ever settle?)"
stop_arm; arm arm-4; show
stop_arm
echo "FINAL: state/.watcher-down=$(cat "$state/.watcher-down" 2>/dev/null || echo '<absent>')"
