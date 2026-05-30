; modules/tap_holds/backspace.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Backspace
; DESCRIPTION:
; Backspace tap-hold: any action from GESTURE_ACTIONS on tap (default:
; backspace), any hold modifier or nav layer on hold. Scancode SC00E.
;
; Note: the physical Backspace key is also used by CapsLock and LAlt modules
; as their tap output — those are output actions, not remappings of the
; physical Backspace key. This module remaps the physical Backspace key itself.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ============================
; ======= 10/ BACKSPACE =======
; ============================
; ==============================

; Helper predicates -------------------------------------------------------

_BackspaceHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "backspace") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 10.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "backspace") != "" and not LayerEnabled
~$SC00E:: {
	ModKey := _BackspaceHoldModKey()
	TextPressKey(ModKey, "Down")
	TimeBefore := A_TickCount
	KeyWait("SC00E")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "backspace") * 1000)
	TextPressKey(ModKey, "Up")
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "BackSpace"
	) {
		_BackspaceDispatch()
	}
}
#HotIf




; ======= 10.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "backspace") != "" and TapHoldHoldModifier(TapHold, "backspace") == "" and not LayerEnabled
~$SC00E:: {
	UpdateLastSentCharacter("BackSpace")

	ActivateLayer()
	KeyWait("SC00E")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("BackSpace") ? LastSentCharacterKeyTime["BackSpace"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "backspace") * 1000)
	if (
		tap
		and (Now - CharacterSentTime) >= TapMinDurationMs()
		and A_PriorKey == "BackSpace"
	) {
		_BackspaceDispatch()
	}
}
#HotIf




; ======= 10.3) Tap-only (tap action set to something other than backspace) =======

#HotIf TapHoldTapAction(TapHold, "backspace") != "" and TapHoldTapAction(TapHold, "backspace") != "backspace" and TapHoldHoldModifier(TapHold, "backspace") == "" and TapHoldHoldLayer(TapHold, "backspace") == "" and not LayerEnabled
~$SC00E:: {
	TimeBefore := A_TickCount
	KeyWait("SC00E")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "backspace") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "BackSpace"
	) {
		_BackspaceDispatch()
	}
}
#HotIf




; ======= 10.4) Tap dispatch =======

_BackspaceDispatch() {
	local action := TapHoldTapAction(TapHold, "backspace")
	if (action == "" or action == "backspace") {
		TextPressKey("BackSpace", [])
		return
	}
	switch action {
		case "alt_tab_monitor":  AltTabMonitor()
		case "caps_lock":        ToggleCapsLock()
		case "caps_word":        ToggleCapsWord()
		case "copy":             TextPressKey("c", ["Ctrl"])
		case "ctrl_backspace":   TextPressKey("BackSpace", ["Ctrl"])
		case "ctrl_delete":      TextPressKey("Delete", ["Ctrl"])
		case "cut":              TextPressKey("x", ["Ctrl"])
		case "delete":           TextPressKey("Delete", [])
		case "enter":            TextPressKey("Enter", [])
		case "escape":           TextPressKey("Escape", [])
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
