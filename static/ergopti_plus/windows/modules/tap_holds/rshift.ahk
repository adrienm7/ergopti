; modules/tap_holds/rshift.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — RShift
; DESCRIPTION:
; RShift tap-hold: any action from GESTURE_ACTIONS on tap, RShift on hold.
; The OS passthrough (~ prefix) keeps RShift functional during the KeyWait
; window so all Shift+key combinations still reach the OS on hold.
;
; Preserved subtleties:
; - "~$" prefix: passthrough so the physical Shift still reaches the OS
;   during the KeyWait window (e.g. hotkeys that include Shift still fire).
; - A_PriorKey == "RShift" guard: allows firing the tap action for very fast
;   presses that complete under the tap threshold yet still feel intentional,
;   while blocking spurious taps triggered mid-shortcut.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ========================
; ======= 8/ RSHIFT =======
; ========================
; ==============================

; Gate: any configured tap action activates the handler.
; The hold behaviour (Shift staying Shift) is provided by the OS passthrough
; via the ~ prefix — no explicit hold logic is needed here.
#HotIf TapHoldTapAction(TapHold, "right_shift") != "" and not LayerEnabled
~$SC036::
{
	TimeBefore := A_TickCount
	KeyWait("SC036")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "right_shift") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "RShift"
	) { ; A_PriorKey allows fast shortcuts under the tap threshold without triggering the tap action mid-combo
		_RShiftDispatch()
	}
}
#HotIf

; Dispatch the configured tap action for RShift.
_RShiftDispatch() {
	switch TapHoldTapAction(TapHold, "right_shift") {
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
