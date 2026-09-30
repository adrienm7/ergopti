# shortcuts

## Purpose

Orchestrates the shortcuts subsystem. Groups standard text/system utility shortcuts (`bindings.lua`), keyboard-layer shortcuts (`keyboard_shortcuts.lua`), and script lifecycle controls — pause, reload, quit — (`script_control.lua`) behind a single unified API surface for the UI menu.

## Ports used (`_shared/core/ports/`)

| Port               | Usage                                                     |
| ------------------ | --------------------------------------------------------- |
| `KeyboardHook`     | Registering global hotkeys for all shortcut bindings      |
| `Clipboard`        | Copy/paste utility shortcuts wired through `bindings.lua` |
| `ProcessLifecycle` | Script reload and quit actions in `script_control.lua`    |

## Domain module (`_shared/core/domain/`)

No domain spec directly consumed. The module is purely driver-side and exposes its own `M.DEFAULT_STATE` as the canonical source for shortcut defaults.

## Public API

| Function                      | Description                                   |
| ----------------------------- | --------------------------------------------- |
| `M.init(state)`               | Initialize with the shared core state table   |
| `M.start()`                   | Register all active hotkeys                   |
| `M.stop()`                    | Unregister all hotkeys                        |
| `M.set_enabled(group, value)` | Enable or disable a shortcut group at runtime |
| `M.get_chatgpt_url()`         | Return the currently configured ChatGPT URL   |

## Init pattern

```lua
local Shortcuts = require("modules.shortcuts")
Shortcuts.init(shared_state)
Shortcuts.start()
```

`M.DEFAULT_STATE` is the canonical source for default shortcut states and the ChatGPT URL. The script chords are the four slots every driver shares (`script_altgr_enter`, `script_altgr_backspace`, `script_altgr_delete`, `script_altgr_escape`, right Option with Return, Backspace, Delete or Escape, listed by `_shared/modules/actions/script_chords.json`). They start with their preset actions (`script_pause_toggle`, `script_reload`, `open_personal_shortcuts`, `script_quit`), and the UI can rebind them without touching key-registration logic. Karabiner turns a chord into its sentinel only while its slot runs an action (`platform/remap/script_chord_rules.lua`).
