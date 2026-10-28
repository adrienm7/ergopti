<!-- docs/audits/windows-2026-10-28/COMMITS.md -->

# Atomic Windows audit commits

The original 160-commit index is historical. The post-validation Windows fixes and their integrated source head are documented in the appendix.

Integration head: `fe3d8b010779a2666ef9307305c68f1bc9d92428`. Base: `18d69a24c06586186a221c1afb5ce703732ac4a1`.

The proof paths below resolve after extracting `evidence.tar.gz`. The machine-readable index is `report.json`.

## 802f7f5749 fix(test): classify repository url fixtures by canonical roots

Full SHA: `802f7f5749c249d81bfd70b58ff4ffc8da53d31d`.

The shared Lua contract corpus uses lua/test, while both URL policies
recognized only plural tests directories. Intentional canonical and
foreign links therefore failed the common gate before Windows validation.

Classify canonical test roots once for both policies. Keep production
paths covered even when their names resemble fixtures, and verify that
repeated violations and standalone extension restrictions remain intact.

Regression files:

- `tools/test/test-repo-url-single-source.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round2/url-gate/formatted-green.log`
- `evidence/scratch/windows-audit-round2/url-gate/regression-old-classification-red.log`
- `evidence/scratch/windows-audit-round2/url-gate/report.txt`

## 225dcdbd17 fix(test): reject incomplete repository url scans

Full SHA: `225dcdbd170f3d9e8c30f041394f6cde89294470`.

The tracked-file scan silently continued after read failures. A refused
production source could therefore disappear from coverage while the gate
still certified every repository link, because its size floor remained
satisfied.

Propagate the original read error and exercise the genuine scanner body
under a controlled filesystem refusal. Keep a real readable-source
control and all existing literal and fixture classification regressions.

Regression files:

- `tools/test/test-repo-url-single-source.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round2/url-read-error/proof.json`
- `evidence/scratch/windows-audit-round2/url-read-error/refusal-after.log`
- `evidence/scratch/windows-audit-round2/url-read-error/regression-before-red.log`

## 53d9b8d2f9 fix(metrics): preserve typing calendar day identities

Full SHA: `53d9b8d2f9afe037b5b642e09806f104a549ee02`.

The typing records view compares local noon instants to exactly 24 hours,
so daylight saving breaks valid streaks. Local calendar construction also
normalizes archived skipped dates, mislabeling records and weekdays and
omitting their cells from the annual calendar.

Extract the existing apps civil-day owner into one shared module, preserve
its public functions and load it before both pages consume recorded dates.
Use its UTC day identities for typing streaks, record labels, calendar
cells and weekday heatmaps while deriving today from the local clock.

Exercise all declared page scripts and real host publication handlers in
VM across DST, midnight transitions, Apia archives and local date edges.
The registered gate now runs 279 checks and retains all228 prior controls.
Verify the actual Windows bundle selection and its page-reference gate
include the newly shared local script.

Regression files:

- `tools/test/test-metrics-apps-linux-poll.cjs`
- `tools/test/test-metrics-apps-publication-order.cjs`
- `tools/test/test-metrics-category-ids.cjs`
- `tools/test/test-metrics-filter-cache.cjs`
- `tools/test/test-metrics-manifest-contract.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-civil-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-grid-proof.json`

## 0e824867d8 fix(metrics): align typing calendar week columns

Full SHA: `0e824867d8a9453e9d66ec282278184357d9c8a4`.

The calendar advances its column after Sunday and again before Monday.
Each real week therefore leaves an empty column, doubling the graph width
and shrinking visible cells. Ending on Sunday adds another empty column.

Derive the week column and SVG width from the rendered cell count instead
of two competing transition counters. Check real rendered geometry through
all three loaded pages for Monday, Sunday and midweek endings, preserving
the earlier calendar identity and native-handler ingress regressions.

Integration validation retains 288 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-grid-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-window-proof.json`

## d0a0f047a7 fix(metrics): scope annual calendar totals and intensity

Full SHA: `d0a0f047a7b92e6dc24139a8e54fe760b0568b22`.

The calendar renders the last year but computes its colour scale and
summary from every manifest date. An invisible old or future outlier
therefore flattens current activity and inflates the annual totals.

Limit the calendar day map to its existing inclusive year window before
normalization and summary aggregation. Keep week-alignment padding empty
and retain the inclusive first day and local today.

Add twenty-four loaded-page regressions across all three host ingress
paths for archives, future rows, padding, invalid keys and date boundaries,
including Los Angeles local midnight and an archived Apia skipped date.
Personal all-time records keep their separate scope.

Integration validation retains 312 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-month-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-window-proof.json`

## e5064253df fix(metrics): clamp quick ranges to valid target month days

Full SHA: `e5064253df49b1221d3ef78e46faa6b16e0d91dd`.

Moving May31 back three months with Date.setMonth overflows February and
starts the query on March3. Six-month ranges have the same defect whenever
the destination month has fewer days, silently dropping valid history.

Add clamped month arithmetic to the shared civil-day owner and use it for
the existing three- and six-month presets. Preserve valid days and derive
the initial day from the local clock before doing calendar arithmetic.

Exercise twenty-four real HTML onchange paths across all three loaded-page
VM hosts, checking displayed dates and the generated query selection for
leap years, month ends, year boundaries and local timezone edges.

Integration validation retains 336 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-month-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-quick-selection-proof.json`

## b61d4fb881 fix(metrics): release quick preset action selections

Full SHA: `b61d4fb881b0580cb33fa6477bb4a03a1a1512ba`.

Quick presets leave their action selected after changing the date inputs.
A later manual date edit therefore retains a false preset label, and the
same action cannot be selected again through a normal change event. The
function documents returning to its placeholder but never does so.

Clear the action selection after applying its dates and before requesting
data. Preserve all preset ranges, hour cutoffs and blank-placeholder no-op
behavior. Exercise every actual HTML preset, manual date changes and
reapplication through all three loaded-page VM host paths.

Integration validation retains 363 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-midnight-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-quick-selection-proof.json`

## 6de0e0ca6c fix(metrics): retain date-qualified last-hour chart windows

Full SHA: `6de0e0ca6c688e86a611234ed220368f707940bb`.

At00:30 the last-hour preset queries only today, losing the previous
evening. Its zero cutoff also selects hourly charts instead of five-minute
detail. Merely widening the dates switches the view to daily granularity,
and flat clock-only bucket keys cannot retain both dates reliably.

Capture an explicit current-and-previous-hour window from one clock, use
its date bounds for the native request and retain dates in five-minute
bucket keys. Render that captured window independently of daily key count.
Clear it for manual dates, Today, resets and multi-day presets, without a
compatibility alias or changing ordinary single-day hourly aggregation.

Exercise422 loaded-page VM controls, including thirty new query, chart,
precision, midnight, DST, skipped-date, bucket-collision and stale-response
checks. Native request shapes, all prior controls, packaging and targeted
publication/reset neighbours pass; native Windows qualification stays with
the integration lane.

Integration validation retains 393 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`
- `tools/test/test-metrics-manifest-contract.cjs`
- `tools/test/test-typing-metrics-reset-transaction.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-live-chart-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-midnight-proof.json`

## 5423b884fa fix(metrics): refresh chart projections on live manifests

Full SHA: `5423b884fae43638522654e00d4de5985a4050b9`.

After the first paint, Windows and Linux admit fresh manifests but only
refresh n-gram views. The chart series and cached manifest dates/apps keep
the initial snapshot, so visible curves disagree with fresh statistics and
new days or applications never reach those projections.

Share the existing metadata reconciliation and refresh the admitted
manifest projection without creating another loader or native range token.
Clear cached dates for empty snapshots while preserving existing empty-data
selection policy. Keep stale native-response and revision fences ahead of
all admission, and preserve the captured hour window.

Add twenty-four loaded-page VM regressions for chart/KPI coherence, new and
cleared data, selection policies and query ownership. Upgrade the envelope
history fixture to real page/DOM dependencies so later refreshes execute
production projection code rather than a stub. The targeted gate passes
417 cases with publication, reset, bridge and packaging neighbours.

Integration validation retains 417 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`
- `tools/test/test-metrics-manifest-contract.cjs`
- `tools/test/test-windows-metrics-range-bridge.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-heatmap-selection-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-live-chart-proof.json`

## 881990f38d fix(metrics): apply app selection to weekday heatmaps

Full SHA: `881990f38d5e997f346a8ca01eabe7ae2c1145c0`.

The app modal filters other typing statistics, but the hour/weekday
heatmap accumulates every app through Object.values. Deselecting all apps
therefore leaves populated cells and totals while the raw-character KPI
correctly displays zero. Subset selections also include excluded apps.

Keep application identities in the accumulator and use the existing
canonical selection predicate for manifest and live data alike. Preserve
its Unknown inclusion policy and the existing date scope.

Add eighteen full loaded-page VM regressions through actual modal actions
for ALL, subsets, NONE, reselection, Unknown and combined date/app filters
on all three host paths, checking cells, totals and KPI agreement.

Integration validation retains 435 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-daily-dates-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-heatmap-selection-proof.json`

## d3863760c3 fix(metrics): retain civil dates in daily typing charts

Full SHA: `d3863760c3324558abe7284e6a964e131363deec`.

Local noon normalizes archived dates in the viewing timezone, so Apia
collapses the recorded December30 and31 into one chart coordinate.
Keep daily points, axes and labels in the shared civil-day domain while
hourly charts retain their local instant labels.

Cover all five daily chart families through loaded native page ingress,
the shipped Chart.js tick generator and the registered canvas renderer.

Integration validation retains 456 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/ribbon-category-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-daily-dates-proof.json`

## a5527398c4 fix(metrics): escape custom category text in activity ribbons

Full SHA: `a5527398c4d327786a78da94b187c414fee9cc06`.

Custom category labels are valid native strings, but the ribbon tooltip
inserted them as raw SVG markup. A balanced label could add SVG elements
and ordinary ampersands also lost their literal representation.

Use the canonical HTML escaper at the tooltip boundary and cover native
publication on all three hosts, with a separate SVG DOM reproduction.

Integration validation retains 471 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/ribbon-category-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-find-empty-proof.json`

## d11e872253 fix(metrics): rescan empty searches after native updates

Full SHA: `d11e8722533a1e17d6c719173b769ba19ddcf6f5`.

A query with no matches returned before checking the current document.
Native table updates could introduce the searched text while repeated
Find commands stayed stuck on the old empty result.

Treat empty results like detached highlights and reuse the existing DOM
rescan path. Cover native table updates and navigation on all hosts.

Integration validation retains 483 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-find-empty-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-find-unicode-proof.json`

## 6fa6b016a2 fix(metrics): preserve text offsets in Unicode searches

Full SHA: `6fa6b016a25274600945a5742abee69c7ec59ebe`.

Lowercasing can expand one character into multiple UTF-16 units. Search
positions in that folded string therefore cannot slice the original DOM
text directly: a valid Unicode process name highlighted the wrong text.

Map expanded offsets back to their source while retaining whole-text
case folding and normal navigation. Cover native table names on all hosts.

Integration validation retains 507 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-find-unicode-proof.json`

## 4b1ead0c81 fix(metrics): fold case-insensitive table search queries

Full SHA: `4b1ead0c812267f6231a3c283bf527b290b61500`.

The table normalizes row keys when case sensitivity is disabled but
compares them with the original query. An uppercase search therefore
hides matching native typing entries without reporting an error.

Normalize the comparison query with the same rule while preserving the
input text. Cover native publications, Unicode letters, sensitive-mode
controls and missing matches across all three shared-page hosts.

Integration validation retains 531 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-search-case-proof.json`

## 5df29dfa39 fix(metrics): retain native words that name inherited members

Full SHA: `5df29dfa399ab6b6317b9db1f2772746df4d3659`.

Ordinary typing can produce words such as constructor and **proto**.
Inherited dictionary reads silently lose these rows and can mutate the
page object prototype. Search aliases also treat inherited functions as
control-key labels and throw when searching such a word.

Create own data properties for every projected token and read only
declared aliases. Cover historical and live native publications, case
modes, cache hits, literal rendering, searches and prototype integrity.

Integration validation retains 591 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-token-keys-proof.json`

## 56fba966b3 fix(metrics): restore word and shortcut table rendering branches

Full SHA: `56fba966b39bc36d7aa303a045b8cb5d5341e493`.

The standalone-shortcut branch lost its condition. Its assignment runs
inside the word-sequence branch, discarding the word chips and arrows,
while ordinary shortcut and modifier rows never reach their renderer.

Restore the existing token-type boundary and cover real native word
pairs, shortcuts, shortcut pairs and derived modifiers in historical
and live publications. Preserve literal Unicode and escaped word text.

Integration validation retains 639 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-token-presentation-proof.json`

## 4541f4cc36 fix(windows): preserve JSON kinds when admitting backup schemas

Full SHA: `4541f4cc36734634a4c5ed337b02b09e046f9e2c`.

AutoHotkey decodes JSON true as integer 1 and compares numeric strings
with numbers. Backup listing and restore therefore granted the current
schema authority to Boolean and string metadata.

Expose each member's kind from the canonical parser dispatch and require
numeric schema versions from the same validated source. Preserve ordinary
JSON decoding and supported numeric spellings, including escaped duplicate
member ownership, and cover actual listing and restore side effects.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/toml/test_json_object_key_nul.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/updater/test_release_install.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/layout-schema-kind-proof/proof.json`
- `evidence/scratch/windows-audit-round6/lifecycle/control-result-kind-proof.json`

## 35d85aa792 fix(windows): admit kana overrides from the boot snapshot

Full SHA: `35d85aa792ba250ed7c55760d7c09bc0490b8849`.

The early script reader treated obsolete file values as strict runtime
candidates before canonical enum admission. Wrong strings and container
values stopped startup, while numeric zero and one forced a layout
override despite their rejected source lexemes.

Use the genuine published boot snapshot for the same enum decision
without changing its raw cache or source. Keep programmatic candidates
strict and cover the real cold-boot initialization in isolated tests.

Regression files:

- `static/ergopti_plus/windows/tests/support/feature_state_boot_smoke.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/config/persistence/test_feature_state_boot.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/kana-candidate/plan.json`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/197-config-valid-old-red.log`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/215-config-canonical-green.log`

## 13c83ac7fc fix(windows): share metrics application list validation

Full SHA: `13c83ac7fcfca37eb6cde2ba1c10fd458a624d36`.

The primary config reader admitted any array although the schema requires
application identity strings. Non-string items then raised in the strict
metrics reader and stopped startup after initial config admission.

Use one existing pure domain validator for canonical admission and live
publication so outdated lists retain their source and cleanup identity.
Keep malformed in-memory candidates strict and preserve valid opt-outs.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/config/persistence/test_config_shortcuts_types.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/string-list-candidate/plan.json`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/198-config-valid-old-red.log`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/218-config-canonical-green.log`

## 166fafeeef fix(windows): admit the error window setting at bootstrap

Full SHA: `166fafeeefe8c8b4a82c7f071a9526309fdcfc01`.

Obsolete authored values could prevent the early error window from
initializing, and signed zero silently disabled it despite canonical
configuration admission preserving the enabled manifest default.

Share the provenance-owned bootstrap reader with the Kana setting so
both early owners use the canonical source-kind decision. Keep raw source
bytes, outdated-key reporting and strict detached candidates unchanged.
Cover real cold initialization and valid, obsolete and detached values.

Regression files:

- `static/ergopti_plus/windows/tests/unit/ui/windows/test_error_dialog.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/error-window-candidate/proof.json`

## 4289cfe142 fix(windows): retain the admitted logger configuration generation

Full SHA: `4289cfe142362d2c544e606e1c344d509480f607`.

Logger initialization reread the physical configuration after bootstrap,
so an intervening edit changed only its threshold. File creation and
deletion also changed the result despite the canonical owner retaining
its original source, causing valid boot messages to be dropped or exposed.

Use the retained semantic snapshot once the genuine journal exists, and
preserve raw reads for fatal recovery before source admission. Cover
replacement in both directions, native creation/deletion, unchanged
controls and the existing pre-journal recovery and queue-filter behavior.

Regression files:

- `static/ergopti_plus/windows/tests/support/feature_state_boot_smoke.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/logger/test_logger_preinit_level.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/logger-generation-proof/proof.json`

## 268a2282bc fix(windows): normalize admitted logger enum spellings

Full SHA: `268a2282bc3e99e623e853286ee6dcdb4b2a5172`.

The canonical manifest accepts case variants of log levels, but the
native severity map uses exact keys. Lowercase and mixed-case settings
silently selected INFO, dropping requested debug messages or exposing
informational messages under an intended warning or error threshold.

Resolve the owning severity name with the canonical enum comparison.
Cover every level in three spellings through actual native source
admission, queued messages and the received disk log, alongside existing
source-generation, fatal-recovery and queue-filter controls.

Regression files:

- `static/ergopti_plus/windows/tests/support/feature_state_boot_smoke.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/logger/test_logger_preinit_level.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/logger-case-proof/proof.json`

## 83c5522e40 fix(windows): publish control readiness after activation

Full SHA: `83c5522e40b7cd33185115239712dc5b2b071acf`.

The requester reads the private token file and rings the native endpoint
only once. Publishing that receipt while registration or the session is
still inactive makes a valid startup reload fail without a retry.

Advertise this token only after both owners are active, while preserving
retirement checks and exact-token withdrawal during publication. Cover
the actual premature refusal and successful native deferred dispatch.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/native-controls-proof.json`

## ef064b6295 fix(windows): retire returning diagnostics registrations

Full SHA: `ef064b629576b183830a3121e0304d827bd9e810`.

A reentrant Stop can run before native registration finishes and mark
its listener unregistered. The late return then leaves a retired native
callback installed after its global owner has already been withdrawn.

Keep the returning acquisition owned and reconcile its exact listener
before propagating failure. Preserve primary and retirement errors and
prove actual native callback withdrawal with a positive delivery probe.

Regression files:

- `static/ergopti_plus/windows/tests/unit/ui/healthcheck/test_diagnostics_window_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/native-controls-proof.json`

## f3df0a7bd4 fix(windows): retain late warmup close retry ownership

Full SHA: `f3df0a7bd4ef3b91ffb20595e79add2121f7463e`.

A controller arriving after retirement could refuse Close while its
promise kept the native parent reserved. Stop could then retry neither
the controller nor the promise, leaving the real window alive.

Retain that exact controller as cleanup debt before propagating the
original refusal. Cover both already-owned and late-returned controller
failures with real native parent lifetime and successful retry checks.

Regression files:

- `static/ergopti_plus/windows/tests/meta/ui/webview/test_webview_shared_env_reentrancy_guard.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/warmup-close-proof.json`

## 7967719d5c fix(windows): validate the authoritative request schema token

Full SHA: `7967719d5c8d7b32d757351bde61891f9279ec57`.

The admission regex could find an earlier integer schema while the JSON
parser used a later boolean, string or decimal duplicate. It also refused
valid escaped schema keys because it searched their encoded spelling.

Read the canonical parser's decoded last-member source span and compare
the exact integer token. Cover escaped keys, authoritative duplicates and
the existing integer-only request contract without coercion.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-schema-token-proof.json`

## 49c914e19f fix(windows): reject nonnumeric control result schemas

Full SHA: `49c914e19f0ee07e9505d81ae7416232bbb11476`.

The JSON codec maps true to the same AHK value as 1, and loose comparison
also accepts the string "1". Both pending-result consumers could therefore
publish a successful completion for a nonnumeric schema.

Read the authoritative member kind from the canonical JSON source owner
before comparing its value. Cover both consumers while preserving valid
decimal and exponent number forms and decoded duplicate-key ownership.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-result-kind-proof.json`

## 04843ce70b fix(windows): bind missing-model recovery to admitted requests

Full SHA: `04843ce70b4748c99c727f3a8e9556aa6bfacce4`.

An Ollama 404 body could name a different model from the private request that
passed tags admission. The terminal handler forwarded that provider-selected
identity into the actual consent and download path, even though it already
retained the admitted model. Equivalent names also replaced its spelling.

Compare recovery identities with the canonical shared normalization and
reject mismatches as typed failures. Build matching recovery receipts from
the captured request model so the provider cannot select another download.

Exercise real public chat admission, filesystem terminal parsing, PollCurl
and the actual offer function with consent/install boundary observers.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_local_presence.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/model-affinity/158-network-next-red.log`
- `evidence/scratch/windows-audit-round6/network/model-affinity/188-network-model-affinity-green.log`
- `evidence/scratch/windows-audit-round6/network/model-affinity/README.md`

## bab16e2b71 fix(windows): retain JSON types for Ollama terminal markers

Full SHA: `bab16e2b7191987a529152f2e634db57615473eb`.

AutoHotkey decodes JSON true and numeric one to the same native value,
and loose equality also admitted quoted one. Those malformed envelopes
could authorize a successful completion without a Boolean done marker.

Consult the canonical member spans before admitting the marker, preserving
last-member identity for duplicate and escaped keys. Reject non-Boolean
markers before exposing their tokens. Cover literal controls, scalar and
container refusals, and decoded duplicate ownership through the real parser,
stream consumer and terminal verdict.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/stream-done-kind/candidate.json`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/331-network-done-marker-old-red.log`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/333-network-done-marker-green.log`

## f34c7aace0 fix(windows): wait for newly created Ollama stream output

Full SHA: `f34c7aace09393bb5382f7da79ec68d77139227e`.

The public streaming call polls immediately after CreateProcess returns.
AutoHotkey throws OSError when curl has not created its output yet, rather
than returning an invalid File object. The first poll therefore marked a
healthy request as failed and terminated curl before it could connect.

Treat only native file-not-found as pending output. Preserve sharing,
invalid-directory and other I/O failures instead of swallowing them.
Exercise genuine missing, empty, exclusively locked and invalid-directory
files, keeping native error-code controls and the stream cursor invariant.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/stream-startup-file/candidate.json`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/339-network-initial-output-four-controls-old-red.log`
- `evidence/scratch/windows-audit-round6/verification-worker/receipts/365-network-initial-output-named-constant-green.log`

## 2b8eafb927 fix(test): reject unknown Windows replay selections

Full SHA: `2b8eafb927cd087518a0ec241d441f2db76de8ec`.

A stale replay list silently dropped renamed or missing tests, allowing a
retained passing case to conceal an incomplete requested execution.

Admit every requested name against the full registry before applying the
explicit filter, module, interactive and reverse selection contracts.
Preserve registry order and duplicate-name registrations, and cover missing
names beside valid controls with typed regression assertions.

Regression files:

- `static/ergopti_plus/windows/tests/test_framework.ahk`
- `static/ergopti_plus/windows/tests/unit/suite/test_runner_shard.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/late-registration/proof.json`
- `evidence/scratch/windows-audit-round6/test-harness/list-selection/proof.json`

## f9eae3e29e fix(test): close Windows test registration before execution

Full SHA: `f9eae3e29e577a42c8d8b4a0fddba2bb7a8b66dc`.

A callback could append a failing test after the execution plan was captured,
so the unplanned callback silently disappeared from an otherwise green run.

Claim the runner lifecycle before receipt I/O or selection, refuse late
registration and nested execution, and preserve the active receipt owner.
Exercise the real lifecycle with valid names and callbacks and require exact
errors so unrelated validation failures cannot satisfy the regressions.

Regression files:

- `static/ergopti_plus/windows/tests/test_framework.ahk`
- `static/ergopti_plus/windows/tests/unit/suite/test_runner_shard.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/late-registration/proof.json`

## 70245d048c fix(test): reject failed canonical Windows TAP publication

Full SHA: `70245d048c59e063868eac95addfdf47725f9ddb`.

A refused FileCopy or an absent source silently retained the preceding
canonical receipt while RunTests still exited successfully. That allowed
legacy receipt consumers to read an old healthy run as the new result.

Propagate the native copy refusal and make every terminal runner branch
request headless failure even when stderr publication also refuses.
Exercise actual unlocked, sharing-locked and missing-source files, retain
Unicode and same-path controls, and cover the exit owner independently.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_runner_failure_ergonomics.ahk`
- `static/ergopti_plus/windows/tests/test_framework.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/receipt-copy/proof.json`

## 943cd2b11a fix(windows): remove owned manual startup links during uninstall

Full SHA: `943cd2b11a1291784a9ae2614271f6b2f589a384`.

The login owner accepts an exact executable command under any shortcut
filename and keeps manual links when startup is enabled. Uninstall only
checked the canonical name, leaving those admitted commands behind after
recycling their executable.

Enumerate the same startup folder and retain the existing exact-target,
argument and reparse-point refusal checks for every candidate. Exercise
the actual worker callback with private native shortcut fixtures so a
canonical-only census cannot pass the regression.

Regression files:

- `tools/test/test-windows-uninstall.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/startup-uninstall/proof.json`
- `evidence/scratch/windows-audit-round6/delivery-review/uninstall-ready-retirement/proof.json`

## d7fb66f7de fix(windows): reject revoked uninstall readiness

Full SHA: `d7fb66f7de8b9b7194a4496bd2a803feb9386a8c`.

A native READY wait can return after public cancellation has consumed the
uninstall transaction and closed its event. The old local owner still
passed readiness admission because the wait result was never checked
against its retained capability.

Require the exact nonzero READY handle to remain owned before accepting
native success. Preserve the existing deadline and polling order, and
exercise cancellation after a real signaled kernel wait returns.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/uninstall-ready-retirement/proof.json`

## acbe168398 test(windows): run native uninstall policy in the driver suite

Full SHA: `acbe168398b0d2437d8ea378236b85557171124c`.

The uninstall policy CLI was registered only in the common JavaScript
lane, which runs on Linux and skips its Windows PowerShell and COM
assertions. Adding native shortcut regressions there did not make the
Windows lane execute them.

Register that individual read-only CLI in the default AHK suite through
the real owned subprocess runner. Require both exit zero and the native
success receipt, then check exact process and capture retirement, so a
platform skip cannot certify native uninstall coverage.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/native-uninstall-bridge/proof.json`

## 4619b5a2c0 fix(metrics): keep ordinary words distinct from control keys

Full SHA: `4619b5a2c0400964cd38e7184775455000815c3a`.

Words such as space and enter are native text, but the table renders
them as keyboard controls and invents title-cased search aliases. This
also makes a case-sensitive search return words with different casing.

Keep word rendering and exact aliases literal while preserving physical
control markers in the character table. Cover both native data sources
and case modes, with matching physical-space positive controls.

Integration validation retains 711 dashboard controls after the
separately archived icon-only changes were removed from Windows scope.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-control-word-proof.json`

## dace692a46 fix(windows): retain foreign configuration restore stages

Full SHA: `dace692a4629277f51b7118735ed644c886b78e3`.

The fixed restore sidecar name did not establish ownership: overwrite-copy
replaced an existing sidecar and the atomic move then consumed it. These
bytes were also outside the configuration backup extension allowlist.

Acquire the stage through the existing verified create-only copy owner.
An occupied sidecar now causes an explicit write refusal while preserving
its bytes, the live destination and the pre-restore recovery snapshot.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/updater/test_release_install.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/restore-stage-collision/README.md`
- `evidence/scratch/windows-audit-round6/delivery-review/restore-stage-collision/qualified-local-boundaries.json`

## 12f5c9f9c6 fix(windows): acquire backup directories exclusively

Full SHA: `12f5c9f9c64018cae2271857f60b6ae8d9a6ba40`.

The name allocator only observed an absent pathname. Its later idempotent
directory creation adopted a directory created by another producer and
published configuration payloads and a complete manifest into that tree.

Acquire the selected root through the existing native exclusive creator.
A racing owner now retains its directory and bytes, and backup creation
propagates the actual native collision instead of publishing into it.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/updater/test_release_install.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/backup-allocation-race/README.md`
- `evidence/scratch/windows-audit-round6/delivery-review/backup-allocation-race/qualified-local-boundaries.json`

## 0ec39c8e3a fix(windows): admit escaped pending successor keys

Full SHA: `0ec39c8e3a5e926548d058f47386c5f5923a0310`.

A valid null successor named with a JSON escape decoded correctly but
failed a redundant raw-text key guard. The pending reload stayed
unclaimed despite a valid request identity and deadline.

Use the codec's unique null sentinel to distinguish explicit null from
an absent member. Retain malformed-value and assigned-successor controls
while covering escaped keys and decoded duplicate ownership.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-pending-successor-proof.json`

## 16a38e295c fix(windows): reject nonnumeric claimed driver identities

Full SHA: `16a38e295c82954da5724f4acb2304f743f262f2`.

A claimed reload record could identify its driver with a JSON string
instead of a number. Loose comparison matched that string to the actual
native process id and incorrectly published a completed reload.

Require canonical numeric member provenance before matching the claimant.
Keep decimal and exponent numeric identities valid, and cover the actual
native process id, escaped keys and authoritative duplicate members.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-claimed-pid-kind-proof.json`

## 1d39ba6297 fix(test): replay the executing Windows runner selection

Full SHA: `1d39ba6297bbeb183bf3ad8cf5ec40c412de63a2`.

Isolated failures advertised run_all with --only even when that runner did
not register the failed cases or accept its selection arguments. Double
quotes also changed values containing PowerShell interpolation syntax.

Capture the actual interpreter, entry and supported invocation arguments
before callbacks can alter them, then quote every operand literally for
PowerShell. Verify an actual failing isolated child, fixed Unicode and
quote vectors, and typed invalid-state refusals without inventing runner
capabilities.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_runner_failure_ergonomics.ahk`
- `static/ergopti_plus/windows/tests/test_framework.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/replay-diagnostics/proof.json`
- `evidence/scratch/windows-audit-round6/test-harness/tree-capture-read/e2e-source-closure-proof.json`
- `evidence/scratch/windows-audit-round6/test-harness/tree-capture-read/proof.json`

## c11eff46ed fix(test): launch native stream fixtures with cmd grammar

Full SHA: `c11eff46ed74f957db45048b0c135d0a44e119a6`.

The completed-process fixture encoded cmd built-ins as separate quoted
CreateProcess arguments. Real Windows cmd returned exit one, so five
cancellation cases failed before reaching their real reader/parser boundary;
Wine accepting that argument spelling had hidden the fixture defect.

Pass one literal command expression after cmd's switches. Keep the native
wait and exact zero-exit receipt, all existing cancellation assertions, and
add a completed-owner control that verifies real handle retirement.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/ci-cmd-fixture/candidate.json`
- `evidence/scratch/windows-audit-round6/network/ci-cmd-fixture/native-old-ci-annotations.json`

## a4ecb36052 fix(windows): admit the authored script chord switch

Full SHA: `a4ecb360521924791aa5ef58a59201aeb98fbc35`.

The late shortcut reader could reject an outdated authored switch after
the canonical loader had already preserved its manifest default. Invalid
strings and containers stopped startup, while signed zero unexpectedly
disabled the chords.

Use the retained source-kind decision for the switch alone. Preserve
strict detached candidates, slot assignments and their recommendations.
Cover the real private-file boot path, typed detached candidates and the
existing switch and slot behavior with bounded native child ownership.

Regression files:

- `static/ergopti_plus/windows/tests/support/feature_state_boot_smoke.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/config/persistence/test_feature_state_boot.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/llm-dedicated-runner-proof/proof.json`
- `evidence/scratch/windows-audit-round6/config/script-chords-proof/proof.json`

## ca83cd9263 fix(windows): use generated keys in admitted config readers

Full SHA: `ca83cd9263aaee10c7df32611effe72306983e25`.

The newly admitted logger and chord-switch paths repeated enrolled key
literals, violating the existing configuration-key ratchet despite correct
runtime behavior. Read the existing generated section and leaf constants
so the new paths preserve the single-source key contract without granting
baseline headroom or changing early logger recovery.

Proof packets:

- `evidence/scratch/windows-audit-round6/frozen-next-batch-followup/full-js.log`
- `evidence/scratch/windows-audit-round6/windows-integration-key-correction/commits.json`

## 184c04d12f fix(windows): declare the model identity failure reason

Full SHA: `184c04d12f6d27d1cd0b59b51f98795af370abc2`.

Model-affinity refusal introduced a distinct typed reason without enrolling
it in the closed vocabulary. The shared logger contract consequently
rejected the Windows producer even though foreign-model consent was
correctly refused.

Declare that semantic reason in the canonical vocabulary and regenerate
its port-contract projection. Check actual matching, normalized, foreign
and private response failures against the generated reason enum, retaining
the original model identity and consent assertions.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_local_presence.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/frozen-next-batch-followup/full-js.log`
- `evidence/scratch/windows-audit-round6/network/report-proofs/e048d63e57-proof.json`
- `evidence/scratch/windows-audit-round6/windows-integration-delivery-corrections/commits.json`

## 69424143fd fix(test): load native consumer scripts from the shared page

Full SHA: `69424143fda45e3d80ec414cd82a10590caf2795`.

The shared calendar became a declared page dependency while the native
consumer fixture retained its own four-script list. It now aborts before
checking the actual Apps projection when the helper reads that constant.

Load the real HTML dependency closure and admit the native manifest via
the Linux response handler. Preserve the genuine SQLite Writer/Reader
step and all five consumer checks so future dependency changes stay loud.

Regression files:

- `static/ergopti_plus/linux/tests/hardware/run_sqlite_kc_hold_consumers.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/frozen-next-batch-followup/full-js.log`
- `evidence/scratch/windows-audit-round6/linux-consumer-calendar-root-native/manifest.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/linux-consumer-calendar-closure-proof.json`
- `evidence/scratch/windows-audit-round6/windows-integration-delivery-corrections/commits.json`

## 15a8fa5c94 fix(test): use native child identity in replay assertions

Full SHA: `15a8fa5c94a3ddd1454b002200af0689b13d90c3`.

Windows can expose TEMP through an 8.3 alias while AutoHotkey reports
the executing script with its long path. Read both executable identities
from the real child UTF-8 receipt so replay checks retain their actual
principal and argument assertions without assuming parent path spelling.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_runner_failure_ergonomics.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/ci-second-job-122002319657-annotations.json`
- `evidence/scratch/windows-audit-round6/test-harness/replay-temp-identity/proof.json`

## fc7ea41332 fix(windows): load logger dependencies in the native loader fixture

Full SHA: `fc7ea413322fa38b0324c64e70b2e90384b27caf`.

The isolated loader component omitted the real configuration journal and
key-class owners newly consumed by LoggerInit, so hosted tests failed before
starting any worker while the main runner supplied those dependencies.

Load the genuine inert configuration closure and generated key classes,
reusing the full category owner instead of an extracted duplicate. Assert
that logging leaves the absent private configuration outside the journal,
while retaining every real worker, source, task, stage and lifetime check.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/user_hotstring_loader_lifetime_body.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/hotstrings/personal/test_user_hotstring_loader_lifetime.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/logger-loader-ci-proof/proof.json`

## d4b8473346 fix(windows): load logger owners in native diagnostics fixtures

Full SHA: `d4b84733469d2b232ea6c00f5a53d3707079e3d6`.

The native error-dialog source and both inherited diagnostics components
omitted the genuine journal dependency now queried by LoggerInit. Main
runner imports hid this gap until all nine hosted UI cases failed before
constructing a page or worker.

Load the canonical configuration, transition, profiler and generated-key
owners without replacing producer functions. Keep the absent error source
and physical DEBUG recovery source outside the journal, and verify their
roles and exact bytes while retaining all lifecycle and archive assertions.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/error_dialog_startup_owner_body.ahk`
- `static/ergopti_plus/windows/tests/fixtures/healthcheck_collection_lifetime_body.ahk`
- `static/ergopti_plus/windows/tests/fixtures/healthcheck_collection_publish_owner_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_error_dialog_startup_owner.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/logger-ui-closure-proof/proof.json`

## d993015add test(windows): retain native uninstall failure diagnostics

Full SHA: `d993015addb9345867d8788b8ce2ec57e44a0ceb`.

The default native uninstall bridge reduced a real Windows CI failure to
node:assert:150 because the annotation retains only the first output line.
Surface the bounded actual assertion message and emit the original bounded
child capture as TAP comments while preserving every failure and retirement
assertion. Cover the annotation boundary, runtime errors and output bounds.

This improves the next native diagnosis; it does not claim that the failing
Windows PowerShell policy control has been fixed or locally qualified.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/native-uninstall-diagnostics/453d-native-diagnostics-receipt.json`

## d6b075687e chore(ci): reseal Windows diagnostics after dev integration

Full SHA: `d6b075687efd090c3b8954413d86140364e8f333`.

The latest dev already contains equivalent reviewed Windows fixes. Bind
its canonical diagnostic inputs to the rebased source through their owner,
retaining every cohort, oracle and unqualified native status.

## fbeccf0404 fix(windows): reject boolean local control deadlines

Full SHA: `fbeccf0404a5b2a975b93b39f003284bfee8da31`.

JSON booleans decode as AHK integers. A true deadline was treated as the
Unix timestamp 1, and false could also time out an already claimed reload,
so malformed records published false timeout results.

Require canonical numeric member provenance before either deadline
consumer runs. Preserve genuine integer expiry and future-time behavior,
and cover both unassigned requests and claimed native process records.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-deadline-kind-proof.json`

## 0d463bd1d9 fix(windows): anchor complete control tokens and request ids

Full SHA: `0d463bd1d93bf4a4ce410ee93a6012de037e0e42`.

The dollar anchor can match before a final newline. This admitted
malformed request identifiers, including 65/66-unit values, and allowed
64-unit tokens whose final hexadecimal digits were replaced by newlines.

Use absolute subject anchors in both validators. Cover native character
and length boundaries plus real private request files that otherwise
reached the reload owner with newline identifiers.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-character-boundaries-proof.json`

## 350f4670a0 fix(windows): match canonical local control states exactly

Full SHA: `350f4670a09828ec88e61154e9a01789712ec53b`.

The completion reader compared state names without case sensitivity,
although the shared declaration and Lua policy require the exact
requested enum. Invalid pending records could therefore publish
successful completion, including through the real startup result-file
path.

Use case-sensitive comparison at the common completion boundary.
Preserve canonical and escaped values, reject other JSON kinds, and
cover both direct consumers and private-file session startup.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-state-enum-proof.json`

## 20363aa5a1 fix(windows): enforce the exact local request key domain

Full SHA: `20363aa5a1dfbe9b58e93d2dec07608b6a4e2402`.

The allowlist compared JSON member names without case sensitivity while
the actual decoder and shared Lua policy use exact keys. Additional
SCHEMA, TOKEN and REQUEST_ID variants were silently ignored and
malformed requests could reach the reload owner.

Compare the three declared key names exactly. Preserve decoded escape
and duplicate-member semantics, and test the real private request-file
path alongside ordinary unknown-key refusal.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/control-request-key-domain-proof.json`

## a55ab9c807 fix(windows): retire refused native menu population timers

Full SHA: `a55ab9c807d8479c300bc3bd6f26eb1a95399cf5`.

Initial timer admission and one-shot rearming could throw after the
owner had published its running latch. It could then report background
population as running without an admitted next callback, blocking later
retries.

Retire the exact timer capability on either admission failure and
preserve the original error, including any cleanup debt. Keep prepared
rows and the partial native cursor available for a genuine retry.

Regression files:

- `static/ergopti_plus/windows/tests/unit/ui/menu/test_menu_population.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/menu-population-admission-proof.json`
- `evidence/scratch/windows-audit-round6/lifecycle/storage-torn-ledger-proof.json`

## e88e727eac fix(windows): release retired metrics cleanup timer tokens

Full SHA: `e88e727eac1a686a4239bbbfba1ca206ff35c07a`.

A locked private stage schedules a bound retry callback, and its token also
owns that callback. Clearing the timer registry leaves this native reference
cycle alive after every completed retry or refused timer admission.

Break the token's reverse callback reference only when that publication is
retired. Preserve the active callback identity used by cancellation receipts,
reentrant cleanup and stale callback fencing. Cover real locked-stage cleanup
with a native timer and the sibling admission failure with release observers.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keystats/metrics/test_metrics_cancel_retry.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/cleanup-token-retirement-qualified.json`

## 6bbe1eb8be fix(windows): admit HTTP status before Ollama stream bytes

Full SHA: `6bbe1eb8be8f4894615dc53e41a77dea200603f3`.

curl treats HTTP errors as successful transfers. The streaming owner only
checked its process exit and provider done frame, allowing redirects,
authentication failures and server errors to publish predictions.

Retain a bounded private header receipt and admit its complete final 2xx
status before reading provider bytes. Reuse the canonical header parser,
wait for partial and informational blocks, and preserve native I/O errors.
The existing cleanup owner also retires the header artifact.

Exercise real curl against ten actual HTTP statuses, header and I/O
boundaries, cancellation after header reads, and existing JSONL guards.
Receive public asynchronous model-removal recovery over real HTTP404 too,
including captured-model spelling and foreign/private consent refusals.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/ollama_stream_http_peer.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_final_flush.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_http_recovery.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_stream_nul.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_stream_utf8.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/report-proofs/e048d63e57-proof.json`
- `evidence/scratch/windows-audit-round6/network/stream-http/proof.json`

## 5b6132d76c fix(windows): close Ollama streams at their terminal marker

Full SHA: `5b6132d76ced61e5b307d03968bb0c88e8fcb01e`.

The JSONL consumer remembered done but still admitted later records. A
successful HTTP200 transfer could therefore append another answer after
its terminal frame and report that invalid sequence as a completion.

Reject every subsequent nonempty record before parsing or appending it.
Keep blank tails, false-to-true transitions and empty final tokens valid.
Exercise same-slice and later-slice violations, duplicate terminals and
the actual public curl path, retaining HTTP, cancellation, exit, cleanup
and captured-model recovery controls in one native cohort.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/ollama_stream_http_peer.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/report-proofs/22d5a22437-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/e048d63e57-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`
- `evidence/scratch/windows-audit-round6/network/stream-after-done/candidate.json`

## b8ecd36e3b fix(windows): reserve Ollama admission before preparation

Full SHA: `b8ecd36e3bb3e3bc2f4a11880c00d89b724ffce2`.

Private-directory preparation could yield before the async slot was published,
so cancellation was lost and a reentrant caller admitted a second active slot.
A throwing scheduler could also leave its published slot permanently occupied.

Reserve the exact owner in the public admission and queued-handoff transactions.
Keep that owner through preparation, and retire it before propagating failures.
Regression tests use the actual public chat, directory resolution and file write
owners while driving explicit caller events at the filesystem return boundary.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_dispatch_admission.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_local_presence.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/async-preparation-admission/candidate.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/22d5a22437-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/4a63f232e3-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`

## a2c2499d09 fix(windows): release retired auxiliary timer callbacks

Full SHA: `a2c2499d09df7902e118efc21e69a29caad5d6f0`.

The one-shot timer closure captured its own TimerFn variable. Clearing owner
registration and cancel capabilities therefore left a reference cycle holding
private callback state after execution, cancellation and scheduler refusal.

Use a callable object to supply the exact timer identity without self capture.
Keep existing stale-owner, re-arm, native cancellation and cleanup-debt checks.
Passive lifetime regressions run genuine native SetTimer execution/cancellation
and explicitly refused scheduler admission with an independent destruction control.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_aux_timer_retirement.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_local_presence.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/report-proofs/4a63f232e3-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/f9f257db49-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`
- `evidence/scratch/windows-audit-round6/network/request-retirement/timer-candidate.json`

## 8dc019023d fix(windows): release acknowledged Ollama retirement callbacks

Full SHA: `8dc019023db2fa91718fb42eddd5399a56c733e8`.

An admitted chat retains its auxiliary owner, whose retirement callback retains
the original private entry. Native completion retired files and processes but
never broke this bound-callback cycle, keeping request closures alive forever.

Release only the exact callback after successful acknowledgement. Keep it on
refusal so existing cleanup debt can retry without losing the retirement event.
Native matching, foreign and private-response tests use passive entry lifetime
witnesses; a real finalizer/debt retry test covers refusal and one-shot delivery.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_http_recovery.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/report-proofs/84d30098c4-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/f9f257db49-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`
- `evidence/scratch/windows-audit-round6/network/request-retirement/request-candidate.json`

## bd04540daa fix(windows): release delivered native health callbacks

Full SHA: `bd04540daa3049efad67b9f5ee9be7b2991664e6`.

The shipped tray enable request retains its auxiliary owner, whose completed
ping ticket kept the callback bound to that same request. Native completion
and config settlement therefore left the request closure in a reference cycle
after both successful enable and an HTTP readiness refusal.

Consume the exact callback with its committed ticket before invoking it once.
Keep ticket diagnostics, selected-origin wrappers and existing cleanup barriers.
Native tray regressions exercise the real health probe and config writer with
passive request lifetime witnesses and explicit lifecycle/UI fixture boundaries.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/ollama_stream_http_peer.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_http_recovery.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_native_enable_retirement.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/native-tray-retirement/candidate.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/84d30098c4-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/f79a2d4cb2-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`

## 071b8a2006 fix(windows): preserve source-kind admission in AI tray restore

Full SHA: `071b8a2006a1463c6ca62498ba55328ddc2f87bb`.

The tray restored manifest-backed values from the raw bootstrap cache
after canonical configuration admission. Its scalar coercions could turn
rejected quoted values into navigation or validation modifiers, application
exclusions, or a completed onboarding flag despite retained defaults.

Reuse the native source-owned admission for these four leaves. Preserve
valid foreign-owned rows and existing detached candidate validation.
Cover exact native file admission, default retention, typed positive
controls and existing persistence/type-boundary behavior.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/menu/test_llm_menu_persistence.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/llm-source-kind-proof/proof.json`

## d31c5367ed fix(windows): use generated keys for AI source admission

Full SHA: `d31c5367ed7172569f56234fc19bfc0a925a0ac9`.

The new source-owned AI restore paths repeated enrolled section and leaf
literals, making the configuration-key ratchet fail. Read their existing
generated constants so the admission fix respects the single-source key
contract without changing runtime values or increasing the baseline.

Proof packets:

- `evidence/scratch/windows-audit-round6/config/llm-key-literal-followup/proof.json`

## 51c8db94d8 fix(windows): load the real isolated AI persistence dependencies

Full SHA: `51c8db94d80a3ffd0d0967e55c57e07c01b8f2fb`.

The dedicated entry aborted before TAP because the staged tray exception owner
was missing, while the main runner accidentally supplied it. Load the genuine
configuration, journal and full-save owners and share the existing headless
fixture contracts so the whole isolated registry runs without skips or shims.

Launch that entry as a bounded owned native child from the main suite and verify
every registered callback, plan, ordinal and footer through a private UTF-8 TAP
receipt. This catches parse aborts that a green main-runner suite cannot see.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/run_llm_menu_persistence.ahk`
- `static/ergopti_plus/windows/tests/support/config_journal_fixtures.ahk`
- `static/ergopti_plus/windows/tests/support/llm_persistence_runner_contract.ahk`
- `static/ergopti_plus/windows/tests/support/wpm_widget_state_contract.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/config/migration/test_config_journal_boot.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/config/persistence/test_config_persistence_transactions.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_llm_persistence_runner.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/llm-dedicated-runner-proof/proof.json`

## 3bd1d4893b fix(windows): enforce numeric layout schema versions

Full SHA: `3bd1d4893bdaed9e186fbcd249b56c455eb75bd5`.

Loose native comparisons accepted Boolean true and quoted numbers as
schema version one. Both installed layout metadata and composer imports
could publish records whose JSON schema type was incompatible, including
values hidden behind decoded duplicate member identities.

Require the canonical JSON member kind before comparing the version.
Reuse the existing installed-record spans and preserve accepted numeric
forms and last-member semantics. Cover both real receiving paths with
wrong-kind, duplicate, numeric and already-refused controls.

Regression files:

- `static/ergopti_plus/windows/tests/support/layout_schema_kind_fixtures.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_catalogue.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_composer_host.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/layout-schema-kind-proof/proof.json`

## c47cff4001 fix(windows): reject unusable installed layout metadata

Full SHA: `c47cff4001f4fab544fc27546315c340c98aefae`.

Installed layout membership checked only that checksum and version fields
existed, so arrays, objects, booleans, numbers and null were exposed as usable
verified metadata. Match the shared catalogue owner by requiring strings.

Exercise every JSON value family through the actual native record reader,
sibling update, writer and reread. Outdated rows retain their exact source
bytes while valid empty and numeric strings keep their existing contract.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_catalogue.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/layout-entry-types-proof/proof.json`

## f31db6d693 fix(windows): test the model browser with its native JSON owner

Full SHA: `f31db6d693587a767ff6f943b081f8d76a43ca76`.

The isolated browser suite passed with a decoder returning empty Maps and
a quote-only encoder, so valid selection messages disappeared and malformed
JavaScript strings went unnoticed. Load the real codec instead of replacing
the boundary the suite claims to exercise.

Cover independent control-character and backslash literals plus actual
deferred bridge selections and negative messages, retaining the original
checks. The effect port stays recorded without constructing a WebView.

Regression files:

- `static/ergopti_plus/windows/tests/run_llm_model_browser.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/model-browser-json-proof/proof.json`

## e76b2b17c6 fix(windows): acquire catalogue publication stages exclusively

Full SHA: `e76b2b17c6fa37bbfcc2cbbccde9be0c791c20bd`.

The fixed publication sidecar was opened with overwrite, so an unrelated
existing file was truncated and moved away by public installed-record and
verified local-layout writes. Acquire it with the existing native CREATE_NEW
and durable writer before attempting publication; collisions stay untouched.

Exercise fresh and existing native targets with absent and binary foreign
stages, checking exact source snapshots, genuine readable results, lease
retirement and preservation of opaque outdated record members.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_catalogue.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/layout-stage-ownership-proof/proof.json`

## 8bb198649b fix(windows): keep configuration backup copy paths literal

Full SHA: `8bb198649b4dc54afec9d7d6d3bd9e9a2b37fa3e`.

AutoHotkey FileCopy and FileDelete expand filename patterns. An imported
backup manifest could reach that path, fail verification, and still delete
an unrelated restore sidecar matched by the cleanup pattern.

Use native create-only CopyFileW and the existing literal deletion owner.
A native copy refusal never acquires cleanup authority. Cover the actual
helper and public restore with real foreign-byte preservation controls.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/updater/test_release_install.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/integration-native-lists/manifest.json`
- `evidence/scratch/windows-audit-round6/delivery-review/literal-copy-paths/candidate-a.json`

## 64d35c376c fix(windows): retain backup stages with ambiguous ownership

Full SHA: `64d35c376c518cc586f1ce0119a604771013961a`.

A failed byte comparison or native rename does not identify the file now
held at a staging pathname. Another producer can replace the original
copy before refusal, and pathname cleanup then deletes that foreign file.

Retain unverified stages and propagate the existing explicit failure from
both copy and restore owners. Real file-ID replacements cover comparison
refusal and an actual native rename denial with the recovery backup kept.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/updater/test_release_install.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/literal-copy-paths/319p-native-copy-replacement-old-receipt.json`
- `evidence/scratch/windows-audit-round6/delivery-review/literal-copy-paths/319t-native-restore-move-refusal-old-receipt.json`
- `evidence/scratch/windows-audit-round6/delivery-review/literal-copy-paths/candidate-b.json`

## 5197592272 fix(windows): validate control session identities before lookup

Full SHA: `5197592272a51bc81b7cdf407b0f63503527741c`.

PowerShell coercion admitted Boolean, string and array identities, and
rounded fractional process IDs before looking them up. Its case-insensitive
end anchor also accepted uppercase or newline-terminated session tokens.

Validate the JSON object and scalar identities before any native lookup.
Keep integral numeric spellings, exact protocol casing and the declared
token length, with real CLI regressions and a mandatory Windows host gate.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control_cli.ahk`
- `tools/test/test-windows-control-cli.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/control-cli-boundaries/qualified-session-boundaries.json`

## 2fad2bc823 fix(windows): reject malformed control result completions

Full SHA: `2fad2bc82318de682e4767b6d62af5cf3eb42347`.

The poll receiver treated PowerShell comparisons as protocol validation.
Arrays and differently cased identities could report a false completion,
while invalid JSON was silently turned into an unknown outcome.

Require the declared scalar fields and phase shapes before correlating an
exact request identity. Preserve every valid state and integral numeric
spelling, and keep the actual public receiver under portable and default
Windows PowerShell host gates.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control_cli.ahk`
- `tools/test/test-windows-control-cli.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/control-cli-boundaries/qualified-result-boundaries.json`

## 08422b0e24 fix(windows): retain refused uninstall worker destinations

Full SHA: `08422b0e24fd0c995b19b10f5a827cec6a3e6da4`.

The generated worker pathname was stored before the create-only copy. A
real allocation refusal therefore canceled an owner that deleted the
existing file even though no worker copy had been acquired. Record copy
ownership only after the native copy succeeds and require that receipt
before cancellation cleanup.

Exercise the actual native create and public cancellation for both an
acquired worker and an occupied destination. Successful-copy replacement
identity remains a separate ownership boundary.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/uninstall-worker-allocation/old-red-summary.json`

## 5e3bc98be9 fix(windows): report tree-owned capture read failures

Full SHA: `5e3bc98be969f82bbced27ac17de73cf779d2c59`.

A native worker could exit successfully while a sharing refusal or a lost
capture prevented its result from being read. The completion still sent
empty output and no diagnostic, hiding the failed capture from callers.

Keep the actual process exit code and return the original read failure
through the existing diagnostic channel, as the legacy adapter does.
Require every expected capture to exist while preserving uncaptured tasks,
private log redaction, one-shot delivery and native cleanup ownership.

Regression files:

- `static/ergopti_plus/windows/tests/unit/adapters/shell_runner/test_shell_runner_tree_deferred_completion.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/tree-capture-read/proof.json`

## fba7946bde fix(test): resolve Windows include paths before traversal

Full SHA: `fba7946bde108842ceb576dac1024c87e449737c`.

The common coverage gate converted backslashes only after POSIX path
resolution. Valid A_LineFile and relative Windows includes therefore kept
noncanonical identities or stopped at file.ahk/../ paths without visiting
their children, so Windows test reachability depended on the audit host.

Normalize native Windows separators before macro and path resolution.
Exercise transitive fixture graphs in the existing wired gate and retain
the real repository census. Actual AutoHotkey accepts both native include
chains, and the gate passes with Linux and Windows Node path semantics.

Regression files:

- `tools/test/test-ahk-test-coverage.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/include-paths/proof.json`

## fab87d3ab2 fix(test): follow executable Windows include directives

Full SHA: `fab87d3ab266d8fde762f16d6cc3920f0fe2ba08`.

A commented or continued-string include let the coverage gate accept a
Windows test which AutoHotkey never registered. Legal trailing comments,
directive case and IncludeAgain could instead reject a registered test.

Read include operands through the canonical AHK lexical boundary, keeping
literal path characters separate from executable statements and comments.
Preserve native bootstrap line boundaries in its receiving guard, cover
real registration and gate verdicts, and enroll the verifier dependency
in existing fixtures and native source receipts without changing cohorts.

Regression files:

- `tools/test/test-ahk-suite-manifest.cjs`
- `tools/test/test-ahk-test-coverage.cjs`
- `tools/test/test-linux-http-stream-registration.cjs`
- `tools/test/test-linux-runtime-native-registration.cjs`
- `tools/test/test-linux-window-switch-registration.cjs`
- `tools/test/test-menu-parity.cjs`
- `tools/test/test-script-source.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/include-non-code/proof.json`

## 5835d30ca9 fix(test): avoid phantom capture debt in state fixtures

Full SHA: `5835d30ca9991c4afa73dbfadba754cbfac63aba`.

Pure legacy transition fixtures never create a native capture, but their
synthetic filename enrolled unfinished claims in the real release queue.
Declare their absent resource honestly and stop deleting a guessed temp
path, so subsequent native tests retain an uncontaminated ownership map.

Regression files:

- `static/ergopti_plus/windows/tests/unit/adapters/shell_runner/test_shell_runner_legacy_state_machine.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/legacy-capture-loss/proof.json`
- `evidence/scratch/windows-audit-round6/test-harness/legacy-fixture-debt/proof.json`

## f92f808038 fix(test): keep identity fixtures free of capture ownership

Full SHA: `f92f808038bcf0988d474b17c189b110c5daefea`.

Direct collision fixtures bypassed the capture-free factory and retained
a phantom release owner. Route shared task identities through the same
factory so identity and stale-owner checks cannot contaminate later
native capture tests.

Regression files:

- `static/ergopti_plus/windows/tests/unit/adapters/shell_runner/test_shell_runner_legacy_state_machine.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/legacy-capture-loss/proof.json`
- `evidence/scratch/windows-audit-round6/test-harness/legacy-fixture-debt/collision-followup/proof.json`

## 1620969491 fix(windows): report missing legacy process captures

Full SHA: `16209694917bae404a38efd6c15e6850029696d3`.

A deleted expected stdout file bypassed the legacy finalizer's read and
reported a clean empty capture. Read every expected capture so its real
native failure reaches the existing diagnostic channel while preserving
the child's process status and exact resource ownership.

Regression files:

- `static/ergopti_plus/windows/tests/meta/adapters/shell_runner/test_shell_runner_legacy_claims.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/shell_runner/test_shell_runner_capture_debt.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/legacy-capture-loss/proof.json`

## 922f1d2e54 fix(test): observe native requeue cancellation in F25 cases

Full SHA: `922f1d2e543141314477f23ee3a8d71f16fb041f`.

F25 cancellation tests stored callbacks that were never armed, allowing
native cancellation to disappear without failing the suite. Preserve
logical assertions and observe genuine delivery, exact cancellation and
an independent native heartbeat so leaked callbacks cannot pass.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/dispatch/test_timer_scheduler_suspend.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/test-harness/f25-native-cancellation/proof.json`

## f7fa791f59 fix(metrics): retire app selections when native history empties

Full SHA: `f7fa791f596ce9ed83f494cc7193f45fdfe35344`.

The manifest update reconciles applications only when at least one
recorded date exists. Clearing native history therefore clears the
charts but retains stale executable names in the selector and later
native query filters.

Reconcile every full replacement, including empty snapshots, while
preserving ALL, NONE and subset ownership for later app discovery.
Cover empty, system-only, retained and new-app native publications.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-empty-app-scope-proof.json`

## afc5b943fc fix(metrics): preserve explicit none in empty app-filter captions

Full SHA: `afc5b943fc1ac9ba302b2afd4b72aaa7671a182c`.

An empty application list makes the selected and available counts equal
even when the user explicitly chose NONE. The count-first caption then
claims ALL although later native apps remain excluded by that intent.

Use the existing localized NONE caption for this state and preserve ALL
and nonempty subset captions. Cover native empty/system-only history,
app discovery, clearing, and both public modal selection actions.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-empty-selection-caption-proof.json`

## 6aea2a4fa9 fix(metrics): retain app-filter selection after locale application

Full SHA: `6aea2a4fa9a33738a468ce003b1c131c1a04c0a5`.

The locale loader reapplies the static ALL label from the page markup
after a native selection is already active. NONE and subset filters then
claim ALL even though their actual native query scope remains restricted.

Repaint the dynamic caption through its existing owner after each locale
application. Exercise every catalogue and all three native host transports
without restarting queries or changing the selected applications.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-i18n-selection-proof.json`

## b606f8f71a fix(metrics): count corrected words in completed word totals

Full SHA: `b606f8f71a46f128cfa3b2d96547a1032747bd3b`.

Native word records split clean completions into c and corrected
completions into e. Reading only c hides corrected words and understates
the words-typed card, including histories with several corrections to one
word. Project both counters as word occurrences while preserving errors
and leaving character occurrence semantics unchanged.

Pin ten real walker histories through the SQLite writer and both reader
paths, then exercise their snapshots through all three dashboard hosts,
case modes and historical/live ingress. Keep the ordinary word backspace
subject to word accuracy rather than the physical-key exemption.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/metrics_word_projection.json`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_word_projection_contract.ahk`
- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-word-completion-proof.json`

## cd4c2f3057 fix(metrics): preserve native correction accuracy across case modes

Full SHA: `cd4c2f3057cab8851b8f1ff1b4a9191447e6da57`.

Case folding changes the real [BS] control marker to [bs], so the table
loses its existing Backspace accuracy exemption and shows 0% instead of
100% for the same stored sequence. Retain accuracy error contributions
from original native keys before folding and preserve raw error counts
for correction metrics. Literal lowercase bracket text stays ordinary.

Carry the projection through character and modifier derivations. Pin
nine real walker and SQLite reader histories, exercise both native data
sources across all dashboard hosts and case modes, and verify derived
modifier accuracy remains finite.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/metrics_accuracy_projection.json`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_accuracy_projection_contract.ahk`
- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-original-precision-proof.json`

## 58c11e996d fix(metrics): retain inherited-member app IDs in typing activity

Full SHA: `58c11e996d3b977e79a53dc8a8045f2d0de70e73`.

Win32 can launch extensionless PE processes named **proto**, constructor
and other inherited object members. The native focus APIs retain these
names, but the typing app KPI treats them as existing accumulator rows
or inherited switch destinations. This drops active apps, corrupts
switch counts and can mutate Object.prototype.

Use dictionaries without inherited members for app activity and outgoing
switch counts. Cover all three native dashboard ingress paths, both
switch directions and refreshed counts for four native-proven process
identities plus an ordinary process control.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-app-id-proof.json`

## c534856f70 fix(metrics): keep native app badges for empty icon maps

Full SHA: `c534856f709de97b35ff4f60d49319c903d3a7ee`.

Windows publishes an empty app_icons map. A real extensionless process
can still be named **proto**, constructor or another inherited member,
so a normal property lookup invents an icon from Object.prototype and
renders an invalid image instead of the app badge.

Accept only explicitly published own icon entries. Cover the actual
empty-map payload across all dashboard hosts, app selection modes and
native discovery updates for four native-proven process identities and
an ordinary executable control.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-literal-unicode-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-native-empty-icon-proof.json`

## 621a84d4bb fix(metrics): preserve literal Unicode in native typing data

Full SHA: `621a84d4bb4aaf47ce146b3bd3011e625c622260`.

The shared projection guessed that valid Unicode strings resembling
Latin-1-decoded UTF-8 were corrupt. Two printable Windows events, A with
circumflex followed by NBSP, therefore collapsed into one space and the
real bigram vanished even in case-sensitive mode. A valid three-scalar
sequence was similarly rewritten to NNBSP.

Keep decoded native JSON text literal instead of reinterpreting it as
bytes. Pin five actual walker histories through SQLite and both reader
paths, then replay their snapshots across all three dashboard hosts,
history/live data and case modes. NBSP and NNBSP controls remain intact.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/metrics_unicode_projection.json`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_unicode_projection_contract.ahk`
- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-case-boundary-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-literal-unicode-proof.json`

## 6f46127e47 fix(windows): validate numeric keystats state provenance

Full SHA: `6f46127e4777375898d3fc716ca278e446185410`.

AHK decodes JSON booleans as Integers. A true allocation counter therefore
selected trusted tail-only recovery, while a true checkpoint published byte
one and made the real journal reader refuse every ingestion as read_failed.

Read the state source once and require the canonical JSON member's numeric
kind before publishing either allocation or checkpoint fields. Reuse the
parser's decoded-key and last-duplicate ownership so escaped field names and
replacement members keep the same semantics as the decoded state object.

Cover rejected boolean counters and offsets, escaped and duplicate ownership,
valid numeric controls, and real journal-to-SQL ingestion after state refusal.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_full_id_recovery.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/lifecycle/state-numeric-kind-qualified-with-runtime-limits.json`

## 3cb5454b3f fix(windows): release cancelled native enable callers

Full SHA: `3cb5454b3f3beebb7cde0733b62cdd12dd3f5a7c`.

A tray enable cancelled while a locked native output retained cleanup debt
kept Request.aux pointing to its undelivered callback owner. Even after real
artifact deletion acknowledged retirement, this reverse reference held the
inactive request and its private source snapshot in a cycle.

Capture native custody, drop the inactive caller reference, then run unchanged
prefix retirement and debt acknowledgement. Native regression controls hold
the actual output exclusively, cancel through the real tray action and require
physical deletion before observing the original request lifetime.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_native_enable_retirement.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/network/native-tray-cancel-retirement/candidate.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/f79a2d4cb2-proof.json`
- `evidence/scratch/windows-audit-round6/network/report-proofs/network-proof-index.json`

## 60f41ffbc1 fix(metrics): preserve native scalar boundaries when ignoring case

Full SHA: `60f41ffbc18fa1d80c0d70b39c2ad4114fac1d91`.

Unicode default lowercase expands capital I with dot into two scalars.
Using that spelling as a fixed-token metric key invents a character,
discards its correction precision and removes real n-grams from tables.

Use explicitly non-expanding lowercase grouping for character and fixed
character n-gram categories. Preserve whole-string Greek context and
retain full-text lowercase for word and shortcut metrics. Keep the
existing n-gram length map in the data owner used by both projections
and rendering.

Pin five actual walker/SQLite histories across both readers and every
dashboard host, source and case mode. Cover independent combining
scalars, corrections, dotless I and Greek words, then check scalar arity
across the complete Unicode scalar range.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/metrics_case_projection.json`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_case_projection_contract.ahk`
- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-audit-round6/ui-metrics/typing-app-activity-locale-proof.json`
- `evidence/scratch/windows-audit-round6/ui-metrics/typing-case-boundary-proof.json`

## f4e670ca39 test(windows): share native CLI assertion diagnostics

Full SHA: `f4e670ca396b16779e99429f18cbd20573aacab0`.

The control admission bridges also reduced real Node failures to their
bootstrap frame, hiding the failed PowerShell prerequisite from first-line
annotations. Reuse one native CLI diagnostic owner for both control phases
and the uninstall bridge, retaining original bounded output as TAP comments.

Preserve all exit, success-marker and native retirement assertions; actual
Windows PowerShell failures remain failures and require native CI diagnosis.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/support/native_cli_diagnostics.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/control/test_driver_control_cli.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/delivery-review/native-control-cli-diagnostics/464-qualified-diagnostics.json`

## 598b4d9164 test(metrics): assert the declared translated selection caption

Full SHA: `598b4d9164d7b0cab21f1590e8022c6edbe76f8b`.

The dev label migration replaced the literal app-count suffix with
ui_typing.apps_some. The retained locale regression still required the
old punctuation and rejected a correct translated subset caption.

Compare the complete catalogue-owned label on Windows, macOS and Linux
while retaining every selection, active-state and native-query assertion.
The old assertion fails at test-metrics-filter-cache.cjs:3481 after the
empty-manifest regression is repaired; no product label is changed.

Regression files:

- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-sync-ed95/metrics-filter-green.log`
- `evidence/scratch/windows-sync-ed95/metrics-filter-locale-green.log`

## 9beaacaecd fix(metrics): retire application identities after an empty manifest

Full SHA: `9beaacaecda9cdf329d58fb1f9275b248b8b3473`.

The merged manifest projection skipped selection reconciliation when
its date list was empty. A complete replacement therefore retained apps
that no longer existed and sent stale identities in subsequent queries.

Always derive the available and selected apps from the admitted manifest.
The retained replacement-scope regression fails before this correction
and covers all, none and subset modes on Windows, macOS and Linux.
Keep the current dev selector, timing and theme behavior unchanged.

Proof packets:

- `evidence/scratch/windows-sync-ed95/metrics-filter-locale-green.log`
- `evidence/scratch/windows-sync-ed95/metrics-filter.log`

## b3bad12bdd fix(windows): retain unowned restore stages after rename refusal

Full SHA: `b3bad12bddeddc79ca8b9e70e106878caafabbdf`.

A failed rename only proves publication was refused. It does not prove
that the pathname still names the verified stage: a replacement can
occupy that name before the failure cleanup runs. Deleting by pathname
then removes another writer's file.

Remove that unproved deletion. The retained native regression first
performs a healthy restore, substitutes a foreign stage, forces a real
sharing refusal and verifies the foreign bytes survive. It fails on the
merged code. macOS and Linux restore through their compare-and-publish
writers and do not use this Windows fixed-sidecar cleanup path.

Proof packets:

- `evidence/scratch/windows-sync-ed95/native-restore-results.json`

## 67d01fa99a chore(windows): reseal updater inputs after the dev merge

Full SHA: `67d01fa99a3207fe39f2313dc71af41054aa5e4b`.

Bind the unchanged diagnostic cohorts to the reviewed merged Windows
source b3bad12bddeddc79ca8b9e70e106878caafabbdf.
Only source_pin_base and source_sha256 change; cohort membership,
oracles and native qualification labels remain unchanged.

## 2926108205 test(windows): expose control admission through its npm alias

Full SHA: `29261082051dd7315830144811375532768d81f7`.

The merged zero-missing-alias gate rejected the new Windows control
checks because their phase-only entrypoint had no standalone npm alias.
A command containing phase arguments is outside that gate's contract.

Make the bare entrypoint run both genuine child phases and propagate
child failures. Enroll that bare path in the existing session check,
retain the independent result check, and add the canonical npm alias.
The alias gate and bare entrypoint both fail before this change. The
alias now runs both phases, and a genuinely absent PowerShell runtime
proves that a child failure cannot become aggregate success.

This protocol is Windows-specific. Other hosts run its portable
PowerShell semantics without qualifying Windows messages or reloads.

Regression files:

- `tools/test/test-windows-control-cli.cjs`

Proof packets:

- `evidence/scratch/windows-sync-1b7d/alias-child-failure.json`
- `evidence/scratch/windows-sync-1b7d/alias-parity-fixed.log`
- `evidence/scratch/windows-sync-1b7d/control-cli-alias-fixed.log`
- `evidence/scratch/windows-sync-1b7d/control-cli-default-old-red.log`

## 791401e8fe test(windows): exercise the current browser row serializer

Full SHA: `791401e8fe47392adb07210247a8d2e6d7fb8638`.

The selector refactor removed \_LLM_MBW_JsStr. Nine retained tests still
called it, so AutoHotkey resolved the missing function as an unassigned
local and every escaping vector failed before exercising the codec.

Replay those independent literals through the actual production row
builder and verify both its raw identity and encoded name field. Keep
all bridge cases and the new upstream install case. The latest merged
baseline gives 15 passes and 9 failures; the corrected runner passes
all 24. No protected model-browser product source is changed.

This standalone AutoHotkey runner exists only on Windows.

Regression files:

- `static/ergopti_plus/windows/tests/run_llm_model_browser.ahk`

Proof packets:

- `evidence/scratch/windows-sync-final/browser-runner-proof.json`

## 312db33a2c test(windows): keep control checks after the new upstream ordinal

Full SHA: `312db33a2cecdc66a31e0c0e7a57333b6aadc66b`.

The new upstream Lua global gate owns ordinal 529. The independent
Windows control checks reused that ordinal, so the inventory refused
to start the entire suite before any check could execute.

Keep every upstream entry unchanged and move only the two Windows
checks to the next available ordinals. The existing inventory gate
fails before this correction and passes afterwards; command bodies,
identifiers, assertions and platform coverage are unchanged.

Proof packets:

- `evidence/scratch/windows-sync-final/inventory-format-fixed.log`
- `evidence/scratch/windows-sync-final/inventory-old-red.log`
- `evidence/scratch/windows-sync-final/inventory-renumbering.json`

## 11bb1fd582 test(windows): acquire receipts before diagnostic imports

Full SHA: `11bb1fd5829d2f09fdafd9d835be0d3c428e8058`.

The shared native diagnostics include was inserted between the framework
and receipt acquisition. The unit entry therefore violated the same
bootstrap boundary that the E2E and native desktop entries enforce, and
the native receipt-sharing guard failed.

Move the include after receipt acquisition and the app-state owner.
Keep the guard and every negative mutation intact. The current baseline
reproduces the native failure; all 16 receipt-sharing tests now pass.
The standalone AutoHotkey entry exists only on Windows.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`

Proof packets:

- `evidence/scratch/windows-ci-followup/batch-proof.json`
- `evidence/scratch/windows-ci-followup/receipt-green.tap`

## ad685f95fc test(windows): derive registry shape from its live admission owner

Full SHA: `ad685f95fc489223d99e5fe5fb31414f94033c50`.

The async admission fix moved map construction before yielding transport
preparation. The old meta guard recognized only an inline Map assignment
to the registry, so it reported zero creators on the valid new path.

Inspect the genuine metadata-only constructor and its published object.
Retain exactly one publication and one local map constructor, and check
all literal reads including Get and case variants against actual keys.
Eight negative or decoy cases prove that duplicate publication, a foreign
map and undeclared fields cannot pass or be supplied by source prose.
The original native failure is reproduced; all ten registry cases pass.

Only the Windows AutoHotkey registry and its test harness have this shape.

Regression files:

- `static/ergopti_plus/windows/tests/meta/modules/llm/servers/test_ollama_async_registry_is_curl_only.ahk`

Proof packets:

- `evidence/scratch/windows-ci-followup/registry-proof.json`

## 5ea8412a65 chore(windows): reseal the corrected receipt bootstrap

Full SHA: `5ea8412a65627191ff5cc079e6169e4a5be6eb6d`.

Bind the unchanged updater diagnostic cohorts to reviewed source
ad685f95fc489223d99e5fe5fb31414f94033c50. The unit entry now acquires its
receipt before the shared diagnostics import.

Only source_pin_base and source_sha256 change. Cohort membership,
oracles and native qualification labels remain unchanged.

## d054bf097b fix(test): account for every thrown AutoHotkey value

Full SHA: `d054bf097b4514379387243129a2aaa88162fe40`.

AHK permits throwing scalars and objects, but the default catch admits
only Error instances. A callback could open an unattended error dialog
and stop the suite without failure accounting. The same filter in
AssertThrows rejected legal throws from its own callback.

Account for every thrown value at both callback boundaries. Preserve
Error diagnostics and not-executed signals. Render opaque payloads
without inspection and escape scalar controls within one TAP line.
Native children require a failed case, an exit receipt and execution of
the next callback. Assertion controls require one real invocation.

The macOS and Linux Lua helpers already use pcall for every error value.
Actual helper controls retain all following callbacks on both platforms.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_runner_failure_ergonomics.ahk`
- `static/ergopti_plus/windows/tests/test_framework.ahk`

Proof packets:

- `evidence/scratch/windows-ci-followup/harness-next/proof.json`

## 4e7c0f6e2c fix(windows): refuse nonnumeric journal event identities

Full SHA: `4e7c0f6e2cf839f893d2bbf56c85eec51853391f`.

AHK decodes JSON true as integer 1. An event with that reserved identity
could collide with an existing raw row, be dropped by INSERT OR IGNORE,
and still advance the durable journal checkpoint.

Validate the decoded member's numeric source kind before using its
identity. Share admission between ingestion and both recovery paths,
including escaped keys and last-duplicate ownership. Keep semantic
refusal outside malformed-JSON containment so the entire refused batch
retains its checkpoint and bytes. Log the refusal without exposing
journal text.

macOS allocates event IDs during SQL conversion; Linux reserves them in
SQLite. Neither consumes this Windows journal identity. Regressions
exercise actual journal-to-SQL collisions, mixed batches and recovery.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_full_id_recovery.ahk`

Proof packets:

- `evidence/scratch/windows-ci-followup/keystats-next/proof.json`

## b281896a59 fix(metrics): keep application pair identities separate

Full SHA: `b281896a596499f4697f4aa7b2974d649108a0b6`.

Distinct application endpoint tuples can share the same arrow label.
Using that label as a key merged separate workflows and displayed eight
switches for a native history whose busiest pair had only five.

Key reciprocal pairs by their sorted JSON endpoint tuple and retain the
readable label for presentation. The shared page serves all three OS.
Replay native Windows fixtures through each host bridge, selection
subset and manifest refresh. Native SQL and walker controls also require
the fixture to retain each directed edge and raw identity.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/metrics_app_pairs_projection.json`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_app_pair_projection_contract.ahk`
- `tools/test/test-metrics-filter-cache.cjs`

Proof packets:

- `evidence/scratch/windows-ci-followup/metrics-next/proof.json`

## 608623fe00 test(menu): receive the current layout activation owner

Full SHA: `608623fe00878c246332fad534fcd0507c887418`.

The upstream layout callback now confirms enabled state from a fresh
process and distinguishes consent, pending logout and failure. Both
mandatory common menu gates still required the old unconditional success
callback and rejected the actual published owner.

Admit the complete current publication route with its async
confirmation. Retain canonical identity, callback, provider and platform
refusal checks. Add four live-confirmation mutations to each independent
gate, including foreign receivers, incomplete state checks and incorrect
pending feedback.

These common contracts block the Windows lane as well. The macOS-only
row remains unavailable to Windows and Linux, and its runtime behavior
is unchanged.

Regression files:

- `tools/test/test-menu-action-handler-bijection.cjs`
- `tools/test/test-menu-category-coverage.cjs`

Proof packets:

- `evidence/scratch/windows-ci-followup/common-next/proof.json`

## 1f7561c1e7 test(process): assert the current preference editor children

Full SHA: `1f7561c1e74cb7c39e477d7ee1e3d58e5adac92b`.

The upstream input-source editor correctly ends after preference export
and import. This mandatory common gate still expected the removed third
agent restart, so its positive deadline and process-group controls
failed on all CI lanes, including Windows.

Require the two actual commands and verify that import reads the real
staged payload. Keep decreasing-budget, timeout kill and reap, and
SIGTERM ownership controls. Add mutants for missing import, extra child,
foreign export target and an undetached child. The macOS runtime is
unchanged; Windows and Linux do not use this macOS preference editor.

Regression files:

- `tools/test/test-input-source-python-supervisor.cjs`

Proof packets:

- `evidence/scratch/windows-ci-followup/common-next/proof.json`

## 19389de2c2 test(layout): resolve the preference editor by its source owner

Full SHA: `19389de2c2d9416d27297b99de5ea187aa84ceb2`.

A new assertion opened a macOS driver source by a fixed path and raised
both frozen source-read counts, failing the mandatory common preflight
for Windows as well.

Resolve the unique ENABLED_LIST_SCRIPT translation unit through the real
source census. Keep every editor and live-state assertion, and fail if
the owner is missing or ambiguous. The existing limits stay at 27 files
and 75 reads. All 24 affected Lua cases pass from their driver root.

Only a macOS test reads this editor; Windows and Linux do not use it.
Their common release gate now retains the intended move-resilience rule.

Regression files:

- `static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_input_sources_bounded_mutations.lua`

Proof packets:

- `evidence/scratch/windows-ci-followup/common-next/proof.json`

## 96746f234e chore(windows): reseal the integrated regression inputs

Full SHA: `96746f234e55ded53721b823ca646d0c742c742e`.

Bind the updated runner and its regression inputs to the exact committed
source after integration. Preserve every cohort member, independent oracle,
clock and native receiving requirement. Only source pin metadata changes.

## 6f4cd13d84 fix(timings): admit the keyboard layout refresh settling delay

Full SHA: `6f4cd13d84fd01c34cdbaaac71a0d3069031c402`.

Two literal sleeps in the imported macOS confirmation worker failed the
mandatory common timer inventory, blocking the Windows lane. Both legs
copied the same settling interval instead of consuming its canonical
timing.

Declare the existing 300 ms interval once and pass it as a required
private worker argument. Preserve the actual delay and worker ownership.
One Lua regression supplies a distinct timing value to the actual task;
another executes both actual Python sleep expressions and their
dependencies.

The Carbon reselect worker exists only on macOS. Windows and Linux do
not execute it. Their shared timing reader remains valid, and the common
preflight no longer needs a literal-delay exception.

Regression files:

- `static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_input_sources_bounded_mutations.lua`
- `tools/test/test-input-source-python-supervisor.cjs`

Proof packets:

- `evidence/scratch/windows-ci-followup/common-next/refresh-delay-before.log`
- `evidence/scratch/windows-ci-followup/common-next/refresh-forwarding-before.log`
- `evidence/scratch/windows-post-qualification/timing-gates.json`

## 1b2ca0eec2 docs(layout): describe native probes without plan tokens

Full SHA: `1b2ca0eec2df6bf4f2aab5408efc07ef4f078129`.

Four imported comments carried probe-plan labels rejected by the common
source convention. Keep their technical explanations and remove only the
labels, so the mandatory preflight can run on Windows and the other OS.
The existing regression gate fails before and passes after the correction.

Regression files:

- `static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_install_transaction.lua`
- `static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_registry.lua`

Proof packets:

- `evidence/scratch/windows-post-qualification/plan-refs-complete.log`
- `evidence/scratch/windows-post-qualification/plan-refs.log`

## 0c58d31fb6 fix(windows): fence layout opening by its window generation

Full SHA: `0c58d31fb6f60710b8501192471e0feadd1b5235`.

WebView2 creation pumps messages while its genuine Promise awaits.
Closing or reopening the window during that wait let the old result
overwrite the new controller, while an old failure closed the
replacement window.

Keep the returned controller local until both the opening epoch and
exact GUI still own the session. Retire a late controller once and keep
stale failure cleanup away from its successor. Six native GUI and SDK-
await cases cover healthy creation, refusal, close and reopen.

macOS and Linux construct their views synchronously and bind callbacks
to their current candidate. Neither uses this Windows SDK-await
publication path. The component tests model COM effects; they do not
certify physical Chromium or keyboard behavior.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/layout_manager_open_generation_body.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_manager_host.ahk`

Proof packets:

- `evidence/scratch/windows-layout-followup/native-result.json`
- `evidence/scratch/windows-layout-followup/proof.json`

## 374765f2c6 test(windows): follow journal admission through rollover evidence

Full SHA: `374765f2c6cfb3d79dfb04092ccd00d445a05920`.

The reader now admits reserved identities before publishing framing
evidence. Its rollover guard still required a direct framing call and
failed the correct admission path.

Follow both real delegates, retaining explicit ok/eof evidence and
refusing date or offset writes at every reader level. Add actual empty,
numeric and refused journal cases that retain bytes and the owning
epoch, and forbid failed admission from authorizing EOF.

Only the Windows AHK reader uses this admission chain. macOS and Linux
use their own journal or SQLite event-identity owners.

Regression files:

- `static/ergopti_plus/windows/tests/meta/modules/keystats/test_keystats_rollover_transaction.ahk`

Proof packets:

- `evidence/scratch/windows-post-qualification/rollover-green.tap`
- `evidence/scratch/windows-rollover-followup/proof.json`

## eab84fb852 chore(windows): reseal the release followup inputs

Full SHA: `eab84fb852050dbe4e2fc76485aaef25f3ceaa87`.

Bind the current runner and source inputs to the integrated fixes. Keep
every cohort, independent oracle, deadline and native receiving gate
unchanged; refresh only the canonical source pin metadata.

## 1d53275666 fix(macos): reuse canonical pending shortcut ordering

Full SHA: `1d53275666272c05639f634bf03eaf4eb0786cd3`.

Two retry loops introduced inline sorted-key collectors, failing the
mandatory common helper-ownership gate and blocking the Windows lane.

Use the existing TableUtil.sorted_keys owner for both maps. Preserve the
same default lexical order, registration decisions and lifecycle fences.
The nine affected transaction cases and the unchanged single-source gate
pass.

These retry loops belong only to macOS. Windows and Linux do not execute
them, while all three lanes retain the same common ownership contract.

Proof packets:

- `evidence/scratch/windows-shared-helper-final/gates.json`
- `evidence/scratch/windows-shared-helper-final/plan.json`

## aefc5711ac fix(test): retire queued callbacks before resetting timer fixtures

Full SHA: `aefc5711ac9d66e997c9c6b481a59ac0beadf037`.

The ordinary and suspended fixtures discarded logical timer owners after
cancelling only the primary callback. Their actual native requeue
remained armed and could execute in a later test.

Use one reset owner that independently retires both frozen callbacks and
requires logical cancellation acknowledgement before releasing the
registry. Keep stale-identity coverage on genuine reused handles, with
explicit retirement debt if cleanup is refused. The 51 scheduler
controls pass; the recorded identity-guard mutant still fails causally.

Only the Windows AutoHotkey fixtures use Fn and RequeuedFn in this
native registry. The Lua drivers do not execute these reset helpers. No
production timer or tap-hold behavior changes.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/dispatch/test_timer_scheduler.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/dispatch/test_timer_scheduler_suspend.ahk`

Proof packets:

- `evidence/scratch/windows-next-batch/integrated-commits.json`
- `evidence/scratch/windows-timer-followup/native-result.json`
- `evidence/scratch/windows-timer-followup/proof.json`

## 6a7877dff0 fix(windows): preserve foreign composer declaration stages

Full SHA: `6a7877dff021137103f65e45c5f7b2a29d0233ac`.

The composer duplicated the catalogue publisher with an overwrite open,
so a public save truncated and moved away a pre-existing declaration
sidecar. Reuse its exclusive publisher to give both saves one ownership
rule. The Lua drivers do not use this Windows declaration sidecar.

Four native public-save cases cover fresh and installed compositions,
with both occupied and free stages. Read back the exact foreign bytes,
declaration, installed record and layout, and require a visible refusal.
The two collision cases fail before this fix; all four now pass.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_composer_stage_ownership.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/composer-stage-proof/proof.json`
- `evidence/scratch/windows-composer-followup/baseline-results.json`
- `evidence/scratch/windows-composer-followup/cross-driver-scope.json`
- `evidence/scratch/windows-composer-followup/stage-commit.json`
- `evidence/scratch/windows-next-batch/integrated-commits.json`

## c27a324ef1 fix(windows): settle composer reload refusals once

Full SHA: `c27a324ef19838c52a7919f668677dc57734ed69`.

A prelaunch manager refusal invokes completion and returns false. The
selected save interpreted both signals as separate terminal results and
sent two failures to the page. Give that save one completion owner and
route synchronous refusal through it. The shared Lua composer observes
selection through its callback alone, so it has no second return path.

Drive selected save, selected save-use and an unselected success through
the actual manager boundary. Both selected cases fail before this fix;
all eleven host cases, four stage controls and twenty schema cases pass.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_composer_host.ahk`

Proof packets:

- `evidence/scratch/windows-audit-round6/config/composer-lease-callback-proof/proof.json`
- `evidence/scratch/windows-composer-followup/baseline-results.json`
- `evidence/scratch/windows-composer-followup/cross-driver-scope.json`
- `evidence/scratch/windows-composer-followup/reload-commit.json`
- `evidence/scratch/windows-next-batch/integrated-commits.json`

## b0f7c9c162 fix(windows): settle completed warmups before retrying

Full SHA: `b0f7c9c1627da75976bcf4743b77f53655d68490`.

A due retry could see its transport finish before the separate ready
poll, discard the HTTP 200 and launch another model load. Consume that
response through the same poll owner and original absolute budget. Fence
retry acquisition when origin observation pumps cancellation, so the
old callback cannot restart a revoked chain. Preserve exact model case.

Both real managed-transport regressions fail on the prior code. Removing
the cancellation fence still fails the withdrawal case. With both owner
checks, two regressions, six local custody cases and seven retry controls
pass. The Lua backends consume their dedicated completion callbacks and
do not implement this separate Windows pending-observation predicate;
the existing macOS and Linux warmup controls pass unchanged.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_warmup.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/prediction/test_llm_prompt_prediction.ahk`

Proof packets:

- `evidence/scratch/windows-next-batch/integrated-commits.json`
- `evidence/scratch/windows-warmup-followup/baseline-results.json`
- `evidence/scratch/windows-warmup-followup/completion-only-results.json`
- `evidence/scratch/windows-warmup-followup/final-results.json`
- `evidence/scratch/windows-warmup-followup/plan.json`
- `evidence/scratch/windows-warmup-followup/proof.json`

## cf2bee6030 chore(windows): reseal verified retry and composer sources

Full SHA: `cf2bee6030ed4b94b9cff68f61d94df5facdbe88`.

Bind the unchanged diagnostic cohorts to the integrated source receipt
after the release merge and verified fixes. Only the canonical source
pin and any changed source digests move; oracles and deadlines stay put.

## bd82ca2a47 fix(windows): observe warmup completion without repolling

Full SHA: `bd82ca2a478e797d8f464367529668a0cb587880`.

The retry predicate introduced a second response observation outside the
canonical poll owner. The transport already publishes its Completed
snapshot, and WaitForResponse only returns that field. Read the owned
snapshot directly, leaving all polling and abandonment in the generic
poll. The Lua backends use completion callbacks and have no such method.

A new controlled observer fails if the retry polls again. It is red on
the prior code and green here. The three full-meta failures are resolved
without changing their assertions; completed-response, custody and retry
controls remain green as well.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama_warmup.ahk`

Proof packets:

- `evidence/scratch/windows-native-followups/integrated-commits.json`
- `evidence/scratch/windows-warmup-followup/snapshot-baseline-results.json`
- `evidence/scratch/windows-warmup-followup/snapshot-green-results.json`
- `evidence/scratch/windows-warmup-followup/snapshot-proof.json`

## 2b9725bcad fix(windows): fence wizard opening by its exact window

Full SHA: `2b9725bcad2b0566ad37a9bae18afcc019df4fb6`.

WebView2 creation pumps messages while awaiting its controller. Closing
and reopening the wizard during that await let an old success overwrite
the new controller, or an old refusal reset the replacement window.
Retain the candidate locally and publish only to its original GUI and
session. A stale refusal cannot clear the current wizard's sentinel.

Six real native GUI and SDK-await scenarios use passive COM effects.
Three fail before this fix; all six pass here, including initial success
and refusal controls. The Lua hosts do not use the Windows SDK Promise
await, so this constructor race is specific to the Windows host.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/onboarding_open_generation_body.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_onboarding_open_generation.ahk`

Proof packets:

- `evidence/scratch/windows-native-followups/integrated-commits.json`
- `evidence/scratch/windows-webview-followup/onboarding-baseline-plan.json`
- `evidence/scratch/windows-webview-followup/onboarding-proof.json`

## 6136f37c12 test(windows): expose archive refusal receipts in components

Full SHA: `6136f37c126c2c95870b4a797559ef82be78a791`.

Native run 40709098135 reached the collector's archive assertion without
reporting its phase or archive-error receipt. Share a bounded observation
between both native collection components so another refusal identifies
its acknowledged file state and owned worker error code. Read it only on
failure, retaining the existing file, digest and native ACK assertions.

Five private receipt cases cover absent, owned, foreign, case-distinct
and malformed evidence; all pass with fourteen existing collection
controls. The original Windows collector failure remains unresolved
until its native receipt is received. These components exercise the
Windows collector and Job acknowledgement, not the Lua collectors.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/diagnostics_archive_observation.ahk`
- `static/ergopti_plus/windows/tests/fixtures/healthcheck_collection_lifetime_body.ahk`
- `static/ergopti_plus/windows/tests/fixtures/healthcheck_collection_publish_owner_body.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/healthcheck/test_archive_failure_observation.ahk`

Proof packets:

- `evidence/scratch/windows-diagnostics-followup/proof.json`
- `evidence/scratch/windows-native-followups/integrated-commits.json`

## f8d42b99ee chore(windows): reseal controller and archive diagnostics

Full SHA: `f8d42b99ee8d53100647224b005534cd8b0fd75c`.

Bind the unchanged diagnostic cohorts to the integrated source receipt
after verified constructor and diagnostic changes. Only the source pin
and changed source digests move; oracles and deadlines stay intact.

## a497a1d29e fix(windows): fence the opening changelog window

Full SHA: `a497a1d29ef5a29c1280faa18115b1e1428c1de6`.

The SDK await lets a shown changelog close or be replaced before its
controller arrives. An old success then overwrote current globals; an
old refusal reset the new window or launched the native fallback after
cancellation. Keep the candidate local and validate both GUI and epoch
before publishing or retiring this opening. Retire before destruction.

The real public request, native GUI and SDK await run with passive COM
and native fallback effects, while any release fetch fails the fixture.
Four of six scenarios fail before this fix; all six and the existing
changelog meta guards pass. The Lua hosts do not use this Windows SDK
Promise await, so the constructor race is Windows-specific.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/changelog_open_generation_body.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_changelog_open_generation.ahk`

Proof packets:

- `evidence/scratch/windows-changelog-followup/proof.json`
- `evidence/scratch/windows-changelog-followup/changelog-baseline-result.json`
- `evidence/scratch/windows-changelog-followup/changelog-green-result.json`
- `evidence/scratch/windows-changelog-integration/changelog-native.json`

## d051ac79d8 chore(windows): reseal current changelog source receipt

Full SHA: `d051ac79d8991c3f6443387fec9c7f3796bba2f1`.

Bind the unchanged diagnostic cohorts to the integrated source receipt
after the dev merge and changelog fix. Only the canonical source pin
and changed source digests move; oracles and deadlines stay intact.

## c28564592d fix(test): reject empty-message adapter exceptions

Full SHA: `c28564592db74de6301d0af0839720160c8f719c`.

Adapter vectors used an empty Error.Message as both their diagnostic and
success sentinel. Error("") therefore certified a throwing adapter as
healthy, including callbacks with no return-value assertion.

Track exception delivery independently across all forty sibling guards
while retaining their cleanup and diagnostic messages. Run the original
notifier and crypto contract callbacks against healthy and empty-error
endpoints, so a test that never reaches the endpoint cannot qualify.

This sentinel is specific to the Windows AHK test vectors. The Lua drivers
have separate exception-status contracts and do not use Error.Message.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/adapter_contract_empty_message.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_adapter_contract_exception_delivery.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/test_adapter_contract_vectors.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/test_adapter_contract_vectors_system.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/proof.json`

## 6029225f73 chore(windows): reseal adapter regression source receipt

Full SHA: `6029225f73e69435432014ab66b9d3829a16bf05`.

Pin the diagnostic cohort to the committed adapter test source so its
required runner input remains verifiable after registration changes.

## 48c0b809ad fix(windows): retire layout windows closed during native show

Full SHA: `48c0b809ad8e536b031bc7bd10bf24054990aafe`.

Gui.Show can dispatch the genuine Close event before returning. The layout
manager published its singleton afterwards, so the Close callback had no
window to destroy. The resumed opening could then publish that retired GUI
over a public successor.

Publish exact native custody before Show and reject retired opening frames
before browser creation. Real native messages cover a healthy open, Close,
and Close with a public reopen: one healthy and two failing cases before,
all three passing afterwards. Six existing SDK-await lifetime controls also
pass.

This cause is Windows-only: the Lua hosts do not use AutoHotkey's separate
native GUI and WebView2 constructor, and macOS publishes through its
on_webview_created owner before the native show call.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/layout_manager_early_show_body.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_manager_early_show.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_manager_host.ahk`

Proof packets:

- `evidence/scratch/windows-layout-show-followup/proof.json`

## e9eecb3b36 fix(test): require native boolean adapter results

Full SHA: `e9eecb3b3629ab5ad2b22c798e8073a973a51620`.

AHK numeric equality accepts String "0" and "1" as false and true. The
return-Boolean vectors therefore passed even when six independent
adapters returned text instead of their required native Boolean values.

Require Integer zero or one across the Boolean-valued assertions and
retain expected true/false semantics. Evaluate clipboard setters once
before inspecting their results. Exercise all six original type-contract
callbacks with native false, native true and both numeric String mutants;
share the same owned child receiver without relaxing its receipt checks.

macOS already checks the Lua Boolean type explicitly. Linux and macOS
Lua equality also keeps numeric Strings distinct from Boolean values.
No driver, shared contract or other OS implementation changes here.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/adapter_contract_boolean_types.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_adapter_contract_boolean_types.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_adapter_contract_exception_delivery.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/test_adapter_contract_vectors.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/test_adapter_contract_vectors_system.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/boolean/proof.json`

## 5573f9f1a2 fix(windows): reserve diagnostic session directories exclusively

Full SHA: `5573f9f1a24e75e8bdc2228ec5655d2606b6fa93`.

Collection admission adopted an existing GUID-named directory and replaced
its request before acquiring a worker. A unique candidate name is not an
ownership receipt, so preserve the shared parent but reserve each session
leaf with the canonical exclusive directory operation.

Public-admission regressions preserve a foreign Unicode request, refuse an
existing empty namespace and retain first-run parent creation. The old
source passes the fresh control but fails both ownership cases; all 17
selected collection controls pass after the fix.

This collector is Windows-only in the shared collection contract; macOS
and Linux have no equivalent session admission path. The intermittent
native archive acknowledgement failure remains a separate open finding.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/healthcheck_collection_lifetime_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/healthcheck/test_healthcheck_collection_lifetime.ahk`

Proof packets:

- `evidence/scratch/windows-diagnostics-namespace-attempt3/proof.json`

## 3a8a9b009c fix(test): reject empty-message callback failures

Full SHA: `3a8a9b009c0ae7aa33ef43d5e49aac3f56c9a8e7`.

Four regression callbacks recorded only Error.Message to detect producer
exceptions. A real producer could finish its effects and throw Error("")
while the complete original callback still passed every assertion.

Keep exception delivery separate from diagnostic text in text-sender
containment, logger fanout and both async registry trim tests. Pair each
original callback with a healthy control and an exact-function observer
that runs its real producer before injecting the empty-message failure.
The observer retires before invoking production, so recursive calls keep
their real behavior and no self-capturing callback owner is retained.

The message-sentinel convention belongs to these Windows AHK test
callbacks; the Lua drivers use their own exception-status contracts.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_no_throw_sentinel_delivery.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/adapters/input/test_text_sender_sendinput_failure.ahk`
- `static/ergopti_plus/windows/tests/unit/infra/logger/test_logger.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_ollama.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_remote_async_registry.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/sentinel/proof.json`

## d6e2ab47d8 fix(windows): bind prompt navigation to its native window

Full SHA: `d6e2ab47d8fc1dcecd62525f2e90cb7dfd42972d`.

A retained navigation callback read the current global profile epoch when
it arrived, so an old closed editor could initialize its successor and
replace an unsaved draft with the saved profile again. Profile identity
alone did not identify the native host that registered the callback.

Bind the exact GUI and capture the current scalar profile context in one
RAM-only transaction before deferring initialization. A profile repoint on
the same GUI remains valid. Give the existing context vectors a test-owned
native GUI so they exercise the required owner contract.

The native callback regression has three healthy controls and one failing
reopen case before the fix. All four pass afterwards, together with ten
existing context, startup, pending-repoint and singleton controls.

macOS already captures and checks its exact active window on navigation;
Linux admits ready messages by its authenticated window epoch. Their host
implementations are unchanged.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/prompt_navigation_custody_body.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/profiles/test_prompt_editor_context_epoch.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_prompt_navigation_custody.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_prompt_startup_owner.ahk`

Proof packets:

- `evidence/scratch/windows-prompt-navigation-followup/proof.json`

## d652a7bdcc fix(test): detect empty errors from retired ready callbacks

Full SHA: `d652a7bdcc565796a26cdf32365bbac4fbebae04`.

The retained bootstrap callback regression used an empty failure message
as its no-exception sentinel. Its real retired callback could complete
and throw Error("") while every remaining retired-owner assertion passed.

Track exception delivery separately and execute the complete original
regression with a healthy control and a post-return fault. Borrow the
actual callback from the real fixture start and restore both temporary
observers by identity before releasing their retained references.

This sentinel belongs to the Windows AHK callback fixture; the Lua
drivers use separate exception-status contracts.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_retired_callback_exception_delivery.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/servers/test_ollama_runtime_ready_cancellation.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/runtime/proof.json`

## 88474635dc fix(test): count native Windows fixture writes in UTF-8 bytes

Full SHA: `88474635dc0bc7fdb15b4920133694a71195d7a2`.

File.Write reports encoded bytes, but the refresh fixture compared that
receipt with UTF-16 code units. A valid Unicode response failed inside
the fixture before the behavior under test could execute.

Compare the actual write with its UTF-8 byte count. A native regression
writes accents, CJK and a supplementary character, then independently
reads back exact bytes. It fails at 12 units versus 19 bytes on the
original helper and passes after the fix. Lua tests do not use this
AutoHotkey File.Write boundary.

Regression files:

- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_catalogue_refresh_owner.ahk`

Proof packets:

- `evidence/scratch/windows-catalogue-followup-r20/helper-commit.json`

## 4c37c6e5c6 fix(windows): retain exact registry download custody

Full SHA: `4c37c6e5c6ac520b8118d7cceab9a1cafe1c1fb2`.

The registry treated its output pathname as deletion authority before the
request started and after it settled. An occupied layout, index or
extension stage was therefore destroyed even though the request never
owned that file. Refused poll and abort scheduling could also abandon an
unretired request with no remaining retry owner.

Acquire each output exclusively, pin its identity through native request
retirement, and consume or dispose only its validated native handle.
Retain refused cleanup and exact request retirement independently of the
timers, retry them before admission and shutdown, and preserve synchronous
consumer ownership across reentrant requests.

Regression tests reproduce foreign-file deletion in all three consumers
and orphaned retirement on the original source. Forty-one focused native
controls cover byte preservation, close acknowledgements, rebound paths,
metadata refusal, callback reentry, and retained retirement debt. macOS
and Linux consume verified response strings in memory and have no such
request-output sidecar or pathname deletion path.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_catalogue.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_registry_download_custody.ahk`

Proof packets:

- `evidence/scratch/windows-catalogue-followup-r20/proof.json`

## 2bac3d9d0d chore(windows): reseal integrated download and UI source

Full SHA: `2bac3d9d0d8fda3e1f1e7a71d2b4640cacc377ad`.

Bind the independent updater cohorts to the committed Windows batch
after the callback, native-window and registry custody corrections.
Only the source pin and computed digests change; diagnostic oracles,
deadlines and coverage remain unchanged.

## 4dc82ea67f fix(test): distinguish empty callback failures in meta guards

Full SHA: `4dc82ea67fdd85d0b9c8f8cdb40be628a424b1f4`.

Completion containment and isolated logging regressions recorded only the
error message. An Error with an empty message could therefore escape after
all expected effects and still certify the original callback as healthy.

Keep the thrown-state receipt independent of its diagnosis. Receive all
three unchanged callbacks through exact-function observers, paired with
healthy controls and isolated logger state so deduplication cannot create
an unrelated red. These AutoHotkey test sentinels have no Lua counterpart:
the other drivers already retain the separate pcall success flag.

Prove the old callbacks red in three native cases, then receive all 117
selected contract and callback cases successfully after the correction.

Regression files:

- `static/ergopti_plus/windows/tests/meta/adapters/shell_runner/test_shell_runner_isolated_logger.ahk`
- `static/ergopti_plus/windows/tests/meta/modules/llm/prediction/test_llm_callbacks_never_swallowed.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_no_throw_sentinel_delivery.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/meta-r29/proof.json`

## 2e3f3dca18 fix(test): preserve live window callback failures

Full SHA: `2e3f3dca1868cc7348990df28666debf52c59a43`.

The Windows maintainer harness treated an empty action error message as
success. Matcher exceptions also escaped the timer before terminal state
was published, leaving its caller waiting for an unrelated timeout.

Record failure independently from the diagnosis, contain both callback
boundaries and stop their exact timer before acknowledging completion.
Keep optional missing windows successful and required timeouts refused.
This native AHK window-driving harness has no macOS or Linux counterpart.

Exercise the genuine timer and public await in six isolated native-window
children. The unchanged regression suite fails on the old empty-action
and throwing-matcher paths while four healthy controls pass.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/live_drive_failure_body.ahk`
- `static/ergopti_plus/windows/tests/live/live_harness.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_live_drive_failure_delivery.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/live-r29/proof.json`

## 1b3e1f84da fix(windows): retain registry retirement after later poll refusal

Full SHA: `1b3e1f84da4fc8a3935dd4b7ba980d7f5a9f9833`.

A poll dispatched from its timer runs after the request's setup catch has
returned. If scheduling its next poll fails, neither the callback nor the
request is retired, so the native stage pin survives even after terminal
transport delivery.

Route that failure through the existing exact request retirement owner.
Once that owner takes over, let setup-layer exceptions propagate instead
of issuing another abort attempt. This preserves the initial refused
poll/abort contract and subscriber error visibility.

The real-facade regression admits one poll before refusing its successor.
On the original source it reports zero callbacks and one live stage owner
after actual terminal acknowledgement. macOS and Linux use completion-
driven registry fetches and have no Windows poll scheduler or native
output-sidecar pin.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_registry_late_poll.ahk`

Proof packets:

- `evidence/scratch/windows-catalogue-late-poll-r32/proof.json`

## 3a8e022a85 fix(windows): replace bundle markers without append fallback

Full SHA: `3a8e022a85eeed627bf5e0e935a9638d37217f72`.

Marker publication ignored a refused unlink and then appended the current
identity to the retained file. A scanner releasing its genuine read lease
after that refusal let the function report success with a corrupt marker,
so the next compiled launch unnecessarily extracted the runtime again.

Write the complete staging marker through the existing checked UTF-8
writer and flush its native handle before acknowledging publication.
Native regressions cover fresh and replacement identities, a real sharing
refusal followed by scanner retirement, denied writes and missing parents.
Retain build-identity, asset-integrity and bootstrap-order controls.

This marker belongs to the Windows compiled executable's self-extraction;
macOS and Linux do not run this bootstrap or publish this marker.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_bundle_skip_validation.ahk`

Proof packets:

- `evidence/scratch/windows-packaging-r30/proof.json`

## d025319cef fix(windows): preserve picker replacements during native teardown

Full SHA: `d025319cef1928d7d4c333d26e36557d06ae9da4`.

The old reset invalidated its epoch before native cleanup, but left
controller, subscriptions and confirmation slots published until Close
returned. A public picker opened during that native pump was then
stripped of its active controller and callback by the retired frame.

Detach the exact retired resources under a RAM-only critical section.
Retain local aliases until Critical is restored, unsubscribe them before
closing their own controller, and never clear a successor after callouts.

The regression drives the public picker, real GUI and WM_CLOSE, then a
native timer opens its successor while a passive browser Close pumps.
It fails on the original complete-controller assertion and passes with
the fix, alongside startup, idempotence and provider-retirement controls.
macOS and Linux already retire exact session objects and clear their
published slots only when that retired session still owns them.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/action_picker_reset_owner_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_reset_owner.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_startup_owner.ahk`

Proof packets:

- `evidence/scratch/windows-ui-reset-followup-r31/proof.json`

## 44f4f379e4 fix(test): reject scalar failures in picker teardown children

Full SHA: `44f4f379e450b09de36a28dd93b374a4bb4643a4`.

A teardown fixture caught Any but decided failure from IsObject afterward.
A string thrown after its genuine positive public path therefore produced
exit zero and a PASS marker. Catching that gap before integration keeps
the new ownership regression from certifying an incomplete child.

Normalize caught non-Error values into explicit errors on the main,
deferred reopen and cleanup paths. Add a permanent scalar-fault case
that requires exit one after the real picker has opened and closed.
An exact old-fixture mutation reproduces the false pass; its corrected
counterpart fails while the unmodified healthy child still passes.
This AutoHotkey exception-representation issue has no Lua counterpart.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/action_picker_reset_owner_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_reset_owner.ahk`

Proof packets:

- `evidence/scratch/windows-ui-reset-followup-r31/fixture-guard/proof.json`

## 16e7420adb fix(test): release completed live timer state

Full SHA: `16e7420adbdd2e81f52ec8c3501f9857555bd7f5`.

A live window drive stored its bound timer in the same state that the
timer captured. Stopping the native timer left that reference cycle
intact, retaining every completed check's state and captured callbacks
for the rest of the maintainer session.

Drop the reverse timer reference on every terminal path before publishing
completion. A replay of an already completed tick has nothing to retire.
This bound AutoHotkey window-driving owner has no macOS or Linux peer.

Prove real object destruction with an independent native destructor
control after the genuine window timer completes and caller references
are released. The old state leaks while the six outcome controls pass.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/live_drive_failure_body.ahk`
- `static/ergopti_plus/windows/tests/live/live_harness.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_live_drive_failure_delivery.ahk`

Proof packets:

- `evidence/scratch/windows-adapter-contract-followup/live-r29/cycle-followup/proof.json`

## 8047f9ab91 chore(windows): reseal current UI and live test source

Full SHA: `8047f9ab917f525cb5997dcda782ef0cc54c1f37`.

Bind the independent updater cohorts to the committed Windows batch
after the picker, bundle, callback and live timer corrections.
Only the source pin and computed digests change; diagnostic oracles,
deadlines and coverage remain unchanged.

## be886aad38 fix(test): follow generated gesture command registration

Full SHA: `be886aad3862c5939db47b1fb9cb95933daafeb8`.

The released Windows menu now registers the generated command constant.
The common source contract still required its previous literal and rejected
the valid registration before checking the explanatory dialog. Keep the
existing three-driver invariant against the canonical representation.

Regression files:

- `tools/test/test-recommended-defaults-rule.cjs`

Proof packets:

- `evidence/scratch/windows-source-contract-final/proof.json`

## 68b6405ffe fix(windows): preserve failures from inline registry subscribers

Full SHA: `68b6405ffe6c05869982083c120812b8bee3126d`.

A scheduler can deliver its bound poll before returning. The new poll
refusal guard then caught a completed subscriber's error as though
scheduling had failed. Retirement correctly ignored the settled job, but
the caller never received its original failure.

Rethrow failures once the exact job has settled. Actual scheduler
refusals still enter owned retirement, while synchronous subscribers keep
their original thrown object or scalar and their existing native cleanup.

Four controls use the public registry request, real managed facade and
exact terminal Job acknowledgement. They distinguish a healthy inline
subscriber, errors with and without messages, and a scalar throw. The
shared Lua registry path has no Windows poll scheduler to misclassify a
synchronous completion.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_registry_inline_callback.ahk`

Proof packets:

- `evidence/scratch/windows-catalogue-inline-callback-r32/proof.json`

## 019879c561 fix(windows): report action picker confirmation failures

Full SHA: `019879c5612a2a799f3737f35f920c19ea891599`.

The picker closed before invoking an ordinary assignment callback, then
caught every exception and returned false without an error record.
Failed assignments disappeared from the central error report and logs.

Deliver the failure type and Error message through the central logger.
Record only the type for non-Error values so arbitrary thrown objects
need no conversion. Keep the existing refusal result and cleanup.

The regression runs the public picker, native GUI and genuine logger
with healthy, Error(message), Error(empty), string and Map callbacks.
The original code passes its healthy control and fails all four error
delivery assertions. macOS Logger.callback and Linux's public active
session confirmation already log callback failures.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/action_picker_confirmation_failure_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_confirmation_failure.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_startup_owner.ahk`

Proof packets:

- `evidence/scratch/windows-ui-reset-followup-r31/confirm-proof.json`

## a633dd1c34 fix(windows): recognize unquoted source startup conflicts

Full SHA: `a633dd1c34884ebf5192c7065a2a9aca7cfda971`.

Source shortcut ownership admitted an exact unquoted script argument, but
the compiled command's conflict observer only extracted quoted arguments.
A real enabled manual source command therefore left the compiled startup
mutation available even though the source getter already recognized it.

Share the existing one-argument grammar between both readers. Native LNK
regressions independently prove source ownership before checking compiled
conflicts, with quoted, disabled, extra-argument and space-path controls.
Replay every existing startup ownership case and pin the shared grammar.

Windows alone combines an AutoHotkey script argument with a Shell shortcut.
macOS uses native login items; Linux uses installed XDG desktop commands.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_start_at_login_other_source.ahk`

Proof packets:

- `evidence/scratch/windows-startup-arguments-r34/proof.json`

## a732ba4aa4 fix(windows): preserve restored configuration until reload completes

Full SHA: `a732ba4aa4801507c45ac46b157565422370ae60`.

A mandatory full-state save could run from OnExit after the Versions
page restored a backup, silently replacing the selected values with old
RAM. Settle accepted saves before the pre-restore backup and retain the
exact terminal bundle through the page delay and reload handoff.

A refused restart keeps that barrier for the existing manual Reload
recovery. Bound callbacks transfer it only once, and the existing
localized refusal notice remains visible after the page closes.

Regressions execute the original public restore click and default
writer: the healthy control passed while a pending request restored
DEBUG then exited as INFO. Cover a real native writer obstruction,
genuine cold LoggerInit, and ten whole-lifecycle handoff, refusal and
replay controls.

The Lua drivers do not have this Windows full-state terminal RAM
serializer. Their remap-specific persistence queues are separate and
remain unchanged.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/changelog_restore_lifecycle_body.ahk`
- `static/ergopti_plus/windows/tests/fixtures/changelog_restore_logger_body.ahk`
- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_changelog_restore_authority.ahk`

Proof packets:

- `evidence/scratch/windows-restore-r22/authority-proof.json`

## 8be6fffc44 fix(windows): consume complete SQLite comment tails

Full SHA: `8be6fffc440d004e28880fcf5eb1ce5a5b336db4`.

The native chunk parser retained every comment-only remainder even when
its LF or block terminator had arrived. Incremental readers therefore
rejected complete rollover tails and withheld fresh metrics.

Consume trivia after SQLite reports no statement only when all comment
heads are closed. Preserve unfinished line and block heads for the next
chunk so split input cannot turn comment prose into executable SQL.

Thirteen native controls cover public cache refresh, closed comments,
empty statements, standalone CR and split comment reconstruction. The
old parser passes five and fails eight; the corrected cases all pass.
Broader reader and SQLite comparisons introduce no new failures while
retaining their baseline native-refusal failures for Windows CI.

This carry map belongs to the AutoHotkey reader. macOS and Linux do not
use this parser, so their drivers are unchanged.

Regression files:

- `static/ergopti_plus/windows/tests/run_all.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/keystats/reader/test_klr_closed_comment_refresh.ahk`

Proof packets:

- `evidence/scratch/windows-reader-closed-comments-r36/proof.json`

## 41411f8124 fix(test): distinguish empty failures in cancellation guards

Full SHA: `41411f81241d6e0bd750ad25ddd5696b4a376bca`.

Cancellation and cleanup regressions treated an empty Error message as
proof that their complete callback did not throw. Track caught state
separately so cancellation cannot certify an unexpected exception.

Each guard now has an actual original-callback healthy control and an
empty-error mutation after real effects complete. These AHK harness
regressions are Windows-specific; Lua suites do not execute these owners.

Regression files:

- `static/ergopti_plus/windows/tests/meta/infra/config/persistence/test_config_boot_read_failure_blocks_persist.ahk`
- `static/ergopti_plus/windows/tests/meta/suite/test_no_throw_sentinel_delivery.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_api_remove_confirmation.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/servers/test_llm_delete_confirmation_owner.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/llm/servers/test_ollama_runtime_terminal_delivery.ahk`

Proof packets:

- `evidence/scratch/windows-final-r29/proof.json`

## ccdf0aa2ad fix(test): reject empty native editor cohort failures

Full SHA: `ccdf0aa2ad22bcc0efef0852c6c630195a7a7ac4`.

The healthy acquisition regression used its diagnostic text as proof
that the complete cohort callback did not throw. An actual empty Error
after all original state changes therefore passed the healthy guard.

Record the thrown state independently and exercise both the real
healthy callback and its completed-effect mutation. This only changes
a Windows AHK fixture; Lua drivers do not execute this native owner.

Regression files:

- `static/ergopti_plus/windows/tests/meta/suite/test_no_throw_sentinel_delivery.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/hotstrings/magic_key/test_magic_editor.ahk`

Proof packets:

- `evidence/scratch/windows-final-r29/magic-proof.json`

## 31bb21bb2e fix(windows): honor explicit developer interpreter choices

Full SHA: `31bb21bb2ec571b60d61184079006ab66fe78adc`.

An invalid explicit AutoHotkey path could silently launch an unrelated
installation because discovery candidates remained in the same list.
Restrict discovery to absent requests and refuse invalid explicit paths
before observing or launching any process.

Real PowerShell filesystem and entry-body controls reproduce the original
fallback. The native AHK bridge requires eight full Windows PowerShell
5.1 entry cases; Wine cannot qualify that lane. macOS and Linux have no
AutoHotkey launcher and run the common host selection controls.

Regression files:

- `static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_dev_source.ahk`
- `tools/test/test-windows-dev-script.cjs`

Proof packets:

- `evidence/scratch/windows-dev-interpreter-r34/final-proof.json`

## 4392f3631e fix(windows): retain the newest action picker opening

Full SHA: `4392f3631ee2d82576e89b2f619f23f3237906fd`.

Native GUI construction and retiring a previous browser can reenter the
public picker before the older request resumes. Revalidate the session
after both boundaries and publish only the admitted private GUI, so an
older request cannot replace a newer picker or steal its confirmation.
Retiring a revoked private window must propagate native cleanup refusal.

The regressions use actual WM_CREATE and a native timer inside browser
retirement, with a positive public confirmation control. macOS and Linux
already publish and revalidate exact session owners at these boundaries.

Regression files:

- `static/ergopti_plus/windows/tests/fixtures/action_picker_create_owner_body.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_create_owner.ahk`
- `static/ergopti_plus/windows/tests/unit/ui/webview/test_action_picker_startup_owner.ahk`

Proof packets:

- `evidence/scratch/windows-picker-create-followup-r31/final-proof.json`

## cc705f5ae4 chore(windows): seal the final audited source cohort

Full SHA: `cc705f5ae4ae466469e80feb5c77b5ad825c3912`.

The final regression fixtures and driver repairs change sealed inputs.
Regenerate their canonical receipt from the committed source so updater
diagnostics verify the delivered cohort rather than an earlier checkout.

## Integration merges

These normal merges import dev under the final synchronization instruction.

- `76641ecf59c26513df678d77bbf666a79809306b` chore(windows): merge current dev before release validation
- `316948379a689a1a1c922f22c339aa6b224ca255` chore(windows): merge the latest release corrections from dev
- `67bd549471adaf90e12acc6bc9a3522fe04aa956` chore(windows): merge the current release snapshot from dev
- `a941a021a2e28bd4e9bc8b3ba823385d5c192c83` chore(windows): merge dev before the native CI followups
- `66d446f5708f46c3ae43f4407fcb4e77dbfe5b56` chore(windows): merge current release fixes before validation
- `7fbcfc3727e586c16224de957d7deab7a57bc318` chore(windows): merge the latest release dependency fixes
- `34e6c7889fe91a3d4e3c2011f7670f2de95e2908` chore(windows): merge current release fixes from dev
- `b542792f3e6b63edc68e3a60b482a979f6a39409` chore(windows): merge released gesture menu updates from dev
- `148b4aa4044e54f9c7386259bfa318aa07b2323a` chore(windows): merge current dev installer test fixes
- `8e636fc9fde012e37a1a15a30d03d62a67ed8fa8` chore(windows): merge current release qualification from dev
- `3c88b1db2320067e2b49b9c4037d50ada5c14c38` chore(windows): merge current release source contracts
- `fe3d8b010779a2666ef9307305c68f1bc9d92428` chore(windows): merge current release history

## Post-validation Windows corrections

### a2fc97973e fix(test): include registry shutdown in the program envelope

Full SHA: `a2fc97973e4f2d9a67e384a7b2b3e92006401cb3`; original: `5ce0e246954ef3d150d9eb19a720fa9b2b0f4e6d`.
The extracted production handler now asks the registry download owner
before program retirement. Its native fixture omitted that dependency,
so an unset call became an earlier shutdown refusal and failed the
actual Windows lane before reaching program ownership.
Export the faithful ready owner and require exactly one registry call
on every shutdown attempt. This isolated AHK child is Windows-only;
macOS and Linux do not execute this handler or fixture.

Regression files:

- `static/ergopti_plus/windows/tests/support/run_program_shutdown_envelope.ahk`

Integration proof: `post-validation-evidence/evidence/windows-post-ci-integration/receipts.json` in `post-validation-evidence.tar.gz`.

### 2ad1daa540 fix(windows): resume native admission after registry refusal

Full SHA: `2ad1daa5405a2ab9dada5cef2a1212933e6a3f5d`; original: `c8e977a8fb138082967a02a2531bf771fcbc6326`.
Registry cleanup could refuse after navigation admission was fenced but
before the compensating finally block began. A cancelled shutdown then
returned to the live driver with native admission still fenced.
Run that refusal gate inside both reversible ownership scopes, after
held modifiers release and before user programs retire. Genuine handler
children cover ready, false, Error and empty Error results, exact bundle
return, one native cancellation and preserved pause/generation state.

macOS and Linux do not execute this AHK OnExit/native-owner contract.

Regression files:

- `static/ergopti_plus/windows/tests/support/run_program_shutdown_envelope.ahk`
- `static/ergopti_plus/windows/tests/unit/modules/shortcuts/test_run_program_actions.ahk`

Integration proof: `post-validation-evidence/evidence/windows-post-ci-integration/receipts.json` in `post-validation-evidence.tar.gz`.

### 0d524fa308 fix(test): serialize absent interpreter choices as null

Full SHA: `0d524fa308358dc54fcca497686ce90411ef2d21`; original: `7348172a5698c0ab5251a1958b9d1e1448676fb4`.
The Windows PowerShell 5.1 native fixture correctly refused missing
explicit interpreters, but serializing the empty pipeline value retained
an object wrapper. Its strict consumer therefore rejected a correct
refusal. Build one canonical receipt with a literal null field and publish
only nonnull selections.
Keep strict null assertions and all eight complete native entry controls.
Exercise literal null, actual pipeline exhaustion, AutomationNull and a
nonnull path through the same producer on every host. The original
Windows CI failure supplies the native before proof; PowerShell 7 host
controls cannot qualify Windows PowerShell 5.1.

Regression files:

- `tools/test/fixtures/windows_dev_interpreter_controls.ps1`
- `tools/test/test-windows-dev-script.cjs`

Integration proof: `post-validation-evidence/evidence/windows-post-ci-integration/receipts.json` in `post-validation-evidence.tar.gz`.
