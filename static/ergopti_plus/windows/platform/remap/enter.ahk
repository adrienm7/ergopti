; platform/remap/enter.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Enter
; DESCRIPTION:
; Enter tap-hold: any action from GESTURE_ACTIONS on tap (default: enter),
; any hold modifier or nav layer on hold. Scancode SC01C.
;
; Modifier and layer ownership begin on physical Enter down. On release the
; hold is balanced first; only a quick, otherwise isolated press dispatches
; the configured tap action.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 9/ ENTER =======
; ========================
; ========================

; Helper predicates -------------------------------------------------------

_EnterHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "enter"), "enter")
}







; ==========================================
; ==========================================
; ======= 9.1) Hold-modifier variant =======
; ==========================================
; ==========================================

#HotIf TapHoldHoldModifier(TapHold, "enter") != "" and not LayerEnabled
*$SC01C:: {
	Result := TapHoldOwnImmediateModifier("enter", "Enter",
		_EnterHoldModKey(), TapHoldDuration(TapHold, "enter"))
	if (Result["tap"] and A_PriorKey == "Enter")
		_EnterDispatch()
}
#HotIf







; =======================================
; =======================================
; ======= 9.2) Hold-layer variant =======
; =======================================
; =======================================

#HotIf TapHoldHoldLayer(TapHold, "enter") != "" and TapHoldHoldModifier(TapHold, "enter") == "" and not LayerEnabled
*$SC01C:: {
	Result := TapHoldOwnImmediateLayer("Enter", TapHoldDuration(TapHold, "enter"))
	if (Result["tap"] and A_PriorKey == "Enter")
		_EnterDispatch()
}
#HotIf







; =========================================================
; =========================================================
; ======= 9.3) Tap-only (hold=none, tap action set) =======
; =========================================================
; =========================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait needed since
; there is no hold behaviour. No ~ so the native Enter is not also sent.
#HotIf TapHoldTapAction(TapHold, "enter") != "" and TapHoldTapAction(TapHold, "enter") != "enter" and TapHoldHoldModifier(TapHold, "enter") == "" and TapHoldHoldLayer(TapHold, "enter") == "" and not LayerEnabled
$SC01C:: _EnterDispatch()
#HotIf







; =================================
; =================================
; ======= 9.4) Tap dispatch =======
; =================================
; =================================

_EnterDispatch() {
	local action := TapHoldTapAction(TapHold, "enter")
	; No tap configured or tap = enter itself → native key behaviour.
	if (action == "" or action == "enter") {
		TapHoldDispatchTap("enter", TextPressKey.Bind("Enter", []))
		return
	}
	_TapHoldFireAction("enter")
}
