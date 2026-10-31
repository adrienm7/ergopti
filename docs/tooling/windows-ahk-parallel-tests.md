# Parallel Windows AHK test runs

`npm run test:ahk-parallel` runs `static/ergopti_plus/windows/tests/run_all.ahk`
in several processes on one checkout. It is the way to run the whole suite
locally: a single process takes over an hour. Windows only, because the suite
drives native AutoHotkey and Win32; macOS and Linux run their own Lua suites.

```powershell
npm run test:ahk-parallel                                  # run, or resume
npm run test:ahk-parallel -- --workers=6                   # default: half the logical CPUs
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
  chunk is sized by what its tests took last time (`durations.json`, five
  minutes by default) rather than by a count.
- **A process that dies or hangs** past its 30-minute cap marks the test it died
  in as failed; the rest of its chunk goes back to the queue.
- **Failures.** Parallel neighbours can disturb tests that use the keyboard, the
  clipboard or a shared native resource. Read a failure as real only once
  `--rerun-failures` reproduces it alone.

Two mechanisms make the parallelism sound. Workers run under `/force`, the
interpreter's switch for `#SingleInstance Off`, so they do not replace one
another and no copy of the runner is needed. Each worker has its own `TEMP`,
because several tests use fixed names there.

Tests that reach the real `%APPDATA%` still do, and an `APPDATA` override does
not move them, so metrics written by a test can land in the live data of a
resident driver on the same account.
