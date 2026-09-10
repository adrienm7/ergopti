<!-- docs/audits/performance/ahk/2026_09_10/histogram_reuse/report.md -->

# Reuse normalized histograms within one manifest call

## Mechanism and regression proof

`KLR_EncodedTimeSeries` grouped duplicate device rows but still parsed the same
histogram again for every bin. It now retains successful unit normalization in
a fresh local Map. Each destination bin receives its own scaled counts; no
normalized Map is published or stored in the complete manifest cache. Invalid
JSON and non-object values are never memoized, preserving their per-row error
path and the logger's existing consecutive-message deduplication.

The optional normalizer port delegates to the real normalizer by default. The
native regression first attached that port to the uncached implementation:
`histogram-reuse-before-02.log` failed both series types with three valid
normalizations instead of one. This demonstrates repeated work, rather than a
missing API failure. The first exploratory receipt (`before-01`) instead
exposed a wrong test assumption about logger deduplication and is not evidence
of a production defect. After the fix, both targeted tests passed in
`histogram-reuse-after-01.log`. The final fixture additionally starts with
multiple source devices and checks different multiplicities, numeric coercion,
repeat invalid diagnostics and fresh normalization on the next invocation.

## Attribution and rejected alternatives

The current encoded manifest was instrumented in an isolated scratch copy,
with exact output equality against production. Three samples attributed
814.568–822.124 ms to base cells, 529.297–594.147 ms to hourly series,
1398.239–1533.355 ms to five-minute series and 1146.979–1193.673 ms to assembly.
A second attribution found 898.038–985.467 ms in five-minute histogram merging,
versus 65.207–77.991 ms in its histogram SQL query. Receipts are
`manifest-current-internal-phases-01.log` and `manifest-series-internal-phases-01.log`.

A SQL VALUES histogram join was canonically equivalent but slower:
hourly 517.859/794.182 ms and five-minute 1345.529/3244.754 ms
(baseline/candidate). EXPLAIN showed `SCAN e LEFT-JOIN` repeatedly scanning
1676 histogram rows. UNION ALL regrouping removed the large penalty but still
lost: 473.495/565.186 ms and 1637.605/1822.566 ms. Neither prototype was adopted.
These are different from the previously rejected SQL JSON-to-AHK decoding path.

Call-local histogram reuse then won all six alternating-order series pairs,
with canonical equality. Hourly baseline/candidate milliseconds were
719.200/420.058, 936.892/597.536 and 721.909/525.530; five-minute values were
1654.211/1105.448, 1385.698/887.259 and 1402.226/931.631.
Receipt: `manifest-cached-histograms-pairs-01.log`.

## Final implementation measurement

The hidden `manifest-histogram-production.ahk` harness compares the committed
baseline at `184a6f651` with the actual modified `KLR_BuildManifestJson`.
It uses QPC, warms both paths, alternates pair order, and performs canonical
comparison outside timing. The historical 702390272-byte derived image is
opened `OPEN_RO`; size and modification time (2026-09-09 07:21:14 UTC) remained
unchanged. No source ledger is changed or uploaded, and no private JSON is
written. All three manifest comparisons pass, each output 1925898 UTF-8 bytes.
The receipt `manifest-histogram-production-01.log` terminated with exit 0.

| Sample | First path | Baseline (ms) | Candidate (ms) | Reduction (ms) |
| --- | --- | --- | --- | --- |
| 1 | Baseline | 6014.674 | 5088.443 | 926.231 |
| 2 | Candidate | 7774.548 | 4872.555 | 2901.993 |
| 3 | Baseline | 6473.099 | 5608.357 | 864.742 |

Candidate median/max: 5088.443/5608.357 ms. Pair reductions span 13.4–37.3
percent, with a much larger second-pair difference. Desktop load, memory
pressure and filesystem residency were uncontrolled; this small sample cannot
support a stable percentage promise or a regression claim against older runs.
No competing heavy verifier was observed during measurement.

This measures manifest generation against a historical image, not a current
cache rebuild or complete dashboard opening. Tail application, decryption,
aggregate recomputation, durable publication, browser rendering, per-keystroke
latency and peak memory were not measured. The local cache adds temporary
normalized Maps; no RAM reduction is claimed. The goal of immediate opening
remains unproven, and these checks do not establish absence of other defects.

## Validation

`histogram-reuse-gate-01.log` selected encoding, parsing, AHK, E2E and JS.
Encoding, parsing, five E2E tests and 223 JS checks passed. Its AHK run had
6090 passes and one tooltip preparation timing failure: p95 5.282 ms against
a strict 5 ms bound, dominated by the native positioning step. That verifier
invocation exited 1 and is not reported as green.

With both modified AHK files temporarily restored to the exact committed
baseline, all three targeted tooltip cases passed (`histogram-tooltip-baseline-02.log`).
The candidate files were restored and compared exactly to their saved contents.
An AHK-only full rerun (`histogram-reuse-suite-02.log`, exit 0) passed all 6091
tests, including the tooltip and strengthened histogram cases. Passed disjoint
gates were not repeated. The initial timing failure was not reproduced and its
cause remains unestablished; no timing threshold or tooltip code was changed.
