; platform/remap/escape.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Escape
; DESCRIPTION:
; Escape tap-hold: any action from GESTURE_ACTIONS on tap (default: escape),
; any hold modifier or nav layer on hold. Scancode SC001.
;
; Modifier or layer ownership begins synchronously on physical key-down. The
; owner is balanced on release before a quick isolated press emits the tap.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 11/ ESCAPE =======
; ==========================
; ==========================

; Helper predicates -------------------------------------------------------

_EscapeHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "escape"), "escape")
}







; ===========================================
; ===========================================
; ======= 11.1) Hold-modifier variant =======
; ===========================================
; ===========================================

#HotIf TapHoldHoldModifier(TapHold, "escape") != "" and not LayerEnabled
*$SC001:: {
	Result := TapHoldOwnImmediateModifier("escape", "Escape",
		_EscapeHoldModKey(), TapHoldDuration(TapHold, "escape"))
	if (Result["tap"] and A_PriorKey == "Escape")
		_EscapeDispatch()
}
#HotIf







; ========================================
; ========================================
; ======= 11.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "escape") != "" and TapHoldHoldModifier(TapHold, "escape") == "" and not LayerEnabled
*$SC001:: {
	Result := TapHoldOwnImmediateLayer("Escape", TapHoldDuration(TapHold, "escape"))
	if (Result["tap"] and A_PriorKey == "Escape")
		_EscapeDispatch()
}
#HotIf







; ==============================================================================
; ==============================================================================
; ======= 11.3) Tap-only (tap action set to something other than escape) =======
; ==============================================================================
; ==============================================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both Escape and the action.
#HotIf TapHoldTapAction(TapHold, "escape") != "" and TapHoldTapAction(TapHold, "escape") != "escape" and TapHoldHoldModifier(TapHold, "escape") == "" and TapHoldHoldLayer(TapHold, "escape") == "" and not LayerEnabled
$SC001:: _EscapeDispatch()
#HotIf







; ==================================
; ==================================
; ======= 11.4) Tap dispatch =======
; ==================================
; ==================================

_EscapeDispatch() {
	local action := TapHoldTapAction(TapHold, "escape")
	; No tap configured or tap = escape itself → native key behaviour.
	if (action == "" or action == "escape") {
		TapHoldDispatchTap("escape", TextPressKey.Bind("Escape", []))
		return
	}
	_TapHoldFireAction("escape")
}
