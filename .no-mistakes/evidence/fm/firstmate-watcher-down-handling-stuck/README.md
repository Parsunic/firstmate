# Evidence: watcher-down supervision deadlock

What an operator sees at a Stop boundary, driving the real shipped executables
(`bin/fm-watch-arm.sh` forking a real `bin/fm-watch.sh`, `bin/fm-wake-drain.sh`,
`bin/fm-turnend-guard.sh`) over a primary-shaped fixture home with one task in
flight and one durable wake queued while no watcher was live.

| file | what it shows |
| --- | --- |
| `repro-supervision-deadlock.sh` | the reproduction driver (takes `<repo-root> <label>`) |
| `transcript-before-fix.txt` | `bin/` checked out at base `b84e0e36`: the reported defect |
| `transcript-after-fix.txt` | `bin/` as shipped at `71bef6d`: the defect gone |
| `regression-tests-on-base-bin.txt` | the three new cases + the repinned case, each failing on base `bin/` |
| `regression-tests-on-fixed-bin.txt` | the same four cases passing on shipped `bin/` |
| `run-single-cases.sh`, `run-single-cases-generic.sh` | per-case drivers (the suite's `fail()` exits the file, so the first failure would otherwise hide the rest) |

## Before the fix (transcript-before-fix.txt)

Five consecutive Stop boundaries, every one of them:

* `check: rearm-resurface`, arm exited after ~1.2s;
* `state/.watcher-down` re-stamped with a brand-new generation each time
  (`...FbkZqD` -> `...b4bvAU` -> `...8KTYiM` -> `...zxrHZY` -> `...fiIxFm`);
* `<nobody holds state/.watch.lock>`;
* turn-end guard `exit 2 - TURN BLOCKED`, "TURN WOULD END BLIND - SUPERVISION IS OFF".

Then the exact command the drain printed:

```
$ bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 2854568.1788915447.3GNR9G
wake drain: acknowledged wakes through 1 (1 row(s) consumed), but a newer recovery
episode is pending; re-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command
state/.watcher-down : announced:downtime:2855334.1788915449.lHBTWl
VERDICT             : episode NOT retired - the printed acknowledgement was orphaned
```

That is the reported symptom: the acknowledgement is accepted, the episode is not
retired, and the next arm has already minted the generation that orphans it.

## After the fix (transcript-after-fix.txt)

One generation, `2856470.1788915461.OIJbZT`, across all five boundaries and the
acknowledgement. Boundaries 2 and 4 reach the poll loop and hold the home lock
(`pid ... LIVE watcher supervising`), and the turn-end guard exits 0 there, so a
turn can end. The announcing boundaries in between are the bounded one-cycle-per-
down-stretch recovery, not a loop: they never re-stamp the generation. The exact
printed command then retires the episode: `acked:downtime:2856470.1788915461.OIJbZT`.
