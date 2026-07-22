# tooltip (AHK)

## Purpose

Floating, frameless overlay for in-context previews. Two distinct tooltip surfaces share this module:

1. **Hotstring tooltip** (`tooltip_hotstring.ahk`) — caret-anchored preview of the expansion that will fire when the current trigger is completed. Per-group tinted background (colours from `_shared/modules/tooltip/constants.toml`). Click-through (`WS_EX_TRANSPARENT`).
2. **LLM tooltip** (`tooltip_llm.ahk`) — multi-slot streaming prediction display that shows the current LLM generation in real time. Accepts an array of text slots; renders them stacked with per-slot styling.

## Key files

| File                  | Description                                              |
| --------------------- | -------------------------------------------------------- |
| `init.ahk`            | Unified `Tooltip_Show` / `Tooltip_Hide` façade           |
| `tooltip_hotstring.ahk`| Hotstring preview tooltip implementation                 |
| `tooltip_llm.ahk`     | LLM streaming prediction tooltip implementation          |

## Shared constants

`_shared/modules/tooltip/constants.toml` — colours and geometry; `_shared/modules/tooltip/tint.js` — tinting parity gate.
