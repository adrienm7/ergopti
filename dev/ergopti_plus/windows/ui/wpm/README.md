# wpm (AHK)

## Purpose

Always-on-top floating widget showing real-time typing speed (WPM). Supports two display modes: a compact pill (default) and a GDI+ sparkline graph (toggleable from the menu). Color-codes each second's WPM bar by keystroke origin (manual, hotstring, autocorrection, AI prediction). Draggable with persistent position across sessions. Visual constants (colours, geometry) come from `_shared/modules/wpm_widget/constants.toml`.

## Key files

| File              | Description                                                     |
| ----------------- | --------------------------------------------------------------- |
| `init.ahk`        | Module entry: `WPMWidget_Start()` / `WPMWidget_Stop()` lifecycle |
| `wpm_widget.ahk`  | GDI+ drawing, tick handler, colour logic                         |
| `wpm_menubar.ahk` | Compact, always-visible WPM label in the tray area (non-GDI+)   |

## Shared constants

`_shared/modules/wpm_widget/constants.toml` — colours and geometry; mirrored in both drivers.
