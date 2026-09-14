# Test evidence: watcher-down recovery episode no longer starves the home lock

Base b182d0f (before) vs target 99f67cc (after). Both commits were extracted with
`git archive` into /tmp so the NEW regression tests could be run against the OLD bin/.
The real worktree run of the targeted suite is `fm-watch-arm-target.log`.

## End-user transcripts (the reported symptom, through the executable interface)

* `transcript-base-b182d0f.txt` - BEFORE: every `bin/fm-watch-arm.sh --restart` exits within
  ~3s on `check: rearm-resurface`, `state/.watcher-down` is re-stamped with a fresh generation
  on every arm, the EXACT acknowledgement the drain printed is accepted but answers
  "a newer recovery episode is pending", no watcher ever holds the lock, and the loop
  continues with an EMPTY queue (rows=0 at steps 5-6).
* `transcript-target-99f67cc.txt` - AFTER: the arm inside the handling window supervises and
  holds the lock (pid ALIVE), the marker keeps its generation, the printed acknowledgement
  retires the episode to `acked:handling:<same generation>`, and later arms alternate one
  announcement per down stretch followed by a supervising watcher.

## Regression tests: fail before, pass after

`before-after-summary.tsv` plus one log per run (`base-bin__*.log`, `target-bin__*.log`).

| case (tests/fm-watch-arm.test.sh)                                | base bin/ | target bin/ |
|------------------------------------------------------------------|-----------|-------------|
| test_repeated_rearm_cannot_starve_the_watcher_lock               | not ok: "the announced episode was re-announced instead of being left for the handling turn" | ok |
| test_arm_inside_handling_keeps_the_episode_retirable             | not ok: "an arm inside the handling window re-stamped the outstanding recovery generation: announced:downtime:..." | ok |
| test_midloop_recovery_discovery_announces_the_generation_once    | not ok: "generation ... was announced a second time after the mid-loop announcement" | ok |

`fm-watch-arm-target.log` - the whole targeted suite (18 cases) on the real worktree: all ok.

## CI failure the change caused on its first run, and the test-fixture fix

| tests/fm-pr-check-security.test.sh test_rejected_metacharacter_bytes_are_inert | base bin/ | target bin/ |
|---|---|---|
| ORIGINAL case (base test file)    | ok (per the intent: cycles 2-4 exited on the very defect) | not ok: "bounded watcher did not complete through the authenticated poll" (`target-bin__ORIGINAL-case__*.log`, 24s) |
| CORRECTED case (target test file) | ok (`base-bin__CORRECTED-case__*.log`) | ok at load <= ~9 (`diag-ab-cycle-timing.log`, `diag-target-sampled.log`) |

## Load-marginality of the pre-existing bounded fixture (not caused by the change)

`run_watcher_bounded` in tests/fm-pr-check-security.test.sh wraps each watcher cycle in a
10s alarm. Measured per-cycle time on BOTH trees is 5-8s at load 6-10
(`diag-ab-cycle-timing.log`, `diag-merge-derivation-ab.log`); a traced cycle at load ~5 spans
3.3s with no single step over 0.6s (`diag-cycle-trace-summary.log`), i.e. spawn overhead that
scales with host load. At load 12-15 the same corrected case timed out at cycle 1 on the target
copy (`target-bin__test_rejected_metacharacter_bytes_are_inert.log`,
`target-bin__CORRECTED-case-isolated-instrumented__*.log`, `diag-target-trace.log`), and the
full file on the real worktree failed once at a different bounded case
(test_valid_recording_and_merge_derivation, `fm-pr-check-security-target.log`), which then
passed 4/4 alternating base/target runs (`diag-merge-derivation-ab.log`). The corrected case now
runs four full authenticated-poll cycles instead of one, so it spends ~20-30s inside that bound.

Host note: the file's default restricted PATH (/usr/bin:/bin:/usr/sbin:/sbin) does not contain
jq on this host; the full-file runs export the fixture's own FM_TEST_BASE_PATH knob to expose it.

## Full pr-check file on the real worktree

* `fm-pr-check-security-target.log` - first attempt: 21 ok, then the bounded cycle of
  test_valid_recording_and_merge_derivation (untouched by this change) hit the 10s alarm at load ~9.
* `fm-pr-check-security-target-run2.log` - second attempt at load 2-4: 33/33 ok, exit 0.
