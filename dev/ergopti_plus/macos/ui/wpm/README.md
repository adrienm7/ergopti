# wpm (Hammerspoon)

## Purpose

Floating `hs.canvas` widget showing real-time typing speed (WPM net). Renders a compact pill with an optional trailing line graph of recent WPM history. Color-codes each bar by keystroke origin (manual, hotstring, autocorrection, AI prediction). A separate `wpm_menubar.lua` sub-module provides an always-visible WPM counter in the macOS menu bar as an `hs.menubar` item. Visual constants come from `_shared/modules/wpm_widget/constants.toml`.

## Key files

| File              | Description                                                     |
| ----------------- | --------------------------------------------------------------- |
| `init.lua`        | `M.init(state)` / `M.start()` / `M.stop()` lifecycle            |
| `wpm_widget.lua`  | Canvas drawing, tick handler, colour and geometry logic           |
| `wpm_menubar.lua` | Menu bar WPM item (always visible, no canvas window)             |

## Shared constants

`_shared/modules/wpm_widget/constants.toml` — colours and geometry; mirrored in both drivers.
