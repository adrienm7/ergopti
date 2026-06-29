# changelog (AHK)

## Purpose

WebView2 window that fetches GitHub release notes for the configured repository and renders them as a two-column layout (sidebar list of releases + main pane with formatted Markdown). Network fetches go through WinHTTP (not WebKit fetch) so the window works on corporate proxies. The shared `_shared/ui/changelog/` frontend is loaded via a virtual-host mapping.

## Key files

| File      | Description                                                             |
| --------- | ----------------------------------------------------------------------- |
| `init.ahk`| Singleton host: opens / focuses the window; owns the WinHTTP fetch loop  |

## Shared frontend

`_shared/ui/changelog/` — HTML/CSS/JS assets used by both drivers; the host injects release data via `postMessage` so the page never makes direct network calls.
