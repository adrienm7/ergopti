# action_picker (Hammerspoon)

## Purpose

WKWebView-based searchable action chooser for assigning actions to gesture or keyboard-shortcut slots. Loads the shared `_shared/ui/action_picker/` frontend (hierarchical TOC, fold support, search). Caller-agnostic: the caller builds the item list (headings and action entries) and provides an `on_confirm` callback; the picker is a pure selection UI with no knowledge of the caller's domain.

## Key files

| File      | Description                                                                |
| --------- | -------------------------------------------------------------------------- |
| `init.lua`| `M.open(opts, on_confirm)` — singleton host; injects `initData`, routes bridge messages (`ready`/`confirm`/`cancel`) |

## Shared frontend

`_shared/ui/action_picker/` — HTML/CSS/JS used by both drivers; host posts `initData` via `evaluateJavaScript`.

## Usage

```lua
local ActionPicker = require("ui.action_picker")
ActionPicker.open({ title = "Choisir une action", items = list, current = cur_id },
    function(id) ... end)
```
