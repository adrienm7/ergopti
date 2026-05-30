; modules/tap_holds/lshift_lctrl.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — LShift and LCtrl
; DESCRIPTION:
; LShift tap-hold (configurable action on tap / shift on hold) and LCtrl
; tap-hold (configurable action on tap / ctrl on hold). The tap action is
; freely selectable from GESTURE_ACTIONS via the tray menu picker.
;
; Preserved subtleties:
; - "~$" prefix: passthrough so the physical Shift/Ctrl still reaches the OS
;   during the KeyWait window (e.g. hotkeys that include Shift/Ctrl still fire).
; - A_PriorKey == "LShift"/"LControl" guard: allows firing the tap action for
;   very fast presses that complete under the tap threshold yet still feel
;   intentional, while blocking spurious taps triggered mid-shortcut.
; - LCtrl: KS_IsUp("SC03A") and KS_IsUp("SC038") guards prevent a spurious
;   paste when CapsLock+LCtrl or LAlt+LCtrl combinations are released.
; - LCtrl: UpdateLastSentCharacter("LControl") keeps the hotstring engine in
;   sync with the physical key stream.
; - LCtrl: ~ must NOT be used on SC01D — see the comment below.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 3/ LSHIFT AND LCTRL =======
; ==========================================
; ==========================================

; Gate: any configured tap action activates the handler.
; The hold behaviour (Shift staying Shift) is provided by the OS passthrough
; via the ~ prefix — no explicit hold logic is needed here.
#HotIf TapHoldTapAction(TapHold, "left_shift") != "" and not LayerEnabled
~$SC02A::
{
	TimeBefore := A_TickCount
	KeyWait("SC02A")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_shift") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LShift"
	) { ; A_PriorKey allows fast shortcuts under the tap threshold without triggering the tap action mid-combo
		_LShiftDispatch()
	}
}
#HotIf

; Dispatch the configured tap action for LShift.
_LShiftDispatch() {
	_TapHoldFireAction("left_shift")
}




; ======= 3.1) LCtrl — tap-only (hold=none) =======

; ~ must NOT be used on SC01D — AltGr = LCtrl+RAlt in AHK; ~ would latch LCtrl
; on every AltGr press. $ suppresses keyboard-hook re-entry.
;
; Tap-only variant: fire the action immediately on key-down, no KeyWait needed.
; CapsLock and LAlt guards prevent spurious fires on CapsLock+LCtrl or
; LAlt+LCtrl combos. No A_PriorKey guard — it is unreliable without ~ because
; AHK updates A_PriorKey only when the hook sees the key, and mid-combo presses
; can change it before KeyWait returns.
#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and TapHoldHoldModifier(TapHold, "left_ctrl") == "" and TapHoldHoldLayer(TapHold, "left_ctrl") == "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	if (
		KS_IsUp("SC03A") ; CapsLock must not be physically held
		and KS_IsUp("SC038") ; LAlt must not be physically held
	) {
		_LCtrlDispatch()
	}
}
#HotIf


; ======= 3.2) LCtrl — hold-modifier =======

#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and TapHoldHoldModifier(TapHold, "left_ctrl") != "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	if (KS_IsUp("SC03A") and KS_IsUp("SC038")) {
		ModKey := _LCtrlHoldModKey()
		TextPressKey(ModKey, "Down")
		tap := KeyWait("SC01D", "T" . TapHoldDuration(TapHold, "left_ctrl"))
		TextPressKey(ModKey, "Up")
		if tap {
			_LCtrlDispatch()
		}
	}
}
#HotIf


; ======= 3.3) LCtrl — hold-layer =======

#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and TapHoldHoldLayer(TapHold, "left_ctrl") != "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	ActivateLayer()
	KeyWait("SC01D")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LControl") ? LastSentCharacterKeyTime["LControl"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_ctrl") * 1000)
	if (tap and KS_IsUp("SC03A") and KS_IsUp("SC038")) {
		_LCtrlDispatch()
	}
}
#HotIf

; Return the AHK key name for the configured hold modifier on LCtrl.
_LCtrlHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "left_ctrl") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}

; Dispatch the configured tap action for LCtrl.
_LCtrlDispatch() {
	_TapHoldFireAction("left_ctrl")
}
