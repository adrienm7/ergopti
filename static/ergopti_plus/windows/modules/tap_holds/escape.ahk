; modules/tap_holds/escape.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Escape
; DESCRIPTION:
; Escape tap-hold: any action from GESTURE_ACTIONS on tap (default: escape),
; any hold modifier or nav layer on hold. Scancode SC001.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ========================
; ======= 11/ ESCAPE =======
; ========================
; ==============================

; Helper predicates -------------------------------------------------------

_EscapeHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "escape") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 11.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "escape") != "" and not LayerEnabled
~$SC001:: {
	ModKey := _EscapeHoldModKey()
	TextPressKey(ModKey, "Down")
	TimeBefore := A_TickCount
	KeyWait("SC001")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "escape") * 1000)
	TextPressKey(ModKey, "Up")
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "Escape"
	) {
		_EscapeDispatch()
	}
}
#HotIf




; ======= 11.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "escape") != "" and TapHoldHoldModifier(TapHold, "escape") == "" and not LayerEnabled
~$SC001:: {
	UpdateLastSentCharacter("Escape")

	ActivateLayer()
	KeyWait("SC001")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("Escape") ? LastSentCharacterKeyTime["Escape"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "escape") * 1000)
	if (
		tap
		and (Now - CharacterSentTime) >= TapMinDurationMs()
		and A_PriorKey == "Escape"
	) {
		_EscapeDispatch()
	}
}
#HotIf




; ======= 11.3) Tap-only (tap action set to something other than escape) =======

; ~ passes Escape to the OS; $ prevents re-entry. Fire immediately on key-down —
; no KeyWait or A_PriorKey guard needed since there is no hold behaviour.
#HotIf TapHoldTapAction(TapHold, "escape") != "" and TapHoldTapAction(TapHold, "escape") != "escape" and TapHoldHoldModifier(TapHold, "escape") == "" and TapHoldHoldLayer(TapHold, "escape") == "" and not LayerEnabled
~$SC001:: _EscapeDispatch()
#HotIf




; ======= 11.4) Tap dispatch =======

_EscapeDispatch() {
	local action := TapHoldTapAction(TapHold, "escape")
	; No tap configured or tap = escape itself → native key behaviour.
	if (action == "" or action == "escape") {
		TextPressKey("Escape", [])
		return
	}
	_TapHoldFireAction("escape")
}
