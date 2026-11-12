# Start at login: Windows, macOS and Linux

Audited source: `54e2486f` (`dev`). Date: November 12, 2026.

## Source census reconciliation

`tools/audit/source-areas.py --ref HEAD` gives 381 areas against the 363 of
the last pinned census (`2026-11-05-native-ui/source-areas.json`): 18 new
areas (Linux `apps`, `desktop_focus`, `keep_awake`, `take_note`,
`bundled_apps`, desktop application resolution and its worker, reload
refusal; shared `lua/color`, `lua/linux_app_identities_data.lua`,
`lua/secure_apps.lua`, `lua/secure_apps_data.lua`, `ui/key_names.js`,
`ui/layout_editor`, `ui/metrics_manifest_keys.js`; Windows `apps`,
`native/keyboard_layout`, `ui/physical_shortcuts`), none removed, 220 with
changed members. Areas changed and never campaigned (outside the modules
listed in `TODO.md` « Parity audit pause and resumption »): `ui/menu` on each
OS (42 changed members on macOS, 23 on Windows, 20 on Linux) and shared
`modules/menu`, `lua/menu`; `infra` i18n and locale fallback; the editors
(`ui/hotstring_editor`, `ui/personal_info_editor`, `ui/layer_editor`,
`ui/layout_manager`, shared `ui/layout_editor`); `ui/healthcheck`,
`ui/onboarding`, `ui/wpm` and `ui/tooltip`; the Linux `install` area
(13 members). This campaign takes start at login, the smallest of them, in
`ui/menu` on each OS.

Windows (`windows/infra/start_at_login.ahk`, `windows/ui/menu/menu_init.ahk`)
is the read-only reference; macOS `ui/menu/start_at_login.lua` with the
launcher's `LoginStartupWorker.swift`, Linux `ui/menu/start_at_login.lua`
with `install/start_at_login.sh`. Candidates were replayed through the real
Lua modules with injected workers; no Startup folder, `SMAppService` or
systemd user session was touched.

## Fixed

| Id      | Sequence                                                              | Windows                                                         | Before                                                               | Regression                                               |
| ------- | --------------------------------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------- |
| SAM-001 | macOS: click Start at login, macOS answers « requires approval »      | Opens Startup Apps and shows the failure dialog too (see below) | System Settings opened behind « Could not change automatic startup » | `an approval answer tells the user the step left`        |
| SAM-002 | macOS: the menu reads the state while the launcher cannot be resolved | `StartAtLoginEnabled` logs « Startup state could not be read »  | No log line; a refused worker logged at every menu rebuild           | `logs a failed status read once until a read succeeds`   |
| SAL-001 | Linux: the helper fails a status read, an enable, or does not confirm | Each failure is logged (`LoggerError("Startup", ...)`)          | No log line at all; only the generic dialog for a click              | `logs a failed read once until a read succeeds, and ...` |

The approval notice is a new key, `dialog.start_at_login.approval`, in the 21
locales, worded for any system's startup settings so Windows can show it
too. A failed read is logged once per distinct failure until a read
succeeds again, since each menu rebuild reads the state.

## Windows, report only

- **SAW-001.** `StartAtLoginToggle` runs `ms-settings:startupapps` when
  Startup Apps keeps the new shortcut disabled, then throws, so the user
  reads « Could not change automatic startup » while the settings page they
  must use opens. Counterpart of SAM-001: show
  `dialog.start_at_login.approval` (informational) on that branch, the
  failure dialog on the others.

## Decision for the coordinator

- **SAD-1, a source run on Linux.** `start_at_login.sh` exits 78
  (« requires an installed copy ») outside `/usr/lib/ergopti` and
  `*/lib/ergopti/linux`, so on a checkout the row is enabled, unchecked, and
  every click shows the failure dialog. Windows registers its source script
  (`StartupLaunchCommand` with the interpreter); the macOS developer app's
  bundle identifier differs from the worker's `kErgoptiBundleId`, so it is
  refused too (to confirm on a Mac).
  - A (recommended): grey the row on a source run with a reason, as
    Uninstall already is (`installed_build`), on Linux and on the macOS
    developer app.
  - B: support a source run on Linux (an autostart entry for the checkout's
    launcher), as Windows does.
  - C: keep the current behaviour.

## Checked and kept

- A read never creates or removes an entry on the three OSes; a click
  changes it only after a confirmed read and confirms the new state.
- Another startup command (a foreign shortcut, desktop entry or user unit) is
  never acquired: Windows and Linux disable the row with
  `menu.about.startup_other_command_reason`.
- macOS queues one click while a read is in flight and never shows a
  checkmark the native worker did not confirm.
- Changing the setting never stops the running driver.

## Left

- Native receiving (a real Startup folder approval, `SMAppService`, a systemd
  user session) is unqualified.
