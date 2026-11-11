# Keyboard shortcuts and text actions: Windows, macOS, Linux and shared

Audited source: `199aa5ad` (`claude/ergopti-todo-parity-audit`, merged with
`dev`). Date: November 11, 2026.

## Source census reconciliation

`tools/audit/source-areas.py --ref HEAD` gives 377 areas against the 363 of
the last pinned census (`2026-11-05-native-ui/source-areas.json`). Of the
changed areas, 47 belong to modules already campaigned since (tap-holds,
hotstrings, gestures, metrics, AI, input/layout). Among the others, the
behavioural module with the most changed members across the drivers is the
shortcuts module (`modules/shortcuts` on Linux and macOS, 12 changed files
each, 3 on Windows, plus shared `lua/shortcuts` and `lua/actions`); this
campaign takes it. Next candidate: the updater (shared `lua/updater` and
`modules/updater` on each OS). The infrastructure, adapter, menu and launcher
areas changed too and still need review before a register row can claim
them.

Windows (`windows/modules/keymap/layout/accented_shortcuts.ahk`,
`windows/infra/config_io.ahk`, `windows/adapters/hotkey_registrar.ahk`) is
the read-only reference. Candidates were replayed through the real Linux
modules under LuaJIT; no evdev/uinput, Hammerspoon or AHK was executed.

## Fixed (Linux)

| Id      | Sequence                                                                                | Windows                                                                                    | Linux before                                                | Regression                 |
| ------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------- | -------------------------- |
| SCL-001 | AZERTY, emulation off, `e_grave` on: hold Ctrl and è                                    | `^SCxxx` hotkey (`accented_shortcuts.ahk` `_AccentedShortcutEmit`): Ctrl+Z on every repeat | The hook swallowed every repeat: one Ctrl+Z                 | `accented-shortcut-repeat` |
| SCL-002 | Ergopti emulated over a system layout with é, `e_acute` on: Ctrl and the system's é key | `AccentedShortcuts_Register` only without the Ergopti emulation (`layout.ahk:883-888`)     | Ctrl+C before the emulation; a slot on that chord never ran | `accented-under-emulation` |

## Decisions pending (behaviour left unchanged)

- **SCD-1, script actions on keyboard slots while paused.** A keyboard slot
  bound to a `script_*` action (Reload, Pause) stays live on Linux while the
  driver is paused, in dry-run or with Shortcuts off (`consume_bound_chord`
  `only_script`, a `script_` prefix test in `keyboard_shortcuts.match`); the
  comment calls it deliberate. Windows binds no slot with Shortcuts off and
  suspends every slot hotkey, only its AltGr script chords staying live
  (`SCRIPT_SHORTCUT_SUSPEND_ALLOWED`); macOS pauses every slot. The prefix
  test also admits `script_save_reload` and refuses `open_personal_shortcuts`,
  unlike the shared `paused_actions` list (`script_chords.json`).
  Recommendation: align Linux with Windows, or read the shared list.
- **SCD-2, accented shortcuts with two non-Shift modifiers.** Linux turns
  Ctrl+Alt+é into Ctrl+Alt+C; Windows registers only `^ ^+ ! !+ # #+`, since
  Ctrl+Alt is AltGr there. It rides on ILD-1 (the logical key for chords of
  two modifiers, decided for the layout emulation).
- **SCD-3, a Ctrl slot under AltGr.** A `ctrl_x` slot fires on Linux for
  Ctrl+AltGr+x (`keyboard_shortcuts.match` leaves AltGr out); Windows' `^x`
  does not fire, AltGr adding Alt. It rides on ILD-2 (Ctrl+AltGr).

## Refuted

Text case transforms (all three drivers replay the shared text-case corpus);
tap keys (a plain tap only, repeats swallowed, gates re-read at delivery);
AltGr script chords (the shared `paused_actions` list matches Windows);
accented shortcuts on the digit row, under AltGr, on a letter switched off or
an invalid configuration; modifier custody of a pressed chord; AI-blocked
slots, checked at the press and at delivery. macOS offers no accented
shortcuts by manifest decision (`accented_shortcuts_need_a_layout_file_on_macos`).

## Remaining work

Not reviewed: macOS `bindings.lua` and the shared slot-role modifier mapping
in depth, Linux `key_combinations.lua`, a Windows keyboard slot bound to a
script action through the physical Win broker. Native receiving unqualified.
