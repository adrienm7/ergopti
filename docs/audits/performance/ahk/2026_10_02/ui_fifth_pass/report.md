<!-- docs/audits/performance/ahk/2026_10_02/ui_fifth_pass/report.md -->

# Windows UI opening latency

## Scope and plan

The requested extension covers typing/app metrics and system diagnostics. Work
stays on `dev`, with local commits and no push. The earlier menu and input
changes have separate reports. This pass measures browser setup, retains bounded
native hosts, proves session retirement and fresh documents, then runs the
driver and shared-page gates. The live driver and its configuration are not
reloaded or modified by the probes.

## Baseline from the live log

The source is `%LOCALAPPDATA%/ergopti_plus/logs/ErgoptiPlus_2026-10-02.log`;
times below are event timestamps on October 2, not the log filename's meaning.

| Diagnostics request | Collection completion          | Host opened  | Page ready   |
| ------------------- | ------------------------------ | ------------ | ------------ |
| 14:13:08.682        | 14:13:08.709, reported 5.3 ms  | 14:13:09.646 | 14:13:09.760 |
| 18:12:08.563        | 18:12:08.625, reported 32.5 ms | 18:12:09.292 | 18:12:09.429 |
| 18:19:00.676        | 18:19:00.690, reported 12.1 ms | 18:19:02.246 | 18:19:02.388 |

Collection is much smaller than the browser/window interval. The collection
clock excludes the first parsing of static diagnostics documents; its number
must not be substituted for total request latency. The last request took about
1.71 s until the page announced readiness, despite a 12.1 ms collection.

Metrics already navigate before the detached data projection. Their 30–90 s
worker warm-up is a different measurement. This change does not claim to make a
cold historical projection instantaneous or remove its correctness checks.

## Native experiment

Windows 11, AutoHotkey v2.0.26, the vendored WebView2 wrapper and installed
Chromium runtime. Private profiles under `%TEMP%`, hidden native GUIs, readonly
virtual-host mapping of the real shared pages; no foreground changes, keyboard
output, live profile reuse, metrics writes or production entry launch.

`%TEMP%/ergopti-ui-native-pages.ahk` executes baseline/retained/retained/baseline
for each page. Each block has one initialization sample followed by three
retained samples: six observations per mode/page. QPC measures environment and
controller acquisition, cache invalidation, navigation and the real page's
`ready` bridge message. Metrics baseline recreates the browser profile each
time; diagnostics baseline retains its environment but recreates controllers.
The candidate retains its controller and clears browser resources before each
new document. Initial samples are printed separately, not hidden as warm data.

The first run overlapped the focused AHK source-loading checks. Its results are
exploratory, including both roughly one-second outliers; they are not a
controlled unloaded-desktop latency guarantee. Its raw output is preserved as
`%TEMP%/ergopti-ui-native-pages-exploratory.out`.

The final paired run followed completion of all test subprocesses, with no
concurrent agent benchmark or gate. The user's existing driver remained active.
Its raw output is `%TEMP%/ergopti-ui-native-pages.out`; all six retained samples
per mode are below. Native windows remained hidden: browser readiness is measured,
not compositor paint or complete historical dataset rendering.

| Page           | Baseline retained samples, ms                        | Candidate retained samples, ms                     |
| -------------- | ---------------------------------------------------- | -------------------------------------------------- |
| Diagnostics    | 203.998, 185.620, 199.239, 188.680, 192.668, 183.046 | 76.871, 62.081, 78.530, 76.135, 77.551, 106.951    |
| Typing metrics | 579.642, 621.456, 654.055, 588.362, 598.897, 589.989 | 140.747, 92.837, 125.377, 138.213, 124.336, 93.076 |
| App metrics    | 604.480, 601.919, 581.353, 700.565, 620.053, 635.691 | 123.522, 121.855, 109.903, 122.222, 91.599, 90.887 |

Medians are 190.674 → 77.211 ms for diagnostics, 594.443 → 124.856 ms for typing,
and 612.266 → 115.879 ms for apps. Cache-clear calls cost 8.472–37.533 ms in these
warm samples. The candidate's separate initialization samples cost
590.769–636.264 ms across the three real pages. The first Chromium/controller
creation still costs hundreds of milliseconds. No hard bound of 100 ms, or
instant first opening after reload, is established.

## Mechanism and ownership

- Metrics retain at most one inactive native host for each of `typing` and
  `apps`. Inactive hosts are absent from `KLWV.windows`; workers, live ingestion,
  rebuild watches, ranges and messages cannot treat them as open dashboards.
  The cache holds only GUI, controller, WebView, profile path and reuse identity.
- Diagnostics retain one hidden singleton, retire its epoch, cancel probes and
  release the native message subscription. A new opening collects a fresh
  snapshot, resets opt-in details and mode through a fresh page, and binds new
  callbacks. It does not reuse an old diagnostics snapshot.
- Reuse requires a live native HWND, the same locale and shared asset root;
  metrics also require the same metrics directory. Locale/store changes dispose
  the former owner. HWND checks include hidden windows independently of AHK's
  per-thread search settings.
- A new document has a unique epoch in its URL. Browser messages validate their
  source URL; native scripts validate `location.href` before application work.
  All four metrics envelope producers attach `host_epoch`; both actual frontend
  listeners reject obsolete or missing epochs when the document is owned.
- Opening and retirement have separate admission guards. Requests during
  retirement are retained until cleanup finishes. A close during asynchronous
  native creation retires the completed transaction rather than reopening the
  UI behind the user's back. Diagnostics request serials also prevent an
  already scheduled predecessor from overriding a newer open or close.
- Reload/shutdown closes both active and inactive metrics hosts and the
  diagnostics singleton. Profile retirement still waits for confirmed browser
  exit. No fixed-delay deletion, unbounded pool or persistent snapshot cache is
  introduced.

Retaining controllers trades bounded Chromium memory for faster reopening.
The first request after reload still performs native creation. No startup
prewarming of three browser surfaces is introduced without memory and input
latency evidence. New info logs separately record host shown, controller
prepared and page ready, with reuse status; no typed content is logged.

## Cache invalidation evidence

A private native fixture rewrites a referenced JavaScript asset with the same
size and modification timestamp between navigations. With a retained
controller, the second document read the first value. Disabling the network
cache alone also reproduced the stale value. A successful native
`Network.clearBrowserCache` before navigation gave values 1, 2, 3 and 4 in the
four corresponding documents. Receipts:
`%TEMP%/ergopti-ui-native-assets.out`,
`%TEMP%/ergopti-ui-native-assets-after.out`, and
`%TEMP%/ergopti-ui-native-assets-cleared.out`.

The shared Windows helper has one finite timeout, logs both success and refusal,
and propagates failure to the host's existing unavailable/native fallback. It
does not bless stale assets after a refused invalidation. The method is part of
the [Chromium DevTools Network protocol](https://chromedevtools.github.io/devtools-protocol/tot/Network/#method-clearBrowserCache).

## Production lifecycle proof

`%TEMP%/ergopti-ui-production-native.cjs` extracts the current production
diagnostics lifecycle functions into a disposable native fixture. It substitutes
only a hidden GUI factory, private environment/profile, minimal page/snapshot,
logs and inactive network probes. Real WebView2 controllers and callbacks run.
It asserts the same controller/HWND over four openings, monotonically fresh
snapshot nonces, hidden retired sessions and idempotent final destruction.

The latest receipt is `%TEMP%/ergopti-ui-production-native.out`: first opening
894.744 ms, subsequent snapshot deliveries 86.830, 66.566 and 74.210 ms. These
are a minimal-page component/lifecycle fixture with concurrent suite startup,
not the full user's diagnostics render. Earlier unloaded fixtures recorded
about 61–87 ms for reopening the same mechanism.

`%TEMP%/ergopti-ui-production-early-close.cjs` additionally closes during the
first native creation and verifies that the resulting retained host is hidden,
has no live session/subscription and can reopen normally. Its latest receipt is
`%TEMP%/ergopti-ui-production-early-close.out`; all lifecycle assertions passed.
That run includes a 1096.851 ms reopening outlier, alongside 122.672, 74.363
and 79.108 ms; the fixture proves lifecycle correctness, not a hard latency bound.

## Platform scope

The retained native HWND/controller and profile ownership fix is specific to
Windows WebView2. macOS uses WKWebView and Linux uses WebKitGTK; they cannot use
this native mechanism. Their metrics and diagnostics capability remains
available. The shared frontend accepts existing unowned host envelopes and
enforces document ownership when Windows supplies its epoch; actual listener
tests cover both shapes. No feature is newly unavailable on another platform,
so no disabled menu reason is added.

## Verification

The new retention source assertion failed against the previous implementation:
manual close destroyed the diagnostics host. Behavioral tests verify hidden
HWNDs, exact GUI ownership, probe cancellation, subscription retirement,
configuration invalidation, single disposal, request admission, bounded cache
invalidation and document fences. Actual shared listener execution tests reject
queued predecessor envelopes for both dashboards and preserve the existing
host delivery shape.

The first complete run found native-call and platform-call purity increases.
These were corrected through the existing clock/timer adapters and a hidden-HWND
window adapter helper; neither ratchet baseline was raised.

The final targeted retention, purity, platform-family and lifecycle-log tests
pass. The complete production include graph compiles; pure expansion E2E is
5/5. All 1776 AHK files pass the encoding gate, and strict conventions report
no violations. Changed HTML, JavaScript and documentation pass Prettier.

The serial complete AHK run passes 7760 tests, zero failed. Its execution
manifest confirms exactly 7760/7760 terminal results. Earlier incomplete runs
are excluded; no competing `run_all.ahk` process ran during this final receipt.

The full JS gate is 343/349. Its six failures match the previously reproduced
baseline/environment failures recorded in
[the preceding menu report](../menu_third_pass/report.md): Windows Lua installed
layout discovery, macOS signing shell replay, Ollama bootstrap and server
ownership, release-install path normalization, and the HS-274 Python runtime.
The drift-perturbation check passes in this run. Full formatting still refuses
fifteen untouched files and installed Ruff 0.15.11 versus required 0.15.8.
Neither broad gate is reported green.

Receipts: `%TEMP%/ergopti-ui-fifth-js.out`,
`%TEMP%/ergopti-ui-fifth-format.out`, the `ergopti-third-focus-*` TAP/output
receipts and `%TEMP%/ergopti-third-pass-e2e.out`.
The final AHK receipt is
`%TEMP%/ergopti-final-ahk-ui-fifth-serial-green.{out,tap,manifest.json}`.
