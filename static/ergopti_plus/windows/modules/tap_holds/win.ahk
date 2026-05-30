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




; ==============================
; =======================
; ======= 12/ WIN =======
; =======================
; ==============================

; Helper predicates -------------------------------------------------------

_WinHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "win") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 12.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "win") != "" and not LayerEnabled
SC15B:: {
	ModKey := _WinHoldModKey()
	TextPressKey(ModKey, "Down")
	TimeBefore := A_TickCount
	KeyWait("SC15B")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "win") * 1000)
	TextPressKey(ModKey, "Up")
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LWin"
	) {
		_WinDispatch()
	}
}
#HotIf




; ======= 12.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and not LayerEnabled
SC15B:: {
	UpdateLastSentCharacter("LWin")

	ActivateLayer()
	KeyWait("SC15B")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LWin") ? LastSentCharacterKeyTime["LWin"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "win") * 1000)
	if (
		tap
		and (Now - CharacterSentTime) >= TapMinDurationMs()
		and A_PriorKey == "LWin"
	) {
		_WinDispatch()
	}
}
#HotIf




; ======= 12.3) Tap-only (hold=none, tap action set) =======

#HotIf TapHoldTapAction(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and TapHoldHoldLayer(TapHold, "win") == "" and not LayerEnabled
SC15B:: {
	TimeBefore := A_TickCount
	KeyWait("SC15B")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "win") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LWin"
	) {
		_WinDispatch()
	}
}
#HotIf




; ======= 12.4) Tap dispatch =======

_WinDispatch() {
	switch TapHoldTapAction(TapHold, "win") {
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
