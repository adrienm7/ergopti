# Notifications and small native UI

Audited source: `889a5c84` (`claude/ergopti-todo-parity-audit`, merged with
`dev`). Date: November 12, 2026.

## Scope

User notifications (refusals, failures, reload and quit notices), their log
traces, levels and lifetimes, tooltips and the tray or menubar state, against
the Windows reference (`windows/infra/quit_admission.ahk`,
`windows/infra/reload_terminal_handoff.ahk`, `windows/adapters/notifier.ahk`,
`windows/infra/user_actions.ahk`). Findings already filed by the
[native UI](../2026-11-05-native-ui/report.md),
[adapters](../2026-11-11-adapters/report.md) and
[lifecycle](../2026-11-12-lifecycle/report.md) reports are not repeated.
Candidates were replayed through the real Lua modules; no notification
daemon, Hammerspoon or AHK was executed.

## Fixed

| Id      | OS           | Sequence                                                                   | Windows                                                                      | Before                                                          | Regression                 |
| ------- | ------------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------- | -------------------------- |
| NUI-001 | macOS, Linux | Quit by shortcut or gesture while an exit already owns the process         | `QuitRequest_Run` notifies a refusal at once (`quit_admission.ahk:177-184`)  | Nothing: macOS logged it, Linux dropped the owner's false       | `nui-001-quit-refused`     |
| NUI-002 | macOS        | Menu Reload while a global action runs, or refused by the coordinator      | `ReloadRefusedNotify` with `init.reload_refused_*` (`lifecycle.ahk:300-303`) | Silence, or « Reloading… » and the old settings                 | `nui-002-reload-refused`   |
| NUI-004 | macOS        | A `run_command` binding fails with a token in its stderr                   | A TrayTip's text is never logged                                             | The body (the stderr line) logged twice, once in French         | `nui-004-notice-privacy`   |
| NUI-006 | macOS, Linux | Any notification                                                           | TrayTip keeps the system duration                                            | 5 s typed on each driver, outside the registry                  | `nui-006-notification-ttl` |
| NUI-007 | Linux        | Open a terminal or create a text file in the file manager folder, and fail | Error notice (`user_actions.ahk:152`)                                        | Info level, while `user_actions` sends the same key as an error | `nui-007-failure-level`    |

The Linux shortcut, gesture and degraded tray Quit share
`QuitRequest.notifying`, which tells a refusal at once with the same
`notify.quit_refused` notice the owner gives a refusal that comes later.
The macOS « Reloading… » notice stays before the request: an accepted fenced
reload can replace the VM before `request_reload` returns. The duration is
`[ui] notification_ttl_ms`.

## Open

- **NUI-003 (Linux, medium):** `adapters/notifier.lua` backgrounds
  `notify-send … &`, so a notify-send that runs and fails (no notification
  daemon, no session bus in the unit) is never logged and the message never
  reaches the log fallback. The documented return value is an admission, not a
  delivery receipt, so callers are not misled; the gap is the lost failure
  log. The fix needs the owned asynchronous process path
  (`ShellRunner.run_async`) with an exit callback, which changes shutdown
  ownership of the child and the shell test seam the notifier's callers use;
  left for a design decision.
- **NUI-005 (macOS, low, plausible):** `infra/file_watchers.lua` sends its
  reload notice before a reload the coordinator can refuse, and retries every
  0.5 s, so a long refusal could repeat the notice; the menu's config watcher
  can notify the same save too. Frequency not measured.

## Windows only (reported)

- Direct `TrayTip` calls with the literal title "ErgoptiPlus"
  (`modules/gestures/actions.ahk:492,572,589`,
  `adapters/system_control.ahk:650`, `infra/user_actions.ahk:152`) bypass
  `NotifierSend`'s "Ergopti+" title and failure logging.
- `TrayTip` calls without `try` (`modules/gestures/screenshots.ahk:853,856,1212`,
  `ui/menu/menu_hotstrings.ahk:582`,
  `ui/hotstrings_config_window/hcw_mutations.ahk:130`) can interrupt their
  action when the shell refuses the balloon.

## Checked and kept

- Feature-toggle notices, `notify.quit_refused` on the tray path,
  `notify.tap_hold.copy_failed` and the crash-report notices share one key and
  level on the three drivers.
- Pause: Windows swaps the icon and ticks the row, Linux and macOS swap the
  icon; macOS also notifies pause and resume (extra, to confirm with the
  maintainer). Tooltips hide on pause on the three drivers.
- `selection.clipboard_busy` is Windows only (only Windows locks the
  clipboard); keep-awake notices differ with each mechanism.
- An unavailable notification backend reports false with a log line on macOS
  and falls back to the log on Linux.
