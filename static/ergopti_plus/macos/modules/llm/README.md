# llm

## Purpose

Coordinates communication with local (Ollama, MLX) and remote LLM backends. Manages backend detection, profile selection, streaming response parsing, warmup scheduling, and exposes a unified prediction API to `keymap/llm_bridge.lua`. Loads cross-platform defaults from `_shared/llm/defaults.json` so the same tuning applies on every driver.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `HttpClient` | REST calls to Ollama/MLX APIs and remote endpoints |
| `FileSystem` | Reading `_shared/llm/defaults.json` and shell-script dependency installers |
| `TimerScheduler` | Debounce timer between keystrokes and the actual LLM request |
| `TooltipRenderer` | Streaming token display during prediction |
| `ProcessLifecycle` | Launching and watching the Ollama/MLX background process |

## Domain module (`_shared/domain/`)

- `PromptBuilder.js` — `prompt_builder.lua` implements this contract
- `TokenParser.js` — `parser.lua` implements token stream parsing
- `ProfileSelector.js` — `profiles.lua` implements profile management

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.request(context, callback)` | Fire an async prediction request for the given text context |
| `M.cancel()` | Cancel any in-flight prediction request |
| `M.set_profile(name)` | Switch the active prompt profile at runtime |
| `M.get_backend_status()` | Returns current backend name and availability flag |

## Init pattern

```lua
local LLM = require("modules.llm")
LLM.init(shared_state)
-- keymap/llm_bridge.lua calls LLM.request() on every keystroke debounce
```

Cross-platform defaults are loaded from `_shared/llm/defaults.json` at init time and merged into `M.DEFAULT_STATE`. HS-specific keys (model names, `llm_debounce` in seconds) are not in the JSON and keep their hardcoded base values.
