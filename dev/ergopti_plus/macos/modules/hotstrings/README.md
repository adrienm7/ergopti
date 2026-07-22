# hotstrings

## Purpose

Resolves the effective expansion delay and tooltip colour for each hotstring group and section by merging three priority layers: user overrides read from the personal TOML, section-level `[_meta]` keys from the hotstring TOML files, and global defaults from `_shared/modules/hotstrings/defaults.toml`. Exposes a single `get_config(group, section)` accessor consumed by the keymap expander and the config-window UI.

## Ports used (`_shared/core/ports/`)

| Port           | Usage                                                            |
| -------------- | ---------------------------------------------------------------- |
| `FileSystem`   | Reading the personal overrides TOML and the shared defaults TOML |
| `TomlCodec`    | Parsing the merged config tables                                  |

## Shared data (`_shared/modules/hotstrings/`)

`defaults.toml` — canonical defaults for every config key; `hotstrings_config.lua` must never re-declare a default locally (§5.4).

## Public API

| Function                   | Description                                                       |
| -------------------------- | ----------------------------------------------------------------- |
| `M.init(state)`            | Initialize with shared state; reads and merges config layers       |
| `M.get_config(group, sec)` | Returns `{delay_ms, color}` for the given group / section path    |
| `M.reload()`               | Re-reads all layers (called after the config window saves)        |

## Init pattern

```lua
local Hotstrings = require("modules.hotstrings")
Hotstrings.init(shared_state)
```
