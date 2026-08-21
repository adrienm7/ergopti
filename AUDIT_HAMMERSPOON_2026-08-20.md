# Adversarial Audit — ErgoptiPlus Hammerspoon Driver

Date: `2026-08-20`  
Audited tree: `5ee09a526` (`dev`; the Hammerspoon Lua tree is unchanged from `173519394`, on which the exclusive Lua suite was first run)  
Scope: `static/ergopti_plus/macos/`, its shared Lua/data dependencies, relevant launcher/native contracts, and `tests/`

## 1. Executive summary

This pass and its implementation-phase rescan found **34 confirmed defects**: **16 High**, **16 Medium**, **2 Low**, and **0 Critical**. “Confirmed” means that the state is reachable, the exact source path was re-opened, a concrete reproduction sequence exists, and the existing tests were inspected for a contradiction. No candidate was promoted merely because a source pattern looked suspicious.

| Severity       | Count | IDs               |
| -------------- | ----: | ----------------- |
| High           |    16 | `HS-001`–`HS-011`, `HS-021`, `HS-022`, `HS-024`, `HS-025`, `HS-033` |
| Medium         |    16 | `HS-012`–`HS-019`, `HS-023`, `HS-026`–`HS-029`, `HS-031`, `HS-032`, `HS-034` |
| Low            |     2 | `HS-020`, `HS-030` |
| Critical       |     0 | —                 |

The most fragile areas are:

- **Native and asynchronous ownership.** Touch-device start/stop, MLX server replacement, Ollama pulls, onboarding tasks, and semantic HTTP operations confuse “the call returned” with “the capability committed or settled.”
- **Sibling paths outside a common transaction.** Repeat-key, navigation retention, configurable shortcut edits, gesture screenshots, and several pause-only paths bypass an invariant already implemented correctly by a sibling.
- **False-green tests.** Several tests assert a friendly stub’s state or scan for one token while omitting the native refusal, reordered completion, or transitive caller that carries the real failure.
- **Input-path work.** Terminal pacing deliberately sleeps/posts inside the originating eventtap callback, and the keylogger can JSON-encode and write JSONL before its taps return.

Verdict: the five guarantees are **not proven**. `G1`–`G3` and `G5` have concrete counterexamples below. `G4` has confirmed structural violations, but no production macOS profile artifact was available on this Windows audit host; therefore latency magnitude and percentile claims remain explicitly unmeasured.

What this pass added beyond the repository’s prior guard tests and project memory:

1. It checked the actual native return contracts for the private touch-device module and `hs.httpserver`, rather than trusting Lua truthiness.
2. It tested same-generation and below-the-fence effects, not only cross-generation final callbacks.
3. It enumerated the engine/preview mutation ledger and direct synthetic producers, finding two `G5` divergences despite the shared resolver being correct.
4. It resolved the configured log root before evaluating performance evidence and separated production artifacts from test fixtures.
5. It performed multi-pass, two-lens source/test refutation and records which domains became dry.
6. It resolved the undefined `BLINDER` label to the launcher/lease guardian boundary by exact repository search, then audited its ACK, HUP, STOP/EOF, identity, and termination ordering instead of silently omitting it.

### Verification snapshot

- Exclusive Hammerspoon Lua suite: `5369` passed, `0` failed, `813` modules. The runner exited `0`. This was a Windows-hosted shim suite, not a native macOS integration run.
- The four `Slow` lines in `D:/tmp/ErgoptiPlus_2026-08-20.log` are duplicated test-fixture output at lines `575375`–`575378`; line `575379` immediately resumes a passing provenance test. They are **not** production measurements.
- `D:/tmp/ErgoptiPlus_boot.log` contains `0` case-sensitive `Slow` lines.
- No production profile directory was found at the resolved configured location or the two fallback locations listed in [Performance](#4-performance). This is an absence claim only for those exact paths on this host.
- No pre-existing `AUDIT_HAMMERSPOON_2026-08-20*.md` existed, so no suffix was needed. The unrelated untracked `AUDIT_AHK_2026-08-20.md` was not touched.

### Implementation status on `codex/hammerspoon-audit-fixes`

This register is updated in the same commit as each completed fix. The worktree starts from current `dev` at `83bbc9120`; two fixes were already bundled in that baseline commit history (`c6d081890`) and are identified explicitly rather than rewritten.

- [x] `HS-001` — `a6569e02e` (`fix(gestures): make touch watchers transactional`)
- [x] `HS-002` — `5b8a86b01` (`fix(macos): invalidate hotstrings on navigation`)
- [ ] `HS-003` — terminal delivery transaction and global ordering fence; second implementation lens found seven material blockers
- [x] `HS-004` — `5e12271b1` (`fix(macos): defer keylogger persistence off eventtaps`)
- [x] `HS-005` — `5ca12305c` (`fix(macos): route repeat through replacement transaction`)
- [x] `HS-006` — `477cec849` (`fix(macos): count dynamic suffixes as codepoints`)
- [x] `HS-007` — manager-side generation fence and exactly-once stale terminal — fixed and behaviorally replayed in this commit
- [ ] `HS-008` — exact MLX predecessor/replacement ownership
- [x] `HS-009` — `2cdf06f89` (`fix(macos): isolate semantic LLM HTTP owners`)
- [x] `HS-010` — exact Ollama pull owner and cancel terminal — fixed and behaviorally replayed in this commit
- [x] `HS-011` — exact installer owner, bounded cleanup retries, and pause/disable/teardown joins
- [ ] `HS-012` — transactional pause-owner registry
- [x] `HS-013` — this fix commit; exact handles are reused and six focused edit/menu repros pass
- [x] `HS-014` — present in starting `dev` via `c6d081890`; independently replayed bind lifecycle tests
- [x] `HS-015` — this fix commit; both entry-point families share one exact screenshot-save transaction and 15 focused repros pass
- [x] `HS-016` — callback inventory plus profile-warning sibling are observable and truthful
- [x] `HS-017` — `ea924a686` (`fix(macos): order updater responses monotonically`)
- [x] `HS-018` — this fix commit; local health generations now invalidate on every committed backend switch
- [ ] `HS-019` — root Karabiner fail-fast and bulk clear transaction
- [x] `HS-020` — `468a3646d` plus fail-safe follow-up `063b8d8ba`
- [x] `HS-021` — `e02233b4b` (`fix(macos): invalidate hotstring context on Escape`)
- [ ] `HS-022` — global Disable All / factory reset transaction
- [x] `HS-023` — this fix commit (`fix(macos): publish VS Code extension transactionally`); `--only "HS-023"` passes 9/9
- [ ] `HS-024` — MLX download exactly-once terminal contract
- [x] `HS-025` — asynchronous Ollama readiness probes
- [ ] `HS-026` — LLM settings transaction
- [x] `HS-027` — this fix commit; model and `No Model` share one recoverable transition, with 26 focused refusal/retry cases
- [x] `HS-028` — this fix commit; direct profile selection is transactional with retryable compensation debt
- [x] `HS-029` — pending model completion preserves newer explicit profile intent — fixed and independently reviewed in this commit
- [x] `HS-030` — this fix commit; exact source-only modules bypass only the case-name no-match guard
- [x] `HS-031` — recommended-profile actions now use the same transactional profile owner; independently reviewed GO
- [ ] `HS-032` — Ollama pull publication waits for the parent model transaction
- [ ] `HS-033` — profile deletion retains exact shortcut and runtime-profile ownership
- [ ] `HS-034` — failed profile creation removes its uncommitted registry candidate
- [x] `PARITY-001` — `4f22a1efc` (Linux suffix codepoint count)
- [x] `PARITY-002` — `22ca14d81` (Linux canonical multibyte trigger)

Implementation verification is recorded per checkbox. For the current `HS-030` commit, the real exact source-only replay changes from exit `1` with a synthetic no-match failure to exit `0`; the selector/runner regression module passes `14/14`, including a child-process replay, unknown-filter fail-closed behavior, and preservation of load failures. Conventions, the false-green ratchet, targeted JS ratchets, `git diff --check`, and the Hammerspoon E2E gate are green. The full Hammerspoon gate returned non-zero in an earlier shared WIP snapshot but its failure output was lost, so no global-green or global-failure attribution is made for this commit.

## 2. Findings

### `HS-001` — Touch watchers false-commit native start and discard live owners on stop

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`
- **Source:** `modules/gestures/init.lua:298-410`, `modules/gestures/init.lua:952-1047`

**Reproduction.** Start Ergopti with an enumerated trackpad and make `MTDeviceStart` refuse while the Lua method still returns its watcher. `create_watcher()` publishes the device and watcher, logs `ATTACHED`, and `M.start()` returns `true` even though `w:running()` is `false`; gestures are dead. Separately, with a running watcher, make native stop refuse or throw while `running()` remains `true`, then pause/reload/stop. `recycle_watchers(false)` removes the exact watcher/device entries and `M.stop()` can return `true`, while the native listener remains live and is no longer retryable.

A native-faithful Lua harness produced `start_result=true`, `watcher_retained=true`, `watcher_running=false`; its stop counterpart produced `stop_result=true`, `watcher_running=true`, `watcher_retained=false`.

**Root cause and silence.** `create_watcher()` uses `pcall(w:start())`, treats non-throwing completion as success, and observes `running()` only for an INFO line. `recycle_watchers()` similarly checks only `pcall`, then unconditionally deletes ownership. The [upstream implementation at commit `856f98dd700e5c0263fbf74ed9ac9b6d13fac84c`](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/856f98dd700e5c0263fbf74ed9ac9b6d13fac84c/internal.m) logs `MTDeviceStart`/`MTDeviceStop` failure only to the Hammerspoon Console and always returns the userdata; only `running()` exposes `MTDeviceIsRunning`. Frame callbacks are dispatched asynchronously on the main queue. The repository vendors a binary without immutable source metadata, so the upstream source is strong contract evidence, not proof of the exact binary build.

This is distinct from the intentional kernel gate: `running()==true` with no first physical frame is allowed; `running()==false` after start is not.

**Existing test/backstop checked.** `tests/unit/modules/gestures/test_stop_detaches_watchers.lua` has a stop stub that always mutates `_running=false` and returns `nil`; its table-empty assertion rewards loss of ownership. `test_recurring_timer_transaction.lua` supplies no devices, and `test_touchdevice_fallback.lua` covers module absence, not an enumerated-device refusal. GC retries stop eventually, but nondeterministic GC is not a settlement backstop.

**Fix.** Make watcher acquisition and release transactional. A start commits only when callback registration succeeds and `running()==true`; a stop settles only when `running()==false`. Retain exact cleanup debt and fence callbacks by lifecycle generation before engine teardown.

**Regression test.** Add `tests/unit/modules/gestures/test_touch_watcher_lifecycle_transaction.lua`. For frame-callback nil/throw, start throw, and start-return-self-with-`running()==false`, assert `Gestures.start()==false`, no success publication, and exact cleanup ownership. Assert `running()==true, alive()==false` still commits. For stop false/throw with `running()==true`, assert first `M.stop()==false`, exact table objects remain, queued frames are inert, and a second stop retries the same object and removes it only after `running()==false`.

### `HS-002` — Navigation can hide the tooltip while retaining a cursor-relative fireable hotstring

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G5`
- **Source:** `modules/keymap/init.lua:1177-1184`, `modules/keymap/init.lua:1499-1529`, `modules/keymap/llm_bridge.lua:1625-1635`, `ui/menu/menu_llm/init.lua:745-754`

**Reproduction.** Enable previews, uncheck `Clear context on click/navigation`, type `agé` (the shared autocorrection maps it to `âgé`), press Left, then press the magic key. Navigation always resets the visible prediction, but clears `CoreState.buffer` only when `llm_reset_on_nav` is true. The engine still resolves `agé` at the moved caret: three Backspaces remove `ag` plus one no-op, then `âgé` is inserted, yielding `âgéé` while the tooltip had shown nothing.

**Root cause and silence.** One state field owns both optional LLM history retention and cursor-relative hotstring eligibility. Navigation revokes presentation unconditionally but revokes the engine buffer conditionally. No callback throws and no log reports the divergence.

**Existing test/backstop checked.** `test_llm_bridge_no_duplicate_init.lua:292-304` calls `check_nav_reset()` with the default false setting only to inspect injected-state identity. `test_preview_matches_engine.lua` and `test_preview_respects_terminator_state.lua` compare engine and preview on an unchanged snapshot; neither moves the cursor with reset disabled.

**Fix.** Always invalidate the cursor/hotstring buffer and boundary state on arrow or click. Preserve optional LLM context in a separately owned state.

**Regression test.** Add `tests/unit/modules/keymap/test_nav_invalidates_hotstring_buffer.lua`, table-driven for Left and mouse-down through the captured production taps with reset disabled. Assert empty hotstring buffer, hidden row, the next magic key returns `false`, emits zero synthetic events, and passes through physically.

### `HS-003` — Terminal pacing blocks the eventtap and publishes irreversible output before transaction commit

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G3`; structural `G4` violation
- **Source:** `modules/keymap/init.lua:1332-1347`, `modules/keymap/expander.lua:83-95`, `modules/keymap/expander.lua:123-165`, `adapters/synthetic_input.lua:2001-2041`, `_shared/modules/timings/constants.toml:203-206`
- **Recent-fix collateral:** `50c2d43e6`

**Reproduction.** In Terminal/iTerm, type bundled `xgboost` and press the magic key. Seven deletion pairs call `event:post(app)` and sleep `20 ms` each before the originating callback returns: `140 ms` of configured sleep, excluding native work. An eight-delete fixture represents `160 ms`. If the kth `post`/`usleep` throws, or the later `buffer_action` fails, earlier Quartz events are irreversible; in-memory cancellation cannot retract them, and the function returns false so the physical magic key can pass after a partial replacement.

**Root cause and silence.** The terminal stale-render fix created an eager exception inside the callback collector. Delivery occurs before buffer commit, telemetry, and seal. No exception is required for the delay, and a CoreGraphics timeout is not routed to the file logger.

**Existing test/backstop checked.** `tests/unit/modules/keymap/test_expander.lua:323-361` replaces paced delivery with a success stub. `tests/unit/adapters/test_synthetic_input_provenance.lua:1630-1651` asserts successful sleep calls but has no callback-boundary or kth-post refusal. Both protect ordering while blessing the blocking architecture.

**Fix.** Transfer a sealed, retained transaction to a timer-driven serializer after the eventtap returns. The serializer must own the exact remaining ordinal, target app, tags, cancellation fence, and terminal result before posting the first event.

**Regression test.** Add `tests/unit/modules/keymap/test_terminal_replacement_off_eventtap.lua`. With `callback_active=true`, make `event.post` and `usleep` fail if called and assert zero calls before return. After return, tick the serializer and assert exact order/tags and configured spacing. Refuse the kth post and assert the undispatched suffix remains owned for retry, with no duplicate ordinal and no physical trigger pass-through after partial delivery.

**Implementation replay — still open.** The candidate closes several earlier ordering cases, but an independent second implementation lens found seven material blockers. None is checked until the real production path and exact native contracts are behaviorally replayed:

1. [ ] The keylogger bypasses provenance classification for mouse/scroll events. A tagged physical replay can therefore reclaim itself while it is still pending, loop forever, and lose the click. Route every taggable event through `EventProvenance.classify_with_fence()` and drive the real keylogger callback.
2. [ ] `when_idle()` ignores already accepted post-eventtap callbacks. Pause can acquire its admission fence before a queued tooltip acceptance opens its transaction, consuming Tab/Enter and then rejecting `begin()`. Idle, recheck, and admission acquisition must include deferred callback ownership.
3. [ ] Pause can orphan its exact admission fence when `get_enabled()` is absent/throws, when the no-integration path exits, when release refuses, or when stop interrupts a transition. Retain explicit release debt and never publish RESUMED until the same fence settles.
4. [ ] Periodic paced/physical/idle timers are erased after an unchecked `stop()`. A native false/nil/throw leaves a self-retained 100–200 Hz timer with no retry owner; constructor results such as literal `false` are also indexed outside protection. Retain and autonomously retry the exact handle until stop is proven.
5. [ ] A paced owner has both a recurring tick and a zero-delay wake. If the originating callback outlives one cadence, both can pump back-to-back and collapse the required Terminal spacing. Use one temporal authority or a monotonic `next_due_at` gate and test both callback orders.
6. [ ] A refused/throwing pre-teardown input drain is routed to `fail_after_teardown()` even though teardown never ran. Quit/reload can therefore fatal-exit with taps and resources still live. The failure sequence must still execute teardown before its fatal backstop.
7. [ ] The new `clipboard_restore` producer is missing from the exhaustive synthetic reset inventory. Extend both the inventory and a behavioral drain test proving that pause/reload remain pending until all-type restoration settles exactly.

Two narrower subcases are already closed in the candidate—failed terminator completion registration cancels its exact reservation, and a missing replacement transaction no longer schedules a duplicate Enter—but they do not close the finding. The previously green focused modules are insufficient because their fixtures bypassed the real non-keyboard keylogger path and modeled recurring timer shutdown as infallible.

The review refuted two broader suspicions: the prediction-engine fallback absorbs an overtaken F16 loopback, and no stock path can pre-seal the terminator's fresh private transaction. Those are not promoted as separate findings.

### `HS-004` — Keylogger persistence performs JSON/native/filesystem work inside both eventtaps

- **Severity:** High
- **Confidence:** High for the call structure; latency magnitude unmeasured
- **Guarantees:** structural `G4`, degrading to `G1`/`G2` if a tap times out
- **Source:** `modules/keylogger/init.lua:565-982`, `modules/keylogger/init.lua:1111-1187`, `modules/keylogger/init.lua:1242-1260`, `modules/keylogger/init.lua:1413-1430`, `modules/keylogger/log_manager.lua:489-604`, `modules/keylogger/rotation.lua:207-240`

**Reproduction.** Enable Metrics/keylogger, type a word, then Space. Before the keylogger eventtap returns, the code detaches and iterates the typing run, builds rich text/WPM, JSON-encodes the entry, and calls an unbuffered file handle’s `write`. Modifier and shortcut branches also query `frontmostApplication()` before returning. A hotstring or non-stream LLM acceptance reaches synchronous `notify_synthetic`/acceptance persistence from the keymap tap.

**Root cause and silence.** `append_log()` immediately drains an empty FIFO; `flush_buffer()` constructs the snapshot entry before queuing. A safe deferred primitive exists, but only selected action-epoch branches use it. Ordinary I/O success produces no error; filesystem latency is environment-dependent and was not measured here.

**Existing test/backstop checked.** `test_action_epoch_consumer.lua` protects only the synthetic action-epoch branch. `test_log_manager_deferred_action_order.lua` proves the safe primitive exists. `test_eventtap_logger_side_effects.lua` stubs the entire keylogger, while `test_rotation_persistent_handle.lua` accepts active-tap append and only removes open/close overhead.

**Fix.** Tap-facing APIs may only detach/O(1)-enqueue. Snapshot conversion, per-codepoint synthetic expansion, JSON encoding, app attribution, and writes belong to the retained FIFO drain after callback return.

**Regression test.** Add `tests/unit/modules/keylogger/test_eventtap_persistence_deferred.lua`. Drive the real captured callback across first key, Space, punctuation, navigation, modifier, shortcut, mouse, pause, hotstring acceptance, and LLM acceptance. While `callback_active`, assert zero JSON encode, `Rotation.append_log`, file write, and `frontmostApplication` calls. After the drain fires, assert exact FIFO records once each.

### `HS-005` — Repeat-key duplicates the replacement producer and makes preview/telemetry state diverge

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G3`, `G5`
- **Source:** `modules/keymap/expander.lua:98-200`, `modules/keymap/expander.lua:921-1007`, `modules/keymap/init.lua:1248-1256`

**Reproduction.** Register non-auto `abb -> X`, enable repeat and preview, type `ab`, then press magic. Repeat emits `b`, changes the engine buffer to `abb`, hides the tooltip, and returns early without the common completion preview. A second magic press fires `X` although the tooltip advertised nothing. Separately, make `TextSender.send` return false: `notify_synthetic` has already persisted a ghost repeated `b` even though output is canceled.

**Root cause and silence.** Repeat reimplements `perform_text_replacement`: it hides presentation, sends telemetry before output construction, mutates only `_state.buffer`, omits `keylogger.set_buffer`, and omits the committed preview callback. These are ordinary state mutations, so nothing throws.

**Existing test/backstop checked.** `test_expander.lua` and `test_repeat_feature_arm_time.lua` assert output/buffer/tags but not preview, keylogger buffer, or refusal ordering. `test_expander_notify_synthetic_pcall.lua` tests a throwing notifier after successful output, not output refusal after successful telemetry. Resolver-order tests stop before the post-repeat cascade.

**Fix.** Remove the second producer and express repeat through `perform_text_replacement` with a `repeat_key` variant and the correct deletion semantics.

**Regression test.** Add `tests/unit/modules/keymap/test_repeat_replacement_transaction.lua`. Drive `ab★` with `abb -> X`; assert `keylogger.set_buffer("abb")` once and visible row `X` only after commit, then assert the same action fires. With direct send false, assert unchanged buffers, zero telemetry/events, and `false` return.

### `HS-006` — Dynamic rules count UTF-8 bytes as screen characters and over-delete

- **Severity:** High
- **Confidence:** High for the public API; bundled rules are currently ASCII-only
- **Guarantee:** `G2`
- **Source:** `modules/dynamic_hotstrings/rules_engine.lua:249-266`, `modules/dynamic_hotstrings/rules_engine.lua:546-553`, `_shared/lua/dynamic_hotstrings/init.lua:114-125`, `_shared/lua/dynamic_hotstrings/init.lua:194-230`, `modules/keymap/init.lua:624-655`

**Reproduction.** In the Hammerspoon console after initialization, call `RulesEngine.add_rule("été", "date", function() return "X" end)`, type `zzété`, then press magic. Matching succeeds bytewise, but `#"été" == 5`; five Backspaces erase `zzété`, producing `X` instead of `zzX`.

**Root cause and silence.** The public rule API accepts arbitrary strings, matching uses byte suffixes correctly, but deletion hands a byte count to an API documented in codepoints. The wrong text is then committed consistently, so no exception exposes it.

**Existing test/backstop checked.** `test_rules_engine_preview_snapshot.lua`, `test_rules_engine_trigger_char_sync.lua`, and `test_resolver_failure_visible.lua` register ASCII suffixes only.

**Fix.** Derive a protected `utf8.len(rule.suffix)` at action time and refuse malformed suffixes. Do not cache the derived count independently of the rule.

**Regression test.** Add `tests/unit/modules/dynamic_hotstrings/test_rules_engine_utf8_delete_count.lua`. Register `été`, drive the real provider/interceptor with `zzété`, assert delete count `3`, exact three delete pairs, and simulated screen/buffer `zzX`. Add malformed UTF-8 with zero injection.

### `HS-007` — A stale MLX switch can mutate the server before the outer generation fence

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G3`
- **Source:** `ui/menu/menu_llm/model_switcher.lua:261-303`, `ui/menu/menu_llm/models_manager_mlx.lua:205-305`, `ui/menu/menu_llm/models_manager_mlx_server.lua:141-175`, `ui/menu/menu_llm/models_manager_ollama.lua:328-448`
- **Recent-fix blind spots:** `3e50bb392`, `37da444bd`

**Reproduction.** With installed MLX models A and B, select A then B. Complete B’s dependency probe first so B starts; complete A’s probe second. A’s manager continuation calls `start_server(A)`, which can terminate B and start A. Only afterward does the final callback reach `model_switcher`’s stale-token check, so state/menu may still say B while A owns the server.

The Ollama sibling has the same fence placement. Select absent A then installed B; let B’s list/loadability path commit, then complete stale A’s list and system check. The stale continuation can prompt/pull A, and `pull_model(A)` publishes runtime, keymap, display, and persistent model state before its terminal callback reaches the switcher token. `HS-010` does not absorb this ordering when B never needed a pull.

**Root cause and silence.** The generation token guards terminal callbacks one layer above destructive manager side effects. Dropping the final stale callback hides rather than prevents the mutation.

**Existing test/backstop checked.** `test_model_switcher_backend_guard.lua` replaces the manager with a final-callback fake and cannot see inner terminate/start effects. `test_mlx_server_readiness_is_shared.lua` covers intentional same-target joining only.

**Fix.** Pass the switcher-owned operation token or `is_current` predicate into both MLX and Ollama managers and recheck it before loadability checks, prompt, pull, terminate, start, preference publish, and every yielded continuation.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_model_switcher_manager_generation.lua`. Defer real manager task completions; run MLX A→B, finish B then A, and assert no `start_server(A)`, no B termination, and B remains current. Repeat with Ollama absent A/installed B and assert zero A prompt, pull, runtime publication, or persistence.

**Implemented and independently replayed.** The switcher-owned predicate and one-shot stale terminal now flow through the real MLX and Ollama task, timer, HTTP, prompt, download, server-adoption, readiness, and publication continuations. Every destructive commit rechecks exact authority. The detached MLX pre-launch sweep was removed; the serial launcher is now the sole cleanup/start owner. The existing Ollama pull-slot guard remains ahead of UI and native-task construction. With only the six production files reverted, `lua tests/run.lua --only HS-007` exited `1` on the stale prompt/readiness/download/Ollama publication reproductions; after restoration it passed `11/11`. This checkbox does **not** close the exact replacement/cancel/pause/download-terminal work tracked separately by `HS-008`, `HS-010`, `HS-012`, `HS-024`, `HS-025`, or `HS-027`.

### `HS-008` — MLX replacement drops its predecessor before exact teardown settles

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`
- **Source:** `ui/menu/menu_llm/models_manager_mlx_server.lua:141-175`, `ui/menu/menu_llm/models_manager_mlx_server.lua:212-249`, `ui/menu/menu_llm/models_manager.lua:551-563`, `ui/menu/menu_llm/backend_panel.lua:165-223`, `ui/menu/menu_llm/init.lua:189-197`, `ui/menu/menu_llm/init.lua:665-680`

**Reproduction.** With server A active, make its task’s `terminate()` throw or return false, then select B. The code clears the active slot and proceeds to B. A native-shaped successful `terminate()` returns the task userdata rather than literal `true`, so the current literal-boolean check can also reject a valid termination request while leaving the replacement transaction unsettled.

The public stop sibling has the same ownership loss: call `stop_mlx_server_if_needed()` with an active task whose `terminate()` throws or returns false. The function unconditionally clears `active_tasks["mlx_server"]`, resets endpoint identity, and logs “stopped safely,” so the still-live exact server can no longer be retried through that owner.

The callers defeat a local stop fix unless they join the same transaction. Switching MLX to API/Ollama publishes and persists the new backend before discarding the stop result; the API path has no MLX hard-kill backstop. Changing the MLX port similarly signals stop and immediately rechecks the same model. Because the server identity does not include the port and teardown is not settled, the old server can be reused on the old port while runtime settings point to the new one. `M.stop_mlx_server()` also discards the stop result and returns `nil`, allowing shutdown to report settlement without it.

**Root cause and silence.** A signal request is treated as settlement, its native return shape is misclassified, its result is discarded by sibling callers, and the exact task handle is dropped before completion.

**Existing test/backstop checked.** `test_mlx_server_readiness_is_shared.lua` uses always-successful termination. `test_mlx_stop_clears_readiness.lua` is source-only. `test_backend_panel_save_gate.lua` replaces the public stop method with a counter and cannot represent refusal. `HS-007` removed the independent fire-and-forget pre-launch sweep and added a negative inventory test, so that former sibling race is closed rather than carried by this finding.

**Fix.** Make replacement, public stop, backend switch, port restart, and shutdown share one exact settlement primitive: retain A until confirmed stopped, accept native task userdata as a termination signal but not as settlement, and launch/publish the successor only from A's exact completion. Include port in the server identity and propagate stop refusal to callers.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_mlx_server_replacement_transaction.lua`. For throw/false/native-self terminate through replacement, public stop, backend switch, port edit, and shutdown, assert no successor/publication, no false success log, and unchanged exact owner. Accepted termination must retain A until its callback, then launch the latest model/port successor exactly once. Preserve the `HS-007` negative invariant that no independent pre-launch sweep exists.

### `HS-009` — Single-slot HTTP clients silently cancel independent semantic operations

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G3`
- **Source:** `adapters/http_client.lua:268-295`, `adapters/http_client.lua:361-374`, `modules/llm/api_ollama.lua:328-368`, `modules/llm/api_ollama.lua:571-575`, `modules/llm/api_remote.lua:45-46`, `modules/llm/api_remote.lua:616-715`, `ui/menu/menu_llm/api_panel.lua:251-300`

**Reproduction A.** Disable streaming, invoke a profile shortcut, and let its non-stream Ollama inference remain pending. The shortcut immediately restores the prior profile; deferred warmup uses the same `_infer_client`, whose `_prepare_request()` cancels the inference. Cancellation deliberately emits no callback, so no prediction arrives and loading survives until a watchdog.

**Reproduction B.** Begin Add Remote API Entry so availability validation owns a mutation lease, then activate a profile/warmup before validation returns. Warmup reuses `_check_client`, silently cancels validation, and the panel’s callback-only lease release never runs; staged API state and CRUD stay stuck until reload.

**Root cause and silence.** `HttpClient` implements latest-request-wins correctly for one semantic owner, but callers share an instance across independent owners. `cancel()` intentionally suppresses the displaced callback, so mandatory terminal cleanup is lost without an error.

**Existing test/backstop checked.** `test_http_client_supersede_race.lua` proves stale callbacks are omitted, but asserts only wrong-recipient suppression. `test_api_remote_identity_generation.lua` covers identity changes, not same-identity warmup/validation collision.

**Fix.** Allocate clients per semantic owner, or return an explicit `superseded` terminal result to every lease-owning operation. Warmup must never share the user-inference or mutation-validation slot.

**Regression test.** Add `tests/unit/modules/llm/test_semantic_http_owner_isolation.lua`. For Ollama, start non-stream inference then profile-restore warmup and assert inference terminates exactly once without being silently canceled. For Remote, start validation then warmup, deliver both out of order, and assert validation commits/rolls back and releases the mutation lease independently.

### `HS-010` — Ollama pull cancellation has no exact owner settlement or terminal

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G3`
- **Source:** `ui/menu/menu_llm/models_manager_ollama.lua:319-420`, `ui/menu/menu_llm/models_selector.lua:281-299`
- **Recent-fix blind spot:** the single-slot guard exists, but its tests do not exercise cancellation refusal, native return shape, or terminal completion

**Reproduction.** Start pulling absent model A, then click Cancel while its exact `terminate()` throws/returns false, or returns the native task userdata but has not completed. The UI callback reports acceptance without checking the signal result and there is no durable exact cancellation owner. When A later completes, the callback clears the slot and the `user_cancelled` branch returns without delivering the required failure/cancel terminal. Before the `HS-007` generation checks, an exit `0` could also publish after cancellation; that late publication is now fenced, but ownership and terminal settlement remain open.

**Root cause and silence.** Cancellation has no durable `{task, cancel_requested, terminal}` owner, discards throw/false/native-self termination semantics, and treats the eventual exact callback as a silent early return instead of settlement. The slot itself is guarded against concurrent entry and callbacks compare the exact task; the earlier no-entry-guard subclaim is refuted below.

**Existing test/backstop checked.** The production guard at `models_manager_ollama.lua:415-421` rejects a second pull before UI/native construction, and the exact callback check at `:451-454` prevents a stale task from clearing a successor. No behavioral test covers terminate throw/false/native-self, retained cancellation ownership, or exactly-once terminal delivery.

**Fix.** Use a pull owner `{task, generation, cancel_requested, terminal}`. Refuse or join re-entry while it owns the slot, mark cancellation before signaling the native task, accept a truthy task userdata only as signal acceptance, retain ownership until the exact callback, and compare owner/token before every clear or publication.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_ollama_download_single_slot.lua`. Preserve the existing A-then-B rejection and exact-owner assertion. Table-drive `terminate()` throw, false, and native-shaped `return self`; accepted cancellation retains A until its callback and delivers one terminal. Deliver late exit `0` after cancel and assert zero model/runtime/persistence publication. A stale completion must not clear or mutate a successor; include the idle positive control.

**Implemented and behaviorally replayed.** The pull now owns `{cancel_requested, completion_seen, terminal}` beside the exact task slot. A user cancel is latched before native termination, native task userdata means signal accepted rather than settled, and false/nil/throw retain the same task for cleanup retry. Construction/start refusal, synchronous completion from `start()` or `terminate()`, duplicate completion, process failure, busy re-entry, and late exit `0` after cancel all deliver at most one terminal and never publish canceled output. The pre-fix behavioral module exposed seven ownership/terminal failures; the final exact module passes `12/12`, and four direct manager/generation neighbors pass `24/24`. Syntax, conventions, false-green ratchet, and scoped diff checks are green. The shared Hammerspoon E2E snapshot remains `60/64` because the concurrently open `HS-003` serializer WIP rejects four synthetic provenance cases; no E2E-green claim is made for this commit, and `HS-010` touches neither the input serializer nor that harness.

### `HS-011` — Onboarding installer tasks survive pause, disable, and stop

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`
- **Source:** `platform/remap/onboarding.lua:261-393`, `platform/remap/onboarding.lua:403-512`, `platform/remap/onboarding.lua:732-741`, `platform/remap/init.lua:4410-4415`

**Reproduction.** With Karabiner-Elements missing, click Install Now. While `curl` runs, pause, disable remapping, or call teardown. Complete the captured download successfully: checksum, DMG mount, package discovery, and privileged `osascript` installation still chain. `Onboarding.stop()` increments only the wizard epoch and returns `true` when no wizard timer exists, ignoring `_active_tasks`.

**Root cause and silence.** Task handles are pinned but are not part of the stop contract. The epoch fences final wizard continuation, not download→verify→mount→install side effects. Every task can succeed normally after authority was revoked.

**Existing test/backstop checked.** `test_onboarding_continuation_timer_transaction.lua:201-223` replaces the entire installer with a fake final callback and proves only that completion does not reopen the wizard.

**Fix.** Give the install pipeline its own lifecycle epoch, own every exact task/mount, terminate on pause/disable/stop, retain refusal debt, and check authority before every successor and privileged action.

**Regression test.** Add `tests/unit/platform/remap/test_onboarding_install_lifecycle.lua`. Start the real pipeline with captured task objects, stop/pause after download dispatch, then complete download. Assert zero checksum, mount, or `osascript` constructions; assert exact termination retry and safe unmount/temporary-file cleanup.

**Implemented and behaviorally replayed.** The installer now owns an exact epoch/stage/task/mount/partial record, pins every native task before start, latches synchronous start/terminate completions until the native result is known, and treats a truthy task userdata as a pending signal rather than settlement. Every successor is generation- and completion-fenced; duplicate callbacks are inert. Pause, disable, revoke, and shutdown join the same owner, including the first-run wizard timer. Task, mount, partial-file, and timer cleanup refusals are retained and retried with a bounded, observable policy, while verified cache publication uses a unique partial and atomic promotion. The adversarial lifecycle matrix passes `82/82`, pause/disable/revoke/shutdown passes `51/51`, guardian recovery passes `66/66`, and the direct timer/task/stock-process neighbors are green. Conventions, false-green, Lua compatibility, integrity, encoding, compilation, and scoped diff checks are also green; an independent second-lens review returned GO.

### `HS-012` — Pause commits before several runtime and deferred owners are quiescent

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G2`, `G3`; state-machine integrity
- **Source:** `modules/shortcuts/script_control.lua:320-475`, `modules/shortcuts/script_control.lua:642-678`, `ui/menu/init.lua:817-837`, `ui/menu/init.lua:1060-1126`, `ui/menu/menu_metrics.lua:154-214`, `modules/gestures/actions.lua:713-920`, `modules/gestures/init.lua:513-537`, `modules/llm/api_remote.lua:616-672`, `ui/menu/menu_llm/startup_controller.lua:235-319`, `ui/menu/menu_llm/model_switcher.lua:261-339`, `ui/menu/menu_llm/model_switcher.lua:459-551`

**Reproduction A — WPM.** Enable both WPM surfaces and pause. `pause_all()` omits them, publishes `_is_paused=true`, and the listener merely schedules a menu rebuild `50 ms` later. Both owners therefore remain live after pause commitment; if timer construction/rebuild fails they remain indefinitely, and later `stop()` refusal cannot reject the already-published pause.

**Reproduction B — gesture search.** Select text, fire `search_web`, and pause/disable/stop within the configured `200 ms` clipboard window. Production `Actions.force_cleanup` only delegates to Click, so the search timer later restores the clipboard and opens a browser while paused.

**Reproduction C — Remote warmup.** Start an API warmup, pause before its HTTP completion, then return success. Pause stops MLX/Ollama warmup but has no Remote stop/generation; `_is_ready` becomes true after the runtime gate closes.

**Reproduction D — startup MLX.** Boot with MLX enabled and pause before the one-/three-second startup timers. They check persisted `state.llm_enabled`, which pause preserves, and can call `force_mlx_check`, start the server, and re-enable predictions while paused.

**Reproduction E — cleanup refusal hidden by gesture lifecycle.** Arm a gesture clipboard/click cleanup owner, make `Actions.force_cleanup()` return `false`, then pause or disable gestures. `modules/gestures/init.lua:515-540` discards both the protected-call status and explicit result, and `M.suspend()` returns `nil`; `script_control.call_lifecycle_operation()` treats that legacy nil as success and can publish PAUSED while exact cleanup debt remains. `M.stop()` repeats the same discarded-result shape at `:1011-1019`.

**Reproduction F — already-dispatched startup work crosses pause.** Let the one- or three-second startup timer dispatch `force_mlx_check()`, pause before its dependency probe completes, then deliver that probe. The startup generation guards only the terminal `on_ok`/`on_fail`; the manager can still start/publish an MLX server below that fence while PAUSED. Merely parking timers therefore does not absorb in-flight work.

**Reproduction G — an ordinary model switch crosses a pause epoch.** Select installed MLX model A and leave its dependency probe pending, then pause and resume before completing that probe. A dynamic `is_paused` check is true again after resume, while the switch request token was never invalidated by the pause epoch. The late probe can start/publish A after resume. If the stale terminal is delivered while still paused, the temporary prediction lock cannot be re-enabled at that moment and no current resume owner restores it, leaving predictions disabled indefinitely.

**Root cause and silence.** Pause is implemented as a manually enumerated transaction, but these sibling producers live behind deferred UI reconciliation or outside the list. Gesture lifecycle additionally converts explicit cleanup refusal into legacy nil-success through a bare `pcall`. Startup/model-switch generations are checked above, rather than below, destructive manager continuations, and the prediction-lock owner is not part of pause/resume state. Each late callback can complete normally, so no error identifies the invariant breach.

**Existing test/backstop checked.** `test_menu_metrics_wpm_pause_gate.lua` source-scans and incorrectly assumes `updateMenu() -> build()` is synchronous. `test_suspend_quiesces_scroll_and_clicklock.lua` stubs `Actions.force_cleanup` and cannot inspect production search ownership. `test_warmup_gate_respects_pause.lua` and `test_warmup_parked_during_pause.lua` assert MLX/Ollama only despite broader descriptions. `test_startup_controller_generation_guard.lua` has no pause state.

**Fix.** Maintain one enumerated pause-owner registry. Every owner must synchronously fence callbacks and return exact settlement before `_is_paused` is published; resume may re-arm only previously committed owners. Bump startup and ordinary model-switch operation tokens on pause and pass them through the manager-side operation guard from `HS-007`, so already-dispatched probes cannot mutate native state. Snapshot a temporary MLX prediction lock as an owned pause resource and restore it exactly once on resume when the persisted feature remains enabled.

**Regression test.** Add `tests/unit/modules/shortcuts/test_pause_owner_inventory.lua`. The class-wide state×owner test must inject WPM stop refusal, a live search timer, Remote warmup, both startup timers, and `Actions.force_cleanup=false`. Also dispatch both startup and ordinary model requirements, pause/resume, then complete the old probes. Assert pause returns false or leaves every callback inert before publication; after a successful retry, no URL, readiness, model start, WPM timer, tap, canvas update, or gesture cleanup owner occurs until resume, and the abandoned temporary prediction lock is restored exactly once from live preferences.

### `HS-013` — Configurable shortcut edits release ownership before replacement and persistence commit

- **Severity:** Medium
- **Confidence:** High
- **Guarantee:** `G2`; state-machine integrity
- **Source:** `modules/shortcuts/keyboard_shortcuts.lua:196-290`, `modules/shortcuts/keyboard_shortcuts.lua:378-426`, `ui/menu/menu_keyboard_slots.lua:110-124`

**Reproduction.** Start with a live configurable chord, then choose another action while the successor bind refuses: `set_action()` first releases the old handle, cannot acquire the replacement, and its unchecked best-effort rebind can also refuse. Alternatively let `hs.settings.set` raise after mutating its store: the new handle is already live, the persisted value changed, and both rollback operations are unchecked. In either case the menu discards `false` and refreshes as if the edit committed. A fresh assignment has the same false-success UI path when native bind refuses.

**Root cause and silence.** The edit pipeline unnecessarily destroys and recreates the same native chord, while its callback captures the old action. That forces release-before-acquire ordering and makes exact rollback impossible on a same-chord bind refusal. Persistence and compensation results are not one transaction. [Hammerspoon documents `hs.hotkey.bind()`](https://www.hammerspoon.org/docs/hs.hotkey.html#bind) as returning `nil` when the hotkey cannot be enabled; the lower adapter reports this, but the menu erases that refusal.

**Existing test/backstop checked.** `test_keyboard_shortcuts_start_transaction.lua` covers boot acquisition/teardown only. `test_menu_keyboard_slots.lua` uses the friendly default registrar and checks only that assignment/UI changed.

**Fix implemented.** Bound callbacks now resolve the committed `_actions[slot_id]` at delivery, so action-to-action edits reuse the exact live handle with zero native churn. Transitions to or from `none` use the registrar's reversible `setEnabled()` boundary and retain the exact handle on refusal. The settings value is snapshotted and restored on a throwing write before in-memory publication; failed native/persistence transitions never refresh the menu.

**Regression test implemented.** `tests/unit/modules/shortcuts/test_keyboard_shortcuts_edit_transaction.lua` proves action-to-action edits make zero bind/unbind/enable calls, callbacks resolve the new action only after commit, a write that throws after mutation restores the exact old setting/action/handle, disable refusal retains and retries the same handle, failed fresh publication leaves an inert retained candidate, and fresh bind refusal changes nothing. `test_menu_keyboard_slots.lua` asserts a refused transaction causes zero menu refreshes. Both pre-existing startup acquisition/teardown refusal tests also pass.

### `HS-014` — VS Code caret bridge reports a failed TCP bind as successful

- **Severity:** Medium
- **Confidence:** High
- **Guarantee:** `G2`; log truth
- **Source:** `infra/vscode_bridge.lua:226-244`, `infra/vscode_bridge.lua:359-376`, `init.lua:1317-1321`

**Reproduction.** Occupy TCP `7878`, then load/reload Ergopti. `start_server()` publishes `_server`, calls `:start()`, never checks `:getPort()`, logs `HTTP server started successfully`, and setup returns normally. Extension POSTs fail for the session and exact caret data never updates (the AX fallback can partially mask the loss).

A faithful server harness produced `start_result=nil`, `native_port=0`, `getPort_calls_by_bridge=0`, `success_log=true`.

**Root cause and silence.** [Hammerspoon’s native `hs.httpserver:start()` implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/httpserver/libhttpserver.m#L528-L550) logs bind failure to the Console and unconditionally returns the userdata. [CocoaHTTPServer exposes `listeningPort`](https://github.com/Hammerspoon/hammerspoon/blob/master/Pods/CocoaHTTPServer/Core/HTTPServer.m#L220-L232), which remains `0` when the server is not running. Root’s `pcall(setup)` therefore observes no throw and the file log contains a false success.

**Existing test/backstop checked.** `test_init_vscode_bridge_setup_error_logged.lua` assumes bind failure throws and only scans root logging. Setup-isolation/AX-cache fixtures use `start=function() end` and no faithful `getPort()`.

**Fix.** Construct locally, start, require `candidate:getPort()==7878`, then publish/log success. Stop or retain exact cleanup debt on refusal and propagate `false` through `setup()`.

**Regression test.** Add `tests/unit/lib/test_vscode_bridge_bind_transaction.lua`. A native-faithful server returning self from `start()` and `0` from `getPort()` must yield `start_server()==false`, one ERROR, no success line, and no published live server. Port `7878` is the positive control. Add a native macOS integration case that pre-binds the port.

### `HS-015` — Duplicated screenshot-save pipelines silently fail and reuse same-second targets

- **Severity:** Medium
- **Confidence:** High
- **Guarantee:** `G2`
- **Source before fix:** `modules/gestures/actions.lua:573-632` at `c6d081890`; `modules/shortcuts/actions/system.lua:747-762`
- **Fixed source:** `modules/shortcuts/actions/screenshot_save.lua:135-178`; callers at `modules/gestures/actions.lua:599-612` and `modules/shortcuts/actions/system.lua:733-745`

**Reproduction.** The audited gesture implementation launched `screencapture` into `~/Pictures/screenshots` without first creating the directory and ignored native task refusal. Starting `dev` later contained a partial gesture-only repair from `c6d081890`, but the independently duplicated shortcut path still ignored mkdir exit plus both `ShellRunner` start results. Bind the physical instant-screenshot action, inject mkdir exit nonzero or task-start refusal, and no file is produced while the callback cannot reject the action. Separately, fire either same-mode save action twice within one wall-clock second: both old pipelines derive the same pathname and the later capture can overwrite the first.

**Root cause and silence.** Two entry-point families owned separate asynchronous mkdir/capture pipelines with different subsets of the required checks. Neither had a collision-resistant target allocator. Task refusal is returned rather than thrown, so an ignored `start()` result is silent; repeated second-resolution names mutate the correct path twice without raising.

**Existing test/backstop checked.** No pre-fix test names the gesture screenshot IDs. `tests/unit/modules/shortcuts/test_actions_system.lua:792-828` proves positive mkdir-before-capture order, but its task double always starts successfully and it does not deliver mkdir failure, capture refusal, or two saves in one second. It therefore does not contradict either current reproduction.

**Fix implemented.** `modules/shortcuts/actions/screenshot_save.lua` is now the single lifecycle owner. It allocates a PID/monotonic-tick/process-sequence target, requires exact construction and `start()==true` at both stages, starts capture only after mkdir exit `0`, and reports every terminal refusal to the file logger and user. All three gesture save IDs and the instant-window shortcut call this owner and propagate its immediate result.

**Regression test.** `tests/unit/modules/gestures/test_screenshot_save_transaction.lua:148-277` behaviorally covers construction nil/throw, start nil/false/throw and nonzero exit at both stages; it asserts exact mkdir→capture order, one visible failure, no false success, distinct targets for two same-tick saves, and truthful gesture propagation. The existing shortcut test still drives the real shared owner and proves the window ID reaches `screencapture` only after mkdir commits. The focused `HS-015` replay passes `15/15`.

### `HS-016` — Bare callback `pcall`s turn consumed actions and cleanup chains into silent success

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`
- **Source:** `modules/shortcuts/script_control.lua:923-958`, `ui/menu/menu_llm/models_manager_mlx_download.lua:476-480`; siblings in `models_manager_ollama.lua`, `models_manager_mlx_hf.lua`, `models_manager.lua`, and `settings_manager.lua`
- **Recent-fix blind spot:** `ba681d500f`

**Reproduction A.** Register `set_extras({open_config=function() error("boom") end})`, map a script-control slot to it, and press the physical key. `call_extra()` discards both `pcall` results, returns true, and the event is consumed with no output and no file ERROR.

**Reproduction B.** Complete an MLX download, then make the supplied success callback throw in `update_menu`. `pcall(on_success)` erases the failure; the later `unlock_predictions` statement in the callback is skipped, leaving predictions locked.

**Root cause and silence.** These sites use containment without observability or finally-style cleanup. The error is consumed inside the callback before the logger-aware lifecycle boundary can see it.

**Existing test/backstop checked.** `test_script_control.lua:742-770` source-scans only that fallback is reachable. `tests/unit/llm/test_callbacks_never_swallowed.lua` proves `ApiCommon.protected_call`, but its curated file inventory omits the split download, Ollama, HF, and settings modules.

**Fix.** Route every externally supplied callback through the contextual traceback/error wrapper, return failure truthfully, and place mandatory unlock/lease release in an unconditional terminal path.

**Regression test.** Add `tests/unit/modules/shortcuts/test_script_control_extra_callback_errors.lua` and extend `tests/unit/llm/test_callbacks_never_swallowed.lua`. Execute the real deferred script-control path with success then throw; assert success once, one contextual ERROR on throw, and no silent success result. For each LLM callback-bearing module, inject throw and assert containment, traceback log, and terminal cleanup. Make the meta inventory enumerate modules rather than selected spellings.

**Implementation rescan collateral.** `ui/menu/menu_llm/model_switcher.lua:381` still invoked the profile-power warning through a bare `pcall(notifications.notify, ...)` and discarded both status and error. Repro: commit a profile whose power exceeds the active model by more than one level, inject a throwing notification sink, and observe a successful action with no warning and no file `ERROR`. The prior callback inventory did not include this helper. A follow-up regression must drive the real committed profile path, make the warning sink throw, and assert that the profile remains committed while one contextual traceback is file-logged.

**Follow-up implemented and behaviorally replayed.** The profile-power warning now crosses `Logger.callback`: a throwing notification remains non-transactional after the profile commit, but its label and traceback reach the central file logger. The real profile transaction test was red before the change and passes `28/28` after it, the gesture callback module passes `30/30`, and the move-resilient callback inventory now accepts both tested visible boundaries (`ApiCommon.protected_call` and `Logger.callback`) while still rejecting every bare callback `pcall` (`9/9`).

### `HS-017` — Same-generation updater responses can regress release state

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G2`, `G3`
- **Source:** `modules/updater/init.lua:343-382`, `modules/updater/init.lua:436-477`

**Reproduction.** Select the user-visible `1m` check interval. Boot and recurring timers can launch requests in the same `_poll_generation`. Let request A snapshot release `v2`, publish `v3`, let request B snapshot/return `v3` first, then deliver A. A passes the generation check and overwrites `_fetch_cache`, `_cached_release`, ETag/state/menu, and potentially notification state with older data.

**Root cause and silence.** `_poll_generation` distinguishes lifecycle/channel changes, not two requests within the same generation. There is no single-flight rule, request sequence, or monotonic-version commit gate.

**Existing test/backstop checked.** `test_updater_bg_timer_generation.lua` is source-only and checks cross-generation rejection. Timer transaction tests do not deliver two same-generation HTTP callbacks out of order.

**Fix.** Use single-flight or a monotonically increasing request ID checked at commit; additionally refuse a version lower than the already committed release.

**Regression test.** Add `tests/unit/modules/updater/test_updater_same_generation_order.lua`. Capture boot and recurring callbacks for one generation, deliver B=`v3` then A=`v2`, and assert cache/ETag/menu/notifier remain at `v3` with zero side effect from A.

### `HS-018` — A stale local health probe repopulates cache after switching to Remote API

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G2`, `G3`; tooltip/menu truth
- **Source:** `ui/menu/menu_llm/init.lua:135-172`, `ui/menu/menu_llm/init.lua:558-610`, `ui/menu/menu_llm/backend_panel.lua:202-222`

**Reproduction.** Open the menu with an MLX health probe pending, then click the Remote API backend. The switch resets `_llm_health_status=nil` and future API builds skip local probing. Deliver the old MLX `200`: its unconditional callback writes `true`, so API mode can display the local-server “reachable/warming” state instead of its own unavailable state.

**Root cause and silence.** Reset clears the value but does not invalidate pending writers; the callback captures neither backend identity nor generation.

**Existing test/backstop checked.** `test_menu_llm_api_backend_probe.lua` checks source wiring only. `test_menu_llm_probe_no_loop.lua` checks rebuild loops, not stale backend completion.

**Fix.** Capture backend plus a health generation; bump on switch/reset/stop and commit only if both still match.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_health_probe_generation.lua`. Defer MLX probe, switch/reset to API, deliver old 200, and assert cache remains invalid/API-derived with no refresh. A current local probe is the positive control.

### `HS-019` — Root ignores Karabiner initialization failure and exposes false-success controls

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; fail-fast/state-machine integrity
- **Source:** `init.lua:1299-1305`, `init.lua:1403-1416`, `platform/remap/init.lua:4117-4168`, `platform/remap/init.lua:4377-4380`, `ui/menu/menu_remap.lua:908-929`

**Reproduction.** Corrupt `<config_dir>/hammerspoon/config_karabiner.toml`, then reload. `karabiner.init()` refuses, but root ignores its return, starts the menu, logs boot success, and publishes boot-ready. Choose Clear All: state-dependent setters return false, but bare `pcall`s discard results, increment the displayed count, call regenerate, and log success although nothing changed.

**Root cause and silence.** Fail-fast is implemented inside the callee but defeated transitively by callers. Several init failures return false/nil; root consumes neither. Menu bulk commands treat “did not throw” as “committed.”

**Existing test/backstop checked.** `test_set_enabled_lease_transaction.lua:657-668` proves the callee fails closed but never boots root/menu. `test_require_state_pattern.lua` checks file-level presence, not every public state-dependent call or its transitive consumer.

**Fix.** Normalize `karabiner.init()` to literal boolean, require exact true before operational UI/boot-ready publication, and make every menu mutation honor returned commit state. Provide a disabled diagnostic menu if desired, never active-looking controls.

**Regression test.** Add `tests/unit/test_init_karabiner_fail_fast.lua`. The root harness injects `karabiner.init=false/nil` and asserts no operational remap menu, no boot success/ready flag, and a visible boot failure. An integration case loads malformed TOML and invokes Clear All, asserting zero success claim and unchanged state.

### `HS-020` — The Hammerspoon `--only` runner still loads every test module

- **Severity:** Low
- **Confidence:** High
- **Guarantee:** verification integrity and developer feedback latency
- **Source:** `tests/run.lua:70-85`, `tests/run.lua:184-198`, `tests/helpers/init.lua:523-530`

**Reproduction.** Run `lua tests/run.lua --only "rejects native watcher start mode false"`. Although only one assertion body matches, the runner still requires all `813` discovered modules before it reaches the filtered result. Unrelated property suites execute at module load, native/scratch fixtures emit logs and attempt filesystem writes, and the focused replay takes the full-suite path. During this audit it had to be interrupted after more than a minute despite the target test itself taking under one second when loaded directly.

**Root cause and silence.** `helpers.it()` owns the only filter, but filtering happens after `tests/run.lua` has already purged state and required each test module. Module-level setup and generated property registration therefore remain unfiltered. The final passed-test count can look focused while load-time work was global.

**Existing test/backstop checked.** No test covers `--only` discovery behavior. The runner's replay hint promises `lua tests/run.lua --only <name>`, but existing tests check neither loaded-module count nor unrelated module side effects.

**Fix.** Add a conservative source selector before `require`: load only modules whose source can register the requested plain-text case, with token-aware handling for dynamically concatenated names and a correctness-preserving full-load fallback when no candidate can be identified. Keep the existing assertion-level filter as the final authority and report selected versus discovered module counts.

**Regression test.** Add `tests/unit/test_runner_only_selector.lua` for exact, dynamically concatenated, unrelated, and zero-candidate fallback cases, plus a runner integration assertion that an unrelated load-time sentinel is absent under `--only` while the target assertion executes. The test must fail against the current load-all runner and pass without weakening discovery for an unfiltered run.

### `HS-021` — Escape hides a fireable hotstring without invalidating its cursor-relative buffer

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G2`, `G5`
- **Source:** `modules/keymap/llm_bridge.lua:1155-1192`, `modules/keymap/llm_bridge.lua:1595-1623`

**Reproduction.** Enable hotstring preview, type a non-auto trigger whose row is visible, press Escape, then press the magic key. The persistent Escape trap consumes Escape and defers only the tooltip hide/reset. The main `check_escape_reset()` path likewise returns immediately when a tooltip is visible. Neither path invalidates the cursor-relative hotstring buffer, so the row disappears but the next magic key still fires the hidden action.

**Root cause and silence.** Tooltip dismissal and engine eligibility are mutated on separate paths. The early return treats presentation reset as context invalidation; no callback throws and no log exposes the divergence.

**Existing test/backstop checked.** `test_llm_bridge_stop.lua` covers exact native ownership and callback error visibility for the Escape tap. `test_preview_render_off_hid_thread.lua` covers render invalidation ordering. Neither drives a visible fireable row through Escape and then replays the magic key, and no test contradicts retained eligibility.

**Fix.** Reuse one cursor-context invalidator for navigation and Escape. It must always clear the hotstring buffer and unknown-boundary state before consuming Escape; any separately preserved LLM context remains governed by the explicit reset-on-navigation policy.

**Regression test.** Add `tests/unit/modules/keymap/test_escape_invalidates_hotstring_buffer.lua`. Drive the real trap and resolver in both runtime-available and hotstring-only quarantine branches; after Escape, assert the row is hidden, the hotstring buffer is empty, and the next magic key passes through with zero synthetic output.

### `HS-022` — Global Disable All and factory reset publish success after partial mutation

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; state-machine integrity
- **Source:** `ui/menu/init.lua:455-530`, `ui/menu/init.lua:603-643`

**Reproduction.** In normal state, click Disable All while one configurable shortcut, gesture, or Karabiner setter returns `false` or throws. `clear_external_bindings()` invokes every sibling through bare `pcall`, discards explicit refusal, then the caller notifies success while the refused external binding remains live. For factory reset, make either config deletion or reload scheduling refuse: the preceding stores have already changed, later steps still run, and the user receives a reset-success notification for a mixed old/new state.

**Root cause and silence.** A distributed multi-store mutation treats “did not throw” as commit, has no snapshot/rollback owner, and publishes success after best-effort calls. The failure can be a normal `false`, so no exception or file log is required.

**Existing test/backstop checked.** `tests/meta/test_fresh_regressions_2026_07_21.lua` only guards that reset does not call `save_prefs()` and targets both config files. `test_global_actions_pause_gated.lua` checks pause gating, not store refusal or compensation. Neither contradicts the partial-commit sequence.

**Fix.** Introduce one bulk transaction owner over runtime bindings, Karabiner state, settings, and recoverable file moves. Abort and compensate in reverse on the first refusal; publish success only after exact Karabiner deployment and the terminal reload handoff commit.

**Regression test.** Add `tests/unit/ui/menu/test_global_reset_transaction.lua`. Table-drive false/throw at each setter, regeneration, settings/file boundary, and reload scheduling. Assert no success, no reload, exact old externally visible state/files, and retained cleanup debt if compensation refuses; a retry must commit once.

### `HS-023` — VS Code extension writes false-commit on write or close refusal

- **Severity:** Medium
- **Confidence:** High
- **Guarantee:** `G2`; log truth
- **Source:** `infra/vscode_bridge.lua:150-195`

**Reproduction.** Trigger an extension update on a filesystem where `io.open(path, "w")` succeeds but `file:write()` returns `nil, err`, or where `file:close()` reports a flush failure. `write_file()` ignores both results and returns `true`; after doing the same independently for `package.json` and `extension.js`, `install_extension()` logs “Extension installed” although one file is truncated, stale, or mismatched and caret updates do not work.

**Root cause and silence.** Opening the destination directly destroys the old file before either payload is known durable. Returned write/close failures are discarded, and the two publication paths have no common owner or compensation.

**Existing test/backstop checked.** `tests/unit/lib/test_vscode_bridge_install_extension.lua` source-scans for `ok_pkg`, `ok_ext`, and a later boolean check. Its friendly file handle cannot refuse write/close and it cannot observe one file publishing while the second fails.

**Fix implemented.** Read both originals fail-closed, stage and exactly write/flush/close both candidates and any backups, then persist a canonical recovery journal before either final path changes. Publish `extension.js` first and the manifest `package.json` last; deleting the journal is the logical commit point. Any pre-commit refusal restores the exact original pair through idempotent restore sidecars. The deterministic journal and backups survive a Hammerspoon reload, while post-commit orphan cleanup debt can retry without rolling the committed pair back. No success log is emitted until the journal commit settles. POSIX cannot atomically replace two unrelated pathnames, so a manually concurrent VS Code reload can still observe the brief rename window; incompatible future schemas require a versioned-directory pointer rather than this manifest-last protocol.

**Regression test implemented.** `tests/unit/lib/test_vscode_bridge_write_transaction.lua` behaviorally table-drives uncertain original/journal reads, write/flush/close refusal for every staged payload, both publication renames, restore/remove compensation refusal across a fresh module load, invalid journals, journal commit refusal, and post-commit cleanup debt. It asserts fail-closed publication, exact retained recovery ownership, manifest-last ordering, no false success line, and one exact retry commit. Focused replay: `lua tests/run.lua --only "HS-023"` — 9 passed, 0 failed on 2026-08-21. Native macOS filesystem/crash injection remains required before claiming the two-path recovery protocol proven outside the behavioral shim.

### `HS-024` — MLX download failures strand the prediction gate and cancellation can publish late

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`
- **Source:** `ui/menu/menu_llm/model_switcher.lua:434-502`, `ui/menu/menu_llm/models_manager_mlx_download.lua:61-123`, `ui/menu/menu_llm/models_manager_mlx_download.lua:442-577`

**Reproduction.** With installed MLX model A active, select absent model B and confirm the download. The switcher disables predictions before delegating. Click Cancel, or enter while another download owns the slot, or make temp-file/task/download/save/server startup fail. Those paths never invoke the switcher's failure terminal, so predictions remain disabled indefinitely. Separately, cancel and then deliver the old tail task with exit `0`: cancellation clears handles but does not revoke an owner generation, so the stale completion can still publish B and start its server. A sibling sequence reaches the same missing lease without cancellation: let the detached Python launcher succeed, then make construction or start of the tail task fail. The launcher slot has already been released and no tail slot owns the still-live Python/poll session, so a second pull can overwrite its session and UI.

**Root cause and silence.** `pull_model()` exposes success but no exactly-once failure/cancel terminal across the whole pipeline. `do_cancel()` signals tasks without first fencing every continuation, the busy-slot guard simply returns, and shared-slot ownership is represented only by whichever native handle happens to exist at the current stage rather than by one stage-independent operation lease. Commit `ffd7ec2a2` added the busy guard with a manager-only test, introducing a deterministic outer-lock leak while preserving a green local assertion.

**Existing test/backstop checked.** `tests/unit/ui/menu/menu_llm/test_mlx_download_single_slot.lua` passes `nil` callbacks and asserts only that the task slot is not overwritten. It confirms the reachable busy state but cannot observe the switcher's prediction lock or a late-success publication.

**Fix.** Give the download one terminal owner `{active, generation, tasks, partial, on_success, on_cancel, guard}`. Every terminal failure settles `on_cancel` exactly once; cancellation revokes authority before signaling native work; retry transfers the same owner; every continuation and server start rechecks authority.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_mlx_download_terminal_contract.lua`. Drive busy slot, user cancel, temp-file refusal, launcher/tail constructor and start refusal, task exit failure, save refusal, and server-start refusal through the real switcher; assert the keymap gate transitions `false -> true` exactly once with no state commit. After a tail-acquisition refusal, assert a second pull is rejected while the same logical owner remains. Deliver exit `0` after cancel and assert zero publication/server start/second terminal.

### `HS-025` — Ollama readiness blocks the Hammerspoon runloop for up to five seconds per attempt

- **Severity:** High
- **Confidence:** High for the blocking call structure; production latency magnitude unmeasured
- **Guarantees:** `G4`, degrading to `G1`/`G2` while the runloop cannot service input/lifecycle work
- **Source:** `ui/menu/menu_llm/models_manager_ollama.lua:172-203`

**Reproduction.** Bind a local listener on port `11434` that accepts the connection but does not return `/api/version`, then select or start an Ollama model. `ensure_ollama_running()` calls synchronous `hs.execute("curl -s --max-time 5 …")`; each timer retry repeats the same blocking call. The configured five-second ceiling is code-derived, not a measured production percentile, but the stalled-local-listener sequence deterministically holds the single Lua runloop until curl exits.

**Root cause and silence.** The former unbounded call was changed to a bounded synchronous call, preserving the architectural violation. Timer deferral changes when the block begins, not which thread/runloop it blocks.

**Existing test/backstop checked.** `tests/unit/ui/menu/menu_llm/test_ollama_manager_nonblocking.lua` explicitly accepts remaining synchronous curl calls when they contain `--max-time 5`; it source-scans the bound rather than asserting off-runloop execution. The test title therefore overstates its guarantee.

**Fix.** Replace every readiness curl with one retained `ShellRunner`/`hs.task` transaction, generation-fence its completion, and make timer retry ownership exact. No synchronous shell call may occur in the menu/timer callback.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_ollama_readiness_async.lua`. Install a tripwire on `hs.execute`, capture the real readiness task/timers, and assert menu and timer callbacks return before any completion. Deliver refusal, stale completion, retry, and success out of order; assert one exact owner and one terminal callback.

**Implemented and independently replayed.** Readiness curl/restart work now runs through retained `ShellRunner` owners, retries use committed `TimerScheduler` handles, and one manager-local single-flight transaction lets a current waiter adopt an in-flight daemon restart without launching a duplicate. Every waiter has an independent freshness predicate and exactly-once terminal. The implementation pass also found a same-boundary delete sibling: an inline `ollama rm` completion could publish success before `start()` subsequently refused. Delete now buffers completion until exact start commitment and rejects late/duplicate completion. Loading the `HEAD` production module into the new behavioral suite produced `0/9`; the completed implementation passes `12/12`. Direct neighboring replays pass `1/1` nonblocking-policy, `10/10` manager-generation, `4/4` bundled-binary, `4/4` daemon-log-rollover, and `2/2` no-usleep tests. The configured worker timeout remains five seconds, but it no longer blocks the Hammerspoon Lua runloop; no production latency percentile is claimed.

### `HS-026` — LLM settings publish state and `hs.settings` before runtime and persistence commit

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; menu/engine truth
- **Source:** `ui/menu/menu_llm/settings_manager.lua:114-158`, `ui/menu/menu_llm/settings_manager.lua:195-286`, `ui/menu/menu_llm/settings_manager.lua:379-438`, `ui/menu/menu_llm/trigger_panel.lua:92-138`

**Reproduction.** Change debounce, word limits, indentation, modifiers, or an instant-trigger toggle while the corresponding keymap setter returns `false`/throws or `save_prefs()` returns `false`. The handlers already mutate `state` and call `hs.settings.set`; they then return failure without restoring either value. The menu/settings claim the candidate while the live engine retains the old behavior. A throwing `hs.settings.set` escapes the menu callback to Hammerspoon Console before any owned rollback exists.

**Root cause and silence.** Duplicated per-setting pipelines publish to two stores before exact runtime/persistence acknowledgement. Callback observability from `HS-016` makes some throws visible, but it does not make the mutation atomic.

**Existing test/backstop checked.** `test_settings_mlx_port.lua` covers valid/invalid happy input; preference-save gate tests require calls to check exact `save_prefs` results but do not assert rollback of already-mutated state/settings/runtime. Trigger-panel fixtures do not inject setter refusal.

**Fix.** Route every LLM setting through one `apply_setting_transaction`: snapshot state/settings/runtime, require exact runtime mutation, persist once through the canonical owner, publish/rebuild only after commit, and compensate exact old values in reverse on refusal. Retain and log explicit debt if compensation itself refuses.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_settings_transaction.lua`. Table-drive settings throw, runtime false/throw, persistence false, and menu callback throw across numeric/reset/toggle/modifier paths; assert exact old state/settings/runtime/menu on every pre-commit failure and exactly-once publication on success.

**Implementation review collateral (open).** The first transaction candidate routes SettingsManager and TriggerPanel actions through the shared owner, but six stock siblings still run the original mutate -> bare runtime `pcall` -> save -> unchecked menu sequence: info-bar visibility, token streaming and multi-streaming in `streaming_panel.lua`; auto-raise temperature in `temperature_panel.lua`; prediction count and reset-on-navigation in `menu_llm/init.lua`. A runtime false/throw or save refusal still leaves each candidate published in state/runtime. `HS-026` remains open until all six delegate to the same owner and the route matrix injects refusal through their real menu callbacks.

### `HS-027` — Model switching publishes state before runtime and persistence commit

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; menu/runtime truth
- **Source:** `ui/menu/menu_llm/model_switcher.lua:491-540`

**Reproduction.** Keep an installed model `A` active, select installed model `B`, and let the requirements callback succeed. Make `keymap.set_llm_model(B)` or `keymap.set_llm_display_model_name(B)` return `false`/throw, or make `save_prefs()` return `false`. The callback has already assigned `state.llm_model = B`, cached its power/backend-specific identity, and called the core LLM model setter. It then returns failure without restoring the prior state/runtime values. The menu state and one or more runtime/persistent stores can therefore describe different active models.

The explicit `No Model` sibling is the same distributed transition. With model `A` active, select `No Model`, then make the display setter, persistence save, or menu refresh refuse. The old implementation could clear one or both runtime identities and mutate shared state before returning failure, leaving the menu, persisted model, and prediction engine on different identities.

**Root cause and silence.** The success continuation is a distributed publish sequence, not a transaction: candidate state is mutated before exact runtime and durable acknowledgements, and no snapshot or reverse compensation exists. `Logger.callback` makes throws visible after `HS-016`, but visibility does not restore the previous model.

**Existing test/backstop checked.** `test_model_switcher_backend_guard.lua`, `test_model_switcher_manager_generation.lua`, and the MLX prediction-lock tests cover stale ordering and terminal unlock. No test injects refusal at each setter/save boundary or asserts rollback of the already-published model identity. The generation fence in `HS-007` prevents an obsolete operation from entering this block; it does not make a current operation atomic.

**Fix.** Give one model switch an exact transition owner. Snapshot every state/keymap/persistence value, stage the candidate, use `keymap.set_llm_model()` as the sole owner of its nested core-model update, require exact runtime setters and one canonical persistence commit, publish menu/profile effects only afterward, and compensate in reverse on any refusal. If compensation itself refuses, retain and file-log explicit recovery debt rather than reporting success.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_model_switch_transaction.lua`. Faithfully route the public keymap setter through its nested core setter; table-drive `false`/throw at both public runtime setters, a nested core throw, preference save, menu refresh, profile follow-up, and the corresponding `No Model` boundaries. Assert the exact old state/runtime/persistence/menu after every pre-commit failure, retained per-boundary recovery debt when compensation refuses, and one exact commit on retry.

**Implemented and independently replayed.** Model selection and `No Model` now snapshot the prior identity, route the core mutation through the single public keymap owner, require durable save and menu publication, compensate only the boundaries that actually committed, and retain any refused compensation for exact retry. Direct profile selection is barred from publishing across unsettled model debt; its separate ordinary publication defect remains open as `HS-028`. The original model matrix produced 13 failures before the fix, and adding the untouched `No Model` sibling produced 6 more red cases. The final exact module passes `26/26`, including false/throw compensation debt for both entry points; the four direct neighbor modules pass `19/19`. An independent read-only second lens returned GO after verifying the faithful nested-core topology and the added `No Model` debt cases.

### `HS-028` — Direct profile selection publishes before runtime and persistence commit

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; menu/runtime truth
- **Source:** `ui/menu/menu_llm/model_switcher.lua:538-549` in the implementation branch (`:379-386` in the audited tree)

**Reproduction.** Keep profile `basic` active, use the LLM menu to select `advanced`, and make the canonical `save_prefs()` return `false` after its write path refuses. `set_llm_profile()` has already assigned `state.llm_active_profile = "advanced"` and called `llm_mod.set_active_profile("advanced")`; it returns false without restoring either value. The live prompt/warmup identity is `advanced`, the durable configuration remains `basic`, and the menu callback has no truthful committed result. A runtime-setter or menu-refresh throw is swallowed by Hammerspoon's callback boundary after the same partial publication.

**Root cause and silence.** Direct profile selection is a second hand-written publication pipeline outside the settings/model transition owners. It mutates shared and runtime state first, treats persistence as a late gate, and owns no reverse compensation or retryable debt. Callback logging from `HS-016` can expose a throw but cannot restore the old profile.

**Existing test/backstop checked.** `test_llm_activation_save_gate.lua` replaces the whole model switcher with a no-op fixture. `test_profiles_manager_edit_delete_pause_gate.lua` covers profile CRUD and pause gating, not activation through `set_llm_profile()`. `test_model_switch_transaction.lua` covers model identity and its recommended-profile follow-up only; it does not invoke the public direct-profile action. No behavioral refusal/rollback test contradicts this claim.

**Fix.** Give direct profile selection one exact transition owner: snapshot the active profile, require the runtime setter, canonical preference save, and menu refresh to commit in order, then report success. On any refusal, restore runtime/state/persistence/menu in reverse and retain explicit recovery debt if compensation itself refuses.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_profile_switch_transaction.lua`. Table-drive runtime throw/false, persistence throw/false, menu throw/false, and a refused compensation; assert the old state/runtime/persisted/menu identity after each failed attempt, that a new action is blocked until exact debt settles, and that the positive path commits each owner once.

**Implemented and independently replayed.** Direct profile selection now snapshots the independently observed state and runtime identities, requires runtime, durable preference, and menu boundaries in order, and restores only through a retained per-boundary compensation ledger. Model selection, `No Model`, and late model continuations all settle that ledger before publishing. The pre-fix behavioral matrix passed only `2/13`; the final exact module passes `15/15`, including false/throw compensation debt and nil-returning void setters. Direct neighbors pass `43/43` (`26` model transaction, `5` backend guard, `10` manager generation, `2` recommended-profile decision). The distinct recommended-profile publication path remains open as `HS-031`, and the older-model/newer-profile ordering race remains open as `HS-029`.

### `HS-029` — A late model switch can overwrite a newer explicit profile choice

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G2`, `G3`; latest user intent and menu/runtime truth
- **Source:** `ui/menu/menu_llm/model_switcher.lua:282-293`, `ui/menu/menu_llm/model_switcher.lua:538-546`, `ui/menu/menu_llm/model_switcher.lua:651-684`, `ui/menu/menu_llm/profiles_manager.lua:50-60`

**Reproduction.** With MLX model `A` active, select installed model `B` and leave its asynchronous requirements probe pending. Before that probe completes, select profile `advanced` from the LLM menu and let that direct profile transaction commit. Now complete the older model probe. `set_llm_profile()` never advances the model request token, so the callback remains current and `apply_recommended_prompt_profile(B)` can select and persist `B`'s recommended profile (for example `basic`), silently overwriting the user's newer explicit `advanced` choice.

**Root cause and silence.** Model request generation tracks model/backend/pause changes but omits the independent generation of explicit profile intent even though model completion owns a profile follow-up. The callback therefore remains valid for model `B`, but cannot distinguish the older automatic recommendation from the newer user-selected profile. Invalidating the whole model request would be a regression: the user asked for both `B` and `advanced`, so `B` must still commit.

**Existing test/backstop checked.** `test_model_switcher_manager_generation.lua` covers model A→B, backend invalidation, and manager-side yields, but never selects a profile while a probe is pending. `test_model_switcher_refuse_profile.lua` exercises only the synchronous recommended-profile dialog. `test_profiles_manager_edit_delete_pause_gate.lua` covers menu availability/CRUD, not ordering against an older model callback. No test contradicts the reachable interleaving.

**Fix.** Track a separate explicit-profile generation. A model request snapshots it at dispatch. When that model later commits, publish the requested model normally but skip only its recommended-profile follow-up if a newer explicit profile transaction committed. Do not bump `req_token` and do not release the MLX prediction lock early; the still-valid model request owns that lock until its normal terminal.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_profile_intent_ordering.lua`. Capture a real pending switch to model `B`, commit `advanced`, then deliver the model completion. Assert `B` publishes exactly once, `advanced` remains current, and the recommendation performs zero profile setter/save/menu side effects beyond the model transaction's own boundaries. The MLX prediction states must be exactly `{false, true}` when `B` terminates. Add a control with no intervening profile choice where the recommendation still applies normally. Behaviorally prove that clone, create, and active-profile deletion route their resulting selection through the same owner; a refused fallback must leave the old profile and registry untouched.

**Implemented and independently replayed.** `model_switcher` now snapshots a profile-intent generation before asynchronous model dispatch and increments it only after the explicit profile's runtime, persistence, and menu boundaries all commit. Model completion always publishes the requested model and releases the MLX lock at its normal terminal, but skips only an older automatic recommendation when that generation changed. Clone/create activation and active-profile deletion now delegate to the same exact owner; deletion commits the `basic` fallback while the old profile is still resolvable, before registry removal. The core ordering matrix passes `5/5`, the real ProfilesManager delegation matrix passes `4/4`, and six direct transaction/generation/menu neighbors pass `60/60` plus their source-only guard. Syntax, conventions, false-green ratchet, and scoped diff checks are green. A read-only second lens returned GO and kept Auto-detect (`HS-031`) plus shortcut/registry deletion ownership (`HS-033`) explicitly separate.

### `HS-030` — Exact `--only` targets falsely fail source-only test modules

- **Severity:** Low
- **Confidence:** High
- **Guarantee:** verification integrity and focused developer feedback
- **Source:** `tests/run.lua:201-234`, `tests/support/only_selector.lua:194-201`, `tests/support/only_selector.lua:241-260`

**Reproduction.** Run `lua tests/run.lua --only tests/unit/lib/test_config_overrides_comment_strip.lua`. The selector correctly loads exactly one module, the module executes its top-level assertions and prints `[PASS]`, then the unfixed runner changes the result to failure with `no test case matched the requested --only filter` because that source-only module deliberately registers no `helpers.it()` case.

**Root cause and silence.** Exact-path selection correctly clears `case_filter`, but `tests/run.lua` passes the original non-empty `only_filter` to `OnlySelector.require_match()`. The zero-case guard cannot distinguish an unknown case-name filter from a successfully loaded exact module whose contract is expressed through load-time assertions. This makes the new focused-module feature reject a supported class of existing tests and can send developers back to broad/full-suite replays.

**Existing test/backstop checked.** `test_runner_only_selector.lua` proves that exact targets return `case_filter=nil` and separately proves that an unknown textual filter with zero cases fails closed. Its runner-source assertion explicitly requires `OnlySelector.require_match(r, only_filter)`, thereby blessing the wrong transitive argument. No test exercises a real exact source-only module through the runner.

**Fix.** Apply the zero-case match guard only to a real case-name filter, not to an exact module target. Preserve load failures as failures and preserve unknown textual/path fallback as fail-closed. The selector should return an explicit target kind (or the runner should pass `case_filter`) rather than reinterpreting the original argument after classification.

**Regression test.** Extend `tests/unit/test_runner_only_selector.lua` with a real runner fixture or subprocess that selects an exact source-only module whose top-level assertion succeeds and registers zero cases; assert exit `0`, one loaded module, and no synthetic no-match failure. Add a throwing source-only control and an unknown textual filter control so the change cannot hide load failures or zero-match typos.

**Implemented and behaviorally replayed.** The runner now passes the selector's classified `case_filter` to the zero-case guard, so an exact module target with no registered cases is accepted only after its module loads successfully; unknown textual/path filters remain fail-closed, and an actual load failure remains counted. The exact pre-fix command loaded `1/834`, printed the source-only module's `[PASS]`, then exited `1` with the synthetic no-match error. The same command now exits `0`. The runner regression module executes a child runner against that real source-only target and passes `14/14`, including unknown-filter and throwing-load controls.

### `HS-031` — Recommended-profile actions bypass the transactional profile owner

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; menu/runtime truth
- **Source:** `ui/menu/menu_llm/model_switcher.lua:384-453`, `ui/menu/menu_llm/profiles_manager.lua:158-171`, `ui/menu/menu_llm/init.lua:356-362`

**Reproduction A.** Keep profile `basic` active with an enabled chat model, click the user-facing recommended-profile/auto-detect row, and accept `advanced`. Make `llm_mod.set_active_profile("advanced")` throw from its native timer acquisition. `apply_recommended_prompt_profile()` has already assigned `state.llm_active_profile = "advanced"`; it returns `false` without restoring that state, and both public wrappers discard the result. The menu state says `advanced` while runtime and durable configuration remain `basic`. Completion models take the same non-transactional mutation path without a dialog. A simple `save_prefs()==false` reproduction is **refuted**: the canonical `PreferencesTransaction` restores state and runtime on that boundary.

**Reproduction B.** Enable LLM but select `No Model`, then click Profiles → Auto-detect. The row remains enabled. The recommendation helper returns `nil` immediately for an empty model; `menu_llm/init.lua` and `profiles_manager.lua` both discard that result, and the fallback warning is reachable only when the injected helper itself is missing. The click therefore produces no result and no visible failure.

**Root cause and silence.** `HS-028` makes explicit profile-row selection transactional, but the sibling recommendation entry point retains a second hand-written state -> runtime -> persistence -> menu pipeline. `profiles_manager.lua` also discards the returned result, so a refused transaction is indistinguishable from success to that menu action. Callback logging can expose a throw but cannot restore the prior profile.

**Existing test/backstop checked.** `tests/unit/ui/test_model_switcher_refuse_profile.lua` proves only that refusing the dialog has no effects and that a friendly accepted path calls each boundary once. It supplies no refusal/throw, rollback, or debt case. `test_profile_switch_transaction.lua` calls only `set_llm_profile()` and therefore does not cover this public sibling. No existing test contradicts the sequence.

**Fix.** Route accepted recommended profiles, including silent completion recommendations, through the exact profile transition owner introduced by `HS-028`. Mark an internal model-completion recommendation separately from explicit user intent so it does not advance `HS-029`'s profile generation. Propagate the literal result through `menu_llm/init.lua`, `profiles_manager.lua`, and `select_profile()`: no active model must return `false` with a visible unavailable warning, a dialog throw must return `false` with an ERROR, and voluntary cancellation remains a successful no-op. Never duplicate state/runtime/save/menu publication inside the recommendation helper.

**Regression test.** Extend the profile transaction suite with both accepted-dialog and silent-completion entry points. Table-drive runtime throw/false and menu refusal/throw plus refused compensation; assert the old profile at every observable boundary, retained exact debt, a truthful `false` result through both public adapters, and exactly one shared transaction on success. Add an enabled-LLM/`No Model` Auto-detect case asserting a literal `false` plus one visible unavailable warning. Preserve the existing preference-rollback tests as a contradiction to the refuted simple save-false claim.

**Implemented and independently replayed.** Accepted chat recommendations and silent completion recommendations now delegate to the exact profile transaction owner; model-owned recommendations explicitly avoid advancing the newer user-intent generation. The helper settles retained model/profile recovery debt before any dialogue or no-op, propagates literal results through the menu and ProfilesManager adapters, reports `No Model` visibly, and contains a throwing dialog with a contextual ERROR. The primary transaction module passes `27/27`; the five exact adapter, intent-ordering, ProfilesManager, activation, and parent-model modules pass `56/56`. Syntax/conventions/false-green/diff gates are green, and a read-only second lens returned GO. The clone/create registry rollback remains separately tracked as `HS-034`.

### `HS-032` — Ollama pull publishes model identity before the parent transaction exists

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`; runtime/persistence truth
- **Source:** `ui/menu/menu_llm/models_manager_ollama.lua:696-756`, `ui/menu/menu_llm/model_switcher.lua:704-802`

**Reproduction.** Keep installed model `A` active, select absent Ollama model `B`, and let the pull process finish successfully. Make the canonical `save_prefs()` call inside `pull_model()` return `false`. Before that refusal, the manager assigns `state.llm_model = B` and calls both runtime keymap setters. It then reports failure to `model_switcher`, whose failure branch only releases the prediction gate because its model transition snapshot is created exclusively inside the success continuation. The menu/runtime therefore say `B` while durable preferences still say `A`.

**Root cause and silence.** The manager duplicates state/runtime/persistence publication below the parent model transaction. The transactional owner added for `HS-027` begins too late to compensate a manager-side failure, so a truthful failure terminal alone cannot restore the old identity.

**Existing test/backstop checked.** `test_model_switch_transaction.lua` replaces the requirements manager and therefore cannot observe publication below its callback seam. `test_model_switcher_manager_generation.lua` drives only stale Ollama pull completion and asserts zero publication there; it has no current-generation save refusal. The `HS-010` success control deliberately asserts terminal settlement only and does not bless this duplicate publication.

**Fix.** Make `pull_model()` own only download/loadability and terminal delivery. The parent `model_switcher` transaction must remain the sole publisher of model state, runtime setters, persistence, recommendation, and menu identity. If a standalone manager caller still needs publication, give it an explicit transactional adapter rather than an implicit side effect.

**Regression test.** Drive the real Ollama manager under the real switcher: complete the pull, then refuse the first persistence boundary. Assert exact old state/runtime/durable/menu identity, one failure terminal and restored prediction gate. On success, assert the parent transaction publishes each boundary once and the manager performs zero direct model publication.

### `HS-033` — Profile deletion can lose a live global shortcut and keep the deleted prompt executable

- **Severity:** High
- **Confidence:** High
- **Guarantees:** `G1`, `G2`, `G3`; exact hotkey ownership and profile SSOT
- **Source:** `ui/menu/menu_llm/profiles_manager.lua:42-48`, `ui/menu/menu_llm/profiles_manager.lua:272-297`, `ui/menu/menu_llm/trigger_orchestrator.lua:155-177`, `ui/menu/menu_llm/trigger_orchestrator.lua:220-264`, `modules/llm/init.lua:1183-1186`, `modules/llm/init.lua:1460-1467`

**Reproduction.** Start with custom profile `P` and an enabled global shortcut for it. Click Delete and confirm while the exact hotkey handle's `delete()` throws. `apply_llm_profile_shortcut()` catches and discards that throw, drops the handle from its owner table, erases the shortcut preference and returns no failure. The caller ignores the result, replaces `state.llm_user_profiles`, persists the deletion and reports it through the menu. Press the still-native chord: its retained closure calls `trigger_prediction_with_profile(P)`. Because `sync_profiles()` assigns the dead public field `llm_mod.user_profiles` instead of calling `set_user_profiles()`, `CoreState.user_profiles` still contains the old table and resolves the supposedly deleted prompt.

**Implementation-phase siblings (same owner).** Editing a profile shortcut is also release-first and non-transactional. The function forgets the old handle before it knows whether `hs.hotkey.new()` acquired and enabled the replacement; construction refusal clears the live-handle slot, while `activate_hotkey()` discards an `enable()` throw and reports success. Both paths can persist a candidate chord that cannot fire after the prior chord has already been lost. The primary LLM trigger shortcut repeats the same sequence and additionally leaves candidate runtime/preferences published if persistence refuses after acquisition. The `HS-033` hotkey transaction must cover fresh bind, activation, action-to-action rebind, disable, rollback, and profile deletion for both trigger families, retaining the exact old owner and preference until the successor commits.

**Root cause and silence.** Two owners false-commit together: raw hotkey teardown is treated as settled on `pcall` success alone and its exact handle is discarded, while replacement of the user-profile table is published to a field the runtime never reads. The boot alias masks the second defect for in-place insert/edit mutations; Delete is the reachable replacement-table path that exposes it.

**Existing test/backstop checked.** `test_profiles_manager_edit_delete_pause_gate.lua` checks only row availability and never invokes Delete. The tests that load `trigger_orchestrator` replace it with a stub; `test_hotkey_registrar.lua` covers the correct adapter but this module bypasses that owner with raw handles. No behavioral test contradicts the sequence.

**Fix.** Give both LLM shortcut families an exact hotkey transition owner, then make profile deletion join it before publishing registry, active-profile, persistence, or menu changes. Retain the exact old handle on release/construction/activation refusal, retry it through the shared hotkey lifecycle adapter, and publish a successor only after acquisition and persistence settle. Publish replacement profile tables only through `llm_mod.set_user_profiles()` and roll back every earlier boundary on refusal.

**Regression test.** Add `tests/unit/ui/menu/menu_llm/test_profile_delete_transaction.lua`. Use a native-shaped hotkey whose `delete()` throws/returns false, invoke the real confirmed Delete action, and assert the old profile, shortcut preference, runtime registry, durable state, menu and exact handle remain. After the same handle settles, assert `set_user_profiles(kept)` commits once and the chord cannot execute `P`. Table-drive fresh bind, action-to-action rebind, disable, and persistence refusal for both primary and profile shortcuts: the exact old handle/chord and preference must remain, with no false menu success.

### `HS-034` — A refused clone/create leaves an uncommitted ghost profile in memory

- **Severity:** Medium
- **Confidence:** High
- **Guarantees:** `G1`, `G2`; runtime/durable/menu registry truth
- **Source:** `ui/menu/menu_llm/profiles_manager.lua:79-94`, `ui/menu/menu_llm/profiles_manager.lua:326-341`

**Reproduction.** Start with built-in profile `basic`, choose Clone or Create, then make the real transactional `set_llm_profile(candidate)` refuse (for example, let the runtime setter mutate and throw while its compensation succeeds). Both paths insert the candidate into `state.llm_user_profiles` before asking the activation owner to commit. Clone returns `false`; Create loses the same `false` below its protected editor callback. Neither removes the candidate. Active/runtime/durable/menu state remains `basic`, but the in-memory registry contains a profile that creation never committed; the ghost appears on a later rebuild and can be persisted by an unrelated action.

**Root cause and silence.** Registry construction and activation are split transactions without ownership transfer or candidate rollback. Making profile selection transactional in `HS-028` exposes a truthful refusal but the callers treat their earlier list insertion as irreversible. The Create callback additionally discards the returned failure.

**Existing test/backstop checked.** `test_profiles_manager_profile_activation_owner.lua` proves only that the candidate is resolvable when activation begins. Its refusal case observes `registry_size == 1` at that boundary but never asserts the final registry, editor, notification, durable state, or menu. No existing clone/create test injects a real runtime-setter failure.

**Fix.** Give clone/create one candidate-registry owner around activation. On a clean activation refusal, remove the exact newly inserted table before returning failure and emit no editor/success notification. If the profile transition retains compensation debt that still references the candidate, retain an explicit candidate cleanup debt and remove it exactly once only after the transition settles. Coordinate runtime registry publication with `HS-033` rather than assigning a second public field.

**Regression test.** Drive real `ProfilesManager` plus real `ModelSwitcher` from an empty user registry. Inject a runtime setter that mutates then throws, with successful compensation, and assert Clone and Create leave zero profiles, `basic` at every boundary, and zero editor/notification. Add a refused-compensation case proving the exact candidate remains owned while live and is removed after recovery, never by a later unrelated profile.

### Cross-driver parity findings discovered during implementation

These two confirmed Linux defects are outside the Hammerspoon severity total above. They were re-derived while implementing `HS-006` and are retained here because they share its byte/codepoint class and otherwise risk disappearing between implementation commits.

#### `PARITY-001` — Linux dynamic rules over-delete non-ASCII suffixes

- **Severity:** High
- **Confidence:** High
- **Guarantee:** output integrity
- **Source:** `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:351-358`

**Reproduction.** Register or load a dynamic rule with suffix `été`, type `zzété` followed by an ASCII trigger, and fire it. The manager computes `#match.rule.suffix + 1`, so it requests six codepoint Backspaces for a three-codepoint suffix plus one trigger and erases the two preceding characters as collateral.

**Test gap and fix.** Existing dynamic-manager tests force the ASCII trigger `\\` and use ASCII rules. Add a behavioral Unicode rule test asserting four deletions total (three suffix codepoints plus one trigger), and derive both suffix and trigger lengths with strict UTF-8 validation rather than Lua byte length.

#### `PARITY-002` — Linux cannot recognize the shipped multibyte magic key

- **Severity:** High
- **Confidence:** High
- **Guarantee:** output availability
- **Source:** `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:325-343`, `static/ergopti_plus/_shared/modules/features/manifest.toml:307-309`

**Reproduction.** Use the canonical default trigger `★`, then type `td★` or `@p★`. `buffer:sub(-1)` extracts one byte and can never equal the three-byte trigger; `buffer:sub(1, -2)` would likewise remove only one byte. The dynamic path returns false, so the shipped default cannot fire any Linux dynamic rule.

**Test gap and fix.** Existing manager tests initialize with `trigger_char = "\\"`; the separate magic-key tests prove `★` is a valid single codepoint but never feed it through `on_trigger()`. Add `linux/tests/unit/modules/hotstrings/test_dynamic_multibyte_trigger.lua`, compare the full byte suffix with `buffer:sub(-#t)`, strip exactly `#t` bytes after strict one-codepoint validation, and assert the default fires without malformed intermediate text.

## 3. Refuted claims

The following claims were actively investigated and rejected:

1. **“The logger keeps writing to the process-start date.”** Refuted. `infra/logger.lua:756-785` re-evaluates the calendar date on every write, closes/reopens the handle, updates both unified/error paths, and schedules rollover purge. `test_logger_rollover_purge_integrity.lua` and topical rollover tests exercise the behavior.
2. **“No production logs exist because the driver never logged.”** Refuted as an invalid inference. The config root was resolved first; this host lacks artifacts at three exact locations only. See [Performance](#4-performance).
3. **“Tooltip has an independent static matcher.”** Refuted. The event path and preview both call `Expander.resolve_magic_action`; `infra/hotstring_engine.lua` is a pure shared decision re-export. `test_preview_matches_engine.lua`, gate/cross-kind/winner/terminator tests, and `test_would_fire_single_source.lua` cover the shared resolver.
4. **“AHK and Hammerspoon word-boundary behavior proves a tooltip divergence.”** Refuted. Their completing-event ownership differs intentionally; Hammerspoon’s preview and engine share the same local semantics.
5. **“Ordinary Backspace clears preview but only trims the engine.”** Refuted. `keymap/init.lua:1149-1174` UTF-8-trims the authoritative buffer and immediately previews it; personal combos revalidate against that buffer.
6. **“A declined/no-op match rewrites the buffer.”** Refuted by the current commit gates and `test_noop_expansion_passthrough.lua`, `test_auto_expand_flag_gate.lua`, and `test_preview_star_requires_auto_expand.lua`.
7. **“Dynamic/personal preview normally computes a second output.”** Refuted. Rules share `match_buffer` and a single-use snapshot; personal preview/fire share `resolve_combo` and exact-buffer revalidation.
8. **“Ignored/private apps still enter text features.”** Refuted. Classification exits before character reads/interceptors/buffer/preview. `test_ignored_window_deferred_buffer_snapshot.lua` and privacy suites cover transitions.
9. **“Synthetic ownership still relies on timing, PID, or text.”** Refuted. `event_provenance.lua` requires an exact userdata ledger tag; PID is diagnostic only. Provenance and queue-drain suites cover it.
10. **“Tooltip canvas/AX rendering is synchronous in the keymap tap.”** Refuted. Rendering and navigation dismissal are stamped/deferred; `test_preview_render_off_hid_thread.lua` trips on inline render.
11. **“Pause reuses pre-pause text context.”** Refuted. Keymap clears context on pause and resume; `HS-012` concerns omitted sibling owners, not the core text buffer.
12. **“Restoring profile/model state alone warms a model.”** Refuted. `modules/llm/init.lua:1198-1200,1220` requires the runtime LLM gate. Existing warmup-gate tests agree.
13. **“Every profile change leaves an old prediction reachable.”** Refuted for stock user paths. Menu clicks quarantine runtime before the action, keyboard navigation resets immediately, profile hotkeys reset explicitly, and model switches call `prediction_engine.reset()`. The direct internal setter alone lacks a prediction reset, but no unabsorbed user sequence was found.
14. **“HTTP generation routes an old response to the wrong recipient.”** Refuted. The adapter’s generation prevents wrong-recipient delivery; `HS-009` is instead missing terminal completion when independent owners share a latest-wins slot.
15. **“The gesture first-frame kernel gate should be removed.”** Refuted. Pre-first-touch dormancy is intentional. `HS-001` specifically distinguishes a committed running watcher from a native start refusal.
16. **“Gesture peak confirmation is frame-rate dependent again.”** Refuted; current logic uses elapsed time and the related behavior tests remain present.
17. **“The script-control eventtap is torn down by pause/layout switch.”** Refuted. The dedicated tap survives binding pause and the layout watcher skips the prohibited rebuild path.
18. **“Reload and quit still indiscriminately kill Karabiner processes.”** Refuted. Current exact token/lease isolation owns Ergopti state only. Older sentinel wording in project memory is documentation drift.
19. **“A native eventtap `stop()` refusal creates a separate demonstrated leak.”** Not promoted: no distinct valid native refusal contract or reproduction was established beyond already-owned watchdog paths.
20. **“A buffered live launcher ACK can currently outrank inner HUP or parent STOP/EOF.”** Refuted for stock paths. `RemapLeaseWorker.swift:2186-2281` processes terminal parent state before inner progress, and `:2432-2500` rechecks both guardian and private transport immediately before publishing a live ACK. `testPublicTerminalBatchNeverForwardsBufferedPause`, `testInnerHUPOutranksBufferedReadyAcknowledgement`, and `testParentEOFAfterPublicPingOutranksItsLatePong` are behavioral counterexamples. The idempotent-wire-command seam listed under suspected claims is narrower and not reachable through the stock Lua controller.
21. **“Ollama pull B can overwrite active pull A because there is no entry guard.”** Refuted on the implementation audited for this fix. `models_manager_ollama.lua` rejects a second pull while `active_tasks["ollama_pull"]` is owned and its completion compares the exact task before clearing the slot. `test_model_switcher_manager_generation.lua` now drives two dispatches and preserves the first native handle. `HS-010` remains confirmed for cancellation refusal/native-return/terminal settlement, not concurrent slot overwrite.

## 4. Performance

### 4.1 Evidence provenance

`C:/Users/admin/AppData/Roaming/Ergopti/paths.toml` resolves:

```toml
ConfigDirPath = "D:/Documents/GitHub/config/ergopti_plus/"
```

Production logs should therefore be under `D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/`. The audit checked:

- `D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/` — missing;
- `C:/Users/admin/.config/ergopti_plus/hammerspoon/logs/` — missing;
- `C:/Users/admin/.hammerspoon/logs/` — missing.

Conclusion: **no production profiler artifact was found at X, Y, or Z on this host.** This does not imply that the target Mac never logged.

The available `D:/tmp/ErgoptiPlus_2026-08-20.log` and `D:/tmp/ErgoptiPlus_boot.log` are test-harness artifacts. Case-sensitive counts were `4` and `0`. The four lines all say `Slow keydown: 21.00 ms (q)` and are duplicated fixture output immediately adjacent to a passing test. No percentile, boot total, canvas cost, AX cost, or production slow-event count is reported from them.

### 4.2 Confirmed blocking structures, not production timing measurements

| Path                 | Code-derived cost/complexity                                                                              | Status                                                                                                    |
| -------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Terminal replacement | Candidate: `D` timer-owned delete-pair turns at the configured `20 ms` cadence; zero payload `post`/`usleep` inside the eventtap | `HS-003` remains open because timer/drain/provenance ownership is not yet correct; latency is unmeasured |
| Keylogger taps       | O(events/chunks) snapshot conversion + JSON encode + unbuffered write; native app lookup on some branches | Structural finding `HS-004`; latency unmeasured                                                           |
| Ollama readiness     | retained async curl worker with a configured five-second per-attempt bound and `0.5 s` owned retry cadence | `HS-025` fixed; dispatch is bounded in-memory Lua work, runtime worker latency remains unprofiled           |
| MLX adoption         | synchronous `curl --max-time 1` in `models_manager_mlx_server.lua:189-191`                                | **Performance hypothesis**, not promoted without target profile                                           |
| Backend/menu helpers | several synchronous `os.execute`/`hs.execute` paths on the Hammerspoon runloop                            | Inventory item; measure on target before prioritizing                                                     |

The previously documented boot costs—approximately `2 s` for a disable/enable group round trip and `0.6 s` for shell purge—are historical measurements, not re-measured here. Current code keeps the group work outside the synchronous boot transaction and the logger purge uses an owned, no-subprocess implementation; `test_logger_no_shell_at_boot.lua` and `test_logger_deferred_purge.lua` guard those fixes.

### 4.3 Offensive optimization candidates (explicitly unmeasured)

1. **WPM mouse tracking.** `ui/wpm/wpm_widget.lua:658-675` registers `mouseMoved`; the `0.2 s` throttle happens only after every event has entered Lua. Target: remove `mouseMoved` from the tap and sample `hs.mouse.absolutePosition()` on the existing 5 Hz widget timer. Current cost is O(mouse events), target O(widget ticks). Risk: an out-and-back move between samples is missed. `test_wpm_widget_mouse_throttle.lua` is false-green because it source-scans constants/branches rather than callback entries.
2. **Terminal identity lookup.** `adapters/text_sender.lua:117-140` queries focused window/frontmost app/bundle/name for every deleting replacement. Target: cache by focus/app generation. Risk: stale target on rapid focus changes; the generation must be part of the key.
3. **Keylogger app attribution.** Modifier/shortcut paths call `frontmostApplication()` despite already-owned context. Target: reuse the focus-generation cache. Risk: attribution drift at exact focus boundaries.
4. **Prediction candidate loop.** `prediction_engine.lua:934-953` recomputes `buffer:lower()` per candidate. Hoisting removes repeated O(buffer-length) allocations. Risk is low, but profile before changing because model/network time may dominate completely.
5. **Dynamic rules.** Match remains O(R) per preview. Current rule count is small; no index change is recommended without profile evidence and mutation-invalidation tests.
6. **Tooltip/canvas.** Renderer work is already off the HID callback and watcher reuse is tested. Obtain real `hotpath_profiler`/canvas timings before proposing cache or layout changes.
7. **VS Code AX.** The 200 ms positive/negative cache remains in place; no uncached AX frame query was found on the keymap callback. Preserve focus-generation invalidation if optimizing further.

`G4` conclusion: structural hazards are proven, but production performance remains **non-covered** until the audit is run on the target Mac with `infra/hotpath_profiler.lua`, `infra/boot_profiler.lua`, and `infra/perf.lua` artifacts from the resolved config directory.

## 5. `PROJECT_MEMORY` watch-list

Each memory item was treated as a hypothesis/watch-list entry; current code and tests, not prose, determined the status.

| Memory class                                              | Status                                                    | Current evidence                                                                                                                                                                                                                                                                                                                   |
| --------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `project-lua-closure-before-local-nil-global`             | Fix in place                                              | The prior streaming temporary-path class is declared before callbacks; the LLM callback inventory found no promoted recurrence.                                                                                                                                                                                                    |
| `project-hs-stateful-native-test-doubles`                 | Same class found elsewhere                                | `HS-001`, `HS-013`, and `HS-014` are hidden by friendly stubs that cannot represent native refusal/state.                                                                                                                                                                                                                          |
| `project-hs-native-result-contracts`                      | Regressed                                                 | `HS-001` and `HS-014` treat native userdata return/pcall success as operational commitment.                                                                                                                                                                                                                                        |
| `project-hs-process-lifecycle-transaction`                | Regressed                                                 | `HS-001`, `HS-008`, `HS-010`, and `HS-011` publish/drop capabilities before exact start/stop settlement.                                                                                                                                                                                                                           |
| `project-hs-timer-commit-contract`                        | Mostly in place; sibling omissions                        | TimerScheduler owners generally consume handle+commit. `HS-012` shows pause does not own all already-armed timers.                                                                                                                                                                                                                 |
| `project-hs-timer-callback-errors-invisible`              | Regressed at callback sites                               | `HS-016` consumes callback errors below the logger-aware boundary. Most timer owners use contextual `xpcall`.                                                                                                                                                                                                                      |
| `project-hs-ordered-startup-transaction`                  | Regressed transitively                                    | Root ignores Karabiner init refusal in `HS-019`; gesture watcher start also false-commits in `HS-001`.                                                                                                                                                                                                                             |
| `project-hs-synthetic-injection-choke-point`              | Fix in place literally; broader logical invariant missing | Raw synthetic events retain exact adapter provenance. Repeat-key is instead a second logical replacement producer outside `perform_text_replacement()` and omits common commit/preview ordering (`HS-005`).                                                                                                                        |
| `project-hs-native-eventtap-disable-recovery`             | Watchdog fix remains; prevention candidate is incomplete  | `HS-003` moves Terminal pacing out of the tap but retains ownership blockers, and `HS-004` still puts persistence work there; recovery is not a substitute for prevention.                                                                                                                                                           |
| `project-macos-script-control-tap-lifecycle`              | Fix in place                                              | The dedicated tap survives pause and layout switches; no contrary path was found.                                                                                                                                                                                                                                                  |
| `project-hs-karabiner-exact-lease-isolation`              | Fix in place in lease layer; parent fail-fast gap         | Exact token-scoped ownership and reload/quit isolation remain. `HS-019` is the root/menu consumer, not a stock-process kill regression.                                                                                                                                                                                            |
| `project-touchdevice-dormancy-is-kernel`                  | Code/doc aligned                                          | No repeated kernel readiness loop was proposed. `HS-001` preserves the `running=true, alive=false` case.                                                                                                                                                                                                                           |
| `project-hs-clipboard-transaction-ownership`              | Partial                                                   | `search_web` snapshots/restores all data and retains retry debt, but lifecycle cleanup omits its live transaction (`HS-012`).                                                                                                                                                                                                      |
| `project-hs-keylogger-append-commit`                      | Correctness fix in place; hot-path cost remains           | Write refusal retains FIFO ownership. Immediate drain inside taps is `HS-004`.                                                                                                                                                                                                                                                     |
| `project-macos-eventtap-no-blocking`                      | Candidate removes inline Terminal pacing; ownership open  | `HS-003` still has timer/drain/provenance blockers; `HS-004` remains.                                                                                                                                                                                                                                                                |
| `project-typing-order-and-atomicity` versus eventtap rule | Candidate reconciles the callback boundary only           | Exact-app replacement pacing is outside the eventtap, but its periodic owner, physical replay, pause admission, and teardown drain remain open under `HS-003`.                                                                                                                                                                      |
| `project-macos-llm-runtime-enable-gate`                   | Base fix in place; pause side channels                    | Profile restoration alone cannot warm. Remote/startup continuations can cross pause (`HS-012`).                                                                                                                                                                                                                                    |
| Daily logger rollover/purge                               | Fix in place                                              | Re-derived from `infra/logger.lua`; rollover/purge tests cover both sink date and retained timer ownership.                                                                                                                                                                                                                        |
| Tooltip/engine single resolver                            | Fix in place, but state mutation siblings diverge         | Matching itself is shared. Navigation, Escape, and repeat break truth through state/presentation mutation (`HS-002`, `HS-021`, `HS-005`).                                                                                                                                                                                           |
| Reload-vs-quit sentinel narrative                         | Documentation drift                                       | Current exact lease revocation supersedes the older broad “kill on quit” model; no stock Karabiner process ownership was found.                                                                                                                                                                                                    |

Recent-fix collateral checked:

- `50c2d43e6` fixed terminal rendering by introducing eager paced delivery, causing `HS-003`.
- `dafbcb591e` strengthened lifecycle/timer ownership tests but missed sibling native watcher acquisition and refusal shapes (`HS-001`).
- `ba681d500f` connected the script-control extras path but retained silent `pcall` (`HS-016`).
- `3e50bb392` / `37da444bd` fenced the outer MLX switch without passing identity below destructive manager effects (`HS-007`).
- `ffd7ec2a2` added MLX download slot ownership with manager-only coverage. The current Ollama path also has an entry guard; `HS-010` is the narrower cancellation/terminal blind spot, while `HS-024` is the MLX outer-lock/late-completion blind spot.

## 6. Coverage register and loop-until-dry

Legend: `B` = audited and behaviorally/source-blanched; `F` = confirmed finding; `R` = claim investigated/refuted; `S` = suspected, not promoted; `N` = not covered on this host. A cell can contain both a finding and a blanch/refutation for sibling paths.

| Area                                                                                 | `G1`           | `G2`                   | `G3`               | `G4`                   | `G5`       | Dry status / evidence                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------ | -------------- | ---------------------- | ------------------ | ---------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `modules/keymap/{init,state,registry,utils,terminators}`                             | `B`            | `F HS-002,021`         | `B`                | `B/R`                  | `F HS-002,021` | Input pass 3 was dry before the implementation-phase Escape sibling rescan; that new finding resets this zone to one unclean follow-up pass. Registry tail indexes, case-conform fast path, ignored/private gates and Backspace were rechecked.                                                                                 |
| `modules/keymap/expander`, `adapters/{synthetic_input,event_provenance,text_sender}` | `B/F`          | `F HS-003,005`         | `F HS-003,005`     | `F HS-003`             | `F HS-005` | The second implementation lens reopened `HS-003` on exact timer settlement, deferred-work drain, physical provenance, pause admission, and teardown ordering.                                                                                                           |
| `modules/dynamic_hotstrings/**`, personal hotstrings                                 | `B`            | `F HS-006`             | `B`                | `B`                    | `B/R`      | Input pass 3 dry; normal preview/action snapshot path is single-source.                                                                                                                                                                                                    |
| `modules/keylogger/**`                                                               | `B`            | `B`                    | `B`                | `F HS-004`             | n/a        | Input pass 3 dry for requested lens; persistence refusal correctness is blanched, tap cost is not.                                                                                                                                                                         |
| `ui/tooltip/**`, renderer/watchers                                                   | `B`            | `B`                    | `B`                | `B/N profile`          | `B/R`      | Source behavior dry; canvas performance unmeasured on native macOS.                                                                                                                                                                                                        |
| `modules/llm/**`, prompt/parser/profiles/streaming                                   | `B`            | `F HS-009`             | `F HS-009`         | `S`                    | `R`        | Two full post-candidate LLM passes were dry. Direct profile-setter claim was rejected for stock paths.                                                                                                                                                                     |
| `ui/menu/menu_llm/**`, MLX/Ollama managers                                           | `F HS-008,024,026–029,031–034` | `F HS-007,009,010,018,024,026–029,031–034` | `F HS-007–010,018,024,029,032–034` | `F HS-025` | `F HS-018,026–029,031–034` | Two audit passes were dry before implementation-phase transaction/terminal rescans found `HS-024`–`HS-034`; this zone is reopened until a clean post-fix pass.                                                                                                   |
| `modules/gestures/{init,engine,actions,conflicts}`                                   | `F HS-001`     | `F HS-001,012,015`     | `F HS-001,012`     | `S`                    | n/a        | Watcher domain had a clean recheck; late search/screenshot findings received one clean sibling recheck, not two-pass dry.                                                                                                                                                  |
| `modules/shortcuts/**`, script control, keyboard slots                               | `F HS-016`     | `F HS-013,016`         | `F HS-012,013`     | `B`                    | n/a        | Late findings verified; one clean recheck only, therefore not claimed two-pass dry. Dedicated script-control tap lifecycle blanched.                                                                                                                                       |
| `platform/remap/**`, generator, watchers, onboarding, KE lifecycle                   | `F HS-011,019` | `F HS-011,019`         | `F HS-011`         | `S`                    | n/a        | Generator, KE lease/reload lifecycle and input-source state dry; onboarding late finding has one clean recheck.                                                                                                                                                            |
| `infra/logger`, boot/hotpath/perf                                                    | `B/R`          | `B`                    | `B`                | `N production profile` | n/a        | Logger rollover/purge dry; production performance explicitly non-covered.                                                                                                                                                                                                  |
| `tests/run.lua`, focused selector                                                    | n/a            | `F HS-020,030`         | n/a                | `F HS-020`             | n/a        | Exact module discovery is now narrow, but implementation-phase replay found the distinct source-only zero-case false failure tracked by `HS-030`; runner coverage is reopened.                                                                                                          |
| `infra/vscode_bridge`                                                                | `B`            | `F HS-014,023`         | `B`                | `B/S`                  | n/a        | Bind contract verified against primary source; implementation rescan found the independent two-file write/flush false-commit.                                                                                                                                               |
| Launcher/lease guardian (presumed `BLINDER`)                                         | `B/N native`   | `B/N native`           | `B/N native`       | `N profile`            | n/a        | One complete boundary pass plus a targeted ACK/HUP recheck. Exact lease identity, STOP/EOF priority, live-transport gate, and final ACK revalidation are guarded; native POSIX/ServiceManagement execution was unavailable, so this is audited-clean but not two-pass dry. |
| `modules/updater/**`                                                                 | `B`            | `F HS-017`             | `F HS-017`         | `B`                    | n/a        | Same-generation race verified; one clean sibling pass only.                                                                                                                                                                                                                |
| `infra/file_watchers`                                                                | `S`            | `S`                    | `S`                | `S`                    | n/a        | **Not dry.** Lua acquisition is not robust to every start-refusal shape, but no deterministic valid-path native reproduction was established.                                                                                                                              |
| Menubar/WPM/UI builders                                                              | `B/F HS-022,026` | `F HS-012,018,022,026` | `F HS-012,018,022` | `S/N profile`          | `F HS-018,026` | Global bulk actions and LLM setting writers were reopened by implementation-phase refusal testing; mouseMoved/canvas optimization still requires profiles.                                                                                                      |
| First-launch UI/config schema/i18n                                                   | `B`            | `B/R`                  | `B`                | `N`                    | n/a        | Canonical lowercase Hammerspoon schema and `hs.settings` locale persistence blanched.                                                                                                                                                                                      |
| Native macOS behavior and real hardware                                              | `N`            | `N`                    | `N`                | `N`                    | `N`        | Windows host; native contracts read from primary source, but no target Mac execution/profile.                                                                                                                                                                              |

### Pass chronology

1. **Input/G5 pass 1:** found navigation, terminal delivery, keylogger persistence, and repeat duplication.
2. **Input/G5 pass 2:** mutation/producer ledger found Unicode delete units.
3. **Input/G5 pass 3:** no new candidate — domain dry.
4. **LLM/async pass 1:** found manager-side effects, shared semantic clients, pull ownership, pause continuations, stale health, and silent callback sites.
5. **LLM/async passes 2 and 3:** complete async inventory then independent test/recent-fix refutation; no new candidate — domain dry.
6. **Lifecycle pass 1:** found touch watcher start/stop ownership.
7. **Lifecycle pass 2:** found shortcut, updater, VS Code, screenshot, WPM, and callback sibling gaps.
8. **Remaining-domain pass:** found onboarding continuation, gesture search lifecycle, and root Karabiner fail-fast defects. A sibling rescan found no fourth candidate, but late domains have only one clean pass and are reported as debt rather than “proven dry.”
9. **Launcher/guardian (`BLINDER`) pass:** one complete protocol/ownership pass plus a targeted recheck of the latest ACK/HUP fix found no reachable defect. It is audited-clean, not claimed two-pass dry, and native execution remains non-covered.

### Explicitly suspected, not findings

- `infra/file_watchers.lua` publishes a composite owner early and does not robustly consume every native pathwatcher start refusal. The Lua transaction is weak, and current success-only tests are not sufficient, but this pass could not establish a deterministic user-reachable refusal for a valid watched path. It remains suspected.
- `LeaseOuterStateMachine.requestMode()` can immediately publish `PAUSED`/`RESUMED` when its transported mode already matches, without acquiring the live-transport gate used for a private send. A same-poll HUP could therefore race that direct wire-level ACK. The stock Lua controller at `platform/remap/lease_controller.lua:1177-1194` settles already-paused/active requests locally and never sends that idempotent command, so no user-reachable reproduction was established. Keep a native test that injects public idempotent mode plus private HUP in one poll batch; do not promote this unless a caller appears.
- Synchronous `hs.execute`/`os.execute` calls in MLX adoption, input-source helpers, onboarding helpers, and backend menu actions remain performance hypotheses without a target profile. Ollama readiness is separately promoted as `HS-025` because a stalled local listener gives an exact bounded blocking reproduction.
- The direct internal `set_active_profile()` API does not itself reset prediction identity. All stock user entry points found have a stronger quarantine/reset backstop, so that prediction-generation claim was not promoted. This is distinct from `HS-028`, which concerns the user-reachable menu action publishing profile state/runtime before durable commit.
- `modules/keymap/terminator_replay.lua:224-225` checks the protected-call status of `SyntheticInput.seal()` but not its exact `true` result. Re-derivation found that `emit_pending()` creates a fresh private transaction and no stock `with_transaction`/`TextSender` path can pre-seal or expose it, so `seal()==false` is not currently user-reachable. Keep an exact-return hardening test; do not promote it without a reachable producer.
- [x] The focused selector formerly failed to recognize an exact test-file path or dotted module name: `lua tests/run.lua --only tests/unit/adapters/test_synthetic_input_provenance.lua` fell back to all modules while retaining the path as a case filter. The dedicated runner fix now resolves normalized POSIX, Windows, absolute, and dotted-module targets to exactly one module and clears only the case-name filter for that form; historical case filters and unknown-target fail-closed behavior remain intact. Direct replays of every exact form loaded `1/831` (or `1/832` while the new test was untracked), and the selector suite passed `12/12`.
- Three older gesture lifecycle tests install `Actions.force_cleanup()` stubs that return `nil`, while the production exact contract now requires literal success. They can fail for fixture reasons and do not faithfully refute watcher lifecycle behavior; update those doubles rather than weakening the exact contract.

### Method and limitations

- Entry points inventoried: key/mouse eventtaps, script-control shortcuts, configurable hotkeys, gesture frames/actions, menu callbacks, LLM triggers/streaming completions, timers, tasks, HTTP callbacks, input-source/wake watchers, reload, quit, pause/resume, first launch, and Karabiner lifecycle.
- Every promoted candidate was checked against reachable state, exact lines, sibling callers, tests, and any absorbing backstop. Findings describe root causes rather than grep tokens.
- The full shim suite being green does not refute failure modes its doubles cannot represent. Conversely, no test was proposed for weakening/removal.
- No code fix was made in this audit. Proposed test filenames/assertions are deliverables for the corresponding fixes.
- The repo contains no implementation path or identifier named `BLINDER`; an exact search found the word only in the two audit prompts and unrelated French corpus prose. The macOS launcher/lease worker/guardian boundary was therefore treated as the likely intended separate protector. Its exact-lease, ACK/HUP, STOP/EOF, and termination gates were reviewed and their behavioral tests opened, but native process and ServiceManagement behavior must still be exercised on macOS.

## 7. Recommended fix order

1. `HS-003`, `HS-004`: finish the Terminal serializer's exact timer/drain/provenance ownership and remove the remaining keylogger eventtap work before another correctness change increases callback duration. `HS-025` is already implemented in the status register.
2. `HS-001`, `HS-007`, `HS-008`, `HS-010`, `HS-011`, `HS-024`: restore exact native/task ownership, terminal completion, and generation fencing.
3. `HS-002`, `HS-005`, `HS-006`, `HS-021`: repair text/tooltip correctness through shared transactions and codepoint units.
4. `HS-009`, `HS-012`: make semantic clients and pause an explicit owner registry.
5. `HS-013`–`HS-020`, `HS-022`, `HS-023`, `HS-026`–`HS-033`: make configuration/UI/file publication transactional, order profile/model intent, eliminate silent callback success, and keep every focused test-module shape replayable in isolation.
6. `PARITY-001`, `PARITY-002`: carry the strict UTF-8 fix through the Linux sibling and exercise the shipped default trigger end to end.

Each fix should land with the behavioral test described in its finding, run alone, in the full Lua suite, and—where native contracts are involved—in a macOS integration harness with faithful refusal and reordered-completion cases.
