; platform/remap/win.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Win (LWin)
; DESCRIPTION:
; LWin tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier or
; nav layer on hold. Scancodes SC15B (LWin) / SC15C (RWin).
;
; Caveat: LWin alone opens the Start menu on Windows. The ~ prefix passes the
; key through so OS shortcuts (Win+D, Win+L etc.) still work during hold.
; On tap the configured action fires AFTER key-up, so Win+nothing never
; reaches the OS on a short press — the Start menu is suppressed.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================
; =======================
; ======= 12/ WIN =======
; =======================
; =======================

; Helper predicates -------------------------------------------------------

_WinHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "win"), "win")
}







; ===========================================
; ===========================================
; ======= 12.1) Hold-modifier variant =======
; ===========================================
; ===========================================

#HotIf TapHoldHoldModifier(TapHold, "win") != "" and not LayerEnabled
*$SC15B:: {
	Result := TapHoldOwnImmediateModifier("win", "LWin",
		_WinHoldModKey(), TapHoldDuration(TapHold, "win"))
	if (Result["tap"] and A_PriorKey == "LWin")
		_WinDispatch()
}
#HotIf







; ========================================
; ========================================
; ======= 12.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and not LayerEnabled
*$SC15B:: {
	Result := TapHoldOwnImmediateLayer("LWin", TapHoldDuration(TapHold, "win"))
	if (Result["tap"] and A_PriorKey == "LWin")
		_WinDispatch()
}
#HotIf







; ==========================================================
; ==========================================================
; ======= 12.3) Tap-only (hold=none, tap action set) =======
; ==========================================================
; ==========================================================

; Fire immediately on key-down — no KeyWait or A_PriorKey guard needed since
; there is no hold behaviour. No ~ needed: Win tap action suppresses Start menu
; by intercepting the key entirely (no passthrough required).
#HotIf TapHoldTapAction(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and TapHoldHoldLayer(TapHold, "win") == "" and not LayerEnabled
SC15B:: _WinDispatch()
#HotIf







; ==================================
; ==================================
; ======= 12.4) Tap dispatch =======
; ==================================
; ==================================

_WinDispatch() {
	_TapHoldFireAction("win")
}
