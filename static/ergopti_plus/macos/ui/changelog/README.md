# changelog (Hammerspoon)

## Purpose

Floating WKWebView window that fetches GitHub release notes and renders them as a two-column layout (sidebar list of releases + main pane with formatted Markdown). Fetches go through `hs.http.asyncGet` (not WebKit fetch) so the window works on corporate proxies that intercept TLS. Loads the shared `_shared/ui/changelog/` frontend; the host injects release JSON and the page renders without making direct network calls.

## Key files

| File      | Description                                                            |
| --------- | ---------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton; owns the async fetch and `evaluateJavaScript` injection |

## Shared frontend

`_shared/ui/changelog/` — HTML/CSS/JS shared with the Windows driver.
