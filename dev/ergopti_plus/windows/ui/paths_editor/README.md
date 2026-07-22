# paths_editor (AHK)

## Purpose

WebView2 host for the config-folder editor. Loads the shared `_shared/ui/paths_editor/` frontend via a virtual-host mapping; allows the user to browse for and confirm the Ergopti configuration directory. Saving rewrites `paths.toml` and reloads the driver.

## Key files

| File      | Description                                                          |
| --------- | -------------------------------------------------------------------- |
| `init.ahk`| Singleton host: `PathsEditor_Show()` — opens / focuses the window    |

## Shared frontend

`_shared/ui/paths_editor/` — HTML/CSS/JS shared with the macOS driver; host injects the current path and receives a `confirm` message with the new path on save.
