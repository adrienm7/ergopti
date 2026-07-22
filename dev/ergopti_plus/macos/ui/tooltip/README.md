# tooltip (Hammerspoon)

## Purpose

Central tooltip façade exposing a unified API for all overlay previews. Delegates to two sub-modules based on the caller:

1. **`tooltip_hotstring.lua`** — per-group tinted hotstring expansion preview, caret-anchored.
2. **`tooltip_llm.lua`** — multi-slot streaming LLM prediction display; accepts a slot array and updates in real time as tokens stream in.

## Key files

| File                   | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `init.lua`             | `M.show(kind, data)` / `M.hide()` unified façade                    |
| `tooltip_hotstring.lua`| Per-group tinted hotstring preview (hs.canvas)                      |
| `tooltip_llm.lua`      | LLM streaming prediction overlay (hs.canvas, multi-slot)            |

## Shared constants

`_shared/modules/tooltip/constants.toml` — colours and geometry; `_shared/modules/tooltip/tint.js` — parity gate with Windows.
