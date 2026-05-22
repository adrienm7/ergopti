; drivers/autohotkey/lib/tap_hold_config.ahk

; ==============================================================================
; MODULE: Tap-Hold Configuration
; DESCRIPTION:
; Default state for every tap-hold binding. Extracted from features_config.ahk
; for the same reason Hammerspoon isolates its Karabiner config: tap-hold is a
; distinct sub-system with its own timing model and sub-menus, and keeping it
; separate makes both files easier to read and extend.
;
; FEATURES & RATIONALE:
; 1. __Configuration objects carry per-key timing (TimeActivationSeconds).
; 2. Leaf entries (LShiftCopy, etc.) are plain objects with Enabled + optional
;    TimeActivationSeconds — no sub-map nesting needed.
; 3. The TapHoldsConfig Map is loaded directly via #Include in ErgoptiPlus.ahk
;    before the tap-hold loader and menu initialisation.
; ==============================================================================

_TapHoldsConfig := Map(
    "__Order", [
        "CapsLock",
        "LShiftCopy",
        "LCtrlPaste",
        "LAlt",
        "Space",
        "AltGr",
        "RCtrl",
        "TabAlt"
    ],
    "CapsLock", Map(
        "__Configuration", {
            TimeActivationSeconds: 0.35,
        },
        "BackSpace", {
            Enabled: False,
            Description: "`"CapsLock`" : BackSpace",
        },
        "BackSpaceCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : BackSpace en tap, Ctrl en hold",
        },
        "CapsLockCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : CapsLock en tap, Ctrl en hold",
        },
        "CapsWordCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : CapsWord en tap, Ctrl en hold",
        },
        "CtrlBackSpaceCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : Ctrl + BackSpace en tap, Ctrl en hold",
        },
        "CtrlDeleteCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : Ctrl + Delete en tap, Ctrl en hold",
        },
        "DeleteCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : Delete en tap, Ctrl en hold",
        },
        "EnterCtrl", {
            Enabled: True,
            Description: "`"CapsLock`" : Entrée en tap, Ctrl en hold",
        },
        "EscapeCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : Échap en tap, Ctrl en hold",
        },
        "OneShotShiftCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : OneShotShift en tap, Ctrl en hold",
        },
        "TabCtrl", {
            Enabled: False,
            Description: "`"CapsLock`" : Tab en tap, Ctrl en hold",
        },
    ),
    "LShiftCopy", {
        Enabled: True,
        Description: "`"LShift`" : Ctrl + C en tap, Shift en hold",
        TimeActivationSeconds: 0.35,
    },
    "LCtrlPaste", {
        Enabled: True,
        Description: "`"LCtrl`" : Ctrl + V en tap, Ctrl en hold",
        TimeActivationSeconds: 0.2,
    },
    "LAlt", Map(
        "AltTabMonitor", {
            Enabled: False,
            Description: "`"LAlt`" : Alt+Tab sur le moniteur en tap, Alt en hold",
            TimeActivationSeconds: 0.2,
        },
        "BackSpace", {
            Enabled: False,
            Description: "`"LAlt`" : BackSpace. Shift + `"LAlt`" = Delete",
        },
        "BackSpaceLayer", {
            Enabled: True,
            Description: "`"LAlt`" : BackSpace en tap, layer de navigation en hold. Shift + `"LAlt`" = Delete",
            TimeActivationSeconds: 0.2,
        },
        "OneShotShift", {
            Enabled: False,
            Description: "`"LAlt`" : OneShotShift en tap, Shift en hold",
        },
        "TabLayer", {
            Enabled: False,
            Description: "`"LAlt`" : Tab en tap, layer de navigation en hold",
            TimeActivationSeconds: 0.2,
        },
    ),
    "Space", Map(
        "Ctrl", {
            Enabled: False,
            Description: "`"Espace`" : Espace en tap, Ctrl en hold",
            TimeActivationSeconds: 0.15,
        },
        "Layer", {
            Enabled: False,
            Description: "`"Espace`" : Espace en tap, layer de navigation en hold",
            TimeActivationSeconds: 0.15,
        },
        "Shift", {
            Enabled: False,
            Description: "`"Espace`" : Espace en tap, Shift en hold",
            TimeActivationSeconds: 0.15,
        },
    ),
    "AltGr", Map(
        "__Configuration", {
            TimeActivationSeconds: 0.2,
        },
        "BackSpace", {
            Enabled: False,
            Description: "`"AltGr`" : BackSpace en tap, AltGr en hold",
        },
        "CapsLock", {
            Enabled: False,
            Description: "`"AltGr`" : CapsLock en tap, AltGr en hold",
        },
        "CapsWord", {
            Enabled: False,
            Description: "`"AltGr`" : CapsWord en tap, AltGr en hold",
        },
        "CtrlBackSpace", {
            Enabled: False,
            Description: "`"AltGr`" : Ctrl + BackSpace en tap, AltGr en hold",
        },
        "CtrlDelete", {
            Enabled: False,
            Description: "`"AltGr`" : Ctrl + Delete en tap, AltGr en hold",
        },
        "Delete", {
            Enabled: False,
            Description: "`"AltGr`" : Delete en tap, AltGr en hold",
        },
        "Enter", {
            Enabled: False,
            Description: "`"AltGr`" : Entrée en tap, AltGr en hold",
        },
        "Escape", {
            Enabled: False,
            Description: "`"AltGr`" : Échap en tap, AltGr en hold",
        },
        "OneShotShift", {
            Enabled: False,
            Description: "`"AltGr`" : OneShotShift en tap, AltGr en hold",
        },
        "Tab", {
            Enabled: True,
            Description: "`"AltGr`" : Tab en tap, AltGr en hold",
        },
    ),
    "RCtrl", Map(
        "BackSpace", {
            Enabled: False,
            Description: "`"RCtrl`" : BackSpace. Shift + `"RCtrl`" = Delete"
        },
        "Tab", {
            Enabled: False,
            Description: "`"RCtrl`" : Tab en tap, Ctrl en hold",
            TimeActivationSeconds: 0.2,
        },
        "OneShotShift", {
            Enabled: True,
            Description: "`"RCtrl`" : OneShotShift en tap, Shift en hold",
        },
    ),
    "TabAlt", {
        Enabled: True,
        Description: "`"Tab`" : Alt-Tab sur le moniteur en tap, Alt en hold. À activer pour ne pas perdre Alt",
        TimeActivationSeconds: 0.2,
    },
)
