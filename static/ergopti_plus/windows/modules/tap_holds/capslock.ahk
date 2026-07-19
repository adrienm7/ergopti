; modules/tap_holds/capslock.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — CapsLock
; DESCRIPTION:
; CapsLock tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier
; (Ctrl/Shift/Alt/AltGr/Win) or nav layer on hold.
;
; Preserved subtleties:
; - LAlt+CapsLock shortcut is intercepted in every branch that remaps CapsLock,
;   so the LAltCapsLockShortcut() combo keeps working regardless of tap/hold config.
; - "plain backspace" variant (tap=backspace, hold=none): uses *SC03A with Blind
;   so modifiers are passed through — identical to the original v1 behaviour.
; - Hold-modifier variants (Ctrl/Shift/Alt/Win): pre-arm the modifier on key-down,
;   then release immediately if it was a tap so the tap action fires clean.
; - Hold-layer (nav): mirrors LAlt — activate layer on press, tap action fires on
;   release if under threshold, no modifier ever sent.
; - "no remapping" fallback: when CapsLock has no tap action AND no hold action,
;   and LAlt is remapped to one_shot_shift, the LAltCapsLockShortcut must still
;   be reachable — handled by the dedicated first #HotIf block.
; - CtrlActivated guard: when LCtrl is physically held while CapsLock fires,
;   the tap action is sent inside Ctrl so shortcuts like Ctrl+CapsLock still work.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===========================
; ======= 2/ CAPSLOCK =======
; ===========================
; ==============================

; Helper predicates -------------------------------------------------------

; True when CapsLock has a tap action or hold action configured.
_CapsLockIsRemapped() {
	return TapHoldIsConfigured(TapHold, "caps_lock")
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







; ======= 2.1) No-remap LAlt+CapsLock rescue =======

; When CapsLock is not remapped at all but LAlt is on one_shot_shift, the
; LAlt+CapsLock shortcut must still fire. Without this block AHK would let
; CapsLock pass to the OS and LAltCapsLockShortcut() would never be called.
#HotIf (
	TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift"
	and not _CapsLockIsRemapped()
	and not LayerEnabled
)
SC03A:: {
	if (KS_IsDown("SC038")) { ; LAlt physically held
		LAltCapsLockShortcut()
		return
	}
	ToggleCapsLock()
}
#HotIf







; ======= 2.2) Plain-backspace variant (tap=backspace, hold=none) =======

; Uses *SC03A (wildcard = pass modifiers through Blind) so Shift/Ctrl+CapsLock
; still produce Shift+BackSpace / Ctrl+BackSpace as expected.
#HotIf _CapsLockIsPlainBackspace() and not LayerEnabled
*SC03A:: {
	if (KS_IsDown("SC038")) { ; LAlt physically held
		LAltCapsLockShortcut()
		return
	}
	TextPressKey("BackSpace", "Blind")
}
#HotIf







; ======= 2.3) Hold-modifier variant =======

; Pre-arms the configured modifier on key-down, waits for key-up, then either
; sends the tap action (short press) or keeps the modifier held until release.
; The modifier is always released before the tap action fires so the action
; itself runs clean (e.g. Enter without Ctrl).
#HotIf _CapsLockHasHoldModifier() and not LayerEnabled
*$SC03A:: {
	CtrlActivated := KS_IsDown("SC01D") ; LCtrl physically held at press time

	if (KS_IsDown("SC038")) { ; LAlt physically held — shortcut intercept
		LAltCapsLockShortcut()
		return
	}

	ModKey := _CapsLockHoldModKey()
	HoldGuardMs := TapHoldDuration(TapHold, "caps_lock") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("caps_lock", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "CapsLock hold suppressed after long press because wheel activity was detected.")
		return
	}
	TapHoldSyntheticKeyDown(ModKey)
	tap := KeyWait("CapsLock", "T" . TapHoldDuration(TapHold, "caps_lock"))
	if tap {
		; Short press — release modifier then dispatch tap action.
		TapHoldSyntheticKeyUp(ModKey)
		_CapsLockDispatch(CtrlActivated)
		return
	}
	; Long press — modifier stays armed until key-up. Bound the wait and release
	; the modifier in a finally so a lost key-up (UAC focus steal, Suspend toggled
	; mid-press) or a thrown Send can never latch Ctrl/Shift/Alt/Win Down forever
	try {
		KeyWait("CapsLock", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 2.4) Hold-layer variant =======

; Mirrors the LAlt layer approach: activate layer on hold, tap action on release.
#HotIf _CapsLockHasHoldLayer() and not LayerEnabled
$SC03A:: {
	if (KS_IsDown("SC038")) { ; LAlt physically held
		LAltCapsLockShortcut()
		return
	}

	UpdateLastSentCharacter("CapsLock")
	HoldGuardMs := TapHoldDuration(TapHold, "caps_lock") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("caps_lock", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "CapsLock layer hold suppressed before activation because wheel activity was detected.")
		return
	}
	ActivateLayer()
	try {
		KeyWait("CapsLock", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		DisableLayer()
	}

	Now           := A_TickCount
	CharTime      := LastSentCharacterKeyTime.Has("CapsLock") ? LastSentCharacterKeyTime["CapsLock"] : Now
	tap           := ((Now - CharTime) <= TapHoldDuration(TapHold, "caps_lock") * 1000)
	if (
		tap
		and (Now - CharTime) >= TapMinDurationMs()
		and A_PriorKey == "CapsLock"
	) { ; A_PriorKey + TapMinDurationMs floor suppress spurious taps when CapsLock is brushed mid-roll
		_CapsLockDispatch(False)
	}
}
#HotIf







; ======= 2.5) Tap-only variant (tap action set, hold=none, not plain backspace) =======

; Simple gate: fire the tap action on every press (no hold behaviour).
#HotIf TapHoldTapAction(TapHold, "caps_lock") != "" and not _CapsLockHasHoldModifier() and not _CapsLockHasHoldLayer() and not _CapsLockIsPlainBackspace() and not LayerEnabled
SC03A:: {
	if (KS_IsDown("SC038")) { ; LAlt physically held
		LAltCapsLockShortcut()
		return
	}
	_CapsLockDispatch(False)
}
#HotIf







; ======= 2.6) Tap dispatch =======

; Dispatch the configured tap action for CapsLock.
; CtrlActivated: true when LCtrl was physically held at key-down time — the
; tap action is then wrapped in LCtrl so Ctrl+CapsLock combos still work.
_CapsLockDispatch(CtrlActivated) {
	TapHoldDispatchTap("caps_lock", _CapsLockInvokeTap.Bind(CtrlActivated))
}

; Emit CapsLock's special tap variants after the shared activity gate has
; accepted the physical press. Keep the optional Ctrl wrapper balanced even if
; a configured action throws.
_CapsLockInvokeTap(CtrlActivated) {
	if CtrlActivated {
		TapHoldSyntheticKeyDown("LCtrl")
	}
	try {
		; Special cases that cannot be handled by GESTURE_ACTIONS.Fn.Call() directly.
		local action := TapHoldTapAction(TapHold, "caps_lock")
		if (action == "backspace") {
			TextPressKey("BackSpace", "Blind")
		} else if (action == "caps_lock" or action == "toggle_capslock") {
			ToggleCapsLock()
		} else {
			_TapHoldInvokeConfiguredAction("caps_lock")
		}
	} finally {
		if CtrlActivated {
			TapHoldSyntheticKeyUp("LCtrl")
		}
	}
}
