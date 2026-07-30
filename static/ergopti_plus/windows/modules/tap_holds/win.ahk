; modules/tap_holds/win.ahk
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
	tap := KeyWait("LWin", "T" . TapHoldDuration(TapHold, "win"))
	if tap {
		if (A_PriorKey == "LWin")
			_WinDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "win") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("win", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Win hold suppressed after long press because wheel activity was detected.")
		return
	}
	ModKey := _WinHoldModKey()
	TapHoldSyntheticKeyDown(ModKey)
	try {
		KeyWait("LWin", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ========================================
; ========================================
; ======= 12.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and not LayerEnabled
*$SC15B:: {
	tap := KeyWait("LWin", "T" . TapHoldDuration(TapHold, "win"))
	if tap {
		if (A_PriorKey == "LWin")
			_WinDispatch()
		return
	}
	ActivateLayer()
	try {
		; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
		; must never latch it forever if the key-up event is lost. A hold LAYER holds no
		; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
		; dropped the layer out from under the user after five seconds of legitimate
		; navigation, and base-layer letters then landed in the document until it
		; re-armed. Re-arm the wait instead while the key is still physically down: every
		; iteration stays bounded, which is the property test_hold_layer_release_bounded
		; pins, and a timeout with the key already up means the key-up really was lost --
		; exactly the case the failsafe exists for.
		while !KeyWait("LWin", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("LWin", "P")
				break
		}
	} finally {
		DisableLayer()
	}
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
