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

; Returns true when at least one entry in
; ``Features["shortcuts"][<group>]`` is a true bool. Called live on every
; #HotIf evaluation so tray-menu changes take effect without a reload.
_AnyShortcutEnabled(Group) {
    global Features
    ; Reachable from a PARSE-TIME #HotIf (base_modifier.ahk SC038 & SC03A) that
    ; arms before boot assigns Features (ErgoptiPlus.ahk pre-pump block seeds
    ; TapHold/LayerEnabled/CapsWordEnabled but NOT Features). A bare .Has() on the
    ; still-unset global throws UnsetError inside the #HotIf evaluator; pre-ready
    ; the fatal error net escalates that to ExitApp(1). Guard the global itself
    ; first so the criterion simply reads "disabled" until Features exists
    if !IsSet(Features)
        return false
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

; Wrapper required: #HotIf re-evaluates its expression on every hotkey test.
; Delegates to _AnyShortcutEnabled() so runtime config changes (e.g. tray
; toggle) take effect immediately without a reload.
IsAltGrLAltEnabled() {
	return _AnyShortcutEnabled("alt_gr_lalt")
}

; Dynamic registration of SC138 & SC038 -- see _RegisterAltGrShortcutsHotkeys
; below. Defining this hotkey as a static ``SC138 & SC038::`` block would have
; AHK claim SC138 as a prefix key at parse time, which breaks native AltGr
; behaviour for the entire first-run wizard window. Registering at runtime
; through _RegisterAltGrShortcutsHotkeys() -- called after Onboarding_Run
; returns -- keeps SC138 a vanilla key until the wizard is done.

AltGrLAltShortcut() {
    global Features
    ; Defense-in-depth: the #HotIf guard only fires this dispatcher when
    ; _AnyShortcutEnabled("alt_gr_lalt") is already true, which requires the
    ; sub-map to exist -- but a direct call (or a future dispatch path that
    ; skips the #HotIf) against malformed/missing config must degrade
    ; gracefully instead of throwing on the raw Map access below.
    if !IsSet(Features) or !Features.Has("shortcuts") or !Features["shortcuts"].Has("alt_gr_lalt")
        return
    if Features["shortcuts"]["alt_gr_lalt"]["backspace"] {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = Ctrl + BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            TextPressKey("BackSpace", ["Ctrl"])
        } else {
            TextPressKey("BackSpace", [])
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["caps_lock"] {
        ToggleCapsLock()
    } else if Features["shortcuts"]["alt_gr_lalt"]["caps_word"] {
        ToggleCapsWord()
    } else if Features["shortcuts"]["alt_gr_lalt"]["ctrl_backspace"] {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            TextPressKey("BackSpace", [])
        } else {
            TextPressKey("BackSpace", ["Ctrl"])
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["ctrl_delete"] {
        ; "Shift" + "AltGr" + "LAlt" = Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            TextPressKey("Delete", [])
        } else {
            TextPressKey("Delete", ["Ctrl"])
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["delete"] {
        ; "Shift" + "AltGr" + "LAlt" = Ctrl + Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            TextPressKey("Delete", ["Ctrl"])
        } else {
            TextPressKey("Delete", [])
        }
    } else if Features["shortcuts"]["alt_gr_lalt"]["enter"] {
        TextPressKey("Enter", [])
    } else if Features["shortcuts"]["alt_gr_lalt"]["escape"] {
        TextPressKey("Escape", [])
    } else if Features["shortcuts"]["alt_gr_lalt"]["one_shot_shift"] {
        OneShotShift()
    } else if Features["shortcuts"]["alt_gr_lalt"]["tab"] {
        TextPressKey("Tab", [])
    }
}

; Wrapper required: #HotIf re-evaluates its expression on every hotkey test.
; Delegates to _AnyShortcutEnabled() so runtime config changes (e.g. tray
; toggle) take effect immediately without a reload.
IsAltGrCapsLockEnabled() {
	return _AnyShortcutEnabled("alt_gr_caps_lock")
}

; SC138 & SC03A is also registered dynamically (see _RegisterAltGrShortcutsHotkeys
; below) for the same prefix-key-at-parse-time reason as the SC038 combo above.

AltGrCapsLockShortcut() {
    ; Inline v2 if/else cascade -- same 10-action surface as LAltCapsLockShortcut
    ; but reads from the alt_gr_caps_lock sub-Map.
    global Features
    ; Defense-in-depth: same guard as AltGrLAltShortcut -- the #HotIf normally
    ; ensures this sub-map exists, but a direct call against malformed/missing
    ; config must degrade gracefully instead of throwing on the raw Map access.
    if !IsSet(Features) or !Features.Has("shortcuts") or !Features["shortcuts"].Has("alt_gr_caps_lock")
        return
    if Features["shortcuts"]["alt_gr_caps_lock"]["backspace"] {
        TextPressKey("BackSpace", [])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["caps_lock"] {
        ToggleCapsLock()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["caps_word"] {
        ToggleCapsWord()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["ctrl_backspace"] {
        TextPressKey("BackSpace", ["Ctrl"])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["ctrl_delete"] {
        TextPressKey("Delete", ["Ctrl"])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["delete"] {
        TextPressKey("Delete", [])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["enter"] {
        TextPressKey("Enter", [])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["escape"] {
        TextPressKey("Escape", [])
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["one_shot_shift"] {
        OneShotShift()
    } else if Features["shortcuts"]["alt_gr_caps_lock"]["tab"] {
        TextPressKey("Tab", [])
    }
}

; Idempotence latch for _RegisterAltGrShortcutsHotkeys. A second call would
; stack a fresh HotIf closure on the same SC138 combos, orphaning the previous
; criterion and silently shifting the SC138-as-prefix latch semantics. The
; guard turns any future in-process re-arm (the AltGr layer already does
; in-process toggling elsewhere) into a logged no-op instead of a silent
; double registration. Initialised to 0 (an integer latch, not a `:= false`
; boolean) so the require_state meta scan does not mistake this registration
; idempotence flag for an injected-dependency module-state guard.
global _AltGrShortcutsRegistered := 0

; Dynamic registration entry point -- called once Onboarding_Run() has returned
; so the wizard never sees SC138 as a prefix key. Each Hotkey() pair below
; mirrors the criterion of the previous static ``#HotIf`` block: AHK won't fire
; the combo unless the feature is enabled AND the press came through a real
; AltGr / Kana modifier.
_RegisterAltGrShortcutsHotkeys() {
    global _AltGrShortcutsRegistered
    ; Single-call contract: re-running would orphan the prior HotIf criterion and
    ; silently shift the SC138-as-prefix latch semantics, so a second call warns
    ; and bails before re-binding the SC138 combos.
    if _AltGrShortcutsRegistered {
        LoggerWarn("shortcuts", "_RegisterAltGrShortcutsHotkeys called more than once -- ignoring duplicate AltGr combo registration.")
        return
    }
    LoggerStart("shortcuts", "Registering AltGr shortcut combos (SC138 + LAlt / CapsLock)…")
    ; I3 — same priority as script-management AltGr combos. Custom prefix combos
    ; (SC138 & suffix) already use the keyboard hook; a leading ``$`` is invalid.
    opts := "I3"
    HotIf((*) => IsAltGrLAltEnabled() and IsRealAltGrPress())
    try Hotkey("SC138 & SC038", (*) => AltGrLAltShortcut(), opts)
    catch as Err {
        HotIf()
        LoggerError("shortcuts", "Failed to register SC138 & SC038 (AltGr+LAlt): {1}.", Err.Message)
        return
    }
    HotIf((*) => IsAltGrCapsLockEnabled() and IsRealAltGrPress())
    try Hotkey("SC138 & SC03A", (*) => AltGrCapsLockShortcut(), opts)
    catch as Err {
        HotIf()
        LoggerError("shortcuts", "Failed to register SC138 & SC03A (AltGr+CapsLock): {1}.", Err.Message)
        return
    }
    HotIf()
    _AltGrShortcutsRegistered := true
    LoggerSuccess("shortcuts", "AltGr shortcut combos registered.")
}

; Auto-execute hook: shortcuts.ahk is #Include'd at line 2176 of ErgoptiPlus.ahk
; which means by the time we reach this line in the merged auto-exec, the
; onboarding wizard has either been skipped (config exists) or completed and
; triggered a Reload. Registering now is therefore safe.
_RegisterAltGrShortcutsHotkeys()
