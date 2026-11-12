# Gestures: a physical click and the click hold

Audited source: `4f3f51e4` (`claude/ergopti-todo-parity-audit`), against the
[gestures campaign](../2026-11-11-gestures/report.md). Date: November 12, 2026.

## Scope

The campaign's open Linux row: a physical mouse click did not release a
gesture's click hold. The campaign found no pointer button observer. Since
then the keyboard hook opens a read-only descriptor on each pointer and
reports every press (`onClick`), so the row can be closed. The campaign's
fixes, GSD-2, GSD-3, the pending GSD-1 and its refuted list are not repeated.

Checked and kept:

- **The hold's own press:** the click hold presses its button through
  `xdotool` (XTest), and the pointer selection drops synthetic devices
  (`device_finder.select_pointers`). The daemon never sees its own press, so
  the release cannot answer it.

## Fixed

| Id      | OS    | Sequence                                                                         | Windows                                                            | Before                                             | Regression                    |
| ------- | ----- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------- | ----------------------------- |
| GSX-001 | Linux | A gesture holds the left button (`left_click_toggle`), then the mouse is clicked | `click.ahk` `mouse_ldown` and `mouse_rdown` subscribers release it | The synthetic button stayed down until a key press | `gsx-001-click-releases-hold` |

`on_click` in `ergopti_hotstrings.lua` releases the hold for a pointer button
(`InputEvent.is_pointer_button`). A finger landing on the touchpad
(`BTN_TOUCH`, `BTN_TOOL_*`) also reaches `onClick`, but it is how the held
button drags, so it keeps the hold. The regression compiles Main's own
`on_click`.

## Open

GSD-1 (macOS live x1 fires) waits for the maintainer. Not reviewed in depth:
Linux `background_commands`, `pointer_spotlight`, `pointer_warp` and
`system_actions`; macOS `app_switch`, `apple_shortcut_action`, `conflicts` and
`frame_clock`. Native receiving is unqualified.
