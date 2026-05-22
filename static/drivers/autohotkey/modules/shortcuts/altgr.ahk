; modules/shortcuts/altgr.ahk

; ==============================================================================
; MODULE: Shortcuts — AltGr Combos
; DESCRIPTION:
; AltGr-layer shortcuts: AltGr+LAlt and AltGr+CapsLock combos each dispatch
; one of ten configurable actions. Both hotkeys are registered dynamically
; (after onboarding) to prevent AHK from claiming SC138 as a prefix key at
; parse time, which would silently break native AltGr for the wizard window.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 4/ ALTGR SHORTCUTS =======
; ==================================
; ==================================

; Pre-computed at boot -- evaluated once instead of 10 OR comparisons per key press.
global _ALTGR_LALT_ENABLED := _AnyShortcutEnabled("alt_gr_lalt")

; Returns true when at least one entry in
; ``Features["shortcuts"][<group>]`` is a true bool. Used by the boot-time
; ``_ALTGR_*_ENABLED`` gates so the multi-OR check happens once instead of
; on every key press routed through the gated combo.
_AnyShortcutEnabled(Group) {
    global Features
    if !Features.Has("shortcuts") or !Features["shortcuts"].Has(Group) {
        return false
    }
    for _Key, Val in Features["shortcuts"][Group] {
        if (Val = true) {
            return true
        }
    }
    return false
}

; Wrapper required: #HotIf re-evaluates its expression every time the hotkey
; is tested. If the global is read before auto-execute has assigned it, AHK
; raises "global variable has not been assigned a value".
IsAltGrLAltEnabled() {
    global _ALTGR_LALT_ENABLED
    return IsSet(_ALTGR_LALT_ENABLED) ? _ALTGR_LALT_ENABLED : False
}

; Dynamic registration of SC138 & SC038 -- see _RegisterAltGrShortcutsHotkeys
; below. Defining this hotkey as a static ``SC138 & SC038::`` block would have
; AHK claim SC138 as a prefix key at parse time, which breaks native AltGr
; behaviour for the entire first-run wizard window. Registering at runtime
; through _RegisterAltGrShortcutsHotkeys() -- called after Onboarding_Run
; returns -- keeps SC138 a vanilla key until the wizard is done.

AltGrLAltShortcut() {
    if Features["shortcuts"]["alt_gr_lalt"]["backspace"] {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = Ctrl + BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("^{BackSpace}")
        } else {
            SendInput("{BackSpace}")
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["caps_lock"] {
        ToggleCapsLock()
    } else if Features["shortcuts"]["alt_gr_lalt"]["caps_word"] {
        ToggleCapsWord()
    } else if Features["shortcuts"]["alt_gr_lalt"]["ctrl_backspace"] {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("{BackSpace}")
        } else {
            SendInput("^{BackSpace}")
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["ctrl_delete"] {
        ; "Shift" + "AltGr" + "LAlt" = Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("{Delete}")
        } else {
            SendInput("^{Delete}")
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["delete"] {
        ; "Shift" + "AltGr" + "LAlt" = Ctrl + Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("^{Delete}")
        } else {
            SendInput("{Delete}")
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["enter"] {
        SendInput("{Enter}")
    } else if Features["shortcuts"]["alt_gr_lalt"]["escape"] {
        SendInput("{Escape}")
    } else if Features["shortcuts"]["alt_gr_lalt"]["one_shot_shift"] {
        OneShotShift()
    } else if Features["shortcuts"]["alt_gr_lalt"]["tab"] {
        SendInput("{Tab}")
    }
}

global _ALTGR_CAPSLOCK_ENABLED := _AnyShortcutEnabled("alt_gr_caps_lock")

; Wrapper required: #HotIf re-evaluates its expression every time the hotkey
; is tested. If the global is read before auto-execute has assigned it, AHK
; raises "global variable has not been assigned a value".
IsAltGrCapsLockEnabled() {
    global _ALTGR_CAPSLOCK_ENABLED
    return IsSet(_ALTGR_CAPSLOCK_ENABLED) ? _ALTGR_CAPSLOCK_ENABLED : False
}

; SC138 & SC03A is also registered dynamically (see _RegisterAltGrShortcutsHotkeys
; below) for the same prefix-key-at-parse-time reason as the SC038 combo above.

AltGrCapsLockShortcut() {
    ; Inline v2 if/else cascade -- same 10-action surface as LAltCapsLockShortcut
    ; but reads from the alt_gr_caps_lock sub-Map.
    if Features["shortcuts"]["alt_gr_caps_lock"]["backspace"] {
        SendEvent("{BackSpace}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["caps_lock"] {
        ToggleCapsLock()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["caps_word"] {
        ToggleCapsWord()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["ctrl_backspace"] {
        SendInput("^{BackSpace}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["ctrl_delete"] {
        SendInput("^{Delete}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["delete"] {
        SendInput("{Delete}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["enter"] {
        SendInput("{Enter}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["escape"] {
        SendInput("{Escape}")
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["one_shot_shift"] {
        OneShotShift()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["tab"] {
        SendInput("{Tab}")
    }
}

; Dynamic registration entry point -- called once Onboarding_Run() has returned
; so the wizard never sees SC138 as a prefix key. Each Hotkey() pair below
; mirrors the criterion of the previous static ``#HotIf`` block: AHK won't fire
; the combo unless the feature is enabled AND the press came through a real
; AltGr / Kana modifier.
_RegisterAltGrShortcutsHotkeys() {
    HotIf((*) => IsAltGrLAltEnabled() and IsRealAltGrPress())
    Hotkey("SC138 & SC038", (*) => AltGrLAltShortcut(), "I2")
    HotIf((*) => IsAltGrCapsLockEnabled() and IsRealAltGrPress())
    Hotkey("SC138 & SC03A", (*) => AltGrCapsLockShortcut(), "I2")
    HotIf()
}

; Auto-execute hook: shortcuts.ahk is #Include'd at line 2176 of ErgoptiPlus.ahk
; which means by the time we reach this line in the merged auto-exec, the
; onboarding wizard has either been skipped (config exists) or completed and
; triggered a Reload. Registering now is therefore safe.
_RegisterAltGrShortcutsHotkeys()
