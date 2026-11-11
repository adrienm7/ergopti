<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-11-07. Latest stable: [v1.0.8](https://github.com/adrienm7/ergopti/releases/tag/v1.0.8).
This file shrinks toward deletion after the next field reports: each machine section is one line per check, naming
the field-run step or the hand action that proves it and the commits it confirms. Conventions and tags:
[workflow and verification memory](docs/memory/workflow-and-verification.md). Finished items are in Git
(`git show 2a0083cb11:TODO.md` is the long form before this shrink).

## Windows CI reliability (2026-11-07)

- [x] **[CODE] Boot counts 2 more TOML parses than on 2026-11-05:** the boot log's "Document parses by owner"
      record named them: the typed personal_info.toml read (ad8268b7da, kept, ceiling 15) and an absent override
      file parsed as an empty document (3e25e5d71c, no longer parsed). The extra registry compare is 424b4a26d8's
      boot-tail snapshot proof (kept, ceiling 14).
- [x] **[TEST] layout-row-external-native-flags (released):** the receipt showed a test-side race: the receiving
      keydown carried Shift (receipt Shift=1) and the sender passed, but the receiver's own translation ran under
      the later state and wrote « q ». The probe now checks the character that keydown types under its own state.
- [x] **[TEST] llm-debounce-password-source-privacy (plain-stays):** the rolling context once lacked one unit
      (« cnary »). The `LLM_DEBOUNCE_BUFFER_GAP` trace of a second failure (« allowed_cotext_b_canaryn ») showed
      the 11th callback entering at 10 units and completing last: a later callback overtook it. A real Windows
      bug on the dispatcher path, which left Critical before its append and dropped the overtaken character,
      and a test-side race in the probe's own callback; both now serialize from admission (0aae34e00c).
- [ ] **[TEST] Windows compiled upgrade (Install and launch):** run 42480459552 (39b55d78ff) failed at the
      `upgrade` step: the current exe, booted on the profile v1.0.0 installed, did not exit successfully. It last
      passed on fb2059e00e; the exe changes since are the dev channel core (5427b56b49) and the LLM dispatcher
      serialization (0aae34e00c). 36805b170a keeps the exit code, the launch streams and the startup logs in
      `windows-compiled-upgrade-evidence/failure-diagnostics`: read them on the next failure.
      Read on run 42619305563 attempt 1 (4c809ea0fb, 2026-11-09; attempt 2 passed): the upgraded exe reached
      « Driver fully initialised — ready », logged « [HttpClient] Curl child termination was refused »
      0.5 s later, then exited non-zero with empty stdout and stderr. Lead: a curl
      child still running when the smoke quits makes the exit fail; check how the quit path settles an in-flight
      HttpClient request and why its termination is refused.
- [ ] **[MACOS] Issue #106, owned Karabiner runtime not admitted (Clem, dev.166, macOS 27.3; the maintainer's
      Mac too):** rules stay fail-closed. The misleading « lease auto-recovery exhausted » error is gone (the
      recovery stops while the runtime waits for admission), and the installer helper refusal now names its cause
      (`helper_signature_invalid`, `helper_signature`, `helper_code_hashes`). The helper of
      `remap-runtime-v16.3.0-ergopti.3` and the dev.166 launcher carry the same leaf (759d8aae…), so the leaf is not
      the cause. Next: the `remap.runtime_owner` lines (« unavailable: <reason> ») and `launcher.log` « owned runtime
      install: refused (…) » of a build with these fixes.
- [ ] **[RELEASE] Dev naming handoff:** everything is on `dev`. `v0.0.0-dev.169` is the bridge (ci.yml keeps the
      legacy core up to counter 169), then `v1.0.10-dev.170`; the next merge to `main` carries
      `Release-As: 1.0.10`. Delete the orphan draft `v0.0.0-dev.167` by hand (this session cannot delete releases).
- [x] **[TEST] LLM debounce privacy probes:** the trace showed a real Windows bug: a late key-down of the last
      typed letter cancelled the debounce its character had just armed (66afcf12e3). Fixed by 679e279d19.

## Layout generator from an Ergopti TOML source (maintainer request, 2026-11-06)

Large project: an Ergopti equivalent of [kalamine](https://github.com/OneDeadKey/kalamine), going further. Take
ideas from kalamine and KbdEdit, never their code: write every generator from the formats' own documentation, so
that no MIT notice has to ship.

Decided 2026-11-06: the source of truth is an Ergopti layout file in TOML, a superset of every target. A macOS
`.keylayout` cannot hold extra modifiers (Kana, Roya, Loya, a held key as a layer), lock layers other than Caps
Lock, physical key remapping, shortcuts that send another key than the typed character (Ctrl+A giving Ctrl+B),
KbdEdit's special functions and Windows flags, export settings, nor Ergopti's own features (tap-hold, emulated
layers). The `.keylayout` stays a first-class format: imported without loss and exported. No custom element goes
into an exported `.keylayout`, since macOS may refuse to load it.

- [ ] **The TOML format.** Specify it (schema, version field, comments allowed): layers and modifiers including
      user-defined ones, held or locked, per-key Caps Lock mode, dead keys with chaining and multi-character
      results, ligatures, physical remapping, per-modifier alternative keys, key names, ISO base and ANSI rule,
      export metadata. Lossless round trip `.keylayout` → TOML → `.keylayout` for everything the `.keylayout` holds.
      Foundation implemented: [TOML v1 interchange](docs/design/layout-source-format.md), strict structural validation and `tools/layout-source.cjs` preserve imported XML exactly, including unmodelled constructs. Edited mappings and new layouts still need compilers; the source model is not yet the unified editor or a driver input.
- [ ] **One generator, every target.** From the TOML, generate the macOS bundle, the Linux XKB files, the Windows
      `.klc` plus the keyboard DLL and its unsigned installer, the AutoHotkey emulation tables, the Hammerspoon and
      Linux emulation tables, and the web emulation used by the site and the composer. Each export reports per
      target what is native, emulated by the ErgoptiPlus driver, or impossible; nothing is dropped silently. Reuse
      the existing bricks: `static/ergopti/linux/xkb_generation/keylayout_to_xkb.py`,
      `_shared/lua/layouts/composer.lua` and `composer_check` (whose `composition.json` beside `composed.keylayout`
      already shows the superset idea), `_shared/ui/layout_composer/`, the composer corpus vectors, and the Windows
      installer from `layout/windows-klc-installer`. Each target gets a golden-vector test against the same corpus.
      Linux milestone implemented: `tools/layout-source.cjs export-xkb` exports admitted unchanged imports into a new directory with XKB symbols/types, XCompose and `export.json`. Its report names actual modifier/output losses and always marks this projection partial; unsupported constructs refuse before writing. macOS bundles, edited mappings and native driver loading remain open.
      Windows milestone implemented: `tools/layout-source.cjs export-klc` reuses the existing Windows generator for admitted unchanged imports and writes a UTF-16LE `.klc` plus `export.json` into a new directory. The report names Ctrl/Command, system-key and virtual-key limits; unsupported Caps/dead-key/Unicode constructs refuse before writing. Native DLL compilation, installation and loading remain open.
- [ ] **Two uses of one source.** (1) The TOML source generates a standalone installable layout per OS that never
      assumes ErgoptiPlus is installed: it carries as many features as that OS expresses natively (macOS bundle,
      Linux XKB with its extra levels and dead keys, Windows DLL and installer), and the export says what was left
      out and why. (2) ErgoptiPlus loads the TOML source itself, not a per-OS file: it detects the OS, enables
      every feature that OS allows, natively or by emulation, and says which ones it cannot offer.
- [ ] **macOS export: bundle by default, ISO and ANSI.** A macOS layout can be one `.keylayout` file, but the
      default export is a `.bundle` holding both physical variants, ISO and ANSI (as `Ergopti_v2.2.0.bundle` does
      today). The export dialog has a drop-down: « Bundle ISO + ANSI » (default), « ISO only » or « ANSI only », the
      last two giving a single `.keylayout`. Decided 2026-11-06: the user edits the ISO layout; the ANSI variant is
      derived by a fixed rule that moves the extra ISO key, and the editor can change where that key goes.
- [ ] **KbdEdit parity, or better.** The editor offers every KbdEdit capability (extra modifier levels such as Kana,
      Ctrl/Alt shortcuts that send another key than the typed character, Caps Lock modes, chained dead keys and
      compose, ligatures, numpad and media keys, key remapping, sticker printing, Unicode palette, live preview),
      for free and on all three OS. Inventory and design:
      [layout-generator-kbdedit-parity.md](docs/design/layout-generator-kbdedit-parity.md).
- [ ] **One layout editor, not three.** Decided 2026-11-06: the generator's editor is built by unifying the editors
      that already exist, never as a new parallel one: the navigation layer editor (`_shared/ui/layer_editor`, whose
      model already reads and writes a TOML file with per-OS sections), the per-layer layout composer
      (`_shared/ui/layout_composer`, which compiles a `.keylayout`) and the layout manager window that hosts it
      (`_shared/ui/layout_manager`). One shared model and one page edit every layer, the navigation layer included,
      and save the Ergopti TOML source; improve the navigation layer editor's UI on the way and retire the duplicates.
- [ ] **Layout editor on the Svelte site.** A new tab where a user configures their own layout, opens or saves the
      Ergopti TOML, imports a `.keylayout`, and downloads every generated target.
- [ ] **The same UI inside ErgoptiPlus.** The editor page runs locally in the app's webview on Windows, macOS and
      Linux. It installs or emulates the result and switches to it from the menu.

## Parity audit pause and resumption

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
records the focused campaigns already completed, broader reviews, exact limits
and the next module candidates. The audit is paused at the maintainer's request.

- [ ] **[CODE] Parity audit continuation:** on resumption, reconcile current source areas with the linked coverage register, then deepen tap-holds/chords/layers as one bounded module across Windows/macOS/Linux/shared before moving to another. Keep native receiving and implementation of existing finding IDs separate; do not restart completed focused campaigns without source drift or a new hypothesis.
      Progress (10 November 2026, [tap-hold campaign](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): census reconciled (375 areas, 12 new and 206 changed since the last pinned census, still to review outside tap-holds). Fixed on Linux/shared: LAlt's Tab tap with no hold is tap-only (THL-001), the Alt-Tab and RCtrl Tab taps keep their strict threshold (THL-002), a pair starts from the earliest held first key (THL-003), a pair's release tap respects the decided tap minimum (THL-004), chord defaults pinned across drivers (THS-001). Decisions pending: THD-1, THD-3, THD-4 (pair tap and the layer, layer-hold pair activity, macOS thumb Backspace under modifiers) and THD-2's lone window. Minimum tap (decided 2026-11-10): Linux complete; macOS needs a Karabiner mechanism qualified on a Mac (`to_if_alone` has no minimum); Windows is the maintainer's change. Left: the report's Linux and macOS remaining rows; native receiving unqualified. Next module after this one: hotstring cascade.
      macOS minimum tap (11 November 2026): done in the generator. Each release-judged tap, a pair's included, is gated on a lease-scoped variable a `to_delayed_action` raises after `tap_hold.tap_min_duration_ms` (Karabiner v16 evaluates a to-event's own conditions when it posts it); the rollover keys keep no minimum, as the Linux roll keys. Generator test `test_generator_tap_minimum.lua`, corpus vectors without their macOS divergence; native timing under « To confirm on the Mac ».

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
- [x] **[CODE] DKS-001 — shared/Linux:** avoid inherited locale descendants shadowing an explicit shorter Compose terminal in both converters. Require actual native COMPOSED ₢ for Bépo monnaie+cedille; retain locale/no-include/private-trigger controls. Private-trigger probe is not a proposed production fix.
      Done: both converters read the libX11 locale prefixes pinned in `key_sym.json` (`locale_extended_prefixes`) and give the dead key starting a written terminal the locale extends a borrowed trigger, re-running until none is shadowed; only Bépo's monnaie moves (the shipped Ergopti files are unchanged). Regressions: native libxkbcommon COMPOSED ₢ with the locale included, locale-shadowing and no-include controls, every Bépo terminal completing, and the Lua contract. Other libX11 versions are covered only as far as the pinned list matches them.
- [x] **[CODE] Magic conversion:** decide and document the eight known Plus/PlusANSI pending-state Magic contexts at level 1 before claiming equivalent state-aware output; retain all six registry checks and native explicit-rule comparisons, without counting eight additional roots.
      Done (decision 2026-11-06, macOS output everywhere): both XKB converters end the magic key's dead-state sequences on ★ too, the builtin Windows tables take the missing ★ continuations from the Ergopti+ .keylayout, and four shared keystroke vectors pin j/ξ/ʲ/ⱼ. AHK not executed on the Linux authoring host.
- [x] **[CODE] Dead-key lifecycle:** define unmapped fallback, expiry/pause and modified-control replay contracts across legacy Windows, registry Windows, native macOS and Linux Compose. Extend existing OSW-001 conditional replay regression to legacy DeadKey; do not call modifier loss intentional. Qualify native cancelled-state policy, macOS grouped payloads, AHK/HKL and real Linux desktop receiving. Keep current per-engine behavior until a common contract is approved. Latency, RSS and long-session memory watchlist remain unmeasured.
      Done (decision 2026-11-06): Linux Compose tables carry the terminator-then-key fallback; legacy Windows expiry and both Windows engines' pause cancel the pending dead key; the legacy DeadKey control replay keeps its captured modifiers (source guards, AHK not executed here). Still open: macOS and Linux pending composition is native state Ergopti's pause does not cancel; native receiving (AHK/HKL, desktop Compose, macOS grouped payloads) stays unqualified, as do latency and memory.

## Cross-platform feature inventory

- [x] **Dynamic hotstrings:** align or explicitly document the Windows `@td★` / `@dt★` / `@date★` date vocabulary versus bare Lua triggers and their boundary rules. Linux's shortest phone prefix must wait for the magic key, as Windows/macOS do; normalize the international phone output consistently (the Lua drivers currently keep the national zero after +33). Reproduce with the [module audit probe](docs/audits/platform-parity/2026-11-04/hotstrings.md). Progress: macOS drops the trunk zero after +33; the Linux phone fixes are on `fix/linux`; the date vocabulary awaits a product decision (`observed_not_decided`). Done (6 November 2026): Windows uses the bare `td★`/`dt★`/`date★` triggers with the shared word-start rule, and its +33 form drops only a leading 0, as macOS and Linux do.
- [x] **Linux AI:** implement bounded retries for failed/empty predictions and refill after deduplication, with the shared retry token/temperature policy. Windows already has `retry_extra_tokens`; remove obsolete claims that it has no owner. See [AI evidence](docs/audits/platform-parity/2026-11-04/llm.md). Done: sequential variants spend the shared max_multiplier budget, refill after duplicates and retry failed/empty calls with the policy's extra tokens and temperature; the stale Windows claim was already removed. Follow-up (6 November 2026): a refused credential (HTTP 401/403, missing or invalid key) is never retried on any OS, through one shared classification.
- [x] **Linux metrics:** implement durable per-device append-only ledger export/import/replay for cross-device metrics. Export done: `linux/modules/keystats/metrics_ledger.lua` projects the committed raw rows of metrics.sqlite to `metrics/by_device/<id>/{device.json,data.sql}` in the macOS/Windows format (macOS scanner pinned by `test_linux_ledger_admission`). Left: importing the other devices' ledgers into metrics.sqlite and rebuilding their aggregates. Every Linux dashboard reads aggregates only, so a raw import alone would show nothing: the import must land with a per-device derived rebuild (the shared walker over foreign events*json, app/system/hotstring/LLM day rows) in the same change. A foreign data.sql runs in the local store, so the importer must admit only `INSERT OR IGNORE INTO events*\*` tuples of literals carrying the folder's own device_id (no subquery, ATTACH or function call), and keep the macOS watermark contract (`devices.imported*data_sql_size`plus the SHA-256 of that prefix, a replaced generation replayed from byte 0). A Windows reader replay of a Linux ledger is unverified (no AHK runner here). Do not advertise schema compatibility as synchronization. Done:`linux/modules/keystats/ledger_import.lua`imports every other folder of`by_device/`from the daemon tick once the own export is idle (rescanning at the ingest cadence, as macOS does): each statement is parsed and re-rendered from its literals (only`INSERT OR IGNORE INTO events*\*`with schema columns and the folder's own device_id, plus the BEGIN/COMMIT/PRAGMA framing), the raw slice, the watermark (size and SHA-256 of the applied prefix, a mismatched prefix replayed from byte 0) and a pending mark commit together, and once the device is caught up`ledger_rebuild.lua`rebuilds its aggregates through the shared walker and clears the mark in one transaction; work per tick is bounded (streaming SHA-256 keeps a verified prefix while the file is unchanged). Regression`test_ledger_import`. A Windows reader replay of a Linux ledger stays unverified (no AHK runner).
- [x] **Software trigger metrics on all three drivers.** macOS and Linux now record the Windows `roi_snapshot`,
      `new_trigger_candidate` and `trigger_halflife` families through the shared Lua ROI owner and `events.roi`
      SQL projection, including accepted private-expansion savings without retaining private trigger identities.
      Physical words require an admitted app/window, exclude known triggers and stop at privacy, focus, mouse-click
      or synthetic-output boundaries; counts and savings survive capture pauses. The native Windows casing
      projection is qualified for AutoHotkey 2.0.26, Windows 10.0.26100, language 0409 (1,488 scalar vectors plus
      three contextual vectors); it does not change general Unicode conversion. SQLite and device-ledger
      export/import preserve the raw events idempotently. These are collectors and durable events: no new ROI,
      candidate or half-life dashboard panel is claimed. Shared corpus: `_shared/tests/corpus/keystats/trigger_roi.lua`;
      driver regressions: Linux `test_trigger_roi.lua`, macOS `test_trigger_roi_callbacks.lua` and
      `test_trigger_roi_sql.lua`; native casing receipts are linked by `_shared/data/keystats_roi_lowercase.json`.
- [x] **ROI text and metrics encryption.** Windows, macOS and Linux withhold new candidate/half-life text when
      encryption is requested, active or unknown; pending text and its in-memory maps are retired, while admitted
      numerical snapshots continue. A started historical append must settle under the previous policy before
      activation commits; otherwise activation refuses visibly. Existing database and ledger history still exports
      and reimports faithfully. The 21 locales explain this scope. This does not close the separate macOS
      `events_typing.rich_text` SQLite follow-up (AHK-005 / WM-002 below), and final-source CI/native qualification
      remains in the acceptance sections.
- [ ] **macOS/Linux remaining raw telemetry.** Implement clipboard copy/paste bursts, capture-process presence
      and detailed window topology on both Lua drivers, plus Internet/VPN transitions on macOS. Windows defines
      these raw families; they are separate from dashboard presentation. Linux Internet/VPN transitions are already
      implemented: `linux/modules/keystats/network_metrics.lua` records `internet_up`/`internet_down` and
      `vpn_connected`/`vpn_disconnected` at the shared registry cadences through `events.network`, and the Linux
      device ledger exports them. The ROI implementation above does not add any of these OS collectors.
      Clipboard bursts done on Linux and macOS (code, 10 November 2026): `_shared/lua/keystats/clipboard_events.lua`
      holds the Windows kinds (`clipboard_copy`, `clipboard_paste`, `paste_burst`), the Windows burst rule (5 pastes
      within `[keystats] paste_burst_window_ms`), the copy provenance a paste carries (`copy_lag_ms`, `source_app`)
      and the one `events_clipboard` INSERT both Lua drivers render; the physical Ctrl/Cmd+C, X, V and Shift+Insert
      the hook forwards feed it, a paused, filtered or excluded copy clears that provenance, and the Linux ledger
      exports the rows. Unlike Windows the clipboard is never read: a copy is counted from its chord, so
      `content_type` is `unknown`, no `char_count` is stored and a menu copy is not counted.
      Capture-process presence and window topology done on both Lua drivers (2026-11-10): the shared reducers
      `_shared/lua/keystats/window_topology.lua` and `capture_presence.lua` port the Windows classifiers, so
      `window_move`/`window_resize`/`window_state_change`/`monitor_focus_change` reach `events_window_topo` and
      `screen_recording_start`/`screen_recording_end` reach `events_av` through the new `events.window_topo` and
      `events.av` catalogue statements (Linux ledger exports both). Linux reads X11 geometry, EWMH state and RandR
      monitors in process (libxcb, `topo_tick_ms`) and `/proc/<pid>/comm` every `av_state_slow_tick_ms`; under
      Wayland topology is not measured and the Metrics menu says why (21 locales). macOS reads `hs.window` and the
      running bundle ids on the maintenance tick. `virtual_desktop_switch` stays Windows-only: both Lua drivers
      record the real desktop as `space_change`. Left: confirm the X11/RandR reads and the macOS frames on hardware.
- [x] **Metrics:** expose collection availability and units. Linux done: completed suspensions and locks count as passive periods (`passive_period` events), CPU/RAM are sampled from /proc as the Windows `system_load` event, the X11 EWMH current desktop feeds `space_switches`, and pointer distance is the X11 cursor travel in screen pixels; under Wayland both are not measured and the Metrics menu names each with its reason (21 locales) and the log says so. The dashboard no longer draws an unmeasured KPI as zero: the Linux payload names each one with its reason (`driver_meta.unmeasured`) and the desktop-change card reads « — » and that reason while no device counted any. The two Linux-only remainders moved to their own entry below. Windows space changes done: `keystats_virtual_desktop.ahk` polls the current desktop id Explorer publishes (Windows 11 `Explorer\VirtualDesktops`, Windows 10 `SessionInfo\<id>\VirtualDesktops`, value `CurrentVirtualDesktop`) on the window-topology tick and emits the macOS `space_change` event; the focus heuristic stays a raw topology event (real-desktop check under "To confirm on Windows"). Night wakes done on all three OS: a wake earlier than `[keystats] night_wake_end_ms` (06:00) after local midnight counts in `night_wake_count` (macOS and Windows walkers, Linux sampler and ledger import, shared corpus vector `system_event_night_wake`; macOS aggregate cache revision 6 recounts past days). See [metrics evidence](docs/audits/platform-parity/2026-11-04/metrics.md).
- [x] **Linux metrics:** count tap-to-click (libinput synthesizes it above evdev, so the daemon never sees the tap; it needs a desktop-level source) and read the Wayland compositors' current desktop (sway/Hyprland/KWin IPC) so `space_switches` is measured there too. Until then both stay named as not measured in the Metrics menu and the dashboard. Wayland desktop done (2026-11-10): `workspace_switcher.current_workspace_source` reads sway's focused workspace name, Hyprland's active workspace id or KWin's current desktop (one bounded query, reused for 1 s, so a round trip shorter than that is missed) and feeds `space_switches` when no X11 desktop exists; GNOME Wayland stays unmeasured with `platform_reason.desktop_changes_need_workspace_interface` (renamed from `…need_x11`, 21 locales). Left: tap-to-click, and the real-session check under "To confirm on Linux". Tap-to-click done (2026-11-10): the keyboard hook forwards each touch report of a pointer source (`contact`) and the frame's kernel stamp; `modules/gestures/tap_detector.lua` applies libinput's tap rules (180 ms from the last landing, 1.3 mm, one to three fingers, no landing after a lift, no button press, tap-and-drag adds no click) and a left or right tap (button map `lrm`/`lmr`) counts in `mouse_clicks` only while `adapters/tap_to_click_setting.lua` reads the desktop's setting as on (X11 xinput libinput properties by event node, KWin InputDevice D-Bus, swaymsg get_inputs, hyprctl getoption, GNOME gsettings); an unreadable setting counts no tap and the Metrics menu names « Touchpad taps » with `platform_reason.tap_to_click_setting_unreadable` (new, 21 locales; no earlier « not measured » reason existed for taps). Palm/thumb and disable-while-typing rejection are not reproduced. Regressions from `libinput record` traces: `test_tap_detector`, the `(tap-click)` cases of `test_keystats_pointer_metrics`, `test_tap_to_click_setting`, `test_metrics_availability_rows`, `test_keyboard_hook_nav_wheel`. Windows and macOS already count the synthesised click.
- [x] **macOS onboarding:** expose live number-row ordering with the same selected-layout availability as its working menu; the wizard currently excludes macOS. Document the typing-priority rollover alternative to Windows/Linux release-order tap-holds; do not promise identical hold semantics. Done (aligned on Linux, decision 2026-11-06): the wizard's number-row order is offered on macOS behind the `number_row_live` capability the host reads from `modules/keymap/number_row_live.lua` (greyed with `platform_reason.number_row_live_no_layout` while no layout of ours types); a stored order is rebuilt live into the typing layout before the reload, bounded at 20 s. The Tap-Holds page carries a macOS-only hint (`onboarding.page.tap_holds.rollover_note`, 21 locales) saying that Space, Enter, Tab, Escape, Backspace and Delete favour typing there, without promising the release-order semantics.
- [ ] **Windows/Linux diagnostics:** add the manifest-derived unavailable-features explanation already collected and rendered on macOS. Evaluate authenticated fallback metadata for feed-only update installation; retain current refusal without authenticated assets (macOS uses signed Sparkle metadata for newest-channel updates). Progress: Linux and Windows now publish the section through one shared Lua collector and its AHK mirror (AHK test written, not run on Linux); the feed-only fallback evaluation remains. Decided 2026-11-06 (align on macOS): a feed-only list may install the channel's newest release only through authenticated metadata, otherwise the refusal stays. Windows/Linux design: download the asset under its conventional name, compute size and SHA-256 locally, rebuild the `asset_signing.json` record and verify `<asset>.sig` against the pinned key before installing. Blocked: `public_key_spki_base64` is empty and enforcement is `off`, so every such install would refuse today; build it once the key is provisioned (docs/tooling/update-signing.md).
- [x] **Backup scope:** classify the macOS native settings that truly need restoration and document filtered backups; owned programmable .ahk/.lua sources are excluded by the common TOML/JSON extension policy on all OS. Do not export caches or all native settings indiscriminately. Done (aligned on Windows, decision 2026-11-06): the one native setting that is configuration is the remote API entry list, which Windows backs up as api_entries.json in its folder. macOS now backs up its hs.settings `llm_api_state_v1` as api_entries.json through a native port root of the shared owner (`{ id, name, port }`, written and read back on restore), and Linux adds api_keys.json as a file root while no row holds a plaintext key (WARN and left out otherwise). Each holds Keychain/secret-service/DPAPI references, never a portable key. The rest of hs.settings is classified in `macos/modules/updater/config_backup.lua` as runtime state or config.toml mirrors and stays out; the shared rule is in the updater defaults' comment. Left: a restored macOS entry whose Keychain account was retired since the backup needs its key typed again.
- [x] **Layers:** evaluate repeat-count support on macOS/Linux (`parameters.repeat_count` currently Windows-only), and mouse-button layer sources on Linux (`source_kinds.mouse_button` excludes Linux because the observed button cannot be suppressed). Fn remains a macOS-specific modifier; layer Spotlight is a macOS-specific action. Source: `_shared/keymap/layer_actions.toml`. Done (aligned on Windows, decision 2026-11-06): `repeat_count` resolves on the three OS. Linux counts in the tap-hold engine (a count key sends nothing, a repeatable action sends its last chord N times, any send and leaving the layer reset it); macOS uses the lease-scoped Karabiner variable `nav_repeat_count` (one counted manipulator per count the layer sets, reset by every keystroke and, when the layer binds a count, by entering the layer). The Linux recommended layer gets the Windows number row. Mouse buttons are a Linux layer source: the hook takes the mouse for the hold, as for the wheel, and hands a bound button to the engine, which keeps its chord down until the button's release. Left: on macOS a wheel binding cannot read the Karabiner count (Hammerspoon posts it), so a counted wheel action sends once and a `repeat_count` on the wheel is left out with a warning; Linux brightness `call:` rows reset the count where the Windows handlers do not.
- [ ] **Windows/macOS/Linux:** qualify physical shortcut delivery and its editor; Windows has no host, and both Lua production getters currently return false. Preserve the safety refusal until source/collision/output custody is qualified; see LIN-004 in the deep input audit. Windows token-by-token prediction display also remains unvalidated (`platform_reason.token_streaming_unvalidated_on_windows`). Progress (code, 6 November 2026): the refusal is now pinned on the real chain, not an injected answer: on Linux and macOS a test drives the production `keyboard_shortcuts.physical_delivery_available` (false), the real editor host and the shared menu port with the GUI ready, and the editor stays closed with no scope captured. The greyed editor row no longer says « Try reopening it »: it names the cause, `physical_shortcuts.delivery_unqualified` (21 locales, `disabled_reasons` on the row). Left: the Windows host, and the qualification itself, which needs real hardware (under "To confirm on Linux" and "To confirm on the Mac"); only then may a getter turn true.
- [x] **macOS:** review the tap-hold word-reset option and automatic model-to-prompt-profile switching (`hotstrings.tap_hold_resets_word`, `llm.profiles.auto_profile_for_model`). Provide shortcut-only restore/clear if feasible; the configuration menu currently restores Karabiner settings together with other settings. Decision (2026-11-06): align on Windows/Linux. Findings: (1) the word reset needs the driver to tell a Karabiner tap-hold's output from the keyboard's own keys, which it cannot today; a Karabiner-side marker (a variable or a dedicated virtual key the driver observes) is the candidate, to qualify on the Mac. (2) macOS already offers the recommended profile after a model switch (`model_switcher.apply_recommended_prompt_profile`, silent for completion models, a dialog for chat models); alignment means a persisted `llm.profiles.auto_profile_for_model` toggle (manifest and menu row for `hs`) that switches silently when on, offers nothing when off, and is turned off by a manual profile choice, as `linux/modules/llm/profile_settings.lua` does. **Auto-profile done:** `llm.profiles.auto_profile_for_model` is now a macOS setting and check row (the one-shot "recommend" row is retired); on, a model change applies the recommended profile without a dialog and switching it on applies it at once; off, a model change keeps the profile; a manual profile choice switches it off. **Word reset done (code, 6 November 2026):** `hotstrings.tap_hold_resets_word` is a macOS setting and live check row. The Karabiner generator leads a tap whose output is a Cmd, Ctrl or Option chord with a tagged F20 (`tap_hold_command`, `_shared/lua/keymap/control_signals.lua`); the keymap claims it like the other control sentinels, applies the option at once and lends it to the chord that follows, and a shortcut struck while the navigation layer is on (its F20/F19 sentinels) follows the option too. Left on macOS: a shortcut under a Ctrl, Cmd or Option hold of a tap-hold key still follows `shortcut_resets_word`, because a tagged marker makes Karabiner lift the hand's modifiers around the rule (the decision contract `hold_key_tap_keeps_a_modifier_held_before_it` fails) and F13 to F20 are all reserved; it needs an untagged sentinel key. Hardware check under "To confirm on the Mac".
- [x] **macOS:** a shortcut struck under a Ctrl, Cmd or Option hold of a tap-hold key should follow `hotstrings.tap_hold_resets_word`, as on Windows and Linux; today it follows `shortcut_resets_word`. A tagged F20 at the hold's start makes Karabiner lift the hand's modifiers (decision contract `hold_key_tap_keeps_a_modifier_held_before_it`), and F13 to F20 are all reserved: it needs an untagged sentinel key free of every other owner, and its release edge. **Done (code, 10 November 2026):** the generator leads every tap-hold hold that presses Ctrl, Cmd or Option of its own (not a key held as its own native modifier, not a Shift hold) with the untagged context-menu key (`application`, keycode 110; F21 to F24 are dead keys in the macOS HID table). The keymap claims both phases, records the hand's modifiers from the marker's flags, gives every shortcut carrying another Cmd, Ctrl or Option to `tap_hold_resets_word`, and ends the hold when its modifiers go up (flagsChanged, no release marker). Hardware check under "To confirm on the Mac" (Tap-hold word reset).
- [x] **macOS and Linux:** evaluate automatic insertion of completed AI continuations; both currently show a bubble and insert on acceptance. The Windows inline mode is not token-by-token document streaming (`platform_reason.inline_autotype_is_windows`). Done (aligned on Windows, decision 2026-11-06): `llm.trigger.inline_autotype` is a setting and a check row of the trigger menu on macOS and Linux. On, a request asks for one variant and its finished prediction goes through the acceptance Tab uses (request, focus, pause and privacy rechecked; macOS after the painting callback returns); a rewrite, live mode and an erasing correction keep their offer. The Windows-only reason is retired from the 21 locales. Unlike Windows, the bubble is painted for an instant before the text is typed.
- [ ] **Windows and Linux:** evaluate incremental touchpad gesture modes and step sizes; macOS tracks finger movement while the other drivers handle discrete gestures. Linux done (follow macOS, decision of 2026-11-06): `linux/modules/gestures/incremental_tracker.lua` fires an incremental slot's action while the fingers move, from the decoder's live travel (`mt_decoder` `live()`), with the step rule and reversal shared with macOS (`_shared/lua/gestures/incremental.lua`, `_shared/lua/gestures/sensitivity.lua`); travel is converted to millimetres with the touchpad's own resolution (EVIOCGABS, `touchpad_finder.read_resolution`), the unit of the macOS sensitivities, so the manifest's modes and steps (`gestures.modes`, `gestures.sensitivities`, now declared for `linux`) apply unchanged; a pad that reports no resolution fires once, as x1, said in the log. Modes and steps are read from and written to `[gestures.modes]` / `[gestures.sensitivities]` and offered in each swipe slot's submenu through the shared templates (`test_gesture_incremental.lua`). Windows stays blocked: the driver receives each swipe finished, as the Precision Touchpad settings send it, and sees no finger travel to step on; following macOS needs a raw HID digitizer reader (RegisterRawInputDevices, usage page 0x0D) the driver does not have, so its rows stay greyed with `platform_reason.gesture_modes_and_steps_need_finger_travel`. Left on Linux: a real touchpad check (see "To confirm on Linux").
- [x] **Windows:** implement the bulk copy of tap assignments into simultaneous-chord assignments where compatible; `key_combinations_group.copy_tap_to_combo` is declared for macOS and Linux only. Done (decision of 2026-11-06, align on macOS/Linux): `KeyCombinationCopyTapsToChords` plans every chord from its pair's tap in the freshly read file under the commit lease (symmetry owner order only; pairs that cannot chord and taps no chord can run are skipped and logged), and the row is declared for `ahk` (`test_key_combination_chord_engine.ahk`).
- [x] **Linux:** review exposing keyboard-layout-only restore/clear. `keyboard_layout_scope` participates in global restore/clear, but the two `layout_menu` commands are hidden on Linux; re-check the menu's old assumption that Linux has no layout settings against the live number-row and pause-layout controls before choosing behavior. Done (aligned on Windows/macOS): the two `layout_menu` rows now show on Linux and run `keyboard_layout_scope.request`, the participant a global restore composes, so the number-row rows settle only once the session loads them and a refused load reverts config.toml.
- [x] **Windows:** implement a notification-area WPM readout; the floating widget is the current alternative (`platform_reason.wpm_readout_needs_a_menubar`). Decided 2026-11-06 (align on the most complete OS): Windows follows macOS (menu bar) and Linux (`linux/ui/wpm/tray_readout.lua`): a second notification-area icon with the number painted in it on the source colour, shown while typing, declared on `ahk` for `metrics_menu.wpm_menubar` / `menubar_colors` and the two `metrics.wpm_menubar_*` keys, the reason retired. Done: `ui/wpm/wpm_tray_readout.ahk` over `adapters/notify_icon.ahk` (Shell_NotifyIcon owner with TaskbarCreated re-add, a pause owner and NIM_DELETE on exit; GDI+ HICON painter), fed by the widget's ring; rows and keys declared on `ahk`, reason retired. Tests `test_notify_icon.ahk` and `test_wpm_tray_readout_wiring.ahk` (unrun on Linux); live check under « To confirm on the Windows PC ».
- [x] **Linux:** correct stale platform-reason translations after checking all consumers and all locales: `platform_reason.llm_configuration_surface_is_not_on_linux` contradicts the Linux model/profile/generation providers, and `platform_reason.metrics_extras_are_not_on_linux` contradicts the exclusion handler. Avoid treating these stale strings as proof of missing functionality. Done: the generation-submenu reason now names Linux's inline rows (new key, 21 locales); the unconsumed exclusion-list refusal is removed.
- [x] **Linux:** add user management of wrap-symbol pairs (custom add/delete, enable/disable and bulk actions): the existing menu only invokes the shared fixed pairs. Inspect `linux/ui/menu/menu_shortcuts.lua` and the Windows/macOS wrap menu owners. Done (aligned on Windows/macOS): the Linux wrap submenu draws the shared controls (check/uncheck all, restore, one group per catalogue family with its own check/uncheck all, custom add/delete) and stores the choices in config.toml `shortcuts.wrap_symbols` through the shared `menu/wrap_preferences` planner, macOS's store; the shortcuts manager wraps only with the active pairs. The former click-to-wrap rows are replaced by these toggles (the `wrap_selection` action stays bindable).
- [x] **Linux Wayland:** investigate supported compositor interfaces for focused-application identity on GNOME, KDE, COSMIC and Weston; the current adapter cannot supply it there, limiting per-application rules. Preserve unknown/fail-closed behavior where no safe interface exists. Done (6 November 2026): every wlr-foreign-toplevel compositor (labwc, Wayfire, river and the other wlroots ones) now answers through `lswt -j` in `linux/adapters/window_info.lua`, after sway, Hyprland and niri; a listing without activation state, with none or with two activated toplevels stays unknown. Findings for the others: GNOME admits `org.gnome.Shell.Introspect` to allow-listed senders only and removed Shell.Eval, so only an Ergopti Shell extension could ask; KWin answers only a loaded script, which must call back a D-Bus name the daemon owns; COSMIC's `zcosmic_toplevel_info_v1` needs a native Wayland client (ext-foreign-toplevel-list carries no activation); Weston has no such protocol. They stay unknown, fail-closed.
- [ ] **Linux Wayland:** focused-application identity on GNOME, KDE and COSMIC, from the findings above: an Ergopti GNOME Shell extension exposing the focused window's WM class, title and pid on the session bus (installed and enabled by the installer), a persistent KWin script calling back a session-bus name the daemon owns on `workspace.windowActivated`, and a native `zcosmic_toplevel_info_v1` client for COSMIC. Each needs its desktop to be qualified on real hardware. Code done for GNOME and KDE (10 November 2026): the GNOME Shell extension (`linux/desktop_focus/gnome/`, `focus@ergopti.fr`, GNOME 45 and later) and the KWin script (`linux/desktop_focus/kwin/`, Plasma 5 and 6) call `org.ergopti.Focus1.Activated(class, title, pid, id)` on the session-bus name `org.ergopti.Focus`, owned by a resident worker (`linux/adapters/compositor_focus_worker.lua`, libgio) that admits only the current owner of `org.gnome.Shell` or `org.kde.KWin`; the daemon reads its lines (`linux/adapters/compositor_focus.lua`) and `window_info` answers the 4×/s poll from memory, no fork, unknown before the first report, after a malformed one or once the worker exits. `install/compositor_focus.sh` installs and enables them for the running desktop (once: an update keeps a user's off switch; GNOME for the next login when the Shell refuses), run by install.sh and by launch.sh at every start (so .deb, .rpm and AppImage users get them too; Flatpak's private data folder cannot), removed by uninstall.sh. Tests: `test_compositor_focus.lua`, `test_compositor_focus_assets.lua`, `tools/test/test-linux-compositor-focus-install.cjs`, and the worker on a real dbus-daemon (`tests/hardware/run_compositor_focus_bus.lua`). Left: COSMIC (a `zcosmic_toplevel_info_v1` client means hand-built libwayland-client interface tables over FFI that nothing here can run against without cosmic-comp; it stays unknown), and the real-desktop check under « To confirm on Linux ».
- [x] **Linux:** investigate a safe copy-confirmation mechanism on Wayland and X11 without xclip; tap-hold copy currently sends the keys without the retry/confirmation used when a clipboard change counter is available. Done (aligned on Windows/macOS): X11 without xclip reads the CLIPBOARD owner's ICCCM TIMESTAMP through libX11 (`linux/adapters/x11_selection_stamp.lua`, proven on Xvfb by `tests/hardware/run_x11_selection_stamp.lua` in CI); Wayland counts the selection changes of a `wl-paste --watch` child the tap-hold manager owns (`linux/adapters/wayland_selection_counter.lua`, the offered content drained to /dev/null). Both feed the same check, retry and warning as xclip. A compositor without data-control (GNOME) makes `wl-paste --watch` exit, so there the copy stays unchecked, said once in the log; no client-side counter exists there.
- [x] **Linux:** investigate `open_personal_shortcuts`: the action opens `personal_shortcuts.toml`, but the menu and loader describe keyboard slots stored in `config.toml`, and no production reader of that file was found. Route it to the actual owner or remove the misleading action after runtime verification. Decided 2026-11-06 (align on the most complete OS): Windows (`GestureEditPersonalShortcuts`, the programmable personal `.ahk`) and macOS (`PersonalShortcutsLuaPath`) open the driver's programmable personal source, the default of `script_altgr_delete`; Linux follows by opening its own programmable source, or the action is retired there with a reason. Done (aligned on Windows/macOS): the action opens `personal_shortcuts.lua` in the configuration folder, created from a commented template when absent (exclusive create, never overwritten), and the daemon runs it once at the end of its services in a protected call (`linux/infra/personal_shortcuts.lua`), as macOS runs its file with dofile; the dead `personal_shortcuts.toml` target is gone. Linux offers no hotkey API to that file: bindings stay in config.toml.
- [x] **Linux:** evaluate accented-key shortcut remapping on layouts where those keys are not shortcut letters (`platform_reason.accented_shortcuts_are_windows`). Done (aligned on Windows): `linux/modules/shortcuts/accented_shortcuts.lua` turns Ctrl, Alt or Super (Shift riding along) on a key whose plain press types è, ê, é or à in the loaded keymap into the chord on the chosen letter, from the keyboard hook's consumption callback under the Shortcuts master; AltGr is left alone and a digit-row key stays a digit while the row types digits first. The four `shortcuts.<letter>` settings and the « Raccourcis sur les lettres accentuées » letter pickers of the layout menu are declared for `linux`; the reason now names macOS alone (`platform_reason.accented_shortcuts_need_a_layout_file_on_macos`, 21 locales).
- [x] **Linux:** evaluate X11 implementations of pointer centering, pointer teleportation and mouse spotlight; Wayland restricts these operations (`sg_actions.center_mouse`, `teleport_mouse`, `spotlight_mouse`). Evaluate file-manager-specific implementations of open-terminal-here and new-text-file-here. Progress (aligned on Windows/macOS): `center_mouse` and `teleport_mouse` run on X11 (`linux/modules/gestures/pointer_warp.lua`: RandR monitors, xdotool position and move; teleport cycles the RandR order and shows `shortcuts.no_other_monitor` with one monitor) and require `session:x11` so the picker greys them under Wayland; unlike macOS, teleport shows no spotlight afterwards. `spotlight_mouse` runs on X11 too (`linux/modules/gestures/pointer_spotlight.lua`, drawn by `linux/adapters/spotlight_overlay.lua`): a yellow ring around the pointer and a red × at the centre of every other RandR monitor, click-through GTK popups, dismissed after 5 s or by a pointer move of more than 5 px (Windows' rule), with the Windows/macOS sizes and colours; it requires `session:x11` like the two others, and its Linux reason is retired from the 21 locales (`test_pointer_spotlight.lua`). Without a compositor the windows are shaped to the stroke, so the translucent fill shows only on a composited desktop. The look is still three copies (Windows `ui/spotlight/init.ahk`, macOS `system_mouse.lua`, Linux `pointer_spotlight.lua`): a shared constants file would let the three read one. Left: qualify a file-manager-specific active-window, active-tab and folder owner before enabling terminal/file creation. Thunar takes caller-supplied paths; Nautilus publishes all tabs after a delay; Dolphin can fall back to HOME for a nonlocal folder. Cover focus/navigation changes, local/remote folders, exclusive file creation and reveal. Window titles, process cwd and clipboard location-bar guesses are not ownership evidence. Done (10 November): `linux/adapters/file_manager_folder.lua` reads the active X11 window's `_GTK_UNIQUE_BUS_NAME` and `_GTK_WINDOW_OBJECT_PATH` and asks that Nautilus process (never the well-known FileManager1 name) for `OpenWindowsWithLocations`; the window and its folder are read twice and must agree, tabs on different folders, `trash:`/`starred:`/`sftp:` and a missing folder are refused with a notice. open_terminal_here starts the session terminal detached in the folder; new_text_file_here creates the first free name exclusively and selects it with ShowItems on the same process. Thunar (its D-Bus only takes caller-supplied folders) and Dolphin (its MainWindow only answers whether a URL is open in some tab) are refused by name, and the picker greys both rows with the reason when no Nautilus is installed (`file_manager:folder`); requires X11, as the pointer actions. Proved headless against the apt Nautilus 46.4, Thunar 4.18.8 and Dolphin (`linux/tests/hardware/run_file_manager_folder.sh`, 22 receipts). Wayland stays greyed: the active window's GTK properties are X11 ones. The shared spotlight constants file was not made: three drivers' look values move together and Windows reads it later, so it is not a Linux-only change.
- [x] **Windows and Linux:** implement equivalents of the macOS bundled App Cloner (isolated application copies and profiles) and Encryptor (file encryption/decryption by drag-and-drop). These are bundled apps, distinct from the shared text and metrics encryption features. Decided 2026-11-06 (align on the most complete OS): macOS defines both; Windows and Linux follow. Done (branch `wave3/app-cloner-encryptor`): the tray's Applications submenu is declared on the three drivers; each app runs as its own process. The Encryptor container is `_shared/data/encryptor/format.json` (OpenSSL's `enc` envelope) with shared vectors that Node, the macOS helper, the Linux openssl path and the Windows CNG path all decrypt and, with the same salt, write byte for byte (`test-encryptor-shared-vectors.cjs`, `test_encryptor_core.lua`, `test_bundled_apps.ahk`); its drop targets are a Linux desktop entry (`%F`, Open With) and a Windows Send To shortcut plus a drop window. App Cloner reads `_shared/data/app_cloner/families.json` (macOS's names pinned by `test-app-cloner-families.cjs`): Linux writes a desktop entry and an sh launcher with the family's profile option or private XDG folders; Windows writes a Start menu shortcut with the family's profile option, and says when a program of no family can only get a second shortcut. Colour-tinted icons stay macOS-only (the Linux icon is a theme name drawn by the desktop, Windows has no icon toolchain in the driver): both offer the original icon or an image. Physical checks: « To confirm on the Windows PC » and « To confirm on Linux ».
- [x] Triage each OS-specific configuration entry, action and greyed menu item in the generated [feature inventory](docs/feature-inventory.md). The recorded reason and equivalent distinguish OS-specific mechanisms from actual product gaps. Recheck runtime and hardware behavior before declaring parity. Done (6 November 2026): every row of the inventory is classified (counts in `docs/feature-inventory.md` headings). Rows with an equivalent or a genuine OS mechanism carry a precise reason in 21 locales: path and action reasons were already specific; the 157 hidden menu entries (275 rows) that printed "Review the platform-specific presentation and equivalent." now take their reason from `static/ergopti_plus/_shared/modules/menu/hidden_row_reasons.json` (the generator refuses an unmapped or stale entry), and four one-word Linux reasons (`libinput_reader_is_linux_only`, `only_linux_rereads_its_catalogue`, `only_linux_migrates_in_the_background`, `only_linux_lacks_metric_sources`) and the two Linux generation-settings reasons (which said "two" settings; Linux lists five) were rewritten. Missing features are the existing entries above (incremental gestures, accented shortcuts, Windows WPM readout, tap-hold word reset, physical shortcut editor, token streaming, personal shortcuts file, X11 pointer actions, file-manager actions, macOS shortcut-only restore) plus the four new Linux/Windows entries added above.

## One-shot Shift parity follow-up

[November 5 focused audit](docs/audits/platform-parity/2026-11-05-one-shot-shift/report.md), source `9c565c88c9a1366a2e9b18c1b9d2868509510975`. The [generated capability comparison](docs/audits/platform-parity/2026-11-05-one-shot-shift/capabilities.md) separates intentional differences, source-only findings, original-owner executions over recorded ports and remaining native boundaries.

- [x] **[CODE] OSW-001 — Windows:** retain the completing modifier chord for named-control capture/replay, including Backspace, Enter and Delete. Cover modifier changes between capture and output, admission/refusal, exactly-once native receiving and the sibling DeadKey path. Adding Blind alone does not preserve the original captured state. Conditional source finding; native InputHook completion still needs qualification. **Already fixed** on `origin/fix/windows` (`12d91b67c6`, `3727598a02`, `2da3e853f0`: the captured control flags and logical modifiers are replayed); nothing redone here. Native InputHook completion still needs qualification.
- [x] **[CODE] OSM-001 / OSL-001 — macOS/Linux:** validate the proposed same-key Shift optimization in the actual Caps Lock and held-modifier context. Caps Lock plus physical Shift currently spends one-shot activation while retaining lowercase in the original-owner probes. Cover both Shift keys, ordinary Caps/Shift controls, fallback title output, release ownership and native receiving. The Linux native XKB component independently confirms that its detached inverse plan differs from live Caps+Shift translation. **Partly done:** macOS already fixed by the complete-prospective-flags predicate in `adapters/one_shot_shift.lua`; the Caps Lock case is now pinned by a test. Linux remains open: the engine plans the title with a Caps-unaware layout table, so with Caps Lock plus a held Shift it presses a Shift that yields lowercase; a correct fix needs a live-state-aware planner (XKB peek with the Shift toggled) and native qualification. **Linux done (aligned on Windows, which types the title):** the tap-hold engine reads the live XKB Caps Lock (`caps_locked`); locked, it skips the same-key Shift plan and types the capital with Caps Lock released around the keystrokes and restored, as the injector does (engine test with no Shift, left and right Shift held). Native evdev/uinput receiving, and keymaps whose CapsLock key does not toggle the lock, stay to confirm on Linux.
- [x] **[CODE] OSM-002 — macOS:** validate accepted timeouts against both arming and editor numeric domains. The API can persist zero from a positive fraction; numeric NaN is also accepted under the acknowledged save port, while public arming rejects both. Public menu strings `1e309` and `1e20` persist and reload through original Config/TOML on private Linux files, then the next edit raises at `%d` before opening its dialog. Regress parse→save→rebuild→reopen, enabled/disabled states, valid controls and transaction refusal; define the unlimited-timeout policy explicitly. Native dialogs, metadata and lease/deployment still need qualification. [Real-persistence evidence](docs/audits/platform-parity/2026-11-05-one-shot-shift/macos/real-config-domain/report.md). **Already fixed** in the base (setter and `timing_leaf` admit only whole positive milliseconds within the timer ceiling); regression test `test_sticky_timeout_domain.lua` added. The unlimited-timeout policy question stays with the maintainer.
- [x] **[CODE] OSL-002 — Linux:** retain the engine output holder on repeated wrapped letters armed through an ordinary physical tap. Actual Reader/Hook/Manager/Engine/broker/Writer probes reject repeat provenance and retire the channel; the same stream without repeat remains healthy. Preserve loud refusal for genuinely foreign ownership, release debt and pause/reload controls; qualify real evdev/uinput receiving separately. **Done:** a wrapped key's repeat is now always the engine's own held row, not only for an input-armed one-shot; engine-level holder test added. Real evdev/uinput receiving stays unqualified.
- [x] **[POLICY] Linux action origins:** review the explicit tap-only one-shot Shift restriction before exposing a generic action or keyboard slot equivalent to Windows `one_shot_shift` / macOS `sticky_shift`. Linux already implements the capability through tap-holds; generic accessibility StickyKeys is not established as equivalent to the shared punctuation, magic-key and title-case contract.
      Decided 2026-11-06 (align on Windows/macOS): the one-shot Shift is a generic catalogue action on every OS; chords keep refusing it.
- [x] **[CODE] Linux generic one-shot Shift:** declare `one_shot_shift` for `linux` in `_shared/modules/actions/actions.toml` (retire `reason_linux`, pair `sticky_shift`'s `equivalent_linux`) and give a gesture or keyboard-slot origin an arming route. Today only the hook's key-frame lease can arm the engine (`keyboard_hook.capture_input_owner` requires `_live_input_context.action == "one_shot_shift"`, then `tap_hold_engine:arm_one_shot(now, guard)`); a pointer/touchpad origin has no frame, so it needs its own guard tied to the installed engine generation and pause state, with regressions for arming, spending, timeout and pause. Not done in this pass: the lease model is the input-ownership boundary and changing it without native receiving checks is unsafe. Done: `one_shot_shift` is declared for `linux` (`sticky_shift` pairs it through `equivalent_linux`); a tap-hold key keeps its engine route, key pairs and chords keep refusing it, and a gesture or pointer origin runs the shortcuts manager's handler, which calls `keyboard_hook.arm_action_one_shot`: it arms the installed engine (through the combination issuer when there is one) with a guard tied to that engine, its remapper generation and a running intercepting hook, so a pause (which uninstalls the engine) voids it; it refuses while a key frame holds an arm. Tests `one-shot-action-origin` cover arming, spending, timeout, pause and refusal. Real evdev/uinput receiving stays to confirm on Linux.
- [x] **[POLICY] Windows/Linux timeout configuration:** evaluate exposing an editable one-shot timeout equivalent to the macOS user setting. All three share the2000ms default, but the reviewed Windows/Linux paths use the shared registry without the same editable user leaf. Preserve the documented per-driver construction and define any zero/unlimited policy before adding a control.
      Done (decision 2026-11-06, align on macOS): Windows reads `[tap_holds] sticky_timeout_ms` at boot and Linux `[tap_hold] sticky_timeout_ms` in tap_hold.toml; both tray menus gain the sticky delay row (prompt, positive whole milliseconds, reload); zero, negative, fractional and unlimited values are refused as on macOS. AHK test written, not run on the Linux host.
- [x] **[TEST] macOS one-shot/CapsWord relay:** combine the original serializer and CapsWord observer for generated punctuation under a space-only exit policy. The direct one-shot emission path lacks an explicit output relay, but the archived emission port does not establish native tap ordering or a confirmed CapsWord failure. Keep this candidate outside the confirmed findings until reproduced.
      Done: reproduced with the original adapter and the shared CapsWord policy (the serialized " :" never reached the CapsWord output observer, so a space-only CapsWord stayed on); `adapters/one_shot_shift.lua` now reports the serialized result on an accepted handoff, nothing on a refused one. Native tap ordering stays with « To confirm on the Mac ».
- [x] **[TEST/POLICY] Native one-shot text parity:** qualify Windows Tab/Escape capture representation, Unicode title casing and scalar replay against Lua key-down payloads; qualify macOS modifier-map/dead-key/IME handling and Linux real-device output receiving. The recorded-port probes and genuine isolated XKB component do not establish these cases. Do not list unverified behavior as an absent feature or assume a shared grapheme contract.
      Code part done: Windows titles the captured character with the shared rule (`TextCaseTitle`, no more `Format("{:T}")`) and its title takes the generated Unicode title forms StrUpper lacks (`windows/_generated/unicode_title.ahk`, from `codegen-unicode-case.cjs`), so the corpus title digraph now applies to Windows. Native qualification moved to « To confirm » on each machine.

## CapsWord parity follow-up

[November 5 CapsWord audit](docs/audits/platform-parity/2026-11-05-caps-word/report.md), source `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`: four pinned reviewers,159 initial qualified rows and nine new findings. [Generated capability/intent comparison](docs/audits/platform-parity/2026-11-05-caps-word/capabilities.md). A later direct-catalogue countercheck extends existing WRSL-001 below; it is not a tenth new connector root. Windows findings are source-only; recorded Lua ports do not certify native application receiving.

- [x] **[CODE] CWW-001 — Windows:** attribute CapsWord delimiter termination to the accepted emitted action, not its physical tap carrier. Cover Tab→Backspace with only Tab checked and CapsLock→Enter with only Enter checked, real action/send admission and refusals. Physical Space HotIf priority remains separately unexecuted. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/windows/report.md). **Done:** `_TapHoldTapEmittedKey` makes the dispatcher judge the key the tap types; AHK test added (not executable on Linux; encoding gate passes). Termination still runs just before the send, not after its acknowledgement.
- [x] **[CODE] CWW-002 — Windows:** preserve the intended toggle when AltGr's admitted tap action is `caps_word`; its unconditional pre-clear makes the second accepted tap turn the mode on again. Cover the actual AltGr producer and prior-key-self checks, not just calling the generic toggle twice. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/windows/report.md). **Done:** `_AltGrHandleHold` no longer pre-clears CapsWord; the dispatcher alone ends it for a checked delimiter (source-pinned AHK test, not executable on Linux).
- [x] **[CODE] CWM-001 — macOS:** re-arm the running CapsWord deadline for accepted live idle changes, including0→positive, shorter/longer and positive→0, with save-refusal rollback and generation-safe timer retirement. Disable pointer exits before exercising the real menu so the original session remains reachable. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Done:** `CapsWordAutoOff.set_observer` makes the watcher re-time the running session after every accepted policy change (rollback included); tests in `test_watchers_capsword_auto_off.lua`.
- [x] **[CODE] CWM-002 — macOS:** prevent inactive pointer traffic from reserving the100ms gate for a fresh CapsWord activation's first checked discrete exit. Retain flood protection and test no-prior-pointer, below-threshold and exact-threshold controls. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Already fixed** by the activation reset of the pointer gate in `start_capsword_idle_clock` (test `capsword-activation-throttle`).
- [x] **[CODE] CWM-003 — macOS:** bind pending CapsWord clears to their activation/revision so an older completion cannot suppress a newer checked delimiter. Regress the valid native0-publication→newactivation1→delimiter→oldexit-callback window, preserving protection against old clears erasing a new activation. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/macos/report.md). **Already fixed** by the activation clearing `_capsword_check_pending` and the per-clear identity in `complete_capsword_clear`; regression test added.
- [x] **[CODE] CWL-001 — Linux:** publish meaningful absolute-device pointer motion to CapsWord when pointer_motion is checked and gesture exit is off. Establish previous coordinates, ignore unchanged/initial reports, preserve relative-motion/contact controls and qualify actual reader/compositor receiving. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/linux/report.md). **Done:** the hook publishes a changed ABS_X/ABS_Y coordinate (first report and unchanged ones ignored, lifted contact forgotten) as `absolute_motion` for CapsWord; metrics ignore it. Real reader/compositor receiving stays unqualified.
- [x] **[CODE/DOC] CWL-002 — Linux:** align the menu's explicit next-event live-apply promise with the active session's retained policy. Original menu callbacks acknowledge new Space/left-click values while the running owner uses the old ones. Decide the intended lifetime before changing runtime ownership or correcting the contract; preserve separate next-activation hand-edit semantics and failed-write controls. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/linux/report.md).
      Done (decision 2026-11-06, align on macOS): each acknowledged menu write hands the new policy to the running session (`caps_word_policy_published`), which re-arms its idle check under a chain token; a hand edit still waits for the next activation. Regressions: Space unchecked/checked, left click enabled, idle 0→1, 10→1, 1→5 and →0 mid-session, hand-edit control.
- [x] **[CODE] CWS-001 — shared:** define consistent rejection/minimum-positive quantization for accepted fractional CapsWord idle delays. Values below0.0005s round to0ms, meaning immediate expiry on Lua but disabled on AHK. Cover both actual policy ports and timer admission; ordinary whole-second presets remain unaffected. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/shared/report.md). **Done:** both policy ports now refuse a positive delay below 0.5 ms (`invalid_idle_timeout`); corpus vectors added and replayed by Lua and AHK.
- [x] **[META/POLICY] CWS-002 — shared menus:** align the checked CapsWord star caption with its real character after choosing literal-built-in versus renamed-magic semantics. Actual macOS/Linux menus can show§ while their policy ends★. Preserve Windows's explicit separate built-in instance and test Lua module-load order rather than assuming every OS must rename it. [Evidence](docs/audits/platform-parity/2026-11-05-caps-word/shared/report.md).
      Done (decision 2026-11-06, literal ★ as every OS's policy and Windows's caption): the macOS and Linux CapsWord delimiter rows no longer substitute the renamed magic key; regressions draw the real menus after a rename to § (both fail on the old substitution). Windows caption not re-executed here.
- [x] **[POLICY] CapsWord variants:** settle repeated catalogue invocation (toggle on Windows/Linux versus active request on macOS), fixed macOS editing/navigation exits and modifier-only idle activity. Keep explicit Windows next-activation setting lifetime and gesture exclusion distinct from unknown common intent. [Comparison](docs/audits/platform-parity/2026-11-05-caps-word/capabilities.md).
      Done (decision 2026-11-06): the action toggles everywhere (macOS fixed); the macOS fixed exits are one shared list that Linux (`caps_word_observe_control`) and Windows (`CAPSWORD_FIXED_EXIT_VKS`, key-down always subscribed) now apply; a lone modifier no longer restarts the Windows delay. Gesture exclusion stays as documented. AHK tests written, not run on the Linux host.
- [x] **[PARITY] Windows CapsWord live settings:** under the decision of 2026-11-06 (CWL-002, macOS and Linux), an acknowledged CapsWord menu change must reach the running Windows session from its next event; `CapsWordAutoOffStore` still publishes for the next activation only (`CapsWordAutoOff.Armed` keeps the old policy). Re-arm the active subscriptions and idle timer on publication, with an AHK regression. Done: `CapsWordAutoOffStore` re-arms an active CapsWord with the published policy once the configuration owner has retired (`_CapsWordAutoOffRearmActive`), so subscriptions, motion poll and idle timer follow the change and the delay restarts from it; AHK test `capsword-live-settings` written, not run here.
- [x] **[NATIVE] CapsWord ownership:** qualify preexisting CapsLock and pause/quit/reload restoration, physical Windows Space HotIf priority, macOS key/control payload receiving, and Linux absolute reader/desktop keyboard grouping. Recorded lock requests and successful Lua cases are not receiving evidence. [Coverage limits](docs/audits/platform-parity/2026-11-05-caps-word/report.md).
      Moved 2026-11-06 to « To confirm » on the Mac, the Windows PC and Linux (hardware-only qualification).

## Repeat and recovery parity follow-up

[November 5 repeat/recovery audit](docs/audits/platform-parity/2026-11-05-undo-repeat/report.md), source `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`: four reviewers, 85 aspect rows, independent root replays and two final bounded dry sweeps. [Generated comparison and intentional differences](docs/audits/platform-parity/2026-11-05-undo-repeat/capabilities.md). Native application receiving and AHK execution remain qualified.

- [x] **[CODE] URL-001 — Linux:** retain the matcher word and its boundary after acknowledged repeat output. `ac★ê` misses the shipped correction; a word-only `x → z` rule can wrongly fire inside `po★x`. Cover the actual Main commit, not only the pure repeat resolver. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/linux/report.md). Done: Main now commits the repeat as a non-final result, so the matcher keeps the word and boundary.
- [x] **[CODE] URL-002 — Linux:** preserve private ancestry when repeat derives a scalar from actual personal-prefix output; Main currently publishes it to telemetry as public. TRACE payload logging is demonstrated only with TRACE enabled; SQLite persistence is source-only. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/linux/report.md). Done: the Linux engine tracks private ancestry and Main classifies a repeat out of it as private.
- [x] **[CODE] URM-001 — macOS:** prevent repeat from publishing a derived private scalar to ordinary telemetry, DEBUG output and AI context. Actual public Keymap/personal producer and fake HTTP-body capture demonstrate one scalar; the full private value remains protected. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/macos/report.md). Done: repeat now derives its private flag from the AI privacy mark, extends the mark and withholds the DEBUG scalar.
- [x] **[CODE] URW-001 — Windows:** preserve private ancestry after nonfinal programmable output before repeat. Shipped final personal outputs already block this direct path; genuine AHK regression and native receiving still need execution. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/windows/report.md). Done: `HSE_PrivateAncestry` is kept by every buffer commit/reset owner and the repeat Spec inherits `IsPrivate` from it (source-scan test; AHK not executed).
- [x] **[CODE] URW-002 — Windows:** normalize repeat classification in deferred Notepad/terminal completion as well as the atomic caller; live WPM coloring currently differs. Do not claim canonical category-field corruption: the durable row has no such field. [Evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/windows/report.md). Done: one `_ResolveFireCategory` now classifies repeats as `repeat_key` for the atomic caller and both deferred owners (source-scan test; AHK not executed).
- [x] **[PARITY] Windows/macOS:** evaluate an explicit immediate-Backspace trigger-restoration equivalent to Linux, or decide and document the exclusion. Application Ctrl/Cmd+Z is separate. Preserve original field/privacy authority, literal-output eligibility and empty/key-output/native deletion qualifications. [Comparison](docs/audits/platform-parity/2026-11-05-undo-repeat/capabilities.md).
      macOS done (decision 2026-11-06, align on Linux): a plain or Shift Backspace pressed as the very next key after a literal expansion is consumed, the typed replacement (replayed terminator included) is erased and the trigger typed back outside the buffer (`Expander.undo_on_backspace`); a key, click, focus change, observed-context loss, ignored window, composite event or token/dynamic output voids it; Option/Cmd/Ctrl+Backspace stay the application's. Windows is the open item below.
- [x] **[PARITY] Windows immediate-Backspace restoration:** same contract as Linux and macOS. The Windows Backspace reaches the application before `_OnPrefixKeyDown` sees it (as on Linux), so the restore erases what the fire typed minus one and sends the trigger; it must take the exact on-screen effect from `HSE_DispatchMatch`'s committed effect (`&CommittedScreenEffect`, the terminal-owner and pending paths included), refuse token/dynamic/raw-callback outputs and be voided by any other key, click or focus token change. Not done here: the dispatcher's asynchronous owners cannot be validated without an AHK runner. Done for the atomic SendInput path: `HSE_DispatchMatch` keeps the committed effect's literal text and the typed trigger read from the erased buffer (`_HSE_RememberUndo`, refusing Send-key, dynamic and user-code outputs; raw callbacks never reach it); `_OnPrefixKeyDown` hands the very next key to `_PrefixTakeUndoOnKeyDown` (a lone modifier keeps the record, Ctrl/Alt/Win+Backspace and any other key void it) and `HSE_UndoExpansion` re-checks focus, input generation, buffer and window before erasing the rest and typing the trigger outside the buffers. Left: the Notepad-paste and terminal owners emit after the keystroke and keep no record. AHK tests `backspace-undo` written, not run here; behaviour catalogue declares Windows.
- [x] **[SITE] URS-002:** move the English inventory headings/legend out of JSDoc into the exported dictionary. The actual-module-import guard fails on the missing exports before the repair and passes afterward; source-substring presence is not the oracle. This integration repair covers the shared heading used by the new live table. [Historical evidence](docs/audits/platform-parity/2026-11-05-undo-repeat/shared/report.md).
- [x] **[META] URS-001:** add an authored behavioral catalogue for capabilities without a setting, including qualified Linux Backspace restoration; generate its site/docs table and README link, enforce reviewed-owner drift and localized notes. This closes the metadata omission, not runtime parity or undeclared-feature discovery. [Generated declarations](docs/behavior-inventory.md).

- [x] **[POLICY] Repeat timing:** decide or explicitly retain the OS-specific activation window and expired-candidate ordering. Windows/Linux fallback is untimed independently of idle; macOS applies its effective magic-key window and modifier widening. Windows can let an expired registered winner mask repeat, whereas Linux rejects the timed result before fallback; macOS explicit star validation follows another documented path. The shared repeat corpus has no timing policy. The live behavior catalogue now exposes the window variant; its absence is not automatically a broken parent feature. [Four-reviewer timing countercheck](docs/audits/platform-parity/2026-11-05-undo-repeat/timing-followup/report.md).
      Done (decision 2026-11-06, align on macOS): Linux refuses a repeat outside the magic key category's window in Main (`within_delay` with `RepeatKey.WINDOW_CATEGORY`), Windows gives the transient repeat Spec that window and its letter as time-gate reference (`HSE_RepeatWindowSeconds`); behaviour catalogue updated, owners re-pinned. AHK test written, not run here.
- [x] **[PARITY] Windows expired candidate masks the repeat:** under the same decision an expired registered winner must fall through to the magic-key fallbacks as on Linux and macOS; `_OnPrefixChar` still dispatches it (`HSE_DispatchMatch` refuses on time) and returns before `HSE_TryRepeatKey`. Needs a time-gate preflight shared with `_HSE_PrepareDispatchDecision` (raw callbacks included) and an AHK regression. Done: `HSE_TimeGateExpired` asks the dispatcher's own gate (`_HSE_EvaluateTimeGate`, now shared with `_HSE_PrepareDispatchDecision` and applied to raw callbacks' declared gate) and `_OnPrefixChar` drops an expired winner before the @-combo and repeat fallbacks; AHK test `expired-winner-repeat` written, not run here.

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
- [x] **[CODE] PIL-003:** Missing first-boot personal-info file prevents editor initialization and source creation. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/linux/report.md). Done: init materialises a missing personal_info.toml from the shared placeholders (\_shared/lua/personal_info/defaults.lua, also the macOS source), so the editor captures and saves on a fresh install; test personal-first-boot.
- [x] **[CODE] PIS-001:** Shared prefix counts advertise mappings that are not generated for unspaced personal values. [Evidence and regression direction](docs/audits/platform-parity/2026-11-05-sequential/personal-info/shared/report.md). Done: compute_prefix_counts takes the SSN and IBAN as stored and counts the spaced trigger only when it differs from the raw one (shared helper, macOS, Linux and Windows CountDynamicSection, corpus vectors updated).

### Policy, documentation and verification debt

- [ ] **[CI] Native Lua acquisition:** qualify current-source macOS LuaSocket/native-client build and launch after Lua.org timeouts; the upstream byte-identical Debian mirror changes for Linux and macOS are integrated, and targeted fetch/refusal controls pass. The earlier failed CI sources predate the macOS mirror fix. Preserve exact hashes and native receiving requirements. [Delivery evidence](docs/audits/platform-parity/2026-11-05-sequential/delivery.md).
- [ ] **[CI] Native keyboard-source fixture:** investigate selection-deadline/cleanup-unavailable refusals seen before and during this audit; the targeted retry passes, but that does not establish a repaired cause. Keep failed receipts and exact required cohorts.

- [x] **[CODE] Personal-info documentation:** replace obsolete Windows-preview-not-wired claims in shared README; audit the metadata-only missing localization key separately from the working translated menu caption. Done: the obsolete Windows-not-wired section of the shared README now describes the AutoHotkey mask twin; the metadata-only missing localization key is noted as a separate audit (not fixed here).
- [x] **[PARITY] Personal aliases and preparation (alphabets documented in the shared personal_info README; Windows eager pre-generation cost moved to « To confirm on the Windows PC », macOS Unicode aliases tracked below):** document allowed alias alphabets per OS; qualify or bound Windows eager pre-generation at accepted high pattern settings without claiming a measured hang. Preserve actual dynamic-resolution alternatives on Lua.

- [x] **[PARITY] Linux WPM:** clarify whether no-tray means headless or floating-widget-capable; qualify GTK pumping accordingly. Review an explicit recovery surface for guarded rollback debt without bypassing its fail-closed admission. Done: decided 2026-11-06: the floating widget does not depend on the tray (Windows and macOS draw it without one); the daemon now pumps the widget's own GLib context (wpm_surface.pump). The guarded-rollback recovery surface stays fail-closed.
- [x] **[PARITY] Wrap management:** decide Windows supplementary Unicode scalar support; its UTF-16-length validator currently rejects scalar pairs accepted by macOS. Linux custom pair management is already tracked above; parameter-specific custom delimiters are available. Done: decided 2026-11-06: Windows accepts a supplementary scalar as one custom symbol like macOS and Linux (see the wrap-scalar commit).
- [x] **[CODE] Wrap documentation:** correct the shared catalogue README claiming two drivers and obsolete open/close/label_key shape; retain trigger normalization separately from spaced output delimiters. Done: the shared catalogue README now names the three drivers, the real {left, right} group shape, and keeps trigger normalization separate from spaced output delimiters.
- [x] **[CI] macOS wrap fixtures:** remove combined-run module-cache/i18n contamination: the combined selection reports 255 passes and four failures while the affected delivery fixture alone passes 12/0. Do not replace actual production owners with more forgiving stubs. Done: the delivery fixture now loads the real i18n and a fresh gestures owner instead of a get-only i18n double; the combined --only=wrap run passes 266/0.

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
- [ ] **[CODE] MRT-004:** Advertised reinstall route always refuses an already published runtime needing service recovery. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/macos-runtime/report.md). Decided 2026-11-06: a localized « Réparer le service » action backed by a new authenticated helper role ([maintainer decision](docs/memory/maintainer-decisions.md)). Open: the role must adopt an existing exact Core/VirtualHIDDevice plist and settle the first-start `core.json` fence, which today's provision owners refuse; it needs a Swift build and native macOS qualification. Windows and Linux have no installed privileged remap service.
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
- [x] **[CODE] LDG-003:** Refused timer admission leaves the configuration diagnostic pending without a completion path. [Reproduction and limits](docs/audits/platform-parity/2026-11-05-native-ui/linux-diagnostics/report.md). Fixed on `fix/linux` by cc280519f5 (unarmed configuration and CPU timers finish with an error); closes when that branch merges. Done: already on dev: probes.lua checks timer admission (handle.armed) and finishes configuration and CPU with an error; test healthcheck-timer-refusal fails (nil configuration answer) when that check is removed and passes with it.

### Qualification and policy follow-up

- [ ] **[NATIVE]** Exercise the retained runtime/editor/diagnostics receiving boundaries on Windows and macOS, and the Linux live GTK/session flows. Replay refused writes, native timer admission, stale epochs and physical cleanup; the private models do not certify these boundaries.
- [x] **[POLICY] macOS local crash reports:** clarify raw local error/stack retention versus the existing no-PII comment; Windows explicitly keeps full local crash detail and Linux redacts before persistence. Shared exported diagnostics and day logs pass the canary control. No network disclosure or mandatory identical local retention policy is established. Done: decided 2026-11-06 (see maintainer-decisions): macOS redacts the whole report through the logger redactor before opening it and refuses the report if the redactor cannot answer, as Linux does; test crash-redaction.
- [x] **[COVERAGE] Windows managed-runtime fixture:** update or retire the unregistered legacy direct-child bootstrap fixture; the registered current fixture correctly uses the nested managed path. Do not treat the old fixture as a product install failure. Partly done: the fixture now nests its root like the registered one (source guard in `test-windows-managed-bootstrap.cjs`); it holds the only reuse and runtime-receipt retirement cases, so registering it in `ci-windows.yml` remains, after a first native Windows run (hardware only, listed under « To confirm on the Windows PC »). Moved 2026-11-06: the code part is done (85fa0cfee, nested root guarded by `test-windows-managed-bootstrap.cjs`, re-run green); registering it in `ci-windows.yml` needs that first native run and lives under « To confirm on the Windows PC ».

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
- [x] **[CODE] MUR-001:** Refused restart reports a retained armed installation as failed and idle. [Reproduction, limits and regression direction](docs/audits/platform-parity/2026-11-04-recovery/macos-updater/report.md). Done (decision 2026-11-06): the shared session holds it as `restart_pending` with « Redémarrer maintenant » on the page and in About; macOS reports it not installed once the swap worker stops waiting. Linux shares the state; Windows cancels its worker, so its failure is true.

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

- [x] **[CODE] macOS chosen-release updater:** evaluate an equivalent of Windows successor boot-ready/probation and post-launch recovery. The custom armed swap currently observes dispatch/rename, not a healthy successor; Sparkle is a distinct engine. Preserve intentional ARMED-on-quit semantics and record any deliberate lower guarantee. [Compared contracts](docs/audits/platform-parity/2026-11-04-recovery/capabilities.md).
      Done: the swap opens the chosen app with a one-shot boot-ready token, keeps it once `infra/updater_boot_ready.lua`
      writes the launcher pid (boot complete, Accessibility wait or onboarding) within 60 s and it survives a 0.75 s
      probation, and otherwise stops it, moves it to `$app.failed-<pid>` and puts the previous app back (exit 9).
      ARMED-on-quit is unchanged. Recorded lower guarantees (memory `project-macos-release-swap-keeps-a-build-that-reports-ready`):
      the rollback relaunch is not checked, and an older chosen release without the reporter is only opened. Real
      Mac check under « To confirm on the Mac ».
- [x] **[CODE] Linux standalone updater:** evaluate successor-ready receiving and recovery beyond pre-restart wrapper smoke plus systemd/relay request admission. Windows has the stronger boot-ready/probation contract; an equivalent or an explicit scoped reason remains to be established. [Compared contracts](docs/audits/platform-parity/2026-11-04-recovery/capabilities.md).
      Done: the restart on an installed update runs under a watcher (the relay itself, or a `systemd-run` transient
      unit under systemd) that keeps the new tree once `infra/updater_boot_ready.lua` reports the daemon pid within
      60 s and it survives 0.75 s; otherwise it stops it, moves the tree to `<root>.failed-<pid>`, puts `<root>.old`
      back and starts the previous daemon. A refused restart or a Quit stops the watcher first. Lower than Windows,
      recorded in memory `project-linux-update-restart-is-watched-until-the-daemon-reports`: the rollback start is
      not watched and a tree without the reporter is only started. Live check under « To confirm on Linux ».

## End-to-end parity follow-up

Evidence: [12-scope flow review](docs/audits/platform-parity/2026-11-04-flows/report.md). These are OS/flow work items, not a claim of 26 unique causes or native acceptance. Preserve intentional policies and all current refusal guards.

### Windows

- [x] **[CODE] WCP-001:** Selection startup can clear and copy after an external foreground-window change. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-clipboard/report.md). Done: f46ad9430 refused a changed focused control before each startup step; `_SelectionCaptureStartCurrent` now also compares the foreground window and the physical-input generation, so a newer key press or an external window change refuses before the clear and the Ctrl+C (`test_hotstring_send_failure_containment.ahk`, selection-startup-revocation: foreground, focus and generation at every startup boundary).
- [x] **[CODE] WCP-002:** Selection transformations can paste into a new window after clipboard preparation. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-clipboard/report.md). Done: f46ad9430 and a9781a14f carry the window/control target, with a pause and physical-generation admission, from the selection request to `SendInstant`'s paste (case transforms, gesture wrap, typed wrap). The plain-paste sibling now does the same: `GesturePastePlain` captures `_SendInstantCaptureAdmittedTarget()` and rechecks it before replacing the clipboard and before every paste chord (`test_clipboard_paste_transaction_ownership.ahk` modes drift-target, drift-pause, paused; `test_hotstring_send_failure_containment.ahk`, sendinstant-admitted-target).
- [x] **[CODE] WCR-001:** Marker-prefixed raw typing bypasses the protected SQL text encryption path. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: `KL_Enc_Encrypt` seals every nonempty raw value; only the migration skips stored envelopes; cipher, writer and decrypt-pass regressions added (rows already stored as clear lookalikes, and clear-mode lookalikes, stay a storage-format decision).
- [x] **[CODE] WCF-001:** Widget coordinates can persist a mixed pair after failed compensation or reentrant position writes. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-config/report.md). Initial refusal is logged; preserve/recover the promised durable pair. Reentrant native timing remains conditional. Done (decision of 2026-11-06, atomic publication): the pair is one Storage value `[x, y]` under the canon key `position.storage_pair`, written by one registry write; a refusal leaves the previous pair whole and no compensation write exists (`test_wpm_config_types.ahk`, mode `later-writes-refused`).
- [x] **[CODE] WDS-001:** Ordinary application quit discards failed window-close receipts. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-desktop/report.md). Done: refused WM_CLOSE receipts are counted; all-refused logs an error, partial or windowless quits a warning (`test_system_actions.ahk`, wds-001).
- [x] **[CODE] WDS-002:** Recycle Bin worker failure after successful launch has no completion observer. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/windows-desktop/report.md). Done: the worker runs through `SystemControl.SpawnObserved` (ShellRunner); a refused start, a throw or a nonzero exit with its output is logged as an error (`test_system_actions.ahk`, wds-002).

### macOS

- [x] **[CODE] MCP-001:** Apps selection capture restores an obsolete clipboard over a newer copy. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md). Done: once the selection is read, Apps restores only over the generation it read (conditional `Clipboard.restore` receipt, as Search does) and revokes the snapshot after a newer copy.
- [x] **[CODE] MCP-002:** Independent macOS clipboard borrowers snapshot another family’s temporary payload. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md). Partly done: `infra/clipboard_borrowers.lua` is one admission for every family; Text, Apps and Search refuse while another family borrows the clipboard. Done (decision of 2026-11-06, follow Windows' SendInstant): TextSender fast paste and keymap output now ask the same admission and type the text as keystrokes while another family borrows the clipboard (`test_borrowed_clipboard_output_types.lua`); a deferred keymap paste that comes due during a borrow is typed too.
- [x] **[CODE] MCP-003:** Ordinary delayed selection transforms paste captured text into another focused app. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-clipboard/report.md). Already fixed by 0bee16fce: every ordinary transform, plain paste and wrap captures its classified destination at admission and rechecks it before the deferred copy and paste. Checked on dev: with that change reverted, `test_selection_translation_focus_lifecycle.lua` ("does not paste an uppercase selection after focus moves") and `test_plain_paste_focus_real.lua` ("plain/wrap refuses changed focus") fail.
- [x] **[CODE] MCR-001:** Encryptor source conversion can destroy an approved overwrite target on failure. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Approved overwrite is required; improve failure-safe replacement. No unconsented overwrite or explicit atomicity promise is asserted. Done: `encryptor_convert.sh` converts into a stage next to the destination, renames it over the target only on success and removes only that stage on failure.
- [x] **[CODE] MCR-002:** Encryptor hidden password is embedded in shell command arguments. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the password goes into a private file read by `-pass file:` through the bundled `encryptor_convert.sh`; `main.scpt` is rebuilt by the field run's `scpt_recompile` step.
- [x] **[CODE] MCR-003:** Raw envelope-prefixed typed text bypasses macOS SQL payload encryption. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: the shared `text_cipher.encrypt` seals every nonempty raw value; the shared raw-ingress contract runs on macOS (clear lookalike rows stored before the fix stay a storage-format decision).
- [x] **[CODE] MCR-004:** HuggingFace login credential is embedded in native bash argv. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the token is queued on the login task's stdin before start and Python reads it there; the bash/Python arguments carry no credential.
- [x] **[CODE] MCR-005:** Failed API secret replacement restores old metadata pointing to overwritten Keychain value. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: a replaced token is written to a fresh account `<id>#r<n>`; the superseded account is retired only after the new reference commits, so a rollback still resolves to the old secret.
- [x] **[CODE] MCR-006:** Refused migration slice timer leaves successful-start receipt and permanently running idle pass. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-crypto/report.md). Done: the shared driver reads the timer's committed flag; a refused slice pauses the pass (cursor kept, error logged) and start/resume report false.
- [x] **[CODE] MCF-001:** Rejected locale changes publish canonical config before reload or settings admission. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/macos-config/report.md). Shared rejected-locale publication root; retain the macOS timer-race subtype and Linux startup control. Done: the audited refusals already restore the config row (b63fad4be5); the remaining timer-race subtype is fixed: a refused later switch now re-arms the reload an accepted earlier switch still owed (timer and settings refusal regressions).

### Linux

- [x] **[CODE] LCP-001:** Clipboard borrowers restore only text and silently discard other original formats. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md). Done (aligned on Windows/macOS: nothing is lost): every borrower lists the clipboard formats (xclip TARGETS, wl-paste --list-types) and refuses before its first write when anything beyond text is present; xsel, which cannot list formats, refuses too. Restoring the extra formats themselves needs a native multi-target selection owner (wl-copy and xclip offer one type): follow-up below.
- [x] **[CODE] Linux multi-format clipboard restore:** a small native owner serving every saved target (X11 selection owner, Wayland data-control/data-device) would let Linux borrowers run on rich clipboards instead of refusing them (LCP-001). Done (aligned on Windows/macOS): a clipboard holding formats beyond its text is saved target by target (xclip `-t`, `wl-paste --type`) and restored by `linux/adapters/clipboard_owner_worker.lua`, a LuaJIT FFI child that takes the X11 CLIPBOARD (libX11, TARGETS/TIMESTAMP, INCR above one request) or the Wayland selection (ext-data-control-v1, else wlr-data-control, libwayland-client as an optional FFI library) and forks once it owns it, as xclip and wl-copy do; it exits when another client copies (`test_clipboard_snapshot_restorability.lua`, multi-format restore; `tests/hardware/run_clipboard_owner.lua x11|wayland`, run on Xvfb and headless sway). The refusal stays where the owner cannot run (GNOME Wayland has no data-control, xsel cannot list formats), when one advertised format cannot be read, above 64 MiB, and for a clipboard with no text form (an image alone), since every borrower identifies the clipboard by its text.
- [x] **[CODE] LCP-002:** Text transformations overwrite an intervening external clipboard copy. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md). Already fixed on fix/linux: e0ba9808b restores after a transform only while the clipboard still holds the replacement, be57d9d09 does the same after a selection read, ad0e9483d refuses to restore over an unreadable clipboard. Checked on dev: with an unconditional restore, `test_clipboard_selection_transaction.lua` ("keeps a new clipboard copy made while the replacement settles", "keeps another copy made after reading the selection", X11 and Wayland) fails.
- [x] **[CODE] LCP-003:** Case and wrap transformations can replace a changed selection in the same text field. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md). Done: when the application publishes the copied range as PRIMARY, the transform rechecks PRIMARY right before Ctrl+V and refuses (`selection_changed`, clipboard restored) on a changed or unreadable range. An application that does not publish PRIMARY keeps the field-only check; a different range holding identical text is not distinguishable this way (the AT-SPI range receipt of `selection_transaction` would be).
- [x] **[CODE] LCP-004:** URI clipboard probing can send Ctrl+C to an unvalidated terminal, including an unchanged terminal through make_executable_selection. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/report.md). Already fixed on fix/linux: 9a0caf89a admits make_executable_selection only from a focused file manager, 9c6cc3d4b binds both URI probes to the file manager's native window and sends Ctrl+C only while that window is still focused. Checked on dev: without the guarded press, `test_open_selection.lua` (copy-same-app-window) and `test_system_actions.lua` ("refuses make-executable when focus changes before/after copy") fail.
- [x] **[CODE] LCR-001:** Raw marker-prefixed typed text bypasses encryption and can abort decryption migration. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-crypto/report.md). Shared root: typed-text envelope-prefix admission; implement and test all three ingress/migration paths together. Done: same shared fix and contract on Linux; a decryption pass now restores marker-prefixed literals (clear lookalike rows stored before the fix stay a storage-format decision).
- [x] **[CODE] LCR-002:** Secret-tool stdin write refusal can still publish a successful API credential reference. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-crypto/report.md). Already fixed by a8f314359: `run_tool` returns no status unless the stdin write and the pipe close were both acknowledged. Regression added: a real shell stand-in that reads only the first 3 key bytes and exits 0 no longer yields a reference (`test_api_entries_secret_service.lua`, linux-secret-tool-write-refusal; fails with the write acknowledgement ignored).
- [x] **[CODE] LCF-001:** Failed legacy alias cleanup resurrects a later accepted neutral preference. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-config/report.md). Done: the import writes `_meta.linux_legacy_storage_imported = true` in the same batch as its leaves; a later start that finds the mark only retries the removal, so a neutral choice saved meanwhile survives.
- [x] **[CODE] LCF-002:** Rejected locale change remains canonical startup authority after native alias refusal. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-config/report.md). Shared rejected-locale publication root; retain the macOS timer-race subtype and Linux startup control. Already fixed: b63fad4be5 on this line and a11e87d025 on fix/linux restore the configured row when the native alias is refused; the absent-row startup control is unchanged. Nothing redone here to avoid a test-file conflict.
- [x] **[CODE] LDS-001:** Desktop command producer hides both shell acquisition and background child failures. [Evidence and required boundary regression](docs/audits/platform-parity/2026-11-04-flows/linux-desktop/report.md). Partly done: a refused background shell is now logged; the child's own exit status and stderr still have no owner (open). Done (follow Windows' SpawnObserved): one-shot commands (system commands, direct commands, screenshots, system-action handlers) run through `modules/gestures/background_commands.lua`, whose background shell leaves the child's status and stderr in a private session folder; a deferred collector logs a nonzero exit as an error, stderr withheld for commands that can name user files (`test_background_commands.lua`, background-child-lds-001). Application launches (xdg-open, gtk-launch, settings apps) keep the detached path: their child is the application.
- [x] **[CODE] LDS-002:** Serialize independently accepted Linux theme read-modify-write toggles; overlapping calls currently lose one transition. [Public-dispatch reproduction and controls](docs/audits/platform-parity/2026-11-04-flows/linux-desktop/report.md). Done: toggle_dark_mode and show_desktop queue on one flock in the session lock folder; a real-shell test runs two overlapping toggles.

- [ ] **[PHYS-W] / [PHYS-M] / [PHYS-L]:** execute only the receiving scenarios named by each flow report on isolated native hosts. Source/recording-port tests do not close native focus, selection, keyring, application or device qualification.

## Deep OS × module follow-up

Audited source and immutable evidence: [18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md). These entries are implementation/validation work, not permission to remove deliberate safety checks or silently change explicit product contracts. Intentional differences and unresolved rationale are in the [provenance register](docs/audits/platform-parity/2026-11-04-deep/intentional-differences.md).

### Windows

- [x] **AHK-001 / WH-001:** Reload of a repaired programmable source clears its problem but leaves callback admission disabled. [windows-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/windows-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Fixed: a successful programmable-source Reload restores the configured callback admission; regression test added.
- [x] **AHK-002 / WI-001:** LAlt Tab tap with explicit None hold still activates navigation. [windows-input evidence](docs/audits/platform-parity/2026-11-04-deep/windows-input/report.md). Implement the stated boundary regression before claiming closure. Fixed: Tab immediate-layer mechanics now require a hold layer, so Tab tap + None hold is a plain tap; meta regression added.
- [x] **AHK-003 / WI-002:** Composer Save-and-use treats pending selection launch as completed active layout. [windows-input evidence](docs/audits/platform-parity/2026-11-04-deep/windows-input/report.md). Implement the stated boundary regression before claiming closure. Fixed: Composer Save-and-use now publishes used only when the selection reload commits (new LayoutManager_SelectSettled), failure on later refusal; regression test added.
- [x] **AHK-004 / WM-001:** Movement-only pointer distance is silently excluded from every typing-buffer flush. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure. Already fixed: f7207d6a1 (Windows, both empty-state predicates count `mouse_distance`; registered `mouse-distance-flush-owner` child tests cover direct, periodic and click-control flushes) and 1253c00b3 (macOS `_detach_buffer_snapshot`, `test_log_manager` « flushes mouse travel alone »; re-verified 2026-11-06 failing with the predicate removed). Linux already emitted distance-only rows.
- [x] **AHK-005 / WM-002:** Enabled metrics encryption leaves typed text and per-key events in durable plaintext today.log. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure. Fixed (Windows and macOS, which shared it): with encryption on, a typing row's `text`, `rich_text` and `events` are sealed in today.log under a `_sealed` flag (`KL_JournalSealEntry` / `_shared/lua/keystats/journal_seal.lua`) and reopened by the journal reader; a failed seal keeps the row queued, an unopenable row holds the checkpoint. Rows journaled before the toggle stay until the day rollover (documented in keystats_privacy.md). Regressions `test_keystats_journal_sealing.ahk` (unrun on Linux) and macOS `test_journal_sealing.lua`; the envelope parity gate pins the field list. Linux has no journal. Left: macOS still stores `events_typing.rich_text` in clear in SQLite (Windows and Linux store it empty).
- [x] **AHK-006 / WM-003:** Explicit dashboard cache Reset preserves and reuses its durable reader image. [windows-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/windows-metrics/report.md). Implement the stated boundary regression before claiming closure. Fixed: explicit cache Reset now retires the durable reader image (KLR_CacheRetire) before the successor build; regression tests added.
- [x] **AHK-007 / WG-001:** Onboarding publishes success when Precision Touchpad restart is absent or fails. [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure. Fixed: onboarding PnP worker now fails on no device or refused disable/enable and re-enables disabled devices (same contract as the tray restart worker); regression test added.
- [x] **AHK-008 / WG-002:** Existing invalid touchpad backup authorizes destructive registry configuration. [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure. Fixed: an existing touchpad backup must parse as restorable before any apply or onboarding elevation; regression test added.
- [x] **AHK-009 / WG-003:** Onboarding cross-account UAC writes elevated administrator HKCU instead of original user hive (conditional two-account UAC scenario; native confirmation still required). [windows-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/windows-gestures/report.md). Implement the stated boundary regression before claiming closure. Fixed: the wizard writes the values in the resident process through `TouchpadRegistryApply` (as the tray action does) and elevates only the registry-free touchpad restart (`_GestureRestartBuildPsScript`); the elevated registry writer and its PowerShell table are gone. Regressions in `test_touchpad_registry.ahk` (WG-003) and the path-encoding child (unrun on Linux), plus `test-touchpad-registry-single-source.cjs`. The real two-account UAC check is under « To confirm on the Windows PC ».

### macOS

- [x] **HS-001 / MH-001:** Programmable static preview metadata is parsed as output tokens on macOS. [macos-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/macos-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Done: programmable previews render literally (rules engine marks them; llm_bridge skips token projection); regression test_programmable_preview_literal.
- [x] **HS-002 / MI-001:** Catalogue layer_on/layer_off actions do not synchronize the macOS navigation wheel owner. [macos-input evidence](docs/audits/platform-parity/2026-11-04-deep/macos-input/report.md). Implement the stated boundary regression before claiming closure. Done: catalogue layer_on/layer_off publish the nav layer to the wheel once their write settles (newest intent wins); regressions in test_karabiner_actions_reachable.
- [x] **HS-003 / ML-001:** Sequential local streams and retries share a request-scoped cumulative thinking filter. [macos-llm evidence](docs/audits/platform-parity/2026-11-04-deep/macos-llm/report.md). Implement the stated boundary regression before claiming closure. Done: each sequential MLX/Ollama variant streams under its own identity and the handler resets its filter only at that boundary; retries no longer stream; regression test_sequential_stream_identity.
- [x] **HS-004 / MM-001:** Metrics collection pause still records window activity and later credits paused pointer travel. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure. Done: the metrics pause withholds window titles, app switches, sensors, passive intervals and pointer travel, closing the app interval at pause and restarting timing at resume; regression test_context_tracker_collection_pause.
- [x] **HS-005 / MM-002:** macOS measured passive sleep and lock durations remain zero in dashboard aggregates. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure. Done: the aggregator credits measured sleep and lock periods to sleep_ms and locked_ms ; aggregate cache revision 5 (8b1e19f0ef) rebuilds past days; regression test_passive_period_durations.
- [x] **HS-006 / MM-003:** macOS keep-awake completion events never populate keep-awake accounting. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure. Done: finished keep-awake sessions count once toward awake_ms (per-app attribution left out, as on Windows); regression in test_passive_period_durations; past days recovered by the cache revision 5 rebuild.
- [x] **HS-007 / MM-004:** macOS nested lock and sleep transitions overwrite passive interval ownership. [macos-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/macos-metrics/report.md). Implement the stated boundary regression before claiming closure. Done: a lock closes an open sleep period first and a repeated lock keeps its first start, so passive intervals no longer overwrite each other; regression in test_watchers_lifecycle_transaction.
- [x] **HS-008 / MC-001:** Failed onboarding Finish retains new configuration locator and locale. [macos-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/report.md). Implement the stated boundary regression before claiming closure. Done: a failed onboarding Finish restores the previous folder and locale (refused writer, newer-schema destination, unresolved path, refused locale) without overwriting a newer folder choice; regression test_onboarding_failed_finish_restores_choices.
- [x] **HS-009 / MC-002:** Restored configuration UI promises restart despite refused or throwing reload. [macos-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/macos-lifecycle/report.md). Implement the stated boundary regression before claiming closure. Done: a refused, raising or aborted restore reload now reports phase failed (restore_error_unexpected with the pre-restore copy path), as on Windows, instead of promising a restart (macOS and Linux); regressions in each driver's test_changelog_release_install.
- [x] **HS-010 / MG001:** System-gesture preference probes never start their prepared ShellRunner tasks. [macos-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/macos-gestures/report.md). Implement the stated boundary regression before claiming closure. Done: already fixed on the base by a89dd75544 (the gesture settings read now starts); covered by test_conflict_probe_start.
- [x] **HS-011 / MG002:** Tap commit dispatch bypasses the macOS system-gesture conflict gate. [macos-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/macos-gestures/report.md). Implement the stated boundary regression before claiming closure. Done: the tap commit asks the same macOS system-held conflict gate as swipes before dispatch; regression test_tap_system_conflict_gate.
- [x] **Two copies of the app erase each other's Accessibility grant (field report 2026-11-05).** A local build (`build/macos`, local self-signed certificate) and the `/Applications` dev prerelease (CI certificate) share `com.ergoptiplus.app.hammerspoon`. The switch the user turns on can match the other copy. The copy that boots is then not trusted, and `infra/accessibility_wait.lua` runs `tccutil reset` on the bundle id, which removes the switch at every reload. The field run's installer now unregisters every other copy before it opens the app; the app itself still needs the fix: before the reset, find every registered copy of the bundle id (LaunchServices) whose signature differs from the running one, and name its path in the guidance dialog instead of resetting in a loop. The boot now resets the entry once per install (version, device and inode of the launcher) and shows only macOS's own prompt. `ui.permission_dialog.guide_accessibility`, its tests and its locale strings are now unused: retire them.
      Done: before any reset the wait asks `adapters/accessibility_copies.lua` (LaunchServices and Spotlight, then
      `codesign -d -r-` against the running copy's designated requirement) for the other copies; when one differs the
      entry is left alone, macOS's prompt is shown and `permission_dialog.name_other_copies` names their app paths
      (again on each reopen); a failed probe resets as for a lone copy. `guide_accessibility` and the
      `permission_dialog.accessibility.*` strings are retired, the new `accessibility_copies` kind has 21 locales. The
      two-copy scenario on a real Mac is under « To confirm on the Mac ».
- [x] **Owned runtime: the helper's own report path still demands two code hashes (field report 2026-11-05).** The published helper carries one SHA-256 code directory per slice. The launcher now admits one or two (`OwnedRuntimeInstallMainOperation.codeDirectoryHashes`), which unblocks the install. `OwnedVirtualHIDDaemonReportStageOwner.admitImage` is compiled into the helper and still requires `hashes.count == 2`; switch it to the same rule at the next runtime rebuild. The install acceptance (`tools/build/owned_runtime_install_acceptance.sh`) runs the helper directly with sudo and never exercised the launcher's check; drive it through `--request-owned-runtime-install` instead.
      Done: `admitImage` reads the hashes through `OwnedRuntimeInstallMainOperation.codeDirectoryHashes`, the one rule
      (`test-macos-owned-runtime-code-hash-rule.cjs` keeps every launcher read of `kSecCodeInfoCdHashes` on it); ships with
      the next runtime rebuild. The launcher role asks for an AppleScript administrator prompt, which a hosted runner
      cannot answer, so driving the acceptance through it is a Mac check under « To confirm on the Mac ».
- [x] **Field checks report a missing owned runtime as broken config.** With the owned runtime selected but not admitted, nothing is generated: `field_tap_hold_thresholds` fails `unreadable` on the never-created `karabiner.json` (`adapters/field_check_ports.lua:121-149`), and `field_tap_copy` counts the nil deployed timeout as short (`infra/field_check_tap_copy.lua:72-74`). Both should report `skip:runtime_not_admitted`. Done: already fixed on the base by b1e99eb01b (thresholds skip `owned_runtime_not_ready`, tap copy skips `not_deployed`).
- [ ] **Field run follow-ups from the 2026-11-05 report (30 pass, 12 fail).**
  - `field_lease` runs before `field_owned_install` in `data/field_run.json`: move it after `owned_install_reload`, and report `cli_present`, `guardian_state` and `cli_version` as `skip:owned_runtime_not_admitted` without the 30 s guardian wait when the owned runtime is not admitted (`infra/field_check_checks.lua:129-171`). Its `config_present` reads the shared `~/.config/karabiner/karabiner.json` instead of `KePaths.config_file_for(KePaths.selected_runtime())`. Done (0dc5c48479).
  - `field_owned_runtime` fails `capture_unloaded` on every owned boot: `runtime_owner_ports.new()` loads `physical_capture` eagerly (`adapters/runtime_owner_ports.lua:294`). Make that check info now that owned is the default, or the require lazy. Done: now an info step (89e046e0ed); a lazy require cannot hold once the owned capture runs.
  - `field_owned_start` fails `user_karabiner_closed` when the runtime is not ready; leaving the user's Karabiner-Elements running is then correct (`infra/field_check_owned_activation.lua:88-95`): `skip:runtime_not_ready`. Done (d05e9b9dbe).
  - `field_owned_pause` is rolled back by Ollama: a serve task that exited 78 leaves its start cleanup unsettled, `pause_warmup` returns false (`modules/llm/api_ollama.lua:571-592, 714-735`), and the global pause gives up. A dead, unpublished daemon must not block the pause. Done 2026-11-06: maintainer decision, a dead unpublished daemon is released from the pause (`release_unpublished`, logged); see docs/memory/maintainer-decisions.md.
  - The managed Ollama daemon itself exited 78 ("operation"): the next report names the primary and cleanup failures (`managed_ollama_serve.py` now prints both). Done earlier (44900c09fa, efab6194d5).
  - `key_accounting` fails `window_unfocused` intermittently: the first key asks `hs.window.focusedWindow()` once, 0.6 s after the scratch window shows, and a 523 ms main-thread hold made it miss (`adapters/field_probe_ports.lua:711-714, 799`). Wait for the window's own focus report, and give the two refusal sites distinct tokens. Done: Accessibility is asked only after the window's own focus report, refusals `window_unfocused` / `focus_unreported` / `ax_window_mismatch` (a7143d5ac6).
  - `diagnostics` fails `phase_a_budget` at 5.2 ms against 5 ms: phase A's permissions section calls `hs.accessibilityState` and `screenRecordingState` live (`ui/healthcheck/helpers.lua:436-461`), which breaks the schema's rule that phase A reads memory only. Cache both from the boot and screen-capture reads, or make them a probe; keep the 5 ms budget. Done: phase A reads the cached last live answers, unknown before the first read (c94c7dfe2a, 23ee43ba52).
  - The managed Ollama daemon still fails at the native guardian (`platform/suspended_image_owner.py`, `V1 REFUSED <errno>`); the next report names the errno (`cleanup_guardian_refused`) and the installed app's strict signature (`app_signature` step). Done earlier: `cleanup_guardian_refused` and the `app_signature` step exist.
  - **A resting thumb turns a 2-finger swipe into a 3-finger one** (20:06, `tab_close` fired; also a held `tap_3` left click at 20:04). The join gate accepts a third contact after 20 ms with no spatial check (`modules/gestures/engine.lua:1193, 1204-1228`, cohesion `:301-321`); that contact sat about 60 units from the pair. Log each contact's position and `majorAxis` when a count is accepted, calibrate a max finger gap from the next report, then refuse a far or oversized contact at both join paths and at the 3-finger tap commit, with the three cases of the field report as regression tests. Logging done: both join paths log each contact's position and major axis (`Geometry.describeContacts`). Open: the refusal needs the next field report's positions to calibrate; Linux's `mt_decoder` join has no spatial check either and takes the same rule then.
  - After "Restore recommended", show the Trackpad settings dialog when a recommended slot is still claimed by macOS (`ui/menu/menu_gestures.lua:420`); the restore never touches macOS settings. Add a read-only `defaults read` of the Trackpad and Dock gesture keys to the Mac field report. Done (70ff74f1c6, a42c702a85; the Dock read covers only the gesture switches).
  - The tap commit skips the macOS conflict gate (HS-011 / MG002, `modules/gestures/engine.lua:708`). Done with HS-011.
  - The Mac's LogsDirPath still ends in the old `ergopti_plus` folder, so logs land in `…/ergopti_plus/Ergopti/`; the migration only rewrites old default folders. Open: needs the real value from the Mac and a decision on renaming a custom folder named like the old app folder.

### Linux

- [x] **LIN-001 / LH-001:** Registered single-field dynamic expansions have no production preview row. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Done: a registered single-field dynamic match (@-tag letter or date) yields its own masked preview row, the only row offered, as at fire time; regression single-field-preview.
- [x] **LIN-002 / LH-002:** Invisible previews increment offered-suggestion metrics. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Done: suggestion metrics count only previews show() reports drawn, and a refused offer sets no dedup key; regression invisible-offer-metrics in test_dynamic_dry_run_dispatch.
- [x] **LIN-003 / LH-003:** Built-in dynamic expansions bypass configured expansion-delay admission. [linux-hotstrings evidence](docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/report.md). Implement the stated boundary regression before claiming closure. Done: built-in dynamic expansions (dates, @-tags, @-combos) honour the expansion delay read under dynamichotstrings/section; regression dynamic-expansion-delay.
- [x] **LIN-005 / LL-001:** Interrupted Ollama chat overwrites successor admitted by cancellation terminal callback. [linux-llm evidence](docs/audits/platform-parity/2026-11-04-deep/linux-llm/report.md). Implement the stated boundary regression before claiming closure. Done: Ollama chat yields to a successor started by a cancellation callback, and cancel() no longer silences a successor started during native cancellation; regressions in test_api_ollama_terminal_receipt.
- [x] **LIN-006 / LL-002:** Refused translation dispatch leaves permanent loading offer. [linux-llm evidence](docs/audits/platform-parity/2026-11-04-deep/linux-llm/report.md). Implement the stated boundary regression before claiming closure. Done: a translation whose backend dispatch is refused clears its own loading offer, like an ordinary prediction; regression ll-002 in test_translate_selection.
- [x] **LIN-007 / LM-001:** Excluded collection spans remain inside typing sequences and durations. [linux-metrics evidence](docs/audits/platform-parity/2026-11-04-deep/linux-metrics/report.md). Implement the stated boundary regression before claiming closure. Done: keys typed after a collection exclusion start a new walk (context settled, no inter-key delay or typing interval across the excluded span); regression test_excluded_span_boundary.
- [x] **LIN-008 / LC-001:** Configuration restore announces restart even when restart is refused or unavailable. [linux-lifecycle evidence](docs/audits/platform-parity/2026-11-04-deep/linux-lifecycle/report.md). Implement the stated boundary regression before claiming closure. Done: a refused, raising or aborted restore reload now reports phase failed (restore_error_unexpected with the pre-restore copy path), as on Windows, instead of promising a restart (macOS and Linux); regressions in each driver's test_changelog_release_install.
- [x] **LIN-009 / LG-001:** Linux advertises and accepts three unreachable horizontal-axis gesture slots. [linux-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/linux-gestures/report.md). Done: maintainer decision of 2026-11-06 (implement, not hide; docs/memory/maintainer-decisions.md). 312bb581 makes a straight left/right swipe whose direction slot is unbound run `swipe_N_horiz`; `test_gesture_axis_slots.lua` drives evdev frames to the emitter and checks every offered slot has a route. Real-hardware acceptance is under "To confirm on Linux".
- [x] **macOS axis slots:** the macOS engine never reads `swipe_3_horiz` / `swipe_4_horiz` / `swipe_5_horiz` (`macos/modules/gestures/engine.lua` resolves only `swipe_N_<direction>` through `Geometry.slotForDir`), so the recommended `words` / `spaces` axis bindings and any user binding on them do not fire there either. Bring it onto the Linux rule of 2026-11-06 (direction slot first, axis slot for an unbound left/right, sign from the travel for an axis action) with a commit-path and live-fire regression; found while implementing LIN-009, not audited. Done: `engine.lua` `resolveSwipeSlot` runs the explicit direction slot first and the axis slot for an unbound straight left/right swipe, on the commit and live-fire paths; regression `test_gesture_axis_slots`. Windows has no axis or vertical-axis slots (the OS recognises the gestures); no `swipe_N_vert` slot exists on any OS.
- [x] **LIN-010 / LG-002:** Clearing persistent MT coordinate registers on lift drops subsequent valid gestures. [linux-gestures evidence](docs/audits/platform-parity/2026-11-04-deep/linux-gestures/report.md). Implement the stated boundary regression before claiming closure. Done: already fixed on origin/fix/linux by f691dffbfe (multitouch slot state retained across gestures); not redone here.

- [x] **Accepted-agent policy:** settle whether pause/AI-off cancels an already accepted deferred connector. WL-001 is a policy hypothesis, not a confirmed defect; see the [self-countercheck](docs/audits/platform-parity/2026-11-04-deep/windows-llm/peer-validation.md). Done: decided 2026-11-06: an accepted deferred connector is refused when the script is paused or the AI is off at the time it starts (Windows is the only system with a deferred connector; macOS and Linux run it on the acceptance itself); AHK test accepted-agent-policy, not run natively.
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
  - `wip/layout-composer-responsive` (landed on dev, branch archived 2026-11-04) — the layout composer page reflows when the window is resized and
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
- [x] **Next: land on `dev`** (done; tag `archive/2026-11-04/wip-layout-composer-responsive`) by rebase and fast-forward when the maintainer asks (never push `dev` or `main` from
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

- [x] **Macos field report 2026-11-02.** Rotation warnings at midnight during the recovery; `event_taps` run loop late:
      main thread held 1.5 s, `menu.rebuild` 1.3 s (`menu_item.shortcuts` about 1 s); `diagnostics` phase A over 5 ms;
      `idle_cost` 8.35 %; Ollama `digest_mismatch` on `granite4:350m-h` twice, after the retry. Then rerun the report
      without touching the Mac.
      Moved (wave 3): the code parts already landed (Shortcuts submenu 3,537 → 177 rows, phase A reads cached
      answers, the layout menu lists its folders once, managed Ollama on 0.40.6 with Range alignment). The report's
      logs are not in the repository, so the midnight rotation warnings, the 1.5 s main-thread hold and the
      `idle_cost` share cannot be reproduced here: the rerun is under « To confirm on the Mac ».
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
      macOS, 6 November: the four script-chord slot rows open the shared action picker, as on Windows, instead of
      inlining the 840-action catalogue each: the Shortcuts submenu fell from 3,537 to 177 rows (unit harness:
      35.5 → 2.6 ms, 5.1 → 0.4 MB allocated per build; field rebuilds grew the heap 13-16 MB and the GC landed in
      this stage, 320-342 ms). Left: the Windows AI submenu is still eager; Linux done 10 November: the tray builds a submenu's GTK
      rows when a dbusmenu client opens it and updates a toggled row in place (native publication of the 1007-row
      tree 125 → 1.2 ms, a toggle 118 → 1.0 ms, RSS 137 → 122 MB, headless SNI host; the shared Lua tree build,
      about 78 ms, is unchanged); macOS `menu_keyboard_layout.sources`
      re-reads the bundle variants from disk per rebuild (57-415 ms spikes) and needs a proven cache contract;
      hs.menubar has no per-row update, so a macOS toggle still rebuilds the root.
      macOS, 6 November (wave 3): no cache: the build was repeating work with one answer. Both Keyboard Layouts
      scopes were listed up to four times per rebuild (input-source map, active version, bundles stage, version
      row) and the bundle's Info.plist and variant stats twice; one per-build snapshot now feeds every reader
      (2 listings, 1 plist read; `test_layout_bundle_external_refresh`, `test_input_sources_version_gt`). Not timed
      on a Mac: the next field report's `menu_keyboard_layout.sources` phase says whether the spikes are gone.
- [x] **AI menu.** "Test a prediction" under the profile row: group model, profile, test, never two separators in a row.
      The test uses a high temperature, bypasses the cache, never a fixed string, and shows the generation time.
- [x] **Generation parameters submenu.** Predictions count, min and max words with no separator; one separator; all the
      context rows at the bottom (two separators become one).
- [x] **Prediction indentation default -3**, recommended -3, all drivers.
- [x] **French punctuation.** Space before `:` in composed `label: value` rows and about 21 strings, with a gate.
      Done before 6 November: `common.label_value` (French « {1} : {2} ») through `LabelValue` / `locale.label_value`,
      fr.json clean, gate `test-french-punctuation.cjs` (no glued high punctuation, no hardcoded `" : "` join), and the
      rendered rows walked in French by `test-ahk-tray-rows-read-as-text.cjs` and both Lua tray walks
      (`_shared/lua/test/menu_row_text.lua`). Rechecked green on 6 November.
- [x] **Multi-prediction tooltip.** The number is right-aligned in the tooltip, not stuck to the text.
- [x] **macOS one-shot Shift is not one-shot.** Tap it then type « abc » quickly: « ABc » or « ABC ». It must be spent
      by the first key; today it seems to end only on its timeout (configurable in the menu, can be infinite). Check
      the F20 one-shot sentinel path (modules/keymap/one_shot_shift.lua, adapters/one_shot_shift.lua) against Windows
      and Linux, with a regression test typing three keys inside the timeout.
- [ ] **One configuration layout on every OS.** A macOS configuration imported on Windows or Linux must work as it
      did, Cmd versus Ctrl aside. Decided 2026-11-10: one shared `tap_hold.toml` (keys, global and sticky delays,
      lone-tap window, `mod_combos`; macOS-only `[karabiner]` section), `config.toml` keeps the `[[features.*]]` rows.
      Done on macOS and in the shared pieces: the layout is specified in `_shared/tap_hold/SCHEMA.md`,
      `_shared/tap_hold/shared_file.toml` and `_shared/core/config_schema/tap_hold.schema.json`; macOS reads and writes
      `hammerspoon/tap_hold.toml` through `platform/remap/tap_hold_file.lua` and `_shared/lua/tap_hold/shared_file.lua`
      (catalogue key ids, `<first>_then_<second>` pairs, seconds, `+`-joined holds, only changed leaves written) and
      carries an old `config_karabiner.toml` over once (`migrations.toml` `[legacy_imports.hs]`, renamed
      `.migrated`); Linux leaves another driver's keys alone and names a macOS `hold_action` once. The cross-driver
      corpus `_shared/tests/corpus/tap_hold_shared_file/` pins each Lua writer's file byte for byte and what each
      reader reads from both (`expected.toml`, contract `_shared/lua/test/tap_hold_shared_file_contract.lua`).
      Left: (1) Linux `[mod_combos]` still lives in `config.toml` (`modules/shortcuts/key_combinations.lua`,
      `ui/menu/key_combinations.lua` through the features scope): route the `mod_combos.*` manifest paths to
      `tap_hold.toml`, add `[legacy_imports.linux]` (`config.toml` `[mod_combos]`, a new closed translation in
      `migrate.lua`), and add `mod_combos` reads to `expected.toml`; until then a macOS file's combinations do not
      reach Linux. (2) Windows (maintainer): `tap_hold_loader.ahk` / `tap_hold_writer.ahk` read and write the shared
      layout (catalogue ids, `[mod_combos]` from `config.toml` with its own legacy import, ignore `[karabiner]`,
      `hold_action`, `cmd`/`fn` with one warning, write `_meta.schema_version`), `tap_hold_migration.ahk` accepts the
      `[legacy_imports]` table of `migrations.toml` and validates it like `migrate.parse_legacy_imports`, and the AHK
      suite reads both corpus files with `[reads.<file>.ahk]` added to `expected.toml`.
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
- [x] **Key names, what lot CH left.** Menus now name keys from `_shared/data/keycodes/key_names.json` in the 21
      locales. Still raw or French: the shared modifier-chord action labels (« Cmd + Option + Shift + Enter » in the
      action pickers, all drivers; tests pin this label family, so it needs its own change); the macOS sticky holds
      and `layer` hold labels; the tooltip footer hints in `_shared/modules/tooltip/constants.toml`; the physical
      shortcuts and metrics web pages. Arabic `gesture.slots.swipe_5_horiz` says four fingers.
      Done. Already on dev before 6 November: chord labels (`key_names.chord_label`, AHK twin), macOS sticky and
      layer holds, the tooltip footer, Arabic five fingers. 6 November: the physical shortcuts page names its
      modifiers and positions (ea56e5eb; the Windows page is not built yet, its README carries the rule); the
      metrics heatmap names its special keys for the recording OS through `_shared/ui/_generated/key_names.js`
      (e1f0fbca); the macOS remap picker headings come from `remap.category.*` in 21 locales and AltGr from the key
      table (fbf75123). Left, not key names: the metrics sequence chips (`CONTROL_KEY_SYMBOLS`) keep English names
      on purpose, so a typed dead-key glyph is never mistaken for a control key.
- [x] **Model selection page.** Install Ollama and Install MLX buttons act or say why, disabled when installed; a whole
      section header opens its list; header on two lines (install, port, status; then add a model by hand); Ollama and MLX
      models grouped in collapsible sections per provider, alphabetical; search crosses sections; gate for page actions
      with no host handler.
- [x] **Options greyed.** Disable in browser address bars and in password fields can be changed, or say why not.
- [x] **Defaults and recommended.** Each manifest row declares feature or setting, CI gate, empty config boots neutral,
      missing option takes its manifest default, Restore recommended restores adjusted settings too (see
      docs/memory/maintainer-decisions.md).
      Done before 6 November, rechecked green then: every row declares `family`, enforced by the generator and
      `test-feature-family-rule.cjs` (361 rows, 6 declared exceptions, seeded violations refused; JS suite
      integration-packaging-and-boot), which also proves a feature defaults neutral, a setting recommends its default
      and the global restore reaches every row; absence reads the manifest default through
      `_shared/lua/config_defaults.lua`; empty-config boots pinned by Linux `test_empty_config_neutral.lua`, macOS
      `test_empty_config_defaults.lua` and Windows `test_features_manifest.ahk`. Not a single every-row reader-level
      proof per driver: those tests sample the readers.
- [x] **Keep Ollama behind a proxy.** 0.40.4 downloads blobs outside the proxy; 0.40.6 fixes it, shared pin needs a Mac rebuild.
      Done: the shared pin is 0.40.6 (`ollama_release.json`, `managed_ollama_runtime.json` with commit 2476d5ea and
      the three changed preimages; every asset digest checked by streaming). The hooks apply unchanged and the hooked
      tree vets with Go 1.26 here. Its checked client is now upstream's own transport, so `WrapChecked` gives the
      explicit relay hop a plain transfer transport (bootstrap relay and TLS kept), and `publicAddress` copies the
      widened special-use lists (the Mac receiver's fake registry moved off TEST-NET-3 to 8.8.8.8). The Mac rebuild
      is under « To confirm on the Mac ».
- [ ] **Before publishing.** Whole AHK suite on a quiet machine with no resident driver, `npm run test:ahk-tray-rows-read-as-text`,
      all live checks including `quit-over-a-log-flush`, JS, macOS and Linux suites, Windows field report with a driver.

## To confirm on the Mac

- [ ] Hotstring section order: move a section up/down, reopen and restart to prove persistence, reset the order, and refuse a stale menu after config changes.
- [ ] WPM: a pointer move after the last physical keystroke hides the widget unless a preview or drag is active; overlapping source holds show AI before hotstrings before autocorrection, and pause/restart removes old holds.

- [ ] PAC route lists: use a real PAC with a dead relay followed by DIRECT or a live relay; preserve ordered selection, the shared timeout and refusal after expiry. Native XCTest milestone: `ManagedProxyRouteWorkerTests` compiled and passed all 23 cases on macOS 26 in [CI run 42374265115](https://github.com/adrienm7/ergopti/actions/runs/42374265115/job/128410747338), source `07dda15c1`, including the native TCP listener probe. The injected route-list cases do not close application receiving with a real PAC.
- [ ] Personal aliases: configure cased Unicode aliases, type and erase a combo one scalar at a time, and confirm preview and expansion agree in native applications.

- [ ] Minimum tap: with CapsLock set to Enter on tap and Ctrl on hold, a bounce of about 20 ms types nothing and leaves no Ctrl held, a 60 ms tap types Enter, and Space still types at once in fast typing (owned runtime `to_delayed_action` timing, generator `apply_tap_minimum`).
- [ ] **MRT-004 « Réparer le service »:** decided 2026-11-06, not built: a new authenticated helper role that adopts an existing exact Core/VirtualHIDDevice plist and settles the first-start `core.json` fence; needs a Swift build and native macOS qualification, then i18n in the 21 locales.

Check out `dev` (or the branch to test), set Debug > Log level > DEBUG, then run
`bash tools/dev/collect-macos-field-report.sh`: it creates `field/mac-<today>-<branch>`, runs the field checks in
the developer app, writes the report under `docs/field-reports/`, commits and pushes. Needs Go, the Xcode Command
Line Tools and python3 3.11.4 or newer; `swift test` needs full Xcode.app (install once from the App Store). Read a
red step with its `proves` line in `static/ergopti_plus/macos/data/field_run.json` and
[project-macos-field-run-step-details](docs/memory/macos-hammerspoon.md). Report each line as pass, fail or not run.

Field run, no person needed (read the next report):

- [ ] Rerun of the 2026-11-02 report, without touching the Mac: no keystats rotation warning around midnight, no
      `event_taps` run-loop lateness with the main thread held over 1 s, `menu.rebuild` and its
      `menu_item.shortcuts` / `menu_keyboard_layout.sources` phases, `diagnostics` phase A under 5 ms, `idle_cost`
      below 8 %, and `granite4:350m-h` pulled with no `digest_mismatch`. A remaining one is a code entry with its
      report lines.
- [ ] Release swap boot-ready: install a chosen release from the Versions window; `swap.log` ends with « reported a
      healthy start ». Then a chosen build that cannot boot (rename its `init.lua` in the staged app before the quit)
      is moved to `ErgoptiPlus.app.failed-<pid>` within 60 s and the previous app opens (exit 9).
- [ ] Two copies and one Accessibility switch: with a local `build/macos` copy registered beside the `/Applications`
      prerelease, an untrusted boot logs the other copy, does not run `tccutil reset`, and the dialog names
      `…/build/macos/ErgoptiPlus.app`; once that copy is trashed and the switch turned on, the boot resumes.
- [ ] Owned runtime install through the launcher: after the next runtime rebuild, Tap-Holds > install the owned
      runtime (the `--request-owned-runtime-install` role, its administrator prompt answered) installs and reports
      `files-published-services-observed-staging-retired`, and the helper's report path admits its one SHA-256 code
      directory (no `helper_signature` or report refusal in the launcher log).
- [ ] Managed Ollama 0.40.6: rebuild the managed runtime (`tools/build/build-macos-managed-ollama.py`, Go and macOS
      cells), then `field_ai_local` pulls a model behind a PAC-only or explicit proxy with no direct route, and the
      native receiver passes with its registry at 8.8.8.8.
- [ ] Physical shortcut delivery: the same proof as on Linux (source suppressed once, no other owner acts, output reaches the focused app) under Karabiner and the keymap tap, before `keyboard_shortcuts.physical_delivery_available` may turn true; meanwhile the « Raccourcis physiques » row is greyed with « Pas encore disponible ».
- [ ] Tap-hold word reset: with « Un tap ou un hold sur une touche tap-hold commence un nouveau mot » on and « Un raccourci clavier commence un nouveau mot » off, a tap-hold copy (Cmd+C tap) between two words makes the next word-start hotstring fire, the user's own Cmd+C does not, and no F20 reaches TextEdit or a Finder rename; switching the option off keeps the word. Karabiner-Elements must deliver the tagged F20 before the chord. Then with Caps Lock (or another tap-hold key) held as Ctrl or Cmd: a shortcut struck under it follows the same option, the user's own Cmd+C afterwards follows « Un raccourci clavier commence un nouveau mot », Ctrl held by hand before the key still reaches the tap (Ctrl+Enter), and no context-menu key reaches TextEdit or a Finder rename (Karabiner-Elements must deliver the untagged `application` key before the hold's modifier).
- [ ] AI inline auto-type: switch on « Inline auto-type » in the trigger menu; a finished prediction is typed into a
      text editor without Tab, a correction that rewrites typed words stays in the bubble.
- [ ] Backup of the API entries: add a remote API entry, install a release from the Versions window, delete the entry,
      then restore the pre-install backup: the entry comes back after the reload and its key still works from the
      Keychain.
- [ ] Onboarding number-row order: with an Ergopti layout of ours selected, the wizard offers the order; Finish with «
      symbols » types symbols on the number row after the reload. With a system layout it is greyed with its reason.
- [ ] Navigation layer repeat count: bind `Digit3 = "repeat_count:3"`; under the layer, `3` then `arrow_up` moves up
      three lines, the next `arrow_up` one, and releasing the layer after `3` forgets the count.
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

- [ ] Layout emulation (2026-11-06): with French (or ABC) selected as the input source, choose Keyboard layout >
      Layout to emulate > Ergopti➕ and type in TextEdit: letters, Shift, CapsLock, Option levels and the
      circumflex dead key (`^` then `e` gives ê) follow Ergopti➕; Cmd+Z undoes where Ergopti has z; a row switched
      off types French; a hotstring fires on emulated text. Check that a key the French layout makes dead (`^`)
      types its emulated character, that the cleared Option flag does not break an Option chord in Terminal, and
      note the password-field limit (Secure Event Input: the system layout types).
- [ ] Hotstrings (asa): `asa` + Space fast twenty times, also holding `a`: always `ASA`, with
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
- [ ] Predictions stop on activity (feat/predictions-stop-on-activity): on a real Mac, during the spinner and over
      a shown prediction, a pointer move, a trackpad scroll, a pinch or swipe gesture, Cmd+Tab, a click in
      another app and F5 each cancel and hide; Tab, Shift+Tab, the arrows and the validation digits still act on
      it; a resting hand keeps it. Check that mouseMoved now in the keymap mouse tap adds no visible pointer lag
      (Debug log `User activity (mouseMoved)` appears once per cancellation, not per event).
- [ ] Branch `wave3/input-policies` (2026-11-06): a second CapsWord gesture or shortcut switches CapsWord off and
      unlocks CapsLock; the CapsWord delimiter menu shows « ★ » after the magic key is renamed. Native one-shot Shift:
      modifier-map, dead-key and IME handling of the captured key; CapsWord key/control payload receiving
      (moved from the one-shot and CapsWord parity follow-ups).

## To confirm on the Windows PC

- [ ] Hotstring section order: run the category-order AHK regressions, move/reset sections through the real tray, restart, and verify persistence plus refusal of a stale menu after external config changes.

- [ ] Hotstring preview boundaries: run `preview-word-opening` and `boundary-cache` on native Windows; type punctuation before a word, change custom delimiters and the magic key, and confirm preview and expansion still agree.
- [ ] Remote authentication: exercise real IBM and Google token services; local request/refusal tests do not qualify their live responses.

- [ ] **Windows personal-info eager pre-generation:** measure boot cost at the highest accepted pattern length; cover the accepted-agent policy test, the wrap-scalar test and the 2026-11-06 AHK changes with a native run.

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

- [ ] Layout emulation parity (2026-11-06): run the Windows suite once on a real machine. The AHK test
      `test_keylayout_emulation.ahk` now replays `emulation_vectors.json` (written without an AutoHotkey runtime,
      never run), except five vectors that order the number row (digits or symbols first), whose ordering in effect
      is the foreground OS layout's: the Lua drivers replay those, the AHK number-row suites own that side. Fix any
      difference in the Windows emulation or the corpus, and check the vectors skipped by name are still five.
- [ ] Layout emulation row on Windows (2026-11-06): Tray > Layout > « Disposition à émuler » lists none, Ergopti,
      Ergopti➕ and the registry layouts; choosing one restarts the driver on it (the tick follows), « none » types
      the system layout, an uninstalled stored layout stays named.
- [ ] Tray > Gestures: one « Infos… » row that opens the dialog.
- [ ] Ollama or oMLX on a non-default port with the process scan failing: still found.
- [ ] `asa` then Space fast, 20 times: always `ASA`.
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
- [ ] Predictions stop on activity (feat/predictions-stop-on-activity): with a slow model, type, pause, and during
      the spinner move the mouse by a few pixels, turn the wheel, use a precision-touchpad scroll, Alt+Tab, press
      F5: each cancels the request and hides the tooltip at once (no 100 px threshold, no grace window). Tab, the
      validation digits and the cycle chords still act on a shown prediction; a still mouse keeps it.
- [ ] Branch `decisions/align-windows` (2026-11-06, AHK and PowerShell unrun on Linux): run the AHK suite
      (`test_wpm_config_types.ahk` mode `later-writes-refused`, `test_key_combination_chord_engine.ahk` copy cases,
      the persistence census at 50) and `test-windows-route-plan.cjs`; drag the WPM widget, restart, and check it
      comes back where it was (the old split position keys are no longer read, so it starts once at its default);
      Shortcuts > Key combinations > « Copy tap → combo », then a chord fires the copied action; a model pull behind
      a `PROXY dead:3128; DIRECT` PAC goes direct after the 1 s probe.
- [ ] Branch `wave3/metrics` virtual desktops (AHK unrun on Linux): run `test_keystats_virtual_desktop.ahk` and the aggregation corpus (`system_event_night_wake`), then on Windows 11 and Windows 10 switch desktops (Win+Ctrl+Left/Right) and confirm one `space_change` per switch in today.log and the dashboard's desktop-change KPI, and none from Alt+Tab.
- [ ] Bundled apps (`wave3/app-cloner-encryptor`, AHK unrun on Linux): parse and run `test_bundled_apps.ahk`; from the
- [ ] [COVERAGE] Windows managed-runtime fixture: after a first native Windows run of the legacy fixture, register it
      in `ci-windows.yml` (it holds the only reuse and runtime-receipt retirement cases).
- [ ] Branch `wave3/windows-deep` (2026-11-06, AHK unrun on Linux): run `test_keystats_journal_sealing.ahk`; then
      enable Metrics > « Encrypt logs on disk », type a unique marker in Notepad, wait for the ingest and check that
      `by_device\<id>\today.log` holds no readable marker while the dashboard still counts it.
- [ ] WG-003 two-account check: as a standard user, run the first-run wizard's gesture registration and answer UAC
      with a different administrator account; the standard user's PrecisionTouchPad values change (and its backup is
      theirs), the administrator's hive is untouched, and the touchpad restart still reports success.
- [ ] WPM notification-area readout: run `test_notify_icon.ahk` and `test_wpm_tray_readout_wiring.ahk`; tick Metrics >
      « WPM in menu bar », type: a second icon shows the number (source colour after a hotstring, neutral otherwise),
      hides when typing stops and on pause; restart Explorer: it comes back; quit: it leaves; at 125 % and 200 % the
      number stays legible.
- [ ] Branch `layout/system-switch-parity` (2026-11-06, AHK unrun on Linux): run the AHK suite
- [ ] Branch `wave3/input-policies` (2026-11-06, AHK unrun on Linux): run `test_tap_hold_one_shot_timeout.ahk`,
- [ ] Branch `layout/windows-klc-installer` (2026-11-06, built on Linux only: no MSVC run, AHK unit tests under Wine):

## To confirm on Linux

- [ ] Wayland focus on GNOME and KDE: after `install.sh` (and a new login on GNOME), the excluded-applications rules and the metrics' per-app attribution follow the focused window under GNOME Shell 45+ and Plasma 6 (and 5): the log says « Listening for GNOME Shell/KWin focus reports », a title change in a browser updates the title, and turning the GNOME extension off makes the identity unknown.
- [ ] Hotstring section order: move/reset sections through the tray, restart, and verify persistence plus refusal of a stale menu after external config changes.
- [ ] WPM: verify pointer-before-key and key-before-pointer ordering on a real desktop, preview/drag visibility, AI > hotstring > autocorrection holds, and no retained colour after disable/re-enable.

- [ ] Daily notes: `take_note` opens the current daily file with the registered text editor without replacing its contents; an absent text handler shows the specific refusal.
- [ ] Keep awake: `activity_simulation` prevents idle sleep in real X11 and Wayland sessions and releases the logind inhibitor on toggle-off, pause, quit and daemon termination.

No machine is available. First `bash tools/dev/collect-linux-field-report.sh` on a real desktop: the field run
without a click (53c1766514), the report marks, and `driver_reload` (one daemon restart under a real user manager).

- [ ] Update restart watcher: install an update in a standalone install under the systemd unit and from a terminal
      (relay); `…update-watch.log` beside the settings reads « reported a healthy start ». With a new tree whose
      `bin/` launcher exits at once, the tree moves to `<root>.failed-<pid>` within 60 s, `<root>.old` is back and the
      previous daemon runs; a Quit during the wait leaves the update installed and nothing restarted.
- [x] Layout emulation (2026-11-06): with an AZERTY (fr) XKB layout, choose Keyboard layout > Layout to emulate >
      Done (container proof, [receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): `tests/hardware/run_layout_typing_live.sh` types the 30 hand-read
      `keylayout_vectors.json` vectors of Ergopti, Ergopti➕ and Ergo-L over AZERTY into mousepad (GTK) and kwrite (Qt),
      read back through AT-SPI, with Ctrl+c and Ctrl+z on the Command level, a row switched off and the AZERTY-dead `^`
      key; fixes a1a8cf98, f7541d24, 0601d1a8.
- [ ] Bundled apps (`wave3/app-cloner-encryptor`): Applications > Encryptor opens a file chooser and writes
- [x] AI inline auto-type: with the trigger menu switch on, a finished prediction is typed into a real editor through
      uinput without Tab, and nothing is typed into a password field. Container proof (2026-11-10):
      `tests/hardware/run_ai_inline_container.py` (11 assertions, receipt `docs/audits/linux/2026-11-10-container-proofs`) types the inline prediction into
      mousepad on Xvfb, read back over AT-SPI, with no Tab, and a GTK password field gets no request and no text. The
      X11 session warms its XTEST keyboard first: a slave switch revokes the layout receipt (item under "Remaining
      code work").
- [x] Navigation layer mouse buttons and repeat counts: with `MouseMiddle = "escape"` and the recommended number row,
      a real mouse's middle click under the layer types Escape and never clicks, and `3` then `arrow_up` moves up
      three lines. Container proof (2026-11-10): `tests/hardware/run_nav_pointer_container.py` (21 assertions,
      receipt `docs/audits/linux/2026-11-10-container-proofs`) in mousepad on Xvfb; a leaked click would paste a PRIMARY marker. It found and fixed a stopped
      daemon: the next device watchdog tick after the layer gave the mouse back refused the source cohort.
- [ ] Physical acceptance: evdev/uinput grabs, polkit, autostart, Wayland and X11; wizard (7) on Wayland; magic key
      grab, injection and hotplug (30); real kernel capture (93: ordered pairs need Xorg or a compositor on real
      evdev nodes). Container pass (2026-11-10): not closable in the cloud container, whose kernel has no uinput or
      evdev (`mknod /dev/uinput` opens with `ENODEV`) and no systemd PID 1, so a real-node grab, the polkit agent,
      the user-manager autostart and real kernel capture cannot run there; the grab and injection on a real kernel
      already run on CI (`run_grab_race.lua`, `run_daemon_live.sh`). The X11 and Wayland halves of the grabbed input
      path now run on the kernel model (`tests/hardware/run_container_proofs.sh`). Left for a runner with uinput:
      sway or Xorg reading the daemon's real virtual keyboard (93); wizard (7) and the magic key (30) not attempted.
- [x] Gestures: a three-finger pad and one `libinput record` from a real touchpad (d627f511fc, 1870e62e1a,
      `linux/HARDWARE.md` section 13); a two-finger scroll with a thumb resting reports two fingers, a brisk
      three-finger tap still reports `tap_3`. Container proof (2026-11-10): `container-proof-gestures` in
      `linux/tests/unit/modules/gestures/engine/test_touchpad_container_proofs.lua` replays
      `tests/fixtures/touchpad_record_three_finger_alps.yml` (a trace written in `libinput record` format, not a
      physical capture: HARDWARE.md section 13 still welcomes one) through the binary evdev reader,
      `start_reading`, the decoder and the dispatch.
- [ ] Layout switching (branch `layout/system-switch-parity`, 2026-11-06): on GNOME Wayland, KDE Plasma 6 Wayland,
      Container proof 2026-11-10 (`tests/hardware/run_input_sources_live.sh`, [receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): KDE Plasma 6.6.4
      Wayland and X11, openbox X11 and sway pass (`getLayoutsList` answers `a(sss)` on both Plasma sessions); GNOME
      Shell 46 fails, the switch changes nothing on a running shell (Linux remaining work). Left: GNOME only.
      KDE Plasma X11 and another X11 desktop with two layouts, Layout > « Input sources » lists them (GNOME and KDE
      tick the active one, X11 ticks none) and picking one switches the desktop. On KDE, the keyboard daemon's
      `org.kde.KeyboardLayouts.getLayoutsList` (through `gdbus call`) answers the `a(sss)` shape the adapter parses
      (Plasma 5.21+). With the pause switch on, the daemon start selects the resume layout and a start after a paused
      reload keeps the pause layout; on Sway the rows show the unsupported-desktop reason.
- [x] Incremental swipes: on a real touchpad, a three-finger horizontal swipe steps about one action per 3.5 mm (one tab per 25 mm vertically), a reversal steps back, and the log names the pad's resolution; a pad that reports none logs it and fires once. Container proof (2026-11-10): `container-proof-incremental` (`test_touchpad_container_proofs.lua`, trace `touchpad_record_incremental_elan.yml`); it found the tracker measuring from its first live frame (a brisk 21 mm swipe stepped 5 times, not 6), fixed in `incremental_tracker.lua`.
- [x] Gesture axis slots (312bb581): on a real touchpad, with only `swipe_3_horiz` bound, a three-finger swipe
      left and right each run it once; binding `swipe_3_left` too makes the left swipe run that one instead.
      Container proof (2026-11-10): `container-proof-axis-slots` (`test_touchpad_container_proofs.lua`, trace
      `touchpad_record_axis_swipes_elan.yml`); it found the incremental tracker taking the unbound
      `swipe_3_left`'s default incremental mode, so the axis slot ran about once per 3.5 mm; it now takes the
      answering slot's mode, as macOS does.
- [x] Navigation layer wheel bindings with a real mouse (ea4b3fa600). Container proof (2026-11-10): the wheel phase
      of `tests/hardware/run_nav_pointer_container.py`: a notch under the layer is the volume key and never scrolls,
      outside it the mouse is not grabbed (receipt `docs/audits/linux/2026-11-10-container-proofs`).
- [ ] Wayland desktop changes: on sway, Hyprland and KDE Plasma 6 Wayland, switch workspaces a few times (each at least 1 s apart); Metrics shows the desktop-change count rising by one per switch, and GNOME Wayland still shows « — » with its reason.
- [ ] Secret service: add a key with the keyring locked, the unlock prompt takes the keyboard under the grab; restart
      and check the plaintext `api_keys.json` migration (e93a4f7368, 939c0f60).
- [x] Owned Ollama: with `ollama serve` on 11434, enabling the AI starts Ergopti's on 11435 (32fa07be7f). Container
      proof 2026-11-10 (`static/ergopti_plus/linux/tests/hardware/run_owned_ollama_container.py`, CI `network-ai`): an Ollama stand-in speaking its HTTP
      API on 11434 and an `ollama` on PATH are never contacted or run; the menu's enable starts the managed binary
      with `OLLAMA_HOST=127.0.0.1:11435`, which answers `/api/version`, and switching the AI off ends it. The proof
      found an absent `config.toml` refused the start (`runtime_writer_unacknowledged_restored`): fixed in
      `runtime_source.lua` (`runtime-absent-config`). The pinned release itself cannot be downloaded in the cloud.
- [x] PAC unreachable: an Ollama pull logs the WARNING then the direct success (50b424b997, afc7fa23db). Container
      proof 2026-11-10 (same runner, real glib-pacrunner on a private bus): GIO answered `direct://` with no error for
      a PAC it could not download, so the WARNING never appeared on Linux; the lookup child now downloads the GNOME
      PAC itself and the stage logs « lookup unusable at native_pac_download », then the pull succeeds direct
      (`pac-download-direct`). A PAC that says DIRECT warns nothing; a dead relay as the last entry fails the pull.
- [ ] Item 50 cascade and the composed layout typed on a physical keyboard.
      Not attempted in the 2026-11-10 container pass; the emulation proof above can type the composer's
      `composed.keylayout` once it is the emulated layout.
- [ ] Layout emulation W1 to W4 of `docs/design/layout-option-emulation.md` on real GNOME and KDE sessions
      Container proof 2026-11-10 (`tests/hardware/run_user_layout_wayland_live.lua`, [receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): on GNOME Shell
      46 `apply-wayland` ends `not_loaded` and rolls back (the shell lists no user-tree id, mutter still compiles it);
      on KWin 6.6.4 inconclusive (headless XWayland read-back); W4 not attempted.
      (dbe176e52b, 9b0a205029, dfb197a1ea), including mutter and KWin reloading a `~/.config/xkb` layout (107).
- [ ] Developer mode with the package installed: `run-linux-dev.sh` stops the unit, the tray appears, a saved `.lua`
      and the tray's Reload restart the daemon, a second run reports "already running".
- [ ] Ten window-toggle actions on GNOME Wayland and X11 (a covered page is raised, not closed); release notes pane
      (PAR-52); tap delay row and every tray dialog in the owned GTK host (ca680655d7), group restore and clear, open target, Backspace word start.
- [ ] Wayland focus through lswt: on labwc or Wayfire with lswt 2.x, `lswt -j` marks the focused window `activated`
      and per-application rules follow it; GNOME, KDE and COSMIC log the single "no focused-window query" line.
- [ ] Physical shortcut delivery (LIN-004): with a physical slot bound, prove on a real keyboard that the source key is
      suppressed exactly once, no other owner (tap-hold, layer, hotstring, magic key) also acts on it, and the action's
      output reaches the focused window under the grab; only that evidence may turn
      `keyboard_shortcuts.physical_delivery_available` true. Not done in the 2026-11-10 container pass: the kernel
      model (`tests/hardware/run_container_proofs.sh`) can host this proof, but it first needs a delivery path to
      qualify behind the getter.
- [x] Accented shortcuts: on AZERTY with « é → C » on, Ctrl+é copies in a GTK and a Qt editor, AltGr+é still types
      Done (container proof, `tests/hardware/run_layout_typing_live.sh`, [receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): Ctrl+é copies in mousepad
      and kwrite, AltGr+é types AZERTY's level 3, Ctrl+2 with digits first stays Ctrl+KEY_2 on the wire.
      what the layout gives, and Ctrl+2 (é) stays Ctrl+2 while the number row types digits first.
- [x] Tap-hold copy check on Wayland: on KDE or sway with wl-clipboard, a tap-hold copy in an editor sends no retry
      and no warning, and a copy with nothing selected warns once; on GNOME the log says the watch ended and the
      copy goes unchecked. On X11 with xclip removed, the same copy is checked through libX11. Container proof
      (2026-11-10): `tests/hardware/run_tap_copy_container.py` (23 assertions, receipt `docs/audits/linux/2026-11-10-container-proofs`) on sway headless with
      mousepad, mutter 46 headless (GNOME's compositor) and Xvfb with xclip hidden.
- [x] Some `local_servers.json` servers installed: the detection names them. Container proof 2026-11-10
      (`static/ergopti_plus/linux/tests/hardware/run_local_servers_container.py`, CI `network-ai`): stand-ins under the servers' own names and flags;
      the sweep names llama.cpp and vLLM (port from the command line), Lemonade (`~/.config/lemonade/config.json`)
      and KoboldCpp (its listening socket through ss), each up with its model, every other server « not running ».
- [ ] Predictions stop on activity (feat/predictions-stop-on-activity): with a slow model, during the spinner move
      the mouse, turn the wheel, touch the touchpad (absolute pad and relative pad), switch window (the 250 ms poll),
      press F5: each cancels and hides. The validation digits and the navigation chords keep a shown prediction.
      Not emulable in the cloud (2026-11-10): the container kernel has no uinput module and no /dev/input
      (`mknod c 10 223` opens with ENODEV), so no pointer, wheel or touchpad device can reach the hook's evdev
      reader, and no compositor runs the spinner or the focused-window poll; the event routing is covered by
      `test_prediction_control_retirement.lua` (« Main cancels AI on pointer activity »).
- [ ] Branch `wave3/input-policies` (2026-11-06): with the Bépo registry layout installed, monnaie then cédille
      Container proof 2026-11-10 ([receipts](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md)): Qt (kwrite) types ₢ at once; GTK 3 (mousepad, no IBus) types the
      borrowed trigger « ⅕ » (Linux remaining work); the installed X11 Bépo needed 03a47899. The other parts of this
      line were not attempted.
      types ₢ at once in a GTK and a Qt application (desktop Compose, DKS-001); Tap-holds > sticky delay row changes
      the one-shot wait; a CapsWord menu change applies to the running session. Native one-shot Shift real-device
      output receiving; CapsWord absolute reader and desktop keyboard grouping (moved from the one-shot and
      CapsWord parity follow-ups).

## Remaining code work

### Windows (the PC agent's)

State on 2026-11-01. Whole AHK suite at d85a24eb53: 17277/17288 in parallel, the other 11 (clipboard and focus contention
between workers) green alone. All live checks pass, typed by the harness.

- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the
  keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left, the rest of the menu files need
  `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers and sleeps
  before the registry loads. PAR-83: the host in `ollama_managed_files.ps1`. Moving `tests/run_*.ahk` to
  `tests/runners/` is not worth it (455 `A_ScriptDir` uses, 1,908 includes).
- **Tests.** Source assertions left to convert to behaviour; `--reverse` on the `llm` group has 3 order-dependent reds.
- **Field report.** `field/win-2026-11-01-dev` ran with no driver; run it again with one.
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Older findings.** The seven "Remaining findings" of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36 updater production coupling (the
  first trusted PowerShell host acquisition); a408a29790 (the four longest AHK unit shards split) was never landed.
- **TakeNote and the Windows 11 tabbed Notepad.** The Store Notepad titles a window « Notes.txt – Bloc-notes » with
  an en dash; the matcher read only « - » and never found the window (fixed, `takenote-title-separator`). Left: by
  default it opens a second file as a tab of the open window, so a same-named note of another folder shares one
  window with the first, and the module, which binds one window to one path, waits for a window that never comes
  (`takenote-native-document-owner` mode different-folder fails on the PC, passes on the Server runner's classic
  Notepad). Tell the two tabs apart (UI Automation tab items) or select the right tab before typing.
- **Whole AHK suite on the PC (2026-11-10, `fix/windows-pc-2026-11-10`).** 20,286 run, 16 red: 2 token-exchange
  budgets and 1 shortcut path case (fixed), 2 TakeNote (above). The other 11 need what the CI runner installs
  and this PC does not have: the Kana layout (`one-shot-native-kana-*`, 2), a top row that types letters, while
  the PC's first layout is the custom `d001040c` (`layout-row-native-flags`, `layout-row-external-native-flags`,
  `layout-row-pending-dead-key`, 7), and file symlinks, which need Developer Mode (`unblock-selected-file-reparse`,
  2). Skip each with its reason when the prerequisite is absent instead of failing.

### macOS

- **Field report 2026-11-03 (`mac-2026-11-03_102716`), branch `fix/macos-field-2026-11-03`.** Done: ai_local no
  longer lists the owned endpoint without its binary (no ERROR); n-gram history merges paced (458 ms slice); the
  dashboard no longer resends an unchanged history each live update (250 ms holds, +73 MB heap per minute). Already on
  dev: blob Range redirect (e6942d05c2), diagnostics phase A (e76a5443f8), post-wake AX hold (1f2884f13c), owned
  Ollama Go test enrolment (627bfad0af). Done since: the hardware UUID keystats start needs is read by an ioreg child
  during the start delay (`modules/keystats/host_signature.lua`), no longer by `ioreg -d2` on the main thread (151 ms
  at boot+1 s); a later Metrics toggle still reads it synchronously when no prefetch ran. Karabiner regeneration stays
  synchronous (merge 170 ms, layout actions 230 ms cold: event_taps `runloop_late_ms` 294), no safe non-blocking
  design: the work is in-process Lua plus native calls (`hs.keycodes.map`, `hs.json`, the file write), which no child
  can do, and slicing it across run-loop turns would let layout, pause and lease events land between a build and the
  layout serial, lease token and epoch it was validated against. Measured on Linux Lua 5.4 under the stub harness
  (shipped recommended preset, 6 rounds): layout actions 1.1-1.8 ms, build 27-40 ms, merge 9-30 ms, encode 11-44 ms
  (258617 bytes); so the field 230 ms in `karabiner.layout_actions` is native, not the Lua loop. Next: split that
  phase on the Mac (`Layout.keyboard_form()` registry snapshot vs the 548 `hs.keycodes.map` lookups) before touching
  it. The menu Apps folder reader already uses `FsDir.try_entries_quiet`; the obsolete `find` follow-up is closed.
- **One folder name for Ergopti on the three OS.** The shared roots and boot migrations are already on dev. Check the maintainer's machines against `docs/tooling/one-folder-name-handoff.md`; remove the migration only once those checks pass. Rename the owned Karabiner runtime folder (`ErgoptiPlus`) in its next rebuild (item 31).
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
- **Checks left to a program from the Mac session.** Done on 1 November: `field_tap_hold_thresholds` (9901da4d94;
  PAR-15 is confirmed by the next field run's result);
  the HTTPS downgrade refusal is already covered by `ManagedPACSourceTests` and `ManagedBootstrapDownloadTests`.

### All drivers

- [ ] **Linux PAC lists through GIO (found 2026-11-10).** On GNOME, GIO keeps only the first entry of a PAC answer
      (`PROXY a; DIRECT` reaches the driver as `a`), so the managed Ollama stage's browser-style walk cannot fall
      back to DIRECT when that relay is down (docs/memory `project-linux-gio-hides-pac-failures`). Decide whether to
      evaluate the PAC another way or document it.
- [ ] **Linux managed Ollama under umask 0002 (found 2026-11-10).** The install resolver refuses a group-writable
      ancestor (`install_ancestor_writable_by_others`), and a user-private-group umask 0002 makes `~/.local/share`
      group-writable when an application creates it so: decide whether a private group's write bit is acceptable.
- [x] **Test parity (audit item 14), Linux and macOS.** Closed on 10 November (39b12ae7): the tar feeder tests
      already load `infra.archive_tar_feeder` by module; five more Linux copies resolve their file from the module name
      (ratchet 7 files, 13 reads); every remaining Linux and macOS pin is documented as legitimate in its ratchet header
      (layout staging, harness absence check, e2e soak fragment, opener argv, macOS `init.lua` class scans).
- **Provider flags inferred, not read.** Checked against the docs on 1 November (90344262aa): Featherless and
  Qianfan confirmed. Rechecked on 10 November (7ae1147b): the Perplexity, `dashscope-intl` and Moonshot K2 watches
  are closed and guarded by `test-llm-provider-retirements.cjs`. Left, both only provable with a live key (the docs
  hosts are unreachable from cloud sessions and show no off example): SambaNova's `enable_thinking: false` (off is
  its default, docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **Tooling found on the way (4 November).** The source seal now reads Git blobs without creating a temporary checkout. On the Windows PC these fail on a clean `dev` for
  environment reasons, so only CI proves them: `test-site-github-release` and the site deploy admission controls
  ("file changed before capture"), `test-keylayout-row-options` (different Lua keyboard ids),
  `test-linux-field-report-contract` (setup error), `test-menu-manifest` in a worktree (a `node_modules` junction
  copy fails with `EPERM`). Make each one pass locally or skip with a stated reason.
- [ ] **Linux X11: a same-group XKB notify revokes the layout for good.** Found by the 2026-11-10 container proofs:
      Xorg sends an XKB new-keyboard notify each time the slave keyboard feeding the core keyboard changes (the daemon's
      virtual keyboard after the physical one, XTEST), `adapters/xkb_source_probe.lua` bumps its generation on every
      notify and `adapters/xkb_capture.lua` renews a revoked inverse only for a group change, so after one switch
      `KeyboardLayout.is_ready()` stays false and every replacement takes the clipboard route. Reproduce: drop the XTEST
      warm-up in `tests/hardware/container_session.py` and run `run_ai_inline_container.py`. Decide whether a same-group
      notify whose canonical keymap is unchanged may renew the inverse (the custody tests pin different-group renewal
      only); Wayland and macOS have no slave switch.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins
  of a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods` (macOS capture is item 31's).

### Linux (container proofs of 2026-11-10)

- [ ] **GNOME input source switch.** GNOME Shell 46 ignores runtime writes of `mru-sources` and `current`: on a
      `sources` change it keeps its in-memory MRU and activates its first entry, and a non-interactive activation
      writes no `mru-sources`. Writing `sources` as `[target]`, `[target, other]`, then the user's list switches a
      running shell, but only once the shell processed each write: wait on the session keymap (XWayland group) between
      writes. The same holds for `apply-wayland`, and the shell lists no id it does not know from the system rules.
      [Proof and mechanism](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md).
- [ ] **GTK 3 Compose from the managed `~/.XCompose`.** GTK 3.24's built-in input method compiles nothing from the
      include block (an included file that itself includes `%L`), so Bépo's monnaie then cédille types « ⅕ » in
      mousepad while Qt types ₢. Write the rules where GTK 3 reads them, or state the IBus requirement.
- [ ] **KDE layout id across session types.** `getLayoutsList`'s middle field is Plasma's display label (`''` on
      Wayland, the short name on X11), read as a variant: the same layout is `us` on Wayland and `us(us)` on X11, so a
      stored pause layout does not match on the other session type.

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

- [x] Define "the read-only dashboard with a hot journal". Decided 2026-11-06 (`docs/memory/maintainer-decisions.md`,
      « The metrics dashboard reads the live store »): the typing and applications dashboards read `db.sqlite` on
      Linux and macOS read-only, in a rollback-journal store (`journal_mode = DELETE`, no WAL); the hot journal is the
      `db.sqlite-journal` of an interrupted write, recovered only by the writer, so the reader refuses and keeps its
      last good projection. Reads wait the writer's COMMIT (`keystats.sqlite_read_busy_timeout_ms`) on both. Windows
      replays the append-only `data.sql` into a private image and keeps the last good one on an open transaction.
      Done: the wait, the named refusal, tests on Linux and macOS.
- [x] Dashboard export and purge on the three drivers (reset exists as `metrics_reset_session`). Decided 2026-11-06:
      both go through the single owning writer after its flush settles, with a confirmation, same behaviour on every
      OS, text through the `i18n` skill in all locales. Purge decided 2026-11-06: purge everywhere. The owning writer appends a dated tombstone row to its ledger; every
      device applies it when replaying, so purged data never comes back from a sibling device. Export has no such question (a copy taken
      after the flush settles). Built: the tombstone is an `events_system` `metrics_purge` row applied by the triggers of
      `_shared/data/db/purge_schema.sql`; writers `request_metrics_maintenance` (Linux keystats, macOS `log_manager`) and
      `KL_RunMetricsMaintenance` (Windows); the Windows path is checked by source contracts only and still wants a live
      Windows run.
