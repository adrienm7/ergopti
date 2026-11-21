<!-- docs/platform-parity-audit.md -->

# Ergopti+ platform parity audit

This audit describes the source tree at the time of the change. The generated
[entry-by-entry review queue](feature-inventory.md) is updated from the actual
catalogues, and includes every missing configuration path, bindable action and
platform-restricted interactive menu entry, with action alternatives and menu reasons. An
entry is not the same thing as a user-facing capability: an OS can provide the
same capability through a different path. A declaration is not a runtime or
hardware test.

## Layout capabilities — November 19, 2026

Maintainer request: on Windows, macOS and Linux, from the tray menu and from
Ergopti Studio, (1) install and remove keyboard layouts on the OS and switch
between them, (2) emulate a layout without installing it, (3) emulate small
changes (layers, AltGr, emulated rows, number row, accented-letter shortcuts,
magic key) on top of the OS layout or the emulated one.
`tools/test/test-layout-capability-contract.cjs` now pins every path below per
OS and surface (44 code paths, the six Studio messages each host accepts, the
Optimiser's Download / Install / Emulate, and the reason of every row drawn on
fewer than three OS), each with a mutation that must fail.

| Capability                    | Windows menu                       | Windows Studio                             | macOS menu                                    | macOS Studio                    | Linux menu                                             | Linux Studio                                  |
| ----------------------------- | ---------------------------------- | ------------------------------------------ | --------------------------------------------- | ------------------------------- | ------------------------------------------------------ | --------------------------------------------- |
| Install                       | ✓ installer download (admin)       | ✓ DLL registration (one UAC prompt)        | ✓ `.bundle`, user scope                       | ✓ registry and composed layouts | ✓ opens the layout manager                             | ✓ Wayland; **X11 fixed** (was always refused) |
| Remove                        | ✓ the installer's own uninstaller  | ✓ catalogue layouts; **Studio DLLs fixed** | **fixed** (no removal of the `.bundle`)       | ✓                               | ✓ through the manager                                  | ✓                                             |
| Switch                        | ✓                                  | ✓ through « Install and use »              | ✓                                             | ✓ registry layouts              | ✓ GNOME, KDE, X11                                      | ✓ Wayland; **X11 fixed** (activate refused)   |
| Emulate without installing    | ✓ overrides the active layout      | ✓ `composer_emulate`                       | ✓ overrides the input source                  | ✓                               | ✓ overrides the XKB layout                             | ✓                                             |
| Tune, OS layout as base       | ✓ AltGr, rows, number row, é è ê à | —                                          | ◐ AltGr, rows; number row only on our layouts | —                               | ◐ AltGr, rows, é è ê à; number row only on our layouts | —                                             |
| Tune, emulated layout as base | ✓                                  | —                                          | ✓ **number-row offer fixed**                  | —                               | ✓ **number-row offer fixed**                           | —                                             |

Fixed, each with a regression red on the old code:

| Id     | OS             | Gap                                                                                                                                                                                                                                                          | Fix and regression                                                                                                                                                                                                                                                                                                                        |
| ------ | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LCP-01 | Linux          | The user installer refuses an Xorg session unless the caller loads the layout itself, and only the number-row options passed `--allow-xorg`: the layout manager and Studio installed nothing on X11, and a selection ran `activate`, which refuses Xorg too. | `install` and `install_local` pass `--allow-xorg` on X11 (`with_x11_permission`), `select` runs `apply-x11` and keeps the layout through `x11_layout_reapply`. `test_layout_registry.lua` (`x11-layout-install`, two cases) red on the old code.                                                                                          |
| LCP-02 | macOS          | The `.bundle` row installed the layout in `~/Library/Keyboard Layouts` and offered no way to remove it.                                                                                                                                                      | `layout_install.remove_user` moves the exact checked bundle into a private folder, then deletes it, under the install owner; the new `layout_bundle_remove` row disables the bundle's input sources first. `test_layout_install_transaction.lua` (`layout-bundle-remove`).                                                                |
| LCP-03 | macOS, Linux   | The number-row order was offered as soon as any layout was emulated, though the emulation orders that row only with its base layer and number-row switch on (AltGr alone over the OS layout, or the row switched off, applied nothing).                      | `keylayout_emulation.orders_number_row` and `status().number_row`; both menus read it. `test_layout_emulation.lua` on macOS and Linux (`emulated-number-row-availability`).                                                                                                                                                               |
| LCP-04 | reasons        | `platform_reason.layout_emulation_is_windows_only` said macOS and Linux install the layout and have no emulation, false since both emulate.                                                                                                                  | Replaced by `layout_master_switch_is_windows` (the Windows category gate of the layout section) and `ctrl_magic_save_is_windows` (`not_yet` on Linux, TODO BND-1), in the 21 locales.                                                                                                                                                     |
| LCP-05 | Windows        | The layout manager listed no layout Studio registered as a DLL: its removal went through Windows Settings › Apps.                                                                                                                                            | `KbdRegister_Installed` lists every `Ergopti_kbd_<dll>` uninstall entry as a `native` row of the page; « Uninstall » asks first (`layout_manager.confirm_uninstall_native`), then runs the elevated uninstaller. `test_layout_composer_source.ahk` and `test-layout-manager-page.cjs` (`kbd-dll-manager`).                                |
| LCP-06 | Windows        | A source re-saved under another `dll_name` overwrote the only record of the DLL it had registered.                                                                                                                                                           | `_LayoutComposer_SaveSource` uninstalls the previous DLL before storing the new source (a refused prompt keeps the old source); an emulation or a declaration save keeps the DLL, which the manager lists. `test_layout_composer_source.ahk` (`kbd-dll-replaced`).                                                                        |
| LCP-07 | Windows, Linux | An emulated Ergopti layout took Ctrl/Alt/Win on è ê é à from its Command level (Z X C V) whatever the four choices said, while the Windows built-in base reads them; Linux turned its OS-layout shortcuts off for every key once anything was emulated.      | `keylayout_emulation.lua` `accented_choices` and `KeylayoutEmulation_ShortcutChar` read the choices for the Ergopti family (off: the accented letter itself); Linux keeps its own shortcuts on the keys the emulation leaves to the OS (`owns_chord`). `test_layout_emulation.lua`, `test_keylayout_emulation.ahk` (`accented-emulated`). |
| LCP-08 | Linux          | A layout loaded with `apply-x11` lasted for the X session only.                                                                                                                                                                                              | The X11 selection is recorded (`registry.x11_selection_file`) and loaded again at the daemon's start (`restore_x11_selection`), forgotten on uninstall. `test_layout_registry.lua` (`x11-layout-restore`).                                                                                                                                |

What an OS cannot do, with its reason (menu text in the 21 locales):

- The macOS system scope (`/Library/Keyboard Layouts`) is neither installed nor
  removed: it needs administrator rights the driver cannot yet bind to its
  verified launcher (`install_system_unavailable`).
- Linux on X11 loads a layout into the running server only: Xorg reads no user
  XKB tree, so a new session starts with the desktop's own layouts until the
  layout is selected again; a permanent install there is the root
  `xkb_installation/install.sh`. wlroots compositors (sway, Hyprland) get no
  live selection (`session_unsupported`).
- The number row on the OS layout: macOS and Linux rebuild a layout this app
  installed (`number_row_live`); a stock input source or XKB layout has no
  source to rebuild (`platform_reason.number_row_live_no_layout`), and Linux
  under Wayland only does so on GNOME and KDE (`number_row_live_session`).
  Windows remaps the row with hotkeys on any layout.
- The accented-letter shortcuts are not drawn on macOS
  (`accented_shortcuts_need_a_layout_file_on_macos`): a `.keylayout`'s Command
  level carries the chord, and the macOS emulation reads it too (Ergopti's:
  Z X C V). Windows and Linux apply the four choices under an emulated layout
  of the Ergopti family (LCP-07); another family keeps its own Command level.

Left open (TODO): none in code; the real-machine steps are in the TODO-tests files. The accented-letter
shortcuts on macOS keep the Command level of the installed or emulated layout
(`accented_shortcuts_need_a_layout_file_on_macos`, which now says so).

## Platform parity table — November 19, 2026

[platform-parity-table.md](platform-parity-table.md) is generated by
`tools/codegen/codegen-platform-parity.cjs` from the catalogues themselves
(`manifest.toml`, `actions.toml`, `layer_actions.toml`, `menu_manifest.json`
and the hidden-row reasons). It is the one place that lists, for every
feature, bindable action, navigation layer entry and interactive menu row, its
status on Windows, macOS and Linux:

- **supported**, with the production file that owns it on that OS: the file of
  that driver whose code, comments and module names left out, spells the entry
  the most often. An entry read generically (a hotstring section toggled by
  name, a shortcut slot named by prefix, a data-driven layer keystroke) gets
  an owner declared in `_shared/settings/data/features/platform_parity.toml`,
  with a token that must stand in a code line of that file;
- **degraded**, supported only on some sessions or hardware, declared by the
  new `degraded = { <os> = "<reason key>" }` field of a manifest feature (today:
  the Linux number-row choices, applied live only on X11 and on GNOME or KDE
  under Wayland);
- **unavailable**, with the reason key the menu shows and, in
  `platform_parity.toml`, its technical reason and its class.

`tools/test/test-linux-feature-parity.cjs`, extended rather than duplicated,
fails when the table is stale and when one of these rules breaks: a
non-supported cell without a reason key, a reason without a technical text or
missing in one of the 21 locales, a supported or degraded cell with no owner
on that OS and no recorded finding, a menu row bound to a feature drawn on an
OS where the feature is unavailable, a declared owner whose token is not in
code, and any declaration nothing uses. Each rule has a mutation that must be
named by the gate.

Counts at this revision:

| OS      | Supported | Degraded | Unavailable |
| ------- | --------: | -------: | ----------: |
| Windows |       827 |        0 |         296 |
| macOS   |       941 |        0 |         182 |
| Linux   |       872 |        2 |         249 |

Of the 729 unavailable or degraded cells, the reasons class them as:
`os_concept` 206 (the concept exists only on one OS: Karabiner, the .bundle
layout, AutoHotkey's debug tools, NTFS without an executable bit…),
`menu_layout` 187 (the control exists under another row of that driver's menu),
`os_api` 135 (no API, session or permission for it: Windows passes no touch
data to applications, Wayland gives no cursor position and no other client's
windows, MLX exists only on Apple Silicon, a PC keyboard never reports Fn),
`driver_storage` 124 (same capability, stored under another name),
`os_equivalent` 72 (the OS does it its own way; the equivalent action is
offered) and `not_yet` 5, the only cells the reasons themselves call a gap:
token streaming on Windows (`token_streaming_unvalidated_on_windows`), the
shortcut restore on macOS (`shortcuts_restore_is_composed_on_macos`) and
Ctrl+★ save on macOS and Linux (`ctrl_magic_save_is_windows`, TODO BND-1). The
per-reason list, with each technical text, is in the table. The first two were
closed on 2026-11-20. Ollama streams on Windows as on macOS and Linux, each
partial offered as the parser reads it and a failed stream's row withdrawn
before its retry (`test_engine_state.ahk`, streaming-parity). The macOS
Shortcuts submenu restores and clears its scope through the composition the
Configuration menu runs, its key combinations (the remap file Karabiner
applies) before its config.toml rows (`test_global_scope.lua` and
`test_scope_rows.lua`, shortcuts-scope-macos).
per-reason list, with each technical text, is in the table. Since 2026-11-20
Linux saves with Ctrl+★ too, and macOS keeps its Cmd+★ shortcut under the
`os_equivalent` reason `ctrl_magic_save_is_cmd_star_on_macos`.

Building the owners found three declared features no driver code reads. They
were recorded under `[unowned]` in `platform_parity.toml` (a ratchet: an entry
fails as soon as code reads it); the maintainer decided them on 2026-11-19.

### Fixed with the table

| Id     | OS             | Gap                                                                                                                                                                           | Fix and regression                                                                                                                                                                                                                                                                                                                                                                                 |
| ------ | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SFC-02 | macOS          | `refresh()` cached « not secure » with no frontmost application, no PID, no Accessibility API, no application element or a raised read; the cache also started « not secure » | Those states now publish « secure », as Windows and Linux do, and the cache starts secure like the Linux unknown verdict. An application that answers « no focused element » without an error stays not secure (the kept keystats contract). Seven cases of `test_secure_field_detector.lua` red on the old code; one of them never tested what it named (a `nil` override is dropped by `pairs`). |
| SFC-03 | shared         | The port promised `return_false` on a failed detection, which no adapter returns                                                                                              | `SecureFieldDetector.spec.js` declares `return_true` and the `isSecureField_unclassified_returns_true` vector, replayed by the macOS, Windows and Linux suites; `test-port-vector-traceability.cjs` fails on the old spec and on a driver that drops the vector.                                                                                                                                   |
| SFC-05 | Windows test   | « a RoboForm.exe window is secure » asserted `SFD_IsSecureField(A_ScriptHwnd)`, true for any process                                                                          | The case asserts `SFD_IsSecureAppWindow`, with `notepad.exe` as the negative control.                                                                                                                                                                                                                                                                                                              |
| —      | table          | `shortcuts.wrap_text_if_selected`'s menu row counted as shown on macOS                                                                                                        | A `type = "feature"` row inherits its feature's platforms (each driver draws it from its own generated manifest); the gate asserts it.                                                                                                                                                                                                                                                             |
| SFC-04 | Windows, macOS | Yubico Authenticator had no Windows or macOS identity in `secure_apps.json`                                                                                                   | Maintainer decision of 2026-11-19: `authenticator.exe` and `yubioath-desktop.exe` on Windows, the display name `Yubico Authenticator` on macOS; no Google Authenticator desktop name, no KeePass macOS name. `test-secure-apps-single-source.cjs` and the `sfc-04` cases of the macOS and Windows suites fail when one is dropped.                                                                 |
| PPT-01 | all three OS   | `hotstrings.rolls.chevron_greater` and `chevron_less` were declared and shown, and no driver registered them                                                                  | Maintainer decision of 2026-11-19: removed from the catalogue, the Ergopti `rolls.toml`, the locales and every generated table; config schema v23 deletes their saved values (corpus case `shipped_dead_rolls_and_personal_switches_removed`).                                                                                                                                                     |
| PPT-02 | Windows        | The five built-in `shortcuts.personal.*` switches had no reader                                                                                                               | Maintainer decision of 2026-11-19: removed the same way; v23 deletes their saved values, and the `[shortcuts.personal]` namespace stays for the switches a `personal_shortcuts.ahk` registers.                                                                                                                                                                                                     |
| PPT-03 | Windows, Linux | `llm.generation.sequential_mode` was read by macOS only                                                                                                                       | Maintainer decision of 2026-11-19: the shared request plan takes it and returns `concurrent` on the three drivers (`request_plan_batching_vectors.json`, replayed by each); Windows reads it through `LLM_Engine_SequentialMode`, Linux through its generation settings. No backend overlaps calls on any OS, so no request changes order.                                                         |

### Maintainer decisions pending

None: SFC-04 and PPT-01 to PPT-03 were decided by the maintainer on 2026-11-19 (see the table above).

## Census after the structure phase — November 19, 2026

`tools/audit/source-areas.py --ref HEAD` at `b90ad8de` (S26 included) gives
190 areas against the 381 of the pinned November 12 census
(`audits/platform-parity/2026-11-12-tap-holds-followup/source-areas.json`).
The structure phase folded many of the old areas into feature folders. Of the
381, 237 moved whole, 20 split and 3 left (the retired `ui/layer_editor`).
`tools/audit/parity-census.cjs` matches every area, and every finer unit (an
area plus its layer folder, 316 of them), to the campaigns whose reports name
its files. It measures the drift since the latest campaign's pin, renames and
path-only rewrites left out.

- **Areas:** 108 drifted, 13 stable, 69 never campaigned.
- **Units:** 188 drifted, 29 stable, 99 never campaigned. 25 of the 99 are
  generated, vendored or data files.

The [census report](audits/platform-parity/2026-11-19-census/report.md) holds
the old-to-new area map, the drift table, the ranked never-campaigned list
and the proposed order of the next campaigns. Coverage there is lexical: a
named file is not a reviewed file.

| Module                         | Campaign                                                                                           |
| ------------------------------ | -------------------------------------------------------------------------------------------------- |
| Secure-field detection (focus) | [report](audits/platform-parity/2026-11-19-census/report.md#first-campaign-secure-field-detection) |
| Logger engines                 | [report](audits/platform-parity/2026-11-20-logger-engines/report.md)                               |
| Managed Ollama runtime         | [report](audits/platform-parity/2026-11-20-managed-ollama/report.md)                               |
| Tray adapters                  | [report](audits/platform-parity/2026-11-20-tray-adapters/report.md)                                |
| Update and download windows    | [report](audits/platform-parity/2026-11-21-update-windows/report.md)                               |

The logger-engines campaign (November 20, 2026) fixed LOG-01 to LOG-05,
LOG-07 and LOG-08: the macOS level restore follows the manifest (eight names,
INFO default, a visible refusal), a format error is marked on the line on the
three, macOS keeps the 14-days-old log all day, Linux removes a topical view
from another day, a refused Linux file reopens and counts the lines it
missed, the shared core reports the lines a raising sink lost, and the shim
fallback prints the shared labels. One corpus,
`_shared/tests/corpus/logger/parity_vectors.json`, is replayed by the three
suites and the macOS native worker. Left open: LOG-06, lifecycle pairing is
gated on Windows only (15 Lua call-site files to pair first).

The managed Ollama campaign (November 20, 2026) fixed OLL-01 to OLL-03: Linux
pulls a digest-mismatched model once more and then names the mismatch, as
Windows and macOS do, from one shared class table
(`_shared/ai/data/ollama_pull_errors.json`) and one corpus
(`_shared/tests/corpus/llm/ollama_pull_error_vectors.json`); a Windows model
pull has its own ceiling (`[llm] ollama_model_pull_timeout_ms`, read by Linux
too) instead of the 30 min install budget; and the stale owners of the
registry and the inventories were corrected. Left open: OLL-04 to OLL-13,
among them the free-space check on macOS and Linux, the unlocalized install
failure classes, the readiness bound (30 s on macOS, the install budget
elsewhere; a field measure first) and the Linux listener ownership.

The tray-adapters campaign (November 20, 2026) fixed TRAY-01: the Windows
cold tray appeared before `I18nInit`, so its startup rows were French for
every user (the module default locale) and a screen reader named the icon by
the script's file name, the order bug Linux fixed in August. A normal boot
now publishes the startup commands and the icon's name in the configured
locale, then shows the icon; a first run shows it beside the wizard in the
wizard's language. Left open: TRAY-02, a Windows left click does nothing
(a maintainer decision); TRAY-03, a Linux desktop without a tray host shows
nothing and says nothing; TRAY-04, the TrayMenu port spec and its vectors
describe a three-state `setIcon(state)` no adapter has; TRAY-05, a missing
icon file is replaced silently on the three.

The update-windows campaign (November 21, 2026) fixed UPD-01 to UPD-04: a
Windows update started from the Updates window whose digest is refused now
names the integrity check instead of asking the user to check the
connection; a cancelled Linux update no longer reads « Ollama download
cancelled »; and the shared Updates page closes on Escape and announces the
answer that replaces « checking », on the three drivers. Left open: UPD-05,
closing the Linux download window throws the downloaded update away (a
maintainer choice between cancel and install); UPD-06, macOS and Linux name
no network cause for a failed check where Windows names the proxy or the
certificate; UPD-07, no update progress on Windows and Linux; UPD-08 to
UPD-12, smaller wording, receipt and offer gaps.

## Review status at resumption — November 12, 2026

The audit resumed on November 10. `tools/audit/source-areas.py --ref HEAD` at
`c054579d` gives 381 areas against the 363 of the pinned November 5 census
(`audits/platform-parity/2026-11-05-native-ui/source-areas.json`): 18 new, none
removed, 221 with changed members. The focused campaigns below own the new and
changed areas of their module; each report holds its audited revision, its
fixed and open findings and its proof limits. As at the pause, **reviewed does
not mean native-certified**: none of these campaigns ran the native receivers.

| Module                                             | Campaign                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Tap-holds, chords, navigation layer                | [report](audits/platform-parity/2026-11-10-tap-holds/report.md)                 |
| Hotstring cascade and trigger arbitration          | [report](audits/platform-parity/2026-11-11-hotstring-cascade/report.md)         |
| Gestures                                           | [report](audits/platform-parity/2026-11-11-gestures/report.md)                  |
| Input layout, keymap, layout engine                | [report](audits/platform-parity/2026-11-11-input-layout/report.md)              |
| Keyboard shortcuts and text actions                | [report](audits/platform-parity/2026-11-11-shortcuts/report.md)                 |
| Updater, update check, changelog                   | [report](audits/platform-parity/2026-11-11-updater/report.md)                   |
| Lua adapters and infra (clipboard, privacy, focus) | [report](audits/platform-parity/2026-11-11-adapters/report.md)                  |
| Configuration, scopes, migration                   | [report](audits/platform-parity/2026-11-11-config/report.md)                    |
| AI flows (LLM, model browser, prompts)             | [report](audits/platform-parity/2026-11-11-ai-flows/report.md)                  |
| Metrics and keystats                               | [report](audits/platform-parity/2026-11-11-metrics/report.md)                   |
| macOS launcher (source reading)                    | [report](audits/platform-parity/2026-11-11-macos-launcher/report.md)            |
| Lifecycle: reload, quit, signals, wake             | [report](audits/platform-parity/2026-11-12-lifecycle/report.md)                 |
| Notifications, tooltips, dialogs                   | [report](audits/platform-parity/2026-11-12-notifications/report.md)             |
| Network: proxies, trust, deadlines, downloads      | [report](audits/platform-parity/2026-11-12-network/report.md)                   |
| Start at login                                     | [report](audits/platform-parity/2026-11-12-start-at-login/report.md)            |
| i18n at run time                                   | [report](audits/platform-parity/2026-11-12-i18n-runtime/report.md)              |
| Menus and tray                                     | [report](audits/platform-parity/2026-11-12-menus-tray/report.md)                |
| Layout manager and layout editor host              | [report](audits/platform-parity/2026-11-12-layout-manager/report.md)            |
| Diagnostics page                                   | [report](audits/platform-parity/2026-11-12-healthcheck/report.md)               |
| Onboarding                                         | [report](audits/platform-parity/2026-11-12-onboarding/report.md)                |
| Linux install tree                                 | [report](audits/platform-parity/2026-11-12-linux-install/report.md)             |
| Bundled apps (App Cloner, Encryptor)               | [report](audits/platform-parity/2026-11-12-bundled-apps/report.md)              |
| Navigation layer editor host                       | [report](audits/platform-parity/2026-11-12-layer-editor/report.md)              |
| Webview hosts                                      | [report](audits/platform-parity/2026-11-12-webview-hosts/report.md)             |
| Key combinations and macOS bindings                | [report](audits/platform-parity/2026-11-17-key-combinations-bindings/report.md) |

Changed areas no campaign owns yet: the shared plumbing (`lua/crash_report.lua`,
`modules/logger`, `modules/timings`, `lua/features`, `modules/features`), which
the cross-driver single-source gates hold; the `_generated` trees, reviewed
through their generators; and vendor code, out of parity scope. The tap-hold
module drifted after its campaign (the shared tap-hold file of the 2026-11-11
decision, its migrations, writers and the Karabiner generator): its follow-up
reviews that drift.

## Shared corpus replays on macOS and Linux (PAR-58) — November 18, 2026

**Typing sessions.** `_shared/tests/corpus/keystats/session_events_vectors.json`
now runs on macOS through the real event tap, idle timer
(`watchers.check_idle`) and engine stop
(`tests/meta/corpus/test_corpus_keystats_session_events.lua`). The first replay
found three disagreements, fixed in the new `modules/keystats/session_machine.lua`
that the event tap, the idle timer, the session reset and the stop now share:

- a click or a scroll ended an idle span but did not keep the session alive, so
  a session ended five minutes after the last key even while the pointer moved;
- an input after a missed timeout (no idle tick ran, as across a sleep)
  extended the old session, whose `session_end` then counted the silence as
  typing time; it now ends the old session first;
- a stop (feature off, reload, quit) left the open session without its
  `session_end`.

The Windows replay had found the click and scroll gap too, and its watchers
already close a session on shutdown. macOS keeps its
session state in CoreState rather than in the closure-owned
`_shared/metrics/engine/system/session_events.lua` Linux runs, because the live
WPM readout and the deferred synthetic snapshot read and extend those fields;
the corpus replay is what pins the two machines together.

The deferred snapshot of synthetic text (an expansion, an AI answer) also set
the session fields: with no session open it opened one without its
`session_start`, so the next timeout or stop wrote a `session_end` nothing had
opened. Windows (its hook skips injected input) and Linux (sessions come from
evdev keys only) never show synthetic text to their session machine, and
neither had the defect. The macOS snapshot now feeds only the live WPM; the same
consumer replays synthetic text alone and inside a session.

**Dashboard Export and Purge.**
`_shared/tests/corpus/keystats/metrics_maintenance_vectors.json` now runs on
macOS through the real dashboard request, ingest and writer, in a zone east of
UTC, and its three ledgers replay in every order into stores the real writer
opens (`tests/meta/corpus/test_corpus_keystats_metrics_maintenance.lua`). The
replay found one defect: the writer stores a row's ts in UTC (KMD-1) but the
Purge looked its tombstone up by the tombstone's local ts, so outside UTC a
Purge deleted the metrics and then answered "refused". The lookup now uses the
UTC instant the tombstone's metadata carries. The hosted runners run in UTC,
where the two stamps coincide; the existing ingest test was red only in other
zones.

**Menu corpora.** Review of the 96 corpora of `_shared/tests/corpus/menus/` for
the rows macOS draws. macOS now replays every corpus whose rows it draws, and
Linux replays the same four corpora that carry Linux rows:

| Corpus                                                                    | macOS consumer                                                                                                                |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `hotstring_extension_frames`                                              | `tests/unit/menu/ui/hotstrings/test_extension_hotstrings.lua` (`native_order.hs`)                                             |
| `hotstrings_parameter_frames`                                             | `tests/unit/menu/ui/hotstrings/test_parameter_frames.lua` (`delays.hs`, `mac_delays_ms`)                                      |
| `indentation_control`                                                     | `tests/unit/ai/ui/menu/settings/test_transaction_shared_controls.lua` (choices and cases)                                     |
| `profile_create_command`, `profile_clone_command`                         | `tests/unit/ai/ui/menu/profiles/test_candidate_transaction_deferred_editor.lua`                                               |
| caption, affix, prefix, fixed-parent, separator, magic-key-source corpora | the shared contracts of `_shared/tests/lua/menu/` and `layouts/magic_key_source_contract.lua`, registered by the macOS suites |

The macOS Lua frame places Clone in its own section above Create, unlike the
Windows frame; only the two command declarations are shared. The corpora macOS
does not replay are not macOS rows:

- `windows_*` (four) pin Windows-native captions, and `startup_bootstrap_captions`
  the Windows tray drawn before the full menu loads (the generated
  `startup_tray_projection.ahk`); the macOS menu bar has no such pre-load tray;
- `linux_*` and `agent_linux_disabled_apps` are Linux rows;
- `personal_shortcuts_frame` declares its rows for Windows only
  (`platform_rows.hs` is empty): macOS lists the same shortcuts under rows of its
  own, a menu-structure difference recorded in the feature inventory;
- `llm_complete_presentation_owners` describes manifest ownership and is read by
  the JS menu gate, not by a driver.

Linux consumers, under `linux/tests/unit/`:

- `hotstring_extension_frames`: `menu/hotstrings/test_extension_hotstrings.lua`
  (`native_order.linux`, drawn in English as the corpus writes it, and
  `linux_without_extensions_returns_nil`);
- `hotstrings_parameter_frames`:
  `hotstrings/engine/preview/test_parameter_frames.lua` (`delays.linux`,
  `linux_delays_ms`, `preview.linux`, `parents`);
- `profile_create_command`, `profile_clone_command`:
  `ai/engine/settings/test_profile_settings.lua`, through the real Create and
  Clone rows and their declarations in the manifest.

## Review status at pause — November 5, 2026

The maintainer requested a pause after the dead-key campaign delivered in
`04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9`. This register describes the work
already recorded in the repository; it starts no additional audit. Each dated
report owns its audited revision, exact coverage, rejected hypotheses and proof
limits. **Deeply reviewed does not mean fixed, bug-free or native-certified.**
Later corrections and adjudicated findings take precedence over raw submissions.

### Focused cross-platform investigations already recorded

These campaigns follow named flows through their owners, callers and settlement
boundaries. Their scope includes Windows, macOS and Linux, with shared review
where the linked campaign records it. The links retain the per-OS detail;
a row is not a claim that every function or every physical scenario was tested.

| Area                           | Reviewed in depth                                                                                                                                                                                                         | Evidence                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Dead keys and composition      | Pending-state ownership, disabled rows, grouped character payloads, consumed continuations, chains and converter/locale collisions; six shipped layouts, 140 states and 4,391 explicit converter expectations             | [Dead-key campaign](audits/platform-parity/2026-11-05-dead-keys/report.md)                                               |
| Tap-holds, chords and layer    | No-hold tap rules, lone tap window per rule, pair first-key choice, pair tap/layer interplay, chord defaults, macOS generator per-key rules; source and model replays, no native receiving                                | [Tap-hold campaign](audits/platform-parity/2026-11-10-tap-holds/report.md)                                               |
| Hotstring cascade and undo     | Cascade link choice, private/key/no-op winners, final-entry outranking, delay masking, bare `:` end characters, Backspace undo eligibility/casing/failure, dynamic and personal tags; engine replays, no native receiving | [Hotstring cascade campaign](audits/platform-parity/2026-11-11-hotstring-cascade/report.md)                              |
| Gestures and touchpad          | Incremental diagonal travel and reversal, axis lock in the diagonal band, click hold release, contact join, sensitivity; engine replays on the Lua drivers, no touchpad or AHK receiving                                  | [Gestures campaign](audits/platform-parity/2026-11-11-gestures/report.md)                                                |
| Metrics producers and ledger   | Network/topology/capture privacy, ledger import of control bytes, imported Wi-Fi changes, imported system days, collector field parity; recorder and rebuild replays, no native receiving                                 | [Metrics campaign](audits/platform-parity/2026-11-11-metrics/report.md)                                                  |
| AI request-to-output           | Refused-credential classification through Backboard creation and token exchange, streamed partials across retries, refill and retry budget, successors; engine replays over a scripted HTTP client                        | [AI flows campaign](audits/platform-parity/2026-11-11-ai-flows/report.md)                                                |
| Input and layout joins         | Shortcuts under an emulated layout (release, US fallback, repeat), number row, consumer order, modifier and device currency; fixture replays, no native receiving                                                         | [Input/layout campaign](audits/platform-parity/2026-11-11-input-layout/report.md)                                        |
| One-shot Shift                 | Public activation, next-key consumption, modifier context, repeated presses, timeout and retirement                                                                                                                       | [One-shot campaign](audits/platform-parity/2026-11-05-one-shot-shift/report.md)                                          |
| CapsWord                       | Activation, accepted output, delimiter exits, timers, pointer identity, configuration publication and synthetic-key counterchecks                                                                                         | [CapsWord campaign](audits/platform-parity/2026-11-05-caps-word/report.md)                                               |
| Word reset and AI context      | Independent word/context lifetimes, following keys, edited controls, synthetic origins and lifecycle retirement                                                                                                           | [Word-reset campaign](audits/platform-parity/2026-11-05-word-reset/report.md)                                            |
| Repeat and immediate recovery  | Magic-key repetition, corrections after repeat, word boundaries, private ancestry and eligible immediate Backspace restoration                                                                                            | [Repeat/recovery campaign](audits/platform-parity/2026-11-05-undo-repeat/report.md)                                      |
| WPM                            | Widget publication, native draw/resize refusal, placement, pointer handling, idle behavior and configuration precedence                                                                                                   | [Sequential campaign: WPM](audits/platform-parity/2026-11-05-sequential/report.md#wpm)                                   |
| Wrap symbols                   | Pair catalogue, custom pairs, spaced delimiters, selection completeness, clipboard restoration and endpoint aliases                                                                                                       | [Sequential campaign: wrap](audits/platform-parity/2026-11-05-sequential/report.md#wrap-symbols)                         |
| Personal information           | Field/alias generation, literal values, command-token boundaries, source location, first creation, destination authority and preview/privacy rules                                                                        | [Sequential campaign: personal information](audits/platform-parity/2026-11-05-sequential/report.md#personal-information) |
| Managed local runtime          | Provisioning, deadlines, refusal, repair authority, source identity, native settings and completion/retirement boundaries                                                                                                 | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| WebView editors                | Shared frontend and host joins, zero-valued delays, save/reload/close refusals, draft preservation and configuration serializers                                                                                          | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| Diagnostics                    | Collection/export/page joins, backend and disabled-state reporting, partial output, timer refusal and local versus shared privacy                                                                                         | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| Folder/configuration migration | Destination collisions, physical aliases, locators, alternate roots, refusal, retry and next-start adoption                                                                                                               | [Migration/update campaign](audits/platform-parity/2026-11-04-recovery/report.md)                                        |
| Update/reload handoff          | Chosen-release transactions, leases, armed installation, restart receipts, native alternatives and package-manager ownership                                                                                              | [Migration/update campaign](audits/platform-parity/2026-11-04-recovery/report.md)                                        |
| Clipboard and selection        | Borrow/restore ownership, concurrent clipboard changes, target focus/range and cross-owner transformations                                                                                                                | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Credentials and cipher storage | Typed ingress, persistence markers, SQL/storage joins, credential publication and cryptographic native-component controls                                                                                                 | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Configuration persistence      | Save/publication refusal, authoritative next-start values, durable ownership and truthful saved/applied/restarted reporting                                                                                               | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Fixed desktop actions          | Actual dispatch, acknowledgment/refusal and overlapping native setting changes through bounded worker controls                                                                                                            | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |

### Broader module reviews already recorded

The [18 OS × module review](audits/platform-parity/2026-11-04-deep/report.md)
already inspected hotstrings, input/remapping, AI, metrics, lifecycle and
gestures separately on all three OSes. The [earlier module review](#independent-module-review-2026-11-04)
also records their declarations, implementations and corrected false gaps.
These areas are **not untouched**. Their broad reviews do not replace a focused
end-to-end campaign for every submodule listed below. The later focused
campaigns above extend particular parts of that coverage.

### Remaining investigation, implementation and qualification

The root [TODO](../TODO.md) remains the only implementation checklist and the
owner of individual finding IDs, policy questions and physical acceptance.
This section records investigation boundaries, not a duplicate checklist.
No new investigation is being launched at this pause.

| Remaining work                                    | Starting point and boundary                                                                                                                                                                                                                                                    |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Reconcile coverage with current source            | Generate a fresh source-area census and match its areas to the dated coverage registers. Classify unmatched or changed areas as requiring review; file presence alone never establishes review or feature parity.                                                              |
| Next focused module: tap-holds, chords and layers | Deepen the existing input review: activation/rollover arbitration, held modifiers, repeats, remapped versus native ownership, simultaneous devices, pause/reload/source change and actual action settlement. Keep all OS/shared reviewers on this one module before advancing. |
| Hotstring cascade and trigger arbitration         | Deepen the broad hotstrings review beyond the separately covered repeat, CapsWord and personal-data routes: automatic/terminator cascades, precedence, delay admission, Unicode/word boundaries, preview/output agreement and interrupted output.                              |
| Gestures and touchpad event ownership             | Deepen the existing gestures review with complete slot-to-action flows, axis/threshold/repeat handling, device/session capability, disconnection and retirement. Real hardware acceptance remains separate.                                                                    |
| Metrics beyond the WPM widget                     | Follow each producer through collection/privacy, persistence/ledger, aggregation, export and dashboard display. The broad metrics findings already exist; verify units, missing producers and cross-device behavior without recounting them.                                   |
| AI request-to-output flows                        | Deepen the broad AI review for prediction/streaming, cancellation/successors, retry/refill, model/profile changes and deferred agent/connectors. Managed-runtime provisioning is already a separate focused campaign; live-provider interoperability is still distinct.        |
| Remaining input/layout engine joins               | Extend the existing input and dead-key work to full shortcut/layout/number-row/replay ordering, modifier/source currency and multidevice state. Do not count an emulation path as equivalent to native layout receiving without proof.                                         |
| Fix and regress existing findings                 | Reconfirm each issue against current code before implementing its TODO entry. Audit probes preserve observations; they are not fixes or wired regression tests. Deduplicate overlapping reports and retain intentional differences.                                            |
| Resolve product policy                            | Keep existing behavior until a common contract is decided for unresolved fallback, expiry, pause, modifier attribution, privacy or preview questions. Source-visible differences are not automatically intended differences.                                                   |
| Windows receiving                                 | Qualify the relevant original callbacks, installed HKLs, AHK/InputHook/SendEvent, UIA/WebView2 and target applications on Windows. Portable source projections and Linux PowerShell are not these native receipts.                                                             |
| macOS receiving                                   | Qualify NSEvent/dead-key/IME payload grouping, event consumption/output, Hammerspoon/WebKit and lifecycle/service boundaries on a Mac. Controlled Lua ports and dependency-source contracts do not certify a receiver.                                                         |
| Linux receiving                                   | Qualify the active X11/Wayland session, compositor, evdev/uinput/device lifecycle and receiving application. Genuine libxkbcommon/Compose, filesystem and libuv controls cover components, not the entire desktop.                                                             |
| Timing, memory and failure durability             | Measure real typing latency, long-session retention, native races, power-loss recovery, signing/provisioning and relevant provider/network failures. No global G4/RSS guarantee follows from the source audits.                                                                |
| Maintain automatic inventories                    | Keep the normal catalogue generators, reason/localization checks and drift guards current. Add reviewed behavior declarations for newly identified semantics; automatic catalogue discovery does not discover every behavior or prove native equivalence.                      |

The source-area navigation tool can create a fresh **external** snapshot without
rewriting historical audit evidence:

```sh
python3 -B tools/audit/source-areas.py --ref HEAD --output /tmp/ergopti-source-areas-current.json
node tools/audit/parity-census.cjs --census /tmp/ergopti-source-areas-current.json --output /tmp/ergopti-reconciliation.json
```

When work resumes, read the relevant report's coverage and source receipts,
verify source drift, then choose one bounded module from the table. Reuse the
original-owner probes through their documented safe replay mechanism. Some
historical helpers write sibling receipts or embed retired checkout paths;
never run them in place in immutable evidence. Do not infer completeness from
two dry sweeps, a source-file count, declaration coverage or a green generic CI.

### Verification status retained at the pause

The dead-key delivery records 572 passing JS checks, successful final formatting,
source/custody checks and independent replays in its
[qualified local receipt](audits/platform-parity/2026-11-05-dead-keys/validation/verification.json).
Its initial archive-format failure and correction are preserved there.

[Preflight 42121216727](https://github.com/adrienm7/ergopti/actions/runs/42121216727)
on `04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9` finished with failure.
The originating failed job was **Common / Install and launch (Stable site)**,
at **Install production site browsers**; Common's verdict and the final lane
verification consequently failed. That step is not a successful browser/render
receipt. The root TODO retains the final-source CI checkpoint and the separate
native/physical qualification work. No CI workflow is cancelled or relaunched
as part of this documentation checkpoint.

## Dead-key composition continuation

The [November 5 dead-key audit](audits/platform-parity/2026-11-05-dead-keys/report.md) follows four OS/shared owners at `f2c3ea43542c985fb20e5f0887976f1c02525341`. Five roots cover disabled-row continuation routing, grouped macOS payload lookup/output, consumed Linux Compose history and inherited Bépo Compose prefixes. The [generated 13-contract comparison](audits/platform-parity/2026-11-05-dead-keys/capabilities.md) preserves intentional architecture, native policy, known limits and unresolved lifecycle questions. Six registry layouts, 140 states and 4,391 explicit converter expectations are checked; 97 distinct named source paths are authenticated. Genuine native component tests and original owners over controlled ports do not establish actual application receiving. Reproduction/check commands and immutable worker custody are retained in the campaign README; implementation and policy work remains in the root TODO.

## One-shot Shift continuation

The [November 5 one-shot Shift audit](audits/platform-parity/2026-11-05-one-shot-shift/report.md) keeps four OS/shared reviewers on activation, consumption, modifier context, repeated presses and retirement at `9c565c88c9a1366a2e9b18c1b9d2868509510975`. Its90 qualified coverage summaries are not90 native scenarios. Five OS-scoped findings cover Windows named-control modifier attribution, macOS/Linux Caps+Shift title selection, the macOS programmatic timeout domain and Linux repeat ownership. The [generated comparison](audits/platform-parity/2026-11-05-one-shot-shift/capabilities.md) documents the deliberate tap-only Linux route, action aliases, trigger defaults and configuration differences. Replays authenticate original-owner behavior over declared ports; a separate genuine XKB component check does not establish desktop receiving. The dated source checker rejects changed reviewed bytes, and projection controls reject stale or unqualified metadata.

## CapsWord activation and termination continuation

The [November 5 CapsWord audit](audits/platform-parity/2026-11-05-caps-word/report.md) follows public activation, accepted output, configurable termination, timers, pointer identity and retirement at `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`. Four pinned OS/shared reviewers retain159 initial qualified rows and nine new findings. A further synthetic-key countercheck extends existing WRSL-001 with a CapsWord consumer instead of counting a second connector root. The [generated capability comparison](audits/platform-parity/2026-11-05-caps-word/capabilities.md) distinguishes deliberate Windows next-activation settings, macOS fixed exits, gesture constraints, ambiguous common policy and the observed menu/timer/publication mismatches. Native receiving and corrected fixture limits are explicit.

## Word-reset and AI-context continuation

The [November 5 word-reset audit](audits/platform-parity/2026-11-05-word-reset/report.md) follows the repeat/recovery closure at the same `b17e47e` source. Four reviewers compare independent word/AI lifetimes through the following key, synthetic action origins, edited controls, terminal receipts and lifecycle retirement: 98 coverage rows and five qualified findings. The [generated comparison](audits/platform-parity/2026-11-05-word-reset/capabilities.md) retains explicit macOS tap-hold-origin limits, idle architectures, conditional keypad-Enter receiving and unresolved modifier policy. Root replays include a matched-default physical/action Linux arrow control; no native desktop or AHK receiving is claimed.

## Repeat and recovery continuation

The [November 5 repeat/recovery audit](audits/platform-parity/2026-11-05-undo-repeat/report.md) keeps four OS/shared reviewers on one bounded module at source `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`. Its 85 aspect rows follow repeat through actual caller publication, following corrections, word boundaries, private ancestry and immediate Backspace recovery. The [generated comparison](audits/platform-parity/2026-11-05-undo-repeat/capabilities.md) separates explicit preview policy, application Undo, unestablished intent and native receiving gaps. A [supplementary live behavior catalogue](behavior-inventory.md) now reaches the site and documentation, with reviewed-owner drift checks; it does not infer semantic exhaustiveness.

## Sequential WPM, wrap and personal-information continuation

The [sequential November 5 audit](audits/platform-parity/2026-11-05-sequential/report.md) keeps four OS/shared reviewers on the same module before advancing: WPM, wrap symbols, then personal information, at `7aecd9a25b35efdcff68898919506dc2f6fd02d0`. It adds independently replayed owner evidence, qualified Windows source projections and a [generated capability/intent comparison](audits/platform-parity/2026-11-05-sequential/capabilities.md). Canonical findings, shared mechanisms, known duplicates, policy questions and native receiving gaps remain distinct. The root TODO tracks the open findings; dated validators check evidence and projection drift without claiming automated semantic parity.

## Native runtime, editor and diagnostics continuation

The [nine-scope November 5 audit](audits/platform-parity/2026-11-05-native-ui/report.md) follows managed runtime/provisioning, WebView editors and diagnostics separately on each OS at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. It retains 15 qualified findings, documents intentional differences and refuted hypotheses, and adds an automatic source-area register alongside the existing generated feature inventory. Source presence and declared availability remain distinct from verified native behavior. The [capability comparison](audits/platform-parity/2026-11-05-native-ui/capabilities.md) and root TODO record the concrete follow-ups.

The [Nix delivery follow-up](audits/platform-parity/2026-11-05-native-ui/delivery-nix.md) preserves the native process owner while transporting the enlarged Git inventory outside its bounded result capture; its local controls do not claim an installed-Nix build.

## Migration and update continuation

The [six-scope recovery audit](audits/platform-parity/2026-11-04-recovery/report.md) covers the previously excluded folder migration and updater/reload handoff at `3a680d9f530a9af686fccc16d3f7611ec7fb034c`. It adds 17 qualified OS follow-ups and a [machine-readable, rendered capability/intent comparison](audits/platform-parity/2026-11-04-recovery/capabilities.md). Actual native boundaries, shared causes, receiving gaps and two final dry passes are explicit; the Windows updater scope adds controls without a new confirmed root.

## End-to-end continuation

The [12-scope flow audit](audits/platform-parity/2026-11-04-flows/report.md) follows clipboard/selection, crypto/credential storage, configuration publication and fixed native system actions through their actual acknowledgment and cleanup boundaries at `213d65af24d2aa4845ba47743c9bab6787b61964`. Its 26 OS/flow follow-ups include shared causes, explicitly qualified source-only Windows cases and an approved-overwrite data-loss risk. [Intentional behavior and constraints](audits/platform-parity/2026-11-04-flows/intentional-differences.md) remain separate from defects. Canonical declarations still do not certify native behavior.

## Deep review by OS and module

The [18-scope deep audit](audits/platform-parity/2026-11-04-deep/report.md)
examines each combination of Windows/macOS/Linux and hotstrings, remapping,
AI, metrics, lifecycle and gestures at commit
`89b0b774c8c960c7ad458ac3cb98d5c97598e518`. It supersedes earlier availability
conclusions wherever explicitly corrected. Its [intentional-difference register](audits/platform-parity/2026-11-04-deep/intentional-differences.md)
documents rationale, user-visible effects and OS equivalents, distinguishing
explicit policy from native constraints, guarded unfinished work and unknown
product intent. The JSON companion preserves the same audit-snapshot data.

The deep pass produced 30 OS-scoped actionable entries, including a guarded
unfinished capability and a conditional account-context scenario. These are not
30 native-reproduced bugs. Per-entry severity, confidence and reproduction
basis are in the [Windows](audits/platform-parity/2026-11-04-deep/windows-envelope/report.md),
[macOS](audits/hammerspoon/2026_11_04/report.md) and
[Linux](audits/linux/2026_11_04/report.md) envelopes. The same restart-reporting
root cause affects two OSes. Policy candidates and refuted hypotheses are kept
out of the confirmed queue.

**Corrections:** physical shortcut delivery/editor qualification is disabled on
both Lua drivers as well as missing on Windows. Bridge/capture code and test
fixtures did not establish real feature readiness. Windows inline auto-type
inserts a completed continuation, not tokens as they arrive. Complex-key
expansion-delay widening exists on all three drivers; older Mac-only wording
is stale. Current declaration matrices do not establish these runtime facts.

## Independent module review, 2026-11-04

Five parallel, read-only reviewers examined production code and callers at
`c2fa619`, rather than treating catalogue membership as behavioral proof. The
integration review reopened their evidence and independently reproduced the
phone/date matcher output using the real Lua modules with synthetic data. No
native three-OS certification was performed.

| Module                                                        | Coverage                                                                                | Result and evidence                                                                                                                                                                                                       |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Hotstrings](audits/platform-parity/2026-11-04/hotstrings.md) | Static/dynamic/personal/programmed expansion, input gates, previews, private sources    | Three behavior differences: Linux shortest phone prefix fires without magic key; Lua international output retains the national zero; Windows date triggers and boundary semantics differ. Pure Lua reproduction included. |
| [AI](audits/platform-parity/2026-11-04/llm.md)                | Predictions, profiles, local/remote models, tone, translation, vision, agent/connectors | Linux lacks the bounded retry/refill policy implemented on Windows/macOS. Windows retry TODO refuted. Core AI families have real implementations; native connectors differ.                                               |
| [Input](audits/platform-parity/2026-11-04/input.md)           | Tap-holds, holds/chords, layers, layouts, physical editor, gesture vocabulary           | macOS typing-priority rollover differs from release-order classification; working live number-row control is missing from its onboarding. Hold-picker test only establishes Windows/Linux agreement.                      |
| [Metrics](audits/platform-parity/2026-11-04/metrics.md)       | Producers, persistence, ledger sync, aggregation, dashboards, WPM, privacy              | Linux lacks ledger synchronization and some producers; pointer distance units differ. Windows owns extra raw telemetry. Space-change KPI is only actually produced on macOS; night-wake is inert on every OS.             |
| [Lifecycle](audits/platform-parity/2026-11-04/lifecycle.md)   | Installation/startup/uninstall, updater, backups, onboarding, diagnostics, bundled apps | macOS-only diagnostics availability explanation and signed newest-channel feed-install fallback. Linux packaged updates intentionally belong to the package manager. Backup scope qualifications documented.              |

The detailed reports record tests actually executed, source-only conclusions,
rejected hypotheses and remaining environmental limits. The metrics SQL tests
were not green under this environment's Node 24 NUL-string handling; this was
not promoted into a production parity defect. Each confirmed gap is tracked in
TODO. Finding a behavior difference does not authorize silently changing an
explicitly tested product contract, such as Windows's date trigger vocabulary.

### Generation coverage and limits

The normal generator registry and website prebuild now own the inventories.
Website builds refresh the menu projection first, then regenerate availability;
`npm run gen` and the standard generated-output drift guard share its declared
output paths. Every one of the 197 restricted configuration entries has a
translated explicit or matching-section reason. This checks declaration
coverage, not runtime equivalence.

The generated tap-hold key table reads the live `tap_hold.catalog.keys`: native
Command/Option versus Win/AltGr identities are shown without counting them as
missing product functions. The hold picker is not universal: the actual macOS
picker filters its native catalogue, while Windows/Linux enumerate the shared
PC modifier combinations. Gesture slot actuation, onboarding conditions,
installation ownership, real provider availability and telemetry producers
require the module-specific qualifications above. New unregistered runtime
behaviors cannot be discovered reliably from a manifest alone.

## Sources and checks

- Configuration and settings: `_shared/settings/data/features/manifest.toml`, resolved
  with the same platform inheritance as the driver generator. The existing
  Linux evidence gate checks registration, calls, application and proof tiers.
- Bindable actions and gesture axes: `_shared/shortcuts/data/actions/actions.toml`.
  Its generator requires a reason for each missing platform and validates named
  equivalents; driver suites compare generated catalogues to executable actions.
- User-visible unavailable controls: `_shared/menu/data/menu.toml` and its
  generated `menu_manifest.json`. Restricted interactive rows and rows with `unavailable = "grey"` supply the
  platform-specific reason where declared. The menu's own drift and dispatch gates remain the
  authority for its projection and handlers.
- Additional capabilities: compared the three driver module and UI trees,
  runtime entry points, platform-specific action reasons, and the bundled macOS
  app descriptions. Files with matching names are leads, not proof of parity.

The layer editor has an additional canonical vocabulary:
`_shared/layouts/data/layer_actions.toml`. Its actions, modifier restrictions, input
source kinds and parameters are included in the generated action inventory as
`layers.*`. Mouse-button sources exclude Linux, repeat counts are Windows-only,
and Fn and Spotlight belong to macOS. The source explains each restriction.

## Findings beyond individual configuration paths

| Capability                                                  | Windows                                    | macOS                                                          | Linux                                                                                      | Evidence and qualification                                                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Physical shortcut editor                                    | Unavailable: no host                       | Unavailable: native delivery unqualified                       | Unavailable: native delivery unqualified                                                   | Actual macOS/Linux `keyboard_shortcuts.physical_delivery_available()` both return false; deep input reports supersede declaration-only readiness claims. Preserve fail-closed admission.             |
| Token-by-token prediction display                           | Unvalidated and disabled                   | Declared                                                       | Declared                                                                                   | `llm_token_streaming` menu row; distinct from typing predictions directly into a document                                                                                                            |
| Automatic insertion of a completed continuation             | Declared, completed response only          | Bubble then accept                                             | Bubble then accept                                                                         | Windows `inline_autotype` is not token-by-token document streaming; deep Windows AI report records the native output constraint.                                                                     |
| Prompt profile automatically follows model                  | Declared                                   | Applied on request                                             | Declared                                                                                   | `platform_reason.llm_profile_follows_model_is_not_on_macos`                                                                                                                                          |
| Tap-hold word-reset option                                  | Declared                                   | No equivalent option                                           | Declared                                                                                   | `platform_reason.tap_hold_word_reset_not_on_macos`; macOS Karabiner input follows the shortcut option                                                                                                |
| Bulk copy tap assignments to chord slots                    | Declared                                   | Declared                                                       | Declared                                                                                   | `key_combinations_group.copy_tap_to_combo`; Windows `KeyCombinationCopyTapsToChords`; a tap no chord runs keeps its chord on all three (KCL-001, KCM-001)                                            |
| Layout-only restore/clear                                   | Declared                                   | Declared                                                       | Hidden; global restore/clear includes the scope                                            | `layout_menu` and Linux `infra/keyboard_layout_scope.lua`. The menu comment says Linux has no layout settings, but its live number-row and pause-layout controls warrant rechecking that assumption. |
| Shortcut-only restore/clear                                 | Declared                                   | Configuration restore combines shortcut and Karabiner settings | Declared                                                                                   | `scope_restore` and `scope_clear` in `shortcuts_menu`                                                                                                                                                |
| Continuous gesture axes and step sizes                      | Discrete system gestures                   | Continuous                                                     | Discrete                                                                                   | `ax_actions` and `platform_reason.gesture_modes_and_steps_are_macos`; catalogue records discrete equivalents                                                                                         |
| Extra touchpad slots                                        | Three/four finger system slots             | Two to five fingers, including diagonals                       | Shared gesture slot set, subject to device/session                                         | `actions.toml` slots and Windows touchpad reason; actual device support requires testing                                                                                                             |
| Floating WPM widget                                         | Implemented                                | Implemented                                                    | Implemented                                                                                | Windows `ui/wpm/wpm_widget.ahk`, macOS `ui/wpm/wpm_widget.lua`, Linux `ui/wpm/widget.lua` and runtime registration. Linux availability is not hardware proof.                                        |
| WPM in system bar                                           | Notification area                          | Menu bar                                                       | Notification area                                                                          | Same contract on all three (decision 2026-11-06)                                                                                                                                                     |
| Wrap-symbol pair management                                 | Custom add/delete and bulk controls        | Custom add/delete and bulk controls                            | Fixed-pair invocation; no custom/bulk menu controls                                        | Linux `ui/menu/menu_shortcuts.lua`; shared `wrap_symbols_*` control rows filter Linux                                                                                                                |
| Focused-application identity                                | Native API                                 | Native API                                                     | X11 and selected Wayland compositors; unavailable on GNOME, KDE, COSMIC and Weston Wayland | `linux/platform/focus/window_info.lua`; unknown identity constrains per-application rules and is not equivalent to an empty application                                                              |
| Tap-hold copy confirmation                                  | Check supported by platform implementation | Check supported by platform implementation                     | Unchecked on Wayland or X11 without xclip                                                  | `linux/platform/remap/tap_copy.lua`: copy is sent, but the counter-dependent retry and warning cannot run                                                                                            |
| Pointer center, teleport, spotlight                         | Declared                                   | Declared                                                       | No implementation                                                                          | `sg_actions` reasons: Wayland restricts pointer moves/overlays; X11-only implementations remain potential work                                                                                       |
| Open terminal or create file in current file-manager folder | Declared                                   | Declared                                                       | No implementation                                                                          | Action catalogue records lack of a common Linux file-manager interface; per-file-manager support remains potential work                                                                              |
| Accented-key shortcut remapping                             | Declared                                   | Native layout control/command layer                            | Declared on the system layout                                                              | `platform_reason.accented_shortcuts_need_a_layout_file_on_macos`; under emulation the layout's Command level decides (layout capabilities above)                                                     |
| MLX local inference                                         | Not applicable                             | Apple Silicon                                                  | Not applicable                                                                             | `platform_reason.llm_mlx_is_apple_silicon`; Ollama is separate                                                                                                                                       |
| Keyboard layout emulation                                   | Declared                                   | Declared, over any input source                                | Declared, over any XKB layout                                                              | Each driver types the emulated layout itself (layout capabilities above); `platform_reason.layout_master_switch_is_windows` covers only the Windows category gate                                    |
| App Cloner bundled application                              | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/App Cloner.app/Contents/Info.plist`; separate app clones and profiles                                                                                                                    |
| Encryptor bundled application                               | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/Encryptor.app/Contents/Info.plist`; file encryption/decryption is distinct from text and metrics encryption                                                                              |

Some missing menu rows have equivalent providers rather than missing features: Linux's
`llm_generation` provider exposes min/max words, temperature, prediction count
and context length even though the native Windows/macOS presentation rows are
absent. See `linux/ai/ui/menu/llm.lua` and `ai/engine/settings/settings.lua`.

Windows programmable hotstrings are an equivalent presentation rather than an
absence: `menu/ui/builder/submenus.ahk` calls `_HS_ProgrammableHotstringRows`, whose
commands open, reload or repair the user's source. Likewise Linux prompt actions
reach `prediction_engine.trigger_prompt` through `llm_prompt_prediction`; the
absence of macOS's per-profile shortcut dialog does not remove prompt actions.

The English catalogue also contains stale Linux claims. The reason
`platform_reason.llm_configuration_surface_is_not_on_linux` says Linux has no
backend, profile, trigger or display surfaces, while `linux/ai/ui/menu/llm.lua`
provides them and `menu.toml` explicitly selects Linux's inline generation
provider. `platform_reason.metrics_extras_are_not_on_linux` says there is no
per-application exclusion, while `linux/ui/menu/menu_metrics.lua` and
`modules/keystats/keystats.lua` implement it. These strings are not reliable
proof of absence; correcting and propagating their translations is tracked in
TODO. The Linux action `open_personal_shortcuts` additionally resolves
`personal_shortcuts.toml`, but the declared editable shortcut owner uses
`config.toml`; no production reader of that file was found in this tree. Its
actual behavior requires verification and is tracked separately.

The complete action-level list also includes OS-specific system commands,
keyboard shortcuts, sticky modifiers and equivalents. For example, a missing
macOS `copy` action is provided as a modifier/key combination, and a missing
Windows executable-permission action reflects the OS permission model. The
queue deliberately retains these entries with reasons instead of counting all of
them as missing product features.

The comparison does not establish that every unregistered feature has been
identified, nor that all declared features behave identically. New capabilities
must be registered in the appropriate shared catalogue; code review and runtime
or hardware tests remain necessary to establish behavior. Linux evidence tracks
hardware proof independently of software registration.
