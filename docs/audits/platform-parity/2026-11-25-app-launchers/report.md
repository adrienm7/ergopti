# Application launch adapters

Audited source: `c360c722` (`integrate-2026-11-25a`, `dev` plus unpushed
commits). Date: November 25, 2026. Two units the
[2026-11-19 census](../2026-11-19-census/report.md) lists as never campaigned
(`linux/apps/adapters`, rank 15, and `macos/apps/adapters`, rank 21), read
against the Windows `apps/adapters/launcher.ahk` and the shared
`core/ports/AppLauncher.spec.js` port they implement.

## Scope

- Windows `apps/adapters/launcher.ahk` (`AL_Launch`, `AL_LaunchWithArgs`,
  `AL_OpenStrict`, `AL_LaunchArgvStrict`, `AL_QuoteArgument`,
  `AL_IsRunning`, `AL_ProgramName`);
- macOS `apps/adapters/launcher.lua` (`launch`, `launchWithArgs`,
  `isRunning`);
- Linux `apps/adapters/desktop_opener.lua` and its worker, and its one caller
  `modules/shortcuts/open_selection.lua`.

Read for each: what a launch, a refusal and a failure log, whether a log line
can carry the target or its arguments, how arguments reach the program, and
what the caller learns. The shortcut actions that call these adapters were
read only as callers: another session is changing them today. Source reading
and the macOS Lua suite (Lua 5.4) in a Linux container; the AutoHotkey suites
did not run (no Windows host) and no Windows source changed.

Checked and kept:

- **Arguments.** Windows quotes each argument by the `CommandLineToArgvW`
  rules and starts no shell; macOS passes an argv to `/usr/bin/open -a … --args`
  through the asynchronous task runner; Linux hands one literal target to
  `xdg-open` in a detached session, never through a shell. No adapter lets a
  selected text reach a shell.
- **Linux has no `AppLauncher` adapter.** Its only launch is the desktop
  opener, an `xdg-open` of a path or URL with a bounded confirmation; the
  application shortcuts that need `launch(name)` are the shortcut actions'
  scope. Its caller logs « Could not open the selected target (failed) » and
  « xdg-open accepted the selected … » without the target: the same privacy
  rule as Windows.
- **`isRunning`.** Windows `ProcessExist`, macOS the running-application
  index (never `hs.application.get`, which walks every window); both return
  false on error, as the port says.

## Fixed

| Id     | OS    | Sequence                                                                                                                 | Reference                                                                                                                       | Before                                                                                                                                                                                                        | Regression                                                                                                                                |
| ------ | ----- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| LCH-01 | macOS | Launch a document path that raises, a name no application accepts, a URL, and a program with arguments whose start fails | Windows logs every launch, success or failure, by `AL_ProgramName` (base name or URI scheme), never the target or its arguments | A raised launch logged the full target (`%q`), a failed launch with arguments logged the native error that spelled out every argument, a refusal returned false with no log line, and a launch logged nothing | `application launch logs (lch-01)` (`macos/tests/unit/core/process/test_app_launcher_log_privacy.lua`), six cases, all red before the fix |

Windows and Linux need no change: both already log by program name or by
kind only.

## Open

- None from this campaign. The shortcut actions that call `launch` with a
  list of candidate names now log one warning per refused candidate; their
  owners may prefer one line per action.
