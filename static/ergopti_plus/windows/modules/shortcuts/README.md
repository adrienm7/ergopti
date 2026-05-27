# shortcuts (AHK)

## Purpose

Windows port of the shortcuts subsystem. Registers global hotkeys for AltGr combos, CapsLock remap, modifier-layer shortcuts (LAlt, LShift+LCtrl, RCtrl), navigation helpers, and one-shot shift. Each sub-file handles one logical shortcut group and is included by the main AHK entry point after onboarding completes.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Registering all `#HotIf`-gated hotkeys |
| `WindowInfo` | Context guards (`WinActive`, window class checks) used by several shortcut groups |

## Domain module (`_shared/domain/`)

No domain spec directly consumed. The module reads its enabled state from the shared `Features` map populated at startup.

## Public API (per sub-module)

| File | Entry point / Description |
|---|---|
| `altgr.ahk` | AltGr+LAlt and AltGr+CapsLock combo dispatchers (10 configurable slots each) |
| `capslock.ahk` | CapsLock remap and CapsWord activation |
| `lalt.ahk` | LAlt tap-to-modifier shortcuts (nav, app launch, window ops) |
| `lshift_lctrl.ahk` | LShift+LCtrl chord shortcuts |
| `one_shot_shift.ahk` | One-shot capitalisation on tap, sticky shift on double-tap |
| `nav_layer.ahk` | Full navigation layer hotkeys (included by `tap_holds`) |
| `base_modifier.ahk` | Shared modifier-remapping helpers |

## Init pattern

```ahk
; Included by ErgoptiPlus.ahk after onboarding
#Include modules/shortcuts/altgr.ahk
#Include modules/shortcuts/capslock.ahk
; …etc.
```

AltGr bindings are registered dynamically after onboarding (not at parse time) to prevent AHK from claiming `SC138` as a prefix key during the wizard window, which would silently break native AltGr for non-keyboard users. Non-ASCII glyphs in string literals use `Chr(0xNNNN)` to avoid encoding regressions.
