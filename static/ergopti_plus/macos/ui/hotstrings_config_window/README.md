# hotstrings_config_window (Hammerspoon)

## Purpose

WKWebView-based editor for per-group and per-section hotstring expansion delay and tooltip colour. A three-tier selector (Commun / Personnel / extension) routes saves to the correct backing store. Round-trips through `modules.hotstrings_config` so the persisted file format stays consistent with the AHK driver. Changes apply immediately without a full driver reload.

## Key files

| File      | Description                                                              |
| --------- | ------------------------------------------------------------------------ |
| `init.lua`| `M.show()` — singleton host; bridge handler for JS↔Lua config I/O        |

## Shared frontend

The HTML/CSS/JS frontend is `windows/ui/hotstrings_config_window/` rendered in WKWebView; bridge messages use `hs.webview.usercontent`.
