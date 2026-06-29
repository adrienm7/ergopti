# gestures (AHK)

## Purpose

Maps user-configurable gesture slots (3-finger tap, 4-finger tap, left/right/up/down swipe) to actions. Each slot holds one action key read from the features manifest; a user-facing picker (`ui/action_picker/`) lets the user reassign slots without reloading. Also provides three always-available gestures: screenshot (GDI+ region capture), paste-plain (strips rich formatting), and left-button click-lock for drag gestures.

## Ports used (`_shared/core/ports/`)

| Port              | Usage                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| `KeyboardHook`    | `#HotIf`-gated hotkeys that fire on gesture-synthesised key sequences    |
| `ClipboardAccess` | Read clipboard on paste-plain; write screenshot data path                |
| `FileSystem`      | Temp file for screenshot capture via Snipping Tool / GDI+                |
| `TimerScheduler`  | Debounce timer for window-cycle focus events                              |
| `WindowInfo`      | `WinGetList` / `WinActivate` for the window-cycle action                  |

## Shared data (`_shared/modules/gestures/`)

`actions.toml` — catalogue of all assignable action identifiers, used by both drivers to populate the picker list.

## Public API

| File              | Description                                              |
| ----------------- | -------------------------------------------------------- |
| `init.ahk`        | Module entry: reads slot assignments, registers hotkeys  |
| `config.ahk`      | `GestureGetAction(slot)` accessor; slot-name constants   |
| `click.ahk`       | Left-button click-lock (long-press drag simulation)       |
| `screenshots.ahk` | GDI+ region capture and clipboard copy                   |
| `window_cycle.ahk`| Alt-Tab-style window cycle guarded by HWND fence          |

## Init pattern

```ahk
; Included by ErgoptiPlus.ahk
#Include modules/gestures/init.ahk
```

Slot assignments are read from `Features["gestures"][slot]` at startup. Changing a slot in the menu reloads the driver to re-register the hotkeys.
