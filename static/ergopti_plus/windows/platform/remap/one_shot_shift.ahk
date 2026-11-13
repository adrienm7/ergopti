; platform/remap/one_shot_shift.ahk

; ==============================================================================
; MODULE: Tap-Holds — One-Shot Shift
; DESCRIPTION:
; OneShotShift() capitalises the next typed character (or types the result
; _shared/tap_hold/data/one_shot_shift.json gives it) and resets immediately after. Also owns
; OneShotShiftFix() (disables the pending shift when used as a chord modifier)
; and ToggleCapsLock() (shared by CapsLock and AltGr tap-hold modules).
; ==============================================================================

#Requires AutoHotkey v2.0
; =================================
; =================================
; ======= 9/ ONE-SHOT SHIFT =======
; =================================
; =================================

OneShotShift() {
		global OneShotShiftEnabled, _ALTGR_KANA_FIXUP
		; Capture ownership ends before activation/output; the gesture epoch must
		; remain current through those later effects as well.
		GestureOwner := TapHoldNewOwner()
		; Skip entirely when the script is suspended — an in-flight InputHook would
		; intercept keystrokes that belong to other applications while AHK is paused
		if A_IsSuspended
				return
		TimeoutSec := (IsSet(ONE_SHOT_SHIFT_TIMEOUT_SEC) and ONE_SHOT_SHIFT_TIMEOUT_SEC > 0) ? ONE_SHOT_SHIFT_TIMEOUT_SEC : 2
		; Load the shared results before capture, not after its ownership settles.
		; Full scalar membership must not append an astral magic key's high unit.
		MagicKey := ScriptInformation["MagicKey"]
		_TapHoldOneShotTable()
		if !TapHoldOwnerCurrent(GestureOwner) || A_IsSuspended
				return
		NamedKeys := "{BackSpace}{Enter}{Delete}{Escape}{Tab}"
		ihvText := InputHook("L2 T" . TimeoutSec . " E C", _SIHO_ScalarEndKeys())
		ihvText.KeyOpt(NamedKeys, "ES") ; Own only ending controls; other nontext keys remain native.
		Custom := 0
		if IsSet(_ALTGR_KANA_FIXUP) && _ALTGR_KANA_FIXUP {
				Custom := _SIHO_CustomModifierCapture(ihvText, KS_AltGrKeyName(), KS_AltGrSendKey())
				if !IsObject(Custom)
						return
		}
		try {
				OwnerToken := SIHO_StartOwned(ihvText, "one-shot-shift", true)
				; Refusing a second exclusive capture leaves the admitted latch alone.
				if !OwnerToken
						return
				try {
						; Start may pump teardown. Publish only the exact admitted frame.
						PreviousCritical := Critical("On")
						try {
								Admitted := SIHO_IsOwned(OwnerToken, ihvText) && TapHoldOwnerCurrent(GestureOwner) && !A_IsSuspended
								if Admitted
										OneShotShiftEnabled := True
						} finally Critical(PreviousCritical)
						if !Admitted
								return
						ihvText.Wait()
						if IsObject(Custom) && (ihvText.EndReason == "EndKey" || ihvText.EndReason == "Max")
								if !_SIHO_CustomModifierSettle(Custom, ihvText, OwnerToken)
										return
				} finally CaptureSettled := SIHO_StopOwned(OwnerToken, ihvText)
		} finally {
				if IsObject(Custom)
						_SIHO_CustomModifierRelease(Custom, ihvText)
		}
		; Pause can finish and resume before this older Wait unwinds. Its exact
		; owner acknowledgement remains revoked even when Suspend is false again.
		if !CaptureSettled || !TapHoldOwnerCurrent(GestureOwner) || A_IsSuspended
				return
		; Lifecycle owns clearing the latch. This retired frame must never clear
		; a successor which may already be armed after pause and resume.
		Capture := _SIHO_ReadScalar(ihvText, NamedKeys)
		if Capture.Reason != ""
				LoggerWarn("OneShotShift", "Discarded invalid scalar capture ({1}).", Capture.Reason)
		if !TapHoldOwnerCurrent(GestureOwner) || A_IsSuspended
				return
		if Capture.Kind == "timeout" || Capture.Kind == "invalid"
				return
		if Capture.Kind == "control" {
				; Spending the one-shot never adds Shift to a control. Preserve
				; the original key's own flags even if they were released in Wait.
				CapturedPrefix := ""
				for Symbol in ["^", "!", "+", "#"] {
						if InStr(ihvText.EndMods, Symbol)
								CapturedPrefix .= Symbol
				}
				Restore := false
				if IsObject(Custom)
						if !_SIHO_CustomModifierReplay(Custom, KS_AltGrKeyName(), KS_AltGrSendKey(), &Restore)
								return
				; Own only a modifier the endpoint held but has since released.
				; The captured VK is retained through Up even if the HKL changes.
				try {
						if Restore && !TapHoldSyntheticKeyDown(Custom.send_key, GestureOwner)
								return
						if TapHoldOwnerCurrent(GestureOwner) && !A_IsSuspended
								SendNewResult(CapturedPrefix . "{" . Capture.Name . "}", False, False)
				} finally {
						if Restore
								TapHoldSyntheticKeyUp(Custom.send_key, GestureOwner)
				}
				return
		}
		Scalar := Capture.Text
		SpecialCharacter := TapHoldOneShotResult(Scalar, MagicKey)
		if !TapHoldOwnerCurrent(GestureOwner) || A_IsSuspended
				return
		if SpecialCharacter != "" {
				if OneShotShiftEnabled {
						ActivateHotstrings()
						if !TapHoldOwnerCurrent(GestureOwner) || A_IsSuspended
								return
						SendNewResult(SpecialCharacter)
				} else {
						SendNewResult(Scalar)
				}
		} else {
				if OneShotShiftEnabled {
						; The shared title rule, as the Lua drivers' UnicodeCase.title.
						TitleCaseText := TextCaseTitle(Scalar)
						SendNewResult(TitleCaseText)
				} else {
						SendNewResult(Scalar)
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

; Flips genuine CapsLock intent and delegates the toggle/LED to its single
; owner. Navigation uses a separate tray indicator and never changes case.
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
