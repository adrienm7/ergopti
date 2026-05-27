# gestures

## Purpose

Captures raw multi-touch trackpad input via the undocumented macOS `touchdevice` API. Maps multi-finger taps and directional swipes to configurable system actions (app switching, scroll toggling, workspace navigation, etc.). Handles cold-start dormancy (the kernel gates the device until the first physical touch) through an adaptive probe loop.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `TimerScheduler` | Adaptive wakeup probe loop and gesture debounce timers |
| `Notifier` | User-facing feedback for gesture registration failures |

The raw touch frame callback arrives via `vendor.hs_asm.undocumented.touchdevice` (loaded with `pcall`; gracefully absent when unavailable).

## Domain module (`_shared/domain/`)

- `GestureRecognizer.spec.js` — `engine.lua` implements the finger-count + direction classification contract

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.start()` | Subscribe to the touchdevice frame callback (arms the probe loop if the device is dormant) |
| `M.stop()` | Unsubscribe from the frame callback |
| `M.set_gesture(name, action)` | Bind a named gesture slot to an action key at runtime |
| `M.get_available_actions()` | Return the full list of valid action keys from `actions.lua` |

## Init pattern

```lua
local Gestures = require("modules.gestures")
Gestures.init(shared_state)
Gestures.start()
```

`M.DEFAULT_GESTURES` is the canonical source for default gesture bindings; menu modules must read from it. The `touchdevice` dependency is optional — if absent the module self-disables with a warning rather than crashing.
