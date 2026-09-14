# Test-phase evidence: watcher-down recovery episode no longer re-stamped on every arm

Branch fm/firstmate-watcher-down-handling-stuck, base b182d0f -> target 174708d.

- `transcript-before-fix-base-bin.txt` - real `bin/fm-watch-arm.sh --restart` and `bin/fm-wake-drain.sh` driven against the BASE commit's `bin/` (target `tests/` helpers): every arm prints `check: rearm-resurface` under a fresh generation and exits, no watcher ever holds the home lock, the exact printed acknowledgement is answered with "a newer recovery episode is pending", and the plain Stop-style arm resurfaces again on an empty queue.
- `transcript-after-fix-target.txt` - the same driver on the target commit: arm 2 and arm 4 supervise and hold the lock, the generation stays stable across a supervising close (reopened to pending under its OWN generation), the arm inside the handling window leaves the generation intact, the exact printed acknowledgement retires the episode to `acked:handling:<G>`, and the plain arm attaches to the live watcher.
- `regression-tests-on-base-bin.log` - the three new tests in tests/fm-watch-arm.test.sh run alone against base `bin/`; each fails at its own named assertion.
- `fm-watch-arm.test.log` - the full tests/fm-watch-arm.test.sh on the target commit (18 ok, exit 0).
- `ci-fixture-case-matrix.log` and `original-ci-case-on-fixed-bin.log` - test_rejected_metacharacter_bytes_are_inert: the pre-change case passes on base and fails on the fix ("bounded watcher did not complete through the authenticated poll"); the corrected case passes on both trees.
- `fm-pr-check-security.test.log` - full tests/fm-pr-check-security.test.sh on the target commit with `FM_TEST_BASE_PATH` extended by a jq-only directory (the file's restricted PATH otherwise lacks jq on this host).
- `related-suites.log` - tests/fm-watch-recovery-loop.test.sh (exit 0) and tests/fm-watcher-lock.test.sh on the target commit.
