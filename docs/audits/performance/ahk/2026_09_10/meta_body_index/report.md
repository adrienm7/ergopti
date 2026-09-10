# Initial function lookup in AHK source tests

## Scope and method

Measured on the maintainer's Windows machine, 2026-09-10, from the dedicated
metrics worktree based on `772034467`. No driver startup, typing or private
metrics data was involved. Each hidden AHK process ran the actual HotIf safety
and tooltip expiry guards three times. Only one native process ran at a time;
the launcher waited for other agents' verifier/Lua processes before each run.

The existing function-body cache already removed repeated extraction. QPC
instrumentation around its original `Get` method localized the expensive first
pass to 72 cold lookups for HotIf and 65 additional lookups for tooltip expiry.
Repeated lookups took less than 1.3 ms in aggregate per guard invocation.

The candidate indexes the first line-anchored identifier followed by `(` in the
immutable source. It starts the unchanged signature/body parser at that position.
A candidate call is not assumed to be a definition. Case-sensitive lookup,
invalid-name errors, empty-source retry and custom extractor ports are retained.

## Alternated measurements

Separate processes used baseline/candidate, candidate/baseline, baseline/candidate
order. Baseline injected the original non-indexed extractor through the existing
cache port; candidate used the new default. Both used the same source and timing
wrapper. Values below are total first-pass guard wall time in milliseconds.

| Pair | HotIf baseline | HotIf candidate | Tooltip baseline | Tooltip candidate |
| --- | ---: | ---: | ---: | ---: |
| 1 | 2893.169 | 2181.814 | 2605.841 | 1309.373 |
| 2 | 2867.419 | 2159.218 | 2743.109 | 1271.607 |
| 3 | 2937.909 | 2178.646 | 2708.799 | 1293.750 |

HotIf saved 708-759 ms (about 25-26%); tooltip expiry saved 1296-1472 ms
(about 50-54%). Candidate maxima were 2181.814 and 1309.373 ms respectively.
These are two isolated source guards, not a complete-suite or driver latency
measurement. The remaining source parsing work is still substantial.

An independent pass compared all 137 requested names against the original
extractor and obtained identical bodies/absence. A separately constructed index
held 4537 entries. Process private committed memory increased by 385024 bytes
around that construction; this is one allocator-dependent sample, not an exact
object-size or peak-RAM measurement. The counter layout follows Microsoft's
[PROCESS_MEMORY_COUNTERS_EX definition](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex).

## Evidence and reproduction

Campaign scratch: `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
Receipts: `meta-scan-warm-profile-01`, `meta-scan-warm-profile-02`,
`meta-scan-index-profile-01`, and `meta-index-pairs-01-1-baseline` through
`meta-index-pairs-01-7-equivalence` (`.out`, `.err`, `.exit`).
The final probe is archived there as `meta-body-index-profile.ahk.txt`.
Place an owned copy under `windows/tests/` so the standard source loader resolves
its root, then launch AutoHotkey64 with `/ErrorStdOut` hidden, passing `baseline`,
`candidate`, or `equivalence`. Set TEMP/TMP to the campaign scratch. Retire only
that owned probe after the process exits. No `/validate` or resident restart.

Native cache tests cover scanner parity, exact case, invalid typed names,
immutable snapshots, empty-source recovery and custom extraction counters.
The default-path fixture initially had an AHK quoting error; after correction,
`body-index-native-02` passed all 14 selected cases. Full change-scoped validation
is recorded separately; targeted success alone does not establish suite coverage.
