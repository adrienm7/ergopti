# Layout manager and layout editor host

Audited source: `49d49988` (`claude/ergopti-todo-parity-audit`), fixed on top
of `d0bc45f1` (`dev`). Date: November 12, 2026.

## Scope

The layout manager window's host on macOS and Linux (the shared
`_shared/lua/layouts/manager_bridge.lua` and `source_store.lua`, the macOS
`ui/layout_manager` host and menu bindings, the Linux
`ui/layout_manager/bridge.lua`) against the Windows reference
(`windows/ui/layout_manager/init.ahk`, `composer.ahk`, `source_store.ahk`).
Checked and kept: the two action allowlists match (16 actions), `select`
differs by design, `builtin` is empty on macOS and Linux, and the stale
editor flag and the pending page promise after a silent refusal behave the
same on all three hosts.

## Fixed

| Id      | OS           | Sequence                                                  | Windows                                                        | Before                                                          | Regression                     |
| ------- | ------------ | --------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------ |
| LMH-001 | macOS, Linux | Uninstall or remove the emulated layout                   | `_LayMgrWeb_After` reloads (and clears the choice, see below)  | The emulation kept typing the removed layout from memory        | `lmh-001-002-emulation-reload` |
| LMH-002 | macOS, Linux | Update, reinstall or re-save the emulated layout          | `_LayMgrWeb_After`, `_LayoutComposer_OnInstalled` reload       | The old map stayed until the next reload                        | `lmh-001-002-emulation-reload` |
| LMH-003 | macOS, Linux | Install, uninstall or select from the window while paused | `_LayMgrWeb_OnWebMessage` admits only `ready` while suspended  | Every command ran on a paused driver                            | `lmh-003-paused`               |
| LMH-004 | macOS, Linux | Install or uninstall a layout that ships hotstrings       | `_LayMgrWeb_After` reloads the script                          | Its hotstrings loaded, or stopped, only at the next reload      | `lmh-004-extension-reload`     |
| LMH-005 | Linux        | « Emulate without installing » in the layout editor       | —                                                              | The tray kept the previous choice ticked until its next rebuild | `lmh-005-emulate-tray`         |
| LMH-006 | macOS, Linux | Reopen the editor's last source                           | `SourceStore_Open` reads through `FSReadUtf8ExactBounded`      | Whole-file read before the size check, no UTF-8 check           | `lmh-006-bounded-reopen`       |
| LMH-007 | shared Lua   | (code health) the store's export name and failure codes   | `SourceStore_Settings` reads them from `layouts/defaults.json` | `layers.toml` and both codes hard-coded                         | `lmh-007-store-settings`       |

LMH-001, decided by the maintainer on 2026-11-12: the stored
`[layout] emulated_layout` is kept on uninstall or remove. The menu row stays
named, ticked and greyed (« — non appliqué »), the emulation stops and
reloads, and it resumes by itself when the layout is installed again. Windows
keeps it too (2026-11-12): its boot no longer downloads a missing layout, and
the menu choice installs one before selecting it.

LMH-004 asks the host for a full driver reload, because the extension
catalogue is read once per boot; that reload also restarts the emulation, so
the extension case replaces the emulation reload. On macOS the layout manager
receives the reload, the pause query and the emulation reload from the menu,
so it never loads the shortcuts stack itself.

## Open

None in this module. Native receiving (a real install, uninstall and reload
on a Mac and a Linux session) is unqualified.
