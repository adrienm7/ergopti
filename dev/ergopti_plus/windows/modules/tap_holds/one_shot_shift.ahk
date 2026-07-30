; modules/tap_holds/one_shot_shift.ahk

; ==============================================================================
; MODULE: Tap-Holds — One-Shot Shift
; DESCRIPTION:
; OneShotShift() capitalises the next typed character (or maps punctuation
; keys to their shifted equivalents) and resets immediately after. Also owns
; OneShotShiftFix() (disables the pending shift when used as a chord modifier)
; and ToggleCapsLock() (shared by CapsLock and AltGr tap-hold modules).
; ==============================================================================

#Requires AutoHotkey v2.0
global _OneShotShiftInputHook := ""





; ========================================
; =================================
; ======= 9/ ONE-SHOT SHIFT =======
; =================================
; ========================================

OneShotShift() {
    ; Skip entirely when the script is suspended — an in-flight InputHook would
    ; intercept keystrokes that belong to other applications while AHK is paused
    if A_IsSuspended
        return
    global OneShotShiftEnabled := True
    TimeoutSec := (IsSet(ONE_SHOT_SHIFT_TIMEOUT_SEC) and ONE_SHOT_SHIFT_TIMEOUT_SEC > 0) ? ONE_SHOT_SHIFT_TIMEOUT_SEC : 2
    ihvText := InputHook("L1 T" . TimeoutSec . " E", "=%$.', " . ScriptInformation["MagicKey"])
    ihvText.KeyOpt("{BackSpace}{Enter}{Delete}", "E") ; End keys to not swallow
    global _OneShotShiftInputHook := ihvText
    try {
        ihvText.Start()
        ihvText.Wait()
    } finally {
        try ihvText.Stop()
        _OneShotShiftInputHook := ""
    }
    ; Guard against a suspend that arrived while Wait() was blocking — discard
    ; the captured input and leave the shift state clean for the next resume
    if A_IsSuspended {
        global OneShotShiftEnabled := False
        return
    }
    SpecialCharacter := ""

    if (ihvText.EndKey == "=") {
        SpecialCharacter := Chr(0xBA) ; º (masculine ordinal indicator)
    } else if (ihvText.EndKey == "%") {
        SpecialCharacter := " %"
    } else if (ihvText.EndKey == "$") {
        SpecialCharacter := " " Chr(0x20AC) ; space + Euro sign
    } else if (ihvText.EndKey == ".") {
        SpecialCharacter := " :"
    } else if (ihvText.EndKey == ScriptInformation["MagicKey"]) {
        SpecialCharacter := "J" ; OneShotShift + magic-key gives J directly
    } else if (ihvText.EndKey == ",") {
        SpecialCharacter := " " Chr(0x3B) ; Chr avoids AHK parser misreading ";" as comment
    } else if (ihvText.EndKey == "'") {
        SpecialCharacter := " ?"
    } else if (ihvText.EndKey == " ") {
        SpecialCharacter := "-"
    }

    if (ihvText.EndReason == "Timeout") {
        return
    } else if (ihvText.EndReason == "EndKey" and (ihvText.EndKey = "BackSpace" or ihvText.EndKey = "Enter" or ihvText.EndKey = "Delete")) {
        ; InputHook is suppressive by default. Only the three KeyOpt("E") control
        ; keys (Backspace, Enter, Delete) end this one-shot capture yet still belong
        ; to the user and must reach the foreground app exactly once. The punctuation
        ; end keys (= % $ . , ' space + magic key) are ALSO EndKey terminations, so
        ; this branch must NOT swallow them — restricting it to the control keys lets
        ; them fall through to the SpecialCharacter dispatch below
        SendNewResult("{" . ihvText.EndKey . "}", False, False)
        return
    } else if SpecialCharacter != "" {
        if OneShotShiftEnabled {
            ActivateHotstrings()
            SendNewResult(SpecialCharacter)
        } else {
            SendNewResult(ihvText.EndKey)
        }
    } else {
        if OneShotShiftEnabled {
            TitleCaseText := Format("{:T}", ihvText.Input)
            SendNewResult(TitleCaseText)
        } else {
            SendNewResult(ihvText.Input)
        }
    }
}

OneShotShiftFix() {
    ; This function and global variable solves a problem when we use the OneShotShift key as a modifier.
    ; In that case, we first press this key, thus firing the OneShotShift() function that will uppercase the next character in the next 2 seconds.
    ; The only way to disable it after it has fired is to modify this global variable by setting global OneShotShiftEnabled := False.
    ; That way, calling this function OneShotShiftFix() won't uppercase the next character in our shortcuts involving the OneShotShift key.
    global OneShotShiftEnabled := False
}

; Flips the real hardware CapsLock toggle, then delegates the LED to
; UpdateCapsLockLED — the single LED owner — so the indicator stays the OR of
; CapsWord, the nav layer, and the hardware toggle. Setting the LED directly
; here would bypass that owner and let the LED desync from CapsWord/layer
; intent (e.g. turning the LED off via SetCapsLockState("Off") while the nav
; layer is still active).
ToggleCapsLock() {
	global _HardwareCapsLockOn
	; Route through DisableCapsWord so subscriber cleanup (mouse-down listener
	; unregistration) runs before the LED is updated.  Calling it unconditionally
	; is safe — DisableCapsWord is a no-op when CapsWord is not active.
	if IsSet(DisableCapsWord)
		DisableCapsWord()
	else
		global CapsWordEnabled := False
	; Flip the recorded INTENT, never the live toggle: deriving the next state
	; from GetKeyState("CapsLock", "T") read back whatever CapsWord or the nav
	; layer had just written, so a toggle pressed while either was active
	; inverted their LED instead of the user's own CapsLock.
	if !IsSet(_HardwareCapsLockOn)
		_HardwareCapsLockOn := false
	_HardwareCapsLockOn := !_HardwareCapsLockOn
	UpdateCapsLockLED()
}
