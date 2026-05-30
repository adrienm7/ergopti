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

#HotIf TapHoldTapAction(TapHold, "escape") != "" and TapHoldTapAction(TapHold, "escape") != "escape" and TapHoldHoldModifier(TapHold, "escape") == "" and TapHoldHoldLayer(TapHold, "escape") == "" and not LayerEnabled
~$SC001:: {
	TimeBefore := A_TickCount
	KeyWait("SC001")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "escape") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "Escape"
	) {
		_EscapeDispatch()
	}
}
#HotIf




; ======= 11.4) Tap dispatch =======

_EscapeDispatch() {
	local action := TapHoldTapAction(TapHold, "escape")
	if (action == "" or action == "escape") {
		TextPressKey("Escape", [])
		return
	}
	switch action {
		case "alt_tab_monitor":  AltTabMonitor()
		case "backspace":        TextPressKey("BackSpace", [])
		case "caps_lock":        ToggleCapsLock()
		case "caps_word":        ToggleCapsWord()
		case "copy":             TextPressKey("c", ["Ctrl"])
		case "ctrl_backspace":   TextPressKey("BackSpace", ["Ctrl"])
		case "ctrl_delete":      TextPressKey("Delete", ["Ctrl"])
		case "cut":              TextPressKey("x", ["Ctrl"])
		case "delete":           TextPressKey("Delete", [])
		case "enter":            TextPressKey("Enter", [])
		case "find":             TextPressKey("f", ["Ctrl"])
		case "one_shot_shift":   OneShotShift()
		case "paste":            TextPressKey("v", ["Ctrl"])
		case "paste_plain":      GesturePastePlain()
		case "redo":             TextPressKey("y", ["Ctrl"])
		case "select_all":       TextPressKey("a", ["Ctrl"])
		case "space":            TextPressKey("Space", [])
		case "tab":              TextPressKey("Tab", [])
		case "toggle_capslock":  ToggleCapsLock()
		case "undo":             TextPressKey("z", ["Ctrl"])
	}
}
