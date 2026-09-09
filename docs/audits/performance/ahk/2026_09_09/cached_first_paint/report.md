# Cached metrics first paint

## Scope and provenance

Measured on 2026-09-09, Windows, baseline `940b971f9`. The derived reader
image was opened with `SQLiteConst.OPEN_RO`; no ledger or private payload was
modified or exported. Image size: 685,060,096 bytes. Physical RAM: 7,274,124 KiB,
with 1,506,152 KiB available before sampling. No parallel local test suite ran.

Three fresh hidden AHK processes measured `KLR_ReadManifest` followed by
`KL_JsonEncode` using QueryPerformanceCounter. Each encoded result contained
1,811,993 UTF-16 characters. The local reproduction is
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08/probe-manifest-phases.ahk`,
run with `AutoHotkey64.exe /ErrorStdOut`. Receipts are `manifest-current-1.out`
through `manifest-current-3.out` and `manifest-cached-ready-1.out` through
`manifest-cached-ready-3.out` in that directory. They contain timings and counts,
not private payloads. The probe also times a historical encoder candidate;
that candidate was not changed or shipped in this pass.

| Phase | Before median / maximum | After median / maximum |
| --- | --- | --- |
| Manifest projection | 1256.47 / 1338.41 ms | 1228.48 / 1233.80 ms |
| JSON encoding | 888.45 / 890.35 ms | 890.45 / 897.24 ms |

The backend is unchanged. These small sample differences are not evidence of
faster projection. Three samples do not establish a useful p95 or p99.

## Confirmed redundant work

`KLWV_OnWebMessage` already delivered the disk sidecar on `ready`, including
when the resident JSON cache was empty. However, it did not commit first-paint
completion. The 1500 ms fallback then saw empty resident RAM and requested a
manifest worker. Its completion scheduled a full worker after another delay.
Disposable workers populate their own JSON cache, not the resident process's.

The change commits successful cached delivery and schedules the deferred full
refresh immediately. The existing fallback sees completed first paint and does
nothing. A running worker retains completion ownership; failed or stale delivery
still takes the existing retry path. A cached payload never establishes that a
fresh full build has completed.

Four behavioral tests in `test_metrics_cached_ready.ahk` exercise real sidecar
reads with empty resident RAM: delivery, refusal, recipient replacement, and an
existing worker. Before the change, successful delivery left first paint false;
afterward it is true, the fallback performs no additional delivery, and duplicate
`ready` schedules no duplicate full timer.

## Limits and next work

This removes a redundant manifest worker; it does not claim measured
open-to-painted latency, instant opening, or an improved keystroke budget.
WebView construction, browser rendering, full-range projection, worker startup,
and incremental reader refresh remain unmeasured in this pass.

The same sidecar is still replaced by full, manifest, and live payloads.
Manifest/live payloads do not carry all historical range data, so reopening can
still need the background full projection before historical tables populate.
Persisting a complete snapshot needs an explicit freshness and invalidation
contract, not merely a second filename.

An additional read-only probe measured 5653 five-minute rows, 4172 empty JSON
histograms and 243 distinct JSON strings: query 157.48 ms, histogram merging
384.13 ms, whole five-minute projection 589.50 ms. This is one diagnostic sample,
not a benchmark distribution. Empty histograms already bypass JSON parsing;
adding another empty-object fast path would do nothing. No histogram cache was
added without measuring its retention cost and invalidation contract.
