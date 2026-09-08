<!-- docs/audits/performance/hammerspoon/2026_09_09/registry_test_compilation/report.md -->

# Registry property test compilation

## Scope and provenance

This measures the Windows Lua test harness, not native macOS latency. The
production driver is unchanged. Repeated fresh registry construction recompiles
the same dependency sources thousands of times. Earlier module profiling placed
this property workload first among the Hammerspoon test modules.

Measurements ran sequentially on the maintainer's Windows PC on 2026-09-09,
using Lua from `C:/Users/admin/AppData/Local/Programs/Lua/bin/lua.exe` and source
based on commit `eb446e166`. No other agent test suite was launched by this
session; unrelated desktop activity was not controlled.

Both modes execute all 14 real properties and 5,200 samples with seed 424242.
The benchmark checks a canonical signature of every generated value, the labels,
sample counts and actual helper failure totals. Baseline disables only the new
compilation scope. No generator, predicate, run count or assertion is removed.

## Observations

| Matched run | Baseline seconds | Cached seconds | Reduction |
| --- | ---: | ---: | ---: |
| Initial integrated scope | 38.077 | 20.196 | 47.0% |
| With payload observation | 35.766 | 19.263 | 46.1% |
| Tracked benchmark replay | 47.505 | 24.672 | 48.1% |

These are whole-workload observations, not per-keystroke percentiles or a
statistical latency budget. The maximum observed baseline/candidate durations
were 47.505/24.672 seconds. An earlier calibration showed that this Windows
Lua's `os.clock()` advances during a sleeping child: these values are clock/
elapsed seconds here, not pure CPU consumption. POSIX Lua uses different clock
semantics. Native event-tap, startup, idle and GC latency remain unmeasured.

All three candidate runs recorded 36,302 compilation-cache hits and 98 misses.
Maximum observed end-of-property retained source-plus-bytecode payload was
318,488 bytes (about 311 KiB). This excludes Lua table/string overhead, temporary
allocations, module state, the benchmark's input history and child processes.
It is not a peak-RSS measurement or evidence of an overall RAM reduction.

## Mechanism, lifetime and regression risk

Each property owns a separate synchronous compilation scope. Each lookup resolves
the current path and reads exact source bytes. Path changes, new shadowing files,
same-length edits, deletions and syntax errors cannot use an old hit. Misses use
the original file searcher, preserving BOM/shebang parsing and loader metadata;
only ordinary main chunks are retained after checking the source again.

Hits load a new function from bytecode. Reusing an executed function was rejected:
a real module replacing `_ENV` returned 1 then 2 with closure reuse, rather than
1 then 1 with fresh functions. Module executions, native stubs and registry state
remain fresh. The cache becomes unreachable after each property; it is neither
global nor persisted on disk. Custom searchers retain their own behavior.

Behavioral regressions cover fresh object identity, mutation isolation, source
and path invalidation, preload priority, syntax repair, fresh environments,
BOM/shebang, nested scopes, exact error/return arity, custom loaders, changed
searchpath hooks and read/close failures. Searcher restoration is asserted before
fixture rescue. Owned source files are removed even after callback failure.

The source checks do not make filesystem reads atomic against arbitrary external
writers. As with uncached test execution, run against a stable checkout; never
run driver tests alongside generators or drift probes. This fixture is test-only
and does not authorize introducing a production hot-path cache.

## Replay

From `static/ergopti_plus/macos`, with the desired Lua runtime on PATH:

```sh
lua tests/run.lua --only tests.unit.infra.test_compiled_lua_scope
lua tests/benchmarks/registry_compilation.lua
```

The benchmark is opt-in and is not discovered by the normal unit runner. Its
retained-payload observation intentionally inspects the private cache; failure
to find that cache fails the measurement instead of reporting zero bytes.

Full-suite duration, aggregate process-tree CPU/RAM and native macOS performance
need separate measurements. Do not extrapolate the approximately 46–48% gain of
this module to the complete suite.
