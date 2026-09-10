<!-- docs/audits/performance/ahk/2026_09_10/encoded_titles/report.md -->

# Encoded window-title projection

## Mechanism and regression proof

The encoded manifest still constructed nested title Maps and encoded every
title again. `KLR_ReadManifestBase` now defaults to complete title Maps but lets
encoded publication opt out. `KLR_EncodedTitles` aggregates titles as native
SQLite JSON, and the publisher inserts these fragments at its owned object
boundary. Title-only dates/apps still populate membership. System counters
retain their overwrite priority, while a title-only `_system` cell keeps its
ordinary shape. JavaScript line and paragraph separators remain escaped.

The regression first added the optional flag without changing the old work:
`encoded-titles-before-01.log` failed because the opt-out still materialized a
title-only date; the independent equivalence case passed. After implementation,
both cases passed in `encoded-titles-after-01.log`. Tests cover ordinary Maps,
date bounds, title-only membership, device sums, fractions, large values, empty
and escaped titles/app names, both system ownership cases, and complete-cache
reference/content isolation. A guarded source assertion connects the measured
opt-out to production publication.

## Attribution and prototype

At `40d3dd7ac`, an isolated per-field encoder preserved exact manifest output.
Window-title encoding took 395.347/393.848/517.317 ms in three samples; other
large scalar histogram fields each took roughly 47–66 ms. Timers add overhead,
so these are attribution results, not an alternative latency baseline.
Receipt: `manifest-cell-fields-01.log`.

The initial title prototype pair was neutral: 4257.246/4252.096 ms. After warming
both paths, alternating-order baseline/candidate pairs were
4263.355/3050.693, 3400.690/2755.626 and 3576.996/3034.988 ms. All canonical
comparisons passed. These receipts are `manifest-encoded-titles-probe-01.log`
and `manifest-encoded-titles-pairs-01.log`; do not discard the neutral sample
or merge independent workloads into a new claim.

## Integrated producer measurement

`manifest-encoded-titles-production.ahk` retains the baseline builder/series
source from `40d3dd7ac` and compares it with the actual modified producer.
The baseline still requests complete title Maps from the shared base reader.
QPC measures each call; both paths are warmed and pair order alternates.
Canonical comparison is outside timing. Three comparisons pass, each manifest
1925898 UTF-8 bytes. Receipt `manifest-encoded-titles-production-01.log` exited 0.

| Sample | First path | Baseline (ms) | Candidate (ms) | Reduction (ms) |
| --- | --- | --- | --- | --- |
| 1 | Baseline | 5047.152 | 3714.814 | 1332.338 |
| 2 | Candidate | 3315.683 | 2812.930 | 502.753 |
| 3 | Baseline | 3038.278 | 2543.628 | 494.650 |

Candidate median/max: 2812.930/3714.814 ms. Pair reductions span approximately
15–26 percent. Desktop load and filesystem residency were uncontrolled, and
absolute times varied substantially; three samples do not estimate tail
percentiles or establish a stable speedup guarantee.

## Separate process memory measurement

Six fresh hidden processes each generated one manifest without same-process
warmup or canonical parsing. GetProcessMemoryInfo was sampled immediately after
generation, before receipt serialization. Receipts
`manifest-encoded-titles-memory-01-1.log` through `-6.log` all exited 0.

| Run | Mode | Elapsed (ms) | Peak working set (bytes) | Private bytes after generation |
| --- | --- | --- | --- | --- |
| 1 | Baseline | 2771.810 | 39645184 | 11415552 |
| 2 | Candidate | 2581.123 | 37371904 | 12431360 |
| 3 | Candidate | 2137.166 | 37154816 | 12070912 |
| 4 | Baseline | 2688.949 | 39714816 | 12890112 |
| 5 | Baseline | 3204.564 | 39759872 | 11952128 |
| 6 | Candidate | 2318.683 | 37019648 | 11415552 |

Median peak working set drops from 39714816 to 37154816 bytes: 2560000 bytes,
about 2.44 MiB. Median private bytes after generation instead rises by 118784
bytes (116 KiB). Peak and retained allocation are different measures; do not
claim a reduction in every memory counter or combine these timings with the
warmed pairs above. This measures the projection process, not system-wide RAM
or the large SQLite memory clone.

A preceding fresh-process check of histogram reuse at `40d3dd7ac`, against its
pre-fix baseline, found median peak working set +108 KiB and private bytes after
generation +772 KiB. Those are separate results, recorded in
`manifest-histogram-memory-01-1.log` through `-6.log`, not title optimization data.

## Provenance and limits

All probes ran hidden and sequentially against the historical 702390272-byte
derived SQLite image opened `OPEN_RO`. Its size and modification time
(2026-09-09 07:21:14 UTC) remained unchanged. Harness outputs contain timings,
byte counts and memory counters, never window titles or manifest JSON. No source
ledger, published cache or resident driver was changed by the probes.

These results do not measure a fresh cache rebuild, tail consumption, decryption,
aggregate recomputation, durable publication, browser rendering or complete
opening. They also do not cover keystroke latency, startup readiness or
long-lived memory growth. Immediate opening and absence of other defects remain
unproven. All commands and detailed receipts are retained in the campaign scratch.

## Validation

`encoded-titles-before-01.log` records the behavioral regression: the base reader
still materialized title-only cells despite the explicit opt-out. The projection
positive control passed. Both targeted cases passed after the implementation in
`encoded-titles-after-01.log`.

`encoded-titles-gate-01.log` ended with exit 1: 6092 AHK tests passed, while the
unchanged complete tooltip preparation case exceeded its strict 5 ms p95 budget
at 5.080 ms (positioning component 4.712 ms). Encoding, parsing, all five E2E
tests and all 223 JavaScript checks passed. This receipt is not a green gate;
the timing failure was checked against the baseline separately.

The full baseline suite ran from an isolated `git archive` of `40d3dd7ac`, with
the candidate worktree untouched. `encoded-titles-baseline-suite-01.log`
reproduces the same tooltip failure at p95 5.405 ms (clamp 1.350 ms, positioning
3.753 ms). This establishes a baseline failure independently of the title
changes, but does not establish its root cause or excuse the latency budget.
The archive has no Git metadata, so its commit-history check is not evidence
about repository history. No threshold or assertion was weakened.
The control ended with exit 1, 6090 passes and this single failure. All candidate
metrics tests passed in the original gate. Disjoint encoding, parsing, E2E and
JavaScript gates were not repeated; the tooltip baseline failure remains open.
