# Native macOS metrics reader benchmark

This entrypoint needs real Hammerspoon, not the unit-test `hs` fake. It opens
the production schema through `sqlite_writer`, seeds 224 synthetic aggregate
rows and measures eleven production `read_manifest` calls with the native
monotonic clock. Every call must return 224 date/application rows and report no
production query error. The first sample is **not** an OS-cold-cache claim.

This deliberately does not measure ingestion, range projections, UI startup,
WebView rendering, or open-to-painted latency. Infrastructure logger/path/cipher
boundaries are isolated; SQLite and the writer/reader implementations are real.
No event taps, driver configuration installer, hardware identity, or personal
metrics database is loaded. The synthetic database is retained for inspection.

## Launch on a disposable GitHub macOS runner

The checked supervisor copies the supplied application into its own temporary
directory, creates the isolated configuration, validates the native receipt,
and shuts down only processes with that exact copied executable path:

```bash
python3 tools/bench/macos-metrics/test_run.py
python3 tools/bench/macos-metrics/run.py --app /absolute/Hammerspoon.app --output /absolute/fresh/results
```

The output directory must not exist. `supervisor.json` records terminal status
and cleanup, `result.json` holds native measurements, and `launch.log` captures
startup diagnostics. The workflow uploads these synthetic artifacts even on
failure. The following details describe the supervised launch protocol.

Use an isolated copy of Hammerspoon (the existing macOS build currently pins
1.1.1). Make a fresh directory under `RUNNER_TEMP`, copy this `init.lua` into it,
and create `bench-config.json` beside it with absolute JSON-escaped paths:

```json
{"repo_root":"/absolute/checkout","output_dir":"/absolute/fresh/output"}
```

Create the output directory first. It must not contain `synthetic.sqlite`.
Launch via Launch Services, preserving its owner just like the repository's
native application smoke test:

```bash
open -n -g -W "$BENCH_HS_APP" --args -MJConfigFile "$BENCH_DIR/init.lua" &
BENCH_OPEN_PID=$!
```

The job must impose a 60-second deadline, wait for a parseable `result.json`,
require `status == "ok"`, and upload the result. Missing native APIs, bootstrap
failure, missing result or `status == "error"` are failures, never skipped
measurements. Keep the exact launched application PID (resolve its unique
bundle executable path); terminate and wait for that owner and the `open -W`
process in a trap. Do not use broad `pkill`, modify TCC databases, or launch the
full Ergopti driver. This benchmark does not require keyboard/Accessibility or
screen-capture permission, but GUI session availability must still be checked by
the job. No native execution has been performed from the Windows workspace.
