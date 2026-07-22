# wpm_widget (shared constants)

## Purpose

Cross-driver visual constants for the WPM floating widget (pill, sparkline, and macOS menu bar modes). Both drivers read from `constants.toml` at boot so the two widget surfaces share identical colours, geometry, and darkening factors without duplicating literals.

## Key files

| File             | Description                                                             |
| ---------------- | ----------------------------------------------------------------------- |
| `constants.toml` | Colours (hex), dimensions (px), alpha, and darkening-factor constants   |

## Driver implementations

| Driver   | Consumer                                    |
| -------- | ------------------------------------------- |
| Windows  | `windows/lib/metrics/wpm_widget.ahk`        |
| macOS    | `macos/ui/wpm/wpm_widget.lua` (+ menubar)   |

Both implementations load `constants.toml` at startup; a change here is reflected in both surfaces on next reload without touching driver code.
