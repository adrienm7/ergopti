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

## Fixed after review

- **NUI-003 (Linux):** `adapters/notifier.lua` backgrounded `notify-send … &`,
  so a notify-send that ran and failed (no notification daemon, no session bus
  in the unit) was never logged and its text never reached the log fallback.
  It now runs as an argv through `ShellRunner.run_async` under
  `[ui] notification_send_timeout_ms`; the exit callback logs the failure and
  keeps the notice in the log. Ownership stays with the process operation (a
  notice never delays shutdown; the deadline stops the child's group).
  Fixtures use `ShellRunner._set_async_runner`; every Linux test process puts a
  sentinel `notify-send` first on PATH (`tests/support/notify_send_guard.lua`,
  pinned by `nui-003-spawn-guard`), so no test can show a real notification.
  Regression `nui-003-notify-send-failure`.
- **NUI-005 (macOS):** measured through the real watcher, four refused
  source-change reloads then an admission gave five « Reloading » notices. The
  notice is now sent once per burst. Regression
  `nui-005-refused-reload-notice`.

## Left

- The Linux runner counts the notices that reach the notify-send sentinel
  (about 370 across the groups, through fixtures that keep the real notifier)
  instead of failing the run; make the count fatal once those fixtures install
  `ShellRunner._set_async_runner`.

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
