# personal_info_editor (Hammerspoon)

## Purpose

Standalone WKWebView form for editing personal information (name, phone, IBAN, SSN, address, etc.). Loads the shared `_shared/ui/personal_info_editor/` frontend; the `hsPersonalInfo` usercontent bridge handler receives the updated fields and writes `personal_info.toml` before triggering a driver reload.

## Key files

| File      | Description                                                               |
| --------- | ------------------------------------------------------------------------- |
| `init.lua`| `M.show()` — singleton host; `hsPersonalInfo` bridge handler               |

## Shared frontend

`_shared/ui/personal_info_editor/` — HTML/CSS/JS shared with the Windows driver.
