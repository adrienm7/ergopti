; modules/tap_holds/lshift_lctrl.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — LShift and LCtrl
; DESCRIPTION:
; LShift tap-hold (configurable action on tap / shift on hold) and LCtrl
; tap-hold (configurable action on tap / ctrl on hold). The tap action is
; freely selectable from GESTURE_ACTIONS via the tray menu picker.
;
; Preserved subtleties:
; - "~$" prefix: passthrough so the physical Shift/Ctrl still reaches the OS
;   during the KeyWait window (e.g. hotkeys that include Shift/Ctrl still fire).
; - A_PriorKey == "LShift"/"LControl" guard: allows firing the tap action for
;   very fast presses that complete under the tap threshold yet still feel
;   intentional, while blocking spurious taps triggered mid-shortcut.
; - LCtrl: KS_IsUp("SC03A") and KS_IsUp("SC038") guards prevent a spurious
;   paste when CapsLock+LCtrl or LAlt+LCtrl combinations are released.
; - LCtrl: UpdateLastSentCharacter("LControl") keeps the hotstring engine in
;   sync with the physical key stream.
; - LCtrl: ~ must NOT be used on SC01D — see the comment below.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 3/ LSHIFT AND LCTRL =======
; ==========================================
; ==========================================

; Gate: any configured tap action activates the handler.
; The hold behaviour (Shift staying Shift) is provided by the OS passthrough
; via the ~ prefix — no explicit hold logic is needed here.
#HotIf TapHoldTapAction(TapHold, "left_shift") != "" and not LayerEnabled
~$SC02A::
{
	TimeBefore := A_TickCount
	KeyWait("SC02A")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_shift") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LShift"
	) { ; A_PriorKey allows fast shortcuts under the tap threshold without triggering the tap action mid-combo
		_LShiftDispatch()
	}
}
#HotIf

; Dispatch the configured tap action for LShift.
_LShiftDispatch() {
	switch TapHoldTapAction(TapHold, "left_shift") {
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




; ======= 3.1) LCtrl =======

; ~ must NOT be used here — with ~SC01D, a sequence of [AltGr] presses
; (which AHK sees as LCtrl+RAlt) would suddenly block and keep LCtrl latched.
; The $ prefix suppresses keyboard-hook re-entry, preventing infinite loops.
#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and not LayerEnabled
$SC01D::
{
	UpdateLastSentCharacter("LControl")
	TimeBefore := A_TickCount
	KeyWait("SC01D")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_ctrl") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LControl"
		and KS_IsUp("SC03A") ; "CapsLock" must not be physically held
		and KS_IsUp("SC038") ; "LAlt" must not be physically held
	) {
		_LCtrlDispatch()
	}
}
#HotIf

; Dispatch the configured tap action for LCtrl.
_LCtrlDispatch() {
	switch TapHoldTapAction(TapHold, "left_ctrl") {
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
