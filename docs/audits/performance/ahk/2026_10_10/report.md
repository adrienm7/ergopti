<!-- docs/audits/performance/ahk/2026_10_10/report.md -->

# Windows configuration registry comparison

## Measurement and limits

The October 10 release investigation measured the existing registered
`hotstrings-capacity: genuine captured registry guard` callback on Windows,
using AutoHotkey v2 and a private copy of the canonical test include graph.
The resident driver was left running. The original and candidate actors ran
successively without another audit actor, and both exited normally with the
same 32 successful guard calls. The surrounding sources remained unchanged.

This is one paired sample, using QueryPerformanceCounter instrumentation.
It measures a configuration predicate, not typing latency, startup completion,
menu click latency, or the complete CI suite. There is no per-call percentile
or maximum distribution. The profile used an isolated temporary directory but
inherited LOCALAPPDATA; the selected callback does not flush the parse cache.
The later safety controls also isolated LOCALAPPDATA.

| Instrumented region                                |   Original |  Candidate | Change |
| -------------------------------------------------- | ---------: | ---------: | -----: |
| Batch of 32 genuine guard calls                    | 492.896 ms | 279.830 ms | -43.2% |
| Registry comparison across 43 observed validations | 652.169 ms | 368.931 ms | -43.4% |
| Complete private process, including parsing        |   10.991 s |   11.721 s |  +6.6% |

The comparison is nested inside registry validation; those durations must not
be summed. The complete process did not become faster in this pair. Whole-driver
latency and the full-suite deadline remain unqualified.

## Change and retained checks

`ConfigMigrateBoot` compares typed scalar leaves before object dispatch, using
the same exact string comparison and integer/Float numerical equality as its
canonical scalar owner. A map that is already case-sensitive no longer needs
another case-sensitive copy. Other maps retain the exact-key copy.

Every validation still checks the canonical native function identities, actual
registry identity, map and array prototypes, own properties, sizes, key case,
array holes, and TOML boolean shape. No result or permission is cached. This
optimization is specific to the Windows AHK implementation; the Lua drivers
do not use this comparator or AutoHotkey Map case modes.

Nine actual controls passed, including two new registered tests for scalar
types and native-owner withdrawal. Removing the String type check made the
numeric-looking String vector fail. Removing the canonical scalar-owner check
made the foreign-owner vector fail. Both inverse runs exited with the expected
failure; the retained candidate passed all nine controls.

## Remaining work

The boot and menu latency budgets are still open. Full Windows unit and E2E
qualification must run on the final composed release source. The broader source
lifecycle defect found during this investigation is tracked separately; this
comparison optimization does not settle a retired configuration transaction.
