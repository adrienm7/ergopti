# Tray adapters

Audited source: `db0de8ff62` (`dev`). Date: November 20, 2026. Fourth
campaign in the order of the [2026-11-19 census](../2026-11-19-census/report.md),
after the [managed Ollama runtime](../2026-11-20-managed-ollama/report.md). The
census found the tray adapters never campaigned: the
[menus-tray campaign](../2026-11-12-menus-tray/report.md) read the menu
composition and its refresh, not the code that puts an icon in the tray.

## Scope

The code between the rendered menu tree and the system tray, on the three
drivers and their shared owners:

- Windows: `windows/tray/` (`bootstrap.ahk`, `state_tip.ahk`,
  `adapters/menu.ahk`, `adapters/notify_icon.ahk`,
  `adapters/startup_click.ahk`, `adapters/startup_commands.ahk`), the icon and
  tooltip owner `UpdateTrayIcon` (`core/lifecycle/engine/lifecycle.ahk`), the
  reveal in `ErgoptiPlus.ahk` and the balloon click owner
  (`modules/updater/self_update.ahk`);
- macOS: `macos/tray/adapters/menu.lua` and the menu-bar item it adopts
  (`macos/menu/ui/init.lua`: `update_icon`, the static menu push, teardown);
- Linux: `linux/tray/adapters/appindicator.lua` and `menu.lua`, their wiring in
  `ergopti_hotstrings.lua` and the start check `core/ui/engine/gui_stack.lua`;
- shared: `_shared/tray/protocol.lua`, `_shared/core/ports/TrayMenu.spec.js`,
  `_shared/menu/data/startup_tray.toml` and its generated projection.

Read for each: the icon states, the menu build and rebuild, the click and
double-click actions, the tooltip, how a row's check, greying and reason reach
the native menu, the accessible names, the localization of every row, the
refresh after a configuration change, a missing tray host and the teardown.
Source reading plus the AutoHotkey suites; no tray was rendered on a desktop.

Checked and kept:

- **Icon states.** The three draw two states, active and paused, from the same
  logo (`static/img/logo/logo_simple{,_disabled}`; Linux ships byte copies
  pinned by `test-linux-tray-icon-assets.cjs`). macOS alone offers a second
  variant, `[ui] menubar_icon`, declared macOS-only with
  `platform_reason.layout_bundle_and_menubar_are_macos`. No driver draws an
  error or update icon: an update shows as a menu row and a notification on the
  three. TRAY-04 corrected the port spec that said otherwise.
- **Rows.** The shared renderers decide every label, check and greying; a
  greyed row's reason is part of its label (« label — head of the reason »), so
  it reaches each native menu as text. The adapters only carry `checked` and
  `disabled`: AutoHotkey `Check` and `Disable`, the `hs.menubar` fields, GTK
  check items and `gtk_widget_set_sensitive`. A greyed Linux row gets no action
  at all, since dbusmenu can activate an insensitive item.
- **Rebuild.** Windows replaces its root through the root coordinator, macOS
  pushes a prebuilt static menu after a state change, Linux patches its GTK
  menu in place when the row shapes are unchanged and rebuilds a changed node.
  A click on a replaced row runs nothing on the three (dispatcher reset, click
  gate, never-reused action ids). A language change reloads Windows and
  rebuilds macOS and Linux, whose icon description follows.
- **Tooltip and accessible name.** The three name the icon with
  `accessibility.tray_tip` and say the pause with
  `accessibility.tray_tip_paused`: the Windows tooltip, the macOS tooltip, the
  Linux icon description (libayatana has no tooltip; its title stays
  « Ergopti+ »). Each follows the pause and the locale. See TRAY-01 for boot.
- **Missing tray host.** Linux refuses to start with `--tray` when GTK 3 or
  libayatana is missing, names the package in the user's language
  (`startup.linux_gui_stack_tray_body`) and exits 69. macOS treats a failed
  `hs.menubar.new` as a failed start (`menu.start did not commit`), reported by
  the launcher's localized fatal alert (`dialog.fatal_error.cannot_start`).
  Windows always has its tray: AutoHotkey adds its icon again when Explorer
  broadcasts `TaskbarCreated`, as the WPM readout does for its own icon.
  TRAY-03 added the check for a Linux desktop with no tray host at all.
- **Teardown.** AutoHotkey removes its tray icon at exit and the driver deletes
  the WPM readout icon (`WPMTrayReadout_Shutdown`); Hammerspoon removes its
  menu-bar item when it quits or reloads, and a failed start deletes it
  (`TrayMenu.destroy`); the Linux daemon sets its indicator passive and
  releases it at a clean exit, and its D-Bus name goes with the process.

## Fixed

| Id      | OS        | Sequence                                                                     | Reference                                                                                                                                                   | Before                                                                                                                                                                                                                                                                                                                                                                                                                                          | Regression                                                                                                                                                                                                                                                                               |
| ------- | --------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TRAY-01 | Windows   | Start the driver in any language but French and right-click it as it appears | Linux draws its tray after `i18n.init()` (the same bug, fixed 2026-08-07, `test_i18n_is_ready_before_the_tray.lua`); macOS names its item when it builds it | The icon was revealed before `Onboarding_Run` with rows projected from `_I18nLocale`, still the module default `fr` until `I18nInit` some 60 lines later: « ⏸︎ Suspendre », « 🔄 Recharger », « ⏹ Quitter » until the refresh before feature initialization, and « ErgoptiPlus — Démarrage… » during the whole first-run wizard, which opens in English. No tooltip was set before the tray root: a screen reader read the script's file name | `the cold tray appears in the configured locale, named` (meta), `the icon is named before it is shown` and `the first-run startup row follows the wizard's locale` (unit)                                                                                                                |
| TRAY-03 | Linux     | Start the daemon with `--tray` on GNOME without the AppIndicator extension   | Windows and macOS always show their icon; a missing tray library is already refused in words (`gui_stack.lua`)                                              | libayatana created its icon with no `org.kde.StatusNotifierWatcher` host and fell back to an XEmbed `GtkStatusIcon` nothing embeds: « Tray icon created », then no icon, no menu and no word                                                                                                                                                                                                                                                    | `test_tray_host_check.lua`: `a session with no host tells the user what to install, three ways`, `a probe that cannot read the session is logged, never told as a missing tray`, `a --tray launch schedules the check once the icon is up` and four more                                 |
| TRAY-04 | the three | Call the port's `setIcon` as `TrayMenu.spec.js` describes it                 | The spec is the contract a new driver is written from                                                                                                       | `setIcon(state)` over `active`, `paused`, `disabled` that « adapters MUST accept »; no adapter took a state, and the `set_icon_*` vectors only asked for no exception, which an adapter ignoring its argument satisfied                                                                                                                                                                                                                         | `set_icon_draws_the_image`, `set_icon_refuses_a_missing_file`, `set_icon_refuses_a_state_name` and `destroy_then_set_icon_is_safe` on the three mirrors; `test-port-vector-traceability.cjs` requires them                                                                               |
| TRAY-05 | the three | Remove the paused logo file of an install and pause                          | —                                                                                                                                                           | Windows kept the running icon (`if FileExist(...) TraySetIcon`), macOS drew `logo_simple.png` for a missing disabled logo and « 🔧 » for a missing logo, Linux resolved a missing paused logo to the active one, all without a log line                                                                                                                                                                                                         | `a missing logo file is said, not drawn as the other state` and `only the tray owners draw the tray icon` (AHK), `test_menubar_logo_missing.lua` (macOS), `a missing paused logo never resolves to the running one` and `draws the warning sign, logs the file once and says so` (Linux) |

Notes:

- **TRAY-01.** A normal boot now projects its native startup commands right
  after `I18nInit`, names the icon (`TrayRevealNamed`, `state_tip.ahk`) and
  only then reveals it; the later refresh, now redundant, is gone. Until then
  the icon stays hidden behind the inert bootstrap row, which still replaces
  the stock items before anything else (AHK-21). A first run never reaches
  `I18nInit` (its wizard reloads the driver), and its icon brings the wizard
  forward, so it still appears before the wizard: its row and its name are
  projected in `ONBOARDING_FIRST_RUN_LOCALE`, the language the wizard opens in
  (`TrayBootstrapInertLabel`, `_Onboarding_Translate`). One function,
  `_DriverRevealTrayIcon`, holds the only `A_IconHidden := false`.
- **TRAY-03.** `tray/adapters/status_notifier_host.lua` reads the session:
  `NameHasOwner` of the watcher, its `IsStatusNotifierHostRegistered`
  property (no auto-start, each call bounded by `[ui] tray_host_bus_timeout_ms`)
  and the X11 `_NET_SYSTEM_TRAY_S<screen>` selection, so an XEmbed-only panel
  (i3bar, an old XFCE panel) counts as a host. `tray/engine/host_check.lua`
  runs it once, `[ui] tray_host_check_delay_ms` (15 s) after `start()`, since
  the GNOME extension registers its watcher only once the shell has loaded.
  With no host it says so through the status window, a notification and the
  console (`startup.linux_tray_host_missing_title` and `_body`, which names
  `gnome-shell-extension-appindicator`); a probe that cannot read the session
  is an error in the log, never a « no tray » message.
- **TRAY-04.** The spec (2.0.0) states the real contract: `setIcon` takes an
  option map whose `image` names an existing file and returns whether it is
  drawn; a missing file or a map without one is refused with one logged error
  and the previous icon stays. The two states stay with the pause owners,
  outside the port. The three adapters implement it (Windows and macOS keep
  their `title` extra; Linux creates its icon through `start()` instead of a
  `setIcon({ title })` that drew nothing), and the mirrors read the result:
  `A_IconFile`, what `hs.menubar` received, what the indicator received. The
  dead node shape left in `set_menu_replaces_previous` is gone too. The
  Windows `TrayMenuSetMenu` and `TrayMenuDestroy` still have no production
  caller; they are port surface, kept.
- **TRAY-05.** Each pause state draws only its own file. Windows draws through
  `TrayApplyStateIcon` (`state_tip.ahk`, the one owner of the boot and pause
  icons) and falls back to the `user32.dll` warning sign; macOS chooses through
  `menu/ui/menubar_logo.lua` and draws « ⚠︎ »; Linux resolves through the
  shared protocol, which no longer falls back to the other state, and draws the
  themed `dialog-warning`. One error is logged per missing file and the icon's
  accessible name says the file is missing
  (`accessibility.tray_tip_icon_missing` and `_paused_icon_missing`).

## Open

- **TRAY-02 (low, Windows; maintainer decision, fixed 2026-11-21):** a
  primary click did nothing on Windows. The maintainer chose the macOS and
  Linux behaviour: `TrayStartupClick.OnTrayMessage` now opens the tray menu on
  `WM_LBUTTONUP` once ready and queues it like a right click during boot
  (`tests/unit/menu/test_tray_primary_click_opens_menu.ahk`; the decision is in
  `docs/memory/maintainer-decisions.md`). The finding as audited: AutoHotkey opens the menu on a right-click only;
  `A_TrayMenu.Default` is never set and no owner handles `WM_LBUTTONUP`
  (`startup_click.ahk` reads `WM_RBUTTONUP` and `WM_CONTEXTMENU` alone), so a
  left click and a double-click are inert. macOS opens the menu on any click,
  and libayatana opens it on the primary click (its GtkStatusIcon fallback on
  both buttons). Windows is the reference and the right-click is its
  convention, so aligning it is the maintainer's choice, not a fix; a change
  would also have to route the early-click queue.

Native receiving, in the three `TODO-tests-<os>.md`: the Windows cold tray in
another language and its name read by Narrator (TRAY-01); a Linux desktop
without a tray host, then with one, the window and notification that say so,
the click and the accessible name (`tray_host_missing`, TRAY-03); a missing
paused logo on the three, its warning sign, its name read by the screen reader
and its single log line (Windows line, `tray_icon_missing` on macOS and Linux,
TRAY-05). The macOS and Linux points are registered in their
`field_todo_coverage.json` and coverage tables.

## Proof

Commit `36224233b7` (TRAY-01).

- **Red on the old code.** With `ErgoptiPlus.ahk`, `tray/bootstrap.ahk` and `tray/state_tip.ahk` taken back from `db0de8ff62`, the three `tray-01` cases fail: the meta case on « the native startup commands are projected only once the configured locale is read », the two unit cases because `TrayRevealNamed` and `TrayBootstrapInertLabel` do not exist.
- **Green on the new code.** `node tools/test/ahk-parallel.cjs --fresh
--only=tray --wait=300`: 171 of 171, every tray, bootstrap, startup click,
  WPM readout and accessibility case; the `boot` filter (542 of 542, among them the reveal position of `test_single_instance_mutex_first.ahk`) and `personal-shortcuts` (12 of 12), which pin where the icon appears.
- **Gates.** `test-ahk-encoding.cjs`, `test-menu-no-duplicate-actions.cjs`, `test-linux-feature-parity.cjs`, `test-shared-literal-inventory.cjs`, the locale gates (`test-locale-*`, `test-action-labels-have-locale-keys.cjs`), `test-no-pinned-source-reads-lua.cjs` and `-linux.cjs`, `lint-conventions.js --fail-on-violations` and the formatter. Red before this campaign and untouched by it: `test-no-pinned-source-reads.cjs` (171 AHK paths over a baseline of 170, none in the files changed here) and `test-config-key-literals.cjs` (three `_shared/core/ui/engine/webview/reading_*.lua` files).
- **Not run here.** The full startup smoke (`test-ahk-full-startup-smoke.cjs`)
  starts a second driver beside the resident one; the Lua suites (no Lua code
  changed); `test-linux-field-report-contract.cjs` and
  `test-field-todo-summary.cjs`, which need Linux or Python (WSL failed during
  the run; the new `tray_host_missing` point was checked against both coverage
  files by hand); `npm run test:js` and `verify-change` (they refuse this checkout's
  Node pin).

Commits `6fb02d7d98` (TRAY-05), `04c92079e1` (TRAY-04), `70083d79fd` (the
TRAY-05 guard off pinned paths), `fee1b92a2d` (TRAY-03), `ec577560d9` (the
Main startup fixture through `start()` and the host check), `9fedb3f955`
(the degraded input-access tray through `start()`, a caller TRAY-04 had
missed), `8111cb6f38` (the macOS menu boot fixture and the two `update_icon`
source pins follow the logo owner) and `71d75452bf` (the host check off the
shared literal ratchet).

- **Red on the old code.** TRAY-05: with `state_tip.ahk` taken back, the AHK
  unit case fails (« This local variable has not been assigned a value »), and
  with `boot.ahk` and `lifecycle.ahk` taken back the source guard names
  `boot.ahk`; with `protocol.lua`, the Linux `menu.lua` and the macOS
  `init.lua` taken back from `7b7e0eec1f` and `menubar_logo.lua` removed, the
  two Linux cases fail on « a paused daemon drawn with the running logo looks
  running » and « the warning sign, not the running logo », and the macOS suite
  fails to load. TRAY-04: with the three adapters taken back from `6fb02d7d98`,
  the Windows vectors fail 4 of 4 (`TrayMenuSetIcon` returned `""`), macOS
  fails `set_icon_refuses_a_missing_file` and `set_icon_refuses_a_state_name`
  on their assertions, Linux fails `set_icon_draws_the_image` on its assertion
  and the three others on the missing `start()`; with the old spec,
  `test-port-vector-traceability.cjs` lists the icon states, the three
  no-exception vectors and the three missing ones. TRAY-03: without
  `host_check.lua` the suite fails to load, and with only the old entry point
  `a --tray launch schedules the check once the icon is up` fails. The
  degraded tray: with the old `access.lua`, `keeps the icon, names the failure
and exits only on Quit` fails.
- **Green on the new code.** AHK (`ahk-parallel.cjs --fresh --wait=300`):
  `--only=tray` 177 of 177, `--only=adapter` 64 of 64, `--only=boot` 547 of
  547, `--only=a11y` 42 of 42,
  `--only=TrayMenu:` 7 of 7, `--only=tray-05` 2 of 2. Lua under WSL (Debian,
  normal user, `git archive` copies, `DISPLAY` and `WAYLAND_DISPLAY` unset):
  Linux `--only tray` 99 of 99 and `--only startup-late-grab` 34 of 34, the
  TRAY-03 cases one by one, the macOS modules
  `test_adapter_contract_vectors_input_and_system` (63 of 63) and
  `test_menubar_logo_missing` (6 of 6). The native probe ran on private session
  buses (`dbus-run-session` and a stand-in watcher): no watcher → `has_host`
  false; a watcher with a host → true; a watcher without one → false. Whole
  suites: Linux 24 316 passed, 65 failed, none of them tray cases, and the
  groups that fail when run alone (`model-cancel-settlement`, the keystats
  `vector reset_` and `vector suspend_` cases) fail the same way on
  `7b7e0eec1f`; the others pass alone on both, and the « Permission denied »
  ones read `/tmp` fixtures a root run left. macOS 29 039 passed, 57 failed:
  each of the 17 modules holding a failure was rerun alone on `7b7e0eec1f` and
  on the final tree with the same tallies, once the two stale `update_icon`
  pins and the boot fixture were fixed (`8111cb6f38`).
- **Gates.** The locale gates, `test-action-labels-have-locale-keys.cjs`,
  `test-shared-literal-inventory.cjs`, `test-linux-feature-parity.cjs` (after
  re-pinning the Linux control owner: the entry point changed only in its tray
  start block), `test-no-pinned-source-reads.cjs` (170 of 170), `-lua.cjs` and
  `-linux.cjs`, `test-config-key-literals.cjs`, `test-ahk-encoding.cjs`, the
  port gates (`test-port-compliance.cjs`, `test-port-vector-traceability.cjs`
  with its baseline raised from 61 to 73, `test-port-adapter-matrix.cjs`),
  `test-timings-registry-liveness.cjs`, `test-linux-tray-icon-assets.cjs`,
  `test-field-todo-summary.cjs` and `test-linux-field-report-contract.cjs` (in
  WSL), `lint-conventions.js --fail-on-violations` and the formatter.
  `test-linux-install-layout-registry.cjs` and `test-linux-elf-needed-closure.cjs`
  fail the same way on `7b7e0eec1f`.
- **Not run here.** The real desktops (field points above); `npm run test:js`
  and `verify-change` (Node pin).
