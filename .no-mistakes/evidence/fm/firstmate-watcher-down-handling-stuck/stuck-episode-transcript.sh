#!/usr/bin/env bash
# End-to-end reproduction of the reported supervision deadlock in a scratch state dir.
# Drives the real bin/fm-watch-arm.sh (Stop-boundary style --restart arm) and
# bin/fm-wake-drain.sh exactly as a handling turn does: arm -> drain -> re-arm while
# handling -> run the exact WAKE_ACK_REQUIRED command the drain printed -> re-arm.
set -u
WT=$1 LABEL=$2
cd "$WT" || exit 1
# shellcheck disable=SC1091
. "$WT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-evidence-stuck-episode)
dir=$(make_case loop); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$home/data"
ARM="$WT/bin/fm-watch-arm.sh"; DRAIN="$WT/bin/fm-wake-drain.sh"
drain_ack_pair() {
  local err=$1 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$sequence" "$generation"
}
ARM_PID=; held=0; resurfaced=0; arms=0
marker() { printf '    state/.watcher-down = %s\n' "$(cat "$state/.watcher-down" 2>/dev/null || echo '<absent>')"; }
lockholder() {
  local p; p=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$p" ] && is_live_non_zombie "$p"; then printf '    home lock: held by live watcher pid %s\n' "$p"; else printf '    home lock: NO live watcher holds it\n'; fi
}
stop_arm() {
  [ -n "$ARM_PID" ] || return 0
  if is_live_non_zombie "$ARM_PID"; then kill -TERM "$ARM_PID" 2>/dev/null || true; fi
  wait "$ARM_PID" 2>/dev/null || true
  local p; p=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$p" ] || { kill -TERM "$p" 2>/dev/null || true; }
  for _ in $(seq 1 30); do [ -n "$p" ] && is_live_non_zombie "$p" || break; sleep 0.1; done
  ARM_PID=
}
arm() {  # <name>
  local out="$dir/$1.out" i=0
  arms=$((arms + 1))
  printf '\n$ bin/fm-watch-arm.sh --restart    # %s\n' "$1"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ARM" --restart > "$out" 2>&1 &
  ARM_PID=$!
  while [ "$i" -lt 60 ] && is_live_non_zombie "$ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  sed 's/^/    | /' "$out"
  if is_live_non_zombie "$ARM_PID"; then
    printf '    -> arm still live after 6s: supervising (poll loop reached)\n'; held=$((held + 1))
  else
    wait "$ARM_PID" 2>/dev/null; printf '    -> arm exited within 6s\n'
    grep -qF 'check: rearm-resurface' "$out" && resurfaced=$((resurfaced + 1))
    ARM_PID=
  fi
  lockholder; marker
}
echo "##### $LABEL"
echo "# scratch state dir: $state"
printf '\n# 1. a durable wake is queued while no watcher is live (a down stretch)\n'
append_wake "$state" check startup-network 'check: startup-network'; marker
for round in 1 2 3; do
  printf '\n# ===== round %s =====\n' "$round"
  arm "round$round-arm-A"
  stop_arm
  printf '\n$ bin/fm-wake-drain.sh    # handling turn drains\n'
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain$round.out" 2> "$dir/drain$round.err"
  sed 's/^/    | /' "$dir/drain$round.out" "$dir/drain$round.err" | grep -v '^    | $'
  pair=$(drain_ack_pair "$dir/drain$round.err") || { echo "    (drain printed no ack command)"; marker; continue; }
  seq=${pair%%$'\t'*}; gen=${pair##*$'\t'}
  marker
  printf '\n# Stop boundary: the next watcher arms while the handling turn is still running\n'
  arm "round$round-arm-B-during-handling"
  printf '\n$ bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s    # exact printed command\n' "$seq" "$gen"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" > "$dir/ack$round.out" 2>&1
  rc=$?
  sed 's/^/    | /' "$dir/ack$round.out"; printf '    exit=%s\n' "$rc"; marker
  stop_arm
done
printf '\n# SUMMARY (%s): arms=%s  arms-that-reached-supervision=%s  arms-that-exited-on-rearm-resurface=%s\n' "$LABEL" "$arms" "$held" "$resurfaced"
