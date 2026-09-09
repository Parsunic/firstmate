#!/usr/bin/env bash
# Operator-level reproduction of the reported watcher-down supervision deadlock.
#
# Drives the real shipped executables - bin/fm-watch-arm.sh (which forks a real
# bin/fm-watch.sh), bin/fm-wake-drain.sh and bin/fm-turnend-guard.sh - over a
# primary-shaped fixture home, and prints what an operator sees at each Stop
# boundary: the watcher's reason line, state/.watcher-down, who holds
# state/.watch.lock, and whether the turn-end guard blocks the turn.
#
# usage: repro-supervision-deadlock.sh <repo-root> <label>
set -u
ROOT=$1
LABEL=$2

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deadlock-repro.XXXXXX")
HOME_DIR="$WORK/home"
STATE="$HOME_DIR/state"
FAKEBIN="$WORK/fakebin"
mkdir -p "$STATE" "$HOME_DIR/data" "$FAKEBIN"
cp -R "$ROOT/bin" "$HOME_DIR/bin"
cp -R "$ROOT/docs" "$HOME_DIR/docs"
: > "$HOME_DIR/AGENTS.md"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.email=fm@example.invalid -c user.name=fm commit -q --allow-empty -m init

# Hermetic stand-ins so no real terminal multiplexer or crew state is touched.
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
printf '#!/usr/bin/env bash\nprintf "state: unknown \xc2\xb7 source: none \xc2\xb7 fixture\\n"\nexit 0\n' > "$FAKEBIN/fm-crew-state.sh"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fm-crew-state.sh"
# Keep the drain's worktree-tangle banner inert without touching FM_ROOT for the
# guard, which resolves its own primary scope from FM_ROOT.
TANGLE_ROOT="$WORK/tangle-root"
mkdir -p "$TANGLE_ROOT"

banner() { printf '\n=== %s ===\n' "$*"; }
show_marker() { printf '  state/.watcher-down   : %s\n' "$(cat "$STATE/.watcher-down" 2>/dev/null || echo '<absent>')"; }
show_lock() {
  local pid
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '  home lock holder      : pid %s (LIVE watcher supervising)\n' "$pid"
  elif [ -n "$pid" ]; then
    printf '  home lock holder      : pid %s (DEAD - stale lock evidence)\n' "$pid"
  else
    printf '  home lock holder      : <nobody holds state/.watch.lock>\n'
  fi
}
run_guard() {  # what an operator's Stop boundary does
  local out status
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$HOME_DIR" \
    bash "$HOME_DIR/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '  turn-end guard        : exit 0 - turn allowed\n'
  else
    printf '  turn-end guard        : exit %s - TURN BLOCKED\n' "$status"
    printf '%s\n' "$out" | sed -n '1,3p' | sed 's/^/      | /'
  fi
}

ARM_PID=
arm() {  # <n> ; one Stop-boundary re-arm, exactly as the harness performs it
  local n=$1 out="$WORK/arm-$n.out" i=0
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$HOME_DIR/bin/fm-watch-arm.sh" --restart > "$out" 2>"$WORK/arm-$n.err" &
  ARM_PID=$!
  while [ "$i" -lt 100 ]; do
    grep -F 'check: rearm-resurface' "$out" >/dev/null 2>&1 && break
    kill -0 "$ARM_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  banner "$LABEL: Stop boundary $n - re-arm the watcher"
  if grep -F 'check: rearm-resurface' "$out" >/dev/null 2>&1; then
    printf '  watcher reason line   : %s\n' "$(grep -F 'check: rearm-resurface' "$out" | head -1)"
  else
    printf '  watcher reason line   : <none - the cycle is supervising>\n'
  fi
  if kill -0 "$ARM_PID" 2>/dev/null; then
    printf '  arm after %5.1fs      : still running (watcher reached its poll loop)\n' "$(echo "$i" | awk '{print $1/10}')"
  else
    printf '  arm after %5.1fs      : exited (resurfaced and gave up the cycle)\n' "$(echo "$i" | awk '{print $1/10}')"
  fi
  show_marker
  show_lock
  run_guard
}

printf '########## %s ##########\n' "$LABEL"
printf 'fixture home: %s\n' "$HOME_DIR"
if (cd "$ROOT" && git diff --quiet HEAD -- bin/); then
  printf 'bin/ under test: as shipped at %s\n' "$(cd "$ROOT" && git rev-parse --short HEAD)"
else
  printf 'bin/ under test: %s with bin/ checked out from an earlier commit (%s)\n' \
    "$(cd "$ROOT" && git rev-parse --short HEAD)" \
    "$(cd "$ROOT" && git diff --stat HEAD -- bin/ | tail -1 | sed 's/^ *//')"
fi

# A task is in flight, so this home genuinely needs supervision, and a durable
# wake arrived while no watcher was live - the down stretch the one-shot
# recovery announcement exists for.
: > "$STATE/task1.meta"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_append check startup-network "check: startup-network"' \
  _ "$HOME_DIR/bin/fm-wake-lib.sh"

banner "$LABEL: before any re-arm"
show_marker
show_lock
run_guard

for n in 1 2 3 4; do
  arm "$n"
done

# --- the acknowledgement the drain itself prints -----------------------------
banner "$LABEL: the operator handles the wake and drains it"
FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  "$HOME_DIR/bin/fm-wake-drain.sh" > "$WORK/drain.out" 2> "$WORK/drain.err" || true
ACK_LINE=$(grep '^WAKE_ACK_REQUIRED:' "$WORK/drain.err" | tail -1)
printf '  drain printed         : %s\n' "$ACK_LINE"
SEQ=$(printf '%s' "$ACK_LINE" | sed -n 's/.*--ack-through \([0-9][0-9]*\) .*/\1/p')
GEN=$(printf '%s' "$ACK_LINE" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
show_marker

banner "$LABEL: the next Stop boundary arms while the handling turn is still running"
arm 5

banner "$LABEL: the operator runs the EXACT command the drain printed"
printf '  $ bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' "$SEQ" "$GEN"
if FM_ROOT_OVERRIDE="$TANGLE_ROOT" FM_STATE_OVERRIDE="$STATE" "$HOME_DIR/bin/fm-wake-drain.sh" --ack-through "$SEQ" \
  --recovery-generation "$GEN" > "$WORK/ack.out" 2> "$WORK/ack.err"; then
  printf '  acknowledgement       : accepted (exit 0)\n'
else
  printf '  acknowledgement       : rejected (exit %s)\n' "$?"
fi
sed -n '1,4p' "$WORK/ack.err" | sed 's/^/      | /'
show_marker
case "$(cat "$STATE/.watcher-down" 2>/dev/null || true)" in
  acked:*) printf '  VERDICT               : episode RETIRED - the printed acknowledgement worked\n' ;;
  *)       printf '  VERDICT               : episode NOT retired - the printed acknowledgement was orphaned\n' ;;
esac

kill "$ARM_PID" 2>/dev/null || true
wait "$ARM_PID" 2>/dev/null || true
pkill -f "$STATE" >/dev/null 2>&1 || true
sleep 0.3
rm -rf "$WORK"
