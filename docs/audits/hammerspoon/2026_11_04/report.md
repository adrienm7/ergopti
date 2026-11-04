# macos deep module audit

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`. Date: 2026-11-04.

This immutable evidence groups separately reviewed modules. Reproductions using real modules and controlled native seams are distinguished from unexecuted native scenarios in each source report. Native desktop certification is not claimed.

| Module           | Findings                       | Evidence, intentional differences and limits                                      |
| ---------------- | ------------------------------ | --------------------------------------------------------------------------------- |
| macos-hotstrings | HS-001                         | [Module report](../../platform-parity/2026-11-04-deep/macos-hotstrings/report.md) |
| macos-input      | HS-002                         | [Module report](../../platform-parity/2026-11-04-deep/macos-input/report.md)      |
| macos-llm        | HS-003                         | [Module report](../../platform-parity/2026-11-04-deep/macos-llm/report.md)        |
| macos-metrics    | HS-004, HS-005, HS-006, HS-007 | [Module report](../../platform-parity/2026-11-04-deep/macos-metrics/report.md)    |
| macos-lifecycle  | HS-008, HS-009                 | [Module report](../../platform-parity/2026-11-04-deep/macos-lifecycle/report.md)  |
| macos-gestures   | HS-010, HS-011                 | [Module report](../../platform-parity/2026-11-04-deep/macos-gestures/report.md)   |

## Confirmed actionable findings

### HS-001 — Programmable static preview metadata is parsed as output tokens on macOS

Source ID: `MH-001`; severity: **low**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "LUA_CPATH=\"/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;\" LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu /workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/macos-hotstrings/probe-programmed-preview.lua",
"observed": "Exact descriptor and actual callback literal output preserve Literal {Left} {U+0041}; actual bridge row displays Literal A. Callback runs only after physical magic dispatch, once.",
"boundaries": "Real programmable source/owner/keymap/deferred output and real bridge/registry/expander row builder in separate fixture phases; Hammerspoon input/AX/timer and canvas sink are native doubles. No native Mac execution."
}

**Root cause:**

macos/modules/keymap/llm_bridge.lua:413 provider_plain unconditionally parses every provider string through tokens_from_repl and plain_text; :850 uses this result for static programmable preview descriptors although user_code.lua projects row.preview unchanged and callback output uses literal emit_text.

**Why existing handling misses it:**

No error; callback still works but braces/key-looking fragments disappear or change in its advertised static description.

**Required regression:**

Run actual programmable preview containing literal {Left} and {U+0041} through real bridge row builder and assert byte-exact descriptor display; retain callback-not-run-on-preview and literal-output controls plus ordinary static TOML output-token preview tests.

### HS-002 — Catalogue layer_on/layer_off actions do not synchronize the macOS navigation wheel owner

Source ID: `MI-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/macos-input/probe-gesture-wheel.lua",
"observed": "layer_on requests layer_active=1 but wheel passes scroll; after F20 entry, layer_off requests layer_active=0 but wheel still posts SOUND_UP; F19 control fixes the same owner.",
"boundaries": "Actual production action registry, wheel owner and sentinel owner; mocked accepted Karabiner variable-write boundary and Hammerspoon event/timer APIs. No native macOS execution."
}

**Root cause:**

macos/modules/gestures/actions.lua:966-972 writes layer_active through ke_variables.set without completion/state publication; macos/modules/shortcuts/actions/system.lua:1048 tracks layer_held only from F20/F19 generator sentinels. CLI variable writes produce no sentinel.

**Why existing handling misses it:**

The action and native variable write can succeed without any error while wheel behavior disagrees with the keyboard navigation layer.

**Required regression:**

Compose real action registry and wheel owner; assert entry from layer_on and exit from layer_off after exact-generation successful write, plus refused and superseded writes. Existing probe-gesture-wheel.lua supplies both failing behaviors and a healthy sentinel control.

### HS-003 — Sequential local streams and retries share a request-scoped cumulative thinking filter

Source ID: `ML-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"kind": "executed_real_production_composition",
"artifact": "docs/audits/platform-parity/2026-11-04-deep/macos-llm/repro-sequential-stream-filter.lua",
"logs": [
"docs/audits/platform-parity/2026-11-04-deep/macos-llm/repro-sequential-stream-filter.log",
"docs/audits/platform-parity/2026-11-04-deep/macos-llm/repro-sequential-stream-retry.log",
"docs/audits/platform-parity/2026-11-04-deep/macos-llm/repro-sequential-stream-control.log"
],
"steps": [
"Enable streaming and streaming-multi; choose non-batch profile and two candidates on MLX or Ollama",
"First independent transport streams its completion and succeeds",
"Second independent transport streams a different completion; handler treats new prefix as malformed and suppresses interim output until final"
],
"executed": true,
"runtime": "Lua 5.4.8 + repository Hammerspoon and transport doubles; no native Mac claim"
}

**Root cause:**

{
"consumer": "macos/modules/llm/streaming_handler.lua:297",
"prefix_rejection": "macos/modules/llm/streaming_handler.lua:310",
"producers": [
"macos/modules/llm/api_mlx_fetch.lua:224",
"macos/modules/llm/api_ollama.lua:2291"
],
"description": "One filter/partial_raw_seen is retained for whole request while same callback receives independent cumulative strings from multiple variants and retries."
}

**Why existing handling misses it:**

Later token previews stop rendering but final candidates still succeed; only a cumulative-prefix warning identifies the mismatch. Failed partial plus retry has the same outcome.

**Required regression:**

Compose actual local strategy and handler for two successful independent streams and partial-failure/retry. Assert interim rendering for admitted streams and final candidates. Retain valid cumulative and malformed same-stream prefix controls, plus thinking-tag suppression.

### HS-004 — Metrics collection pause still records window activity and later credits paused pointer travel

Source ID: `MM-001`; severity: **high**; confidence: **high**.

**Reproduction and evidence:**

Run probe.lua. With collection_suspended=true, real context_tracker appends PAUSED SECRET window_switch and real watcher appends space_change; a 1000px movement during the pause is included by exact snapshot function after resume. Exact real append_log/FIFO body forwards paused title to Rotation.

**Root cause:**

User pause is checked in privacy_context.allows_logging, but watcher/context_tracker production callbacks receive \_is_paused that checks global script_control only. LogManager.append_log and Rotation do not apply admission; pointer baseline/state are not reset across user pause.

**Why existing handling misses it:**

UI reports collection suspended while identifying activity metadata continues down JSONL/SQL path and paused pointer distance backfills next typing entry. Existing tests gate global pause or typing-only paths.

**Required regression:**

Invoke real Metrics suspend/resume and browser title/app/spaces/mouse callbacks with shared CoreState; assert no paused metadata or pointer delta, allowing previously admitted closing rows.

### HS-005 — macOS measured passive sleep and lock durations remain zero in dashboard aggregates

Source ID: `MM-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

Run probe.lua. Actual caffeinate callback emits a 60000ms sleep and 30000ms lock passive_period; actual aggregator produces sleep_ms=0, locked_ms=0, passive_count=2.

**Root cause:**

Watchers put durations on passive_period(kind,duration_ms), while aggregator.events only counts that action and credits sleep/lock duration from bare wake/unlock edges. macOS has no Windows-style SQL system-duration rebuild.

**Why existing handling misses it:**

Nonzero passive counts accompany zero durations in system manifest and dashboards. Cache replay and foreign imports use same incorrect walker.

**Required regression:**

Replay actual producer event pairs through raw storage/rebuild and aggregate flush/manifest; assert exact lock/sleep durations and no double counting legacy duration-bearing edges.

### HS-006 — macOS keep-awake completion events never populate keep-awake accounting

Source ID: `MM-003`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

Run probe.lua. Feed exact producer pair passive_period(kind=awake,duration_ms=120000) and awake_focus(app=Editor,duration_ms=120000) into actual event walker; system awake_ms stays 0.

**Root cause:**

Keep-awake shortcuts emit both accounting records, but macOS aggregator has no duration branch for awake passive periods or app awake_focus. It initializes awake_ms to zero and never increments it.

**Why existing handling misses it:**

Dashboard keep-awake totals remain empty and app focus accounting cannot exclude these sessions as UI expects; replay repeats omission.

**Required regression:**

Exercise actual keep-awake stop and auto-stop into live/replay system and app aggregates; verify full interval once globally and expected per-app focus subtraction/toggle.

### HS-007 — macOS nested lock and sleep transitions overwrite passive interval ownership

Source ID: `MM-004`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

Run probe.lua. At one-second increments drive lock -> screensDidSleep -> systemWillSleep -> systemDidWake -> screensDidWake -> unlock. Actual watcher emits only one passive_period, kind sleep, duration_ms 1000; lock and earlier sleep segments disappear. Native ordering not measured, sequence uses accepted public callback inputs.

**Root cause:**

Single passive_started_at/passive_kind slot is blindly replaced on every lock/display/system sleep, then cleared by first wake; no independent locked/sleeping state or duplicate-edge idempotence.

**Why existing handling misses it:**

Missing durations are absent from raw metrics and unrecoverable by correcting aggregation. Completed count and sleep-vs-lock partition also become inaccurate.

**Required regression:**

Replay nested/repeated lock/sleep/display edges and assert exact non-overlapping partition, pre/post-sleep locked portions, duplicate-edge idempotence and pause/shutdown interval ownership.

### HS-008 — Failed onboarding Finish retains new configuration locator and locale

Source ID: `MC-001`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"kind": "executed_real_finish_controller",
"artifact": "docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/repro-onboarding-partial-state.lua",
"log": "docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/repro-onboarding-partial-state.log",
"executed": true,
"cases": [
"successful moved-directory control",
"final writer false",
"final writer throws",
"actual destination schema_version=999 refusal before any config batch write"
],
"observed": "Failure closes wizard with error and no reload, while path_writes=1 still names new directory and locale_persists=1."
}

**Root cause:**

{
"producer": "macos/ui/onboarding/init.lua:722",
"later_failure": "macos/ui/onboarding/init.lua:753",
"failure_handler": "macos/ui/onboarding/init.lua:570",
"canonical_locator": "macos/infra/config_paths.lua:729",
"description": "Locator/locale commit before destination versioning and main configuration publication; outer Finish owner has no inverse for these fields."
}

**Why existing handling misses it:**

Error claims failed Finish, but locator/locale changes persist independently; later saves resolve new directory while old runtime survives. Original directory is not claimed deleted.

**Required regression:**

Move directory then reject destination schema or fail/throw main publication; require old directory/locale or retained exact compensation debt; retain success and concurrent-external-change controls.

### HS-009 — Restored configuration UI promises restart despite refused or throwing reload

Source ID: `MC-002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"kind": "executed_real_versions_bridge",
"artifact": "docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/repro-restore-reload-ack.lua",
"log": "docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/repro-restore-reload-ack.log",
"executed": true,
"cases": [
"reload true",
"reload false",
"reload throws"
],
"observed": "All cases publish restoring,restored; false/throw only log, canonical UI text says app restarts."
}

**Root cause:**

{
"owner": "macos/ui/changelog/init.lua:587",
"premature_success": "macos/ui/changelog/init.lua:610",
"refusal_log_only": "macos/ui/changelog/init.lua:613",
"description": "Restored phase publishes before reload receipt; immediate refusal and later abort have no visible pending-reload/failure state."
}

**Why existing handling misses it:**

Disk restore succeeded but old process may remain; page hides restore button and promises restart without exposing reload failure. Linux counterpart shares behavior; Windows reports refusal.

**Required regression:**

Drive restore success with reload true/false/throw and asynchronous abort. Require explicit disk-restored/reload-required state on refusal, backup path retained, and no false restart message.

### HS-010 — System-gesture preference probes never start their prepared ShellRunner tasks

Source ID: `MG001`; severity: **high**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/macos-gestures/probe-conflict-probes.lua",
"observed": "Actual ShellRunner constructs4 native task doubles; starts0, callback0; repeated recheck joins pending probe, swipe_3_left stays free. Starting the exact4 retained handles and completing enabled preference reads changes it to taken.",
"boundaries": "Real conflict module and real ShellRunner lifecycle over hs.task native doubles; no real commands, macOS settings or native actions."
}

**Root cause:**

macos/modules/gestures/conflicts.lua:259-296 calls ShellRunner.spawn and retains/checks handles but never calls handle.start. Real shell_runner.lua:784 prepares, :793 exposes start, :831 returns without starting. snapshot_ready never changes, so conflict slots initially return free.

**Why existing handling misses it:**

Refresh returns true without a start error; pending probe never drains and native conflict warning/disable policy has no actual settings snapshot.

**Required regression:**

Use real ShellRunner with recording native task construction/start/terminal; require four starts and terminal/failure settlement; repeat refresh and settings changes, exact shutdown, and fail-closed slot admission before first snapshot. Existing spawn doubles must model prepared/start lifecycle.

### HS-011 — Tap commit dispatch bypasses the macOS system-gesture conflict gate

Source ID: `MG002`; severity: **medium**; confidence: **high**.

**Reproduction and evidence:**

{
"command": "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua docs/audits/platform-parity/2026-11-04-deep/macos-gestures/probe-tap-conflict.lua",
"observed": "Real engine with system_held always true dispatches lookup on stationary3-contact tap/lift and never queries predicate. Horizontal swipe control queries same predicate and dispatches nothing.",
"boundaries": "Real gesture engine over native touch/clock/eventtap doubles; action recorders only, no real lookup or output."
}

**Root cause:**

engine.lua:700-716 calls dispatchAction directly in tap branch; triggerAction:451-459 alone applies state.system_held. multiFingerAllowed:300 checks physical recognition policy, not native ownership. conflicts.lua:120-127 explicitly declares tap_3 blocking.

**Why existing handling misses it:**

Tap logs TAP FIRE with no conflict rejection even when system-held state is true; fixes to preference probing do not fix this independent dispatch omission.

**Required regression:**

Replay real tap commit for taken/unverified/free tap_3 state; assert no dispatch while held and one single-shot dispatch when free, alongside existing swipe control, AI and pause gates.

## Validation and coverage boundaries

Each linked module report records executed commands, initial dependency failures, successful reruns, unsupported native scenarios, refutations and explicit versus inferred intentional differences. Counts from overlapping batches must not be summed as unique test coverage. Performance is unmeasured unless a report supplies actual timing evidence.

The shared audit workflow validates the AHK and Hammerspoon manifests. Its scope vocabulary does not support Linux; the Linux manifest is validated against the same required field types/enums by the integration check, without claiming official Linux workflow support.
