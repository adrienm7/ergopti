<!-- docs/audits/performance/ahk/2026_09_10/apps_encoded_manifest/report.md -->

# Encoded Apps manifest publication

## Scope and mechanism

The Apps producer still materialized complete manifest Maps before JSON
encoding. The typing producer already used `KLR_BuildManifestJson`, which keeps
hourly and five-minute series encoded while retaining ordinary metadata Maps.
Apps now opts into the same serializer through `KLPF_BuildApps(db, true)`.
The default Apps API still returns complete Maps. Publication extracts the
internal JSON field and inserts it at the encoder-owned object boundary.
No new cache or ledger mutation is introduced.

## Method

Baseline source: `e64d7458f`. The hidden native AHK harness
`apps-encoded-manifest-bench.ahk` in the campaign scratch includes the actual
Apps producer and existing manifest reader. It opens the existing 702,390,272
byte derived SQLite image with `OPEN_RO`; its size and modification time were
unchanged across measurement. It does not attach, rebuild or publish that cache.
No private payload is written to receipts, repository files or remote services.

Each pair times `KL_JsonEncode(KLPF_BuildApps(db))`, then the encoded producer
and the same structural JSON insertion used by publication. QPC is the clock.
Canonical JSON comparison happens outside timing. Each side produces 1,925,934
UTF-8 bytes and all three comparisons pass. Baseline runs first in every pair.
The preceding prototype warmed filesystem pages; this is not a cold-cache test.
No other heavy verifier was observed at launch or during the final measurement,
but desktop load was uncontrolled and absolute times varied substantially.

## Final implementation measurement

Receipt: `apps-encoded-manifest-production-01.log`, process exit 0.

| Sample | Ordinary Apps build and encode (ms) | Encoded Apps build and encode (ms) |
| --- | --- | --- |
| 1 | 3000.698 | 2589.435 |
| 2 | 4202.340 | 3753.600 |
| 3 | 4804.111 | 4135.169 |

Reduction: 411.263–668.942 ms, approximately 10.7–13.9 percent. Maximum candidate
sample: 4135.169 ms. This is a small sample with fixed ordering, not a latency
distribution or a guarantee. Database construction, staged file writing,
browser rendering, complete dashboard opening and peak RAM were not measured.

The earlier prototype receipt `apps-encoded-manifest-bench-01.log` also passed
three canonical comparisons. Baseline/candidate milliseconds were
2534.318/2290.606, 2760.935/2397.818 and 3213.921/2636.494. Use the final table
above for the production implementation; do not merge both runs into a new
latency claim.

## Regression coverage

Native manifest tests compare ordinary and encoded Apps output, preserve the
complete typing cache's identity and contents, and retain malformed-series
diagnostics and daily system totals. A new real worker-database fixture exercises
Apps publication in full, live and manifest modes, checks escaped internal-marker
text in an application name, and compares the exact published bytes with the
RAM publication cache. A nonempty source guard protects the production opt-in;
the baseline fails that routing assertion. The initial native selection ran
106 manifest-related cases successfully. Final change-scoped verification
(`apps-encoded-gate-01.log`, exit 0) passed 6,089 AHK tests, five E2E tests,
223 JavaScript checks, encoding and parsing. This coverage does not establish
that the modules are free of other defects.
