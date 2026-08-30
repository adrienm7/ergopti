# Ergopti Plus Linux completeness and parity audit

## Audit record

- Audited commit: `f909766e46f8eb14e556033bd8c7f59940b87871`
- Audit date: 2026-08-30
- Scope: Linux runtime, Linux packaging and release path, Linux verification, and behavioral parity against the already-operational Windows and macOS drivers
- Audit type: read-only adversarial audit; no production fix was implemented
- Machine-readable findings: `docs/audits/linux/2026_08_30/findings.json`
- Local branch state at audit start: `dev` was 458 commits ahead of `origin/dev` and the working tree was clean
- Remote evidence: no remote-tracking ref contained the audited commit, so no remote CI run proves this exact SHA

The repository audit workflow currently validates only `ahk` and `hammerspoon` scopes. It rejects a Linux scope. This report therefore follows the same evidence contract manually and records that tooling gap as an action item; it does not pretend that the unsupported validator ran successfully.

## Executive decision

Linux is **not release-ready and not behaviorally at parity**. It is much further along than the old Linux TODO and README imply, but source presence and green local tests overstate its readiness:

- Of 25 canonical features, Windows has 24 production runtime paths plus one intentional omission, macOS has 25 production runtime paths, and Linux has **19 production runtime paths, 5 test-only features, and 1 absent feature**.
- Several of the 19 Linux runtime paths are only partial or broken in live use. In particular, core text capture/injection, Ollama, self-update, action assignment, shortcut enablement, selection transforms, and package onboarding cannot currently be accepted as functional.
- The assembled Linux release bundle removes all 15 shared WebView applications. UI openers in its tarball, deb, rpm, AppImage, Flatpak, and PKGBUILD consumers therefore resolve to an error page even where the checkout has a source-level runtime path; the Nix flake and source checkout use a different copy path (LNX-054).
- The audit confirms **65 actionable findings**: 8 critical, 42 high, 14 medium, and 1 low. These are reproducible defects or truthful-parity/governance failures, not estimates of hypothetical future bugs.
- The local Linux unit suite reports 1,976/1,976 passing and the pseudo-E2E suite reports 43/43. However, the unit runner can pass with zero selected tests, the pseudo-E2E runner can pass without its corpus and ignores the exact backspace oracle, and mandatory-looking CI subjects can be skipped while the aggregate job remains green.
- Linux has never been qualified on a real Linux desktop in this project. No local result in this audit proves physical evdev/uinput behavior, a visible tray or WebKit window, real X11/Wayland focus semantics, touchpads, fresh-user permissions, systemd user lifecycle, suspend/resume, or a release upgrade.

The correct strategy is not a rewrite. The shared engine, generated assets, manifest sources, and a substantial Linux implementation already exist. The shortest safe path is to repair truthfulness and the input transaction first, then make LLM/update/package operations non-blocking and atomic, then connect the dormant UI and action surfaces, and finally perform real-hardware qualification.

## Method and guarantees

Each confirmed finding records an exact execution or source-level reproduction, the root cause, why the current system can remain silently green, the proposed repair boundary, and a regression proof that would fail on the audited code.

The guarantees used below are:

- **G1 — Robustness:** no stuck input state, unsafe lifecycle transition, or unrecoverable partial update.
- **G2 — No missing output:** user input, expansion output, configuration, or requested operation is not silently lost.
- **G3 — No races:** event ordering, hotplug, cancellation, reload, and persistence remain coherent.
- **G4 — No lag:** the grabbed keyboard path and UI event loop never wait on blocking external work.
- **G5 — Truthful preview/state:** menus, counters, previews, logs, and green tests reflect what is actually applied.

Three independent passes covered runtime/input, parity/UI, and verification/package surfaces. A final refutation pass re-opened the highest-risk claims. Claims that still require physical Linux hardware are listed as unconfirmed risks, not promoted to findings.

## Reproduced baseline

| Check | Result at audited SHA | What it proves | What it does not prove |
|---|---:|---|---|
| `npm run test:linux` under `/usr/bin/lua5.4` | 150 modules, 1,976 passed, 0 failed | Broad Lua behavior under the available interpreter | LuaJIT/FFI, hardware, and non-empty selection integrity |
| `npm run test:linux:e2e` | 34 corpus vectors, 43/43 passed | Current model-based corpus agrees with its permissive runner | Exact Linux backspace behavior or corpus presence |
| `npm run build:linux` | exit 0; 46 required files, 488 total files | Bundle construction completes | Installed operation; the green bundle omits every shared WebView app directory (LNX-054) |
| `npm run test:luajit-52-isms` | pass across 314 files | No forbidden Lua 5.2+ constructs found | Runtime FFI/ABI correctness |
| `npm run test:menu-parity` | 19 menus; 103 Windows rows; 149 labels in 21 locales; 0 unexplained hidden rows | Shared menu declarations are internally consistent | Linux callbacks and effects work |
| `npm run test:linux-package-layout` | pass for four packagers and service root | Static paths share the expected boot root | Fresh-user permissions, service startup, GUI, or input |
| `npm run test:adapter-reachability` | Linux 19 adapters, none unreferenced | Every adapter has at least one reference | Production callers or semantic correctness |
| `npm run test:find-false-greens` | current baseline 0 tautologies / 0 pcall-only patterns | The narrow detector's patterns are clean | Runner-level false greens described below |
| `npm run test:tree-parity` | 28/51 directories shared; 19/25 canonical features present in all three trees | Structural convergence | Behavioral parity |
| `npm run test:manifest-parity` | 523/523 | Windows/macOS manifest projection parity | Linux; the command does not compare Linux |
| `lua5.4 tests/run.lua --only __NO_SUCH_TEST_CASE__` | 0 modules, 0 tests, exit 0 | Reproduces LNX-037 | Nothing was tested |
| Full `npm run test:js` | 14/199 failed in this checkout | The local JS environment is incomplete | This is not attributed to Linux code: 20 npm dependencies and `build/static_bundle.zip` were absent, plus an unrelated Windows structural failure |

The historical ledger that claimed 29 tautologies and 219 pcall-only tests is stale at this SHA. It is explicitly rejected rather than repeated as a current result.

## Canonical feature parity matrix

`runtime-proven` below means that a production caller and an application path exist in source. It does **not** mean real Linux hardware was exercised.

| Canonical feature | Windows | macOS | Linux | Linux disposition |
|---|---|---|---|---|
| `action_picker` | runtime-proven | runtime-proven | **test-only** | No production opener; bridge imports a nonexistent Linux module and silently returns an empty catalogue (LNX-031) |
| `apps` | runtime-proven | runtime-proven | runtime-proven, unsafe | App tracking runs, but the metrics page trusts remote scripts with native metrics capabilities and polls while hidden; per-app configuration opens only generic configuration (LNX-035, LNX-057, LNX-058) |
| `changelog` | runtime-proven | runtime-proven | runtime-proven, broken | Its CSP blocks Linux-inlined scripts, and its page/bridge actions, response channel, and release schema disagree (LNX-055, LNX-056) |
| `diagnostics` | runtime-proven | runtime-proven | runtime-proven | Crash reporter is owned by the daemon |
| `download_window` | intentional omission | runtime-proven | **test-only** | No opener and incompatible JS/host messages (LNX-032) |
| `dynamic_hotstrings` | runtime-proven | runtime-proven | runtime-proven, broken | Trigger, privacy, reload, counter, and UTF-8 alias defects (LNX-005 to LNX-010, LNX-059) |
| `gestures` | runtime-proven | runtime-proven | runtime-proven, broken/unqualified | Enabling after boot does not start the reader, and failed binding persistence publishes memory-only state; no physical trace (LNX-007, LNX-043) |
| `healthcheck` | runtime-proven | runtime-proven | runtime-proven, broken | Production caller exists, but the page never requests or receives its Linux snapshot and renders empty (LNX-053) |
| `hotstring_editor` | runtime-proven | runtime-proven | runtime-proven, unsafe | Production caller exists, but its focus flag never inhibits the global engine, so active triggers can expand inside the editor (LNX-050) |
| `hotstrings` | runtime-proven | runtime-proven | runtime-proven, unsafe | Core capture/injection findings LNX-001 to LNX-004, lifecycle findings LNX-012 to LNX-019, stale standalone packs (LNX-061), clipboard loss on read failure (LNX-062), and non-atomic Kanata configuration writes (LNX-063) |
| `hotstrings_config_window` | runtime-proven | runtime-proven | runtime-proven, broken | Production callers exist, but priority has no collision effect and is not serialized; the page's Close button is disconnected (LNX-047, LNX-052) |
| `layout` | runtime-proven | runtime-proven | runtime-proven, unqualified | Apply path exists; real XKB capture does not follow the active layout (LNX-003) |
| `llm` | runtime-proven | runtime-proven | runtime-proven, broken | Local Ollama URL/transport is unusable and safety-critical; the custom numeric prompt opens without its host-supplied label, value, or bounds (LNX-021 to LNX-024, LNX-051) |
| `menu` | runtime-proven | runtime-proven | runtime-proven | Builder runs; shared-manifest migration remains later cleanup |
| `keylogger` | runtime-proven | runtime-proven | runtime-proven, unsafe | Physical modifier/lock events are omitted; secure-field failures and same-window control changes are fail-open; ordinary characters also enter DEBUG logs in plaintext (LNX-017, LNX-020, LNX-045, LNX-060) |
| `model_browser` | runtime-proven | runtime-proven | **test-only** | No opener; frontend/bridge contract mismatch (LNX-032) |
| `onboarding` | runtime-proven | runtime-proven | runtime-proven, broken | A production opener exists, but the shared page and Linux bridge implement disjoint protocols, so completion is neither applied nor persisted (LNX-049) |
| `paths` | runtime-proven | runtime-proven | runtime-proven, editor test-only | Path infrastructure is used; the shared editor has no caller and an incompatible bridge (LNX-032) |
| `personal_info_editor` | runtime-proven | runtime-proven | **test-only** | No opener; calls nonexistent methods and can claim success (LNX-032) |
| `prompt_editor` | runtime-proven | runtime-proven | **test-only** | No opener; payload schema is incompatible and save writes the wrong field (LNX-032) |
| `shortcuts` | runtime-proven | runtime-proven | runtime-proven, partial | Master toggle neither gates configured slots nor persists; selection transforms are X11-only (LNX-033, LNX-034) |
| `spotlight` | runtime-proven | runtime-proven | **absent** | Action remains declared `platform="all"` (LNX-036) |
| `tooltip` | runtime-proven | runtime-proven | runtime-proven, partial | Hotstring preview has a caller; AI preview renderer is declared but not called |
| `updater` | runtime-proven | runtime-proven | runtime-proven, unsafe | Asset selection, staging, exit status, integrity, and blocking defects (LNX-025 to LNX-027) |
| `wpm` | runtime-proven | runtime-proven | runtime-proven, unsafe | Runtime restore/flush paths exist, but metrics WebViews trust remote scripts with native data capabilities and poll while hidden (LNX-057, LNX-058) |

Exact canonical totals:

- Windows: 24 runtime-proven, 1 intentional omission.
- macOS: 25 runtime-proven.
- Linux: 19 runtime-proven, 5 test-only, 1 absent.

## Confirmed findings

### Critical findings

#### LNX-001 — Non-consuming terminators are deleted by an expansion

- **Evidence/reproduction:** `static/ergopti_plus/linux/ergopti_hotstrings.lua:594-598` passes `is_terminator` as `terminator_consumed`. The shared engine at `_shared/lua/hotstring_engine/init.lua:625-671` consequently requests deletion of the terminator even though `_shared/lua/keymap/terminators_catalogue.lua:15-43` declares Space and punctuation with `consume=false`. `teh -> the`, non-auto, followed by Space yields four backspaces and inserts only `the`, producing `the` instead of `the `.
- **Why silent:** the injector receives neither the terminator identity nor a replay policy.
- **Repair:** make the match result carry the exact terminator and canonical consume policy; erase and replay as one transaction.
- **Regression proof:** full hook-to-uinput assertions for Space, comma, period, Enter, Tab, and a custom consuming terminator, including exact final text.

#### LNX-003 — Captured text does not follow the active XKB state

- **Evidence/reproduction:** `ergopti_hotstrings.lua:265-268` recognizes only the literal override `azerty`; `modules/hotstrings/input_reader.lua:147-151` otherwise resolves the static QWERTY table. The standard service supplies no layout override. Under XKB `fr`, physical keycode 30 produces `q` on the desktop while the engine records `a`. CapsLock is discarded, AltGr is absent, and two Shift keys collapse into one boolean in `adapters/keyboard_hook.lua:98-107,186-200,237-238`.
- **Why silent:** the fallback is treated as a valid normal layout while only Ergopti's internal buffer diverges.
- **Repair:** resolve evdev events against the live XKB keymap/state, including keycode sets, groups, locks, AltGr, dead keys, and hot changes; reject unknown explicit overrides.
- **Regression proof:** an XKB oracle for `us`, `fr`, CapsLock, AltGr, dual Shift, compose/dead keys, multi-group, and group changes.

#### LNX-004 — Pass-through and injection are not failure-atomic while the keyboard is grabbed

- **Evidence/reproduction:** `adapters/uinput_writer.lua:409-428` can return `false`; `adapters/keyboard_hook.lua:220-225`, the injector emission loops, and `ergopti_hotstrings.lua:663-693` ignore false returns and still advance callbacks, undo, metrics, and engine state. A fake uinput backend returning false drains the physical event without delivery. Separately, `injector.lua:410-444` maps a generic `shift` to LeftShift and restores modifiers only on its success tail; RightShift or an exception after modifier-up can leave a synthetic key stuck or a real modifier released.
- **Why silent:** `false` does not trip `pcall`, logs report completion, and logical state commits without an observed output commit.
- **Repair:** introduce one owned input transaction with checked EV_KEY/SYN results, exact pressed keycodes, unconditional cleanup, and an emergency stop/ungrab on pass-through failure. Commit undo/metrics/keylogger state only after output commit.
- **Regression proof:** fail every individual EV_KEY/SYN step; assert immediate ungrab, balanced exact modifiers, no false undo/metrics, and no swallowed physical key.

#### LNX-021 — Ollama endpoint composition is invalid

- **Evidence/reproduction:** `infra/llm_bridge.lua:69-77` returns a base already ending in `/api/chat`; `modules/llm/profiles.lua:115-135` appends `/api/tags`, while `modules/llm/api_ollama.lua:160-198` appends `/api/chat`. Live calls become `/api/chat/api/tags` and `/api/chat/api/chat`.
- **Why silent:** unit tests pin the already-suffixed base or mock `popen` without asserting the final command.
- **Repair:** store only the validated origin/base API and centralize typed endpoint builders.
- **Regression proof:** profile-to-prediction integration test asserting the exact tags and chat URLs against a local fake server.

#### LNX-022 — Synchronous LLM transport freezes the grabbed keyboard loop

- **Evidence/reproduction:** `api_ollama.lua:211-246` runs `io.popen` and drains curl synchronously. The prediction engine invokes it from the keystroke path (`prediction_engine.lua:309-397`; daemon `:756-796`). A slow or unreachable Ollama blocks pumping while EVIOCGRAB is active; Escape/Backspace cancellation cannot execute.
- **Why silent:** mocked fast subprocesses make the callback-shaped API look asynchronous; cancellation is only state, not process termination.
- **Repair:** use a single event-loop-owned asynchronous transport, bounded timeouts, request epochs, process-group termination, and exactly one terminal callback.
- **Regression proof:** slow/hung server while physical events continue to pass through; cancellation kills the request and a stale completion cannot update preview/state.

#### LNX-025 — The updater requests the wrong asset and may select an arbitrary release file

- **Evidence/reproduction:** `modules/updater/manager.lua:120-121` expects `ergopti_linux.tar.gz`; `.github/workflows/ci.yml:2404-2411,2489-2496` publishes `ergopti-plus-linux.tar.gz`. The fallback at manager `:399-406` selects the first `browser_download_url`, potentially a zip, deb, rpm, or AppImage.
- **Why silent:** download size is treated as sufficient evidence of a valid update artifact.
- **Repair:** generate one release artifact manifest used by CI and updater; require the exact platform/architecture/package kind and reject ambiguity.
- **Regression proof:** shuffled release assets with near-matching names must select exactly the declared tarball or fail closed.

#### LNX-026 — Self-update stages inside the directory it moves and replaces the wrong tree level

- **Evidence/reproduction:** the release tar contains top-level `linux/`, `_shared/`, `bin/`, `install.sh`, and `kanata.kbd`. `install_dir` is constructed as `.../linux/modules/updater/../..` without normalization, so appending `.old` produces a destination such as `.../linux/modules/...old`, inside the source tree. The generated first command is equivalent to `mv './modules/updater/../..' './modules/updater/../...old'` and must fail because it moves a tree into itself. Staging is also inside that tree. On standard LuaJIT, zero and nonzero numeric `os.execute` results are both truthy, so the checks can still report success. Even after path normalization, replacing only `linux/` with the whole bundle would yield nested `linux/linux` and stale `_shared`.
- **Why silent:** no post-install wrapper smoke or version/layout verification is required before the success state.
- **Repair:** choose an installation-type-aware updater; stage beside the complete install root, validate a signed manifest and layout, atomically swap the correct root, smoke the wrapper, then remove backup. Delegate or disable self-update for package-manager and read-only image installs.
- **Regression proof:** upgrade an actual N release fixture to N+1, verify Linux and `_shared` versions plus wrapper boot, then inject failure at each phase and prove rollback.

#### LNX-045 — Secure-field state is stale when focus moves within one window

- **Evidence/reproduction:** focus a normal username field, then use Tab or click to focus `PASSWORD_TEXT` without changing application ID or window title and type a password. `adapters/process_lifecycle.lua:93-103,213-222` publishes `onFocusChange` only when app ID/title changes; the secure detector is refreshed only at boot and from that callback (`ergopti_hotstrings.lua:1477-1528`). A production-path probe reports zero focus notifications for the same-window field change and one only after a title change. The cached `secure=false` therefore survives. With shipped defaults (`metrics enabled=true`, secure filter true, encryption false), `modules/keylogger/keylogger.lua:308-313,481-521,1330-1356` accepts the characters and flushes exact text/events to `metrics.sqlite`. LLM filtering reads the same stale cache and could submit the context if a prediction triggers.
- **Why silent:** top-level app/window identity is unchanged, so no refresh or diagnostic occurs; the field detector itself did not fail and consumers see a valid-looking false.
- **Repair:** subscribe to AT-SPI accessible focus/state changes and bind secure/insecure/unknown to a monotonically increasing focus epoch. Tab, click, focus navigation, and uncertain transitions must immediately invalidate to unknown/fail-closed; only a fresh verdict for that epoch may re-enable capture. Purge/refuse pending events and cancel/reject stale LLM work.
- **Regression proof:** in one unchanged app/title, transition TEXT → PASSWORD_TEXT by Tab and by click, then back. Before any fresh secure verdict, assert zero pending/plaintext SQLite/log data and zero LLM request; re-enable ordinary capture only after a fresh insecure verdict.

### High findings

#### LNX-002 — Enter and Tab never reach the hotstring matcher as terminators

- **Evidence:** `adapters/keyboard_hook.lua:274-277` routes them only as controls; daemon `on_control` at `:843-892` resets the engine. The catalogue declares both as default terminators.
- **Repair/test:** emit a domain-level textual terminator before the reset and test hook → daemon → engine → exact replay for Enter and Tab.

#### LNX-005 — Dynamic hotstrings fire after any following character

- **Evidence:** `dynamic_hotstrings/manager.lua:345-369` substitutes the current character for `trigger` and only checks that the buffer ends with it; it never verifies equality with the configured magic key. `tdx` can fire the `td` date rule.
- **Repair/test:** require `trigger == _trigger_char` before matching; assert `tdx/x` false and `td★/★` true.

#### LNX-006 — Personal dynamic output reaches the injector without privacy metadata

- **Evidence:** manager `:382-385` calls `inject(backspaces, result)` and computes privacy only for the later event at `:400-411`; injector success/failure logs redact only when the third argument is true.
- **Repair/test:** derive and require privacy at the injection boundary; logger-spy both success and failure and prohibit the personal payload anywhere.

#### LNX-007 — Enabling gestures after boot does not start the reader

- **Evidence:** `gestures/manager.lua:665-680` toggles `_enabled`; only init with enabled true calls `start_reading` at `:1052-1065`. A false → enable probe reports enabled true, reading false.
- **Repair/test:** make enable a start transaction and publish enabled only after a successful open; test false-at-init → enable → event dispatch.

#### LNX-008 — Magic-key configuration accepts unsafe keys and does not migrate static mappings

- **Evidence:** `magic_key.lua:22-25,46-54,113-130` uses a short blacklist and accepts ordinary `e`; repeat fallback can then alter normal words. When the key changes, daemon `:1358-1364` reloads, but `hotstrings/loader.lua:192-230` copies literal triggers; 940 of 2,121 loaded mappings still end in `★`.
- **Repair/test:** share an allow-policy for safe non-word codepoints and substitute the canonical configured key while staging every magic-key-owned mapping. Test all letters/digits rejected and a custom safe symbol applied after reload/restart with no old trigger left.

#### LNX-010 — A non-committed TOML parse can replace the last healthy configuration

- **Evidence:** shared `toml_codec/reader.lua:396-397,641-645` returns `data, committed`; Linux `hotstrings/loader.lua:151-155` captures only `pcall`'s `ok, data`. Partial/empty data with `committed=false` is installed.
- **Repair/test:** stage each source, require committed true, retain its last valid snapshot, and atomically swap only a fully valid aggregate. Inject read, semantic, and close failures and assert the prior mapping set remains active.

#### LNX-011 — Persistence operations and callers can report success without a durable commit

- **Evidence/reproduction:** `adapters/storage.lua:83-102` can return false and does not check every mkdir/write/close/rename result; `set`, `delete`, and `clear` ignore it and return true. With `XDG_CONFIG_HOME=/dev/null`, set reports true and reads from memory in-process, but the value is missing after module reload. Even after repairing the adapter, several production consumers currently discard its result and publish success/state anyway: dynamic-rule toggles, shortcut assignments, hotstring group state, magic-key reset, updater preferences, LLM settings, keylogger/WPM preferences, and one hotstring-editor save path.
- **Repair/test:** stage cache changes, check every I/O result, atomically rename, publish only after commit, preserve corrupt stores for explicit recovery, and make every mutating caller propagate the exact result before changing visible state. Cover unwritable path, short write, close, rename, corrupt JSON, all caller families, and restart.

#### LNX-012 — An explicit `--device` selection is silently replaced by auto-detection

- **Evidence:** `keyboard_hook.lua:445-475,523-558` stores no pinned-device policy; after eight watchdog ticks it selects the current auto-detected best device.
- **Repair/test:** distinguish pinned and automatic ownership; a pinned watchdog only reacquires that path. Fake `event7` pinned and `event3` preferred, including disconnect/reconnect.

#### LNX-013 — Only one keyboard and one pointer are observed

- **Evidence:** `device_finder.lua:251-326` returns scalar selections and the hook owns one slot for each. On a laptop plus USB keyboard without a working consolidated Kanata output, one device bypasses hotstrings and keylogger silently. A healthy Kanata aggregate can mitigate this case, so the defect is conditional rather than universal.
- **Repair/test:** either observe/grab every eligible device with identity-aware state, or explicitly require and health-check one remap output. Test simultaneous two-keyboard and multi-pointer fixtures plus hotplug.

#### LNX-014 — Pointer and keyboard queues can reverse real event order

- **Evidence:** `keyboard_hook.lua:340-363` drains the keyboard queue completely before the pointer queue. A click at T followed by a key at T+1 may dispatch key first, allowing a stale buffer to erase text at the new caret.
- **Repair/test:** poll and merge all input sources by kernel timestamp with deterministic tie-breaking; test click T before key T+1 and the inverse.

#### LNX-015 — Fatal evdev reads are indistinguishable from temporary EAGAIN

- **Evidence:** `evdev_reader.lua:198-203,382-388` maps every negative/short/exception read to nil while `is_open` only checks stored fd. Reconnection at the same `eventN` can leave the watchdog believing a dead descriptor is healthy.
- **Repair/test:** return `event | would_block | fatal` with errno/revents, teardown on fatal, and reacquire even at the same path. Simulate ENODEV/HUP and same-name reconnection.

#### LNX-042 — Keyboard capture ignores `SYN_DROPPED` and never resynchronizes

- **Evidence/reproduction:** `adapters/keyboard_hook.lua:228` discards all `EV_SYN`, and the keyboard path has no `EVIOCGKEY` resynchronization. Feed `SYN_DROPPED`, a lost Shift release, `SYN_REPORT`, then a normal key: the hook continues from its stale modifier/buffer state. Linux input semantics require clients to ignore events until the next `SYN_REPORT` and query current device state after `SYN_DROPPED`. The gesture decoder already owns an equivalent recovery path; the keyboard does not.
- **Why silent:** overflow looks like an ordinary ignored synchronization event. The blocking LLM path increases the chance of queue overrun while the device is grabbed.
- **Repair/test:** make reader/hook expose synchronization loss, suspend interpretation until `SYN_REPORT`, rebuild exact key/lock state with `EVIOCG*`, invalidate text candidates, and fail-safe if resynchronization fails. Use a synthetic overflow with a lost modifier release and an integration stress case.

#### LNX-043 — Gesture assignments commit in memory even when TOML persistence fails

- **Evidence/reproduction:** production initializes gestures with `persist=true` (`ergopti_hotstrings.lua:1376-1379`). `gestures/manager.lua:692-704,743-748,773-792` mutates `_actions`/parameters first and ignores `_persist_updates`; `batch_write` failure is only logged. `set_action_parameter` returns true, while set/reset/disable log success and the menu rebuilds from memory. Inject a writer returning false: the new binding appears until restart, then disappears.
- **Why silent:** the current in-memory state and rebuilt menu match the user's choice, hiding the failed durable transaction.
- **Repair/test:** stage a copy of bindings/parameters, require an exact successful atomic batch write, then publish; return and propagate false from set/reset/disable and keep prior state on failure. Fault open/write/close/rename for one binding, parameter, reset-all, disable-all, and restart.

#### LNX-046 — Shutdown waits on external `luv` handles whose owners stop too late

- **Evidence/reproduction:** `modules/updater/manager.lua:446-498,796-816` arms one-shot/repeating background checks and exposes `stop_background_checks` at `:428-438`, while `infra/file_watchers.lua:297-336,432-448` creates referenced `fs_event` handles closed by its owner at `:564-583`. `ergopti_hotstrings.lua:1594-1620` calls those owner stops only after `event_loop.run` returns. The loop stop at `infra/event_loop.lua:293-307` closes only loop-owned handles and then waits in `luv.run`; therefore it can wait for external handles whose cleanup cannot execute until after that wait. A production-module fake-luv probe leaves an updater handle active after loop stop and reaches zero only after the updater owner is stopped; normal watchable installations add the independent `fs_event` path.
- **Why silent:** unit coverage forces the no-luv fallback, while tray Quit does ungrab the keyboard, making the UI appear partly stopped even though clean-exit/flush/destroy is never reached. SIGTERM performs its first cleanup but can hang until systemd escalates to SIGKILL.
- **Repair/test:** centralize a shutdown transaction and stop/cancel/close updater, file-watcher, and every other module-owned handle before waiting for the event loop; assert a complete handle registry, zero active/referenced handles, and idempotent cleanup. With real and fake luv, armed updater timers, and active `fs_event` watchers, tray Quit and SIGTERM must make `run` return and reach clean exit exactly once.

#### LNX-047 — Hotstring priority has no collision effect and is never serialized

- **Evidence/reproduction:** the shared page sends `set_priority` (`_shared/ui/hotstrings_config_window/script.js:201-227`); the production bridge forwards it (`linux/ui/hotstrings_config_window/bridge.lua:422-434`), and `hotstrings_config.set_override` changes only its in-memory override table, save attempt, resolve cache, and menu callback (`modules/hotstrings/hotstrings_config.lua:386-411`). `save_overrides` at `:267-299` and `load_overrides` at `:215-250` omit priority. More fundamentally, `load_all` at `:681-757` loads priorities directly from TOML/source tiers without applying user overrides, then removes exact duplicate triggers before the engine can perform its priority sort. The shipped corpus probe found 2,994 mappings and eight duplicate entries across eight triggers, all therefore decided by input order. Set the losing category to priority 42: the UI/getter shows 42, the collision winner does not change live or after reload, and restart restores the old displayed value.
- **Why silent:** bridge/getter tests observe the live override table and pass; menu refresh looks like application. No current test crosses collision resolution, serialized TOML, reload, and a fresh module instance.
- **Repair/test:** define one override schema consumed by UI validation, writer, reader, loader, and resolver; persist priority atomically and apply its cascade before collision arbitration. Remove the pre-engine first-wins dedup or make dedup itself priority-aware. Prove WebView priority change → immediate expected winner → reload → restart for each collision tier, plus clear semantics and the eight shipped collisions.

#### LNX-048 — The installer creates two independent startup owners

- **Evidence/reproduction:** `linux/install.sh:624-629` enables and restarts the systemd user service, then `:647-662` unconditionally writes `~/.config/autostart/ergopti-hotstrings.desktop`; both launch the same daemon command from `linux/systemd/ergopti-hotstrings.service:33-39`. The desktop entry has no condition that disables it when systemd owns startup. The official [XDG Autostart specification](https://zbrown.pages.freedesktop.org/xdg-specs/autostart-spec/latest/ar01s02.html) requires eligible desktop files in the autostart directories to launch after login. In such a desktop session, two daemons race for `EVIOCGRAB`; `ergopti_hotstrings.lua:1050-1072` makes the loser exit 1, and `Restart=on-failure` can retry it every three seconds.
- **Why silent:** both installer setup steps report success, and whichever process wins the grab can make typing appear functional while the second owner loops or the systemd-tracked PID is not the device owner.
- **Repair/test:** choose exactly one startup owner. Prefer the systemd user unit when a working user bus is available, otherwise install the XDG fallback; migration must remove or explicitly disable the alternate owner. A single-instance guard is defense in depth, not a substitute. In real and simulated graphical sessions, prove one PID, one device open/grab, stable systemd state, no restart loop, and a non-systemd fallback.

#### LNX-018 — Kanata can be reported started after immediate failure

- **Evidence:** `platform/remap/manager.lua:468-525` accepts the PID printed by a background shell; it does not wait for process stability, a ready signal, or the expected output device.
- **Repair/test:** bounded readiness requires owned process alive plus output device/config readiness; retain stderr. A process exiting code 1 before readiness must return false.

#### LNX-019 — Optional module and pump failures are swallowed

- **Evidence:** daemon startup loads many subsystems through `pcall(require)` without surfacing the error; periodic/idle pumps for input, tray, gestures, and lifecycle discard protected-call errors. A missing enabled module can disappear, while a keyboard pump failure can leave grab active.
- **Repair/test:** classify required versus optional capabilities; required load failure aborts safely, optional failure becomes a visible health state, and keyboard pump failure immediately tears down/ungrabs. Inject load and pump exceptions with traceback assertions.

#### LNX-020 — Secure-field probe failures are interpreted as a safe non-password field

- **Evidence:** `adapters/secure_field_detector.lua:80-117,130-140` returns nil for no D-Bus, failed command, and parse failure, then sets secure false. The keylogger receives false. The API cannot distinguish ordinary field from detector failure.
- **Repair/test:** expose secure/insecure/unknown; fail closed for privacy, with only a bounded explicit stale state. Test missing bus, spawn failure, malformed response, timeout, and genuine password/non-password roles.

#### LNX-023 — LLM text delivery hides failure and erases UTF-8 by byte count

- **Evidence:** `adapters/text_sender.lua:49-121` ignores the `shell_run` boolean and invokes its completion callback without any failure result or log; downstream prediction state/metrics therefore cannot distinguish delivery. The callback is contractually completion, not success—the defect is the missing error channel and later commit. The adapter invokes ydotool/xdotool even though the daemon already owns uinput and the installer does not guarantee ydotool. `prediction_engine.lua:368-370,408-410` uses Lua byte length, so `é` requests two character deletions.
- **Repair/test:** route through the owned transactional injector, propagate a real delivery result, and use the same codepoint/grapheme deletion contract as the hotstring engine. Test missing tools, command failure, `é`, combining text, and emoji.

#### LNX-027 — Updater transport is blocking and accepts unauthenticated content

- **Evidence:** metadata GET is blocking but does append and inspect an HTTP code; the archive download is the defective boundary: it omits `--fail`, ignores `pipe:close()`, and can accept a stale/HTML file over the size threshold. Transfer/extraction has no digest/signature or complete manifest validation. The Timer fallback can silently drop scheduled checks when `luv` is absent.
- **Repair/test:** one asynchronous bounded HTTP/process transport, strict status handling, signed or trusted SHA-256 manifest, path-safe extraction, cancellable request ownership, and an explicit unavailable capability if no scheduler exists. Test slow server, 404 HTML body, timeout, cancellation, traversal, wrong hash, and missing event loop.

#### LNX-028 — Standalone Kanata installation uses obsolete and cross-OS assets

- **Evidence/reproduction:** `linux/install.sh:400-405` maps x86_64 to the obsolete raw asset name `kanata` and `aarch64|arm64` to `kanata_macos_arm64`; `:427-454` downloads from mutable `releases/latest`, converts download failure into optional success, and validates only whether `file` contains “executable”. On the audit date, both exact installer URLs resolve to release v1.12.0 and return HTTP 404. A previously existing Mach-O ARM asset would pass the generic executable check and later fail under Linux. The standalone CI path runs with no dependency/service setup and never checks Kanata, so the 404 remains green.
- **Upstream check (2026-08-30):** the current [Kanata release page](https://github.com/jtroo/kanata/releases) publishes a Linux x64 archive under a new name and no Linux ARM64 release bundle, while the referenced ARM name is explicitly macOS. Until Ergopti owns and verifies a Linux ARM build, ARM must be an explicit unsupported state, never a macOS fallback.
- **Repair/test:** consume a pinned, checksummed Kanata artifact manifest; for x86 extract the current Linux archive and verify ELF architecture plus `kanata --version`. For ARM, build and own a verified Linux artifact, use a distribution package, or fail explicitly. Fixture-test 200 archive, 404, Mach-O, wrong-architecture ELF, checksum failure, and mutation of the asset name; installed x86/ARM smoke must prove remap service readiness or an explicit unsupported result.

#### LNX-029 — Distro dependency mapping and package smoke tests can green without required capabilities

- **Evidence:** `install.sh` reuses positional apt/dnf/pacman package columns for apk/zypper/xbps; Alpine can request the wrong package for `xkbcli`. The distro CI matrix runs as root with `--no-deps`. PKGBUILD and Nix outputs are not built in CI; AppImage is built/tested only on Ubuntu and inherits host ABI. The published PKGBUILD still has `pkgver=__VERSION__`, clones `branch=dev`, and uses `SKIP` checksums, while its layout gate verifies only payload/LUA_PATH rather than a reproducible Arch package.
- **Distribution check (2026-08-30):** Alpine publishes the executable in its current [`xkbcli` package](https://pkgs.alpinelinux.org/package/edge/main/x86_64/xkbcli); the installer must map that name explicitly rather than reuse another manager's column.
- **Repair/test:** manager-specific dependency tables plus postcondition probes; install on fresh containers/VMs without `--no-deps`; build PKGBUILD and Nix on x86_64/aarch64; test AppImage on an old supported glibc host and an explicit unsupported-musl case.

#### LNX-030 — Packages claim service readiness while suppressing enablement and permission failures

- **Evidence:** deb/rpm scripts run `systemctl --user ... || true` through another user and then print that the service is enabled. Deb/rpm/AppImage/Flatpak smokes mostly run `--help` or inspect layout; they do not install/verify udev rules, groups, modules, `/dev/input`, `/dev/uinput`, or a real user session. Release guidance still asks users to extract a separate tarball for permissions.
- **Repair/test:** one package-owned permissions/setup component and blocking healthcheck; use a correct global/user enablement policy or tell the user the exact remaining step. Install as a fresh normal user, relogin/reboot, start the service, capture and inject a key, and open tray/WebKit.

#### LNX-031 — The Linux action picker is unreachable and its catalogue is incomplete

- **Evidence:** no production `webview.show("action_picker")` caller exists. `ui/action_picker/bridge.lua:59-85` imports nonexistent Linux `modules.gestures.actions` and silently emits no items. Shared `actions.toml` has 79 `platform="all"` IDs including the chord placeholder; Linux exposes 42 names, misses 39 user actions, and adds `ws_prev`, `ws_next`, and `app_window_previous`. `open_paths_editor` opens hotstrings configuration.
- **Repair/test:** generate Linux catalogue, labels, aliases, and executor projection from `actions.toml`; connect production assignment callers and the real paths editor. Enforce a bijection gate and E2E select → persist → restart → trigger for every supported action class.

#### LNX-032 — Six shared WebViews are dormant and use incompatible host protocols

- **Evidence:** no production opener exists for download window, model browser, personal-info editor, prompt editor, or token prompt; paths infrastructure runs but its editor is dormant. Their bridges disagree with the shipped JavaScript on message type and payload fields: download string vs table commands, model `select_model{name}` vs `select{model}`, paths `configDir` vs key/value, personal `save{values}` vs nonexistent field methods, prompt edit epoch/name/prompt vs a `save_prompt{title}` handler that writes title into prompt, and token page `open_link`/`cancel`/`{type=validate,token}` vs bridge `ready`/`refresh`/`close`/settings actions. Some paths reply success without a writer or implemented effect.
- **Repair/test:** define one versioned shared message schema, implement real storage/module operations, propagate failures, and add openers. Replay each page's actual JS messages and prove open → initialize → modify → save → restart → read/apply; prohibit success without observed commit.

#### LNX-049 — Production onboarding page and Linux bridge use disjoint protocols

- **Evidence/reproduction:** the daemon has a real onboarding opener at `ergopti_hotstrings.lua:1237-1240`. The shipped shared page posts `action=ready`, `previewLocale`, `localeSelected`, `loadExistingConfig`, `pickConfigDir`, and finally `action=finish` with answers (`_shared/ui/onboarding/script.js:161-172,506-535,592-620`). `ui/onboarding/bridge.lua:139-165` ignores `action` and routes only an invented `payload.step` vocabulary (`init`, `layout`, `language`, `llm_setup`, `complete`). Replaying the real `ready` and `finish` messages returns nil: no host initialization is sent, answers are not applied or persisted, and `onboarding_done` is not written. Existing bridge tests at `tests/unit/meta/test_ui_bridge_handlers.lua:554-583` and `tests/unit/meta/test_bridge_persistence.lua:115-124` exercise only the invented `step` protocol.
- **Why silent:** registration and the production opener make the feature inventory look runtime-complete, while tests agree with the bridge rather than with the actual page.
- **Repair/test:** define and version one shared page/host contract; `ready` must deliver initialization and localized strings, and `finish` must validate and transactionally commit every answer before closing. Add a DOM-to-real-bridge E2E covering ready → choices → finish → fresh restart/application, plus a mutation gate requiring every page action to have exactly one handler and every success response to have an observed durable effect.

#### LNX-050 — Hotstring editor focus never inhibits the global expansion engine

- **Evidence/reproduction:** the shared editor emits `window_focus` (`_shared/ui/hotstring_editor/script.js:1442-1455`), and `linux/ui/hotstring_editor/bridge.lua:526-533` stores `state.editor_focused`. A repository-wide search finds no production reader of that flag. The global character path at `ergopti_hotstrings.lua:539-598,660-693` still sends every physical character to `engine:on_char` and injects a match. Open the editor and type an already-active trigger into its trigger or replacement field: the global hotstring can replace the form text itself.
- **Why silent:** the bridge unit test asserts only that the boolean changes; it never types through the production hook while the real page is focused.
- **Repair/test:** create a central, epoch-bound capture gate for owned WebViews. On editor focus, reset candidates and pass physical input through literally without expansion, LLM, preview, or metrics; clear the gate on blur, hide, destroy, and crash. With the real page focused, type an existing trigger and require literal text plus zero injection/LLM/metric activity; after blur require exactly one ordinary expansion, and prove forced close cannot leave capture disabled.

#### LNX-053 — Production healthcheck opens an empty page

- **Evidence/reproduction:** the production menu calls `webview_manager.show("healthcheck")` (`ergopti_hotstrings.lua:1230-1234`). The page contains only `<div id="content">` and a passive renderer, `window.renderHealthcheck(snapshot)` (`_shared/ui/healthcheck/index.html:7-11`, `script.js:54-264`); it never creates a host bridge, posts `ready`/`refresh`, or defines `window.__hostBridgeResponse`. The Linux bridge waits for `ready` or `refresh` before building a snapshot (`linux/ui/healthcheck/bridge.lua:393-407`), and the manager can return that snapshot only through the absent callback. Opening Tray → Debug → Diagnostic therefore leaves `#content` empty. Even if connected, the renderer recognizes only AHK and Hammerspoon system shapes, not the Linux `sys.os/arch/display_server` shape.
- **Why silent:** `show()` succeeds, bridge tests call the handler directly, and host tests prove only that HTML/scripts were assembled; no test asserts the rendered production DOM.
- **Repair/test:** define one versioned diagnostic request/response contract. The real page must request initial/refresh snapshots, decode the Linux response, call `renderHealthcheck`, render Linux-specific system fields, and show transport/validation errors rather than blank content. In a real WebKit page opened through production, assert version/adapters/Linux fields in the DOM, a changed snapshot after refresh, and mutation failure when either request or response wiring is removed.

#### LNX-054 — The Linux release bundle and six derived formats remove every WebView application

- **Evidence/reproduction:** `tools/build/build-linux-driver.sh:102-114` copies `_shared` with `--exclude 'ui/*'`, then restores only `host_bridge.js`, `i18n.js`, `dom_utils.js`, and `apps.manifest.json`; its required-file list at `:167-217` requires no application `index.html`. After the green build, `rg --files build/linux/_shared/ui` returns exactly those four files and none of the 15 application directories. `ui/webkit_host.lua:116-130,276-287` converts a missing app into non-empty `<h1>Error: app '…' not found</h1>` HTML, so `webview_manager.show` registers it and returns success. The release tarball, deb, rpm, AppImage, Flatpak, and PKGBUILD paths consume this truncated bundle. The Nix flake copies `static/ergopti_plus/_shared` directly and is not affected by this exact exclusion.
- **Why silent:** `npm run build:linux` and `test:linux-package-layout` pass because their manifests verify boot files/paths, not the transitive assets of production openers; source-checkout execution still sees all pages, and `show()` treats the generated error HTML as success.
- **Repair/test:** make the bundle include the complete required UI tree or generate an exact transitive closure from production openers, bridge registrations, HTML, and referenced assets. Missing application pages/assets must fail build and `show`, not become a successful error page. For each tar/deb/rpm/AppImage/Flatpak/PKGBUILD artifact, enumerate every production `show(app)`, require its index and referenced assets, and run a fresh WebKit DOM smoke; deletion mutation of any required page/asset must fail. Keep the separate Nix path under the same closure gate.

#### LNX-058 — Remote CDN code inherits privileged metrics and native bridge capabilities

- **Evidence/reproduction:** the two metrics pages load Chart.js and related JavaScript directly from jsDelivr, mostly without pinned versions and entirely without SRI or CSP (`_shared/ui/metrics_apps/index.html:6-8`, `metrics_typing/index.html:11-15`). `ui/webkit_host.lua:160-194` deliberately preserves remote scripts, while `ui/webview_manager.lua:539-567` registers every bridge handler in every WebView. Replace one CDN response with a controlled script: it can redefine `window.__hostBridgeResponse`, post `ready` or `export` to `metrics_apps_bridge`, receive application metrics/session data and n-gram payloads, invoke `reset`/`pause`/`edit`, and send results over the unrestricted network. Cross-application handlers are exposed as well, even where on-demand routing limits which absent page modules load.
- **Why silent:** successful HTTPS traffic looks like normal rendering, the tests treat global bridge registration as expected, and no gate checks remote origins, asset integrity, page-specific capability binding, or offline completeness. LNX-054 hides the page entirely in six bundle-derived formats, but the Nix and source-checkout paths remain exposed.
- **Repair/test:** vendor and verify all UI dependencies, enforce a CSP with no remote script/connect capability, register only the bridge owned by the current application, and bind routing to that page identity. Built pages must issue zero remote requests and render offline; a hostile fixture must be unable to read metric responses, invoke a foreign bridge, or mutate collection. Deleting a vendored dependency or widening the bridge allow-list must fail a security gate.

#### LNX-060 â€” Keystrokes are logged in plaintext despite at-rest encryption

- **Evidence/reproduction:** every accepted printable character reaches `modules/keylogger/metrics_collector.lua:160-186`, which calls `Logger.debug(LOG, "on_keydown('%s') ...", ch, ...)`; the production keylogger forwards it at `modules/keylogger/keylogger.lua:481-486`. The shared logger defaults to level 10, accepting DEBUG, then retains every accepted line in its 200-entry ring and sends it to its configured sink (`_shared/lua/logger/init.lua:15-18,210-226,305-307`). A collector fixture typing `S` emits `on_keydown('S')`; this happens before any SQLite at-rest encryption.
- **Why silent:** encryption protects selected persisted columns, not the logger's ring or sinks; DEBUG is documented as normal per-keystroke logging and current privacy tests assert only database/filter behavior.
- **Repair/test:** make raw character content structurally unloggable outside the capture boundary; log only non-sensitive aggregate/typed event classes. Add a logging privacy firewall and test ring, stdout/file/journal sinks in normal, private, secure, encrypted, and unencrypted modes. A sentinel character sequence must never occur in any log channel.

#### LNX-061 â€” Standalone upgrades freeze canonical hotstring packs at their first installed version

- **Evidence/reproduction:** `linux/install.sh:485-496` copies every bundled canonical TOML into `~/.config/ergopti/hotstrings` only when absent. At every later load, `modules/hotstrings/hotstrings_config.lua:639-668` adds bundled files first then assigns the same stem from the user directory into `by_stem[stem]`, so that first seed always replaces the newer bundle. Upgrade N to N+1 therefore never receives corrected, added, or removed canonical entries, with no version/hash/provenance to distinguish an untouched seed from a user edit.
- **Why silent:** the installer accurately says it preserved configuration, and both paths parse as valid; ordinary source and fresh-install tests never exercise a versioned N to N+1 canonical-pack transition.
- **Repair/test:** stop seeding complete canonical packs as user overrides, or write provenance and atomically migrate only known-intact seeds while preserving user modifications. Test N to N+1 with an intact pack receiving additions/corrections/removals, a modified pack remaining a deliberate override, and a fresh process resolving the expected source.

#### LNX-062 â€” Clipboard fallback destroys existing content after a read failure

- **Evidence/reproduction:** `adapters/shell_runner.lua:113-137` turns any command error into `""`; `adapters/clipboard.lua:135-140` therefore cannot distinguish a failed read from an empty clipboard. `paste_text` snapshots that empty value, writes the expansion, pastes it, then restores `""` at `:202-221` and reports success. With an initial logical clipboard `COPIED-SECRET`, injected failure of `xclip -o`, and successful writes/uinput, the reproduction returns true and leaves the clipboard empty.
- **Why silent:** fakes model only a readable text clipboard and test adapter conformance covers the happy path; all injection events succeed, so the existing output transaction reports success.
- **Repair/test:** make clipboard reads typed `(ok, value, error)` results, and refuse to replace, paste, or restore when the snapshot is unavailable. Test a genuinely empty clipboard separately from a failed X11/Wayland read; on failure require zero writes/paste events, preserved original content, and false propagated to the injector transaction.

#### LNX-063 â€” Kanata configuration writes can destroy the last good file yet report success

- **Evidence/reproduction:** `platform/remap/manager.lua:440` opens the final `ergopti.kbd` with `"w"`, truncating it before a commit exists. Its `fh:write(kbd)` and `fh:close()` results are ignored at `:445-446`, then `write_kbd` logs success and returns true at `:448-449`. An injected file with `write → nil, "disk full"` and `close → nil, "I/O error"` produced `WRITE_KBD_RESULT=true`; restart then passes its success guard, stops Kanata, and attempts startup with the empty/partial file.
- **Why silent:** meta tests wrap their assertions in `if ok` and `if fh`, so a real failure path is skipped; an I/O failure becomes apparent only on restart or next boot.
- **Repair/test:** write a validated temporary sibling, check open/short write/flush/close/rename, atomically replace only after a full commit, and never stop Kanata before that commit. Fault every stage and require false, byte-identical prior config, no stop/start, and no success log; verify exact content on the happy path.

#### LNX-064 â€” Kanata stop failure is reported as success and loses process ownership

- **Evidence/reproduction:** `platform/remap/manager.lua:542-544` ignores `kill` failure, logs `Kanata stopped`, and clears `_kanata_pid` without checking whether the owned process exited. A fake owned PID 4242 for which `kill 4242` fails but `kill -0` remains true makes `restart` return true and log restart while the old process lives, ownership is lost, and no valid relaunch occurs.
- **Why silent:** tests cover no-process/double-stop and foreign-process protection, but not a failed stop of a PID owned by this manager.
- **Repair/test:** give stop a result contract, retain ownership until bounded liveness confirmation, and make restart stop on failure. Simulate a failed TERM and a stubborn process: require false, retained PID, no stopped/restarted success log, and no new launch; cover normal delayed termination separately.

#### LNX-065 â€” A recycled Kanata PID can terminate an unrelated user process

- **Evidence/reproduction:** `platform/remap/manager.lua:578-582` treats a bare PID as owned whenever `kill -0` succeeds; it stores neither executable nor process creation identity. After owned Kanata PID 4242 exits and Linux reassigns 4242 to a fake editor, `is_running` treats that editor as Kanata and `stop` signals it at `:542`. The injected probe kills the unrelated process and logs `Kanata stopped`.
- **Why silent:** foreign-instance tests begin without an owned PID and no lifecycle test kills the child then recycles its PID before `is_running`, stop, or restart.
- **Repair/test:** own a process handle/pidfd and observe its exit; fallback identity must compare `/proc` start time and executable immediately before signaling and fail closed on mismatch. Test PID reuse: no ownership, no signal, survivor intact, no stopped log, and inactive Kanata state.

#### LNX-033 — The shortcuts master toggle neither gates configured shortcuts nor persists

- **Evidence:** daemon initialization forces disabled; manager state is memory-only. Menu toggle affects the CapsWord check, but configured slots still dispatch through `keyboard_shortcuts.lua` regardless of the master state.
- **Repair/test:** one persisted authority gates every shortcut action before dispatch and only changes after durable save. Off must block slots, CapsWord, and associated actions across restart.

#### LNX-034 — Selection transformations are X11-only and fail silently on Wayland

- **Evidence:** `modules/shortcuts/manager.lua:160-198,263-353` shells to xclip/xdotool, ignores important failures, and uses byte-oriented Lua case conversion. A Wayland user can invoke the action and receive no trustworthy result.
- **Repair/test:** display-server capability adapters for selection, clipboard, and owned injection; Unicode-aware transforms; disable with an explicit localized reason where unsupported. Test X11, GNOME/KDE/wlroots Wayland, missing tools, non-ASCII, and terminal paste semantics.

#### LNX-037 — The Linux unit runner succeeds when it executes no tests

- **Evidence/reproduction:** `static/ergopti_plus/linux/tests/run.lua:90-186` has no discovery/test floors and does not make an unmatched filter fatal. `--only __NO_SUCH_TEST_CASE__` prints 0 modules, 0 passed, 0 failed and exits 0; a missing discovery dependency can produce the same result.
- **Repair/test:** require expected module/test floors (or a checked manifest), fail an unmatched explicit filter, and check discovery process/module close status. Meta-test the runner itself under empty directory, missing dependency, bad filter, and partial discovery.

#### LNX-038 — The pseudo-E2E suite can pass without its corpus and ignores exact backspace expectations

- **Evidence/reproduction:** `tests/run_e2e.lua:111-130` warns when the corpus is absent and proceeds with built-ins; `:238-273` converts `expected.backspace_count` to a permissive boolean and accepts codepoint count or +1. Removing the corpus still yields 9/9; changing expected backspaces to 999 still yields 43/43.
- **Repair/test:** corpus absence is fatal, impose vector/category floors, use an exact platform oracle, and mutation-test every expected field so each mutation makes the suite fail.

#### LNX-039 — Mandatory-looking CI subjects can be skipped while the aggregate stays green

- **Evidence:** Wayland and WebKit jobs exit 0 when required status/socket/page conditions are absent; the aggregate `linux-ok` accepts `skipped` dependencies and checks only failure/cancelled. The LuaJIT distro job also contains successful skip paths.
- **Repair/test:** a checked Linux coverage manifest labels mandatory versus optional subjects; mandatory jobs must conclude `success` with an artifact proving executed assertions, and the aggregate rejects skipped/missing mandatory subjects. Test the aggregator with every result state.

### Medium findings

#### LNX-009 — Dynamic-rule counters grow on each initialization

- **Evidence:** `dynamic_hotstrings/manager.lua:132-184` resets engine rules but not `_rules_count`; repeated init produces 3 then 6 while only 3 rules exist.
- **Repair/test:** stage and reset the count before registration; publish only after success and assert idempotent init/reload.

#### LNX-016 — Trigger timeout checks only the last inter-key interval

- **Evidence:** daemon `on_char` at `:611-624` evaluates delay only after a match and compares the current event only with `_last_key_ms`. In `abcd`, a one-second pause after `a` followed by fast `bcd` can still match a 750 ms policy.
- **Repair/test:** maintain aligned buffer timestamps or invalidate the buffer on any excessive interval; test pauses at every trigger position and reset boundaries.

#### LNX-017 — Physical modifier and CapsLock events do not reach keylogger metrics

- **Evidence:** `keyboard_hook.lua:235-272` returns from modifier/lock handling before `_on_physical`, contradicting the daemon's all-physical-events contract.
- **Repair/test:** publish the physical event once before text interpretation; assert down/up for Shift/Ctrl/Alt/Meta/CapsLock without producing characters.

#### LNX-024 — LLM setting ownership is inconsistent

- **Evidence:** `prediction_engine.enable/disable` persist, but `toggle` changes memory only; the menu calls toggle. URL filtering defaults to true in the manifest and false in shared defaults/Linux bridge.
- **Repair/test:** make toggle delegate to the canonical persisted setter and select one generated default source. Test menu toggle across restart and cross-driver default projection.

#### LNX-035 — “Per-application configuration” opens generic configuration

- **Evidence:** the Linux menu row is declared in `menu_manifest.json:454-486`; `menu_builder.lua:2472-2488` opens the generic hotstrings config without an application or profile context.
- **Repair/test:** either implement app identity → profile storage → live application and restart tests for two apps, or rename/remove the promise until supported.

#### LNX-036 — Spotlight is absent despite an all-platform action declaration

- **Evidence:** Windows and macOS have production implementations; Linux has none while `actions.toml:732-751` declares the action for all platforms.
- **Repair/test:** implement a compositor-safe Linux overlay and caller with multi-monitor/scale tests, or make the omission explicit and justified in the canonical platform declaration.

#### LNX-040 — Linux parity status is not governed by the current gates

- **Evidence:** the generated Linux feature manifest marks 126 entries supported and 198 unavailable; 194 unavailable entries have an empty reason key. `test:manifest-parity` compares only AutoHotkey and Hammerspoon. Registration/presence is not distinguished from production caller, persistence, application, or hardware proof. Test fakes are checked real→fake only, allowing extra fake APIs.
- **Repair/test:** generate a Linux capability projection with status, reason, owner, caller, persistence, application, and proof tier; include it in parity gates. Enforce bidirectional fake equivalence or a named test-only namespace.

#### LNX-041 — Status documentation, localization, and skip ownership obscure Linux reality

- **Evidence:** `todo_linux.md` and Linux READMEs still claim missing notifier, gestures, hotkeys, crypto, and LLM even though callers now exist; elsewhere the same TODO admits later delivery. Four conformance skip entries point to a nonexistent “Lot5 Linux parity” owner. Several Linux user-facing labels/errors are hardcoded French instead of using the shared localization source.
- **Repair/test:** replace stale claims with links to this audit and feature-state generation, make every skip reference an existing finding/issue with expiry, route user strings through i18n, and add doc-path/locale completeness gates.

#### LNX-044 — Tooltip category resolution fails open

- **Evidence/reproduction:** `ui/tooltip/preview.lua:207-215` returns true when configuration is absent, throws, or returns a non-table. Inject a resolver failure for a category whose stored policy is `show_tooltip=false`; `M.show` continues to `Renderer.show` instead of withholding the bubble.
- **Why silent:** the exception is swallowed and the permissive default is indistinguishable from an enabled category. Personal values remain separately masked, so this is a preference/truthfulness defect rather than an unmasked-secret claim.
- **Repair/test:** keep the last committed category policy or fail closed for display when resolution fails, surface a health diagnostic, and test missing resolver, thrown resolver, malformed result, explicit false, and recovery.

#### LNX-051 — Numeric prompt ignores host initialization and close responses

- **Evidence/reproduction:** production menu callers use `Prompt.ask` (`linux/ui/menu/menu_builder.lua:1344-1362`). The page posts `ready` and expects its title, current value, and bounds through `receive_prompt` (`_shared/ui/numeric_prompt/script.js:40-68,99-100`), but it never defines `window.__hostBridgeResponse`; `linux/ui/webview_manager.lua:420-441` sends every bridge return only through that callback. The page therefore opens blank. Save can still reach the current Lua callback if the user guesses a value, and Cancel clears `_pending`, but their returned success/closed states are also ignored, so the window stays visible. Closing with the GTK X only hides it, and `webview_manager.show` at `:189-193` reuses it without another `ready`, leaving the next request stale and unlabeled.
- **Why silent:** tests call `Prompt.on_message("ready")` directly and assert the returned Lua table; they never prove that the shipped page receives or renders that table, nor that a completed prompt closes.
- **Repair/test:** use one explicit request/response contract: install a response handler that calls `receive_prompt`, attach a request epoch, deliver fresh data on every show, and close/hide only after acknowledged save/cancel. Run the real page through temperature and context-length prompts in sequence, asserting title/value/bounds, one correct setter, visible close, stale-response rejection, and reopen behavior.

#### LNX-055 — Changelog CSP blocks the scripts inlined by the Linux host

- **Evidence/reproduction:** the changelog declares `script-src 'self'` before its local script tags (`_shared/ui/changelog/index.html:6-14,46`). `ui/webkit_host.lua:177-218,235-250,276-296` replaces those same-origin tags with inline script bodies and injects additional bootstrap scripts without a nonce/hash. Loading the production-built HTML with the production `file:///` base leaves `makeHostBridge`, `_initializePage`, and `openOnGitHub` undefined because the CSP blocks the inlined application scripts.
- **Why silent:** HTML/CSS and the window still appear, CSP violations do not flow through `window.onerror`, and the WebKit page-error harness covers only the configuration and hotstring editor pages.
- **Repair/test:** preserve executable assets as same-origin resources or generate and apply exact nonces/hashes to every injected script, including bootstrap code; do not relax the policy with blanket `unsafe-inline`. Load every production-built page in WebKitGTK and assert initialization functions, the ready signal, working controls, and zero CSP violations.

#### LNX-056 — Changelog page and Linux bridge implement three incompatible protocols

- **Evidence/reproduction:** after bypassing the CSP defect, replay the page's real `{action="fetch",channel="dev"}` and `{action="open_url",url=…}` messages (`_shared/ui/changelog/script.js:188-217,416-424`): `ui/changelog/bridge.lua:50-78` handles only string `ready/refresh/close` and table `open_release`, so both return nil. The `ready` result is sent through `window.__hostBridgeResponse`, which the page does not define, and the bridge returns `tag/notes` while the page consumes `tag_name/body/html_url`.
- **Why silent:** after the CSP is repaired, an 800 ms direct GitHub fetch can mask the native fetch failure online; the GitHub button remains inert, offline cached data is unreachable, and unknown actions produce only a debug log.
- **Repair/test:** define one versioned action, response-channel, and release-record schema; implement exact `fetch/open_url` behavior with a validated repository URL and surfaced opener/network failures. Exercise the real DOM through ready → native cached data offline → channel change → release open, plus rejected URLs and failure states.

#### LNX-057 — Hidden metrics WebViews continue polling the keylogger

- **Evidence/reproduction:** both metrics pages arm an unconditional two-second `setInterval` that requests native data (`_shared/ui/metrics_apps/index.html:1219-1235`, `metrics_typing/index.html:1359-1379`). The GTK `delete-event` at `ui/webview_manager.lua:600-615` only hides the window and retains its WebView/JavaScript context. Instrument `keylogger.get_dashboard_payload`, close a dashboard with the title-bar X, and pump for more than four seconds: native payload reads and rendering work continue while `is_visible=false`; reopening reuses the same context.
- **Why silent:** the visible window disappears normally, and pure-Lua tests never pump a real hidden WebKit page. This is ongoing SQLite/aggregation/rendering work, not evidence of third-party disclosure or direct data loss, so it is medium severity.
- **Repair/test:** either destroy the page on close or define a visibility lifecycle that cancels and re-arms exactly one poller. Assert zero native reads while hidden, exactly one interval after every reopen, and complete timer/WebView teardown on destroy and daemon shutdown.

#### LNX-059 — Personal non-ASCII aliases cannot be registered or resolved

- **Evidence/reproduction:** `modules/dynamic_hotstrings/manager.lua:171` accepts a `[letters]` key only when Lua byte length `#letter == 1`, so a valid one-codepoint alias such as `é` is silently skipped. The combo fallback at `:217-229` iterates `1..#tag` and slices one byte at a time; `_fire_combo` at `:315` also derives deletion count from byte length. A Lua 5.4 fixture with `é = "first_name"` produced four rules instead of five, a two-byte/one-codepoint tag, zero resolved fields, `FIRED=false`, and no injector call, even though `trailing_tag` explicitly preserves accented aliases.
- **Why silent:** invalidated keys are neither rejected nor logged; the three date rules keep the module enabled and its summary healthy. Existing concrete alias tests use only ASCII `p/n` and do not assert Unicode combo deletion.
- **Repair/test:** validate alias keys with the module's strict codepoint-length helper, iterate tags by decoded codepoint, and compute deletion in the injector's canonical codepoint metric; explicitly validate the NFC policy instead of silently normalizing. Test NFC `é`, mixed combo `né`, exact preview/field order/injection/backspaces, malformed UTF-8 rejection, and a mutation that restores byte iteration.

### Low findings

#### LNX-052 — Hotstrings settings Close button has no window owner

- **Evidence/reproduction:** the page sends `{action="close"}` from its visible Close button (`_shared/ui/hotstrings_config_window/script.js:63-65`). The bridge calls `state.close_webview` only if supplied and uses the wrong identifier `hotstrings_config` (`linux/ui/hotstrings_config_window/bridge.lua:492-500`); daemon state at `ergopti_hotstrings.lua:1390-1397` supplies no close function, and the registered app is `hotstrings_config_window`. Clicking Close therefore does nothing, although the GTK title-bar X remains a workaround.
- **Why silent:** the handler returns nil after a success-looking log, and unit tests do not observe native window visibility.
- **Repair/test:** give bridges a single owned close capability keyed by their registered app identity, make the request return/propagate failure, and assert DOM click → one hide/destroy transition → `is_visible=false` → clean reopen. Add a manifest test that every page close action resolves to an existing app key.

## Cross-surface parity details

### Actions

- Shared source applicable to Linux: 94 declarations, comprising 79 single-action IDs (including the internal chord placeholder) and 15 axis declarations.
- Linux `ACTION_I18N_KEYS`: 42 rows. Of the 79 single-action declarations, Linux exposes 39 canonical IDs plus three noncanonical extras; this is a catalogue comparison, not proof that every missing label also lacks an executor.
- Linux misses 39 user actions: tab navigation, window cycling, paragraph navigation, selection moves, six screenshot actions, twelve `open_*` actions, four script actions, select line, mouse teleport/spotlight, and CapsLock toggle.
- Linux has three noncanonical aliases/IDs: `ws_prev`, `ws_next`, and `app_window_previous`.
- Generated Linux gesture emission already handles 36 combos, but the manager does not enumerate them. This is a source-of-truth/caller defect, not evidence that all actions are absent.

### Shared pages

There are 15 shared `index.html` pages in the source checkout. Eight have a proven Linux production opener: hotstrings configuration, healthcheck, onboarding, hotstring editor, typing metrics, application metrics, changelog, and numeric prompt. Healthcheck, onboarding, numeric prompt, and changelog have broken page/host contracts; the editor/configuration pages have the focus/close defects above. Metrics pages keep polling while hidden and load remote code into a native-capability context (LNX-057, LNX-058). The dormant/incompatible surfaces are action picker, download window, model browser, paths editor, personal-info editor, prompt editor, and token prompt. AI preview has a renderer but no prediction-engine caller. Registration in `webview_manager.lua` is lazy and is not a production-use proof. The current release bundle contains none of these 15 page directories, making all source-level UI dispositions worse in its six derived formats (LNX-054).

### Ports and manifests

- The current port inventory contains 21 ports: Windows 21, macOS 21, Linux 14, with all 14 Linux ports common and declared absences for the remainder.
- Tree parity reports 19/25 canonical feature directories across all drivers. This agrees with structural presence but not the behavioral matrix.
- The Linux generated feature manifest's 198 unavailable entries need classification. Many are OS-specific or internal and must not be blindly called bugs; the missing reasons are the governance defect.
- MLX remains an intentional macOS-only LLM backend. Linux parity should target supported behavior (profiles, prompts, model management, local/remote providers, cancellation, preview, secret handling), not identical backend technology.

## Action plan

The ordering is intentional. Later milestones must not build acceptance tests on runners that can pass without executing their subject, and no UI/parity work should be released on top of a keyboard transaction that can swallow input.

### M0 — Make evidence and status truthful

Dependencies: none. Exit criterion: a green Linux aggregate proves that every mandatory subject ran and that every canonical parity row has a machine-owned status.

- [ ] Fix LNX-037: checked module/test manifest or floors, fatal empty discovery and unmatched filters.
- [ ] Fix LNX-038: mandatory corpus, exact Linux oracle, category floors, and mutation tests for every expected field.
- [ ] Fix LNX-039: mandatory/optional coverage manifest; aggregate rejects skipped or missing mandatory jobs.
- [ ] Add LuaJIT as the authoritative Linux unit interpreter; retain Lua 5.4 only as a compatibility lane.
- [ ] Add Linux to manifest parity and encode `declared`, `registered`, `production caller`, `persisted`, `applied`, `hardware-proven`, and `intentional` separately (LNX-040).
- [ ] Remove remote executable UI dependencies and enforce page-specific native bridge capabilities before treating any WebView proof as trusted (LNX-058).
- [ ] Make fakes bidirectionally conformant or put helpers under an explicit test-only namespace.
- [ ] Link every conformance skip to an existing finding/issue and expiry; remove the nonexistent Lot5 owner.
- [ ] Add the Linux scope to the repository audit workflow and validator without weakening AHK/Hammerspoon validation.
- [ ] Record gate artifacts with audited SHA, interpreter, distro, session type, architecture, and executed assertion counts.

### M1 — Restore a fail-safe input transaction

Dependencies: M0 runner integrity. Exit criterion: under fault injection, no grabbed physical event disappears, no synthetic key remains held, and no logical state commits before output.

- [ ] Define one input transaction result shared by hook, engine, injector, undo, keylogger, metrics, and preview: staged → emitted → committed or failed → cleaned up.
- [ ] Fix non-consuming and control terminators (LNX-001, LNX-002) with exact final-text tests.
- [ ] Replace static capture with live XKB state and exact keycodes (LNX-003).
- [ ] Make clipboard snapshots typed and abort the fallback before any write or paste when reading fails (LNX-062).
- [ ] Commit generated Kanata configuration through a checked temporary file and atomic replacement before any restart (LNX-063).
- [ ] Retain Kanata process ownership until a bounded, checked stop succeeds; prevent restart on any stop failure (LNX-064).
- [ ] Bind Kanata ownership to a process handle or verified process identity so PID reuse can never signal another application (LNX-065).
- [ ] Check every uinput/key/SYN emission, restore exact modifiers in unconditional cleanup, and emergency-ungrab on pass-through failure (LNX-004).
- [ ] Classify module/pump errors and make keyboard pump failure fatal-safe (LNX-019).
- [ ] Implement evdev fatal/would-block distinction and same-path reacquisition (LNX-015).
- [ ] Handle `SYN_DROPPED`: pause interpretation, query exact device state, invalidate candidates, and fail-safe on resync failure (LNX-042).
- [ ] Add an explicit shutdown transaction that stops updater timers, file watchers, and all module-owned handles before waiting for the loop; prove zero referenced `luv` handles (LNX-046).
- [ ] Preserve a pinned device policy (LNX-012).
- [ ] Choose and implement multi-device ownership; merge keyboard/pointer events by timestamp (LNX-013, LNX-014).
- [ ] Add Kanata readiness instead of PID-only success (LNX-018).
- [ ] Fix full trigger-window timeout and physical modifier publication (LNX-016, LNX-017).
- [ ] Fault matrix: every emit step, SYN failure, throw after modifier release, ENODEV/HUP, hotplug, process death, daemon crash, and graceful shutdown.

### M2 — Make hotstrings, configuration, and privacy atomic

Dependencies: M1 transaction contract. Exit criterion: every accepted configuration is durable and applied, invalid reload retains the last good snapshot, and private data is absent from all logs.

- [ ] Guard the dynamic trigger character exactly (LNX-005).
- [ ] Make personal alias registration, combo resolution, and deletion codepoint-correct with an explicit normalization policy (LNX-059).
- [ ] Require privacy metadata before personal output reaches injection/logging (LNX-006).
- [ ] Remove raw characters from every logger pathway and prove a sentinel typed sequence reaches no ring or sink (LNX-060).
- [ ] Make gesture enable start/rollback transactional (LNX-007).
- [ ] Centralize safe magic-key validation and migrate all owned mappings on change (LNX-008).
- [ ] Reset/publish dynamic counts atomically (LNX-009).
- [ ] Honor TOML `committed`, stage per source, and retain last-known-good snapshots (LNX-010).
- [ ] Put priority in the canonical hotstring-override schema and prove WebView-to-fresh-reload collision behavior (LNX-047).
- [ ] Make storage write/close/rename and cache publication one durable transaction; expose corrupt-store recovery (LNX-011).
- [ ] Propagate durable-save results through every Storage and gesture-TOML mutator; publish bindings/preferences only after commit (LNX-011, LNX-043).
- [ ] Make secure-field state tri-valued and privacy fail-closed (LNX-020).
- [ ] Track accessible focus epochs inside a window; invalidate on Tab/click/navigation, prevent pending keylogger/LLM data, and prove same-window TEXT ↔ PASSWORD_TEXT transitions (LNX-045).
- [ ] Make tooltip category policy retain last-known-good state or fail closed on resolver failure (LNX-044).
- [ ] Test reload during typing, watcher bursts, failed disk writes, corrupt config, duplicate init, restart, and private expansion failure logs.

### M3 — Replace the blocking LLM path

Dependencies: M0 and M1. Exit criterion: local Ollama works with exact endpoints, slow/cancelled requests never block input, and text delivery is transactional and Unicode-correct.

- [ ] Canonicalize provider origins and endpoint builders (LNX-021).
- [ ] Introduce the owned asynchronous transport with timeout, cancellation, epoch/stale-result rejection, and process cleanup (LNX-022).
- [ ] Route delivery through the owned injector and shared deletion metric; propagate failure (LNX-023).
- [ ] Fix persisted toggle and URL-filter SSOT (LNX-024).
- [ ] Connect AI preview lifecycle only after cancellation semantics are proven.
- [ ] Define Linux LLM parity: profiles, prompts, display/navigation controls, model list/download/delete, local and remote providers, offline state, and error presentation.
- [ ] Add Secret Service/libsecret ownership before remote API keys; tests must prove no secret appears in logs, argv, persisted plain text, or WebView messages.
- [ ] Test local server success/streaming/malformed chunks, DNS/connect timeout, HTTP error, slow body, cancel/retry, Unicode, secure fields, and daemon shutdown.

### M4 — Rebuild update, install, and package proof

Dependencies: M0. Exit criterion: every supported install type starts for a fresh normal user and either upgrades atomically or explicitly delegates to its package manager.

- [ ] Generate and consume one exact release artifact manifest (LNX-025).
- [ ] Implement package-aware sibling staging, complete-root validation, atomic swap, wrapper smoke, and rollback (LNX-026).
- [ ] Add bounded async transfer, strict HTTP status, SHA-256/signature, extraction traversal protection, cancellation, and explicit scheduler capability (LNX-027).
- [ ] Pin the current Linux Kanata archive with checksum/ELF/version validation and explicitly support or reject Linux ARM64 (LNX-028).
- [ ] Replace positional dependency reuse with manager-specific tables and postcondition probes (LNX-029).
- [ ] Package udev/group/module/setup ownership and truthful service enablement (LNX-030).
- [ ] Select exactly one login-start owner, migrate away the alternate systemd/XDG entry, and prove one stable daemon PID (LNX-048).
- [ ] Generate and verify the transitive WebView asset closure in the release bundle and every derived format; missing pages must fail build and runtime open (LNX-054).
- [ ] Add canonical-pack provenance and an upgrade migration that updates intact seeds but preserves explicit user overrides (LNX-061).
- [ ] Run the updater against the actual CI tarball fixture, not a checkout-shaped archive.
- [ ] Deb matrix: fresh Debian stable and Ubuntu LTS, install/upgrade/remove/purge, normal-user service and input.
- [ ] RPM matrix: Fedora and a Rocky/RHEL-compatible host; test openSUSE separately rather than assuming rpm scripts are equivalent.
- [ ] AppImage: old supported glibc baseline, Fedora, explicit Alpine/musl negative behavior, read-only self-update policy.
- [ ] Flatpak: real host/session portal behavior and input permission design; do not accept bundle-only smoke.
- [ ] PKGBUILD: real `makepkg` with non-placeholder version and non-`SKIP` checksums.
- [ ] Nix: flake/package checks on x86_64 and aarch64.
- [ ] Release drill: clean install → login/reboot → use input/UI → upgrade N→N+1 → rollback injected failure → uninstall without orphaned privileged state.

### M5 — Connect dormant UI and complete action/shortcut parity

Dependencies: M0, M1, M2; model/download pages also depend on M3/M4. Exit criterion: each supported UI operation opens from production, persists a real effect, survives restart, and reports failure truthfully.

- [ ] Generate the Linux action catalogue/executor/labels/aliases from `actions.toml`; remove missing/extra drift (LNX-031).
- [ ] Add production assignment callers for gestures, shortcut slots, tap-hold/chords where supported.
- [ ] Fix `open_paths_editor` and prove every `open_*` action target.
- [ ] Version and align protocols for download, model, paths, personal-info, and prompt pages (LNX-032).
- [ ] Include token prompt in the shared protocol inventory or explicitly retire it until Linux owns the required provider/secret semantics (LNX-032).
- [ ] Align the production onboarding page and bridge on the real shared contract, with transactional completion and restart proof (LNX-049).
- [ ] Gate global input while owned editors are focused, with epoch-safe cleanup on every window lifecycle path (LNX-050).
- [ ] Deliver and acknowledge numeric-prompt requests on every show, including close/reopen and stale-response tests (LNX-051).
- [ ] Route every page Close action through one registered app-key owner (LNX-052).
- [ ] Wire the healthcheck's real request/response/render path and render Linux system fields and transport failures (LNX-053).
- [ ] Make the Linux CSP/asset strategy compatible without `unsafe-inline`, then align the changelog actions, response path, and release schema (LNX-055, LNX-056).
- [ ] Stop metrics polling whenever its WebView is hidden or destroyed and prove exactly one poller after reopen (LNX-057).
- [ ] Vendor verified dashboard dependencies, forbid remote script/connect origins, and register only each page's owned native bridge (LNX-058).
- [ ] Implement actual model download/cancel/retry/delete and personal/prompt/path persistence before exposing those pages.
- [ ] Make the shortcuts master state persistent and authoritative for all dispatch (LNX-033).
- [ ] Replace X11-only selection transformations with session adapters and explicit capability states (LNX-034).
- [ ] Implement real per-app profiles or remove/rename the menu promise (LNX-035).
- [ ] Implement Linux spotlight or canonically mark the asymmetry intentional (LNX-036).
- [ ] Route all hardcoded Linux user strings through shared i18n; require locale completeness.
- [ ] Only after behavior is stable, finish the Linux menu-builder migration to the shared menu manifest.

### M6 — Hardware and desktop qualification

Dependencies: M1 through M5. Exit criterion: the release evidence contains repeatable traces on every mandatory platform cell and zero unowned mandatory skip.

- [ ] Test x86_64 and aarch64 on supported distro/package cells.
- [ ] Test X11 and Wayland on GNOME, KDE, and one wlroots compositor; record display server, desktop, input stack, XKB layout, and package kind.
- [ ] Test ANSI and ISO keyboards, `us`/`fr`, CapsLock, AltGr, dead keys, compose, multiple groups, autorepeat, two simultaneous keyboards, hotplug, and Kanata handoff.
- [ ] Observe exact pre/post-Kanata events and uinput output with a capture oracle; prove no recursion and balanced key state.
- [ ] Test pointer/caret invalidation, clicks interleaved with typing, focus changes, secure fields, terminals, and clipboard MIME preservation.
- [ ] Capture real multitouch traces for 2/3/4/5 fingers, two device families, semi-MT limitations, palm rejection, and threshold boundaries.
- [ ] Test tray visibility/actions and WebKit pages on GNOME/KDE/wlroots, including focus, close/reopen, crash, localization, scale, multi-monitor, and accessibility.
- [ ] Test service start, relogin, reboot, lock, suspend/resume, device removal/reappearance, daemon crash/restart, and stale process cleanup.
- [ ] Run long-duration typing/gesture/LLM/updater stress while measuring input loss, stuck keys, event-loop stalls, CPU, memory, and descriptor/process leaks. Performance numbers require the separate profiling procedure and provenance.

### M7 — Parity acceptance and release gate

Dependencies: all prior milestones. Exit criterion: every canonical row is `runtime-proven + integration-proven`; every promised hardware-dependent row is also `hardware-proven`, or has an explicit canonical intentional reason.

- [ ] Re-run the 25-feature matrix transaction by transaction against Windows/macOS, comparing observable results rather than directory names.
- [ ] Require a production caller and persisted/applied proof for each exposed setting and action.
- [ ] Require exact UI message contract tests for all 15 shared pages, including unsupported-state behavior.
- [ ] Require a privacy sink gate proving no raw typed content appears in any log transport (LNX-060).
- [ ] Require updater/install/package release drills on the exact signed artifacts.
- [ ] Require zero critical/high open findings, zero mandatory skips, no empty reason for an unavailable exposed capability, and no stale audit skip.
- [ ] Update root/Linux docs from generated capability status and archive superseded TODO claims without losing durable information.
- [ ] Publish Linux only after the audited release commit is the same SHA proven by remote CI and the physical qualification record.

## Physical/package qualification matrix

| Surface | Current evidence | Required acceptance proof |
|---|---|---|
| Lua runtime | Local Lua 5.4; CI config includes LuaJIT | Actual LuaJIT/FFI unit and integration artifacts at release SHA |
| evdev/uinput | Source/unit plus CI virtual-kernel tests | Real keyboard capture/pass-through/injection, permission failure, emit failure, balanced keys |
| XKB | Static/codegen checks | `us`, `fr`, AltGr, CapsLock, compose/dead keys, multi-group and live switching |
| Multi-device/hotplug | No real proof | Two keyboards, pointer interleaving, same-path reconnect, suspend/resume |
| Touchpad | Decoder/unit and virtual traces | Physical 2–5 finger traces across at least two families and semi-MT characterization |
| X11 | Xvfb-style checks | Real desktop typing, selection, focus/caret, tray, WebKit, clipboard |
| Wayland | CI path can skip | Mandatory GNOME/KDE/wlroots proof with no X11 tool dependency |
| deb/rpm | Static layout and limited container install | Fresh normal user, deps, permissions, service, GUI/input, upgrade/remove |
| AppImage/Flatpak | Build/layout smoke | Real host execution and explicit privilege/update model |
| PKGBUILD/Nix | No CI build proof | Native package build/check on supported architectures |
| Updater | Unit/source path only | Exact release artifact N→N+1 plus injected rollback failures |
| Privacy | Mocked role/config paths | Secure fields across desktops, unavailable accessibility bus, no payload in logs |

## Unconfirmed risks requiring targeted reproduction

These are plausible from source inspection but remain outside the machine finding manifest until reproduced:

- Clipboard fallback always uses a generic paste chord and restores only text after a fixed delay; terminals, slow consumers, and non-text MIME may lose data.
- Kanata configuration writes may be non-atomic under disk-full/concurrent shutdown; fault-inject write and close.
- Focus-change fidelity on Wayland may permit cross-surface expansion; requires compositor-level tracing.
- Secure-field behavior depends on actual AT-SPI/Desktop portals and must be confirmed despite the definite fail-open adapter defect.

## Refuted or superseded claims

- Linux does use EVIOCGRAB in the normal path and opens uinput before grabbing.
- Output injection is not universally US-fixed; output uses a generated XKB keymap. The confirmed defect is capture-state resolution.
- The multitouch decoder handles `SYN_DROPPED`; the confirmed missing recovery is specific to keyboard capture (LNX-042).
- Normal device selection excludes generic virtual devices and prefers the expected remap output, so a self-uinput recursion claim was not confirmed.
- Kanata process ownership checks prevent an obvious duplicate-start/foreign-kill defect; readiness remains defective.
- `input_event` native size is computed for 32/64-bit ABI rather than hardcoded to 24 bytes.
- Notifier, gesture reader, shortcut support, crypto, and an LLM path are not absent as old docs claim. Their presence does not refute the live defects in this report.
- No evidence supports claiming “hundreds” or “thousands” of known Linux bugs. This audit reports 65 confirmed actionable findings and clearly labels the still-unqualified surface.
- No rewrite, size-based file split, separate X11/Wayland binaries, Espanso/ydotool core engine, or mass conversion of source-inspection tests is proposed.

## Completion definition

This audit is complete as a code/repository audit of the stated SHA after the independent runtime, parity, verification/package, and refutation passes produced no unclassified critical surface. It is **not** a certification of Linux behavior because the required physical and installed-package evidence does not exist. The action plan closes that distinction explicitly: Linux parity is achieved only when behavior is proven on the release artifact and supported desktops, not when another folder, menu row, or passing mock test appears.
