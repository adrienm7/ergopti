<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-11-05. Latest stable: [v1.0.8](https://github.com/adrienm7/ergopti/releases/tag/v1.0.8).
This file shrinks toward deletion after the next field reports: each machine section is one line per check, naming
the field-run step or the hand action that proves it and the commits it confirms. Conventions and tags:
[workflow and verification memory](docs/memory/workflow-and-verification.md). Finished items are in Git
(`git show 2a0083cb11:TODO.md` is the long form before this shrink).

## Parity audit pause and resumption

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
records the focused campaigns already completed, broader reviews, exact limits
and the next module candidates. The audit is paused at the maintainer's request.

- [ ] **[CODE] Parity audit continuation:** on resumption, reconcile current source areas with the linked coverage register, then deepen tap-holds/chords/layers as one bounded module across Windows/macOS/Linux/shared before moving to another. Keep native receiving and implementation of existing finding IDs separate; do not restart completed focused campaigns without source drift or a new hypothesis.

## Dead-key composition parity follow-up

[Focused audit](docs/audits/platform-parity/2026-11-05-dead-keys/report.md), pinned source `f2c3ea43542c985fb20e5f0887976f1c02525341`: five new roots, [generated comparison](docs/audits/platform-parity/2026-11-05-dead-keys/capabilities.md). Evidence boundaries remain explicit; these are follow-ups, not implemented fixes.

- [x] **[CODE] DKW-001 — Windows:** make pending registry composition respect disabled physical continuation rows. Reproduce original registered callback with global base enabled, top row disabled and installed US HKL; preserve neutral/enabled/Shift controls. Current proof is source routing plus original parsed data, not AHK execution.
  Done: `_KLE_OnKey` routes a switched-off row's continuation to native composition; regression drives the registered callbacks (plain, Shift, neutral and enabled-row controls). AHK not executed on the Linux authoring host.
- [x] **[CODE] DKM-001 — macOS:** make automatic suffix lookup scalar-aware for grouped two-ASCII payloads; compare grouped/split original callback paths with Unicode and longer-payload controls. Qualify native dead-state payload grouping separately.
  Already fixed on the base (scalar-aware two-byte branch in `modules/keymap/init.lua`, test `test_star_validation_beats_repeat_key.lua`); the audit probe now expands grouped `^0`. Added a grouped/split callback regression.
- [x] **[CODE] DKM-002 — macOS:** preserve the unmatched prefix exactly once when consuming a grouped payload for a shorter suffix; assert constructed event text and logical buffer agree, retaining split/full-trigger controls. Native application receiving remains unmeasured.
  Already fixed on the base (`expander.lua` dispatches the event prefix); the audit probe returns `´EXPANDED` matching the buffer. Added a returned-text/buffer agreement regression with the split control.
- [x] **[CODE] DKL-001 — Linux:** preserve the previously acknowledged Compose prefix when a later continuation is consumed; compare semantic capture against acknowledged raw plus emitted-output history. Keep first-consumed, refusal, repeat, ignored-modifier and stale-generation controls; qualify actual desktop receiving separately.
  Done: `XkbCapture.process` returns the press's Compose mark and the Hook restores it on consumption (`restore_compose`) instead of resetting; regressions cover consumed tap/completing key/repeats/first dead key, ignored Shift and a stale mark. Real desktop receiving still unqualified.
- [ ] **[CODE] DKS-001 — shared/Linux:** avoid inherited locale descendants shadowing an explicit shorter Compose terminal in both converters. Require actual native COMPOSED ₢ for Bépo monnaie+cedille; retain locale/no-include/private-trigger controls. Private-trigger probe is not a proposed production fix.
- [ ] **[CODE] Magic conversion:** decide and document the eight known Plus/PlusANSI pending-state Magic contexts at level 1 before claiming equivalent state-aware output; retain all six registry checks and native explicit-rule comparisons, without counting eight additional roots.
- [ ] **[CODE] Dead-key lifecycle:** define unmapped fallback, expiry/pause and modified-control replay contracts across legacy Windows, registry Windows, native macOS and Linux Compose. Extend existing OSW-001 conditional replay regression to legacy DeadKey; do not call modifier loss intentional. Qualify native cancelled-state policy, macOS grouped payloads, AHK/HKL and real Linux desktop receiving. Keep current per-engine behavior until a common contract is approved. Latency, RSS and long-session memory watchlist remain unmeasured.

## Cross-platform feature inventory

- [ ] **Dynamic hotstrings:** align or explicitly document the Windows `@td★` / `@dt★` / `@date★` date vocabulary versus bare Lua triggers and their boundary rules. Linux's shortest phone prefix must wait for the magic key, as Windows/macOS do; normalize the international phone output consistently (the Lua drivers currently keep the national zero after +33). Reproduce with the [module audit probe](docs/audits/platform-parity/2026-11-04/hotstrings.md).
- [ ] **Linux AI:** implement bounded retries for failed/empty predictions and refill after deduplication, with the shared retry token/temperature policy. Windows already has `retry_extra_tokens`; remove obsolete claims that it has no owner. See [AI evidence](docs/audits/platform-parity/2026-11-04/llm.md).
- [ ] **Linux metrics:** implement durable per-device append-only ledger export/import/replay for cross-device metrics; the current local metrics.sqlite has no Windows/macOS ledger synchronization. Do not advertise schema compatibility as synchronization.
- [ ] **Metrics:** expose collection availability and units: Linux lacks passive-period counts, CPU/RAM samples and a real space-change KPI; its sleep is sampled-gap estimation and its mouse distance is device units, not screen pixels, with no evdev tap-to-click count. Windows has heuristic desktop-switch raw events but no producer feeding the shared space-change KPI. Night-wake count currently has no producer on any OS. See [metrics evidence](docs/audits/platform-parity/2026-11-04/metrics.md).
- [ ] **macOS/Linux metrics:** evaluate Windows-only raw telemetry families: clipboard copy/paste bursts, Internet/VPN transitions, capture-process presence, detailed window topology and trigger ROI/manual-word/halflife events. These are raw collectors, not a claim that current dashboards display all of them.
- [ ] **macOS onboarding:** expose live number-row ordering with the same selected-layout availability as its working menu; the wizard currently excludes macOS. Document the typing-priority rollover alternative to Windows/Linux release-order tap-holds; do not promise identical hold semantics.
- [ ] **Windows/Linux diagnostics:** add the manifest-derived unavailable-features explanation already collected and rendered on macOS. Evaluate authenticated fallback metadata for feed-only update installation; retain current refusal without authenticated assets (macOS uses signed Sparkle metadata for newest-channel updates).
- [ ] **Backup scope:** classify the macOS native settings that truly need restoration and document filtered backups; owned programmable .ahk/.lua sources are excluded by the common TOML/JSON extension policy on all OS. Do not export caches or all native settings indiscriminately.
- [ ] **Layers:** evaluate repeat-count support on macOS/Linux (`parameters.repeat_count` currently Windows-only), and mouse-button layer sources on Linux (`source_kinds.mouse_button` excludes Linux because the observed button cannot be suppressed). Fn remains a macOS-specific modifier; layer Spotlight is a macOS-specific action. Source: `_shared/keymap/layer_actions.toml`.
- [ ] **Windows/macOS/Linux:** qualify physical shortcut delivery and its editor; Windows has no host, and both Lua production getters currently return false. Preserve the safety refusal until source/collision/output custody is qualified; see LIN-004 in the deep input audit. Windows token-by-token prediction display also remains unvalidated (`platform_reason.token_streaming_unvalidated_on_windows`).
- [ ] **macOS:** review the tap-hold word-reset option and automatic model-to-prompt-profile switching (`hotstrings.tap_hold_resets_word`, `llm.profiles.auto_profile_for_model`). Provide shortcut-only restore/clear if feasible; the configuration menu currently restores Karabiner settings together with other settings.
- [ ] **macOS and Linux:** evaluate automatic insertion of completed AI continuations; both currently show a bubble and insert on acceptance. The Windows inline mode is not token-by-token document streaming (`platform_reason.inline_autotype_is_windows`).
- [ ] **Windows and Linux:** evaluate incremental touchpad gesture modes and step sizes; macOS tracks finger movement while the other drivers handle discrete gestures (`platform_reason.gesture_modes_and_steps_are_macos`).
- [ ] **Windows:** implement the bulk copy of tap assignments into simultaneous-chord assignments where compatible; `key_combinations_group.copy_tap_to_combo` is declared for macOS and Linux only.
- [ ] **Linux:** review exposing keyboard-layout-only restore/clear. `keyboard_layout_scope` participates in global restore/clear, but the two `layout_menu` commands are hidden on Linux; re-check the menu's old assumption that Linux has no layout settings against the live number-row and pause-layout controls before choosing behavior.
- [ ] **Windows:** evaluate a notification-area WPM readout; the floating widget is the current alternative (`platform_reason.wpm_readout_needs_a_menubar`).
- [ ] **Linux:** correct stale platform-reason translations after checking all consumers and all locales: `platform_reason.llm_configuration_surface_is_not_on_linux` contradicts the Linux model/profile/generation providers, and `platform_reason.metrics_extras_are_not_on_linux` contradicts the exclusion handler. Avoid treating these stale strings as proof of missing functionality.
- [ ] **Linux:** add user management of wrap-symbol pairs (custom add/delete, enable/disable and bulk actions): the existing menu only invokes the shared fixed pairs. Inspect `linux/ui/menu/menu_shortcuts.lua` and the Windows/macOS wrap menu owners.
- [ ] **Linux Wayland:** investigate supported compositor interfaces for focused-application identity on GNOME, KDE, COSMIC and Weston; the current adapter cannot supply it there, limiting per-application rules. Preserve unknown/fail-closed behavior where no safe interface exists.
- [ ] **Linux:** investigate a safe copy-confirmation mechanism on Wayland and X11 without xclip; tap-hold copy currently sends the keys without the retry/confirmation used when a clipboard change counter is available.
- [ ] **Linux:** investigate `open_personal_shortcuts`: the action opens `personal_shortcuts.toml`, but the menu and loader describe keyboard slots stored in `config.toml`, and no production reader of that file was found. Route it to the actual owner or remove the misleading action after runtime verification.
- [ ] **Linux:** evaluate accented-key shortcut remapping on layouts where those keys are not shortcut letters (`platform_reason.accented_shortcuts_are_windows`).
- [ ] **Linux:** evaluate X11 implementations of pointer centering, pointer teleportation and mouse spotlight; Wayland restricts these operations (`sg_actions.center_mouse`, `teleport_mouse`, `spotlight_mouse`). Evaluate file-manager-specific implementations of open-terminal-here and new-text-file-here.
- [ ] **Windows and Linux:** evaluate equivalents of the macOS bundled App Cloner (isolated application copies and profiles) and Encryptor (file encryption/decryption by drag-and-drop). These are bundled apps, distinct from the shared text and metrics encryption features.
- [ ] Triage each OS-specific configuration entry, action and greyed menu item in the generated [feature inventory](docs/feature-inventory.md). The recorded reason and equivalent distinguish OS-specific mechanisms from actual product gaps. Recheck runtime and hardware behavior before declaring parity.

## One-shot Shift parity follow-up

[November 5 focused audit](docs/audits/platform-parity/2026-11-05-one-shot-shift/report.md), source `9c565c88c9a1366a2e9b18c1b9d2868509510975`. The [generated capability comparison](docs/audits/platform-parity/2026-11-05-one-shot-shift/capabilities.md) separates intentional differences, source-only findings, original-owner executions over recorded ports and remaining native boundaries.

- [x] **[CODE] OSW-001 — Windows:** retain the completing modifier chord for named-control capture/replay, including Backspace, Enter and Delete. Cover modifier changes between capture and output, admission/refusal, exactly-once native receiving and the sibling DeadKey path. Adding Blind alone does not preserve the original captured state. Conditional source finding; native InputHook completion still needs qualification. **Already fixed** on `origin/fix/windows` (`12d91b67c6`, `3727598a02`, `2da3e853f0`: the captured control flags and logical modifiers are replayed); nothing redone here. Native InputHook completion still needs qualification.
- [ ] **[CODE] OSM-001 / OSL-001 — macOS/Linux:** validate the proposed same-key Shift optimization in the actual Caps Lock and held-modifier context. Caps Lock plus physical Shift currently spends one-shot activation while retaining lowercase in the original-owner probes. Cover both Shift keys, ordinary Caps/Shift controls, fallback title output, release ownership and native receiving. The Linux native XKB component independently confirms that its detached inverse plan differs from live Caps+Shift translation. **Partly done:** macOS already fixed by the complete-prospective-flags predicate in `adapters/one_shot_shift.lua`; the Caps Lock case is now pinned by a test. Linux remains open: the engine plans the title with a Caps-unaware layout table, so with Caps Lock plus a held Shift it presses a Shift that yields lowercase; a correct fix needs a live-state-aware planner (XKB peek with the Shift toggled) and native qualification.
- [x] **[CODE] OSM-002 — macOS:** validate accepted timeouts against both arming and editor numeric domains. The API can persist zero from a positive fraction; numeric NaN is also accepted under the acknowledged save port, while public arming rejects both. Public menu strings `1e309` and `1e20` persist and reload through original Config/TOML on private Linux files, then the next edit raises at `%d` before opening its dialog. Regress parse→save→rebuild→reopen, enabled/disabled states, valid controls and transaction refusal; define the unlimited-timeout policy explicitly. Native dialogs, metadata and lease/deployment still need qualification. [Real-persistence evidence](docs/audits/platform-parity/2026-11-05-one-shot-shift/macos/real-config-domain/report.md). **Already fixed** in the base (setter and `timing_leaf` admit only whole positive milliseconds within the timer ceiling); regression test `test_sticky_timeout_domain.lua` added. The unlimited-timeout policy question stays with the maintainer.
- [x] **[CODE] OSL-002 — Linux:** retain the engine output holder on repeated wrapped letters armed through an ordinary physical tap. Actual Reader/Hook/Manager/Engine/broker/Writer probes reject repeat provenance and retire the channel; the same stream without repeat remains healthy. Preserve loud refusal for genuinely foreign ownership, release debt and pause/reload controls; qualify real evdev/uinput receiving separately. **Done:** a wrapped key's repeat is now always the engine's own held row, not only for an input-armed one-shot; engine-level holder test added. Real evdev/uinput receiving stays unqualified.
- [ ] **[POLICY] Linux action origins:** review the explicit tap-only one-shot Shift restriction before exposing a generic action or keyboard slot equivalent to Windows `one_shot_shift` / macOS `sticky_shift`. Linux already implements the capability through tap-holds; generic accessibility StickyKeys is not established as equivalent to the shared punctuation, magic-key and title-case contract.
- [ ] **[POLICY] Windows/Linux timeout configuration:** evaluate exposing an editable one-shot timeout equivalent to the macOS user setting. All three share the2000ms default, but the reviewed Windows/Linux paths use the shared registry without the same editable user leaf. Preserve the documented per-driver construction and define any zero/unlimited policy before adding a control.
- [ ] **[TEST] macOS one-shot/CapsWord relay:** combine the original serializer and CapsWord observer for generated punctuation under a space-only exit policy. The direct one-shot emission path lacks an explicit output relay, but the archived emission port does not establish native tap ordering or a confirmed CapsWord failure. Keep this candidate outside the confirmed findings until reproduced.
- [ ] **[TEST/POLICY] Native one-shot text parity:** qualify Windows Tab/Escape capture representation, Unicode title casing and scalar replay against Lua key-down payloads; qualify macOS modifier-map/dead-key/IME handling and Linux real-device output receiving. The recorded-port probes and genuine isolated XKB component do not establish these cases. Do not list unverified behavior as an absent feature or assume a shared grapheme contract.

## CapsWord parity follow-up

[November 5 CapsWord audit](docs/audits/platform-parity/2026-11-05-caps-word/report.md), source `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`: four pinned reviewers,159 initial qualified rows and nine new findings. [Generated capability/intent comparison](docs/audits/platform-parity/2026-11-05-caps-word/capabilities.md). A later direct-catalogue countercheck extends existing WRSL-001 below; it is not a tenth new connector root. Windows findings are source-only; recorded Lua ports do not certify native application receiving.

- [x] **[CODE] CWW-001 — Windows:** attribute CapsWord delimiter termination to the accepted emitted action, not its physical tap carrier. Cover Tab→Backspace with only Tab checked and CapsLock→Enter with only Enter checked, real action/send admission and refusals. Physical Space HotIf priority remains separately unexecuted. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/windows/report.md). **Done:** `_TapHoldTapEmittedKey` makes the dispatcher judge the key the tap types; AHK test added (not executable on Linux; encoding gate passes). Termination still runs just before the send, not after its acknowledgement.
- [x] **[CODE] CWW-002 — Windows:** preserve the intended toggle when AltGr's admitted tap action is `caps_word`; its unconditional pre-clear makes the second accepted tap turn the mode on again. Cover the actual AltGr producer and prior-key-self checks, not just calling the generic toggle twice. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/windows/report.md). **Done:** `_AltGrHandleHold` no longer pre-clears CapsWord; the dispatcher alone ends it for a checked delimiter (source-pinned AHK test, not executable on Linux).
- [x] **[CODE] CWM-001 — macOS:** re-arm the running CapsWord deadline for accepted live idle changes, including0→positive, shorter/longer and positive→0, with save-refusal rollback and generation-safe timer retirement. Disable pointer exits before exercising the real menu so the original session remains reachable. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Done:** `CapsWordAutoOff.set_observer` makes the watcher re-time the running session after every accepted policy change (rollback included); tests in `test_watchers_capsword_auto_off.lua`.
- [x] **[CODE] CWM-002 — macOS:** prevent inactive pointer traffic from reserving the100ms gate for a fresh CapsWord activation's first checked discrete exit. Retain flood protection and test no-prior-pointer, below-threshold and exact-threshold controls. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Already fixed** by the activation reset of the pointer gate in `start_capsword_idle_clock` (test `capsword-activation-throttle`).
- [x] **[CODE] CWM-003 — macOS:** bind pending CapsWord clears to their activation/revision so an older completion cannot suppress a newer checked delimiter. Regress the valid native0-publication→newactivation1→delimiter→oldexit-callback window, preserving protection against old clears erasing a new activation. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Already fixed** by the activation clearing `_capsword_check_pending` and the per-clear identity in `complete_capsword_clear`; regression test added.
- [x] **[CODE] CWL-001 — Linux:** publish meaningful absolute-device pointer motion to CapsWord when pointer_motion is checked and gesture exit is off. Establish previous coordinates, ignore unchanged/initial reports, preserve relative-motion/contact controls and qualify actual reader/compositor receiving. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/linux/report.md). **Done:** the hook publishes a changed ABS_X/ABS_Y coordinate (first report and unchanged ones ignored, lifted contact forgotten) as `absolute_motion` for CapsWord; metrics ignore it. Real reader/compositor receiving stays unqualified.
- [ ] **[CODE/DOC] CWL-002 — Linux:** align the menu's explicit next-event live-apply promise with the active session's retained policy. Original menu callbacks acknowledge new Space/left-click values while the running owner uses the old ones. Decide the intended lifetime before changing runtime ownership or correcting the contract; preserve separate next-activation hand-edit semantics and failed-write controls. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/linux/report.md).
- [x] **[CODE] CWS-001 — shared:** define consistent rejection/minimum-positive quantization for accepted fractional CapsWord idle delays. Values below0.0005s round to0ms, meaning immediate expiry on Lua but disabled on AHK. Cover both actual policy ports and timer admission; ordinary whole-second presets remain unaffected. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/shared/report.md). **Done:** both policy ports now refuse a positive delay below 0.5 ms (`invalid_idle_timeout`); corpus vectors added and replayed by Lua and AHK.
- [ ] **[META/POLICY] CWS-002 — shared menus:** align the checked CapsWord star caption with its real character after choosing literal-built-in versus renamed-magic semantics. Actual macOS/Linux menus can show§ while their policy ends★. Preserve Windows's explicit separate built-in instance and test Lua module-load order rather than assuming every OS must rename it. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/shared/report.md).
- [ ] **[POLICY] CapsWord variants:** settle repeated catalogue invocation (toggle on Windows/Linux versus active request on macOS), fixed macOS editing/navigation exits and modifier-only idle activity. Keep explicit Windows next-activation setting lifetime and gesture exclusion distinct from unknown common intent. [Comparison](docs/audits/platform-parity/2026-11-05-caps-word/capabilities.md).
- [ ] **[NATIVE] CapsWord ownership:** qualify preexisting CapsLock and pause/quit/reload restoration, physical Windows Space HotIf priority, macOS key/control payload receiving, and Linux absolute reader/desktop keyboard grouping. Recorded lock requests and successful Lua cases are not receiving evidence. [Coverage limits](docs/audits/platform-parity/2026-11-05-caps-word/report.md).

## Repeat and recovery parity follow-up

[November 5 repeat/recovery audit](docs/audits/platform-parity/2026-11-05-undo-repeat/report.md), source `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`: four reviewers, 85 aspect rows, independent root replays and two final bounded dry sweeps. [Generated comparison and intentional differences](docs/audits/platform-parity/2026-11-05-undo-repeat/capabilities.md). Native application receiving and AHK execution remain qualified.

- [x] **[CODE] URL-001 — Linux:** retain the matcher word and its boundary after acknowledged repeat output. `ac★ê` misses the shipped correction; a word-only `x → z` rule can wrongly fire inside `po★x`. Cover the actual Main commit, not only the pure repeat resolver. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/linux/report.md). Done: Main now commits the repeat as a non-final result, so the matcher keeps the word and boundary.
- [x] **[CODE] URL-002 — Linux:** preserve private ancestry when repeat derives a scalar from actual personal-prefix output; Main currently publishes it to telemetry as public. TRACE payload logging is demonstrated only with TRACE enabled; SQLite persistence is source-only. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/linux/report.md). Done: the Linux engine tracks private ancestry and Main classifies a repeat out of it as private.
- [x] **[CODE] URM-001 — macOS:** prevent repeat from publishing a derived private scalar to ordinary telemetry, DEBUG output and AI context. Actual public Keymap/personal producer and fake HTTP-body capture demonstrate one scalar; the full private value remains protected. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/macos/report.md). Done: repeat now derives its private flag from the AI privacy mark, extends the mark and withholds the DEBUG scalar.
- [x] **[CODE] URW-001 — Windows:** preserve private ancestry after nonfinal programmable output before repeat. Shipped final personal outputs already block this direct path; genuine AHK regression and native receiving still need execution. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/windows/report.md). Done: `HSE_PrivateAncestry` is kept by every buffer commit/reset owner and the repeat Spec inherits `IsPrivate` from it (source-scan test; AHK not executed).
- [x] **[CODE] URW-002 — Windows:** normalize repeat classification in deferred Notepad/terminal completion as well as the atomic caller; live WPM coloring currently differs. Do not claim canonical category-field corruption: the durable row has no such field. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/windows/report.md). Done: one `_ResolveFireCategory` now classifies repeats as `repeat_key` for the atomic caller and both deferred owners (source-scan test; AHK not executed).
- [ ] **[PARITY] Windows/macOS:** evaluate an explicit immediate-Backspace trigger-restoration equivalent to Linux, or decide and document the exclusion. Application Ctrl/Cmd+Z is separate. Preserve original field/privacy authority, literal-output eligibility and empty/key-output/native deletion qualifications. [Comparison](docs/audits/platform-parity/2026-11-05-undo-repeat/capabilities.md).
- [x] **[SITE] URS-002:** move the English inventory headings/legend out of JSDoc into the exported dictionary. The actual-module-import guard fails on the missing exports before the repair and passes afterward; source-substring presence is not the oracle. This integration repair covers the shared heading used by the new live table. [Historical evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/shared/report.md).
- [x] **[META] URS-001:** add an authored behavioral catalogue for capabilities without a setting, including qualified Linux Backspace restoration; generate its site/docs table and README link, enforce reviewed-owner drift and localized notes. This closes the metadata omission, not runtime parity or undeclared-feature discovery. [Generated declarations](docs/behavior-inventory.md).

- [ ] **[POLICY] Repeat timing:** decide or explicitly retain the OS-specific activation window and expired-candidate ordering. Windows/Linux fallback is untimed independently of idle; macOS applies its effective magic-key window and modifier widening. Windows can let an expired registered winner mask repeat, whereas Linux rejects the timed result before fallback; macOS explicit star validation follows another documented path. The shared repeat corpus has no timing policy. The live behavior catalogue now exposes the window variant; its absence is not automatically a broken parent feature. [Four-reviewer timing countercheck](docs/audits/platform-parity/2026-11-05-undo-repeat/timing-followup/report.md).

## Word-reset and AI-context parity follow-up

[November 5 word-reset audit](docs/audits/platform-parity/2026-11-05-word-reset/report.md), same `b17e47e` source: four reviewers moved to this module after repeat/recovery closure, covering 98 aspects. [Generated comparison](docs/audits/platform-parity/2026-11-05-word-reset/capabilities.md) distinguishes independent AI lifetime, input-origin rules, documented limits and policy ambiguities. Runtime fixes below remain open.

- [x] **[CODE] WRSW-001 — Windows:** stop asserting a known word start after synthetic Alt/Win+Backspace where the physical counterpart explicitly leaves position unknown. Cover public shortcut emission and actual canonical effect; preserve send refusal/partial-output invalidation. Source-only finding; native AHK execution remains required. [Evidence](docs/audits/platform-parity/2026-11-05-word-reset/windows/report.md). Done: `HS_SyntheticBackspaceLeavesBoundaryUnknown` makes a sent Alt/Win/AltGr+Backspace publish no word start; Ctrl+Backspace unchanged (AHK test written, not executed).
- [x] **[CODE] WRSW-002 — Windows:** notify complete AI/agent context owners on physical editing/shortcut early returns and qualified synthetic effects. Incomplete-fragment revocation does not erase ordinary complete text; a fresh observer can forward obsolete context after Ctrl+Backspace or Select All. Preserve generation/focus rejection. [Evidence](docs/audits/platform-parity/2026-11-05-word-reset/windows/report.md). Done: `LLM_Bridge_OnUnknownEdit` retires prediction and agent contexts from modified Backspace, shortcut resets and synthetic non-arrow resets (source-scan test; AHK not executed).
- [x] **[CODE] WRM-001 — macOS:** preserve the independent AI navigation lifetime through the next typed key instead of reconstructing it from the hotstring buffer. Test all four reset-word/reset-AI combinations through actual public input and request serialization; immediate navigation assertions alone miss loss and resurrection. [Evidence](docs/audits/platform-parity/2026-11-05-word-reset/macos/report.md). Already fixed by `f390cbf51a` (independent AI context appended per key, no longer rebuilt from the hotstring buffer); no further change.
- [x] **[CODE] WRM-002 — macOS:** qualify bare keypad Enter's terminal empty-prompt receipt alongside main Return. Preserve multiline/modifier distinctions; reproduction requires a terminal accepting keypad Enter as submit, with native receiving and actual CR/ETX event payload still unexecuted. [Evidence](docs/audits/platform-parity/2026-11-05-word-reset/macos/report.md). Done: bare keypad Enter (keycode 76) now publishes the terminal empty-prompt receipt and the no-prediction Enter reset; Shift+keypad Enter stays multiline.
- [x] **[CODE] WRSL-001 — Linux:** publish arrow semantics for BOTH catalogue actions (currently no notification) and tap-hold arrow actions (currently generic tap switch). The declared arrow policy applies to all origins. Regress both independent switches, next-key matcher/AI state and acknowledged output; fixing only one caller does not close this finding. [Evidence](docs/audits/platform-parity/2026-11-05-word-reset/linux/report.md). CapsWord consumer extension: direct keyboard-slot/catalogue Enter/Tab emission also needs acknowledged semantic publication to the CapsWord owner; literal injector output already notifies it. Ordinary tap Enter/Tab uses a working native semantic relay and must remain a positive control. This extends the same connector root, not a new independent finding. [Supplemental evidence](docs/audits/platform-parity/2026-11-05-caps-word/linux-synthetic-followup/report.md). Done: the gesture manager publishes every acknowledged catalogue combination to one observer; Main applies the arrow policy (tap-hold option no longer overrules it) and ends CapsWord on an emitted Enter/Tab.

## Sequential WPM, wrap and personal-info parity follow-up

[November 5 sequential audit](docs/audits/platform-parity/2026-11-05-sequential/report.md) at `7aecd9a25b35efdcff68898919506dc2f6fd02d0`: four reviewers stayed on one module at a time, with independent root replays before advancing. [Generated capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-sequential/capabilities.md). These are bounded source/actual-owner findings; Windows native execution and desktop receiving remain qualified. Findings below remain open; this campaign changes evidence and tracking, not production behavior.

### wpm

- [x] **[CODE] WPMW-001:** Delayed boot Show overrides a newer widget disable. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wpm/windows/report.md). Done: the post-ready boot timer now runs WPMWidget_BootShow, which reads the committed visible preference when it fires, so a disable made during the delay stays in force.
- [x] **[CODE] WPMW-002:** Graph reports success after native bitmap upload refuses. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wpm/windows/report.md). Done: RenderGraph returns the GR_DrawBitmap acknowledgement (logged once, surface not revealed) and the pre-warm no longer reports success after a refused upload.
- [x] **[CODE] WPMM-001:** Floating WPM canvas never opts into native mouse event delivery. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wpm/macos/report.md). Done: the floating WPM canvas now opts into mouse down, up and move delivery (canvasMouseEvents), so dragging reaches its callback.
- [x] **[CODE] WPMM-002:** WPM default anchor remains outside the desktop after display shrink. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wpm/macos/report.md). Done: the default anchor is recomputed from the current display on every draw and no longer cached; only a dragged position persists.
- [x] **[CODE] WPML-001:** Refused redraw clears shown while the existing native widget remains visible, skipping later idle hide. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wpm/linux/report.md). Done: already fixed on origin/fix/linux (761df35a9f settle partially drawn WPM widget, c3c94dd547 retain ambiguous WPM widget hides): draw is treated as shown until an acknowledged hide; nothing redone here.

### wrap-symbols

- [x] **[CODE] WSW-001:** Saved custom wrap pair is ignored by remapped symbol keys. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/windows/report.md). Done: WrapTextIfSelected resolves the saved custom pair of the typed symbol (WrapSymbols_CustomPairFor) before building the output, so remapped keys wrap like the prefix route.
- [x] **[CODE] WSW-002:** UIA selection prefix is wrapped as though it were the complete selection. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/windows/report.md). Done: the UIA worker withholds a read that fills its GetText cap (status empty) so a truncated prefix is never wrapped as the whole selection.
- [x] **[CODE] WSM-001:** Checked guillemet pair does not match native layout trigger strings. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/macos/report.md). Done: typed guillemets, bare or with a non-breaking space, now trigger the spaced pair through the shared wrap_pair trigger keys while the output keeps its spacing.
- [x] **[CODE] WSM-002:** Wrap clipboard restoration discards later pasteboard items. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/macos/report.md). Done: already fixed by 68bd4b064d (Clipboard.save refuses a multi-item pasteboard before any mutation); regression test added for the wrap path.
- [x] **[CODE] WSM-003:** Disabling lower curly quotes removes a still-enabled opener. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/macos/report.md). Done: triggers are resolved after filtering by enabled pairs, so disabling the lower-quote pair keeps the curly opener.
- [x] **[CODE] WSL-001:** Typed guillemets cannot match their spaced built-in wrap pair. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/linux/report.md). Done: the manager registers every trigger form (bare and non-breaking-space guillemets) of each catalogue end through shared wrap_pair.register while the pair keeps its spaced delimiters.
- [x] **[CODE] WSL-002:** Endpoint alias collision removes the standard curly-double-quote pair from the actual menu. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/wrap-symbols/linux/report.md). Done: the tray menu is built from the ordered catalogue list instead of the alias map, so every declared pair appears once even when two pairs share an endpoint.

### personal-info

- [x] **[CODE] PIW-001:** Eager registered compounds escape field-navigation separators and admit partial identities. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/windows/report.md). Done: registered @-combos escape each value separately, keep the {Tab} separators live and decline the whole combo for an unknown letter or an empty field, as the fire-time resolver does.
- [x] **[CODE] PIW-002:** Valid TOML known personal fields silently load as placeholders. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/windows/report.md). Done: already fixed on origin/fix/windows (ad8268b7da preserve typed personal information through canonical TOML loading): ReadPersonalInfoToml decodes through the canonical codec; nothing redone here.
- [x] **[CODE] PIM-001:** Added valid ASCII aliases are ignored and removed by unrelated personal-info saves. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/macos/report.md). Done: [letters] now loads and saves any lowercase ASCII alias to a known field; an alias outside that alphabet is refused at load instead of being dropped and erased on the next save.
- [x] **[CODE] PIM-002:** Personal prefix expansion interprets accepted field data as key commands. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/macos/report.md). Done: personal prefix mappings register with literal_output, so field data such as {Tab} is typed as text and never sent as a key.
- [x] **[CODE] PIL-001:** Personal multi-field expansion drops the retained original text-destination publication. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/linux/report.md). Done: the retained text destination now reaches inject_fields and the combo is refused without one; the first erase and first value must still belong to the original field (later Tab-reached fields are not bound to it).
- [x] **[CODE] PIL-002:** Personal-information source and editor save ignore the effective configuration directory. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/linux/report.md). Done: init resolves personal_info.toml through the effective configuration directory (Paths.config) instead of the default directory, so expansion and editor save use the same file as the open-file action.
- [ ] **[CODE] PIL-003:** Missing first-boot personal-info file prevents editor initialization and source creation. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/linux/report.md).
- [x] **[CODE] PIS-001:** Shared prefix counts advertise mappings that are not generated for unspaced personal values. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/shared/report.md). Done: compute_prefix_counts takes the SSN and IBAN as stored and counts the spaced trigger only when it differs from the raw one (shared helper, macOS, Linux and Windows CountDynamicSection, corpus vectors updated).

### Policy, documentation and verification debt

- [ ] **[CI] Native Lua acquisition:** qualify current-source macOS LuaSocket/native-client build and launch after Lua.org timeouts; the upstream byte-identical Debian mirror changes for Linux and macOS are integrated, and targeted fetch/refusal controls pass. The earlier failed CI sources predate the macOS mirror fix. Preserve exact hashes and native receiving requirements. [Delivery evidence](docs/audits/platform-parity/2026-11-05-sequential/delivery.md).
- [ ] **[CI] Native keyboard-source fixture:** investigate selection-deadline/cleanup-unavailable refusals seen before and during this audit; the targeted retry passes, but that does not establish a repaired cause. Keep failed receipts and exact required cohorts.

- [x] **[CODE] Personal-info documentation:** replace obsolete Windows-preview-not-wired claims in shared README; audit the metadata-only missing localization key separately from the working translated menu caption. Done: the obsolete Windows-not-wired section of the shared README now describes the AutoHotkey mask twin; the metadata-only missing localization key is noted as a separate audit (not fixed here).
- [ ] **[PARITY] Personal aliases and preparation:** document allowed alias alphabets per OS; qualify or bound Windows eager pre-generation at accepted high pattern settings without claiming a measured hang. Preserve actual dynamic-resolution alternatives on Lua.

- [ ] **[PARITY] WPM:** decide pointer-hide and overlapping colour-source precedence explicitly across OSes; current code differs. Preserve the distinction between an unknown-intent discrepancy and a confirmed bug.
- [ ] **[PARITY] Linux WPM:** clarify whether no-tray means headless or floating-widget-capable; qualify GTK pumping accordingly. Review an explicit recovery surface for guarded rollback debt without bypassing its fail-closed admission.
- [ ] **[PARITY] Wrap management:** decide Windows supplementary Unicode scalar support; its UTF-16-length validator currently rejects scalar pairs accepted by macOS. Linux custom pair management is already tracked above; parameter-specific custom delimiters are available.
- [x] **[CODE] Wrap documentation:** correct the shared catalogue README claiming two drivers and obsolete open/close/label_key shape; retain trigger normalization separately from spaced output delimiters. Done: the shared catalogue README now names the three drivers, the real {left, right} group shape, and keeps trigger normalization separate from spaced output delimiters.
- [ ] **[CI] macOS wrap fixtures:** remove combined-run module-cache/i18n contamination: the combined selection reports 255 passes and four failures while the affected delivery fixture alone passes 12/0. Do not replace actual production owners with more forgiving stubs.

## Native runtime, editor and diagnostics parity follow-up

[November 5 audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md): nine bounded OS × module scopes at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`; 15 qualified findings, including one shared frontend root affecting all three OSes. These are source/model/private native-port findings, not 15 native desktop reproductions. [Capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-native-ui/capabilities.md). The canonical manifests exclude counterchecked LVB-002 and MRT-005.

### windows-webview

- [x] **[CODE] WVB-001:** Personal editor save refusal emits invalid JavaScript and leaves Saved visible. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/windows-webview/report.md). Done: the refusal toast splices the JSON literal bare through a tested script builder.
- [x] **[CODE] WVB-002:** Hotstring settings replace an unlimited zero delay with the default in the displayed control. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/windows-webview/report.md). Already fixed by 80f7ca753d (`ms ?? defaultMs`, gate `test-hotstrings-config-zero-delay.cjs`).

### windows-diagnostics

- [x] **[CODE] WDG-001:** Both crash worker writers retain truncated canonical JSON after partial write refusal. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/windows-diagnostics/report.md). Done: both workers stage the bytes, delete the owned staging file on refusal and publish with a no-replace move.

### macos-runtime

- [x] **[CODE] MRT-001:** Approval-watch deadline counts polling intervals rather than elapsed time. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Done: the watch takes a monotonic `now` port and checks one absolute deadline before each look and each result.
- [x] **[CODE] MRT-002:** Refused command watchdog leaves pending installation without its local deadline. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Already fixed by b4335a81ec (refused deadline retires the exact child; case `field-command-timer-refusal`).
- [x] **[CODE] MRT-003:** Malformed cached receipt is accepted by Lua but permanently refused by the Swift install source. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Done: the Lua cache requires the exact `digest\n` bytes the Swift source requires, so a damaged receipt is refetched.
- [ ] **[CODE] MRT-004:** Advertised reinstall route always refuses an already published runtime needing service recovery. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Needs a maintainer choice: a new authenticated Swift recovery role for a published runtime, or a distinct recovery reason and menu action; both need native macOS qualification.
- [x] **[CODE] MRT-006:** False native System Settings opener result is accepted without failure diagnostics. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Done: the watch keeps the native boolean and logs a false/nil opening as a refusal.

### macos-webview

- [x] **[CODE] MVB-001:** Action picker silently drops failed initial data delivery. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-webview/report.md). Done: init delivery reports encoding, submission and page-execution failures once with fixed metadata.
- [x] **[CODE] MVB-002:** Shortcut auto-close destroys the unsaved draft after a refused hotstring save. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-webview/report.md). Done: the host refuses the page-sent close until the last save committed, so a refused draft stays open.

### linux-runtime

- [x] **[CODE] LRT-001:** First managed install leaves the model browser using stale absence ancestry. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-runtime/report.md). Done: the page's read-only observer builds a fresh resolver per observation instead of keeping its first witness.

### linux-webview

- [x] **[CODE] LVB-001:** Shortcut hotstring auto-close is admitted but never closes its Linux page. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-webview/report.md). Done: `close` calls the manager's epoch-bound `close_owned_window` and, like macOS (MVB-002), refuses after a refused save.

### linux-diagnostics

- [x] **[CODE] LDG-001:** API diagnostics report and probe the Ollama backend instead of the selected backend. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-diagnostics/report.md). Done: collector and probe read `get_backend()`; a backend without a schema health path answers unsupported, as on macOS.
- [x] **[CODE] LDG-002:** Disabled AI becomes unknown in diagnostics and disappears from its export. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-diagnostics/report.md). Done: the collector keeps a known `false` and leaves only a missing switch unknown.
- [ ] **[CODE] LDG-003:** Refused timer admission leaves the configuration diagnostic pending without a completion path. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-diagnostics/report.md). Fixed on `fix/linux` by cc280519f5 (unarmed configuration and CPU timers finish with an error); closes when that branch merges.

### Qualification and policy follow-up

- [ ] **[NATIVE]** Exercise the retained runtime/editor/diagnostics receiving boundaries on Windows and macOS, and the Linux live GTK/session flows. Replay refused writes, native timer admission, stale epochs and physical cleanup; the private models do not certify these boundaries.
- [ ] **[POLICY] macOS local crash reports:** clarify raw local error/stack retention versus the existing no-PII comment; Windows explicitly keeps full local crash detail and Linux redacts before persistence. Shared exported diagnostics and day logs pass the canary control. No network disclosure or mandatory identical local retention policy is established.
- [ ] **[COVERAGE] Windows managed-runtime fixture:** update or retire the unregistered legacy direct-child bootstrap fixture; the registered current fixture correctly uses the nested managed path. Do not treat the old fixture as a product install failure. Partly done: the fixture now nests its root like the registered one (source guard in `test-windows-managed-bootstrap.cjs`); it holds the only reuse and runtime-receipt retirement cases, so registering it in `ci-windows.yml` remains, after a first native Windows run.

## Migration and update parity follow-up

Evidence: [six-scope recovery/lifecycle audit](docs/audits/platform-parity/2026-11-04-recovery/report.md). These 17 OS manifestations include shared causes; keep intentional platform policies and all current refusal guards.

### Windows

- [x] **[CODE] WFM-001:** Independent migration moves and locator publication can select an empty configuration after a refusal. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/windows-migration/report.md). A refused move keeps its key; paths.toml is staged and replaced atomically, a same-text backup is reused, and the configuration moves back when the file cannot follow.
- [x] **[CODE] WFM-002:** Moving a legacy ancestor leaves a selected custom descendant pointing to its removed path. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/windows-migration/report.md). A folder chosen below a moved old folder is rebased to where that folder went (its backup included).
- [x] **[CODE] WFM-003:** Valid quoted TOML locator keys are missed by the migration rewriter after data moves. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/windows-migration/report.md). The rewriter reads quoted keys, literal strings and escapes as the boot TOML reader does.
- [x] **[CODE] WFM-004:** Migrating only the locator hides the old configuration-transition recovery journal. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/windows-migration/report.md). The boot recovery owner runs on the old locator before anything moves; quarantine refuses the migration.

### macOS

- [x] **[CODE] MFM-001:** Refused bootstrap rewrite leaves a backup that blocks automatic restart recovery. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). paths.toml is staged and replaced atomically, a same-text backup is reused on retry, and the configuration moves back when the file cannot follow.
- [x] **[CODE] MFM-002:** Refused configuration move still publishes a locator to the absent new folder. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). A key is rewritten only when the report shows its old folder left.
- [x] **[CODE] MFM-003:** Valid explicit configuration locators become dangling after their containing folder migrates. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). Nested locators are rebased with their ancestor; quoted keys, literal strings and escapes are read as the TOML reader does.
- [x] **[CODE] MFM-004:** Destination check followed by POSIX rename can overwrite a newer concurrently published file. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). Native rename never replaces (mkdir reservation or hard link); a late arrival sends the old entry to its backup.
- [x] **[CODE] MFM-005:** Native directory listing refusal escapes migration and aborts driver initialization. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). The native list catches fs.dir's raise; the core reports an unlistable folder as kept (list_failed).
- [x] **[CODE] MFM-006:** Legacy log alias archives active files from the current destination root. [Physical identity proof and immutable post-discovery controls](docs/audits/platform-parity/2026-11-04-recovery/macos-migration/report.md). A legacy folder or entry that is the same device/inode as its destination is left in place and reported as aliased.
- [ ] **[CODE] MUR-001:** Refused restart reports a retained armed installation as failed and idle. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-updater/report.md).

### Linux

- [x] **[CODE] LFM-001:** Concurrent migration destination arrival is overwritten by native replacing rename. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-migration/report.md). Native rename is renameat2 RENAME_NOREPLACE; a late arrival sends the old entry to its backup.
- [x] **[CODE] LFM-002:** Newline-bearing legacy filenames are split and silently skipped. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-migration/report.md). The native list uses libuv scandir, which returns exact name bytes.
- [x] **[CODE] LFM-003:** Relocated configuration directory retains its obsolete native bootstrap locator. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-migration/report.md). The bootstrap config/logs settings follow a moved entry; a refused setting moves the folder back.
- [x] **[CODE] LFM-004:** Native directory enumeration failure is accepted as an empty successful scan. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-migration/report.md). A scandir refusal is reported as kept (list_failed); an emptied folder that cannot be removed is reported too.
- [x] **[CODE] LFM-005:** Legacy root aliasing current root archives active configuration as its own conflict. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-migration/report.md). A legacy root or entry that is the same device/inode as its destination is left in place and reported as aliased.
- [x] **[CODE] LUR-001:** Owned async installation blocks the daemon event loop during an unbounded launcher smoke. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/linux-updater/report.md). The async installer runs the smoke as an owned process group polled by a libuv timer; a refused install admission kills it.

- [ ] **[PHYS-W]:** receive the recovery audit scenarios on isolated Windows: actual AHK migration, DirMove/ACL refusal, old-locator transition recovery and native swap/boot-ready events. Private shared-Lua/PowerShell fixtures do not close Win32 qualification.
- [ ] **[PHYS-M]:** receive the recovery audit scenarios on isolated macOS: Darwin migration/permission/rename contracts, selected-profile restart adoption and Versions ARMED/refused-exit reconciliation. Linux physical ports do not close Hammerspoon/APFS qualification.
- [ ] **[PHYS-L]:** receive the recovery audit scenarios in an isolated real standalone installation: owned smoke deadline and responsive input/event loop, actual systemd/relay restart and successor observation. Disposable filesystem fixtures do not close live daemon qualification.

### Capability parity review

- [ ] **[CODE] macOS chosen-release updater:** evaluate an equivalent of Windows successor boot-ready/probation and post-launch recovery. The custom armed swap currently observes dispatch/rename, not a healthy successor; Sparkle is a distinct engine. Preserve intentional ARMED-on-quit semantics and record any deliberate lower guarantee. [Compared contracts](docs/audits/platform-parity/2026-11-04-recovery/capabilities.md).
- [ ] **[CODE] Linux standalone updater:** evaluate successor-ready receiving and recovery beyond pre-restart wrapper smoke plus systemd/relay request admission. Windows has the stronger boot-ready/probation contract; an equivalent or an explicit scoped reason remains to be established. [Compared contracts](docs/audits/platform-parity/2026-11-04-recovery/capabilities.md).

## End-to-end parity follow-up

Evidence: [12-scope flow review](docs/audits/platform-parity/2026-11-04-flows/report.md). These are OS/flow work items, not a claim of 26 unique causes or native acceptance. Preserve intentional policies and all current refusal guards.

### Windows

- [ ] **[CODE] WCP-001:** Selection startup can clear and copy after an external foreground-window change. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-clipboard/report.md).
- [ ] **[CODE] WCP-002:** Selection transformations can paste into a new window after clipboard preparation. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-clipboard/report.md).
- [x] **[CODE] WCR-001:** Marker-prefixed raw typing bypasses the protected SQL text encryption path. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: `KL_Enc_Encrypt` seals every nonempty raw value; only the migration skips stored envelopes; cipher, writer and decrypt-pass regressions added (rows already stored as clear lookalikes, and clear-mode lookalikes, stay a storage-format decision).
- [ ] **[CODE] WCF-001:** Widget coordinates can persist a mixed pair after failed compensation or reentrant position writes. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-config/report.md). Initial refusal is logged; preserve/recover the promised durable pair. Reentrant native timing remains conditional.
- [x] **[CODE] WDS-001:** Ordinary application quit discards failed window-close receipts. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-desktop/report.md). Done: refused WM_CLOSE receipts are counted; all-refused logs an error, partial or windowless quits a warning (`test_system_actions.ahk`, wds-001).
- [x] **[CODE] WDS-002:** Recycle Bin worker failure after successful launch has no completion observer. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-desktop/report.md). Done: the worker runs through `SystemControl.SpawnObserved` (ShellRunner); a refused start, a throw or a nonzero exit with its output is logged as an error (`test_system_actions.ahk`, wds-002).

### macOS

- [x] **[CODE] MCP-001:** Apps selection capture restores an obsolete clipboard over a newer copy. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md). Done: once the selection is read, Apps restores only over the generation it read (conditional `Clipboard.restore` receipt, as Search does) and revokes the snapshot after a newer copy.
- [ ] **[CODE] MCP-002:** Independent macOS clipboard borrowers snapshot another family’s temporary payload. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md). Partly done: `infra/clipboard_borrowers.lua` is one admission for every family; Text, Apps and Search refuse while another family borrows the clipboard. Left, needs a decision: TextSender fast paste and keymap output only register as holders and still snapshot without asking, because refusing them drops typed output (drop, wait, or type as keystrokes?).
- [ ] **[CODE] MCP-003:** Ordinary delayed selection transforms paste captured text into another focused app. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md).
- [x] **[CODE] MCR-001:** Encryptor source conversion can destroy an approved overwrite target on failure. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Approved overwrite is required; improve failure-safe replacement. No unconsented overwrite or explicit atomicity promise is asserted. Done: `encryptor_convert.sh` converts into a stage next to the destination, renames it over the target only on success and removes only that stage on failure.
- [x] **[CODE] MCR-002:** Encryptor hidden password is embedded in shell command arguments. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the password goes into a private file read by `-pass file:` through the bundled `encryptor_convert.sh`; `main.scpt` is rebuilt by the field run's `scpt_recompile` step.
- [x] **[CODE] MCR-003:** Raw envelope-prefixed typed text bypasses macOS SQL payload encryption. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: the shared `text_cipher.encrypt` seals every nonempty raw value; the shared raw-ingress contract runs on macOS (clear lookalike rows stored before the fix stay a storage-format decision).
- [x] **[CODE] MCR-004:** HuggingFace login credential is embedded in native bash argv. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the token is queued on the login task's stdin before start and Python reads it there; the bash/Python arguments carry no credential.
- [x] **[CODE] MCR-005:** Failed API secret replacement restores old metadata pointing to overwritten Keychain value. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: a replaced token is written to a fresh account `<id>#r<n>`; the superseded account is retired only after the new reference commits, so a rollback still resolves to the old secret.
- [x] **[CODE] MCR-006:** Refused migration slice timer leaves successful-start receipt and permanently running idle pass. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the shared driver reads the timer's committed flag; a refused slice pauses the pass (cursor kept, error logged) and start/resume report false.
- [x] **[CODE] MCF-001:** Rejected locale changes publish canonical config before reload or settings admission. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-config/report.md). Shared rejected-locale publication root; retain the macOS timer-race subtype and Linux startup control. Done: the audited refusals already restore the config row (b63fad4be5); the remaining timer-race subtype is fixed: a refused later switch now re-arms the reload an accepted earlier switch still owed (timer and settings refusal regressions).

### Linux

- [ ] **[CODE] LCP-001:** Clipboard borrowers restore only text and silently discard other original formats. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md).
- [ ] **[CODE] LCP-002:** Text transformations overwrite an intervening external clipboard copy. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md).
- [ ] **[CODE] LCP-003:** Case and wrap transformations can replace a changed selection in the same text field. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md).
- [ ] **[CODE] LCP-004:** URI clipboard probing can send Ctrl+C to an unvalidated terminal, including an unchanged terminal through make_executable_selection. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md).
- [x] **[CODE] LCR-001:** Raw marker-prefixed typed text bypasses encryption and can abort decryption migration. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: same shared fix and contract on Linux; a decryption pass now restores marker-prefixed literals (clear lookalike rows stored before the fix stay a storage-format decision).
- [ ] **[CODE] LCR-002:** Secret-tool stdin write refusal can still publish a successful API credential reference. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-crypto/report.md).
- [ ] **[CODE] LCF-001:** Failed legacy alias cleanup resurrects a later accepted neutral preference. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-config/report.md).
- [x] **[CODE] LCF-002:** Rejected locale change remains canonical startup authority after native alias refusal. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-config/report.md). Shared rejected-locale publication root; retain the macOS timer-race subtype and Linux startup control. Already fixed: b63fad4be5 on this line and a11e87d025 on fix/linux restore the configured row when the native alias is refused; the absent-row startup control is unchanged. Nothing redone here to avoid a test-file conflict.
- [ ] **[CODE] LDS-001:** Desktop command producer hides both shell acquisition and background child failures. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-desktop/report.md). Partly done: a refused background shell is now logged; the child's own exit status and stderr still have no owner (open).
- [x] **[CODE] LDS-002:** Serialize independently accepted Linux theme read-modify-write toggles; overlapping calls currently lose one transition. [Public-dispatch reproduction and controls](docs/audits/platform-parity/2026-11-04-flows/linux-desktop/report.md). Done: toggle_dark_mode and show_desktop queue on one flock in the session lock folder; a real-shell test runs two overlapping toggles.

- [ ] **[PHYS-W] / [PHYS-M] / [PHYS-L]:** execute only the receiving scenarios named by each flow report on isolated native hosts. Source/recording-port tests do not close native focus, selection, keyring, application or device qualification.

## Deep OS × module follow-up

Audited source and immutable evidence: [18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md). These entries are implementation/validation work, not permission to remove deliberate safety checks or silently change explicit product contracts. Intentional differences and unresolved rationale are in the [provenance register](docs/audits/platform-parity/2026-11-04-deep/intentional-differences.md).

### Windows

- [x] **AHK-001 / WH-001:** Reload of a repaired programmable source clears its problem but leaves callback admission disabled. [windows-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/windows-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Fixed: a successful programmable-source Reload restores the configured callback admission; regression test added.
- [x] **AHK-002 / WI-001:** LAlt Tab tap with explicit None hold still activates navigation. [windows-input evidence](docs/audits/platform-parity/2026-11-04-deep/windows-input/report.md). Implement the stated boundary regression before claiming closure. Fixed: Tab immediate-layer mechanics now require a hold layer, so Tab tap + None hold is a plain tap; meta regression added.
- [x] **AHK-003 / WI-002:** Composer Save-and-use treats pending selection launch as completed active layout. [windows-input evidence](docs/audits/platform-parity/2026-11-04-deep/windows-input/report.md). Implement the stated boundary regression before claiming closure. Fixed: Composer Save-and-use now publishes used only when the selection reload commits (new LayoutManager_SelectSettled), failure on later refusal; regression test added.
- [ ] **AHK-004 / WM-001:** Movement-only pointer distance is silently excluded from every typing-buffer flush. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **AHK-005 / WM-002:** Enabled metrics encryption leaves typed text and per-key events in durable plaintext today.log. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [x] **AHK-006 / WM-003:** Explicit dashboard cache Reset preserves and reuses its durable reader image. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure. Fixed: explicit cache Reset now retires the durable reader image (KLR_CacheRetire) before the successor build; regression tests added.
- [x] **AHK-007 / WG-001:** Onboarding publishes success when Precision Touchpad restart is absent or fails. [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure. Fixed: onboarding PnP worker now fails on no device or refused disable/enable and re-enables disabled devices (same contract as the tray restart worker); regression test added.
- [x] **AHK-008 / WG-002:** Existing invalid touchpad backup authorizes destructive registry configuration. [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure. Fixed: an existing touchpad backup must parse as restorable before any apply or onboarding elevation; regression test added.
- [ ] **AHK-009 / WG-003:** Onboarding cross-account UAC writes elevated administrator HKCU instead of original user hive (conditional two-account UAC scenario; native confirmation still required). [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure.

### macOS

- [x] **HS-001 / MH-001:** Programmable static preview metadata is parsed as output tokens on macOS. [macos-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/macos-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Done: programmable previews render literally (rules engine marks them; llm_bridge skips token projection); regression test_programmable_preview_literal.
- [x] **HS-002 / MI-001:** Catalogue layer_on/layer_off actions do not synchronize the macOS navigation wheel owner. [macos-input evidence](docs/audits/platform-parity/2026-11-04-deep/macos-input/report.md). Implement the stated boundary regression before claiming closure. Done: catalogue layer_on/layer_off publish the nav layer to the wheel once their write settles (newest intent wins); regressions in test_karabiner_actions_reachable.
- [x] **HS-003 / ML-001:** Sequential local streams and retries share a request-scoped cumulative thinking filter. [macos-llm evidence](docs/audits/platform-parity/2026-11-04-deep/macos-llm/report.md). Implement the stated boundary regression before claiming closure. Done: each sequential MLX/Ollama variant streams under its own identity and the handler resets its filter only at that boundary; retries no longer stream; regression test_sequential_stream_identity.
- [ ] **HS-004 / MM-001:** Metrics collection pause still records window activity and later credits paused pointer travel. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **HS-005 / MM-002:** macOS measured passive sleep and lock durations remain zero in dashboard aggregates. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **HS-006 / MM-003:** macOS keep-awake completion events never populate keep-awake accounting. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **HS-007 / MM-004:** macOS nested lock and sleep transitions overwrite passive interval ownership. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **HS-008 / MC-001:** Failed onboarding Finish retains new configuration locator and locale. [macos-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/report.md). Implement the stated boundary regression before claiming closure.
- [x] **HS-009 / MC-002:** Restored configuration UI promises restart despite refused or throwing reload. [macos-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/report.md). Implement the stated boundary regression before claiming closure. Done: a refused, raising or aborted restore reload now reports phase failed (restore_error_unexpected with the pre-restore copy path), as on Windows, instead of promising a restart (macOS and Linux); regressions in each driver's test_changelog_release_install.
- [ ] **HS-010 / MG001:** System-gesture preference probes never start their prepared ShellRunner tasks. [macos-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/macos-gestures/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **HS-011 / MG002:** Tap commit dispatch bypasses the macOS system-gesture conflict gate. [macos-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/macos-gestures/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **Two copies of the app erase each other's Accessibility grant (field report 2026-11-05).** A local build (`build/macos`, local self-signed certificate) and the `/Applications` dev prerelease (CI certificate) share `com.ergoptiplus.app.hammerspoon`. The switch the user turns on can match the other copy. The copy that boots is then not trusted, and `infra/accessibility_wait.lua` runs `tccutil reset` on the bundle id, which removes the switch at every reload. The field run's installer now unregisters every other copy before it opens the app; the app itself still needs the fix: before the reset, find every registered copy of the bundle id (LaunchServices) whose signature differs from the running one, and name its path in the guidance dialog instead of resetting in a loop. The boot now resets the entry once per install (version, device and inode of the launcher) and shows only macOS's own prompt. `ui.permission_dialog.guide_accessibility`, its tests and its locale strings are now unused: retire them.
- [ ] **Owned runtime: the helper's own report path still demands two code hashes (field report 2026-11-05).** The published helper carries one SHA-256 code directory per slice. The launcher now admits one or two (`OwnedRuntimeInstallMainOperation.codeDirectoryHashes`), which unblocks the install. `OwnedVirtualHIDDaemonReportStageOwner.admitImage` is compiled into the helper and still requires `hashes.count == 2`; switch it to the same rule at the next runtime rebuild. The install acceptance (`tools/build/owned_runtime_install_acceptance.sh`) runs the helper directly with sudo and never exercised the launcher's check; drive it through `--request-owned-runtime-install` instead.
- [ ] **Field checks report a missing owned runtime as broken config.** With the owned runtime selected but not admitted, nothing is generated: `field_tap_hold_thresholds` fails `unreadable` on the never-created `karabiner.json` (`adapters/field_check_ports.lua:121-149`), and `field_tap_copy` counts the nil deployed timeout as short (`infra/field_check_tap_copy.lua:72-74`). Both should report `skip:runtime_not_admitted`.
- [ ] **Field run follow-ups from the 2026-11-05 report (30 pass, 12 fail).**
  - `field_lease` runs before `field_owned_install` in `data/field_run.json`: move it after `owned_install_reload`, and report `cli_present`, `guardian_state` and `cli_version` as `skip:owned_runtime_not_admitted` without the 30 s guardian wait when the owned runtime is not admitted (`infra/field_check_checks.lua:129-171`). Its `config_present` reads the shared `~/.config/karabiner/karabiner.json` instead of `KePaths.config_file_for(KePaths.selected_runtime())`.
  - `field_owned_runtime` fails `capture_unloaded` on every owned boot: `runtime_owner_ports.new()` loads `physical_capture` eagerly (`adapters/runtime_owner_ports.lua:294`). Make that check info now that owned is the default, or the require lazy.
  - `field_owned_start` fails `user_karabiner_closed` when the runtime is not ready; leaving the user's Karabiner-Elements running is then correct (`infra/field_check_owned_activation.lua:88-95`): `skip:runtime_not_ready`.
  - `field_owned_pause` is rolled back by Ollama: a serve task that exited 78 leaves its start cleanup unsettled, `pause_warmup` returns false (`modules/llm/api_ollama.lua:571-592, 714-735`), and the global pause gives up. A dead, unpublished daemon must not block the pause.
  - The managed Ollama daemon itself exited 78 ("operation"): the next report names the primary and cleanup failures (`managed_ollama_serve.py` now prints both).
  - `key_accounting` fails `window_unfocused` intermittently: the first key asks `hs.window.focusedWindow()` once, 0.6 s after the scratch window shows, and a 523 ms main-thread hold made it miss (`adapters/field_probe_ports.lua:711-714, 799`). Wait for the window's own focus report, and give the two refusal sites distinct tokens.
  - `diagnostics` fails `phase_a_budget` at 5.2 ms against 5 ms: phase A's permissions section calls `hs.accessibilityState` and `screenRecordingState` live (`ui/healthcheck/helpers.lua:436-461`), which breaks the schema's rule that phase A reads memory only. Cache both from the boot and screen-capture reads, or make them a probe; keep the 5 ms budget.
  - The managed Ollama daemon still fails at the native guardian (`platform/suspended_image_owner.py`, `V1 REFUSED <errno>`); the next report names the errno (`cleanup_guardian_refused`) and the installed app's strict signature (`app_signature` step).
  - **A resting thumb turns a 2-finger swipe into a 3-finger one** (20:06, `tab_close` fired; also a held `tap_3` left click at 20:04). The join gate accepts a third contact after 20 ms with no spatial check (`modules/gestures/engine.lua:1193, 1204-1228`, cohesion `:301-321`); that contact sat about 60 units from the pair. Log each contact's position and `majorAxis` when a count is accepted, calibrate a max finger gap from the next report, then refuse a far or oversized contact at both join paths and at the 3-finger tap commit, with the three cases of the field report as regression tests.
  - After "Restore recommended", show the Trackpad settings dialog when a recommended slot is still claimed by macOS (`ui/menu/menu_gestures.lua:420`); the restore never touches macOS settings. Add a read-only `defaults read` of the Trackpad and Dock gesture keys to the Mac field report.
  - The tap commit skips the macOS conflict gate (HS-011 / MG002, `modules/gestures/engine.lua:708`).
  - The Mac's LogsDirPath still ends in the old `ergopti_plus` folder, so logs land in `…/ergopti_plus/Ergopti/`; the migration only rewrites old default folders.

### Linux

- [ ] **LIN-001 / LH-001:** Registered single-field dynamic expansions have no production preview row. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-002 / LH-002:** Invisible previews increment offered-suggestion metrics. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-003 / LH-003:** Built-in dynamic expansions bypass configured expansion-delay admission. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-005 / LL-001:** Interrupted Ollama chat overwrites successor admitted by cancellation terminal callback. [linux-llm evidence](docs/audits/platform-parity/2026-11-04-deep/linux-llm/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-006 / LL-002:** Refused translation dispatch leaves permanent loading offer. [linux-llm evidence](docs/audits/platform-parity/2026-11-04-deep/linux-llm/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-007 / LM-001:** Excluded collection spans remain inside typing sequences and durations. [linux-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/linux-metrics/report.md). Implement the stated boundary regression before claiming closure.
- [x] **LIN-008 / LC-001:** Configuration restore announces restart even when restart is refused or unavailable. [linux-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/linux-lifecycle/report.md). Implement the stated boundary regression before claiming closure. Done: a refused, raising or aborted restore reload now reports phase failed (restore_error_unexpected with the pre-restore copy path), as on Windows, instead of promising a restart (macOS and Linux); regressions in each driver's test_changelog_release_install.
- [ ] **LIN-009 / LG-001:** Linux advertises and accepts three unreachable horizontal-axis gesture slots. [linux-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/linux-gestures/report.md). Implement the stated boundary regression before claiming closure.
- [ ] **LIN-010 / LG-002:** Clearing persistent MT coordinate registers on lift drops subsequent valid gestures. [linux-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/linux-gestures/report.md). Implement the stated boundary regression before claiming closure.

- [ ] **Accepted-agent policy:** settle whether pause/AI-off cancels an already accepted deferred connector. WL-001 is a policy hypothesis, not a confirmed defect; see the [self-countercheck](docs/audits/platform-parity/2026-11-04-deep/windows-llm/peer-validation.md).
- [ ] **Native acceptance:** run the unexecuted AHK/account-context/PnP and actual Mac/Linux device/provider scenarios from each module coverage register. Lua/PowerShell recording-port probes are not native desktop certification.

## Handoff, 2026-11-03 late evening (read first if the session was lost)

- **Release 1.0.9 is pending on CI only.** dev `ed2618c2fe` holds every 1.0.9 change; full CI run 41730677937 is the
  release gate. Last reds before it were infrastructure (Ubuntu APT over 10 min in Shared UI rendering, macOS 26 XCTest
  lease lost, Windows keystats `metrics-native-sender` deadline): rerun those jobs once; any other red is real. When
  green: fast-forward `main` to that commit (`Release-As: 1.0.9` trailer only if the computed version differs), watch
  the publish, then clean up (below). Never push main for anything else.
- **Work for the next release, each on its own pushed branch** (rebase on dev, land by fast-forward only):
  - `next/ai-hotstring-tooltip` — AI tooltip never covers a hotstring tooltip; choice wait (default) / both. Done, CI
    reds same as dev. Left: try « both » by hand; Windows rows linger past expiry; macOS canvas does not follow height.
  - `next/key-names` — chord action labels, sticky/layer holds, tooltip footer from the key name table; Arabic and
    Chinese finger counts fixed. Left: physical shortcuts and metrics web pages; macOS `hyper`/`altgr` holds French.
  - `wip/gesture-clear-touchpad` (agent running) — Gestures « Tout effacer » also restores the touchpad (backup, else
    Windows factory defaults) and the Configuration row goes; « Infos… » instant (took 5 s) with a rewritten text in 21
    locales explaining the rare-shortcut trick; recommended set on all OS, macOS direction: 3 fingers ←/→ tabs (macOS
    incremental `ax_actions.tabs`, Windows discrete), ↑ new tab / ↓ close tab; 4 fingers ←/→ Space/desktop, ↑/↓ next /
    previous window of the app; macOS 5 fingers ↑ Mission Control / ↓ App Exposé; tap 3 left click held; tap 4
    `alt_tab_monitor`; macOS greys a slot whose system gesture is on (suffix about 20 characters, « — pris par macOS »)
    and suspends it until the system gesture is None; never write the macOS prefs.
  - `wip/layout-composer-responsive` (agent running) — the layout composer page reflows when the window is resized and
    no button sits behind the preview, same page on the three OS; Layout menu: « Couches émulées » header, the four
    rows in a « Rangées émulées (apprentissage progressif) » submenu.
  - `wip/windows-boot-time` (agent running) — boot measured at 7.8 s (parse 1.7, layout 1.2, hotstrings 1.0, tray 1.0);
    parser and snapshot fixes, counted-operations gate; approved: keyboard before tray, a tray click during boot waits
    for input ready. Still too slow: keep cutting (lazy includes, caches).
- **Cleanup after the release.** Remove every `.claude/worktrees/*` (delete the node_modules link first, never the
  real folder); delete local branches except dev and main; delete remote branches except main, dev, sparkle-appcasts,
  gh-pages and the `next/*` / live `wip/*` branches above; tag non-merged tips `archive/2026-11-03/<branch>` first.
- **After that:** owned bundled Karabiner (`next/owned-karabiner`), one Ergopti folder name, one config layout on every
  OS (items below); macOS field report rerun (`git pull && bash tools/dev/collect-macos-field-report.sh`).

## Branch `wip/layout-composer-responsive` (3 November, resume from this branch alone)

- [x] **Responsive layout composer, same page on the three OS.** Done in 47e87f0f0b: board in fractions of a
      full-width board, footer action bar, `WebView_FitToWindow` in every Windows Size handler; macOS and Linux
      already resized their view. Gates: `npm run test:browser:layout-composer`, `test_webview_fit_to_window.ahk`.
- [x] **Layout menu: layers and rows apart.** Header « Couches émulées » above the two layer rows, the four row
      switches in the submenu « Rangées émulées (apprentissage progressif) »; decision in maintainer-decisions.md.
- [ ] **Next: land on `dev`** by rebase and fast-forward when the maintainer asks (never push `dev` or `main` from
      here). Branch rebased on dev 41e2888d08; CI run 41742438444 green except Linux alpine integration
      (`test_sqlite_first_open.lua` system-event capture, metrics, untouched here) and the macOS 26 build still
      running when noted. Chromium and WebKit ran the composer gate: 24 cases.

## Branch `wip/gesture-clear-touchpad` (gesture requests of 3 November)

Resume from this branch alone; it is based on dev 6d6b743c4f and not yet integrated.

- **Done.** Gestures « Tout effacer » restores the Windows touchpad (registry backup, else the Windows factory
  defaults of `precision_touchpad_registry.toml`), global clear too; Configuration row and its locale key removed
  (95ee89c868). Instant « Infos… » after a reload (27c7e13053, a18cfaecff). Infos text: the Windows rare-shortcut
  trick, macOS/Linux read the touchpad (9d8d16237a). One recommended set on every OS, macOS direction (6bc43f8d44),
  macOS five fingers up/down = Mission Control/App Exposé (6fd5f27e95); macOS tabs already scale (mode
  incremental), Linux scalable swipes queued below (c99fe71d17). macOS greys and holds back a slot whose macOS
  gesture is on, short « — pris par macOS » suffix, recheck every 20 s (bccbdb185c). Updater sources resealed
  (5b6ee92094).
- **In progress.** CI `os_lanes=all` on bccbdb185c. Known reds also red on dev 6d6b743c4f: Common Menus
  (`test-menu-parity.cjs` macOS configuration dispatch fixture) and Linux fedora (OpenSSL signature tests).
- **Next.** Rebase on dev and hand over for integration; on the Mac, check that a slot greys when its Trackpad
  gesture is on and comes back when it is off, and that a three-finger swipe moves tabs with the distance.

## Release 1.0.9 (maintainer requests of 1-2 November, written so the work survives a lost session)

Release as 1.0.9 on `main` by fast-forward from `dev`, with `Release-As: 1.0.9` if the computed version differs, once the
three-OS CI is green on the final source. See the handoff above for the current state.

- [ ] **Macos field report 2026-11-02.** Rotation warnings at midnight during the recovery; `event_taps` run loop late:
      main thread held 1.5 s, `menu.rebuild` 1.3 s (`menu_item.shortcuts` about 1 s); `diagnostics` phase A over 5 ms;
      `idle_cost` 8.35 %; Ollama `digest_mismatch` on `granite4:350m-h` twice, after the retry. Then rerun the report
      without touching the Mac.
- [ ] **Slowness, every driver.** Windows boot 7 s, `menu.rebuild` 1.7 s: lazy submenus, single-toggle update, one
      registry proof, full save after ready, disk caches; a toggle must not rebuild 1000 rows.
      Resume here (branch `wip/windows-boot-time`): parse fixes, the smoke operation caps, keyboard before tray root
      and the queued early tray click are committed (keyboard registered at 4.5 s instead of 5.1 s on the smoke
      fixture). Next, largest first: the emoji and symbol sections take 406 of the 1031 ms hotstrings stage on that
      fixture; defer them after ready in slices of a few tens of ms, but their registration order feeds the
      collision tie-break (`_DynHS_RegisterAll` and the repeat key must stay after them): reserve their `Seq` block at
      the boot position, and keep the preview index complete. Then script parse (lighter boot includes; AHK has no
      runtime include, so only a smaller graph or a worker helps) and layout (rejected disk cache: native hotkey
      registration). Measure each with interleaved base/candidate smoke-fixture boots (summed `process_cpu`). CI of
      the branch: run 41737399378 (first run 41732233161 found two branch regressions, fixed since; its PAC and
      action-picker WebView reds pass locally).
      Windows boot, 3 November. Real logs: 4.75 s at best, 7.8 s typical, 15 s and more
      under load; parse 1-1.7 s, layout 1.2 s, hotstrings 1.0 s, tray 1.0 s (AI submenu 0.75 s), pre-logger 1.2 s.
      Three boots waited 24 s, 26 s and 446 s on a tray opened during boot (`native_menu_wait`): input waits for the
      open menu. Done, measured on a smoke fixture made from the maintainer's config (median of 3 interleaved runs,
      process CPU 7.75 → 7.20 s, menu usable 6.6 → 5.5 s; realistic-hotstrings fixture: hotstrings stage 1.9 → 1.1 s):
      quoted TOML text lexed in native runs (personal file parse 463 → 165 ms), snapshot comparison without map
      copies, one boot snapshot read for the AI options (4 → 1), personal-file metadata decodes only `[_meta]`
      (468 → 29 ms for three 35 KB files). Gate: the startup smoke bounds the boot's counted operations
      (`BOOT_OPERATION_CEILINGS`). Left, deliberate or rejected: parse, layout and hotstring registration (about
      4.4 s) are needed at the first key; the remote AI catalogue (212 ms, rejected while the AI root is eager); the
      boot's 9-13 registry deep compares (every write compares).
- [ ] **AI menu.** "Test a prediction" under the profile row: group model, profile, test, never two separators in a row.
      The test uses a high temperature, bypasses the cache, never a fixed string, and shows the generation time.
- [ ] **Generation parameters submenu.** Predictions count, min and max words with no separator; one separator; all the
      context rows at the bottom (two separators become one).
- [ ] **Prediction indentation default -3**, recommended -3, all drivers.
- [ ] **French punctuation.** Space before `:` in composed `label: value` rows and about 21 strings, with a gate.
- [ ] **Multi-prediction tooltip.** The number is right-aligned in the tooltip, not stuck to the text.
- [x] **macOS one-shot Shift is not one-shot.** Tap it then type « abc » quickly: « ABc » or « ABC ». It must be spent
      by the first key; today it seems to end only on its timeout (configurable in the menu, can be infinite). Check
      the F20 one-shot sentinel path (modules/keymap/one_shot_shift.lua, adapters/one_shot_shift.lua) against Windows
      and Linux, with a regression test typing three keys inside the timeout.
- [ ] **One configuration layout on every OS.** A macOS configuration imported on Windows or Linux must work as it
      did, Cmd versus Ctrl aside. Today the tap-hold settings live in three shapes: Windows `config.toml` plus
      `tap_hold.toml`, macOS `config_karabiner.toml` (keys, global delay, sticky delay, key combinations, and now
      `tap_holds.lone_modifier_tap_max_ms`), Linux `tap_hold.toml` (keys, switch, and the lone tap window) plus
      `config.toml` (`mod_combos`). Pick one home per manifest path (the manifest's `config.toml` for every
      `[[features.*]]` row, one shared tap-hold file for the keys), move each driver's reader and writer to it,
      with one migration of the old files, and a cross-driver test that writes a file on one driver and reads it on
      the other two.
- [x] **Metrics and gestures section titles.** The metrics section « Mots par minute » becomes « Vitesse de frappe »;
      the gestures menu gets one section title per finger count (« Gestes à 2 doigts », « à 3 doigts », …) and no
      « Gestes Ergopti » title; « Gestes du système » gets a clearer title saying the system gestures are handed to
      Ergopti so it can change them (synchronisation of the system gestures), all drivers, 21 locales. In the
      shortcuts menu the « Sélection » section title becomes « Encadrement de la sélection ».
- [x] **Download proxy row out of Debug.** The download proxy setting is configuration, not debugging: move it from
      the Debug menu to the Configuration menu, all drivers.
- [x] **Hotstring tooltip under the AI tooltip.** Option `llm.trigger.while_hotstring_tooltip` in the AI trigger
      menu, 21 locales: "wait" (default and recommended) holds every automatic request at the debounce, the spinner
      and the render while a hotstring tooltip shows, and the chain after the hotstring asks again; "both" draws the
      hotstring rows and the prediction in one stack (Windows one surface, Linux one window, macOS the prediction
      canvas under the rows). Live mode always waits; a prompt asked for by name is never held. Field check left:
      "both" on a real desktop, and the Windows header rows stay until the next render after their own expiry.
- [ ] **Key names, what lot CH left.** Menus now name keys from `_shared/data/keycodes/key_names.json` in the 21
      locales. Still raw or French: the shared modifier-chord action labels (« Cmd + Option + Shift + Enter » in the
      action pickers, all drivers; tests pin this label family, so it needs its own change); the macOS sticky holds
      and `layer` hold labels; the tooltip footer hints in `_shared/modules/tooltip/constants.toml`; the physical
      shortcuts and metrics web pages. Arabic `gesture.slots.swipe_5_horiz` says four fingers.
- [ ] **Model selection page.** Install Ollama and Install MLX buttons act or say why, disabled when installed; a whole
      section header opens its list; header on two lines (install, port, status; then add a model by hand); Ollama and MLX
      models grouped in collapsible sections per provider, alphabetical; search crosses sections; gate for page actions
      with no host handler.
- [ ] **Options greyed.** Disable in browser address bars and in password fields can be changed, or say why not.
- [ ] **Defaults and recommended.** Each manifest row declares feature or setting, CI gate, empty config boots neutral,
      missing option takes its manifest default, Restore recommended restores adjusted settings too (see
      docs/memory/maintainer-decisions.md).
- [ ] **Keep Ollama behind a proxy.** 0.40.4 downloads blobs outside the proxy; 0.40.6 fixes it, shared pin needs a Mac rebuild.
- [ ] **Before publishing.** Whole AHK suite on a quiet machine with no resident driver, `npm run test:ahk-tray-rows-read-as-text`,
      all live checks including `quit-over-a-log-flush`, JS, macOS and Linux suites, Windows field report with a driver.

## To confirm on the Mac

Check out `dev` (or the branch to test), set Debug > Log level > DEBUG, then run
`bash tools/dev/collect-macos-field-report.sh`: it creates `field/mac-<today>-<branch>`, runs the field checks in
the developer app, writes the report under `docs/field-reports/`, commits and pushes. Needs Go, the Xcode Command
Line Tools and python3 3.11.4 or newer; `swift test` needs full Xcode.app (install once from the App Store). Read a
red step with its `proves` line in `static/ergopti_plus/macos/data/field_run.json` and
[project-macos-field-run-step-details](docs/memory/macos-hammerspoon.md). Report each line as pass, fail or not run.

Field run, no person needed (read the next report):

- [ ] Owned Ollama starts and pulls: `field_ai_local` ready daemon and a done pull (6170813ea9, 6335790e5a,
      894585a213, b71b4a67db, 4545f672d1, 721074f21d).
- [ ] Test models: one complete Ollama and MLX test-model download on a connection that does not count (e8ff7479e1).
- [ ] Timed reload: `driver_reload` passes and `reload.request_to_boot` is under 4000 ms (b12a654d79, 02c58f8a94,
      c366dd1c5b, c0ba1d98bb, 8121349ee7, e6426e2ec5).
- [ ] Remap guardian: `field_login_items` `developer_adhoc_reregistered` on a Mac that holds an earlier build's
      Background Items record, no `ErgoptiPlus` codesigning kill in `field_app_health`, `guardian_state` ready with
      `guardian_wait` under 10 s, and the same on an Intel Mac (2be257c9f5). Hosted CI proves the ad hoc installed-app
      path on Apple silicon: registration, repeat registration (62eb698420), readback (34888894dd) and retirement pass
      in all five Install-and-launch rows (run 41257389239).
- [ ] Main-thread holds (ledger L16, L17, L18, L23; 0b679b0b0d, b5c0c0de37, c17aa3e5d7, 71a8b87f65, 236ea82e52,
      933707a1ae, 016ef6adc5, 58f82e9fdc, 6c30779ec3): menu rebuild (`field_menu_build` `menu_layout_slowest`,
      `slow_hold_phase`), preferences save (`slow_preferences_save_stage`, `_forks`), keystats append and ledger read
      (`slow_ingest_*`, `worst_hold_site`), healthcheck and ignored-window probe (`slow_diagnostics_collector`,
      `slow_ignored_window_*`), one-off holds (`worst_hold_site`), `keystats_start_ms` under 100 ms. Each names the
      stage to bound next.
- [ ] L24 key events: re-read `key_event_health` totals once the holds are gone (82c220c089); key-ups lost without a
      hold point at the Karabiner virtual HID path.
- [ ] L32 memory: read `memory_footprint_mb`, `memory_region_1..5` and `lua_heap_mb` in `field_app_health`
      (cce99afbc7, 58961fd2b2, f7faaa0558).
- [ ] L42 off the company network: `03_field_network` passes with `pac_download info:unreachable_direct`,
      `pac_script skip:not_fetched`, `route_lookup pass:selected:direct` (5d93e78e90, 1dfaec8298, ec15345d22,
      8fedb505dd).
- [ ] L43: `04_field_toolchain` `karabiner_signature` reads `info strict_only:finder_detritus` (cc172a504d,
      58fd867081).
- [ ] 116: `field_toolchain` third-party report (timer, Shortcuts, Homebrew, Karabiner signature, Gatekeeper).
- [ ] Composer (L52): `06_field_composer` passes after a single re-read.
- [ ] Keystats cache: `field_storage` `keystats_cache_place` is `caches`.
- [ ] Karabiner lease 117/140: `lease_failure_kinds` and `memory_free_percent` (25411ee080, 380ad99aa8); a low free
      percentage next to PONG/READY kinds confirms starvation.
- [ ] Lease deploy write: `deploy_write_verdict` is `keep`; `shrink` means code to write (make the 743 KB file
      smaller).
- [ ] Owned Karabiner runtime: `field_owned_runtime`, then on an owned boot `field_owned_start` and
      `field_owned_pause`; the next run's `field_owned_start` proves close-on-resume.
- [ ] Layout rows: `field_layout_rows` answers M4 to M6 (91725b18f7, fc5d3a11df, aaf3518af7); on `select_refused` or
      `requires_logout` the live path needs the design note's in-bundle route.
- [ ] Apple Shortcuts (106) and the new actions (`run_command`, `open_path`, `run_apple_shortcut`, on dev, not
      field-verified): `field_apple_shortcuts` `field_test_run`. First create a no-op shortcut named
      `Ergopti Field Test` in Shortcuts.
- [ ] PAC unusable on a network whose PAC is unreachable: `field_pac_fallback` `direct_worked` for an Ollama pull and
      the MLX install.
- [ ] Ollama behind a real PAC: `field_ollama_blob_host` and Debug > Test network.
- [ ] Log-only checks of the 2026-10-30 report, each failing by name in `field_slow_lines`: no
      `log_shortcuts_still_unregistered` after a rebind retry (else rebinding needs the `hs.keycodes.map`
      notification); no `log_keystats_database_locked` (8084562373); no `log_lease_bound_failures` nor
      `log_layout_change_before_baseline` (item 38).

Hands needed:

- [ ] Hotstrings (axa): `axa` + Space fast twenty times, also holding `a`: always `AXA`, with
      `Synthetic text moved off a held key` in the day log; ordinary hotstrings in Edge, VS Code and a terminal.
- [ ] oMLX on port 8181 is found in API mode with no `ps` deadlock (`field_local_servers` names it).
- [ ] Gestures: one « Infos… » row that opens the dialog; `tap_3` recommends left click.
- [ ] L46 with no explicit `[gestures.sensitivities]` swipe_3 value (6d3aa65273; `field_gesture_frames`): minutes of
      two-finger scrolls switch no tab; deliberate vertical three-finger swipes (slow, flick, staggered, after a
      scroll, finger resting, ten half a second apart) each switch exactly one tab, past 29 units two; a miss logs
      `Three-finger candidate rejected by <gate>`; no `has no capture timestamp` ERROR after a reload.
- [ ] Ctrl+Caps Lock: type it during a session before the field run; `field_capslock_chord` `never_delivered` drops
      the slot's macOS recommendation with a reason (ea02cf7000).
- [ ] Dropped letters: a day of typing in Safari, TextEdit, Terminal, VS Code and an Electron app, then the field
      report (`swallowed_keys`); Debug > Report a bug right when a letter disappears.
- [ ] Production profile: the same working day feeds `field_boot_cost`, `field_idle_cost` and `field_slow_lines`;
      also three cold starts and one after a login (`Boot complete in`, `Boot CPU`).
- [ ] Event taps refused, personal hotstring reload rolled back, MLX POST routes 404 after a repair, screenshot
      without an image: read the named step or `accessibility_trusted` on the next occurrence.
- [ ] Native ownership contracts with Xcode.app: the launcher XCTest suite, the FSEvents start refusal
      (`macos/infra/file_watchers.lua`), POSIX filesystem capability and ServiceManagement boundaries (hosted CI, run
      41257389239: Launcher XCTest on macOS 26, Native XCTest on macOS 15 Intel, Build and all five Install-and-launch
      rows green for the owned-runtimes Swift and the guardian fixes; a local `swift test` run on full Xcode.app
      remains).
- [ ] Schema v15 and v20 (PAR-41): an old `config.toml` with parameterised slots keeps every action under its role
      id; a v19 file with `ctrl_g = true` opens the ChatGPT URL on Ctrl+G and loses `ctrl_g`, `false` leaves the
      slot empty; old `[llm.profiles] user_profiles` still show (PAR-40).
- [ ] Ten window-toggle actions bound to shortcuts: open, raise when covered, close when frontmost, restore when
      minimised; `open_model_browser` right after a reload and with the AI off logs no `window_toggle` ERROR.
- [ ] Menus: Clear and Restore per category and global; Shortcuts group restore and clear; tap delay row and « Use
      global delay (…) »; tap and hold pickers; « Combinaisons de touches »; row order unchanged (PAR-76 R18);
      « Retirer les anciennes règles » on an upgrade (43); Login Items show one Ergopti (24).
- [ ] Typing: chained expansions, magic key on ISO and ANSI, undo by Backspace, password field, ignored app, no
      wrong erase count (PAR-76 R26); tap-hold rolls; Right Option + Return/Delete/Backspace/Escape; Backspace word
      start (Terminal, TextEdit, Safari Cmd+L); CapsWord cancelled by the pointer (44).
- [ ] AI with a real local model: request floor, explicit shortcut never held, variants, replace in flight, debounce
      "never", live mode; AI off disarms keys and agent actions (PAR-65); tooltip near edges on two displays (111).
- [ ] Network and updates: Debug > Test network on the office network and at home, an `http://` company PAC
      (Issue #101 fixes); release notes pane in light and dark (PAR-52); a Sparkle update; Homebrew live upgrade;
      MLX behind a proxy (119/130/136, code 74).
- [ ] Pages in light and dark (PAR-81); onboarding wizard (7); App Cloner errors (4550befb08); trackpad gestures
      (126), Diagnostics focus (122), shared export (123); reload menu clicks held and replayed; quit while busy ends
      both processes in 10 s.
- [ ] Issue #100 (2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and a PAC proxy, enabling the AI downloads
      the model; the menu held open causes no lease timeout. Issue #99: `memory_pressure` during lease errors, which
      login item starts a second Hammerspoon, declining the download opens no error window.
- [ ] Installed app: guardian registration and retirement on both architectures (13/35), VS Code bridge retirement
      (127), 120 provider menu, issue 94 (tap-hold refusal, symbol-wrap clipboard).
- [ ] App Cloner (81b3cda6a8): on a Mac without the Command Line Tools, Apps > App Cloner offers the install and
      "Install" finishes with no Xcode prompt; clone one app and one PWA, both launch; the PWA launcher shows
      `exec "$CLONE_PYTHON"` on the versionless link; double-clicking App Cloner in Finder shows the localized refusal.
- [ ] VirtualHIDDevice offer (3ebab93a17): on a Mac whose active driver is older than 8.5.0, Tap-holds > update row,
      admin prompt, installer, forceActivate; the report names the new version and the remap reloads; cancelling the
      prompt reports `cancelled` and changes nothing.
- [ ] Run the field report once: its `scpt_recompile` step rebuilds `Encryptor.app/.../main.scpt` from its updated
      `.applescript` (keystats rename) and commits it on the field branch (710f0a379d); cherry-pick that commit.

## To confirm on the Windows PC

Run by the PC agent from a fresh `dev` on a `fix/windows-pc-<date>` branch; push the branch, the coordinator
integrates. Every commit keeps the AHK UTF-8 BOM, reseals a touched updater source and passes the Windows lane
(`gh workflow run ci.yml --ref <branch> -f os_lanes=windows`). Rules and ported work:
[PC handoff](docs/tooling/windows-pc-agent-handoff.md). Order:

1. Parse and run the full AHK suite (`run_all.ahk`, then `e2e/run_e2e.ahk`) and fix what fails. Never executed yet:
   the field run, budgets and LLM latency line (e4ffacc709, 8d52300169), the menu without dynamic rows (eeee484c6c,
   65f298c3f7), thinking off and model capabilities, the per-account provider form and access-token refusal
   (`test_llm_api_url_template.ahk`, `test_llm_api_add_account_address.ahk`), the owned daemon's proxy (743181a933)
   and `vendor/ergopti_route_plan.ps1`.
2. Field report: `powershell -ExecutionPolicy Bypass -File tools/dev/collect-windows-field-report.ps1` (5.1, then
   `pwsh`) with `tools/dev/run-windows-dev.ps1` started, plus the runtime layer of
   `test-windows-field-report-contract.cjs`; this is the first real run of the field run without a click
   (e5315ec576, 29cb604df0, e4ffacc709) and of the report marks.
3. The Windows items of "Remaining code work".
4. The checks below and the [standing checks](docs/tooling/windows-maintainer-checks.md#standing-checks) 1 to 15
   (`node tools/maintainer/windows-live-checks.cjs` runs the automatable ones).

- [ ] Tray > Gestures: one « Infos… » row that opens the dialog.
- [ ] Ollama or oMLX on a non-default port with the process scan failing: still found.
- [ ] `axa` then Space fast, 20 times: always `AXA`.
- [ ] Personal `sru` -> `SRU` (priority 100) beats the bundled `sru` -> `sur` (4741950f04); a hotstring with `{left}`
      moves the caret.
- [ ] Live Ollama: token-by-token predictions display, then enable the row (PAR-12).
- [ ] System Ollama on 11434, AI on: Ergopti's listens on 11435, the other is untouched (f016081056, 597cbbe983).
- [ ] Item 50: `fb` + Space, Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and
      not.
- [ ] Composed layout on a real keyboard (Debug > "Test the composed layout").
- [ ] api.github.com blocked: the update check's Atom fallback reports the version.
- [ ] "Create a GitHub issue" signed in opens the form with no "Whoops" page (4e63c54c8a).
- [ ] Updater: install a build with 5d6beccf83, update: the exe restarts, the three scripts are in
      `%LOCALAPPDATA%\Ergopti\vendor\`, the command line shows `-File`, no `-EncodedCommand`.
- [ ] Developer mode: `tools\dev\run-windows-dev.ps1` with the exe running closes the exe, the tray appears, saving
      an `.ahk` reloads once; `npm run dev:windows` from Git Bash and cmd; double-click `ErgoptiPlus.ahk` with and
      without the exe (expected lines in `docs/design/developer-mode.md`).
- [ ] Ten window-toggle actions, also without WebView2 (native fallbacks): no orphan WebView2 process.
- [ ] Manual steps 1 to 4 of [windows-maintainer-checks.md](docs/tooling/windows-maintainer-checks.md) (Win+S,
      Backspace word start, Versions Retry, pair popup).
- [ ] Brightness joined source; retired Metrics shortcuts across a three-OS full save and an installed upgrade (63,
      71).
- [ ] Corporate network (item 62; 1d15b51e66, 7c001b2456): Debug > diagnostics (`github_api`, `proxy_pac`), a model
      pull behind a PAC (and with the PAC unreachable, d20d328751), the Windows security warning for the native CA
      case, Kerberos, TLS inspection and revocation.
- [ ] Item 49: the terminal-capture hardware list. Item 91: held-alone-then-joined order, AltGr hook provenance.

Account and tester actions (maintainer, from the PC):

- [ ] SignPath application ([answers](docs/tooling/signpath-foundation-application.md)), then its variables and
      secrets (132).
- [ ] Update-signing key ([five steps](docs/tooling/update-signing.md)), one release with `off`, then `required`
      (PAR-30, fe5a1c2340).
- [ ] VirusTotal lookup, Microsoft Defender and vendor submissions
      ([pack](docs/tooling/windows-exe-false-positive-submission-pack.md)).
- [ ] Testers: Netskope tester's download retry, T1-T4 ([matrix](docs/tooling/windows-exe-flagged-by-proxy.md));
      number-row, key-combination (c89d74eb) and priority-100 (cf29c35e5f) testers with their exact setup.
- [ ] `/retest` on AppImage/appimage.github.io#10422 from PowerShell, then read the bot's screenshot (98d41e630b).
- [ ] Key chords, first: assign a « Chord (simultaneous) » slot and check that it fires and that both orders follow the
      symmetry setting (the harness never reached the wait path); then rolling text with a chord on Space, AltGr alone
      and real LCtrl+AltGr on AZERTY, SC138 and AltGr characters on Kana, and a tap-hold key held during an expansion.
- [ ] Win+S, Win+E, Win+H and Ctrl+B on a real keyboard (Ctrl+B now runs `microsoft_bold`).
- [ ] Hold LCtrl through Ctrl+Alt+Del or UAC, come back, press AltGr: it stays AltGr. Confirm raw 0x21D in the log for an
      AltGr press: it unblocks the `left_ctrl` + `alt_gr` pair and the terminal recipe alias.
- [ ] Sticky keys, `run_command` in a console, `open_path` through both pickers, the vision backend list, and a real
      vLLM on port 8000.
- [ ] Decide: squash the old steps of `migrations.toml` (recommended, it would cut most remaining config test time) and
      whether a registry change seen only at the sweep's next capture is acceptable.
- [ ] Review the machine translations of 1 November (curl, proxy, token exchange, WebView2, chord and case-twin keys).

## To confirm on Linux

No machine is available. First `bash tools/dev/collect-linux-field-report.sh` on a real desktop: the field run
without a click (53c1766514), the report marks, and `driver_reload` (one daemon restart under a real user manager).

- [ ] Physical acceptance: evdev/uinput grabs, polkit, autostart, Wayland and X11; wizard (7) on Wayland; magic key
      grab, injection and hotplug (30); real kernel capture (93: ordered pairs need Xorg or a compositor on real
      evdev nodes).
- [ ] Gestures: a three-finger pad and one `libinput record` from a real touchpad (d627f511fc, 1870e62e1a,
      `linux/HARDWARE.md` section 13); a two-finger scroll with a thumb resting reports two fingers, a brisk
      three-finger tap still reports `tap_3`.
- [ ] Navigation layer wheel bindings with a real mouse (ea4b3fa600).
- [ ] Secret service: add a key with the keyring locked, the unlock prompt takes the keyboard under the grab; restart
      and check the plaintext `api_keys.json` migration (e93a4f7368, 939c0f60).
- [ ] Owned Ollama: with `ollama serve` on 11434, enabling the AI starts Ergopti's on 11435 (32fa07be7f).
- [ ] PAC unreachable: an Ollama pull logs the WARNING then the direct success (50b424b997, afc7fa23db).
- [ ] Item 50 cascade and the composed layout typed on a physical keyboard.
- [ ] Layout emulation W1 to W4 of `docs/design/layout-option-emulation.md` on real GNOME and KDE sessions
      (dbe176e52b, 9b0a205029, dfb197a1ea), including mutter and KWin reloading a `~/.config/xkb` layout (107).
- [ ] Developer mode with the package installed: `run-linux-dev.sh` stops the unit, the tray appears, a saved `.lua`
      and the tray's Reload restart the daemon, a second run reports "already running".
- [ ] Ten window-toggle actions on GNOME Wayland and X11 (a covered page is raised, not closed); release notes pane
      (PAR-52); tap delay row and every tray dialog in the owned GTK host (ca680655d7), group restore and clear, open target, Backspace word start.
- [ ] Some `local_servers.json` servers installed: the detection names them.

## Remaining code work

### Windows (the PC agent's)

State on 2026-11-01. Whole AHK suite at d85a24eb53: 17277/17288 in parallel, the other 11 (clipboard and focus contention
between workers) green alone. All live checks pass, typed by the harness.

- **LLM.** Windows has a production `retry_extra_tokens` owner and regression tests; the outstanding parity gap is Linux sequential retry/refill behavior (see the platform audit). Real IBM and Google token services were never tried.
- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the
  keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left, the rest of the menu files need
  `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers and sleeps
  before the registry loads. PAR-83: the host in `ollama_managed_files.ps1`. Moving `tests/run_*.ahk` to
  `tests/runners/` is not worth it (455 `A_ScriptDir` uses, 1,908 includes).
- **Tests.** Source assertions left to convert to behaviour; `--reverse` on the `llm` group has 3 order-dependent reds.
- **Proxy override.** `_NetworkCheck_FetchPac` and the COM WinHttp use of `api_remote.ahk:603` are not checked against the
  override; `SystemProxy_IsLoopbackUrl` knows only named loopback hosts.
- **Field report.** `field/win-2026-11-01-dev` ran with no driver; run it again with one.
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Hotstring word start, follow-ups of 4a91f19d1c.** The preview bubble still finds the typed word with the old
  boundary list (`hotstring_match.ahk`); move it to `_HSE_CharOpensWord`. The boundary check rebuilds its list on
  every call (about 30 µs per key); build it once per delimiter change.
- **Older findings.** The seven "Remaining findings" of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36 updater production coupling (the
  first trusted PowerShell host acquisition); a408a29790 (the four longest AHK unit shards split) was never landed.

### macOS

- **Field report 2026-11-03 (`mac-2026-11-03_102716`), branch `fix/macos-field-2026-11-03`.** Done: ai_local no
  longer lists the owned endpoint without its binary (no ERROR); n-gram history merges paced (458 ms slice); the
  dashboard no longer resends an unchanged history each live update (250 ms holds, +73 MB heap per minute). Already on
  dev: blob Range redirect (e6942d05c2), diagnostics phase A (e76a5443f8), post-wake AX hold (1f2884f13c), owned
  Ollama Go test enrolment (627bfad0af). Next: Karabiner regeneration is synchronous (merge 170 ms, layout actions
  230 ms cold: event_taps `runloop_late_ms` 294); keystats start runs `ioreg -d2` (151 ms) on the main thread at
  boot+1 s; the first menu build forks two `find` (44 ms; three menu_apps tests are built on find output).
- **Next release after 1.0.9, maintainer priority: switch the driver to the owned Karabiner.** Today the driver still uses
  the installed one and the owned runtime is dormant. The runtime is published and pinned; WP8, WP9 and the real-Mac
  acceptance of item 31 below come next, then `runtime = "owned"` becomes the default.
- **One folder name for Ergopti on the three OS (maintainer, 3 November).** macOS has three folders in Application
  Support: `ErgoptiPlus` (paths.toml, runtime, locks, karabiner.json), `Ergopti` (managed Ollama, embedded Python, MLX)
  and `ergopti_plus` (the local reload control); Windows mixes `%LOCALAPPDATA%\ergopti_plus` and `Ergopti\bundle`, and
  the config, logs and caches use other spellings. Decided: `Ergopti` on macOS and Windows, `ergopti` under XDG on Linux,
  no "Plus" in folder names; put each driver's data under one root, name it once in the shared identifiers, and migrate
  the old folders once at boot with a backup. Branch `next/one-folder-name` (handoff:
  `docs/tooling/one-folder-name-handoff.md`).
  - Done: one root per OS in `_shared/modules/paths/app_dirs.toml` (generated for Lua, AHK and Swift; Node reads it
    through `tools/test/lib/app-dirs.cjs`, Python through `tools/diagnostics/macos_app_dirs.py` or the TOML); the
    three drivers, their tests, the collectors, the reload CLI, the cask zap list, the docs, the skills and the release
    notes use it; the boot migration moves the old folders, renames an entry whose destination is taken into
    `<root>/before-folder-migration/`, removes the emptied old folders and backs up a rewritten paths.toml; shared
    vectors replayed on the three drivers; the gate `tools/test/test-legacy-folder-names.cjs`.
  - In progress: CI on the branch (Swift and the full Lua suites only run there).
  - Next: merge into dev after a green CI and the maintainer's go-ahead; the maintainer checks his machines (handoff
    list); delete the migration once they are moved; rename the owned Karabiner runtime folder (`ErgoptiPlus`) with its
    next rebuild (item 31). The managed Ollama runtime moved inside the root (`%LOCALAPPDATA%\Ergopti\ollama`,
    maintainer decision, 4 November).
- **31. Owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
  [handoff](docs/tooling/next-release-handoff.md)). Status on 4 November, all on `dev`:
  - Done: the owned runtime is the default (`RUNTIME_DEFAULT = "owned"`, the two Configuration rows and
    `remap_switch.lua` gone). Runtime `16.3.0-ergopti.3` published (prerelease `remap-runtime-v16.3.0-ergopti.3`,
    downloaded back: sha256 `eced1bfd…dc4567`, 12351916 bytes) and pinned; its hosted sudo install acceptance passed on
    macos-15, macos-15-intel and macos-26 (Remap runtime build run 41895547018: files, Core and VirtualHIDDevice jobs
    loaded, pqrs' package installed in the same shell, stage retired). The install is offered once by itself (one
    confirmation, one administrator prompt), the driver approval pane opens and is watched, the Tap-Holds row retries;
    the field run and the collector (`--installed`) report every install fact.
  - Decided: field-tested on the CI-signed dev build, never the ad hoc developer app; no Developer ID for now (item
    below).
  - Next: the maintainer's WP9 pass (handoff checklist) once a signed dev build is authorized, then the shared-mode
    deletion. Done on 1 November: the per-OS feature requirements table (`docs/design/feature-requirements.md`) and
    the driver-only VirtualHIDDevice update offer (3ebab93a17).
- **Owned runtime with a Developer ID (maintainer: not now, 2026-11-04).** With the self-signed CI certificate the
  install takes one administrator prompt (the root Core and pqrs' daemon are LaunchDaemons bootstrapped by the
  helper), Login Items lists them as separate « unidentified developer » rows, and the driver approval names pqrs'
  extension. A Developer ID would allow: `SMAppService.daemon` for both jobs from `Contents/Library/LaunchDaemons`
  (no password, one « Ergopti » Login Items group; launchd kills SMAppService jobs of a bundle with no Team ID,
  `RemapLeaseGuardian.swift`), and an Ergopti-signed DriverKit extension in `Contents/Library/SystemExtensions`
  activated with `OSSystemExtensionRequest` (needs Apple's DriverKit HID entitlements for the team). The root Core
  keeps its own Input Monitoring row either way: launchd starts it, not Ergopti.
- **Owned runtimes.** The rows in state "to do" of `_shared/data/owned_runtimes.json` are all item 31 (shared
  Karabiner app, owned runtime, VirtualHIDDevice). The Swift-owned managed daemon under the proxy relay needs a short
  design note first (who launches the relay, how its refusal receipt reaches the Swift owner; Swift and Go). Done on 1
  November: App Cloner on the managed Python with pinned PyObjC 12.1 (managed-pyobjc.json, ensure-managed-pyobjc.sh
  under the native PTY guardian, consent offer from the Apps menu, stable link `native-bootstrap/app-cloner/python3`;
  existing clones keep /usr/bin/python3 until re-cloned).
- **Proxy variables in `network-retry.sh`.** Four hand-typed spellings of the proxy variables now live there (the
  direct override and the refused sign-in start, 3597ee4f, among them); `test-proxy-policy-single-source` allows 4.
  Factor one `clear_proxy_environment()` both paths call, then lower the allowance.
- **Checks left to a program from the Mac session.** Done on 1 November: `field_tap_hold_thresholds` (9901da4d94;
  PAR-15 is confirmed by the next field run's result);
  the HTTPS downgrade refusal is already covered by `ManagedPACSourceTests` and `ManagedBootstrapDownloadTests`.

### All drivers

- **Test parity (audit item 14).** Done on 1 November for the `init.lua` gates (boot scenarios), the dedup test,
  the `managed_http` group and most Linux source invariants (`helpers.read_driver_unit`). Left: whole-tree class scans
  (legitimate meta tests) and the sliced-source compile tests (archive_output tar feeder).
- **Provider flags inferred, not read.** Checked against the docs on 1 November (90344262aa): Featherless and
  Qianfan confirmed; left: SambaNova toggle unverified (its docs answer 403 to automated reads), Chutes Qwen field
  inferred; watch Perplexity Sonar chat completions (ended
  2026-09-27), `dashscope-intl`, Moonshot K2 retiring by December.
- **Linux: scalable three-finger swipes (maintainer, 3 November).** macOS steps tab_next / tab_prev with the swipe's
  distance (mode "incremental"); the Linux gesture manager acts once, when the swipe ends, and has no per-slot mode, so
  a long swipe moves one tab. Its evdev decoder sees the travel, so it could count steps at the end of the swipe (live
  stepping would need a new path in `linux/modules/gestures/manager.lua`). Not small: the mode settings, their menu
  rows and the step accounting are macOS-only today. Linux recommends no swipe anyway (the desktop acts on them), so
  this is for users who bind one.
- **Tooling found on the way (4 November).** `tools/ci/seal-windows-updater-original-source.cjs --write` leaves
  about 90 MB in the temp folder per run; remove it on exit. On the Windows PC these fail on a clean `dev` for
  environment reasons, so only CI proves them: `test-site-github-release` and the site deploy admission controls
  ("file changed before capture"), `test-keylayout-row-options` (different Lua keyboard ids),
  `test-linux-field-report-contract` (setup error), `test-menu-manifest` in a worktree (a `node_modules` junction
  copy fails with `EPERM`). Make each one pass locally or skip with a stated reason.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins
  of a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods` (macOS capture is item 31's).

## CI acceptance

Each closes on a named green hosted or native run, recorded here.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E, packaging,
      installation, launch) with exact receipts; it also carries the first hosted run of: the Linux X11 window list
      (962a25a973), AppImage Build and `install-linux` rows (dce846a0bd), the Linux per-step installs (17e80f2882),
      "Qualify the installed managed Ollama route plan" (c0a50b5e41), the Linux private runtime in every package,
      and the run-timing summary (`run-timing.cjs --step-summary`; Flatpak under 5 min).
      Initial audit preflight [42099804561](https://github.com/adrienm7/ergopti/actions/runs/42099804561) failed Arch native server detection, shared UI browser installation and macOS stubbed replay. Follow-up [42108198520](https://github.com/adrienm7/ergopti/actions/runs/42108198520) at `4ca161c3e512eecc4c78499db0465139c9a71861` is green: 114 successful jobs, with only Release / Publish skipped; Arch integration, shared UI rendering and all OS verdicts passed. Later dead-key preflight [42121216727](https://github.com/adrienm7/ergopti/actions/runs/42121216727), at `04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9`, failed Common / Install and launch (Stable site) at Install production site browsers, followed by its mandatory verdicts. Requalify that browser installation and the final source checkpoint; no successful browser/render receipt follows from the failed step. Hosted results remain separate from physical dead-key receiving.
- [ ] **macOS lane.** L32 and L42 Swift in the Build stage; the Issue #101
      Swift and Go cells; native qualification of the Hotstrings category boot publication and the obsolete-leaf
      setters; item 31's lane once its runtime build is green. Already green (run 41257389239): Launcher XCTest,
      Native XCTest (Intel), Build and all five Install-and-launch rows, guardian fixes included; macOS Unit,
      Integration and every E2E cell on run 41261068581.
- [ ] **Ollama Go cell** (cda1e10c5e) on the final source before a release (passed on run 40021624397).
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy denial, Brew
      archive scenarios; Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package); dynamic
      hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native macOS delimiter transactions; macOS packaging with both extension TOML files;
      Windows native cases and Fedora/Alpine ShellRunner fixtures (Linux done in the start-up E2E).
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification on macOS and Windows; provider published before
      model loading on macOS (Linux done).
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture receipts; daemon-report
      allocation failures on Intel and Apple silicon.
- [ ] **First `main` push after 1.0.9.** CodeQL scans `main` only: the 32 alerts fixed on dev on 4 November
      (a3d69950e5..89b0b774c8) close only once that scan accepts the fixes.
- [ ] **Deploy site after a superseded push.** A `main` push that a newer one passes before its site deploys fails
      red ("target branch no longer names the admitted source"). The quiet skip (bc14746520) was reverted: the closed
      publication chain of `test-ci-pipeline-wiring` forbids conditional jobs and steps. Decide whether that contract
      may allow one admitted skip output, or keep the refusal visible.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a non-empty analysis.
- [ ] **Native Windows TLS fixture.** `X509Store.Add` on the CurrentUser root store blocks on the Windows security
      warning (`docs/memory/windows-ahk.md`), so these cases need a click; hosted lanes pass in LocalMachine scope.
- [x] **Full Windows AHK suite.** Done on 2026-11-01 at d85a24eb53 with `npm run test:ahk-parallel`: 17277/17288 in
      parallel, the 11 others (clipboard and focus contention between workers) green alone.
- [ ] **Intermittent fixtures.** Close each after it stays green: Linux window switch, cffi-lua clone, desktop-webview
      AI focus, Windows `config` group, macOS Go `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`.

## Maintainer decisions pending

- [ ] Define "the read-only dashboard with a hot journal" (which dashboard opens which database read-only, and
      which journal is hot: a rollback `-journal` left by an interrupted keystats write, or a WAL?) so a program can
      check it.

- **PAC list walk on macOS and Windows.** Linux probes a `PROXY a; DIRECT` list before the Ollama start
  (`llm.managed_proxy_probe_timeout_ms`); the decision named Linux only, so macOS
  (`resolve_system_route_for_probe`) and Windows still export the first entry. Default meanwhile: first entry.
