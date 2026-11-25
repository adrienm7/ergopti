# Permission guidance

Audited source: `c360c722` (`integrate-2026-11-25a`, `dev` plus unpushed
commits). Date: November 25, 2026. The next never-campaigned unit of the
[2026-11-19 census](../2026-11-19-census/report.md) outside today's excluded
modules: `macos/ui/permission_dialog` (rank 33), read against what the Linux
and Windows drivers show when the system withholds what the driver needs.

## Scope

- macOS `ui/permission_dialog/init.lua` (the Accessibility, other-copies and
  Login Items dialogs) and `login_items_guide.lua`;
- Linux `platform/input/access.lua` (the `input` and `uinput` access failure:
  notification, fallback tray, exit status 78);
- Windows: no system grant gates the driver; its WebView2 refusal
  (`core/ui/engine/webview/availability.ahk`) is the nearest message.

Read for each: the user's language, what the message names (the app, the
groups, the command), whether it can be dismissed and reopened, keyboard
answers, and what the driver does meanwhile. Source reading, the macOS
dialog's Lua suite and a Node replay of its page script; no Windows source
changed.

Checked and kept:

- **Different by OS, on purpose.** macOS needs a privacy grant the user gives
  in System Settings, so it shows steps and a button that reopens the pane and
  closes itself when the grant poll succeeds. Linux cannot fix group
  membership from the session: it notifies in the user's language, keeps a tray
  icon naming the failure with `--tray`, and exits 78, which the unit does not
  restart. Windows asks for no grant.
- **Localization.** Every string of the three goes through the shared
  catalogue; the macOS page carries the UI language and `dir="auto"`, and the
  bundle path stays left to right inside a right-to-left step.
- **No focus theft.** The Accessibility dialog floats without activating the
  app; the other kinds are ordinary focused windows (ui-focus-not-topmost).

## Fixed

| Id     | OS    | Sequence                                                                | Reference                                                                                                       | Before                                                                                                                                                                                                                                  | Regression                                                                                                                 |
| ------ | ----- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| PRM-01 | macOS | Open the Accessibility dialog, press Tab to « Later », then press Enter | The shared action picker leaves Enter on a focused button to that button (`_shared/ui/action_picker/script.js`) | A document listener answered every Enter with `open_settings` and the browser's default action clicked the focused button too: System Settings opened, then the dialog closed for later. No button had the focus when the dialog opened | `test-macos-permission-dialog-keys.cjs` (JS suite, `shared-ui`): four keys replayed on the page script, red before the fix |

Linux shows a notification with no button, so it has no keyboard answer to
compare; Windows has no such dialog.

## Open

- **Elevated windows on Windows.** Windows keeps a non-elevated process's
  hooks and sends out of an elevated window (UIPI), and the driver says
  nothing about it. Whether to tell the user, as macOS names its missing grant,
  was not decided here: it is a Windows product question, not a drift of this
  unit.
