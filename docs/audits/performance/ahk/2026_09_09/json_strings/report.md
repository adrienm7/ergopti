<!-- docs/audits/performance/ahk/2026_09_09/json_strings/report.md -->

# JSON string admission fast path

## Mechanism and scope

The shared Windows string encoder previously iterated every character even when
no escaping was necessary. A native regular-expression scan now admits strings
with no JSON/JavaScript escape characters; HTML-safe mode additionally rejects
HTML delimiters. Rejected strings use the unchanged original encoder loop.
There is no cache, new format, or changed invalidation rule.

This benefits all callers of `JsonStringLiteral`, including metrics manifest
keys. It does not remove manifest projection, database replay, transport, or
WebView rendering costs. Those costs still prevent an instant-opening claim.

## Evidence

Measurements ran on the maintainer's Windows machine on 2026-09-09 using hidden
AutoHotkey v2 processes and QPC. The resident driver remained running; desktop
load and OS file-cache state were uncontrolled. Private `reader.sqlite` was
opened read-only. No journal/cache was written or private payload exported.

Scratch probes and receipts live in the owned
`ergopti-ahk-verification-temp-2026-09-08` directory. The command shape is
`AutoHotkey64.exe /ErrorStdOut <probe>.ahk` with captured stdout/stderr and a
checked native exit. Every measurement below exited zero.

`probe-json-fast-path.ahk` first compares the original encoder with an isolated
candidate, then encodes 20,000 representative manifest keys. Its initial run
covered 86 equivalence vectors and measured 421.005 ms before versus 82.023 ms
for the candidate. An expanded run covered 131,094 comparisons, including every
non-NUL UTF-16 code unit in both HTML modes, and measured 413.289 versus
63.798 ms. Receipts: `json-fast-path-1` and `json-fast-path-exhaustive`.

`probe-manifest-phases.ahk` reads the real manifest and times `KL_JsonEncode`.
The image is a legacy projection: timings do not establish the correctness or
freshness of its stored aggregates. The resulting JSON has 1,811,993 characters.

| Measurement | Production encoding (ms) |
| --- | ---: |
| Before, sample 1 | 2570.643 |
| Before, sample 2 | 2795.034 |
| Before, sample 3 | 3486.944 |
| After, sample 1 | 1259.205 |
| After, sample 2 | 1262.503 |

Before receipts: `manifest-phases-1`, `manifest-phases-2`, `manifest-phases-3`.
After receipts: `json-production-after-1`, `json-production-after-2`.
Maximum observed encoding fell from 3486.944 to 1262.503 ms; these small sample
counts do not support p99 or cold-boot claims.

Before editing production, a paired experiment used the original encoder and
an isolated recursive encoder differing at string admission only. It required
exact equality of the complete JSON strings in memory: 2593.867 ms original,
1053.832 ms candidate (`json-manifest-candidate-1`). Original ran first, so this
is not a randomized ordering experiment. The production-after measurements
above, rather than the candidate timing, describe the shipped mechanism.

Manifest projection itself still took 4.2–5.5 seconds in these runs. A separate
diagnostic pass identified five-minute statistics, titles, hourly statistics,
and time buckets as expensive contributors; those helper timings are not parts
of the earlier timed call and must not be summed into it.

## Regression coverage and limitations

`unit/test_json_string_fast_path.ahk` registers two behavioral cases under
`json-safe-string-fast-path`. They verify all non-NUL UTF-16 units embedded in
ordinary text, controls, quotes, backslashes, JavaScript line separators,
HTML delimiters, isolated surrogates, empty strings, numeric conversion, and an
astral emoji. The focused native run passed both cases. AutoHotkey strings do
not retain embedded NUL, so it is not claimed as an executable string vector.

The regression tests protect exact output, not a desktop-dependent time budget.
They also pass the former correct-but-slow encoder; the recorded native baseline
is the performance reproduction. No timing threshold was weakened to pass CI.
The full selected verification receipt is `json-fast-path-verify.log`; consult
its terminal result before treating this change as ready to commit.

Keystroke latency, hook deadlines, tooltip rendering, idle CPU, and complete
dashboard first paint were not measured. No budget verdict is asserted for them.
