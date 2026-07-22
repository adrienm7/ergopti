# keymap (AHK)

## Purpose

Defines the full physical key remapping for the Ergopti layout: base layer, Shift layer, CapsLock layer, AltGr layer, and dead-key sequences (circumflex, acute, grave, diaeresis, tilde). All Unicode character output goes through `layout.ahk`; dead-key state is maintained in a module-level global and resolved on the next keystroke. A background timer polls the Windows keyboard layout (HKL) to adapt dead-key tables when the user switches input languages.

## Ports used (`_shared/core/ports/`)

| Port             | Usage                                                          |
| ---------------- | -------------------------------------------------------------- |
| `KeyboardHook`   | `#HotIf`-gated hotkeys for every remapped key                   |
| `TimerScheduler` | HKL poll timer (`LAYOUT_POLL_INTERVAL_MS`)                     |
| `WindowInfo`     | `ImmGetDefaultIMEWnd` to detect IME-active windows             |

## Public API

| File                    | Description                                                         |
| ----------------------- | ------------------------------------------------------------------- |
| `layout.ahk`            | All `#HotIf`-gated remap hotkeys; `DeadKey()` dispatcher           |
| `layout/`               | Sub-folder with per-dead-key resolution tables (`circumflex.ahk`, …) |
| `layout_poll_helper.ahk`| `LayoutPoll_GetHKL()` and `LayoutPoll_Changed()` HKL detection      |

## Init pattern

```ahk
; Included by ErgoptiPlus.ahk — order matters
#Include modules/keymap/layout.ahk
```

Dead-key state resets automatically when a non-composable key fires. The HKL poll is started by `layout.ahk` auto-execute and runs every `LAYOUT_POLL_INTERVAL_MS` milliseconds.
