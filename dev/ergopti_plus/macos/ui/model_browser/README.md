# model_browser (Hammerspoon)

## Purpose

Floating WKWebView window rendering the curated LLM model catalogue as a sortable, filterable table. The Lua backend reads `_shared/modules/llm/models.json`, builds a normalised model list, and injects it via `evaluateJavaScript`. A two-message bridge (select / open-URL) is the complete JS↔Lua protocol. Singleton: a second `show()` focuses the existing window. Shares the HTML/CSS/JS frontend with the Windows driver.

## Key files

| File      | Description                                                           |
| --------- | --------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton host; reads model catalogue and injects data    |

## Shared frontend

`_shared/ui/model_browser/` — HTML/CSS/JS used by both drivers.
