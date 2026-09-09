<!-- docs/audits/performance/hammerspoon/2026_09_09/mlx_test_compilation/report.md -->

# MLX ownership test compilation experiment

## Verdict and provenance

Reject compilation reuse around each MLX ownership scenario group for now.
The small, variable CPU difference does not justify the observed working-set
increase. No implementation, assertion, or corpus count changed. This does
not reverse the separately measured registry-property optimization.

The Windows Lua harness was measured at `64d279337` on 2026-09-09, beginning
at 12:56 UTC, using `C:/Users/admin/AppData/Local/Programs/Lua/bin/lua.exe`.
Runs were sequential, without another heavy test suite. Ordinary desktop
activity and browser tooling were not controlled. Native macOS event taps,
startup, idle, GC latency, and cross-driver runtime budgets remain unmeasured.

## Focused module survey

Two passes run exact modules through `lua tests/run.lua --only`, reversing
the module order in pass two. Every run exits zero. Prefix each suffix below
with `tests.unit.`. Values describe these modules, not the full suite.

| Module suffix | Cases | Elapsed seconds, pass 1 / 2 | Lua CPU seconds, pass 1 / 2 |
| --- | ---: | ---: | ---: |
| `menu.test_llm_menu_persistence` | 26 | 17.118 / 15.328 | 3.313 / 3.094 |
| `adapters.file_system.test_classified_read_and_create` | 15 | 13.214 / 11.982 | 1.375 / 1.156 |
| `modules.llm.test_api_mlx_pause_ownership` | 49 | 11.434 / 12.223 | 10.609 / 11.484 |
| `adapters.test_file_system_staging_isolation` | 13 | 9.171 / 9.113 | 0.953 / 0.859 |
| `lib.test_toml_writer` | 20 | 10.029 / 10.058 | 1.250 / 1.266 |
| `ui.test_preferences_nested_array_roundtrip` | 15 | 10.110 / 9.870 | 1.875 / 1.891 |

CPU comes from the retained Windows process object's `TotalProcessorTime`;
elapsed time uses a .NET `Stopwatch` around launch and completion. CPU excludes
subprocesses. The attempted post-exit memory query returned null: the survey
supplies no RAM evidence. Elapsed-minus-CPU alone cannot distinguish filesystem
cost, child CPU, scheduling, and other waits.

## Counterbalanced compilation trial

The candidate wraps each of five existing `helpers.describe` groups in
`tests.support.compiled_lua_scope.with_scope`. That existing owner validates
source bytes and loads fresh functions, preserving module execution and state.
All 49 callbacks and assertions execute; expanded names and order match exactly.

| Run | Mode | Elapsed seconds | Lua CPU seconds | Sampled peak working set, bytes |
| --- | --- | ---: | ---: | ---: |
| 1 | Baseline | 6.861 | 6.219 | 9,129,984 |
| 2 | Candidate | 6.375 | 6.078 | 15,302,656 |
| 3 | Candidate | 5.771 | 5.469 | 15,577,088 |
| 4 | Baseline | 6.035 | 5.797 | 9,334,784 |

The candidate maximum exceeds the faster baseline in elapsed time and CPU.
Two observations per mode cannot establish tail percentiles or distinguish
small gains from order and desktop variation. Candidate working set is
consistently higher: 14.6-14.9 MiB versus 8.7-8.9 MiB.

Native `PeakWorkingSet64` was sampled while the Lua process was alive at about
25 ms intervals. This is the greatest observed root-process lifetime peak;
the final sampling gap may miss a later peak. It is not child-tree memory,
retained Lua payload, or a GC-pause measurement. Trial timings are not directly
comparable with the survey: the trial uses a minimal bootstrap, while the
survey includes the normal runner's search path and isolation setup.

## Reproduction and next investigation

The existing HS worktree retains private scripts and raw receipts in `.rtk/`:
`measure-hs-candidates.ps1`, `hs-candidate-costs.json`,
`mlx-compilation-candidate.lua`, `measure-mlx-compilation.ps1`,
`mlx-compilation-measurements.json`, and each process's `.out.log`/`.err.log`.
The trial script checks 49 passes, zero failures, and identical case names.
From the worktree root, with Lua on PATH:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .rtk/measure-hs-candidates.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .rtk/measure-mlx-compilation.ps1
```

The candidate's only change is this process-local wrapper, installed before
requiring `tests.unit.modules.llm.test_api_mlx_pause_ownership`:

```lua
local original_describe = helpers.describe
helpers.describe = function(name, callback)
    return Compilation.with_scope(function()
        return original_describe(name, callback)
    end)
end
```

Each mode runs in a fresh process with the same bootstrap. This wrapper is
not installed in the repository suite. Investigate MLX fixture construction
and module initialization before expanding compilation reuse. Preserve all
file-boundary integration scenarios and every generated sample.
