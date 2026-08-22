# Hammerspoon performance audit

## Measurement sources

Resolve the configured Ergopti directory, then `hammerspoon/logs/`. Use the
unified file log rather than the Hammerspoon console, and date events from line
timestamps rather than the process-start date in the filename.

Inspect the live profiler modules before naming instrumentation; extend them if
a high-priority path is not covered. For a temporary wall-clock probe use
`hs.timer.absoluteTime()`. `os.clock()` measures CPU rather than elapsed time.
Remove temporary probes or integrate them with a documented segment and test.

Do not infer event-tap timeouts by searching for Lua constants named after
CoreGraphics disable events. The bundled Hammerspoon native extension handles
tap-disable notifications before Lua dispatch, so those event type names are
not exposed to callbacks. The driver's watchdogs instead poll native enabled
state and restart persistent taps. Measure callback latency directly and inspect
watchdog/restart evidence in current logs.

## Priorities

1. `hs.eventtap` callbacks: bounded in-memory work only. `doAfter(0)` moves work
   to a later turn of the same main loop; it does not make blocking shell,
   filesystem, Accessibility, or network work asynchronous.
2. Synthetic input and tooltip/canvas rendering, including native position
   queries and debounce effectiveness.
3. Startup until input owners are committed.
4. Idle timers/watchers, GC pressure, and structures that grow over a long
   session.

Count tables, closures, concatenations, full-buffer transformations, pattern
work, native calls, and system I/O per keystroke. A reduction in allocations is
only a claimed latency win after an in-situ measurement; otherwise report it as
an operation-count hypothesis.

## Deliverable

Write `docs/audits/performance/hammerspoon/<YYYY_MM_DD>/report.md` without
overwriting an existing pass. Include baseline and provenance, budget verdict
per priority, ranked proposals with before/after proof and regression risk,
GC/idle impact, cross-driver relevance, rejected ideas, and unmeasured paths.
