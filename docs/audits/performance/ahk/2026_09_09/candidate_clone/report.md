# Incremental candidate clone baseline

Measured on Windows on 2026-09-09 against `378719a57`. The production
`SQLite_CloneMemory` implementation copied the real derived reader image,
opened with `SQLiteConst.OPEN_RO`, into a private memory database. No ledger
was opened or modified, and no token, application name or payload was exported.

| Sequential sample | Clone time (ms) |
| --- | --- |
| 1 | 1402.475 |
| 2 | 1371.335 |
| 3 | 1293.045 |

The image contained 171,482 pages and occupied 702,390,272 bytes. QPC timing
covered the clone call only. Each clone was closed before the next sample;
page counts and schema row counts were checked outside the timed region.
These are structural checks, not a substitute for projection-equivalence tests.

The benchmark ran hidden with no concurrent local test suite. Desktop load and
filesystem cache state were uncontrolled; there was no explicit warm-up. Available
physical memory before launch was 1,756,252 KiB. Peak allocation and CPU usage
were not measured. The first sample is not a cold-filesystem measurement.

Reproduction script and exit-zero receipt are
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/metrics-candidate-clone-bench.ahk`
and sibling `.out`. Isolated-wrapper warnings about unused logger symbols and
shadowed benchmark globals did not execute failure paths. All handles closed.

## Consequence and remaining work

An incremental refresh of a restored read-only image pays a measurable
1.29–1.40 seconds for the private writable candidate alone. Unchanged disposable
workers already retain the file-backed image read-only and avoid this copy.
Do not describe this as an opening-latency measurement or assume every refresh
takes the candidate path.

No optimization is implemented by this report. Measure manifest projection and
encoding separately next. Any in-place cache proposal must first preserve atomic
offset/aggregate publication, failed-refresh recovery, resident live-walker
isolation, and competing worker ownership. Removing the private copy without
those guarantees would trade latency for potentially persistent wrong metrics.

## Manifest construction and encoding baseline

A second hidden process opened the same derived image read-only and called
the current `KLR_ReadManifest` and `KL_JsonEncode` separately. The disposable
worker premise was explicit: `KLHook.prev_app` was empty, so no resident live
foreground interval was added. No other local benchmark or suite ran concurrently.

| Sequential sample | Manifest construction (ms) | JSON encoding (ms) |
| --- | --- | --- |
| 1 | 1315.012 | 871.378 |
| 2 | 1317.078 | 915.471 |
| 3 | 1387.135 | 925.163 |

Each result contained 87 dates, 717 date/application cells and 1,910,238 UTF-8
bytes. Parsing and checking date/cell counts happened outside the timed regions.
These totals exclude the n-gram payload and all GUI rendering.

One subsequent diagnostic pass measured individual manifest helpers:

| Helper | Time (ms) |
| --- | --- |
| App/day | 51.127 |
| Time buckets | 115.572 |
| Bursts | 53.137 |
| Sessions | 29.977 |
| Character classes | 20.095 |
| Errors | 16.686 |
| Ergonomics | 11.359 |
| Layouts | 0.536 |
| Key hold | 0.475 |
| Window titles | 169.532 |
| Hourly series | 277.632 |
| Five-minute series | 737.356 |

That diagnostic pass reassembled exactly the same encoded manifest as the
production entry point. Its individual timings are one sample each and must
not be substituted for the three complete-call samples or added to them.
Desktop load, CPU usage, peak RAM and filesystem warmth remain uncontrolled.

Script and exit-zero receipt: scratch `metrics-manifest-phase-bench.ahk` and
`.out`, beside the clone benchmark. No private manifest contents were emitted.
All database handles closed. The next candidate should reduce repeated
materialization/serialization of the hourly and five-minute series while
preserving numeric coercion, malformed-histogram handling and multi-device
multiplicity; these semantics preclude blindly replacing the existing merge
logic with SQLite casts.

## Rejected: grouped JSON rows decoded back into Maps

A scratch-only candidate grouped hourly/five-minute SQL rows into one JSON
array per date/application, decoded those arrays in AHK, and reused the existing
numeric coercion and histogram merge functions. It reduced SQLite column-value
calls but introduced another AHK JSON decode. The candidate and baseline produced
identical canonical encoded projections in all three samples.

| Sample | Existing two helpers (ms) | Grouped-JSON candidate (ms) |
| --- | --- | --- |
| 1 | 924.143 | 1821.228 |
| 2 | 933.599 | 1823.990 |
| 3 | 938.161 | 1855.483 |

Both paths used the same read-only real image and returned Maps for 81 dates
with time-series data. Validation/encoding was outside the timed sections.
Baseline ran before candidate in each pair; no counterbalanced ordering or
separate cold-cache claim is made. The roughly twofold regression does not
justify integrating this candidate. Production code remains unchanged.

Reproduction and exit-zero receipt: scratch `metrics-series-group-bench.ahk`
and `.out`. Every connection closed; no user-data contents were exported.
If revisiting SQL JSON aggregation, keep the generated JSON encoded through
the producer boundary instead of paying to decode and then re-encode it.

## Encoded-series candidate: local gain, not yet integrated

A second scratch-only candidate keeps the scalar series encoded. SQLite emits
each bin's scalar JSON; AHK merges only nonempty error histograms using the
existing helper, then appends that owned property structurally. It returns
encoded series per date/application, not Maps requiring another encoding pass.

| Sample | Series | Existing build + encode (ms) | Encoded candidate (ms) |
| --- | --- | --- | --- |
| 1 | Hourly | 395.835 | 299.377 |
| 1 | Five-minute | 933.892 | 713.850 |
| 2 | Hourly | 364.114 | 278.876 |
| 2 | Five-minute | 918.504 | 698.891 |
| 3 | Hourly | 383.356 | 286.707 |
| 3 | Five-minute | 935.134 | 724.584 |

The baseline includes encoding those series, unlike the preceding two-helper
comparison. Every date/application series was parsed and canonically compared
outside the timed region. All matched on the real image. This is not yet proof
of malformed legacy histogram behavior or every supported numeric edge case.

The total reduction was 304.851–316.500 ms per sample pair. Both sides ran in
one hidden process with baseline first, no concurrent local suite, uncontrolled
desktop load and no cold-filesystem claim. Script and exit-zero receipt:
scratch `metrics-series-encoded-bench.ahk` and `.out`. All database handles closed;
no user-data contents were exported.

Keep this candidate out of production until its whole-manifest integration is
measured and its output/cleanup contract is tested. The new representation must
not contaminate `KLPF_MANIFEST_CACHE` with partially populated Map entries or
change the ordinary Map-returning reader contract.

## Whole-manifest prototype

The complete scratch prototype runs the other ten manifest helpers normally,
adds cells that exist only in time-series tables, and joins encoded series at
owned cell-object boundaries. It clones each metadata cell before removing the
two series fields, so the original cell is not modified.

| Sample | Existing complete build + encode (ms) | Complete candidate (ms) |
| --- | --- | --- |
| 1 | 2279.791 | 2011.864 |
| 2 | 2295.398 | 2013.161 |
| 3 | 2300.626 | 1997.755 |

All outputs contained 1,910,238 UTF-8 bytes and were canonically equal after
parsing outside the timed sections. Savings were 267.927–302.871 ms, roughly
12–13 percent on this workload. This remains a manifest-only measurement, not
an opening-latency or overall worker measurement.

The hidden process completed with exit zero and closed its read-only handle.
Script/receipt: scratch `metrics-manifest-encoded-bench.ahk` and `.out`; the
encoded-series script now guards its direct execution when included, without
changing its standalone benchmark. Ordering, uncontrolled desktop load and
the absence of a cold-filesystem claim match the preceding experiments.

No production integration has been made. The real-image equivalence check is
necessary but insufficient: synthetic coverage still needs malformed histograms,
numeric edge cases, duplicate devices, filtered ranges, series-only cells and
empty stores. A roughly two-second remaining manifest cost also means this
candidate alone cannot deliver the requested instant dashboard opening.

## Synthetic prototype admission checks

An isolated in-memory database using the production schema now covers an empty
store, cells present only in time-series tables, eight devices contributing to
one bin, repeated identical histograms, malformed JSON, scalar JSON, empty
histograms, hexadecimal numeric strings, nonnumeric strings, fractional and
negative histogram values, booleans/null, escaped application names, and inclusive
or excluding date filters. Baseline and candidate outputs match canonically.

Independent assertions require 16 characters, 8 errors and histogram bucket
`5` equal to 19. The malformed fixtures produce four diagnostics on both paths;
excluded dates produce none. These checks use the existing AHK histogram merge,
not a new SQLite numeric-coercion implementation.

Scratch `metrics-manifest-encoded-cases.ahk` completed with exit zero; the final
receipt is `metrics-manifest-encoded-filter-cases.out`. These are prototype
admission checks, not yet registered repository regression tests. Production
integration must retain the ordinary Map reader/cache contract and carry these
assertions into the normal suite before any performance change is committed.

## Production implementation verification

The subsequent implementation uses `KLR_BuildManifestJson` in the disposable
typing producer and preserves the ordinary Map-returning API/cache. Membership
indexes never enter that cache. Six registered native regression cases cover
the admission fixtures and cache reference/content isolation across manifest,
live and full modes. All six pass, as does the native selected-range bridge test.

The same hidden whole-manifest benchmark was then rerun with only its candidate
call changed from `EncodedManifest(Db)` to `KLR_BuildManifestJson(Db)`. The source
image was opened read-only, no suite ran concurrently, and canonical comparison
remained outside timed sections. Each result contained 1,910,238 UTF-8 bytes.

| Sample | Existing complete build + encode (ms) | Production candidate (ms) |
| --- | --- | --- |
| 1 | 2468.517 | 2103.043 |
| 2 | 2454.369 | 2128.686 |
| 3 | 2431.850 | 2143.713 |

The measured reduction is 288.137–365.474 ms (11.8–14.8 percent); the maximum
candidate sample is 2143.713 ms. This is neither a cold-filesystem measurement
nor end-to-end opening latency. Desktop load was uncontrolled and sample order
was baseline first. The scratch receipt is `metrics-manifest-production-01.out`,
exit zero, using `metrics-manifest-encoded-bench.ahk`. Standalone harness warnings
name unused live/logger dependencies; the real-schema suite exercises malformed
histogram diagnostics with the real logger. No private payload was exported.

Initial full verification passed 5905 AHK tests, 5 E2E tests, encoding and parse,
and 222 of 223 JS checks. The sole failure was a missing blank line before a
major section; that formatting violation was corrected before final verification.
