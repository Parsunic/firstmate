#!/usr/bin/env bash
# End-to-end demonstration of the pause-recheck suppression change.
#
# Reproduces the reported 2026-08-20 case with the real bin/ scripts:
# a task parked on an upstream PR with a validated merge poll armed, whose
# declared pause was re-surfaced as an hourly "confirm the wait still holds"
# wake even though the poll would report the merge by itself.
#
# Each round below is one FM_PAUSE_RESURFACE_SECS window ("one hour" in
# production). The demo drives bin/fm-watch.sh for real - fake tmux, fake
# fm-crew-state and fake gh only - at the BASE commit and then at the change,
# and finishes with the fleet digest a supervisor actually reads.
#
# Usage: pause-recheck-demo.sh <target-root> <base-root> <out-dir>
#   <target-root>  a checkout of this change
#   <base-root>    a checkout of the base commit, e.g.
#                    base=$(mktemp -d); git archive 1cb900c | tar -x -C "$base"
#   <out-dir>      where pause-recheck-demo.txt is written
set -u

TARGET_ROOT=$1
BASE_ROOT=$2
OUT=$3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pause-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PR_URL=https://github.com/kunchenguid/firstmate/pull/2606
TASK=fm-context-restart-handoff
WINDOW="fm:$TASK"
PANE='idle - waiting on upstream PR 2606'
AGE=5000          # seconds the pause has been standing
RESURFACE=60      # stands in for the 3600s production FM_PAUSE_RESURFACE_SECS

hash_text() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------------"; }

# A hermetic fixture home: fake tmux/fm-crew-state/gh, a task parked on the PR.
# <root> is the checkout whose bin/ arms the poll, so the base round is armed
# and polled entirely by base code.
make_home() {  # <root> <name> <status-line> <arm-poll:yes|no|custom-check>
  local root=$1 name=$2 line=$3 arm=$4 dir state
  dir="$WORK/$name"; state="$dir/state"
  mkdir -p "$state" "$dir/fakebin" "$dir/pr-root/bin"

  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  display-message) case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac ;;
esac
exit 1
SH
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown}"
SH
  # The forge as the poll sees it: the PR is still open, so the poll stays silent.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_PR_STATE:-OPEN}"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/pr-root/bin/fm-guard.sh"
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/fm-crew-state.sh" "$dir/fakebin/gh" "$dir/pr-root/bin/fm-guard.sh"

  printf '%s' "$PANE" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$WINDOW" > "$state/$TASK.meta"
  printf '%s\n' "$line" > "$state/$TASK.status"
  touch -m -d "@$(( $(date +%s) - AGE ))" "$state/$TASK.status"

  case "$arm" in
    yes)
      FM_ROOT_OVERRIDE="$dir/pr-root" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
        PATH="$dir/fakebin:$PATH" "$root/bin/fm-pr-check.sh" "$TASK" "$PR_URL" >/dev/null || return 1 ;;
    custom-check)
      # A legitimate registered check that is NOT the validated merge poll.
      printf '#!/usr/bin/env bash\nexit 0\n' > "$state/$TASK.check.sh"
      chmod 0700 "$state/$TASK.check.sh"
      FM_STATE_OVERRIDE="$state" "$root/bin/fm-check-register.sh" "$TASK" >/dev/null || return 1 ;;
  esac

  printf '%s' "$(seen_sig "$state/$TASK.status")" > "$state/.seen-${TASK}_status"
  local key; key=$(printf '%s' "$WINDOW" | tr ':/.' '___')
  printf '%s' "$(hash_text "$PANE")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# One supervision window against the always-on watcher. Prints whatever the
# watcher would hand firstmate: a wake reason costs a model turn, silence is free.
watch_round() {  # <root> <dir>
  local root=$1 dir=$2 state key pid out
  state="$dir/state"
  out="$dir/watch.out"; : > "$out"
  # Each round is a fresh supervision window, so the registered-check sweep is
  # due again exactly as it would be an hour later in production.
  rm -f "$state/.last-check"
  key=$(printf '%s' "$WINDOW" | tr ':/.' '___')
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_PR_STATE="${FM_FAKE_PR_STATE:-OPEN}" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream PR 2606' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_ROOT_OVERRIDE="$dir/pr-root" \
    FM_PAUSE_RESURFACE_SECS="$RESURFACE" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$root/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  local i=0
  while [ "$i" -lt 60 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25; i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true

  if [ -s "$out" ]; then
    say "  firstmate is woken:"
    sed 's/^/    > /' "$out"
    say "  (a wake costs firstmate one full model turn)"
    # Ack the durable queue so the next window starts clean, as a real drain would.
    FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir/pr-root" \
      "$root/bin/fm-wake-drain.sh" >/dev/null 2>"$dir/drain.err" || true
    local seq gen
    seq=$(sed -n 's/.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$dir/drain.err")
    gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
    [ -n "$seq" ] && FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir/pr-root" \
      "$root/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
    # Age the re-surface throttle so the next window is due, as an hour would.
    [ -e "$state/.paused-resurfaced-$key" ] \
      && touch -m -d "@$(( $(date +%s) - AGE ))" "$state/.paused-resurfaced-$key"
    return 0
  else
    say "  firstmate is not woken (watcher still absorbing)"
    # This demo restarts the watcher each window; a killed watcher leaves a
    # downtime-recovery marker that would resurface its own restart next round.
    rm -f "$state/.watcher-down"
    return 1
  fi
}

exec > >(tee "$OUT/pause-recheck-demo.txt") 2>&1

say "############################################################"
say "# Declared pause + armed merge poll: what firstmate is asked"
say "############################################################"
say
say "Fixture (all rounds):  task $TASK"
say "                       status line 'paused: awaiting upstream PR 2606'"
say "                       parked ${AGE}s, one validated merge poll armed on"
say "                       $PR_URL (still open on the forge)"
say "Each round below is one FM_PAUSE_RESURFACE_SECS window - one hour in production."
say

rule
say "BEFORE  (base commit, bin/ from $(git -C "$TARGET_ROOT" rev-parse --short HEAD~3 2>/dev/null || echo base))"
rule
before_dir=$(make_home "$BASE_ROOT" before 'paused: awaiting upstream PR 2606' yes) \
  || { say "could not arm the base fixture"; exit 1; }
say "armed poll: $(ls "$before_dir/state" | tr '\n' ' ')"
say
wakes=0
for h in 1 2 3; do
  say "hour $h:"
  watch_round "$BASE_ROOT" "$before_dir" && wakes=$((wakes + 1))
  say
done
say "=> $wakes of 3 hours woke firstmate, every answer 'still open, nothing changed'."
say

rule
say "AFTER   (this change)"
rule
after_dir=$(make_home "$TARGET_ROOT" after 'paused: awaiting upstream PR 2606' yes) \
  || { say "could not arm the fixture"; exit 1; }
wakes=0
for h in 1 2 3; do
  say "hour $h:"
  watch_round "$TARGET_ROOT" "$after_dir" && wakes=$((wakes + 1))
  say
done
say "=> $wakes of 3 hours woke firstmate."
say
say "What a supervisor sees instead of the hourly wake:"
say
say "  \$ cat state/.$TASK.pause-poll-covered"
sed 's/^/    /' "$after_dir/state/.$TASK.pause-poll-covered" 2>/dev/null || say "    (missing)"
say
say "  \$ grep 'suppressed paused recheck' state/.watch-triage.log | tail -3"
grep -F 'suppressed paused recheck' "$after_dir/state/.watch-triage.log" 2>/dev/null | tail -3 | sed 's/^/    /'
say
say "  \$ fm-session-start.sh   (fleet digest, the first thing firstmate reads)"
FM_HOME="$after_dir" FM_STATE_OVERRIDE="$after_dir/state" \
  "$TARGET_ROOT/bin/fm-session-start.sh" 2>/dev/null \
  | grep -A 8 -F -e "--- $TASK ---" | sed 's/^/    /' || say "    (digest unavailable)"
say

rule
say "AFTER   declared pause with NO armed poll - the recheck this is for"
rule
plain_dir=$(make_home "$TARGET_ROOT" plain 'paused: awaiting upstream PR 2606' no)
say "hour 1:"
watch_round "$TARGET_ROOT" "$plain_dir" || true
say
say "coverage note written? $( [ -e "$plain_dir/state/.$TASK.pause-poll-covered" ] && echo yes || echo 'no - nothing claims a suppression')"
say

rule
say "AFTER   declared pause whose check.sh is registered but is NOT the merge poll"
rule
custom_dir=$(make_home "$TARGET_ROOT" custom 'paused: awaiting upstream PR 2606' custom-check)
say "hour 1:"
watch_round "$TARGET_ROOT" "$custom_dir" || true
say
say "coverage note written? $( [ -e "$custom_dir/state/.$TASK.pause-poll-covered" ] && echo yes || echo 'no - an untrusted check suppresses nothing')"
say

rule
say "AFTER   the covering PR is CLOSED without merging - coverage must lapse"
rule
closed_dir=$(make_home "$TARGET_ROOT" closed 'paused: awaiting upstream PR 2606' yes)
say "hour 1 (forge says the PR is still open):"
FM_FAKE_PR_STATE=OPEN watch_round "$TARGET_ROOT" "$closed_dir" || true
say "  coverage note: $( [ -e "$closed_dir/state/.$TASK.pause-poll-covered" ] && echo present || echo absent)"
say
say "hour 2 (forge now says the PR was closed without merging):"
FM_FAKE_PR_STATE=CLOSED watch_round "$TARGET_ROOT" "$closed_dir" || true
say "  coverage note: $( [ -e "$closed_dir/state/.$TASK.pause-poll-covered" ] && echo present || echo 'withdrawn - the poll will never speak again')"
say "  durable terminal observation: $( [ -e "$closed_dir/state/$TASK.pr-poll-terminal" ] && tr '\n' ' ' < "$closed_dir/state/$TASK.pr-poll-terminal" || echo none)"
say

rule
say "AFTER   away mode (bin/fm-supervise-daemon.sh) on the same three fixtures"
rule
run_housekeeping() {  # <dir>
  local dir=$1 state dkey
  state="$dir/state"
  dkey=$(printf '%s' "$TASK" | tr ':/.' '___')
  echo $(( $(date +%s) - AGE )) > "$state/.subsuper-paused-$dkey"
  : > "$state/.subsuper-escalations"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir/pr-root" \
    FM_PAUSE_RESURFACE_SECS="$RESURFACE" FM_ESCALATE_BATCH_SECS=999999 \
    bash -c 'set -u; . "$1/bin/fm-supervise-daemon.sh"; housekeeping "$2"' _ "$TARGET_ROOT" "$state" >/dev/null 2>&1
  if [ -s "$state/.subsuper-escalations" ]; then
    say "  escalated to firstmate:"
    sed 's/^/    > /' "$state/.subsuper-escalations"
  else
    say "  nothing escalated"
  fi
}
say "poll-covered pause:"
run_housekeeping "$after_dir"
say "pause with no poll:"
run_housekeeping "$plain_dir"
say "check.sh that is not the merge poll:"
run_housekeeping "$custom_dir"
say
say "Both supervisors agree on all three fixtures."
