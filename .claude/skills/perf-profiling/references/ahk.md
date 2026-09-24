# AutoHotkey performance audit

## Measurement sources

Resolve `LogsDirPath` in `%APPDATA%\Ergopti\paths.toml`; empty means
`%LOCALAPPDATA%\ergopti_plus\logs\`. Logs written before 2026-09 are under the
old `<ConfigDir>\autohotkey\logs\`. Derive the folder; do not treat an example
as configuration.

`static/ergopti_plus/windows/infra/hotpath_profiler.ahk` uses QPC and emits
`[HotPath] Slow <segment>: <ms> ms`. The default warning threshold is 5 ms, but
`_HOTPATH_SLOW_MS_BY_SEGMENT` contains measured per-segment overrides. Read that
map before interpreting missing lines or comparing counts. The log population
is censored at each segment's threshold, so it cannot provide an all-keystroke
median or p99 without a denominator.

Nested lines can describe the same stall. Current lines may include
`[excl X ms, nested Y ms]`; use that attribution and never sum a parent with its
contained segments. Exclude the errors-only mirror when aggregating the main
log, or warnings are counted twice.

`static/ergopti_plus/windows/infra/boot_profiler.ahk` measures startup with
`A_TickCount`, whose coarse resolution makes zero mean "below one tick", not
zero work. For uncovered code, use a standalone harness around production code
with `QueryPerformanceCounter`, warm-up, a real input, and enough repetitions to
report median and tail values.

## Priorities

1. Keystroke and low-level hook paths. A stall around Windows'
   `LowLevelHooksTimeout` can lose input or disable a hook.
2. `Critical` spans. Too narrow reopens races; too broad converts I/O, rebuild,
   COM, or network work into keyboard starvation.
3. Tooltip build, native positioning, and presentation.
4. Startup until input is usable.
5. Idle timers, retained state, and session-long growth.

Look for synchronous shell/network/file/registry/COM work, scans or string
rebuilds per character, unbounded state, repeated config resolution, and work
whose result did not change. Treat a proposed cache as high risk until every
mutation path proves invalidation.

## Deliverable

Write `docs/audits/performance/ahk/<YYYY_MM_DD>/report.md` without overwriting an
existing pass. Include baseline and provenance, budget verdict per priority,
ranked proposals with before/after proof and regression risk, rejected ideas,
and explicitly unmeasured paths. Do not copy old measured numbers as a new
baseline; re-derive them from current artifacts.
