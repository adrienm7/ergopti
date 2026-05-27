# tap_holds (AHK)

## Purpose

Implements tap-vs-hold disambiguation for keys that have dual roles: a short press (tap) fires one action while a held press activates a layer or modifier. Covers the full navigation layer (arrows, word/line/document navigation, window management, volume), CapsWord, and per-key timing constants shared across all sub-modules.

## Ports used (`shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | `#HotIf`-gated hotkeys for every tap/hold key |
| `TimerScheduler` | Hold-threshold timers (`TAP_MIN_DURATION_MS`) used to distinguish tap from hold |

## Driver-local data (`windows/data/tap_hold/`)

- `windows/data/tap_hold/defaults.toml` — timing and disambiguation defaults that seed the user config at first boot

## Public API

| File | Description |
|---|---|
| `constants.ahk` | `TAP_MIN_DURATION_MS` global and `TapMinDurationMs()` accessor |
| `space.ahk` | Space tap-to-space / hold-to-modifier |
| `tab.ahk` | Tab tap-to-tab / hold-to-layer |
| `lalt.ahk` | LAlt tap-to-action / hold-to-nav-layer |
| `rctrl.ahk` | RCtrl tap-to-action / hold-to-modifier |
| `nav_layer.ahk` | Full navigation layer hotkeys, including a `1-0` repeat-multiplier row |

## Init pattern

```ahk
; Included by ErgoptiPlus.ahk
#Include modules/tap_holds/constants.ahk   ; must come first
#Include modules/tap_holds/space.ahk
#Include modules/tap_holds/nav_layer.ahk
; …etc.
```

`constants.ahk` must be included before any other tap-hold file because the timing globals (`TAP_MIN_DURATION_MS`) are referenced at hotkey-body evaluation time. The `TapMinDurationMs()` wrapper guards against hotkey bodies firing before the auto-execute section has assigned the global.
