#!/usr/bin/env bash
# repro-stuck-episode.sh - operator-level reproduction of the stuck recovery
# episode, driven through the executable interface only:
#   * bin/fm-watch-arm.sh in plain arm mode (exactly what bin/fm-claude-stop-autoarm.sh runs)
#   * bin/fm-wake-drain.sh (the handling turn)
#   * the EXACT "--ack-through N --recovery-generation G" command the drain prints
# against a fresh home. Nothing is asserted; every step prints the marker
# (state/.watcher-down), the queue size and whether a live watcher holds the lock.
# Usage: WT=<worktree> bash repro-stuck-episode.sh <label>
set -u
WT=${WT:?worktree root}
label=${1:-run}
FM_TEST_ONLY=true
# shellcheck disable=SC1090
. "$WT/tests/.nm-single-fm-watch-arm.sh"   # helpers only (make_case, append_wake, is_live_non_zombie)

WATCH_ARM="$WT/bin/fm-watch-arm.sh"
DRAIN="$WT/bin/fm-wake-drain.sh"
dir=$(make_case "repro-$label"); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"
mkdir -p "$home/data"
T0=$(date +%s)
declare -a ARM_PIDS SUMMARY

t() { printf '[t+%3ss]' "$(( $(date +%s) - T0 ))"; }
marker() { cat "$state/.watcher-down" 2>/dev/null || echo "(absent)"; }
queue_rows() { if [ -s "$state/.wake-queue" ]; then wc -l < "$state/.wake-queue" | tr -d ' '; else echo 0; fi; }
lock_state() {
  local pid; pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && is_live_non_zombie "$pid"; then echo "home lock: held by LIVE watcher pid=$pid"
  else echo "home lock: NO live watcher holds it (bin/fm-turnend-guard.sh would block the turn)"; fi
}
show() { echo "    marker=$(marker)   queue-rows=$(queue_rows)"; echo "    $(lock_state)"; }

arm() { # <n> <description>
  local n=$1 desc=$2 i=0 verdict head out
  out="$dir/arm$n.out"
  echo; echo "$(t) == arm #$n: $desc =="
  echo "    \$ bin/fm-watch-arm.sh        # plain arm mode, as the Stop auto-arm runs it"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$out" 2>&1 &
  ARM_PIDS[$n]=$!
  while [ "$i" -lt 80 ]; do
    is_live_non_zombie "${ARM_PIDS[$n]}" || break
    grep -q 'check: rearm-resurface' "$out" 2>/dev/null && break
    sleep 0.1; i=$((i + 1))
  done
  sleep 1
  if is_live_non_zombie "${ARM_PIDS[$n]}"; then
    head=$(grep -o '^watcher: [a-z]* pid=[0-9]*' "$out" | head -1)
    verdict="arm STILL LIVE 8s later (${head:-no started/attached line yet}) -> a watcher is holding the home lock"
  else
    wait "${ARM_PIDS[$n]}"; verdict="arm EXITED rc=$? within seconds"
    grep -q 'check: rearm-resurface' "$out" && verdict="$verdict, emitting the recovery announcement \"check: rearm-resurface\""
  fi
  echo "    -> $verdict"
  sed 's/^/    | /' "$out"
  show
  SUMMARY+=("$(printf '%-34s %-52s marker=%s' "arm #$n ($desc)" "${verdict%% ->*}" "$(marker)")")
}

echo "$(t) == step 0: fresh home, a durable wake arrives while NO watcher is live (a down stretch) =="
append_wake "$state" check startup-network 'check: startup-network'
show

arm 1 "first arm after downtime"

echo; echo "$(t) == the handling turn drains: bin/fm-wake-drain.sh =="
FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"; echo "    drain rc=$?"
sed 's/^/    | /' "$dir/drain.out" "$dir/drain.err"
ack_line=$(grep '^WAKE_ACK_REQUIRED' "$dir/drain.err" || true)
seq_=$(printf '%s\n' "$ack_line" | sed -n 's/.*--ack-through \([0-9]*\) .*/\1/p')
gen_=$(printf '%s\n' "$ack_line" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
show
SUMMARY+=("$(printf '%-34s %-52s marker=%s' "drain (handling turn)" "printed ack: --ack-through $seq_ --recovery-generation $gen_" "$(marker)")")

arm 2 "Stop-boundary arm INSIDE the handling window"

echo; echo "$(t) == the model runs the EXACT acknowledgement the drain printed =="
echo "    \$ bin/fm-wake-drain.sh --ack-through $seq_ --recovery-generation $gen_"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq_" --recovery-generation "$gen_" > "$dir/ack.out" 2> "$dir/ack.err"; rc=$?
echo "    ack rc=$rc"; sed 's/^/    | /' "$dir/ack.out" "$dir/ack.err"
show
case "$(marker)" in acked:*) v="ACCEPTED and episode RETIRED (acked:*)";; *) v="rc=$rc but episode NOT retired";; esac
SUMMARY+=("$(printf '%-34s %-52s marker=%s' "ack (exact printed pair, gen $gen_)" "$v" "$(marker)")")

arm 3 "next Stop-boundary arm, after the ack"
arm 4 "one more Stop-boundary arm"

echo; echo "$(t) == does a live watcher still do real work? a crew status changes =="
printf 'blocked: a later wake the live watcher must surface\n' > "$state/later.status"
i=0; while [ "$i" -lt 100 ]; do
  grep -q '^signal:' "$dir/arm2.out" "$dir/arm3.out" "$dir/arm4.out" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
sleep 1
if grep -h '^signal:' "$dir"/arm[234].out 2>/dev/null | head -1 | grep -q .; then
  echo "    -> a watcher WOKE on the status change:"; grep -H '^signal:' "$dir"/arm[234].out | sed 's/^/    | /'
  SUMMARY+=("$(printf '%-34s %-52s' "crew status change" "DELIVERED by the live watcher (signal: line)")")
else
  echo "    -> NO watcher delivered the status change within 10s (no live watcher to deliver it)"
  SUMMARY+=("$(printf '%-34s %-52s' "crew status change" "NOT delivered: no live watcher")")
fi
show

# clean up whatever is still running from this home
for p in "${ARM_PIDS[@]}" "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
sleep 0.5
echo; echo "================ SUMMARY [$label] ================"
printf '%s\n' "${SUMMARY[@]}"
