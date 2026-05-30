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
	switch TapHoldHoldModifier(TapHold, "tab") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 8.1) alt_tab_monitor tap =======

; SC00F::LAlt remap so the OS hold phase sees Alt (enables Alt+Tab switching).
#HotIf TapHoldTapAction(TapHold, "tab") == "alt_tab_monitor" and not LayerEnabled
SC00F::LAlt
SC00F::
{
	TextPressKey("LAlt", "Down")
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		if TapHoldTapAction(TapHold, "left_alt") == "tab" and KS_IsDown("SC038") { ; LAlt physically held
			TextPressKey("Tab", "Alt")
		} else {
			TextPressKey("LAlt", "Up")
			AltTabMonitor()
		}
	}
}
SC00F Up:: TextPressKey("LAlt", "Up")

^SC00F::  TextPressKey("Tab", "Ctrl")
^+SC00F:: TextPressKey("Tab", "Ctrl Shift")
+SC00F::  TextPressKey("Tab", "Shift")
#SC00F::  TextPressKey("Tab", "Win")
#HotIf




; ======= 8.2) Generic — hold-modifier, any other tap =======

#HotIf TapHoldTapAction(TapHold, "tab") != "alt_tab_monitor" and TapHoldHoldModifier(TapHold, "tab") != "" and TapHoldTapAction(TapHold, "tab") != "" and not LayerEnabled
$SC00F:: {
	ModKey := _TabHoldModKey()
	TextPressKey(ModKey, "Down")
	tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
	if tap {
		TextPressKey(ModKey, "Up")
		_TabDispatch()
		return
	}
	KeyWait("SC00F", "U")
	TextPressKey(ModKey, "Up")
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
	ActivateLayer()
	KeyWait("SC00F", "U")
	DisableLayer()
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
