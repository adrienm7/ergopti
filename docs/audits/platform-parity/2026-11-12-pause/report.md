# Pause: configuration stays available (first pass)

Audited source: `claude/ergopti-todo-parity-b`, on `dev`.
Date: November 12, 2026.

## Scope

Maintainer decision EDD-1 (2026-11-12), sharpened the same day into a « real
pause »: while the driver is paused, every configuration and install action
stays available, and everything that acts on typing stays inert. This pass
removes the pause gates on the menus' whole-scope restore and clear and on
opening the physical shortcuts editor, on macOS and Linux. Windows
(`windows/**`) is the read-only reference; its counterpart is in `TODO.md`
« Windows (the PC agent's) ».

## Fixed (macOS and Linux)

| Sequence                                                           | Before                                                                                                                                                      | Regression                                         |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Pause, then open the physical shortcuts editor                     | Linux and macOS menus refused to open it                                                                                                                    | `edd1-paused-writes` (physical editor menu)        |
| Pause, then « restore recommended » or « clear » in a feature menu | Every scope owner refused: Linux script, tap-hold, hotstrings, shortcuts, key combinations; macOS scoped preferences, gestures, layout, metrics, AI restore | `edd1-paused-writes` in each scope suite           |
| Pause, then the Configuration menu's restore or clear              | Linux refused the composition; macOS greyed both rows and stripped their handler                                                                            | global scope suites, shared Configuration contract |
| Pause, then edit an ordered key combination or its delay (Linux)   | The pair owner refused its configuration source while paused                                                                                                | `edd1-paused-writes` (ordered pair, delay)         |

The typing runtime keeps its pause: the Linux pair owner's runtime capture,
action capture and engine admission still require an unpaused driver, which
the paused-custody regression asserts.

## Second pass: tray rows and submenu rows

| Sequence                                                                                  | Before                                                                                                                                       | Regression                                 |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Pause, then open a feature menu from the tray                                             | Both trays greyed every row the manifest marks `greyed_when_paused`; macOS Shortcuts and Gestures and the Linux AI parents greyed themselves | `edd1-paused-writes` in both trays' suites |
| Pause, then use the Configuration menu's « clean unused keys » (macOS)                    | Greyed and stripped of its handler                                                                                                           | shared Configuration contract, macOS suite |
| Pause, then reorder, toggle or bulk-toggle Linux hotstring sections, or open their editor | Greyed and refused                                                                                                                           | Linux hotstrings suites                    |
| Pause, then change the layout switched to on pause or resume                              | Greyed on both drivers                                                                                                                       | layout switching suites                    |
| Pause, then edit a Linux keyboard group or the wrap choices, or restore or clear gestures | Refused                                                                                                                                      | Linux shortcuts and gestures suites        |

`greyed_when_paused` stays in `menu.toml`: only the AHK tray reads it now,
and the Windows agent deletes it with its `A_IsSuspended` gates (choice B,
2026-11-12).

## Left (next pass, listed rather than guessed)

These still refuse or grey while paused. Ungating the menu alone would let a
paused driver act at once instead of « on resume », or the change needs its
source proofs reworked first:

- macOS Shortcuts: the switch, each shortcut's toggle, the slot rows and the
  wrap rows bind or unbind OS hotkeys at once.
- macOS and Linux Gestures switch: it starts the gesture engine at once.
- Linux tap-holds: `tap_hold_manager.capture_configuration_edit` refuses while
  paused; the edit path needs a pause-safe reload first.
- Programmable hotstrings switch (shared policy): enabling loads the user's
  code at once.
- macOS and Linux AI menus: the enable switch, the privacy and trigger rows
  read the pause through shared policies.
- macOS hotstrings submenus (`menu_hotstrings*.lua`): the section, bulk,
  delay and personal rows still grey; `tools/lib/menu-hotstring-language-binding.cjs`
  and `test-menu-manifest.cjs` prove those pause locals structurally and must
  be reworked with them.
- macOS magic key source capture: it listens to a physical key press.
- The audit that every typing feature (layout emulation first) is inert while
  paused, and that a setting changed while paused applies on resume.
- Windows: every `A_IsSuspended` gate is listed in
  [the Windows inventory](windows-inventory.md); none was changed here.
