# onboarding (AHK)

## Purpose

Multi-step first-run wizard shown automatically when `config.toml` is absent. Built on WebView2 (`_shared/ui/onboarding/` frontend); features live locale preview (the wizard re-renders in the chosen language before step 2), page-as-destroy navigation so each step has clean state, and a single atomic TOML write at the end followed by a driver reload. A native `InputBox` fallback handles systems without WebView2.

## Key files

| File       | Description                                                             |
| ---------- | ----------------------------------------------------------------------- |
| `init.ahk` | Entry: `Onboarding_Start()` — detects absence of config, opens wizard   |
| `steps.ahk`| Step definitions and per-step validation / mutation logic               |

## Usage

```ahk
; Called automatically by ErgoptiPlus.ahk boot when config is absent:
Onboarding_Start()
```
