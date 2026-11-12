# Linux install area and configuration cleanup

Audited source: `709fdfa5` (`claude/ergopti-todo-parity-b`, on `dev`).
Date: November 12, 2026.

## Scope

The census area `install` on Linux (13 changed members), `install.sh`,
`uninstall.sh` and the configuration cleanup page (`ui/config_cleanup` on the
three OSes). The download and network steps belong to the other parity track
and were not read. Windows (`windows/ui/config_cleanup/init.ahk`, its
installer) is the read-only reference where a counterpart exists; most of this
area is Linux packaging with no Windows equivalent.

## Fixed (Linux)

| Id      | Sequence                                                                        | Before                                                                                                                                     | Regression                                           |
| ------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| LIN-001 | Enable start at login from a checkout (SAD-1), then install the standalone copy | The checkout's entry took `ergopti-hotstrings.desktop`, which `install.sh` refuses as a foreign startup it does not own: the install stops | `login-source-run` (the installer's name stays free) |

LIN-001 came from the SAD-1 change on this branch before it reached a
release: the checkout now writes `ergopti-source.desktop`.

## Checked and kept

- Startup ownership: the installer, the startup helper and `uninstall.sh`
  compare an entry's command through one escaping owner
  (`install/desktop_entry.sh`); a foreign or linked entry or unit is never
  rewritten or removed, and the standalone removal follows its content
  receipt, the autostart entry included.
- The configuration cleanup runs one shared session on macOS and Linux
  (`_shared/lua/config_cleanup_session.lua`), bound to the page's epoch;
  Windows ports the same session (`ConfigCleanupSession`).

## Left

- A checkout's startup entry stays after the checkout is deleted (a source
  run has no uninstaller); the next Ergopti run from a checkout reports it as
  stale and rewrites it on enable.
- The download and network steps of `install.sh` (the other track's).
