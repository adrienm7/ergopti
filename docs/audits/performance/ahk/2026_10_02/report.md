<!-- docs/audits/performance/ahk/2026_10_02/report.md -->

# Windows startup and interactive performance

## Scope and method

Improve the real Windows tray startup on dev, without pushing. Preserve complete
input readiness, configuration ownership and atomic menu publication. Extend
runtime attribution for prediction rendering and hotstring sends. This is a
Windows performance change. The diagnostic page also changes shared presentation:
translated feature labels sort alphabetically, Open logs stays left, Copy/Save/
Report center, and Refresh stays right. The same page serves all three drivers.

The runtime configuration locator resolves to D:/Documents/GitHub/config/ergopti_plus.
The main evidence log is %LOCALAPPDATA%/ergopti_plus/logs/ErgoptiPlus_2026-10-02.log.
Only the main log was counted, excluding severity mirrors. Existing sessions and
isolated samples below are distinguished explicitly. The resident driver was
preserved; each probe used a uniquely named wrapper and a private configuration
copy. Temporary copies were deleted by the canonical benchmark.

Work completed: recover the real logs, repair collapsed timings, instrument
initialization boundaries, measure isolated starts, remove repeated scanning,
publish usable global commands before feature trees, reproduce an early native
click, and run the selected verification gates.

## Initial evidence

At 10:09:48, pre-logger initialization took approximately 5911 ms, input readiness
was published at process age 8010 ms, and the tray stage took another 765 ms.
At 10:08:51, readiness took 6449 ms and the tray stage took 1766 ms. These are
existing user sessions, not a controlled benchmark.

Most fine-grained marks were withheld by template-based INFO repeat collapsing.
Replayed marks shared a template too, so the original instrumentation concealed
both the expensive phases and their attribution. The old parse-and-load label
also included executable initialization before LoggerInit.

Three initial isolated launches of the real entry with the same configuration
copy took 6610, 6579 and 6248 ms, median 6579 ms and maximum 6610 ms. The initial
tray stage took 891, 781 and 797 ms. Each probe includes the startup-smoke path's
intentional 650 ms message pump; these durations are not direct live-start times.

## Root causes and implemented changes

1. Multiline TOML arrays rescanned the entire accumulated string on every
   continuation. The 35 KB migration registry exposed this quadratic work.
   Carry bracket depth, quoting and escaping across new fragments instead.
   The measured migration phase fell from approximately 1281 ms to 359–375 ms
   in the first instrumented comparison. Preserve the existing parser and
   recovery semantics rather than bypassing registry validation.
2. Comment stripping scanned every character even when no comment marker
   existed. Hotstring counting also treated every payload line as a possible
   section header. Skip those provably unnecessary scans; retain the existing
   file-count and TOML caches, with their existing invalidation owners.
3. The usable root waited for all feature submenus. Publish the manifest's global
   command projection first through the existing root coordinator, dispatcher
   and sole native publisher. Build the full tree afterward on the deferred
   owner. Keep detailed boot publication pending across pause and narrow
   projections until the full tree succeeds. Pause, reload and quit are enabled
   directly at level zero in the early root.
4. Opening the inert Starting menu during boot can suspend initialization and
   delay timers. AHK explicitly disables timers during native menu navigation
   ([upstream SetTimer documentation](https://github.com/AutoHotkey/AutoHotkeyDocs/blob/v2/docs/lib/SetTimer.htm#L62)).
   Publish the actual native Pause/Reload/Quit rows before revealing the icon.
   Pass the first early notification through to Windows without any temporary
   GUI or loading row. Retain subsequent explicit early clicks until full root
   publication, coalescing them into one complete-menu opening. Repeated native
   bootstrap navigation otherwise suspends initialization on every attempt. With
   only one click, publication never opens a second menu. The dispatcher admits
   at most one lifecycle intent until input readiness. Its owner survives root
   replacement, including commands already deferred by the configuration lease.
   First-run setup retains its wizard owner rather than queueing commands in a
   process that never reaches readiness. Native navigation intentionally pauses
   deferred construction until the user closes the menu; AHK cannot progress
   timers behind that native menu. Ready clicks and balloon events keep their owners.
5. Personal shortcut include repair could reload after the tray was revealed,
   causing two visible icon appearances. Settle both parse-time forwarders before
   revealing the icon, and hoist the template getter so early ownership is safe.
   A genuinely missing or changed include still requires one hidden reparse;
   an ordinary reload with current forwarders does not need that repair.
6. Rich prediction controls measured identical styled spans again during drawing.
   Retain exact dimensions within one build and reuse them for prefix, shortcut,
   body pieces and footer controls. Keep independent combined-row sizing and its
   kerning semantics. No GUI handle or measurement cache survives the build.

The new measurements retain every distinct mark, separate source loading from
mutex and include initialization, split migration/configuration/layout work,
and record precise QPC wall time plus process CPU for named phases and menu rows.
Native menu entry and exit are paired in the log, and queued clicks report their
request count and wait. CPU includes every process thread; nested stages overlap
and must not be added together. A negative CPU sample means unavailable.

## Measurement results and limitations

The first three optimized isolated launches at 10:56 took 5141, 4885 and 4709 ms:
median 4885 ms, maximum 5141 ms. This is a 25.7% median reduction against the
initial sample, with the same configuration and intentional 650 ms pump. The
full tray phase took approximately 391–437 ms; early global publication itself
took 15–16 ms. Machine load differed between sampling windows, so this small
sample is directional evidence rather than a reliable p95 estimate.

The user's live retries at 11:07–11:08 already ran the changed code. Global
commands were usable at process ages 4263, 2937 and 3994 ms. At 11:08:42 the
full tray took 1933 ms wall versus 484 ms process CPU; the tap-hold slice alone
spanned approximately 1563 ms. On the next retry, the full tray took 391 ms.
These observations motivated the early-click fix and explicit native-menu-loop
logging. They do not prove all elapsed time was menu navigation.

A later three-sample run at 11:19, concurrent with verification and generator
work, took 8003, 7333 and 6685 ms. It is retained as contention evidence, not
silently discarded or substituted for the earlier comparison. Source loading
alone rose to 1478–1643 ms. Final sequential comparison is recorded below.

### Final sequential comparison

Three quiet baseline samples had median 4246 ms, maximum 4905 ms and minimum
4125 ms. Three sequential candidate samples had median 3756 ms, maximum 3835 ms
and minimum 3620 ms: an 11.54% median reduction in that paired window. These
samples include the same 650 ms pump and precede the final native-only bootstrap.

The final native-only private benchmark had median 2961 ms, maximum 3020 ms and
minimum 2918 ms across three launches. This later window is not the same machine
load as the baseline window; do not attribute its entire difference to code.

Latest live user logs at 12:19 show input readiness at process ages 2193 and
2323 ms. An earlier modeless prototype measured notification lag 31 ms and panel
presentation 44.554 ms, followed by native handoff 609 ms later. The user rejected
that UI, so it is removed; these figures do not measure the final native-only path.
At 13:11:29 the live native-only path admitted an early notification with 15 ms
message lag, logged native navigation 19 ms later, and exited navigation after
16 ms. That reload completed input initialization at process age 3034 ms. This
is notification/loop evidence, not a physical click-to-pixel measurement; no
temporary GUI or subsequent automatic handoff appears with that single click.
The 13:36 reload reproduced the remaining issue: a second bootstrap click paused
initialization for 2187 ms, then another for 1468 ms; readiness arrived at 6971 ms.
The new repeat-click regression failed on the unset notification return before
the correction and passed after retaining repeated requests until full publication.

A native menu loop lasted 1094 ms during that handoff; another lasted 41093 ms.
These are user navigation intervals, not tree-building CPU costs. Move the
handoff after the construction stage's final stamp so navigation cannot inflate
its wall-time attribution.

### Runtime evidence and span reuse

Conditional slow events in the user's log include Tooltip.Present (201 events,
median 6.96 ms, p95 15.49 ms, maximum 43.99 ms), Tooltip.LlmPresent (58 events,
median 16.88 ms, p95 23.55 ms, maximum 31.97 ms), and HSE.Dispatch (72 events,
median 11.54 ms, p95 33.87 ms, maximum 48.56 ms). These distributions are censored
by the 5 ms logging threshold; they are not percentiles of all calls.

An independent native GDI measurement probe compared the ordinary drawing call
with the same call using retained dimensions, in baseline/candidate/candidate/
baseline order, with 20 warmups and 100 samples per group. All 800 geometry
signatures matched. With eight spans, baseline medians were 1.1235 and 0.9944 ms;
candidate medians were 0.0644 and 0.0642 ms. With 21 spans, baseline medians were
3.0057 and 2.5769 ms; candidates were 0.1518 and 0.2130 ms. This isolates the
drawing pass with real GDI measurement and fake control creation; initial sizing
is outside both timings. It does not measure full tooltip reveal or network time.

Add slow subsegments for HSE preflight, output-host resolution and actual native
send, plus rich tooltip construction and the prediction tooltip call. Split
reveal into content, paint and border children; retain their overlapping parent.
Count successful ordinary, destacked and rich surfaces at the common commit
owner, with periodic and shutdown accounting snapshots.

Prediction records retain one request ID and bounded visibility flags. Logs
distinguish exact/prefix cache paths, rate-floor waiting, generation chain elapsed
time, rendering and positive publication receipts. A final-visible batch/cache
receipt is also its first visibility. Generation-chain time includes loading UI,
variants, retries, polling, parsing and intermediate renders; it is not isolated
transport latency. The render segment excludes preceding display-slot preparation.
Cancellation and early-return paths do not yet have a complete terminal timeline.
New subsegment metadata does not include user text, triggers or window titles.

## Budget verdict and rejected shortcuts

- Input and low-level hooks: no new keystroke-path work. Every hotstring and
  prefix index still reaches readiness before ready is published. Input latency
  and hook p99 were not measured by this startup pass.
- Critical spans: full-tree assembly remains outside the short atomic root
  publication. No extra Critical section wraps filesystem or renderer work.
  Critical-span tail latency was not measured separately.
- Tooltip/UI presentation: repeated span measurement is reduced with geometry
  equivalence in the isolated drawing probe. Full physical presentation latency
  after that change remains unmeasured. Native navigation is attributed separately.
- Startup: improved, but a subsecond full-driver start is not achieved. The
  observed source parse and required registration still cost seconds. Warm menu
  opening uses the published native tree and does not rebuild it per click.
- Idle and memory: no recurring startup timer or unbounded request history was
  introduced. Session-long memory and idle CPU remain unmeasured.

Reject a persistent serialized Menu cache: native handles and dispatcher tokens
belong to one process, and configuration/locale/extension mutations require the
existing invalidation contract. Reject skipping migration validation merely
because the configuration version is current. Reject faking ready or deferring
hotstrings and prefix registration. Reject forcing a root replacement into an
open native menu, which would trade ownership and callback guarantees for speed.

AHK timers are deferred work in the same process, not parallel threads. Early
clicks show the actual native root; construction resumes after navigation ends.
The rejected temporary loading GUI is removed. Compiled first-install
extraction, cold disk cache, company-machine load and physical user navigation
after the final click fix are explicitly unmeasured.

## Cross-driver inspection

macOS already caches its generated menu and prewarms its native tree in
macos/ui/menu/init.lua. Linux retains its published menu and drains GTK events
without blocking in linux/adapters/tray_menu.lua and platform/tray/appindicator.lua.
The Lua drivers share toml_codec rather than the changed AHK parser. The Windows
notification and menu-loop behavior is native to AHK; no new platform restriction
or shared feature divergence is introduced. Native macOS/Linux timing was not
measured on this Windows host.

## Regression proof and validation

The new mark-collapse and array-rescan assertions failed before their fixes.
Behavioral fragment tests cover quoted brackets, cross-fragment quotes, nested
arrays and an escape carried into the inserted continuation space. Root tests
cover pending detailed publication under pause. Native-click tests prove unset
notification return on the first click, no GUI callback, no unsolicited second
opening, retained repeat clicks, enabled native
rows, and one accepted command surviving dispatcher replacement. The headless
real-entry smoke posts an actual context notification through an injected owner
and requires a running timer before readiness, then usable native global commands
without a loading/status row before the feature tree. It includes
restored-paused and migration fixtures. The smoke and benchmark copy driver code
and isolate LOCALAPPDATA before parsing both personal includes. The smoke asserts
unchanged production forwarders; both tools detach private junctions and
asynchronously remove fixtures.
Earlier wrappers resolved the production forwarder and temporarily rewrote it;
that flaw was diagnosed, the canonical generator restored it, and the fixture
owner now prevents recurrence.

Headless cancellation tests directly cover scheduled navigation admission;
their pre-fix executions were not recorded. Span drawing and collapsed-timing
regressions have recorded red/green evidence. Request receipt tests cover stale
IDs, refused publication and bounded first/final streaming visibility.

Validation used the change-scoped planner, Node 22.22.2 and AutoHotkey v2:

- Native bootstrap focused suite: 13/13 passed. Complete suite: 7716/7716 passed,
  with the captured stdout manifest checked for every planned result and duration.
  The file mirror dropped three lines during a concurrent progress read; its
  validator correctly refused completeness. The independent stdout is complete.
- Full real-entry startup smoke: passed fresh, reloaded, independent, paused,
  extension opt-in, script-chord, neutral-default and older-release fixtures.
- Whole production include graph compiled; expansion e2e passed 5/5.
- Encoding: 1768 AHK files passed UTF-8 BOM/LF checks. Strict conventions passed.
- All 28 declared hot-path segments and 19 early stamps have emitters.
- Shared diagnostic model/page tests passed, including 167 labels in 21 locales
  on three driver snapshots. Independent locale-collation review passed.
- Changed Prettier-owned files pass formatting. The full format gate remains red
  on 15 unchanged baseline files and the installed Ruff version (0.15.11 versus
  required 0.15.8); unrelated files were preserved.
- The JS suite executed 349 checks: 343 passed and six failed. All six were
  reproduced on the initial baseline: Linux installed-layout discovery with
  Windows Lua paths, macOS signing Bash replay, Ollama bootstrap Bash timeout,
  Ollama shared-network-policy path resolution, release-install Windows paths,
  and the missing Python interpreter for HS-274. These remain unresolved host/
  baseline gates; the overall selected verification run is not all green.

The complete AHK suite initially exposed a stale source-scanning assertion for
the old one-argument reveal call. Its signature-aware correction preserves the
nonempty-body, navigation-order and ownership guards; the focused four cases
passed. A later local launcher hit Node's default output-buffer limit and was
rerun with a sufficient buffer; truncated execution is not counted as a pass.

For reproducible measurements, use Node 22.22.2 and AutoHotkey v2:

```powershell
node tools/dev/bench-ahk-startup.cjs --config-dir=D:/Documents/GitHub/config/ergopti_plus --samples=3
node tools/test/verify-change.cjs
```
