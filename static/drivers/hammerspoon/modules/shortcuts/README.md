# shortcuts

## Purpose

Orchestrates the shortcuts subsystem. Groups standard text/system utility shortcuts (`bindings.lua`), keyboard-layer shortcuts (`keyboard_shortcuts.lua`), and script lifecycle controls — pause, reload, quit — (`script_control.lua`) behind a single unified API surface for the UI menu.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Registering global hotkeys for all shortcut bindings |
| `Clipboard` | Copy/paste utility shortcuts wired through `bindings.lua` |
| `ProcessLifecycle` | Script reload and quit actions in `script_control.lua` |

## Domain module (`_shared/domain/`)

No domain spec directly consumed. The module is purely driver-side and exposes its own `M.DEFAULT_STATE` as the canonical source for shortcut defaults.

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.start()` | Register all active hotkeys |
| `M.stop()` | Unregister all hotkeys |
| `M.set_enabled(group, value)` | Enable or disable a shortcut group at runtime |
| `M.get_chatgpt_url()` | Return the currently configured ChatGPT URL |

## Init pattern

```lua
local Shortcuts = require("modules.shortcuts")
Shortcuts.init(shared_state)
Shortcuts.start()
```

`M.DEFAULT_STATE` is the canonical source for default shortcut states and the ChatGPT URL. Script-control bindings (`return_key`, `backspace`, `escape`) map to named actions (`script_pause_toggle`, `script_reload`, `script_quit`) so the UI can rebind them without touching key-registration logic.
