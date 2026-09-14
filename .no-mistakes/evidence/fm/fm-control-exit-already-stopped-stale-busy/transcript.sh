#!/usr/bin/env bash
# Reproduction transcript: a claude crewmate that crashed without a Stop or
# SessionEnd hook leaves state/<id>.busy-state behind while the pane is back at
# a shell. Shows what fm-crew-state reports and what `fm-control <id> exit`
# leaves behind. Uses the hermetic stubbed session provider from
# tests/fm-control.test.sh (no real tmux, no real agent).
set -u
WT=${WT:?worktree path}
LABEL=${1:-run}
. "$WT/tests/lib.sh"
eval "$(sed -n '29,211p' "$WT/tests/fm-control.test.sh")"

blob=$(git -C "$WT" hash-object bin/fm-control.sh)
base_blob=$(git -C "$WT" rev-parse b182d0f908b78d08c7ccb8dce3775bdca8c5d657:bin/fm-control.sh)
fix_blob=$(git -C "$WT" rev-parse a56e8b6617a2abf8b56311065c01b0c517351c5e:bin/fm-control.sh)
which_bin=other
[ "$blob" = "$base_blob" ] && which_bin="base b182d0f (before fix)"
[ "$blob" = "$fix_blob" ] && which_bin="target a56e8b6 (after fix)"
printf '=== [%s] bin/fm-control.sh under test: %s ===\n' "$LABEL" "$which_bin"

dir=$(new_case dead-busy)
add_task "$dir" t1 claude
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1 --source claude-hook --event UserPromptSubmit)
printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
alive_as "$dir" zsh   # the agent process is gone; the pane's foreground command is the shell

S="$dir/home/state"
crew() { env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" "$ROOT/bin/fm-crew-state.sh" t1 2>&1; }

echo
echo "--- BEFORE exit: hook-written busy wiring left by the crashed agent ---"
echo "\$ cat state/t1.busy-state"; cat "$S/t1.busy-state"
echo "\$ cat state/t1.busy-gen"; cat "$S/t1.busy-gen"; echo
echo "\$ tmux display-message pane_current_command  ->  $(cat "$dir/fake/command")"
echo "\$ fm-crew-state.sh t1"; crew

echo
echo "--- fm-control.sh t1 exit ---"
echo "\$ fm-control.sh t1 exit"
out=$(run_control "$dir" t1 exit); rc=$?
printf '%s\n(exit code %s)\n' "$out" "$rc"

echo
echo "--- AFTER exit ---"
echo "\$ ls state/ | grep busy"; ls "$S" | grep busy || echo "(no busy-state / busy-gen files remain)"
echo "\$ fm-crew-state.sh t1"; crew
echo "\$ bytes typed into the pane (fake/literal):"; if [ -s "$dir/fake/literal" ]; then cat "$dir/fake/literal"; else echo "(none - nothing was sent to the dead pane)"; fi
