<!-- docs/design/linux-number-row-runtime.md -->

# Linux number-row values at runtime

Status (2026-10-30): applied on Linux by rebuilding the layout. Linux reads
`layout.direct_access_digits` and `layout.number_row_reorder_edges` from
`config.toml`, converts the installed `.keylayout` again with them and loads the
result into the running session, on X11 and on GNOME or KDE Wayland. macOS still
stores them without applying them. The whole design, for the three OS, is
`docs/design/layout-option-emulation.md`; this note records the Linux choices.

## How each driver treats the two settings

| Driver  | Number-row ordering (`direct_access_digits`)                                                                                                                                                                   | Edge keys (`number_row_reorder_edges`) |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Windows | Applied. The driver emulates the layout, and `#HotIf NumberRowEffectiveMode()` hotkeys retype the ten digit keys (`modules/keymap/layout.ahk`, `layout/digit_row_bindings.ahk`, `layout/number_row_send.ahk`). | Applied with the ordering.             |
| macOS   | Not applied. The layout is installed as a system input source and the system types the row. The menu row is read-only: `number_row_policy.native_rows` with `platform_reason.number_row_override_unsupported`. | Not applied, same reason.              |
| Linux   | Applied by the layout itself: the converter (`_shared/lua/layouts/xkb_converter.lua`) swaps the cells while converting, and the session loads the new XKB layout. No key is retyped by the hook.               | Applied with the ordering, same path.  |

## Why the layout and not the hook

The keyboard hook could have retyped ten keys of the system layout on every
press (the dormant owner of d70c2d9aa3, `_number_row` in
`adapters/keyboard_hook.lua`). That is a partial emulation, which the Linux
design avoids, and its backend was never qualified on a desktop. Rebuilding the
layout keeps one rule (`layout.number_row_policy`, the same as Windows and the
composer), keeps Ctrl, AltGr and dead keys exactly as the layout defines them, and
needs no hook restart: the grab, the hotstring buffer, the tap-hold engine and
CapsWord are untouched. The dormant hook owner stays unreachable (nothing passes
`numberRowMode`).

## The live path

- `modules/keymap/number_row_live.lua` stores a choice, then asks the layout
  manager to apply the stored values; a choice the session cannot apply stays
  stored with its reason (`no_source_layout`, `session_unsupported`).
- `modules/keymap/layout_registry.lua` (`apply_rows`, `live_path`) converts the
  installed copy with the options and hands it to the user installer:
  - X11: `install --allow-xorg` then `apply-x11`, which compiles the layout from
    the user tree into the running server;
  - GNOME or KDE on Wayland: `apply-wayland`, which alternates between the
    layout's id and `<id>_live` so the compositor sees a new id, moves the
    desktop setting with a read-back and puts it back on any refusal;
  - any other session: refused before anything is written.
- Both installer commands succeed only once the session's keymap, read back with
  `xkbcomp -xkb $DISPLAY -` (the server, or XWayland which receives the
  compositor's), holds the installed cells on the thirteen moved keys.
- `infra/keyboard_layout_scope.lua`: the global restore and clear write the rows,
  then the participant settles only on the layout manager's answer. An inert
  choice is acknowledged with its reason; a load the session refuses reverts the
  rows; a reload refused during a rollback stays owed. `infra/global_scope.lua`
  takes a continuation for that reason.

## What needs a real desktop

`tests/hardware/run_layout_rows_live.lua` proves the X11 chain on Xvfb and the
installer's Wayland sequence is tested against a stand-in compositor. Whether
mutter and KWin compile a layout found only in `~/.config/xkb` and recompile when
the setting moves to the other slot (W1 to W4 of the design note) needs a GNOME
and a KDE session; so does typing on a physical keyboard.
