# Lifecycle: reload, quit, signals, wake and first run

Audited source: `d9224c54` (`claude/ergopti-todo-parity-audit`, merged with
`dev` at `10d00b83`). Date: November 12, 2026.

## Scope

Reload, user Quit, terminating signals and session logout, sleep and wake,
screen lock and session switch, and startup ordering (first run, missing
locale). Windows (`windows/ErgoptiPlus.ahk`, `windows/infra/lifecycle.ahk`,
`windows/infra/i18n.ahk`) is the read-only reference. Findings already filed
by the earlier lifecycle reports
([recovery](../2026-11-04-recovery/report.md),
[macOS lifecycle](../2026-11-04-deep/macos-lifecycle/report.md),
[Linux lifecycle](../2026-11-04-deep/linux-lifecycle/report.md),
[macOS launcher](../2026-11-11-macos-launcher/report.md)) are not repeated.
Candidates were replayed through the real Linux modules under LuaJIT; no
evdev/uinput, systemd session, Hammerspoon or AHK was executed.

## Fixed (Linux)

| Id      | Sequence                                                                            | Windows / macOS                                                                                                   | Linux before                                                                  | Regression              |
| ------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------- |
| LCY-001 | The evdev resynchronisation fails after a resume                                    | Windows logs the failed callback and keeps running (`ErgoptiPlus.ahk:273`); macOS exits 70 for its launcher alert | The keyboard is released and the daemon exits 0: systemd never restarts it    | `lcy-001-failure-exit`  |
| LCY-002 | First run, or a saved locale without a catalogue, in a German session               | The system language, English fallback (`i18n.ahk:144-162`, `macos/infra/i18n.lua` `detect_system_locale`)         | Always French, while the launcher's shell messages follow the session         | `lcy-002-system-locale` |
| LCY-003 | Quit by shortcut or gesture during an update's ready wait, or during a reload       | One shutdown gate (`lifecycle.ahk`); macOS `script_quit` calls `request_user_exit` like the menu                  | The watcher rolled the update back; the reload's restart came back after Quit | `lcy-003-shortcut-quit` |
| LCY-004 | A logout, a second launch's restart or a service stop during the update's probation | macOS `hs.shutdownCallback` reports a quit for any termination that is not a reload                               | No quit report: the previous installation was put back and its daemon started | `update-signal-kept`    |

LCY-001 records a run-time failure through the shutdown coordinator's
`request_failure` (the runtime callback failure and the keyboard hook
stopping on its own) and exits with EX_SOFTWARE (70) once the teardown ran.
Startup refusals (tap-hold, signal handlers) keep their status: a
deterministic refusal would restart every three seconds under
`Restart=on-failure`.

LCY-002 pins the language the Linux unit tests read to French
(`tests/support/session_language.lua`), the catalogue their fixtures were
written against; children keep the real environment.

## Checked and kept

- Reload: Windows and Linux restart the process (`infra/reload_restart.lua`
  postpones it while a window operation or a user program owns cleanup);
  macOS reloads in its VM behind a teardown, breadcrumb and deadline. Each
  re-creates its owners once.
- The quit layout applies on a user Quit only, never on a reload, a logoff or
  a signal, on the three OSes.
- Linux SIGTERM and logout run the same shutdown coordinator; metrics, timers
  and the input capture gate acknowledge before the keyboard stops.
- Wake: Windows re-arms the updater and keystats on power and session
  messages, macOS has wake watchers for the updater, gestures, the Karabiner
  remap and keystats, Linux detects a wake from a wall-clock gap and
  re-enumerates devices through the evdev resynchronisation and hotplug.
- A key-up lost under a locked screen: Windows bounds synthetic modifier holds
  at 5 s, macOS leaves tap-holds to Karabiner, the Linux grab sees every edge
  and an emergency stop releases every key.

## Left

- The degraded tray Quit (the tray adapter failed to load) still ends the
  daemon without the user Quit owner; it keeps the watcher report.
- Native receiving (a real systemd user session, a real resume) is
  unqualified.
