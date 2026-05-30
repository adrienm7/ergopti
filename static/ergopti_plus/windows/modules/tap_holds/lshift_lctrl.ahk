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
; Without ~, LCtrl never reaches the OS — so Ctrl+X combos would be broken if we
; fire on key-down. Instead: KeyWait with timeout, then check A_PriorKey.
; - Relâché seul sous le timeout (A_PriorKey == "LControl") → tap action.
; - Autre touche pressée pendant l'attente (A_PriorKey != "LControl") → combo:
;   re-send LCtrl+that key so the OS sees the real shortcut.
; - Timeout expiré sans autre touche → long hold with no action configured, pass
;   LCtrl through to the OS for any subsequent combo keys.
#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and TapHoldHoldModifier(TapHold, "left_ctrl") == "" and TapHoldHoldLayer(TapHold, "left_ctrl") == "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	tap := KeyWait("SC01D", "T" . TapHoldDuration(TapHold, "left_ctrl"))
	if tap {
		; Key released within timeout.
		if (A_PriorKey == "LControl" and KS_IsUp("SC03A") and KS_IsUp("SC038")) {
			_LCtrlDispatch()
		} else {
			; Another key was pressed during the wait — pass LCtrl through so the
			; combo reaches the OS (e.g. LCtrl was already released alongside that key).
			Send("{LCtrl Down}{LCtrl Up}")
		}
	} else {
		; Timeout expired — hold with no configured hold action. Keep LCtrl down
		; for the OS until the physical key is released, then lift it.
		Send("{LCtrl Down}")
		KeyWait("SC01D")
		Send("{LCtrl Up}")
	}
}
#HotIf


; ======= 3.2) LCtrl — hold-modifier =======

#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and TapHoldHoldModifier(TapHold, "left_ctrl") != "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	ModKey := _LCtrlHoldModKey()
	TextPressKey(ModKey, "Down")
	tap := KeyWait("SC01D", "T" . TapHoldDuration(TapHold, "left_ctrl"))
	if tap {
		; Short press — release modifier then fire tap action.
		TextPressKey(ModKey, "Up")
		if (KS_IsUp("SC03A") and KS_IsUp("SC038")) {
			_LCtrlDispatch()
		}
		return
	}
	; Long press — modifier already held by OS; wait for physical release then lift.
	KeyWait("SC01D")
	TextPressKey(ModKey, "Up")
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
