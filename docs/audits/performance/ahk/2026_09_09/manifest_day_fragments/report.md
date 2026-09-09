# Encoded manifest day-fragment feasibility

## Result and scope

Rebuilding one day and assembling already prepared encoded fragments was much
cheaper than rebuilding the complete manifest on the measured image. Every
sample produced a canonically equivalent 1,910,238-byte JSON manifest covering
87 days. This justifies investigating a fragment reuse prototype; it does not
justify introducing a persistent cache yet.

No production code changed. This is not dashboard opening latency, incremental
SQL replay, cache publication latency, or a system memory benchmark.

## Method

- Measured on 2026-09-09, before 18:24 UTC, at source commit
  `f6a889009a86370d368b0a3ae4a871812753c2c1`.
- Native AutoHotkey v2.0.26, hidden processes, QPC timing, one native measurement
  at a time, after the other agent's heavy verification finished.
- Existing derived SQLite image opened with `SQLiteConst.OPEN_RO`: 702,390,272
  bytes, modification time `2026-09-09T07:21:14.0299375Z`, unchanged afterwards.
  The journal was not opened or modified. No private payload was printed or saved.
- Pre-experiment free resources: approximately 2,835 MB RAM, 13.92 GB on C: and
  47.51 GB on D:. These are availability observations, not peak-memory results.
- Each process first built and decoded a reference manifest, then encoded its
  per-day fragments into an in-memory Map. This preparation is outside timing.
- Each of three samples timed complete `KLR_BuildManifestJson`, a date-filtered
  call for the selected day, and concatenation with prepared fragments. Complete
  output equality was checked after timing by parsing and canonical encoding.
- The latest day contained four application cells. A separate process selected
  the day with the most application cells: fifteen. Cell count does not establish
  the worst day by event count, histogram size, or projection duration.
- No replayed changes were injected: the experiment demonstrates reconstruction
  and assembly cost on an immutable source, not fragment invalidation correctness.

## Samples

| Selection | Sample | Complete manifest ms | Selected day ms | Assembly ms |
| --- | ---: | ---: | ---: | ---: |
| Latest day | 1 | 2564.525 | 14.523 | 32.597 |
| Latest day | 2 | 1938.985 | 17.125 | 1.404 |
| Latest day | 3 | 2057.128 | 17.740 | 1.930 |
| Most application cells | 1 | 2114.632 | 58.746 | 37.274 |
| Most application cells | 2 | 2123.035 | 65.601 | 1.379 |
| Most application cells | 3 | 2272.607 | 64.400 | 1.669 |

The first assembly in both processes was slower than subsequent assemblies.
Retain these values; three samples cannot characterize tails or establish a
steady-state latency distribution.

## Reproduction artifacts

Campaign scratch: `D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
Harness: `metrics-manifest-day-fragments-bench.ahk`; final SHA-256:
`851A1F5F459251D8E14A783ECA83CAEDF2575A5D6425B0B8EB2FF0A6EB8F4306`.
Invoke the hidden AHK process with `/ErrorStdOut` and the harness path, adding
`dense` to select the day with most application cells. Set TEMP and TMP to the
campaign scratch. Never use `/validate`.

Receipts `metrics-manifest-day-fragments-04` and
`metrics-manifest-day-fragments-dense-01` each have `.out`, `.err` and `.exit`
files; both exited zero with three equivalence checks. The latest-day samples
preceded adding the `dense` selection option to the final harness.

Attempt 01 stopped before measurement at an AHK warning dialog; only its verified
benchmark process was terminated. Attempts 02/03 failed in the harness's initial
date comparison against an empty string. The final harness routes warnings to
stdout and selects dates using `StrCompare`. None of those failed attempts is a
performance sample. Optional logger references remain diagnostic warnings in
this standalone include environment.

## Requirements before a production proposal

1. Preserve all manifest fields, date/application membership, and canonical
   equivalence, including days represented only in time-series tables. Do not
   place membership-only or partial cells in `KLPF_MANIFEST_CACHE`.
2. Bind reusable fragments to consumed ledger identities, offsets, modification
   receipts, timing settings and projection format. Classify affected dates from
   the actual consumed SQL; do not assume monotonic event IDs. Missing or
   unclassified provenance must request a complete reconstruction.
3. Publish fragments and provenance atomically. Exercise concurrent workers,
   interrupted writes, rejected replacements, source rewrites/removal and failed
   day reconstruction. Never substitute partial data for a complete snapshot.
4. Keep foreground-only resident time out of durable fragments and preserve the
   resident's isolation. Do not make application-only workers build typing
   manifests merely because they share the reader image.
5. Measure preparation, retrieval, validation, publication, memory and complete
   refresh behavior. Compare against the production path, including cache misses
   and dense or multi-day updates, before claiming an opening-time improvement.

## Synthetic storage and membership prototype

A separate SQLite fixture tested storage and retrieval through the production
SQLite wrapper. It contains 87 days, three synthetic applications per day and
144 time bins per application. It never opens the private journal or real reader
image. Encoded fragments occupy approximately 1.61 MB of assembled JSON.

The prototype uses a fragment table with a JSON-validity constraint and a
singleton synthetic revision row. Updates change the selected fragment and the
revision in one transaction, with DELETE journaling and FULL synchronization.
Three controls passed:

- A pinned reader retains the previous snapshot while another connection edits.
  A competing writer and a blocked commit are refused; rollback preserves the
  old fragment/revision pair.
- Invalid JSON after changing a valid fragment and revision triggers a constraint
  failure; rollback preserves the previous pair.
- Closing an uncommitted writer preserves the previous pair.

These are separate connections in one process. They do not establish recovery
after abrupt process termination, power loss, or races between production workers.
The synthetic revision is not a real ledger receipt or invalidation policy.

The first storage probe, `manifest-fragment-store-prototype-01`, exited zero.
Initial SQL publication took 37.665 ms, excluding payload and SQL preparation.
Its three fragment publication/read-assembly pairs were 6.315/47.153,
5.219/10.414 and 8.690/8.864 ms. Assembled sizes were 1,611,421, 1,611,427 and
1,611,433 bytes as the synthetic revision changed. Every stored fragment and
revision was checked, and every result parsed to 87 dates.

The membership extension obtains application keys using SQLite `json_each` and
`json_group_object`, returning only the small membership object to the AHK
decoder. Full time-series payloads remain encoded. The paired experiment adds
quoted and accented synthetic application names and verifies every membership
key/value against the decoded payload outside the timed region.

| Mode | Sample | Fragment publication ms | Open/read/index/assemble/close ms |
| --- | ---: | ---: | ---: |
| Without membership index | 1 | 6.232 | 46.284 |
| Without membership index | 2 | 4.952 | 8.988 |
| Without membership index | 3 | 6.950 | 8.291 |
| With membership index | 1 | 6.350 | 69.297 |
| With membership index | 2 | 19.705 | 26.050 |
| With membership index | 3 | 5.868 | 28.206 |

Both modes ran sequentially in fresh hidden processes. Each sample opens a fresh
read-only handle in that process; DLL loading and initial fixture preparation
are outside timing. File-system caches are not controlled. The indexed mode
includes decoding the membership objects. Output sizes match across modes:
1,612,030, 1,612,036 and 1,612,042 bytes. All three atomicity controls passed again
in each process. Owned fixture directories were removed after all handles closed.

Receipts in the campaign scratch are
`manifest-fragment-membership-baseline-01` and
`manifest-fragment-membership-index-01`, both exit zero. The final harness is
`manifest-fragment-store-prototype.ahk`, SHA-256
`43B857CA0FF5C02F11CC7F25891DFD3DB1F4C11D1174AF4D043FFE607495B04B`.
Pass `baseline` or `index` after the harness path; use the same hidden AHK,
`/ErrorStdOut`, TEMP and TMP configuration described above.

This remains an isolated feasibility experiment. The next prototype must handle
real consumed provenance, absent or empty caches, multi-day changes, stale
writers, separate-process failures and full reconstruction fallback before any
production integration or complete-refresh performance claim.
