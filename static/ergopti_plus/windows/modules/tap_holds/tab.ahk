; modules/tap_holds/tab.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Tab
; DESCRIPTION:
; Tab tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier or
; nav layer on hold. Scancode SC00F to intercept the physical Tab key.
;
; Preserved subtleties:
; - SC00F::LAlt remap line: keeps Tab acting as LAlt for the OS hold phase when
;   alt_tab_monitor is the tap action (the hold = Alt pattern).
; - alt_tab_monitor tap: pre-arms LAlt Down so the OS sees Alt held; if LAlt
;   is also remapped to "tab" and physically held, sends Alt+Tab instead.
;   Explicit pass-throughs for ^/+/^+/#SC00F so Ctrl+Tab, Shift+Tab etc. work.
; - Generic hold-modifier: pre-arms the configured modifier, releases on tap.
; - Generic hold-layer: activates nav layer on hold, tap action on release.
; - Generic tap-only (hold=none): fires action immediately on press.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ======================
; ======= 8/ TAB =======
; ======================
; ==============================

; Helper predicates -------------------------------------------------------

; Return the AHK key name for the configured hold modifier.
_TabHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "tab"), "tab")
}







; ======= 8.1) alt_tab_monitor tap =======

; SC00F::LAlt remap so the OS hold phase sees Alt (enables Alt+Tab switching).
#HotIf TapHoldTapAction(TapHold, "tab") == "alt_tab_monitor" and not LayerEnabled
SC00F::LAlt
SC00F::
{
	TapHoldSyntheticKeyDown("LAlt")
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		if TapHoldTapAction(TapHold, "left_alt") == "tab" and KS_IsDown("SC038") { ; LAlt physically held
			TapHoldDispatchTap("tab", TextPressKey.Bind("Tab", "Alt"))
		} else {
			; The synthetic LAlt Down armed above must always be released
			; regardless of Suspend state; only AltTabMonitor()'s side effect
			; is guarded.
			TapHoldSyntheticKeyUp("LAlt")
			TapHoldDispatchTap("tab", AltTabMonitor)
		}
	} else {
		; Held past the tap window: the native Alt+Tab switcher stays up via the
		; synthetic LAlt Down. Bound the wait and release in a finally so a lost
		; SC00F key-up (Suspend toggled mid-hold disarms the SC00F Up:: fallback)
		; can never latch Alt Down system-wide (hold-modifier-unbounded-keywait)
		try {
			KeyWait("SC00F", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
		} finally {
			TapHoldSyntheticKeyUp("LAlt")
		}
	}
}
SC00F Up:: TapHoldSyntheticKeyUp("LAlt")

^SC00F::  TextPressKey("Tab", "Ctrl")
^+SC00F:: TextPressKey("Tab", "Ctrl Shift")
+SC00F::  TextPressKey("Tab", "Shift")
#SC00F::  TextPressKey("Tab", "Win")
#HotIf







; ======= 8.2) Generic — hold-modifier, any other tap =======

#HotIf TapHoldTapAction(TapHold, "tab") != "alt_tab_monitor" and TapHoldHoldModifier(TapHold, "tab") != "" and TapHoldTapAction(TapHold, "tab") != "" and not LayerEnabled
$SC00F:: {
	ModKey := _TabHoldModKey()
	HoldGuardMs := TapHoldDuration(TapHold, "tab") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("tab", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Tab hold suppressed after long press because wheel activity was detected.")
		return
	}
	TapHoldSyntheticKeyDown(ModKey)
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		TapHoldSyntheticKeyUp(ModKey)
		_TabDispatch()
		return
	}
	try {
		KeyWait("SC00F", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 8.3) Generic — hold-layer, any other tap =======

#HotIf TapHoldTapAction(TapHold, "tab") != "alt_tab_monitor" and TapHoldHoldLayer(TapHold, "tab") != "" and TapHoldTapAction(TapHold, "tab") != "" and not LayerEnabled
$SC00F:: {
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		if (A_PriorKey == "Tab")
			_TabDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "tab") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("tab", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Tab layer hold suppressed before activation because wheel activity was detected.")
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
		while !KeyWait("SC00F", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("SC00F", "P")
				break
		}
	} finally {
		DisableLayer()
	}
}
#HotIf







; ======= 8.4) Generic — tap-only (hold=none) =======

#HotIf TapHoldTapAction(TapHold, "tab") != "alt_tab_monitor" and TapHoldHoldModifier(TapHold, "tab") == "" and TapHoldHoldLayer(TapHold, "tab") == "" and TapHoldTapAction(TapHold, "tab") != "" and not LayerEnabled
SC00F:: _TabDispatch()
#HotIf







; ======= 8.5) Tap dispatch =======

_TabDispatch() {
	_TapHoldFireAction("tab")
}
