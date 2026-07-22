# download_window (Hammerspoon)

## Purpose

Unified progress window for all long-running LLM operations: model downloads (bytes transferred, ETA, rolling log), MLX/Ollama engine installation (step-by-step log, spinner). A single `PRESETS` table derives the window title, accent colour, progress bar style, and display mode from the caller-provided `opts.kind` — no caller-side styling code needed.

## Key files

| File      | Description                                                                        |
| --------- | ---------------------------------------------------------------------------------- |
| `init.lua`| `M.open(opts)` / `M.update(progress)` / `M.close()` — singleton lifecycle          |

## Usage

```lua
local DlWin = require("ui.download_window")
DlWin.open({ kind = "ollama_model", model = "llama3.2", size_bytes = 2_100_000_000 })
-- … during download:
DlWin.update({ bytes_done = n, speed_bps = s, eta_s = t })
DlWin.close()
```
