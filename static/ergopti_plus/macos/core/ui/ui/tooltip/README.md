# tooltip (Hammerspoon)

## Purpose

Central tooltip façade exposing a unified API for all overlay previews. Delegates to two sub-modules based on the caller:

1. **`hotstring.lua`** — per-group tinted hotstring expansion preview, caret-anchored.
2. **`llm.lua`** — multi-slot streaming LLM prediction display; accepts a slot array and updates in real time as tokens stream in.

## Key files

| File            | Description                                                                     |
| --------------- | ------------------------------------------------------------------------------- |
| `init.lua`      | `M.show(kind, data)` / `M.hide()` unified façade                                |
| `hotstring.lua` | Per-group tinted hotstring preview (hs.canvas)                                  |
| `llm.lua`       | LLM streaming prediction overlay (hs.canvas, multi-slot)                        |
| `renderer.lua`  | Canvas creation and screen coordinate resolution                                |
| `config.lua`    | Loader of the shared visual constants (fails fast on a missing key)             |
| `dequeue.lua`   | Lua port of `_shared/core/ui/data/tooltip/dequeue.js`: stacked row expiry logic |

The Linux driver renders the same tooltips in `linux/core/ui/ui/tooltip/` (`config.lua`
reads the same constants file, `preview.lua` decides what the preview shows,
`llm.lua` presents LLM suggestions); there is no separate hotstring renderer
module there.

## Shared constants

`_shared/core/ui/data/tooltip/constants.toml` — colours and geometry; `_shared/core/ui/data/tooltip/tint.js` — parity gate with Windows.
