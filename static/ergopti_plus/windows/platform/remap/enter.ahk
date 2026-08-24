; platform/remap/enter.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Enter
; DESCRIPTION:
; Enter tap-hold: any action from GESTURE_ACTIONS on tap (default: enter),
; any hold modifier or nav layer on hold. Scancode SC01C.
;
; Two-phase design (mirrors space.ahk) to prevent auto-repeat from
; triggering multiple Enter strokes during a long hold:
; Phase 1 — KeyWait with timeout discriminates tap from hold.
;   tap=1 (released before threshold) → dispatch tap action.
;   tap=0 (still held at threshold) → enter hold phase.
; Phase 2 (modifier) — arm modifier, capture next keystroke via InputHook,
;   then release modifier on key-up.
; Phase 2 (layer) — activate layer, keep active until key-up.
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
	tap := KeyWait("Enter", "T" . TapHoldDuration(TapHold, "enter"))
	if tap {
		; Short press — tap action.
		if (A_PriorKey == "Enter")
			_EnterDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "enter") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("enter", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Enter hold suppressed after long press because wheel activity was detected.")
		return
	}
	; Long press — arm modifier, stay armed until key-up.
	ModKey := _EnterHoldModKey()
	if !TapHoldSyntheticKeyDown(ModKey)
		return
	; Bound the wait and release in a finally so a lost key-up or thrown Send can
	; never latch the modifier Down (tap_holds/constants.ahk explains the cap)
	try {
		KeyWait("Enter", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
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
