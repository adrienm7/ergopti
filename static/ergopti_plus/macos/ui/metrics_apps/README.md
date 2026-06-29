# metrics_apps (Hammerspoon)

## Purpose

WKWebView dashboard showing time-per-application usage derived from the keylogger's `db.sqlite`. Reads records via the `Storage` adapter's `sqlite_reader`; aggregates by `(date, app)` across all devices so a shared-cloud-folder setup accumulates data naturally. Two-stage paint: first renders the disk-cached snapshot (instant), then queries fresh data in the background and updates the page.

## Key files

| File      | Description                                                                |
| --------- | -------------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton host; data pipeline from SQLite to JS bridge         |

## Data path

`keylogger/db.sqlite` → `sqlite_reader` adapter → Lua aggregation → `evaluateJavaScript` injection → rendered chart.
