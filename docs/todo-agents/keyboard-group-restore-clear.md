<!-- docs/todo-agents/keyboard-group-restore-clear.md -->

# Shortcuts: restore and clear at the top of each modifier group

## Request

Maintainer, 2026-10-22: in the Shortcuts menu, the per-modifier submenus (Win, Ctrl, Alt...)
list the default shortcuts and the user's actions with a « + » row to add one, but have no row
to put the group back to the recommended configuration and no row to remove everything. Add
both at the top of each submenu, on the three systems.

## Done

One manifest section, `keyboard_group_scope_controls` (`_shared/modules/features/manifest.toml`),
declares the first group of every modifier submenu: `scope_restore`
(`common.restore_recommended`, « ↺ Restaurer les valeurs conseillées »), `scope_clear`
(`common.clear_to_system`, « ✕ Tout effacer (comportement du système) »), then a separator. No
new locale key: the two shared keys are the ones every other menu reads
(`project-restore-and-clear-read-two-shared-keys`). Like every scope row, both apply at once,
without a question; the owner backs up first.

Behaviour, the same on the three drivers: the Shortcuts scope narrowed to the group's slots and
the action parameters of the bindings they dispatch under.

- Restore: every shipped slot of the group takes its `recommended` action (a value equal to the
  default is a deletion) and the slots the user added are removed. Other groups, the tap keys,
  the script chords and the key combinations are untouched.
- Clear: every slot of the group is removed (each one's default is « none »), with its parameters.

| OS      | Groups                                   | Rows built by                                                            | Scope owner                                                                                                    |
| ------- | ---------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Windows | Alt, Ctrl, Ctrl+Shift, Win               | `KeyboardSlotRows` (`windows/infra/config_io.ahk`)                       | `KeyboardSlotGroupApplyScope`: the Shortcuts plan filtered by `KeyboardSlotGroupOf` (the longest-prefix rule)  |
| macOS   | Option, Ctrl, Ctrl+Shift, Cmd, Cmd+Shift | `keyboard_group_frame` include (`macos/ui/menu/menu_keyboard_slots.lua`) | `apply_keyboard_group_scope` (`macos/ui/menu/init.lua`) with `shortcuts_scope.keyboard_group_rows` as `select` |
| Linux   | Ctrl, Ctrl+Shift, Alt, Super             | `keyboard_slots` provider (`linux/ui/menu/menu_builder.lua`)             | `infra/shortcuts_scope.lua` with `only = "keyboard_group:<prefix>"`                                            |

The contextual group (the magic-key editor slot) has no modifier and no « + » row, so it gets
neither row. The « + » row stays where it was, at the bottom of each Windows and macOS group;
Linux lists every slot of the catalogue and has no « + » row.

The Gestures menu has no per-group submenus of this kind (its restore and clear already open the
menu), so nothing changed there.

## Tests

- Windows: `tests/unit/modules/shortcuts/test_keyboard_slot_group_scope.ahk` (rows and real scope
  over a private config file); `test_shortcuts_menu_groups_unique.ahk` and
  `test_keyboard_slot_win_space.ahk` now skip the separator row.
- macOS: `tests/unit/ui/menu/shortcuts/test_keyboard_group_scope.lua` (real scope owner and real
  Shortcuts submenu); `test_configured_shortcut_labels.lua` reads the first slot row after the
  scope rows.
- Linux: `tests/unit/infra/scope/test_shortcuts_scope_keyboard_group.lua` (real scope owner,
  refused narrowings, real tray clicks with no question).
- JS: `test-menu-first-group.cjs` checks the fragment uncollapsed on every platform;
  `test-menu-reset-terminology.cjs` expects one restore and one clear row in it.

## Left

- Manual check on each OS: open Shortcuts > a modifier group, click « Tout effacer », then
  « Restaurer les valeurs conseillées », and check the group's rows (Windows reloads the driver).
