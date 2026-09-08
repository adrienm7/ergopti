<!-- docs/audits/performance/hammerspoon/2026_09_09/karabiner_test_folding/report.md -->

# Karabiner test constant-folding prefilter

## Scope and provenance

This concerns test execution on Windows Lua 5.4, not native Hammerspoon latency.
The baseline is `5b6674a7a`. Measurements ran on the maintainer's Windows PC on
2026-09-09 using `C:/Users/admin/AppData/Local/Programs/Lua/bin/lua.exe`.
One benchmark ran at a time; unrelated desktop load was not controlled.
No production driver behavior or source inventory coverage changes.

The original nine real test callbacks were captured by replacing `helpers.it`
during module loading, then restoring it. Baseline and candidate were loaded
from the same source, with exactly one in-memory insertion: return false from
`has_folded_stock_target` when neither literal `..` nor literal `+` occurs.
The shared production source cache was warmed before either variant. Each
phase collected garbage, executed all nine callbacks, and measured `os.clock`.
The phase order was baseline, candidate, candidate, baseline. Every callback
completed its actual assertions; all 36 executions passed.

Local reproduction scripts and raw receipts are retained in the worktree's
ignored `.rtk/benchmark-karabiner-fold-prefilter.lua` and matching `.log`.
The script was run from `static/ergopti_plus/macos` with
`lua ../../../.rtk/benchmark-karabiner-fold-prefilter.lua` against the baseline.
It expects the original nine cases, before the new regression is added.

## Measurements and limitations

| Phase | Elapsed-clock seconds | End-of-phase Lua heap, KiB |
| --- | ---: | ---: |
| Baseline 1 | 22.184 | 36300.895 |
| Candidate 1 | 19.968 | 40232.039 |
| Candidate 2 | 19.215 | 40232.039 |
| Baseline 2 | 20.078 | 36301.596 |

Mean module time changes from 21.131 to 19.592 seconds, about 7.3 percent.
Observed maxima are 22.184 and 19.968 seconds respectively. Two samples per
variant cannot establish tail latency or a stable machine-independent gain.
The candidate's slowest sample is only slightly faster than the baseline's
fastest sample. These observations justify a modest, semantics-preserving
work reduction, not a global suite-speed claim.

This Windows Lua clock advances during sleeping children, so the measurements
are not pure CPU time. Ending Lua heap increased in this experiment; it is
neither peak heap nor process RSS. No RAM reduction or CPU percentage is claimed.
Production event-tap, startup, idle, native macOS and GC latency are unmeasured.

An earlier instrumented real whole-driver guard took 23.815 seconds. Its
`has_folded_stock_target` dependency accumulated 4.880 inclusive seconds across
102712 calls. Wrappers share Lua upvalue cells, so this count includes nested
consumers; inclusive timings overlap and must not be summed as exclusive time.
Instrumentation overhead prevents using that run as the candidate baseline.

## Correctness and budget verdict

`folded_constant_values` supplies this predicate only with expressions having
at least one resolved join. The parser recognizes exactly `..` and `+` as
joins. Without either byte sequence, the result must be empty. Standalone
identifiers remain covered by the separate taint analysis; this is not a
Karabiner-substring file filter and does not skip any runtime source unit.

The new `(fold-operator-prefilter)` regression observes constant-table accesses:
operator-free expressions must perform zero lookups. The original code performs
four and fails the assertion. The same test verifies both supported operators
still detect a folded stock target and operators inside literals remain safe.
The complete targeted module passes ten tests after the change.

Targeted replay from the macOS driver root:

```sh
lua tests/run.lua --only tests.meta.test_karabiner_stock_process_isolation
```

No timing threshold is placed in the ordinary suite. Broad integration gates
remain required before committing. Further restructuring should separate the
pure detector from cases without weakening its alias and native-process tests.

## Rejected alternative

Replacing two `sub(index):match(...)` suffix copies with `match(..., index)`
was not retained. Its baseline/candidate/candidate/baseline times were
28.055/25.562/25.379/21.198 seconds: the final baseline beat both candidates.
An initial apparent gain did not survive the reversed order.
