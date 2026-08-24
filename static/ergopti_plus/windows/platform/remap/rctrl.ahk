; platform/remap/rctrl.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — RCtrl
; DESCRIPTION:
; RCtrl tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier or
; nav layer on hold.
;
; Preserved subtleties:
; - backspace tap: key-repeat loop + LShift→Delete guard + LAlt(=OneShotShift)
;   guard to avoid triggering Ctrl+Alt+Delete via Delete key.
; - tab tap: ~ prefix so RCtrl still reaches the OS during KeyWait; explicit
;   pass-through hotkeys for +/^/^+/#SC11D so Shift+Tab, Ctrl+Tab, Win+Tab
;   keep working despite the tap-hold intercepting the bare key.
; - one_shot_shift tap: pre-arms LShift for the hold phase.
; - Generic hold-modifier: pre-arms the configured modifier, releases on tap.
; - Generic hold-layer: activates nav layer on hold, tap action on release.
; - Generic tap-only (hold=none): fires action immediately on press.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 7/ RCTRL =======
; ========================
; ========================

; Helper predicates -------------------------------------------------------

; True when the tap action is handled by a dedicated block (special mechanics).
_RCtrlIsSpecialTap() {
	local action := TapHoldTapAction(TapHold, "right_ctrl")
	return action == "backspace"
		or action == "tab"
		or action == "one_shot_shift"
}

; Return the AHK key name for the configured hold modifier. "ctrl" maps to
; RCtrl (not the shared default LCtrl) so holding the physical Right Ctrl as
; its own hold modifier arms the right-side key.
_RCtrlHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "right_ctrl"), "right_ctrl", "RCtrl")
}







; ===============================================
; ===============================================
; ======= 7.1) backspace tap (key-repeat) =======
; ===============================================
; ===============================================

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "backspace" and not LayerEnabled
SC11D::
{
	if KS_IsDown("LShift") { ; LShift physically held → Delete
		TextPressKey("Delete", "")
	} else if TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and KS_IsDown("SC038") { ; LAlt(=OneShotShift) physically held
		; Cannot simply send Delete — RCtrl+LAlt would be Ctrl+Alt+Delete
		OneShotShiftFix()
		TextPressKey("Right", "")
		TextPressKey("BackSpace", "")
	} else {
		TextPressKey("BackSpace", "")
		Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
		while KS_IsDown("SC11D") { ; key-repeat loop while RCtrl physically held
			if A_IsSuspended
				break
			TextPressKey("BackSpace", "")
			Sleep(KEY_REPEAT_INTERVAL_MS)
		}
	}
}
#HotIf







; ============================
; ============================
; ======= 7.2) tab tap =======
; ============================
; ============================

; ~ prefix: RCtrl passthrough so the OS still sees Ctrl during KeyWait.
; Explicit modifier pass-throughs so Shift+Tab, Ctrl+Tab, Win+Tab still work.
#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "tab" and not LayerEnabled
~SC11D:: {
	tap := KeyWait("RControl", "T" . TapHoldDuration(TapHold, "right_ctrl"))
	if (tap and A_PriorKey == "RControl") {
		if !TapHoldReleasePhysicalKey("RCtrl")
			return
		TapHoldDispatchTap("right_ctrl", LLM_Tooltip_FireTabOrAccept.Bind(""))
	}
}

+SC11D::  TextPressKey("Tab", "Shift")
^SC11D::  TextPressKey("Tab", "Ctrl")
^+SC11D:: TextPressKey("Tab", "Ctrl Shift")
#SC11D::  TextPressKey("Tab", "Win") ; TextPressKey required — SendInput doesn't work here
#HotIf







; =======================================
; =======================================
; ======= 7.3) one_shot_shift tap =======
; =======================================
; =======================================

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" and not LayerEnabled
SC11D:: {
	tap := KeyWait("SC11D", "T" . TapHoldDuration(TapHold, "right_ctrl"))
	if tap {
		TapHoldDispatchTap("right_ctrl", OneShotShift)
		return
	}
	; Long press — arm Shift until key-up, releasing it in a finally so it can
	; NEVER latch. The wait is capped (U T<timeout>) so a lost SC11D key-up
	; (focus stolen by a UAC prompt, Suspend toggled mid-press) cannot block the
	; release forever and leave Shift stuck Down.
	if !TapHoldSyntheticKeyDown("LShift")
		return
	try {
		KeyWait("SC11D", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp("LShift")
	}
}
#HotIf







; ===========================================================
; ===========================================================
; ======= 7.4) Generic — hold-modifier, any other tap =======
; ===========================================================
; ===========================================================

; The gate deliberately does NOT require a configured tap action. The tray
; picker offers the hold options independently of the tap, persists the choice
; and puts a checkmark next to it — so requiring a tap here made « Natif / Rien »
; + hold=<modifier> match no variant at all, and the hold the user just picked
; did nothing. A hold must arm on the hold alone, as CapsLock, Space, Escape,
; Enter, Backspace, Delete and Win already do.
#HotIf not _RCtrlIsSpecialTap() and TapHoldHoldModifier(TapHold, "right_ctrl") != "" and not LayerEnabled
$SC11D:: {
	ModKey := _RCtrlHoldModKey()
	HoldGuardMs := TapHoldDuration(TapHold, "right_ctrl") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("right_ctrl", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "RCtrl hold suppressed after long press because wheel activity was detected.")
		return
	}
	if !TapHoldSyntheticKeyDown(ModKey)
		return
	tap := KeyWait("SC11D", "T" . TapHoldDuration(TapHold, "right_ctrl"))
	if tap {
		if !TapHoldSyntheticKeyUp(ModKey)
			return
		_RCtrlDispatch()
		return
	}
	; Bound the wait and release in a finally so a lost key-up or thrown Send can
	; never latch the modifier Down (tap_holds/constants.ahk explains the cap)
	try {
		KeyWait("SC11D", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ========================================================
; ========================================================
; ======= 7.5) Generic — hold-layer, any other tap =======
; ========================================================
; ========================================================

; No tap-action conjunct, for the reason given on block 7.4: a hold must arm on
; the hold alone or the picker offers a choice the driver silently ignores.
#HotIf not _RCtrlIsSpecialTap() and TapHoldHoldLayer(TapHold, "right_ctrl") != "" and not LayerEnabled
$SC11D:: {
	Result := TapHoldOwnImmediateLayer("SC11D", TapHoldDuration(TapHold, "right_ctrl"))
	if (Result["tap"] and A_PriorKey == "RControl")
		_RCtrlDispatch()
}
#HotIf







; ===================================================
; ===================================================
; ======= 7.6) Generic — tap-only (hold=none) =======
; ===================================================
; ===================================================

#HotIf not _RCtrlIsSpecialTap() and TapHoldHoldModifier(TapHold, "right_ctrl") == "" and TapHoldHoldLayer(TapHold, "right_ctrl") == "" and TapHoldTapAction(TapHold, "right_ctrl") != "" and not LayerEnabled
SC11D:: _RCtrlDispatch()
#HotIf







; =================================
; =================================
; ======= 7.7) Tap dispatch =======
; =================================
; =================================

_RCtrlDispatch() {
	_TapHoldFireAction("right_ctrl")
}
