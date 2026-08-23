#!/usr/bin/env bash
# Manual end-to-end evidence for PR #2750 (rebased): what a supervisor sees when a
# declared pause is covered by this task's own armed merge poll, and what happens
# when that coverage lapses. Drives the REAL bin/ scripts from the worktree with
# the same hermetic fakes the repo's tests use (fake tmux, fake gh).
set -u
WT=${WT:?}
# Load the repo's test helpers (lib.sh, wake-helpers.sh) and the session-start
# harness helpers without running any of its tests.
export FM_ROOT_OVERRIDE=/tmp/fm-demo-root; mkdir -p "$FM_ROOT_OVERRIDE/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FM_ROOT_OVERRIDE/bin/fm-guard.sh"; chmod +x "$FM_ROOT_OVERRIDE/bin/fm-guard.sh"
sed -E '/^test_[a-z0-9_]+$/d; /^echo "# fm-session-start/d' "$WT/tests/fm-session-start.test.sh" > /tmp/fm-ss-helpers.sh
sed -i "s|\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. \"$WT/tests/lib.sh\"|; s|\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/wake-helpers.sh\"|. \"$WT/tests/wake-helpers.sh\"|" /tmp/fm-ss-helpers.sh
. /tmp/fm-ss-helpers.sh
. /tmp/fm-triage-helpers.sh
TMP_ROOT=$(fm_test_tmproot fm-demo)

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
show() { printf '$ %s\n' "$*"; }

dir=$(make_case covered); state="$dir/state"; fakebin="$dir/fakebin"
window="test:fm-held"; statusf="$state/held.status"; capture="$dir/pane.txt"
printf 'idle, holding for the upstream PR' > "$capture"
printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_GH_FAIL:-}" ] && exit 1
printf '%s\n' "${FM_FAKE_PR_STATE:-OPEN}"
SH
chmod +x "$fakebin/gh"

step "1. The crew declares an external wait on an upstream PR"
printf 'paused: awaiting upstream PR 2606\n' > "$statusf"
show "cat state/held.status"; cat "$statusf"

step "2. The PR merge poll is armed for the same task with the real bin/fm-pr-check.sh"
show "bin/fm-pr-check.sh held https://github.com/o/r/pull/2606"
FM_HOME="$dir" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" "$WT/bin/fm-pr-check.sh" held https://github.com/o/r/pull/2606
show "ls state/"; ls "$state" | grep -v '^\.' | sed 's/^/  /'

age_status() { local back; back=$(( $(date +%s) - 5000 )); touch -m -d "@$back" "$statusf"; }
seed_watch() {
  local key sig
  key=$(printf '%s' "$window" | tr ':/.' '___')
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  printf '%s' "$(hash_text 'idle, holding for the upstream PR')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}
run_watch_cycle() {  # [extra env...]; returns 0 if watcher stayed alive through a full poll, 1 if it exited (woke)
  local pid rc
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream PR 2606' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 env "$@" "$WATCH" > "$dir/watch.out" &
  pid=$!
  if wait_poll_cycle "$state" "$pid"; then rc=0; else rc=1; fi
  reap "$pid" 2>/dev/null
  return $rc
}

step "3. The pause is 5000s old (> FM_PAUSE_RESURFACE_SECS=240): a recheck is DUE. Run one always-on watcher poll cycle"
age_status; seed_watch; : > "$state/.watch-triage.log"
if run_watch_cycle; then
  echo "watcher result: stayed alive through a full poll cycle - NO wake, firstmate was not re-armed"
else
  echo "watcher result: EXITED with a wake:"; cat "$dir/watch.out"
fi
show "cat state/.watch-triage.log"; sed 's/^/  /' "$state/.watch-triage.log"
show "cat state/.wake-queue"; if [ -s "$state/.wake-queue" ]; then cat "$state/.wake-queue"; else echo "  (empty - no recheck queued)"; fi
show "ls state/.paused-resurfaced-*"; ls "$state"/.paused-resurfaced-* 2>/dev/null || echo "  (absent - throttle deliberately NOT advanced, so a lapse re-surfaces on the very next poll)"
show "cat state/.held.pause-poll-covered"; sed 's/^/  /' "$state/.held.pause-poll-covered"

step "4. The same due recheck in AWAY mode (bin/fm-supervise-daemon.sh housekeeping) reaches the same verdict"
dkey=held; echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$dkey"; rm -f "$state/.subsuper-escalations"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 FM_ESCALATE_BATCH_SECS=999999 \
  bash -c 'set -u; . "$1/bin/fm-supervise-daemon.sh"; housekeeping "$2"' _ "$WT" "$state" 2>&1 | sed 's/^/  daemon: /'
show "cat state/.subsuper-escalations"; if [ -s "$state/.subsuper-escalations" ]; then cat "$state/.subsuper-escalations"; else echo "  (empty - nothing escalated to the captain digest)"; fi
show "ls state/.subsuper-paused-held"; ls "$state/.subsuper-paused-$dkey" >/dev/null && echo "  present (marker kept, so a lapse escalates on the next tick)"

step "5. What the captain sees at session start: the fleet digest names the covering PR under the task"
rec=$(new_world digest); IFS='|' read -r root home ssfakebin <<EOF
$rec
EOF
make_fake_toolchain "$ssfakebin"; make_fake_ps_claude "$ssfakebin"; make_fake_tmux "$ssfakebin" "fm-sess:live"
printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/held.meta"
cp "$statusf" "$home/state/held.status"; cp "$state/.held.pause-poll-covered" "$home/state/.held.pause-poll-covered"
show "bin/fm-session-start.sh  (FLEET STATE section, task 'held')"
run_session_start "$home" "$root" "$ssfakebin:/usr/bin:/bin:/usr/sbin:/sbin" 2>/dev/null | sed -n '/^--- held ---$/,/^--- \|^CONTEXT$/p' | sed '$d' | sed 's/^/  /'

step "6. Coverage LAPSES when the covering PR is observed closed without merging (fresh fixture; fake gh answers CLOSED; check sweep due)"
dir6=$(make_case closed); state6="$dir6/state"; cp "$fakebin/gh" "$dir6/fakebin/gh"
printf 'window=%s\nkind=ship\n' "$window" > "$state6/held.meta"; printf 'paused: awaiting upstream PR 2606\n' > "$state6/held.status"
FM_HOME="$dir6" FM_STATE_OVERRIDE="$state6" PATH="$dir6/fakebin:$PATH" "$WT/bin/fm-pr-check.sh" held https://github.com/o/r/pull/2606 >/dev/null
dir=$dir6; state=$state6; fakebin="$dir6/fakebin"; statusf="$state6/held.status"; capture="$dir6/pane.txt"; printf 'idle, holding for the upstream PR' > "$capture"
show "pause_recheck_covered_by_merge_poll state held  (coverage established first, so what follows is a withdrawal)"
pause_recheck_covered_by_merge_poll "$state" held && echo "  -> covered (rc=0)"; show "cat state/.held.pause-poll-covered"; sed 's/^/  /' "$state/.held.pause-poll-covered"
age_status; seed_watch; : > "$state/.watch-triage.log"
if run_watch_cycle FM_FAKE_PR_STATE=CLOSED FM_CHECK_INTERVAL=1; then
  echo "watcher result: stayed alive (unexpected)"
else
  echo "watcher result: EXITED with the ordinary recheck wake:"; sed 's/^/  /' "$dir/watch.out"
fi
show "cat state/held.pr-poll-terminal"; sed 's/^/  /' "$state/held.pr-poll-terminal"
show "ls state/.held.pause-poll-covered"; ls "$state/.held.pause-poll-covered" 2>/dev/null || echo "  (withdrawn - the note never outlives the coverage)"
show "grep -c closed-unmerged state/.wake-queue"; n=$(grep -c closed-unmerged "$state/.wake-queue" 2>/dev/null || true); echo "  ${n:-0} (the terminal observation is NOT its own check wake; the declared-pause recheck is what resumes)"
show "cat state/.wake-queue"; sed 's/^/  /' "$state/.wake-queue"

step "7. Disconfirming case: an inconclusive poll (gh fails) is NOT a lapse - recheck stays suppressed"
dir2=$(make_case inconclusive); state2="$dir2/state"; cp "$fakebin/gh" "$dir2/fakebin/gh"
printf 'window=%s\nkind=ship\n' "$window" > "$state2/held.meta"; printf 'paused: awaiting upstream PR 2606\n' > "$state2/held.status"
FM_HOME="$dir2" FM_STATE_OVERRIDE="$state2" PATH="$dir2/fakebin:$PATH" "$WT/bin/fm-pr-check.sh" held https://github.com/o/r/pull/2606 >/dev/null
dir=$dir2; state=$state2; fakebin="$dir2/fakebin"; statusf="$state2/held.status"; capture="$dir2/pane.txt"; printf 'idle, holding for the upstream PR' > "$capture"
age_status; seed_watch; : > "$state/.watch-triage.log"
if run_watch_cycle FM_FAKE_GH_FAIL=1 FM_CHECK_INTERVAL=1; then echo "watcher result: stayed alive - NO wake"; else echo "watcher result: EXITED:"; cat "$dir/watch.out"; fi
show "ls state/held.pr-poll-terminal"; ls "$state/held.pr-poll-terminal" 2>/dev/null || echo "  (absent - silence is not a rejection)"
show "cat state/.held.pause-poll-covered"; sed 's/^/  /' "$state/.held.pause-poll-covered"

step "8. Disconfirming case: a declared pause with NO armed poll still gets its ordinary recheck"
dir3=$(make_case nopoll); state3="$dir3/state"
printf 'window=%s\nkind=ship\n' "$window" > "$state3/held.meta"; printf 'paused: awaiting upstream PR 2606\n' > "$state3/held.status"
dir=$dir3; state=$state3; fakebin="$dir3/fakebin"; statusf="$state3/held.status"; capture="$dir3/pane.txt"; printf 'idle, holding for the upstream PR' > "$capture"
age_status; seed_watch
if run_watch_cycle; then echo "watcher result: stayed alive (unexpected)"; else echo "watcher result: EXITED with the ordinary recheck wake:"; sed 's/^/  /' "$dir/watch.out"; fi
show "ls state/.held.pause-poll-covered"; ls "$state/.held.pause-poll-covered" 2>/dev/null || echo "  (absent - nothing was suppressed, so nothing is claimed)"

step "9. Disconfirming case: a CAPTAIN HOLD with an armed poll keeps its bounded recheck (poll cannot answer for the captain)"
dir4=$(make_case captainhold); state4="$dir4/state"; cp "$fakebin/gh" "$dir4/fakebin/gh" 2>/dev/null || cp "$dir2/fakebin/gh" "$dir4/fakebin/gh"
printf 'window=%s\nkind=ship\n' "$window" > "$state4/held.meta"; printf 'captain-held [key=upstream-cut]: tracked by hold-upstream-cut\n' > "$state4/held.status"
FM_HOME="$dir4" FM_STATE_OVERRIDE="$state4" PATH="$dir4/fakebin:$PATH" "$WT/bin/fm-pr-check.sh" held https://github.com/o/r/pull/2606 >/dev/null
dir=$dir4; state=$state4; fakebin="$dir4/fakebin"; statusf="$state4/held.status"; capture="$dir4/pane.txt"; printf 'idle after the transfer' > "$capture"
age_status; seed_watch; printf '%s' "$(hash_text 'idle after the transfer')" > "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
if run_watch_cycle FM_FAKE_CREW_STATE='state: paused · source: status-log · held per captain'; then echo "watcher result: stayed alive (unexpected)"; else echo "watcher result: EXITED with the captain-hold recheck wake:"; sed 's/^/  /' "$dir/watch.out"; fi
show "ls state/.held.pause-poll-covered"; ls "$state/.held.pause-poll-covered" 2>/dev/null || echo "  (absent - no suppression offered to a captain hold)"
