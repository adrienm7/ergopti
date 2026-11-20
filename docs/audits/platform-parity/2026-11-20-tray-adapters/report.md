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
  three. See TRAY-04 for the port spec that says otherwise.
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
  broadcasts `TaskbarCreated`, as the WPM readout does for its own icon. See
  TRAY-03 for a Linux desktop with no tray host at all.
- **Teardown.** AutoHotkey removes its tray icon at exit and the driver deletes
  the WPM readout icon (`WPMTrayReadout_Shutdown`); Hammerspoon removes its
  menu-bar item when it quits or reloads, and a failed start deletes it
  (`TrayMenu.destroy`); the Linux daemon sets its indicator passive and
  releases it at a clean exit, and its D-Bus name goes with the process.

## Fixed

| Id      | OS      | Sequence                                                                     | Reference                                                                                                                                                   | Before                                                                                                                                                                                                                                                                                                                                                                                                                                          | Regression                                                                                                                                                                |
| ------- | ------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TRAY-01 | Windows | Start the driver in any language but French and right-click it as it appears | Linux draws its tray after `i18n.init()` (the same bug, fixed 2026-08-07, `test_i18n_is_ready_before_the_tray.lua`); macOS names its item when it builds it | The icon was revealed before `Onboarding_Run` with rows projected from `_I18nLocale`, still the module default `fr` until `I18nInit` some 60 lines later: « ⏸︎ Suspendre », « 🔄 Recharger », « ⏹ Quitter » until the refresh before feature initialization, and « ErgoptiPlus — Démarrage… » during the whole first-run wizard, which opens in English. No tooltip was set before the tray root: a screen reader read the script's file name | `the cold tray appears in the configured locale, named` (meta), `the icon is named before it is shown` and `the first-run startup row follows the wizard's locale` (unit) |

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

## Open

- **TRAY-02 (low, Windows; maintainer decision):** a primary click does
  nothing on Windows. AutoHotkey opens the menu on a right-click only;
  `A_TrayMenu.Default` is never set and no owner handles `WM_LBUTTONUP`
  (`startup_click.ahk` reads `WM_RBUTTONUP` and `WM_CONTEXTMENU` alone), so a
  left click and a double-click are inert. macOS opens the menu on any click,
  and libayatana opens it on the primary click (its GtkStatusIcon fallback on
  both buttons). Windows is the reference and the right-click is its
  convention, so aligning it is the maintainer's choice, not a fix; a change
  would also have to route the early-click queue.
- **TRAY-03 (medium, Linux):** a desktop with no tray host shows nothing and
  says nothing. When libayatana loads but no `org.kde.StatusNotifierWatcher`
  owns the session bus (GNOME without the AppIndicator extension), the library
  falls back to an XEmbed `GtkStatusIcon`, which no Wayland session and no
  recent GNOME embeds: the daemon logs « Tray icon created » and the user has
  no menu, while Windows and macOS always show theirs. The memory records the
  fact (`project-linux-first-install-needs-luajit-module-builds`); no start
  check reads the watcher. Follow-up: query `NameHasOwner` for the watcher
  after `create()` and, when it is absent and the fallback icon is not
  embedded, tell the user in their language how to get a tray, as
  `gui_stack.lua` does for a missing library. Field check below.
- **TRAY-04 (coverage):** the port spec describes an adapter nobody wrote.
  `TrayMenu.spec.js` declares `setIcon(state)` with three states, among them
  `disabled` (error), in `ICON_STATES` that « adapters MUST accept ». No
  adapter takes a state: Windows takes `{image, title}` (and `title` sets the
  tooltip), macOS `{image, imageData, title}` (`title` is visible text beside
  the icon), Linux `{icon}` (it ignores `title` and draws the pause through
  `setPaused`). The `set_icon_*` vectors pass on Windows and macOS because a
  string is ignored, so they cannot fail. The real pause owners
  (`UpdateTrayIcon`, macOS `update_icon`, Linux `setPaused`) bypass the port,
  and the Windows `TrayMenuSetMenu`, `TrayMenuSetIcon` and `TrayMenuDestroy`
  have no production caller. Follow-up: rewrite the spec on the two real states
  and the option map, with vectors that read the result.
- **TRAY-05 (low, the three):** a missing icon file is drawn as something else
  without a word. Windows keeps the previous icon
  (`if FileExist(...) TraySetIcon`), so a missing paused icon leaves the active
  one on a paused driver; macOS draws `logo_simple.png` for a missing disabled
  logo and the title « 🔧 » for a missing logo; Linux shows the active logo for
  a missing paused one and warns only when both are missing. The assets ship
  with every build, so only a damaged install sees it; one logged error per
  missing asset would be enough.

Native receiving, in `TODO-tests-windows.md` and `TODO-tests-linux.md`: the
Windows cold tray in another language and its name read by Narrator (TRAY-01),
and a Linux desktop without a tray host (TRAY-03), with the click and the
accessible name on a desktop that has one.

## Proof

Commit `36224233b7` (TRAY-01).

- **Red on the old code.** With `ErgoptiPlus.ahk`, `tray/bootstrap.ahk` and `tray/state_tip.ahk` taken back from `db0de8ff62`, the three `tray-01` cases fail: the meta case on « the native startup commands are projected only once the configured locale is read », the two unit cases because `TrayRevealNamed` and `TrayBootstrapInertLabel` do not exist.
- **Green on the new code.** `node tools/test/ahk-parallel.cjs --fresh
--only=tray --wait=300`: 171 of 171, every tray, bootstrap, startup click,
  WPM readout and accessibility case; the `boot` filter (542 of 542, among them the reveal position of `test_single_instance_mutex_first.ahk`) and `personal-shortcuts` (12 of 12), which pin where the icon appears.
- **Gates.** `test-ahk-encoding.cjs`, `test-menu-no-duplicate-actions.cjs`, `test-linux-feature-parity.cjs`, `test-shared-literal-inventory.cjs`, the locale gates (`test-locale-*`, `test-action-labels-have-locale-keys.cjs`), `test-no-pinned-source-reads-lua.cjs` and `-linux.cjs`, `lint-conventions.js --fail-on-violations` and the formatter. Red before this campaign and untouched by it: `test-no-pinned-source-reads.cjs` (171 AHK paths over a baseline of 170, none in the files changed here) and `test-config-key-literals.cjs` (three `_shared/core/ui/engine/webview/reading_*.lua` files).
- **Not run here.** The full startup smoke (`test-ahk-full-startup-smoke.cjs`)
  starts a second driver beside the resident one; the Lua suites (no Lua code
  changed); `npm run test:js` and `verify-change` (they refuse this checkout's
  Node pin).
