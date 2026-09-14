# Test evidence: an announced/acked recovery episode can no longer trap supervision

Branch `fm/firstmate-watcher-down-handling-stuck`, base `b182d0f`, target `93bd328`.
Everything below was driven through the executable interface (real `bin/fm-watch-arm.sh`,
real `bin/fm-watch.sh`, real `bin/fm-wake-drain.sh`) against fresh homes. "base bin/" means the
worktree with `bin/` checked out from `b182d0f` and the tests from `93bd328`; "fixed" is `93bd328`.

## 1. Operator-level reproduction: same 7 steps, before vs after

`repro-stuck-episode.sh` uses plain arm mode (what `bin/fm-claude-stop-autoarm.sh` runs), the real
drain, and the EXACT `--ack-through N --recovery-generation G` command the drain printed.
Full transcripts: `repro-stuck-episode.base-bin.log`, `repro-stuck-episode.fixed.log`.

| step | base bin/ (the reported loop) | fixed |
|---|---|---|
| durable wake arrives, no watcher live | marker `pending:downtime:G1`, no lock holder | same |
| arm #1 | announces `check: rearm-resurface`, exits (intended one-shot recovery) | same |
| handling drain | prints ack for `G1`; marker `announced:handling:G1` | same |
| arm #2 inside the handling window | re-announces, **exits within seconds**, marker re-stamped `announced:downtime:G2` | **stays live, holds the home lock**, marker still `announced:handling:G1` |
| run the exact printed ack (`G1`) | rows consumed, but "a newer recovery episode is pending"; episode **never retired** | **rc=0, marker `acked:handling:G1`**, queue empty |
| arm #3 (queue now EMPTY) | re-announces with `G3`, exits | `watcher: attached pid=<live watcher>` |
| arm #4 | re-announces with `G4`, exits | attaches to the same live watcher |
| a crew status changes | **never delivered: no live watcher** | delivered: `signal: .../later.status` |

The base transcript shows the loop continuing with an empty queue and without any timeout being
involved, and no watcher ever holding the lock, which is exactly what left the turn-end guard
blocking every turn.

## 2. Regression tests fail before the fix and pass after it

Run one case at a time with a transient single-case runner (see "Regenerating" below).

| `tests/fm-watch-arm.test.sh` case | base bin/ | fixed |
|---|---|---|
| `test_repeated_rearm_cannot_starve_the_watcher_lock` | `not ok - the announced episode was re-announced instead of being left for the handling turn` | ok |
| `test_arm_inside_handling_keeps_the_episode_retirable` | `not ok - an arm inside the handling window re-stamped the outstanding recovery generation: announced:downtime:1926725...` | ok |
| `test_midloop_recovery_discovery_announces_the_generation_once` | `not ok - generation 1927530... was announced a second time after the mid-loop announcement` | ok |

Logs: `test_*.base-bin.log` (one per case) and `fm-watch-arm.fixed.log` (whole suite, 18/18 ok).

## 3. The first-CI-run failure in `tests/fm-pr-check-security.test.sh`

| `test_rejected_metacharacter_bytes_are_inert` version | base bin/ | fixed |
|---|---|---|
| original case (as of `b182d0f`) | not run here (green in CI history at base) | `not ok - bounded watcher did not complete through the authenticated poll` (`pr-check-original-case.fixed-bin.log`) |
| corrected case (as of `93bd328`) | ok (`pr-check-corrected-case.base-bin.log`) | ok (`pr-check-corrected-case.fixed.log`) |

The original case only passed at base because cycles 2-4 exited on the re-announcement this PR
removes; with the fix a cycle supervises and the original fixture times out. The corrected case
passes on both trees and cannot pass vacuously (each cycle must wake on its own merged poll line).

## 4. Related suites on the fixed tree

- `tests/fm-watch-recovery-loop.test.sh` (Pi/OpenCode once-per-generation bound): 2/2 ok, `fm-watch-recovery-loop.fixed.log`
- `tests/fm-watcher-lock.test.sh` (lock lifecycle incl. release-lock publication): 31 ok, 0 not ok, exit 0, `fm-watcher-lock.fixed.log`

## Regenerating the single-case runner

The suites have no per-case filter, so a filtered copy was created inside `tests/` for the run and
deleted afterwards (it must live in `tests/` so the helper sourcing resolves):

    sed '/^test_[a-z_0-9]*$/d' tests/fm-watch-arm.test.sh > tests/.nm-single-fm-watch-arm.sh
    printf '\n"$FM_TEST_ONLY"\n' >> tests/.nm-single-fm-watch-arm.sh
    FM_TEST_ONLY=test_repeated_rearm_cannot_starve_the_watcher_lock bash tests/.nm-single-fm-watch-arm.sh

`repro-stuck-episode.sh` sources that runner for its helpers: `WT=<worktree> bash repro-stuck-episode.sh <label>`.
