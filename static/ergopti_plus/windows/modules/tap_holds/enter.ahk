; modules/tap_holds/enter.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Enter
; DESCRIPTION:
; Enter tap-hold: any action from GESTURE_ACTIONS on tap (default: enter),
; any hold modifier or nav layer on hold. Scancode SC01C.
;
; Architecture mirrors lshift_lctrl: ~$ prefix so Enter still reaches the OS
; during KeyWait (Shift+Enter, Ctrl+Enter etc. keep working). The tap action
; defaults to sending Enter when the key is unconfigured.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ========================
; ======= 9/ ENTER =======
; ========================
; ==============================

; Helper predicates -------------------------------------------------------

_EnterHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "enter") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 9.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "enter") != "" and not LayerEnabled
$SC01C:: {
	ModKey := _EnterHoldModKey()
	TextPressKey(ModKey, "Down")
	TimeBefore := A_TickCount
	KeyWait("SC01C")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "enter") * 1000)
	TextPressKey(ModKey, "Up")
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "Enter"
	) {
		_EnterDispatch()
	}
}
#HotIf




; ======= 9.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "enter") != "" and TapHoldHoldModifier(TapHold, "enter") == "" and not LayerEnabled
$SC01C:: {
	UpdateLastSentCharacter("Enter")

	ActivateLayer()
	KeyWait("SC01C")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("Enter") ? LastSentCharacterKeyTime["Enter"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "enter") * 1000)
	if (
		tap
		and (Now - CharacterSentTime) >= TapMinDurationMs()
		and A_PriorKey == "Enter"
	) {
		_EnterDispatch()
	}
}
#HotIf




; ======= 9.3) Tap-only (hold=none, tap action set) =======

; ~ passes Enter to the OS; $ prevents re-entry. Fire immediately on key-down —
; no KeyWait or A_PriorKey guard needed since there is no hold behaviour.
#HotIf TapHoldTapAction(TapHold, "enter") != "" and TapHoldTapAction(TapHold, "enter") != "enter" and TapHoldHoldModifier(TapHold, "enter") == "" and TapHoldHoldLayer(TapHold, "enter") == "" and not LayerEnabled
~$SC01C:: _EnterDispatch()
#HotIf




; ======= 9.4) Tap dispatch =======

_EnterDispatch() {
	local action := TapHoldTapAction(TapHold, "enter")
	; No tap configured or tap = enter itself → native key behaviour.
	if (action == "" or action == "enter") {
		TextPressKey("Enter", [])
		return
	}
	_TapHoldFireAction("enter")
}
