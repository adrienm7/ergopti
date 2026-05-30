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
$SC15B:: {
	tap := KeyWait("SC15B", "T" . TapHoldDuration(TapHold, "win"))
	if tap {
		if (A_PriorKey == "LWin")
			_WinDispatch()
		return
	}
	ModKey := _WinHoldModKey()
	TextPressKey(ModKey, "Down")
	ih := InputHook("L1 T3")
	ih.Start()
	ih.Wait()
	if (ih.Input != "")
		SendInput("{" . ModKey . " down}" . ih.Input . "{" . ModKey . " up}")
	KeyWait("SC15B", "U T2")
	TextPressKey(ModKey, "Up")
}
#HotIf




; ======= 12.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and not LayerEnabled
$SC15B:: {
	tap := KeyWait("SC15B", "T" . TapHoldDuration(TapHold, "win"))
	if tap {
		if (A_PriorKey == "LWin")
			_WinDispatch()
		return
	}
	ActivateLayer()
	KeyWait("SC15B", "U")
	DisableLayer()
}
#HotIf




; ======= 12.3) Tap-only (hold=none, tap action set) =======

; Fire immediately on key-down — no KeyWait or A_PriorKey guard needed since
; there is no hold behaviour. No ~ needed: Win tap action suppresses Start menu
; by intercepting the key entirely (no passthrough required).
#HotIf TapHoldTapAction(TapHold, "win") != "" and TapHoldHoldModifier(TapHold, "win") == "" and TapHoldHoldLayer(TapHold, "win") == "" and not LayerEnabled
SC15B:: _WinDispatch()
#HotIf




; ======= 12.4) Tap dispatch =======

_WinDispatch() {
	_TapHoldFireAction("win")
}
