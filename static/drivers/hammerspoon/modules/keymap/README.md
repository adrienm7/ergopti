# keymap

## Purpose

Core engine for Ergopti+. Runs the OS-level `eventtap` loop that intercepts every keystroke in real time, maintains the typing buffer, measures inter-key delays, and routes each event to the Registry, LLM Bridge, and Expander. This module is the single source of truth for all keymap-wide defaults.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Raw keystroke event tap (intercept + suppress) |
| `TextSender` | Injects expanded text back into the OS |
| `TooltipRenderer` | Displays LLM prediction suggestions |
| `TimerScheduler` | Debounce timers for LLM calls and inactivity detection |

## Domain module (`_shared/domain/`)

- `HotstringMatcher.spec.js` — the Registry implements this contract for trigger lookup
- `Expander.spec.js` — the Expander sub-module implements this contract
- `Registry.spec.js` — the Registry sub-module implements this contract

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize the module with the shared core state table |
| `M.start()` | Arm the eventtap and begin intercepting keystrokes |
| `M.stop()` | Disarm the eventtap |
| `M.set_delay(group, seconds)` | Update the per-group expansion delay threshold at runtime |
| `M.is_running()` | Returns `true` if the eventtap is currently active |

## Init pattern

```lua
local Keymap = require("modules.keymap")
Keymap.init(shared_state)   -- shared_state is the CoreState table
Keymap.start()
```

`M.DEFAULT_STATE` and `M.DELAYS_DEFAULT` are the canonical source for all keymap defaults; menu modules must read from them rather than re-declaring values.
