# karabiner

## Purpose

Bridge between Hammerspoon and Karabiner-Elements. Manages the full lifecycle: reading and writing `config_karabiner.toml`, generating `karabiner.json` entirely in Lua from in-memory state, deploying it to the Karabiner-Elements config directory, and watching for KE process events. Loads action and modifier-combo definitions from `modules/karabiner/data/` so the menu and the generator are always in sync.

## Ports used (`shared/ports/`)

| Port | Usage |
|---|---|
| `FileSystem` | Reading/writing `config_karabiner.toml` and deploying `karabiner.json` |
| `ProcessLifecycle` | Detecting whether Karabiner-Elements is running and reloading its config |
| `Storage` | Persisting the user config between sessions |

## Domain module (`shared/domain/`)

No direct domain spec. Uses two driver-local JSON data files (Karabiner-Elements is macOS-exclusive, so these files live in the driver rather than in `shared/`):
- `modules/karabiner/data/actions.json` — canonical action dictionary
- `modules/karabiner/data/mod_combos.json` — all available two-modifier combos (tap / hold / chord slots)

Optionally consumes `modules.keylogger.kc_bridge` for keycode translation when available.

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.generate_and_deploy()` | Build `karabiner.json` from current config and copy it to KE's config dir |
| `M.reset_to_defaults()` | Wipe user config and recompute from `defaults.lua` |
| `M.set_action(combo, slot, action)` | Update a single modifier-combo binding |
| `M.get_config()` | Return the full in-memory config table |

## Init pattern

```lua
local Karabiner = require("modules.karabiner")
Karabiner.init(shared_state)
-- Menu calls M.generate_and_deploy() after each user change
```

`config_karabiner.toml` is the single runtime truth after first launch. Defaults are never recomputed at runtime except when the user explicitly resets. The `_DATA_DIR` path is resolved once at load time relative to this `init.lua` to survive symlinking and varied deployment paths.
