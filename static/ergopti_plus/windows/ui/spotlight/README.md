# spotlight (AHK)

## Purpose

GDI+ layered-window overlay that highlights the mouse cursor position. Draws a filled yellow circle around the cursor on the active monitor and a red cross-hair on every other monitor. Auto-dismisses after a configurable timeout or on mouse movement. Useful when presenting to an audience or when a remote viewer cannot see the cursor.

## Key files

| File      | Description                                                         |
| --------- | ------------------------------------------------------------------- |
| `init.ahk`| `Spotlight_Toggle()` / `Spotlight_Show()` / `Spotlight_Hide()` API |

## Notes

The overlay is click-through (`WS_EX_TRANSPARENT`) so it does not interfere with normal mouse interaction. Implemented with GDI+ `Graphics` (no external DLLs beyond the AHK-bundled GDI+ wrapper).
