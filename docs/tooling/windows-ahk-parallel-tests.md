# Parallel Windows AHK test runs

`npm run test:ahk-parallel` runs `static/ergopti_plus/windows/tests/run_all.ahk`
in several processes on one checkout. It is the way to run the whole suite
locally: a single process takes over an hour. Windows only, because the suite
drives native AutoHotkey and Win32; macOS and Linux run their own Lua suites.

```powershell
npm run test:ahk-parallel                                  # run, or resume
npm run test:ahk-parallel -- --workers=6                   # default: half the CPUs, fewer on low memory
npm run test:ahk-parallel -- --only="config transition"    # a subset of the plan
npm run test:ahk-parallel -- --fresh                       # forget the ledger first
npm run test:ahk-parallel -- --rerun-failures              # each failure alone, one at a time
npm run test:ahk-parallel -- --report=40                   # slowest tests and files, runs nothing
```

Everything lives in the ignored `.ahk-parallel/` folder (`--run-dir` moves it).

- **Ledger.** `ledger.json` holds each test's status, detail and duration, and is
  rewritten after each process, so a killed run resumes where it stopped. It is
  tied to the commit: on another HEAD the runner refuses it unless you pass
  `--fresh` or, knowingly, `--accept-stale`.
- **Chunks.** Each process parses the whole suite before its first test, so a
  chunk is sized by what its tests took last time (`durations.json`) rather than
  by a count: five minutes while much work remains, then half of a worker's
  share down to one minute, so the workers finish together.
- **A process that dies or hangs** past its 30-minute cap marks the test it died
  in as failed; the rest of its chunk goes back to the queue.
- **Failures.** Parallel neighbours can disturb tests that use the keyboard, the
  clipboard or a shared native resource. Read a failure as real only once
  `--rerun-failures` reproduces it alone. That run answers for those failures
  only, in its exit status and its summary, and needs `--accept-stale` once HEAD
  has moved.

Two mechanisms make the parallelism sound. Workers run under `/force`, the
interpreter's switch for `#SingleInstance Off`, so they do not replace one
another and no copy of the runner is needed. Each worker has its own `TEMP`,
because several tests use fixed names there.

A test that runs a real configuration transaction spends nearly all its time in
one place: every guarded journal callback compares the live migration registry
with its private copy four times, about 20 ms each, and a one-file commit plus
rollback makes about 1,300 of those comparisons. Fewer transactions per test is
what makes such a test faster; the comparison visits every node on purpose.

Tests that reach the real `%APPDATA%` still do, and an `APPDATA` override does
not move them, so metrics written by a test can land in the live data of a
resident driver on the same account.
