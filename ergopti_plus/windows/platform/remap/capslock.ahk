; platform/remap/capslock.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — CapsLock
; DESCRIPTION:
; CapsLock tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier
; (Ctrl/Shift/Alt/AltGr/Win) or nav layer on hold.
;
; Preserved subtleties:
; - "plain backspace" variant (tap=backspace, hold=none): uses *SC03A with Blind
;   so modifiers are passed through — identical to the original v1 behaviour.
; - Hold-modifier variants (Ctrl/Shift/Alt/Win): pre-arm the modifier on key-down,
;   then release immediately if it was a tap so the tap action fires clean.
; - Hold-layer (nav): mirrors LAlt — activate layer on press, tap action fires on
;   release if under threshold, no modifier ever sent.
; - A key combination that ends on CapsLock (LAlt then CapsLock) is not
;   intercepted here: its hotkeys are created before these and fire first
;   (platform/remap/key_combination_keys.ahk).
; - A Ctrl the user holds while tapping CapsLock stays down: the synthetic owner
;   leaves a key the user holds to the user, so Ctrl+CapsLock gives Ctrl+tap.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================
; ===========================
; ======= 2/ CAPSLOCK =======
; ===========================
; ===========================

; Helper predicates -------------------------------------------------------

; True when CapsLock has a tap action or hold action configured.
_CapsLockIsRemapped() {
	return TapHoldIsActive(TapHold, "caps_lock")
}

; True when tap=backspace and hold=none (the plain-backspace variant that
; needs *SC03A with Blind passthrough — no modifier pre-arming needed).
_CapsLockIsPlainBackspace() {
	return TapHoldTapAction(TapHold, "caps_lock") == "backspace"
		and TapHoldHoldModifier(TapHold, "caps_lock") == ""
		and TapHoldHoldLayer(TapHold, "caps_lock") == ""
}

; True when CapsLock has any hold modifier configured (Ctrl/Shift/Alt/Win/AltGr).
_CapsLockHasHoldModifier() {
	return TapHoldHoldModifier(TapHold, "caps_lock") != ""
}

; True when CapsLock has the nav layer as hold.
_CapsLockHasHoldLayer() {
	return TapHoldHoldLayer(TapHold, "caps_lock") != ""
}

; Return the AHK key name for the configured hold modifier.
_CapsLockHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "caps_lock"), "caps_lock")
}







; =======================================================================
; =======================================================================
; ======= 2.2) Plain-backspace variant (tap=backspace, hold=none) =======
; =======================================================================
; =======================================================================

; Uses *SC03A (wildcard = pass modifiers through Blind) so Shift/Ctrl+CapsLock
; still produce Shift+BackSpace / Ctrl+BackSpace as expected.
#HotIf _CapsLockIsPlainBackspace() and not LayerEnabled
*SC03A:: {
	TextPressKey("BackSpace", "Blind")
}
#HotIf







; ==========================================
; ==========================================
; ======= 2.3) Hold-modifier variant =======
; ==========================================
; ==========================================

; Pre-arms the configured modifier on key-down, waits for key-up, then either
; sends the tap action (short press) or keeps the modifier held until release.
; The modifier is always released before the tap action fires so the action
; itself runs clean (e.g. Enter without Ctrl).
#HotIf _CapsLockHasHoldModifier() and not LayerEnabled
*$SC03A:: {
	ModKey := _CapsLockHoldModKey()
	Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", ModKey,
		TapHoldDuration(TapHold, "caps_lock"))
	if Result["tap"]
		_CapsLockDispatch()
}
#HotIf







; =======================================
; =======================================
; ======= 2.4) Hold-layer variant =======
; =======================================
; =======================================

; Mirrors the LAlt layer approach: activate layer on hold, tap action on release.
#HotIf _CapsLockHasHoldLayer() and not LayerEnabled
*$SC03A:: {

	UpdateLastSentCharacter("CapsLock")
	Result := TapHoldOwnImmediateLayer("caps_lock", "CapsLock", TapHoldDuration(TapHold, "caps_lock"))
	if (
		Result["tap"]
		and Result["elapsed_ms"] >= TapMinDurationMs()
		and TapHoldPriorKeyIsSelf("caps_lock")
	) { ; A_PriorKey + TapMinDurationMs floor suppress spurious taps when CapsLock is brushed mid-roll
		_CapsLockDispatch()
	}
}
#HotIf







; ======================================================================================
; ======================================================================================
; ======= 2.5) Tap-only variant (tap action set, hold=none, not plain backspace) =======
; ======================================================================================
; ======================================================================================

; Simple gate: fire the tap action on every press (no hold behaviour).
#HotIf TapHoldTapAction(TapHold, "caps_lock") != "" and not _CapsLockHasHoldModifier() and not _CapsLockHasHoldLayer() and not _CapsLockIsPlainBackspace() and not LayerEnabled
*SC03A:: {
	_CapsLockDispatch()
}
#HotIf







; =================================
; =================================
; ======= 2.6) Tap dispatch =======
; =================================
; =================================

; Dispatch the configured tap action for CapsLock.
_CapsLockDispatch() {
	TapHoldDispatchTap("caps_lock", _CapsLockInvokeTap)
}

; Emit CapsLock's special tap variants after the shared activity gate has
; accepted the physical press. A Ctrl the user holds is still down here, so the
; tap carries it without any wrapper of its own.
_CapsLockInvokeTap() {
	; Special cases that cannot be handled by GESTURE_ACTIONS.Fn.Call() directly.
	local action := TapHoldTapAction(TapHold, "caps_lock")
	if (action == "backspace") {
		TextPressKey("BackSpace", "Blind")
	} else if (action == "caps_lock" or action == "toggle_capslock") {
		ToggleCapsLock()
	} else {
		_TapHoldInvokeConfiguredAction("caps_lock")
	}
	return true
}







; ====================================
; ====================================
; ======= 2.7) Own auto-repeat =======
; ====================================
; ====================================

; The key's own auto-repeat while an owner holds its suppressed press. Under
; a layer hold no variant above is eligible any more, and the navigation layer
; would map the repeat (CapsLock repeated its layer Backspace) or let it reach
; the system. Declared before nav_layer.ahk, so this variant wins there
; (see TapHoldPressIsOwned).
#HotIf TapHoldPressIsOwned("caps_lock")
*SC03A:: return
#HotIf
