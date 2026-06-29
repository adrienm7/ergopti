# metrics_typing (Hammerspoon)

## Purpose

WKWebView dashboard showing detailed typing metrics (WPM distribution, hotstring hit rates, SFB reduction, keystroke heatmap). SQLite-only data path with rev-keyed cache per filter combination; two-stage paint (cache first, fresh SQL second). Supports dynamic date-range and app-filter requests sent from the JS frontend via `window._lua_request`; responses arrive asynchronously via a poll timer.

## Key files

| File      | Description                                                               |
| --------- | ------------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton host; poll timer for JS request/response bridge    |

## Data path

`keylogger/db.sqlite` → `sqlite_reader` adapter → Lua query → `evaluateJavaScript` injection → rendered metrics.
