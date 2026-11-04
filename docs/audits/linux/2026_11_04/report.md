# linux deep module audit

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`. Date: 2026-11-04.

This immutable evidence groups separately reviewed modules. Reproductions using real modules and controlled native seams are distinguished from unexecuted native scenarios in each source report. Native desktop certification is not claimed.

| Module           | Findings                  | Evidence, intentional differences and limits                                      |
| ---------------- | ------------------------- | --------------------------------------------------------------------------------- |
| linux-hotstrings | LIN-001, LIN-002, LIN-003 | [Module report](../../platform-parity/2026-11-04-deep/linux-hotstrings/report.md) |
| linux-input      | LIN-004                   | [Module report](../../platform-parity/2026-11-04-deep/linux-input/report.md)      |
| linux-llm        | LIN-005, LIN-006          | [Module report](../../platform-parity/2026-11-04-deep/linux-llm/report.md)        |
| linux-metrics    | LIN-007                   | [Module report](../../platform-parity/2026-11-04-deep/linux-metrics/report.md)    |
| linux-lifecycle  | LIN-008                   | [Module report](../../platform-parity/2026-11-04-deep/linux-lifecycle/report.md)  |
| linux-gestures   | LIN-009, LIN-010          | [Module report](../../platform-parity/2026-11-04-deep/linux-gestures/report.md)   |

## Confirmed actionable findings

### LIN-001 — Registered single-field dynamic expansions have no production preview row

Source ID: `LH-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/probe.lua",
"observed": "Enabled @p and td/dt/date resolve through the real manager but static candidates plus dynamic preview_candidates return zero rows; @pn returns one row as positive control.",
"native_reproduction": false
}

**Root cause:**

Daemon ergopti_hotstrings.lua:1499-1512 composes static candidates and manager.preview_candidates only. Aliases/dates register solely in shared dynamic engine (manager.lua:209,221); prefix_mappings exports no such rows. preview_candidates intentionally drops single-field tags at manager.lua:594 and dates at :587. The resolving M.preview API at :621 has no daemon caller.

**Why existing handling misses it:**

Supported expansions fire but their preview is absent without warnings.

**Required regression:**

Drive actual daemon candidate composition for enabled/disabled single aliases and each date family, asserting one masked/classified row only when admitted; include multi-field positive control and unknown boundary refusal.

### LIN-002 — Invisible previews increment offered-suggestion metrics

Source ID: `LH-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/probe.lua",
"observed": "Exact extracted daemon show/metrics fragment with tooltip_preview.show returning false still emits one record_suggestion and commits \_last_offered.",
"native_reproduction": false
}

**Root cause:**

ergopti_hotstrings.lua:1529 ignores the boolean returned by preview.show and unconditionally commits offered state / metric at :1538-1540. ui/tooltip/preview.lua:431-433 and :451 return false for disabled toggle/category/unavailable renderer. keystats.lua:1083 persists offered counters.

**Why existing handling misses it:**

hs_suggested grows for offers never displayed, silently skewing acceptance data and deduplication.

**Required regression:**

Refuse preview for disabled toggle, category and unavailable renderer; assert no offered telemetry/deduplication commit. Then successfully show the same row and assert one count across redraws.

### LIN-003 — Built-in dynamic expansions bypass configured expansion-delay admission

Source ID: `LH-003`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/probe.lua",
"observed": "Real buffer receives td and magic with 1000 ms completing gap. Shared normal timing gate rejects a 0.01-second window; real manager dynamic fallback still injects once. Production source confirms no resolved delay/timing reaches this fallback.",
"native_reproduction": false
}

**Root cause:**

within_delay in ergopti_hotstrings.lua:1340 only guards static results/cascade. Late dynamic dispatch at :1575 supplies buffer, key, boundary and destination but no timing admission. manager.on_trigger at manager.lua:465 and combo path at :399 never consult delay or timing. Programmable path independently applies proper timing at infra/user_hotstring_runtime.lua:35-37. Windows built-in date registrations carry TimeActivationSeconds (dynamic_hotstrings.ahk:135).

**Why existing handling misses it:**

A built-in dynamic expansion commits after its configured deadline while ordinary prefix/static expansion respects it.

**Required regression:**

Drive actual daemon callback with fake monotonic times and resolved dynamic delay for alias/date/combo routes, testing below/exact/above deadline, zero, missing timing and complex keys with a longer idle threshold.

### LIN-004 — Production Linux physical shortcut editor and active physical-action delivery remain unqualified and unavailable

Source ID: `LI-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "LUA_CPATH='/workspace/scratch/parity-toolchain/modules/?.so;;' /workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-input/probe-physical-availability.lua",
"observed": "Actual production delivery getter=false, bridge available/open=false, shared menu ready/open=false, even while GUI readiness is controlled true. No GUI/capture/save invoked.",
"expected": "Availability inventory, README/site/TODO must state unsupported until qualified native broker/source/all-owner/output integration exists; preserve guard.",
"evidence_path": "docs/audits/platform-parity/2026-11-04-deep/linux-input/probe-physical-availability.log"
}

**Root cause:**

{
"locations": [
"static/ergopti_plus/linux/modules/shortcuts/keyboard_shortcuts.lua:732",
"static/ergopti_plus/linux/ui/physical_shortcuts/bridge.lua:24",
"static/ergopti_plus/linux/infra/shortcuts_scope.lua:463",
"static/ergopti_plus/_shared/lua/shortcuts/physical_editor_menu.lua:15"
],
"description": "Physical delivery is deliberately unqualified and production getter returns false unconditionally. Prior audit inferred native feature support from bridge/capture components and tests with capability=true."
}

**Why existing handling misses it:**

Not silent in runtime: menu/bridge correctly refuse. Audit/inventory can falsely claim conditional availability because shared editor assets, native observer and controlled host tests exist.

**Required regression:**

Pin documented unavailable status to actual production getter; keep a real getter -> bridge -> menu test showing unavailable regardless of GUI readiness. When enabling later, require evidence of qualified end-to-end native source/all-owner collision/output custody rather than replacing the guard with true.

### LIN-005 — Interrupted Ollama chat overwrites successor admitted by cancellation terminal callback

Source ID: `LL-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"artifact": "docs/audits/platform-parity/2026-11-04-deep/linux-llm/probe-ollama.lua",
"command": "LUA_CPATH='/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;' LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu /workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-llm/probe-ollama.lua",
"observed": "Start A; A cancellation callback starts C; start B, which cancels A. All three dispatch. Completing C produces zero terminal callbacks; B completes normally. Real API loaded, stable runtime owner and scripted asynchronous transport only.",
"native_reproduction": false
}

**Root cause:**

api_ollama.lua M.chat:246 invokes M.cancel then resumes epoch increment (:247) and active-owner assignment (:293) without checking for a successor. M.cancel:371 publishes finish_request; its callback (:172) can admit C. The older B call overwrites C and later request_current suppresses all C callbacks. Remote cancel_exchange/open_exchange explicitly fence this kind of successor.

**Why existing handling misses it:**

Successor C has an admitted dispatch but never receives result or cancellation, potentially retaining its caller's pending state.

**Required regression:**

Real backend transcript with cancellation terminal observer admitting successor while competing chat is interrupted. Assert no overwrite and one terminal outcome per admitted request; also cover native cancel callback reentry.

### LIN-006 — Refused translation dispatch leaves permanent loading offer

Source ID: `LL-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"artifact": "docs/audits/platform-parity/2026-11-04-deep/linux-llm/probe-translation.lua",
"command": "LUA_CPATH='/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;' LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu /workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-llm/probe-translation.lua",
"observed": "Real engine/remote backend: translate A, refuse native HTTP cancellation, translate again, settle A. One HTTP post only, predicting=true, loading=true, zero offered candidates after A settles.",
"native_reproduction": false
}

**Root cause:**

prediction_engine.lua open_offer:1632 opens loading/advances epoch; translate_selection dispatch at :2186 ignores backend.chat false. Real api_remote open_exchange:941-942 can refuse cancellation and chat:1169 returns false without terminal callback. Old response is correctly stale, leaving nobody to retire the new loading state. Ordinary prediction :1088-1097 already handles this same contract.

**Why existing handling misses it:**

New translation reports accepted and retains spinner/predicting forever despite owning no dispatched response; automatic predictions remain blocked until another cancel/action.

**Required regression:**

Actual engine and remote backend, repeated translation with native cancellation refusal then eventual old completion. Assert clean refusal or one retirement of new loading, stale response suppression, successor preservation, and synchronous completion controls.

### LIN-007 — Excluded collection spans remain inside typing sequences and durations

Source ID: `LM-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-metrics/probe-boundary.lua",
"steps": [
"Record a@1000; optionally flush with repository fake transport.",
"Enter pause/private/secure/suppressed/disabled state; attempt X@1100; exit state.",
"Record b@1200 and space@1300; flush."
],
"observed": "All 10 cases produce word ab count1, bigram ab count1 td200, typing_time_ms300; excluded X is absent.",
"expected": "An explicit exclusion terminates observed typing continuity; no invented ab word/bigram or credited cross-exclusion inter-key delay.",
"evidence_path": "docs/audits/platform-parity/2026-11-04-deep/linux-metrics/probe-boundary.log",
"limits": "Real core/shared walker with repository fake writer and isolated preferences; no real SQLite COMMIT claim."
}

**Root cause:**

{
"locations": [
"static/ergopti_plus/linux/modules/keystats/keystats.lua:1644",
"static/ergopti_plus/linux/modules/keystats/keystats.lua:782",
"static/ergopti_plus/linux/modules/keystats/keystats.lua:845",
"static/ergopti_plus/linux/modules/keystats/aggregate_walker.lua:184"
],
"description": "Policy settlement retires focus/title/hold ownership but not buffered typing-run continuity, last-key cursors or committed walker context."
}

**Why existing handling misses it:**

All calls succeed and filtered text stays absent, while persisted aggregate payload invents contiguous text and includes excluded elapsed time; dashboards cannot identify the discontinuity.

**Required regression:**

Cover five public exclusion paths both within one pending snapshot and across an acknowledged flush; require excluded X absent, no cross-boundary ab ngram/word, zero cross-boundary timing credit, retained valid a/b history; add pending/failed/retried flush boundary case.

### LIN-008 — Configuration restore announces restart even when restart is refused or unavailable

Source ID: `LC-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/LuaJIT-2.1/src/luajit docs/audits/platform-parity/2026-11-04-deep/linux-lifecycle/probe-restore-restart.lua",
"environment": "LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu; LUA_CPATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/workspace/scratch/parity-toolchain/modules51/?.so;;",
"steps": [
"Use real changelog bridge through existing authenticated document fixture and successful backup restore model.",
"Make state.restart return false, then test absent state.restart.",
"Post restore_backup; inspect returned response and shared restored-phase message."
],
"observed": "Both return phase=restored with no restarted/reason metadata; shared page displays Configuration restored: ErgoptiPlus restarts on it.",
"expected": "Preserve acknowledged restored bytes and pre-image, but visibly state restart required/refused rather than claiming restart.",
"evidence_path": "docs/audits/platform-parity/2026-11-04-deep/linux-lifecycle/probe-restore-restart.log",
"limits": "Effect-isolated backup/restart fixture, real bridge+shared locale. No real byte restore or process restart claim in this probe."
}

**Root cause:**

{
"locations": [
"static/ergopti_plus/linux/ui/changelog/bridge.lua:628",
"static/ergopti_plus/linux/ui/changelog/bridge.lua:632",
"static/ergopti_plus/_shared/ui/changelog/script.js:1307",
"static/ergopti_plus/_shared/data/locales/en.json:201"
],
"description": "Missing/refused restart logs error, then uses the same unconditional restored response as accepted restart; shared UI promises the app restarts."
}

**Why existing handling misses it:**

Restart failure is log-only; user sees restart success wording while old runtime can remain active on stale configuration. Restored disk bytes are not claimed lost.

**Required regression:**

Cover successful handoff, false/missing/throwing restart; require visible restored-but-restart-required outcome, preserved pre-restore path and restored bytes; do not turn restart refusal into file rollback.

### LIN-009 — Linux advertises and accepts three unreachable horizontal-axis gesture slots

Source ID: `LG-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"artifact": "docs/audits/platform-parity/2026-11-04-deep/linux-gestures/probe.lua",
"observed": "Real manager accepts tab_next for swipe_3_horiz/swipe_4_horiz/swipe_5_horiz and reachability says true on five-finger hardware. Real decoder returns right and dispatch is false for each aggregator-only binding. Directional binding positive control reaches the recording emitter once.",
"native_reproduction": false
}

**Root cause:**

manifest.toml:3287,3344,3401 and menu_gestures.lua:114 expose Linux axis slots. manager.lua:291 includes them in editable defaults and set_action:1235 accepts them. slot_report.lua:25 only checks finger count. Actual \_slot_for_gesture:1918/dispatch_gesture:1952 select only tap or named direction, while shared actions.toml:116 explicitly documents axes as macOS-only.

**Why existing handling misses it:**

A binding saves and appears reachable but never fires; generated website inventory also declares Linux support from the false source declaration.

**Required regression:**

Enumerate every advertised Linux slot through actual recognizer/dispatcher traces or an explicit unsupported reason. Include each horizontal aggregator alone plus left/right positive controls, and verify menu and generated matrix agree with runtime capability.

### LIN-010 — Clearing persistent MT coordinate registers on lift drops subsequent valid gestures

Source ID: `LG-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"artifact": "docs/audits/platform-parity/2026-11-04-deep/linux-gestures/probe.lua",
"observed": "Existing repository input_core_emulation constructor plus one real persistent decoder: two identical horizontal swipes produce first y_reports=3 gestures=1, second y_reports=0 gestures=0. Changed-Y control (+10 units on second swipe) produces second y_reports=3 gestures=1. Real native device not exercised.",
"native_reproduction": false
}

**Root cause:**

mt_decoder.lua:299 drops slot.x/y at tracking ID -1; reset:220 clears all slot registers and current slot at :221-222, called on gesture completion :413. Kernel MT absolute registers persist across contacts and unchanged fields can be filtered (existing input_core_emulation.lua:42-55). centroid:241 requires both coordinates at :244, so a fresh horizontal contact lacking unchanged Y never contributes.

**Why existing handling misses it:**

A valid configured gesture produces no output or diagnostic until both required coordinate axes happen to be reported again.

**Required regression:**

Pass successive gestures through existing input-core filtering into one decoder, covering unchanged X/Y, reused slots, stationary contacts and changed-axis controls. Separate protocol-register lifetime from gesture state, with independent startup/SYN_DROPPED recovery policy.

## Validation and coverage boundaries

Each linked module report records executed commands, initial dependency failures, successful reruns, unsupported native scenarios, refutations and explicit versus inferred intentional differences. Counts from overlapping batches must not be summed as unique test coverage. Performance is unmeasured unless a report supplies actual timing evidence.

The shared audit workflow validates the AHK and Hammerspoon manifests. Its scope vocabulary does not support Linux; the Linux manifest is validated against the same required field types/enums by the integration check, without claiming official Linux workflow support.
