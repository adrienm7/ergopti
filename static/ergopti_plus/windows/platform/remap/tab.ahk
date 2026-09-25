; platform/remap/tab.ahk
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





; ======================
; ======================
; ======= 8/ TAB =======
; ======================
; ======================

; Helper predicates -------------------------------------------------------

; A scan-code hotkey on SC00F shadows the `Tab::` acceptance HotIf, and the
; canonical policy only accepts while Tab is physically down. So every tap-hold
; variant offers the press itself to acceptance before any tap/hold resolution;
; otherwise a visible prediction lost to the tap action (llm-tab-taphold-accept).
; @returns {Boolean} True when the press accepted the prediction and is consumed.
_TabAcceptVisiblePrediction() {
	; Cheap gate first, like the `Tab::` HotIf: the policy probes focus, which
	; every ordinary Tab press must not pay for.
	if LLM_Tooltip_GetText() == ""
		return false
	if !LLM_Tooltip_TryAcceptTab(true, [])
		return false
	; Same as the bridge's Tab path: a stale debounce must not re-show a tooltip.
	LLM_Engine_CancelTimer()
	; Swallow auto-repeat: once the tooltip hides, a repeat would fire the tap.
	KeyWait("SC00F", "T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	return true
}

; Return the AHK key name for the configured hold modifier.
_TabHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "tab"), "tab")
}







; ========================================
; ========================================
; ======= 8.1) alt_tab_monitor tap =======
; ========================================
; ========================================

; SC00F::LAlt remap so the OS hold phase sees Alt (enables Alt+Tab switching).
#HotIf TapHoldTapAction(TapHold, "tab") == "alt_tab_monitor" and TapHoldHoldModifier(TapHold, "tab") == "" and TapHoldHoldLayer(TapHold, "tab") == "" and not LayerEnabled
SC00F::LAlt
SC00F::
{
	if _TabAcceptVisiblePrediction()
		return
	if !TapHoldSyntheticKeyDown("LAlt")
		return
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		if TapHoldTapAction(TapHold, "left_alt") == "tab" and KS_IsDown("SC038") { ; LAlt physically held
			TapHoldDispatchTap("tab", TextPressKey.Bind("Tab", "Alt"))
		} else {
			; The synthetic LAlt Down armed above must always be released
			; regardless of Suspend state; only AltTabMonitor()'s side effect
			; is guarded.
			if !TapHoldSyntheticKeyUp("LAlt")
				return
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







; ===========================================================
; ===========================================================
; ======= 8.2) Generic — hold-modifier, any other tap =======
; ===========================================================
; ===========================================================

; The gate deliberately does NOT require a configured tap action. The tray
; picker offers the hold options independently of the tap, persists the choice
; and puts a checkmark next to it — so requiring a tap here made « Natif / Rien »
; + hold=<modifier> match no variant at all, and the hold the user just picked
; did nothing. _TabDispatch below emits the native Tab when no action is
; configured, so the tap keeps working too.
#HotIf TapHoldHoldModifier(TapHold, "tab") != "" and not LayerEnabled
$SC00F:: {
	if _TabAcceptVisiblePrediction()
		return
	Result := TapHoldOwnImmediateModifier("tab", "SC00F",
		_TabHoldModKey(), TapHoldDuration(TapHold, "tab"))
	if Result["tap"]
		_TabDispatch()
}
#HotIf







; ========================================================
; ========================================================
; ======= 8.3) Generic — hold-layer, any other tap =======
; ========================================================
; ========================================================

; No tap-action conjunct, for the reason given on block 8.2: a hold must arm on
; the hold alone or the picker offers a choice the driver silently ignores.
#HotIf TapHoldHoldLayer(TapHold, "tab") != "" and TapHoldHoldModifier(TapHold, "tab") == "" and not LayerEnabled
$SC00F:: {
	if _TabAcceptVisiblePrediction()
		return
	Result := TapHoldOwnImmediateLayer("SC00F", TapHoldDuration(TapHold, "tab"))
	if (Result["tap"] and TapHoldPriorKeyIsSelf("tab"))
		_TabDispatch()
}
#HotIf







; ===================================================
; ===================================================
; ======= 8.4) Generic — tap-only (hold=none) =======
; ===================================================
; ===================================================

#HotIf TapHoldTapAction(TapHold, "tab") != "alt_tab_monitor" and TapHoldHoldModifier(TapHold, "tab") == "" and TapHoldHoldLayer(TapHold, "tab") == "" and TapHoldTapAction(TapHold, "tab") != "" and not LayerEnabled
SC00F:: {
	if _TabAcceptVisiblePrediction()
		return
	_TabDispatch()
}
#HotIf







; =================================
; =================================
; ======= 8.5) Tap dispatch =======
; =================================
; =================================

_TabDispatch() {
	local action := TapHoldTapAction(TapHold, "tab")
	; No tap configured → native key behaviour, exactly as Escape, Enter,
	; Backspace, Delete and Space do. Blocks 8.2/8.3 now arm on the hold alone,
	; so without this branch « Natif / Rien » + hold=<modifier> would replace
	; SC00F with a hotkey that swallows the Tab keystroke entirely instead of
	; passing it through.
	if (action == "") {
		TapHoldDispatchTap("tab", TapHoldEmitKeyTap.Bind("Tab"))
		return
	}
	_TapHoldFireAction("tab")
}
