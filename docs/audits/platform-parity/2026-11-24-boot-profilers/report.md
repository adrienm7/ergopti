# Boot profilers, phase stats and perf counters

Audited source: `b3bf4d2d` (`dev`). Date: November 24, 2026. A campaign the
[logger engines](../2026-11-20-logger-engines/report.md) campaign left open:
it read the boot profilers, the perf counters and the keystroke integrity
ring only where they reach a sink. The nine campaigns the
[2026-11-19 census](../2026-11-19-census/report.md) proposed are all taken;
this one follows them.

## Scope

- the boot profilers: Windows `core/logger/engine/boot_profiler.ahk` with the
  boot tail of `ErgoptiPlus.ahk`, macOS and Linux
  `core/logger/engine/boot_profiler.lua`, against `[budgets] boot_total_ms`
  (`_shared/core/timing/data/constants.toml`), the shared perf budget judge
  (`_shared/core/logger/engine/perf_budget.lua`, `perf_budget.ahk`), the
  diagnostic snapshot's `boot_ms` and the field log analyser
  (`tools/dev/field-log-analyse.py`, `boot.total`, `boot.cpu`, `boot.stage`);
- the phase summaries: macOS and Linux `infra/phase_stats.lua` over the shared
  `_shared/metrics/engine/perf/phase_stats_core.lua`, Windows
  `infra/phase_stats.ahk`;
- the hot-path counters: Linux `core/logger/engine/perf_counters.lua`, macOS
  and Windows `infra/hotpath_profiler`, against the shared segment inventory
  `_shared/metrics/engine/perf/hotpath_segments.lua`;
- macOS `core/logger/engine/keystroke_integrity.lua`.

Read for each: what a boot total covers, how a stage opens, closes or stays
open, the summary lines, the budget judgement, the CPU figures, duplicate
initialization and the line shapes the analyser reads. Source reading, the
macOS and Linux Lua suites in a Linux container, the field log analyser and
field report gates; the AutoHotkey suites did not run (no Windows host), so
the Windows change is held by the analyser vector and the parse gates.

Checked and kept:

- **Phase summaries.** macOS and Linux run the same shared core, with the same
  phase names (`process.<program>`, `boot.stage`, `boot.stage_cpu`) and the
  same « Phase summary [family] over N s » line; Windows mirrors its ring floor
  and flush interval in `PhaseStatsStore` and writes the same line through
  `LoggerEvidence`. Linux has no timer of its own (the event loop's periodic
  tick flushes), macOS pairs its timer's start and stop; both are their
  runtime's cadence owner.
- **Hot-path counters.** The segment inventory, the 5 ms
  `[logger] hotpath_slow_ms` threshold, the nesting attribution and the
  `HotPath` warning tag are one source for the two Lua drivers, and the
  Windows `HotPathNesting` replays the same vectors
  (`hotpath_nesting_vectors.json`); each driver emits only the segments its
  input path has, declared with their reason.
- **Keystroke integrity.** macOS only, by its reason: it reports a key-down
  the event tap consumed and never delivered, to tell a loss inside the
  driver from one upstream of every tap (a Karabiner rules reload, a tap
  outage). Windows and Linux own their input below that layer (the low-level
  hook, evdev and uinput), where no upstream remapper sits between the key
  and the driver.
- **Stage shapes.** Windows and Linux key open stages by name and may nest
  them; macOS holds one open stage and warns when another opens over it. The
  three log a START per stage and a SUCCESS with its wall and CPU time, which
  the analyser reads under both spellings.

## Fixed

| Id     | OS      | Sequence                                                   | Reference                                                                                                         | Before                                                                                                                                                                                                                                                                      | Regression                                                                                                                                                                                                            |
| ------ | ------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BPF-01 | Linux   | Start the daemon, with a slow module load before `begin()` | Windows counts from the process creation (`BootProfile_TotalBootMs`); the budget reads « process or VM start »    | The profiler read the process age at `begin()` and logged it as the load phase, but the « Boot complete » total, the `boot_total_ms` judgement, the snapshot's `boot_ms` and the field-run total all started at `begin()`: a slow load was never judged nor counted as boot | `boot profiler: the total is spawn to ready (bpf-01)` (`test_boot_profiler_summary.lua`, a 3 s load is judged over budget) and `snapshot-prepared-ready` (`test_diagnostic_snapshot.lua`, `boot_ms` carries the load) |
| BPF-02 | macOS   | A boot whose last stage opens and is never marked          | Windows (`BootProfile_OpenStageNames`) and Linux warn « Boot completed with unclosed stage(s) »                   | `complete()` said « Boot complete » and nothing of the open stage                                                                                                                                                                                                           | `names a stage still open when the boot completes (bpf-02)` (`test_boot_profiler.lua`), the warning also in the boot journal                                                                                          |
| BPF-03 | macOS   | Compare two boots from their logs                          | Windows « Boot summary: total_ms=… stage_ms: … », Linux « Boot summary: total=… (cpu …) heap=… load=… stages: … » | No single line held the stages: the field run read the three slowest, a person read one line per stage                                                                                                                                                                      | `writes one boot summary with every closed stage (bpf-03)` (`test_boot_profiler.lua`)                                                                                                                                 |
| BPF-04 | macOS   | Call `begin()` again during a boot, or `complete()` twice  | Linux raises « boot has a single owner » and « boot completes once »; AGENTS.md rejects duplicate initialization  | A second `begin()` restarted the clock and dropped every closed stage; a second `complete()` judged and logged the boot again                                                                                                                                               | `boot_profiler ownership (bpf-04)` (`test_boot_profiler.lua`), the suite's cases now reset through `_reset_for_test()`                                                                                                |
| BPF-05 | Windows | Read a Windows field log for the boot's CPU                | macOS « Boot CPU: N ms of process CPU over M ms of boot. », Linux « (cpu N ms) » on its total                     | Windows wrote the CPU of each stage but no boot total, so the analyser's `boot.cpu` metric had no Windows sample                                                                                                                                                            | the `Boot CPU` Windows vector of `tools/test/fixtures/field-log-analyse/vectors.json`, which `test-field-log-analyse.cjs` checks against the source                                                                   |

Notes:

- **BPF-01.** `complete()` now logs, judges and returns the load phase plus
  the stages, « Boot complete in N ms (cpu C ms) since the process started. »,
  the CPU being the process's own since its start. When `/proc` does not give
  the age, `begin()` already warns and `complete()` says « since boot timing;
  the load phase is not measured. » with the measured part only. Both lines
  keep the analyser's `boot.total` and `boot.cpu` shapes (two vectors). The
  budget comment of `constants.toml` names where each driver counts from:
  macOS from its Lua VM's first lines, since Hammerspoon outlives a reload and
  its process age would count every earlier reload.
- **BPF-03.** The line takes the Linux shape without `load=` (see BPF-01 for
  why macOS has no load phase); stage names are code literals.
- **BPF-05.** `BootClockCpuMs()` is the process's kernel and user time since
  its creation, the interval of the Windows total; a refused
  `GetProcessTimes` is a warning, not a zero.

## Open

- **BPF-04 (low, Windows), fixed on 2026-11-25:** a second
  `BootProfile_Begin()` restarted the profiler silently. It now throws
  « boot has a single owner », as on macOS and Linux; a mark before it still
  anchors the origin there (macOS keeps the same anchoring, pinned by its
  suite). A second recorded completion (`BootProfile_CompletedBootMs`) now
  throws « boot completes once » too, as `complete()` does on macOS and
  Linux, instead of replacing the logged total. No suite called
  `BootProfile_Begin`, so the only seam needed is
  `_BootProfileResetForTest()`, used by
  `tests/unit/core/logger/test_boot_profiler_single_owner.ahk`, which fails on
  the old code (no throw) and runs in CI's Windows lane.

Native receiving: a Linux field log whose « Boot complete » line reads
« since the process started » with the load phase of the « Process age at
boot timing » line included; a macOS boot log carrying one « Boot summary »
line; a Windows boot log carrying « Boot CPU ».

## Proof

- **Red on the old code.** With the old macOS `boot_profiler.lua`, the bpf-02
  and bpf-03 cases fail (14 of 16 pass); with the old Linux one, the two bpf-01
  cases and `snapshot-prepared-ready` fail (the profiler has no age seam and
  its total leaves the load out); with the old `ErgoptiPlus.ahk`,
  `test-field-log-analyse.cjs` fails on « no longer writes: Boot CPU: … ».
- **Green on the new code.** `lua tests/run.lua` (macOS) and
  `node tools/test/run-linux-lua.cjs tests/run.lua` (Linux) in full: 29,179 and 24,357 cases
  pass; the 19 and 41 that fail are this container's (a root user who reads
  every denied file, no `USER`, no X display, a non-normalised shared path) and
  none reads a boot profiler;
  `test-field-log-analyse.cjs`, `test-linux-field-report-contract.cjs`,
  `test-windows-field-report-contract.cjs`, `test-diagnostic-snapshot-parity.cjs`,
  `test-logger-lifecycle-pairing.cjs`, `test-timings-registry-liveness.cjs`,
  `test-shared-literal-inventory.cjs`, `test-no-pinned-source-reads-lua.cjs`
  and `-linux.cjs`, `test-ahk-encoding.cjs`,
  `test-ahk-v2-syntax-antipatterns.cjs`, the formatter and
  `lint-conventions.js --fail-on-violations`.
- **Not run here.** The AutoHotkey unit and e2e suites (CI's Windows lane);
  `test_logging.ahk` and `test_reload_timing.ahk` pin the order of the boot
  tail around the new lines, which keeps it.
