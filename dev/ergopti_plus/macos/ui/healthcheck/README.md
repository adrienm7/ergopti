# healthcheck (Hammerspoon)

## Purpose

Runtime diagnostic probe accessible from the Debug menu. Snapshots the Hammerspoon state (module init flags, eventtap status, SQLite health, OS information, recent log entries) and presents it in a structured WKWebView report. Also serviced via `hs.ipc` so the report can be queried from the terminal without opening a window.

## Key files

| File        | Description                                                               |
| ----------- | ------------------------------------------------------------------------- |
| `init.lua`  | `M.show()` — collects diagnostics and opens the window                     |
| `core.lua`  | Diagnostic collection logic (state gathering, formatting)                  |
| `helpers.lua`| Module-status helpers used by `core.lua`                                  |

## Usage

```lua
local Healthcheck = require("ui.healthcheck")
Healthcheck.show()  -- called from the Debug menu item
```
