# onboarding (AHK)

## Purpose

First-run wizard shown automatically when `config.toml` is absent, and re-run
from Configuration > Setup wizard over the configuration in force. The WebView2
host renders the shared page at `_shared/ui/onboarding/`: after the language and
configuration-folder steps, one opt-in question per feature category (default
No), with the recommended choices to import. The page answers with manifest
paths; they are validated against the generated catalogue and written in one
transaction, then the driver reloads once. Without WebView2 the wizard cannot be
shown: the user is told so and a first run exits.

## Key files

| File                       | Description                                                            |
| -------------------------- | ---------------------------------------------------------------------- |
| `init.ahk`                 | Includes the sub-modules                                               |
| `core.ahk`                 | Entry points `Onboarding_Run()` and `Onboarding_ShowFromMenu()`        |
| `answers.ahk`              | Catalogue index, answer validation, values read from a config.toml     |
| `webview.ahk`              | WebView2 host and the page's action protocol                           |
| `finish.ahk`               | Transactional write of config.toml (and paths.toml) followed by Reload |
| `gesture_registration.ahk` | Elevated touchpad gesture registration from the gestures page          |

## Usage

```ahk
; Called automatically by ErgoptiPlus.ahk boot when config is absent:
Onboarding_Run()
```
