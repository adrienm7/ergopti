# shortcuts (AHK)

## Purpose

Windows port of the shortcuts subsystem. Registers global hotkeys for AltGr combos, CapsLock remap, modifier-layer shortcuts (LAlt, LShift+LCtrl, RCtrl), navigation helpers, and one-shot shift. Each sub-file handles one logical shortcut group and is included by the main AHK entry point after onboarding completes.

## Ports used (`_shared/core/ports/`)

| Port           | Usage                                                                             |
| -------------- | --------------------------------------------------------------------------------- |
| `KeyboardHook` | Registering all `#HotIf`-gated hotkeys                                            |
| `WindowInfo`   | Context guards (`WinActive`, window class checks) used by several shortcut groups |

## Domain module (`_shared/core/domain/`)

No domain spec directly consumed. The module reads its enabled state from the shared `Features` map populated at startup.

## Public API (per sub-module)

| File                 | Entry point / Description                                    |
| -------------------- | ------------------------------------------------------------ |
| `capslock.ahk`       | CapsLock remap and CapsWord activation                       |
| `lalt.ahk`           | LAlt tap-to-modifier shortcuts (nav, app launch, window ops) |
| `lshift_lctrl.ahk`   | LShift+LCtrl chord shortcuts                                 |
| `one_shot_shift.ahk` | One-shot capitalisation on tap, sticky shift on double-tap   |
| `nav_layer.ahk`      | Full navigation layer hotkeys (included by `tap_holds`)      |

## Init pattern

```ahk
; Included by ErgoptiPlus.ahk after onboarding
#Include modules/shortcuts/capslock.ahk
; …etc.
```

The key combinations (AltGr then LAlt, LAlt then CapsLock, any ordered pair of tap-hold keys) are not here: their slots and their handler are `infra/key_combinations.ahk`, their hotkeys `platform/remap/key_combination_keys.ahk`. Native AltGr in the wizard window comes from the `~SC138 & ~F24` anchor in `platform/remap/altgr.ahk` makes `SC138` a prefix key from parse time, every AltGr combination is false while the wizard is up (`IsRealAltGrPress`), and AutoHotkey, which reads `SC138` as the RAlt modifier, never suppresses a modifier prefix that no variant fires for. Non-ASCII glyphs in string literals use `Chr(0xNNNN)` to avoid encoding regressions.
