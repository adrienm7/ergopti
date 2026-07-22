# personal_info_editor (AHK)

## Purpose

WebView2 host for the personal-information form (name, phone, IBAN, SSN, address, etc.). Loads the shared `_shared/ui/personal_info_editor/` frontend; the host injects current values and receives a `confirm` message with the updated fields, which it writes to `personal_info.toml` and triggers a driver reload.

## Key files

| File      | Description                                                                    |
| --------- | ------------------------------------------------------------------------------ |
| `init.ahk`| Singleton host: `PersonalInfoEditor_Show()` — opens / focuses the window        |

## Shared frontend

`_shared/ui/personal_info_editor/` — HTML/CSS/JS shared with the macOS driver.
