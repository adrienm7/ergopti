# Sixth startup and dashboard filter pass

## Scope and plan

Continue on `dev`. The user subsequently authorized pulling the latest remote
commits, integrating these local changes and pushing the complete branch.
Read the live Windows logs, distinguish
native menu navigation from actual boot work, remove repeated catalogue priority
resolution, and retain bounded dashboard filter projections. Preserve native
menu behavior, source selection, generation invalidation and range ownership.

1. Establish live boot evidence and private baselines.
2. Implement precise pre-logger resource stamps and native menu wait accounting.
3. Resolve cached hotstring section priority once per build, with individual overrides intact.
4. Cache the actual shared dashboard scripts and invalidate accepted native mutations.
5. Retain bounded fast-path distributions and attribute dashboard and shutdown stages.
6. Remove repeated native PNG decoding with generated, pixel-equivalent bitmaps.
7. Correct editor preference ownership and logger repeat reentry revealed by measurement.
8. Prove equivalent output, benchmark misses and retained queries, and run selected gates.

The Windows startup changes concern its AHK lifecycle. The dashboard scripts are
shared by Windows, macOS and Linux, so the filter optimization applies to all
three without a second implementation. No live driver, live configuration or
user input was changed by measurement probes.

## Live evidence

Logs resolved through `%APPDATA%/Ergopti/paths.toml` to
`%LOCALAPPDATA%/ergopti_plus/logs/ErgoptiPlus_2026-10-02.log`.
These are line timestamps on October 2, 2026, Europe/Paris, not filename dates.

At 20:06:47, first auto-execute was 754 ms and the pre-logger window 1,004 ms.
The configured menu was ready at 1,567 ms. A native menu opened at
20:06:48.529 and closed at 20:07:01.141, interrupting boot. The keyboard-hook
stage consequently reported 12,615.560 ms wall time but 234.375 ms process CPU.
This reading interval explains most of the 15,161 ms wall-clock ready time;
it is not keyboard-hook construction latency. Native navigation legitimately
keeps AHK in the Windows menu loop. The new logs retain total wall time and
separately identify the overlapping navigation interval.

The previous boot at 20:05:28 reported menu ready at 1,273 ms and driver ready at
4,089 ms. Its prefix watcher took 2,034.378 ms wall but 187.5 ms process CPU,
another reason not to attribute every stall to catalogue computation.

## Catalogue measurement

A private, no-tray, no-hook AHK probe copied the original and current production
functions and loaded the real bundled TSV: 2,911 rows across 21 enabled sections.
Four warmups preceded five ABBA rounds, ten samples per implementation. QPC
measured wall time; `GetProcessTimes` measured process CPU. Line history was
disabled equally for both implementations in this isolated probe. The user’s
live driver remained running; this is catalogue latency, not complete startup.

| Metric                 |         Original |        Optimized |
| ---------------------- | ---------------: | ---------------: |
| Wall median            |       83.8705 ms |       54.1080 ms |
| Wall range             | 83.288–88.640 ms | 53.388–55.572 ms |
| Process CPU median     |       85.9375 ms |       54.6875 ms |
| Counted resolver calls |            4,984 |               21 |

All 4,896 prefix keys and 2,847 trigger keys were equivalent field by field,
including array order. A second, more contended earlier series had a candidate
maximum of 612.026 ms; scheduler/load outliers still exist and the isolated
catalogue saving does not guarantee a sub-second complete boot.

Private evidence directory:
`%TEMP%/ergopti-prefix-priority-7acb57e42eba4fdd9c94ab70927dea28`.
Files include `result-production.txt`, `resolver-proof.txt`, and
`menu-clock-proof.txt`. The reviewed production source SHA-256 was
`72b7231360f1029a11dd898054afa15b4b1295fad5fa030b9ea44bc9381dfc31`.

## Rejected line-history experiment

The real-entry fixture ran four ABBA blocks of four launches, retaining cold
sample zero and three warm samples per block. Disabling `ListLines` did not
produce a consistent startup gain. Cold ready times were 2,209/2,416 ms for the
control and 2,238/2,246 ms for the candidate. Warm ready ranges were
2,011–2,396 ms and 1,989–2,492 ms respectively. Production line history remains
available. Private receipts are `%TEMP%/ergopti-sixth-listlines-*.jsonl` and
`%TEMP%/ergopti-sixth-listlines-receipt.json`.

## Filter cache contract

Apps retain four complete query projections in an LRU: current query,
comparison and two recent filters. Keys cover period, anchor date, canonical
category/weekday sets (empty differs from unrestricted), awake counting and
locale. Manifest, category and translation owners guard replacements; accepted
bootstrap, category updates and in-place live pushes explicitly invalidate.

Typing retains two projections, current and previous. Keys cover source mode,
case sensitivity, dates, local day, selection mode and sorted selected apps.
Live app discovery occurs before key construction. Accepted range responses,
live pushes and Reset invalidate; rejected stale range responses do not.
Owner checks additionally catch source replacement. Pause thresholds, layout
and manifest-only KPIs always rerender without unnecessarily merging n-grams.
No native selected-range response is reused across requests without a data epoch.

`window.appsFilterPerformance` and `window.typingFilterPerformance` expose
hits, misses, retained entry count and last miss aggregation milliseconds,
measured with the coarse browser `Date.now` clock. They contain no input text,
app names or selected filters. A hit records zero aggregation time because it
skips aggregation; this is not a measurement of total UI rendering.

## Latest user reload evidence

The supplied diagnostics were generated at 20:48:45 against local commit
`48b52f25d`. New live logs show configured menu readiness at 1,405/1,568/1,455 ms
for the three boots at 20:46:53, 20:46:57 and 20:48:33. Keyboard-hook stages
took 5.270/4.302/3.787 ms. The last prefix stage took 10,647.620 ms wall,
218.750 ms process CPU, including 10,381.212 ms inside native menu navigation;
wall time without that navigation was 266.408 ms. The 12,881 ms ready line
therefore does not describe ten seconds spent building the prefix index.

The first typing dashboard at 20:47:09 showed its native host in 230.95 ms,
prepared its controller in 1,319.77 ms and reported page ready in 1,518.82 ms.
A background language-menu batch took 344.87 ms during controller preparation.
These overlapping intervals must not be added. Background population now runs
at priority -1, so it cannot interrupt a foreground controller wait. Requested
native leaf menus still finish synchronously before paint.

## Retained filter measurement

A private Node VM loaded the production dashboard scripts with synthetic data.
Apps used 365 days, 15 apps and eight hourly slots, totaling 5,475 rows. Typing
used eight tabs with 15,000 entries plus case, control and NBSP variants. After
two warmups, each mode had twelve samples. Original and candidate query outputs
were equivalent for five apps queries and eight typing modes.

| Projection | Original median | Candidate miss | Candidate retained hit | Maximum retained hit |
| ---------- | --------------: | -------------: | ---------------------: | -------------------: |
| Apps       |       230.44 ms |      218.20 ms |              0.0058 ms |            0.0133 ms |
| Typing     |       230.24 ms |      230.15 ms |              0.0107 ms |            0.0122 ms |

Rendering and chart adapters were stubbed while their call counts were checked;
612 rendering calls still occurred. These numbers measure projection work,
not DOM rendering or visible filter latency. Cold misses remain essentially
unchanged. Receipt: `%TEMP%/ergopti-metrics-cache-independent-benchmark.cjs`.

## Native language icon measurement

Twenty-one PNG flags repeatedly invoked the native decoder. The canonical
`tools/locale/generate_flags.py` now emits top-down 32-bit BI_RGB bitmaps with
opaque BGRA pixels beside the authoritative PNGs. `--native-only` converts the
existing PNGs without redrawing them. PNGs remain available to the other
surfaces. Windows uses BMP paths; packaging retains the complete flags directory.

Six fresh invisible menus at the machine's 125% DPI took a median 115.2361 ms
with PNGs, maximum 134.2846 ms; actual generated BMPs took a median 5.9033 ms,
maximum 7.3739 ms. Every native RGB and alpha byte matched for all 21 icons,
including the resulting 20x15 dimensions. This is roughly 19.5 times faster
for icon construction, not for the complete menu or application startup.

An initial Pillow 24-bit BMP conversion was rejected: native scaling changed
RGB pixels and lost opaque alpha despite matching original image RGB bytes.
The 32-bit owner fixes that mechanism. The JS gate checks every authoritative
pixel, dimensions, top-down rows and alpha; the native probe additionally
checks the scaled Win32 menu bitmaps. Evidence directory:
`%TEMP%/ergopti-generated-flag32-verify-7tkv5s`, with `benchmark.ahk` and
`pixels.ahk`. Bundle mutation coverage now drops both PNG and native BMP assets.

## Bounded instrumentation and its cost

All existing hot-path segments now retain fast and slow samples: count, sum,
minimum, maximum, slow count and buckets at 1/5/10/50 ms. The same mechanism
retains tooltip substeps, even when their parent remains below the warning
threshold. A 128-label limit bounds memory; refused new labels are counted and
the first refusal is visible. No callback detail or input content is retained.

A priority -1 timer publishes summaries every 60 seconds, and the logger exit
handler publishes the last window before its durable flush. Snapshot exchange
is atomic; logging happens outside the transaction, and a nested callback
records in the next window. Individual slow warnings remain immediate. These
are distributions and tail counts, not exact individual latency percentiles.

Pre-logger stamps now separate wall and process CPU time. Boot stages report
overlapping native menu wait separately. Dashboard opening attributes host,
profile, controller, bindings, mount and navigation. Diagnostics opening
attributes snapshot, host, controller, bindings, navigation and native controls.
Shutdown attributes preparation, hook, watchers, sensors/timers, flush/journal,
categories, ingest/state and file closure. Labels are fixed developer names.
Native leaf warnings identify the list and remaining rows, without input text.

Private AHK measurement used independently renamed HEAD and working functions,
no hooks, GUI, driver or summary timer, `ListLines(false)`, four warmup rounds
and six ABBA rounds: twelve samples per mode, 50,000 pairs or 2,000 synthetic
tooltip transactions per sample.

| Synthetic instrumentation | Original median | Candidate median | Additional cost |
| ------------------------- | --------------: | ---------------: | --------------: |
| Fast QPC/profile pair     |       2.9483 µs |        9.6140 µs |       6.6657 µs |
| Parent plus 20 substeps   |     136.9002 µs |      284.6289 µs |       0.1477 ms |

Maximum batch averages were 4.6254/10.9546 µs for the pair and
203.9448/461.5418 µs for the tooltip transaction. CPU medians confirmed the
cost. These are batch averages, not individual callback p95 values. The final
probe retained 22 labels with zero refusals, 612,000 pair samples and 24,800
tooltip samples; caller critical state returned to zero. Evidence directory:
`%TEMP%/ergopti-hotpath-bench-39fa365de91449e1a7ac5b7af50ef46f`.

## Errors exposed by the measurements

Private real-entry measurement exposed an interrupted logger repeat eviction:
the flush timer could remove the selected victim before `Map.Delete` resumed.
Selection, detachment and incoming-owner publication now share a short atomic
transaction, while summary I/O follows release. The deterministic regression
failed before and passed after. Shared Lua had the analogous sink reentry
problem: an eviction summary callback could create the incoming streak before
the outer call overwrote it. Publishing first fixes that once for macOS/Linux;
the shared corpus proves both nested repeats survive.

Live config errors named `personal_editor.compact_view`. At 20:58:45 the logger
reported 584 more failed collector attempts over ten minutes. All three known
editor preferences now retain their exact editor owner rather than entering
the manifest-backed feature tree. A full-save regression fails against HEAD
(three preferences applied) and passes against the corrected loader, including
the real collector and `TOML_BatchWrite`. A supplemental HEAD probe reproduces
`Unknown configuration path: personal_editor.close_on_add` from the same tree
pollution. Unknown misspelled preference keys remain eligible for cleanup.
Evidence: `%TEMP%/ergopti-editor-owner-proof.cjs` and fixture directory
`%TEMP%/ergopti-editor-owner-proof-eubarh`.

The live watcher shutdown debt remains a separate issue. A private chain probe
shows that stopping the hook invalidates the foreground safety verdict, so a
later accepted session close can be refused by the privacy predicate. This
matches the mechanism of the live `watchers=0` report, but its exact live cause
was previously unlogged. This pass adds explicit refusal/error and stage timing
evidence. It keeps producer shutdown before draining and retains privacy checks.
A follow-up fix must qualify only frozen, accepted `idle_end`/`session_end`
ownership and revalidate at central queue commit; a generic shutdown privacy
bypass or a retained stale foreground verdict is unsuitable.

## Validation and remaining measurements

The regression suite loads the apps
scripts referenced by `index.html`, rather than its legacy bundled `script.js`.
Behavioral checks cover retained queries, canonical sets, comparator anchors,
bounded eviction, native updates, locale, live discovery and stale ownership.

## Complete log review and diagnostic admission

The five-day inventory contained 17 log files, approximately 5.007 MB and
40,881 lines. All files were read; errors-only mirrors and repeat summaries
were distinguished from actual duplicate work. The 159 sessions include 56
on October 2. Four were replaced before readiness; distinct PIDs do not prove
double initialization. The latest completed sessions contain one initialization
per owner. Catalogue refresh did repeat within 23 and 34 ms through native
navigation completion plus page readiness. Windows and macOS now claim one
readiness epoch per window; explicit refresh remains available. Linux has one
page-ready path, so its bridge needs no duplicate native-notification fix.

At 21:31 the first diagnostic selection waited another 1,172 ms for unrelated
input initialization. Snapshot preparation took 123.6 ms, host creation 23.8 ms,
controller creation 1,247.2 ms wall but 62.5 ms CPU, bindings 99.1 ms, and page
readiness 1,624.6 ms overall. The read-only diagnostic now has an independent
cleanup-readiness certificate. Mutating menu commands retain their original
input-readiness gate. Early exit still rejects accepted persistence debt.

A shared browser is prewarmed asynchronously on a real hidden 600x400 control,
after its single shutdown owner is registered. Environment construction alone
does not start Chromium. A message-only HWND was rejected after unstable
browser identity and no repeatable gain. Foreground demand joins the exact
background promise; nested foreground waits still fail explicitly. Late native
completion cannot publish after shutdown and closes before its host is retired.

An isolated production-class probe, with unique profiles and no input hooks,
used three cold and three warm demands in balanced order. Cold controller
median was 860.749 ms, maximum 931.313; warm median 158.464 ms, maximum 166.583.
Warm dispatch itself took 10.705–16.704 ms. All three warm browser identities
remained stable and all owned exits were observed. This was measured during
other tests and covers controller availability, not complete page paint.
Receipt: `%TEMP%/ergopti-sixth-production-warm.out`. Probe-only missing-function
warnings were captured to stdout; they do not describe the production include
graph, whose parse gate is checked separately.

The complete log review expands the editor failure population to 2,508 attempts
between 20:48:45 and 21:31:55, represented by ten collapsed lines. The corrected
owner addresses the same confirmed failure. Watcher shutdown debt occurs in
18 sessions today and 70 over five days; it remains an instrumented, separate
persistence/privacy issue, not a claimed duplicate-registration fix.

Metrics backend work remains a material limit: 72 completed workers today had
typing/apps database medians 27.843/28.031 seconds and total medians
37.687/30.766 seconds. Cached UI attachment was 14–16 ms. Different ledger
epochs prevent calling independent worker deltas duplicate operations. A frozen
database shared within one disposable warm batch is a future measured candidate;
this pass's retained filter projections do not solve cold database preparation.

## Trigger preview scheduling and stable placement

Eight real previews at 22:12–22:13 had mean build 4.105 ms, maximum 6.757;
mean presentation 5.620 ms, maximum 11.031; mean position resolve 0.125 ms.
The fixed 150 ms prefix wait plus 75 ms tooltip wait contributed 225 ms before
that work. Both now coalesce on the next timer turn, using 1 ms requested delays
which remain subject to Windows timer resolution. GUI work stays off OnChar.

The user's live ChatGPT trial exposed the first implementation's fallback
reveal followed by precise movement. That behavior was rejected. A 300 ms,
priority -1, idle-only position prewarm now supplies bounded, exact-control and
monitor/work-area/DPI receipts. Native-caret and retained-position renders can
proceed immediately. A cold caret-less first request stays hidden during the
200 ms provider-admission wait and reveals once at the validated position;
this cold case is not advertised as zero latency. Timeout or a hostile provider
may use a stable fallback, never a later cross-screen move of visible pixels.

The position continuation retains the exact request, decision items, generation
and physical input intent across the trigger key release, freezes the physical
epoch at worker admission, and revalidates context before the resumed render
and final pixel commit. Accepted bounds immediately populate the position cache.
Cancellation retires only its exact pending tuple, preventing abandoned output
from holding an older surface's expiry open. Startup retries are bounded by the
existing worker deadline; synchronous terminal refusal cannot restart an owner.
All original row deadlines and prediction ownership remain intact.

New aggregate labels attribute prefix/render queues, decision collection,
preview metadata, input-to-visible time and position waiting without logging
input text. Dynamic replacement callbacks remain a possible contributor to
the originally reported second; the new decision measurement covers that work.

## Rapid magic-key admission

The user's failed trigger followed by the magic key was not explicitly logged.
The 22:56–23:07 interval contains successful dispatches, but no-match attempts
had no INFO-level outcome evidence. The `title_timeout` warning at 23:06:49.183
was followed by a successful `ct` dispatch and 9.26 ms native send, so that
warning alone does not identify the reported failure.

A private actual-callback probe reproduced a silent ordering defect: while the
last trigger character yielded in pre-feed work, a timer delivered the magic
key first. HSE received `c★t`, produced no send and raised no exception.
Sequential `ct★` sent exactly once with zero painted preview decisions.
An attempted character FIFO was rejected: it produced apparently correct HSE
state but lost an already-visible trailing character during backspacing.

The Windows watcher now serializes admission before pre-feed work. Its AI
context edit is bounded RAM work; file-backed agent configuration, observer
notification, transport cancellation callbacks and prediction rearming are
deferred under one coalesced owner. Synchronous request invalidation prevents
stale responses while that owner waits. Exact focus, physical input, lifecycle,
bridge mode and owner identity are revalidated before cancellation or publication.
Live-mode expansion reissue uses the same deferred owner. The existing paced
selection-wrap path restores the scheduler and revalidates its context before
ordinary matching resumes. macOS event-tap ownership and Linux's synchronous
input pipeline do not share the AHK callback-reentry mechanism.

The real watcher regression uses a timer-controlled slow pre-feed seam and a
recorded atomic sender: `ct★x` expands once, retains `x`, and keeps screen and
HSE state equal, without a keyboard hook or tooltip. Other cases cover coalescing,
agent-only mirroring, stale focus/lifecycle/mode, and refusal to cancel newer
agent, prediction or transport owners. The original private callback proof is
retained under `%TEMP%/ergopti-fast-magic-admission-probe-20261002`.

New `HSE.Magic.<outcome>` numeric samples count sent, no-match, disabled,
paused, focus-refused, dispatch-refused, pending and terminal-replay attempts
without storing input text. `LLM.PrefixMirror`, `Prefix.FocusAdmission` and
`LLM.PrefixObservers` distinguish ordered RAM admission from ancillary work.
Recent normal native sends were approximately 8–24 ms; no arbitrary pacing or
output-host safety gate was removed to manufacture a faster send.

The later live preview summaries still show a cold-position tail: at 23:41,
19 previews averaged 75.260 ms with a 400.780 ms maximum; at 23:49, 34 previews
averaged 23.714 ms with a 315.191 ms maximum. Most previews have improved,
but this evidence does not establish instant presentation for every application
or a sub-second complete first launch. The controlled regression suppresses
visual previews explicitly and checks that no native worker leaks into the
following suite. Clearing only the prefix index was insufficient because the
canonical engine can still resolve a preview.

## Final gate provenance

Changed shared logger cases pass on Windows-host Lua 5.4.6: macOS 31/0,
Linux 43/0; changed macOS layout-manager cases pass 2/0. Original HEAD's full
Linux suite reproduces all 39 current failures with matching assertions
(4,558 passes before, 4,559 after). Original macOS's 12 affected modules
reproduce all 54 current failures; its full archived attempt reached its
explicit 600-second cap. This is baseline causality, not native OS certification.
Evidence: `%TEMP%/ergopti-lua-head-baseline-0Pst7E/comparison-details.json`.

The private native bundle gate validates all 21 BMP pixel payloads, 258 tracked
bundle files and eleven destructive manifest mutations. Actual full AHK, E2E,
JS, encoding and convention receipts are retained in the private sixth-pass
gate files.

Integration rebased all local atomic commits onto remote dev, first at
221fb7648 and then at 14c9e332b. The measured-span painter retains the new
shared regular/bold emphasis contract; its cached selected/unselected spans
have a behavioral regression. Retained metrics hosts use the shared native
window title owner. The hidden browser warm host now uses that same factory,
and its native fixture verifies its title, retained caption and invisibility.
Stamp-only migrations retain source records and comments, including an adjacent
comment, BOM, CRLF, existing metadata and a missing final newline. Migrated
candidates still have to parse and equal the intended typed model. Other
migration edits retain the canonical writer; this does not establish general
byte preservation for mixed successful and skipped copies.

The serial whole AHK suite is checked again after these integration changes.
The virtual-keyboard E2E suite passes 5/5; it does not certify the optional
interactive keyboard path. Whole-entry compilation, all 1,785 AHK source
encodings, the strict conventions and the repository formatter pass.

The complete Windows-host JS attempt records 343/352 passes. Subsequent
replays pass whole-entry compilation after removing an incompatible PYTHONHOME,
the product-window title audit, and the strengthened typing wiring gate
(152 checks) tracing both the legacy and deferred notification owners. The
actual generated-output guard passes all 43 outputs of 24 generators.
Its mutation/restore coverage stress still encounters Windows UNKNOWN open
failures on different files; its exact private trailing-marker mutation was
verified and restored, and no generated edit is included in the commits.
That stress gate is not green.

Four assertion failures reproduce on an untouched archive of origin/dev:
Linux installed layout discovery/ownership, macOS signing replay, Ollama
server-command policy resolution and release-install path inventories. The
archive uses the same Windows-host Lua/Bash environment; this is baseline
causality rather than Linux/macOS certification. The Ollama bootstrap replay
exceeds its private 240-second cap; the live-suite replay selects actual curl
rather than its fixture double. Its exact owned private process tree was
stopped, and an isolated PATH-normalization probe did not repair the behavior.
The bootstrap gate remains unvalidated. No assertions were weakened or skipped
to call those platform results green.

Final AHK count: 7,878 passed, zero failed in the final serial receipt.
