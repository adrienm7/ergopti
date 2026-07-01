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
; - LCtrl: ~ IS used on SC01D so Ctrl+X combos still reach the OS during KeyWait.
;   The AltGr collision (LCtrl+RAlt) is handled upstream by altgr.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ===================================
; ======= 3/ LSHIFT AND LCTRL =======
; ===================================
; ==========================================

; Gate: any configured tap action activates the handler.
; The hold behaviour (Shift staying Shift) is provided by the OS passthrough
; via the ~ prefix — no explicit hold logic is needed here.
#HotIf TapHoldTapAction(TapHold, "left_shift") != "" and not LayerEnabled
~$SC02A::
{
	; Bounded (unlike a bare KeyWait): a lost SC02A key-up (focus stolen by a
	; UAC prompt, Suspend toggled mid-press) can never wedge this hotkey's
	; tap/hold discrimination forever (hold-keywait-whole-class).
	TimeBefore := A_TickCount
	Released := KeyWait("SC02A", "T" . TapHoldDuration(TapHold, "left_shift"))
	TimeAfter := A_TickCount
	tap := Released and ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_shift") * 1000)
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
	_TapHoldFireAction("left_shift")
}







; ======= 3.1) LCtrl =======

; ~$SC01D: ~ passes LCtrl through to the OS during KeyWait so Ctrl+X combos
; still work. $ prevents keyboard-hook re-entry. The AltGr (LCtrl+RAlt) case is
; handled by altgr.ahk which intercepts RAlt before this block fires.
; A_PriorKey == "LControl" guard: blocks the tap when another key was pressed
; during the hold window (combo use), while still allowing intentional taps.
; KS_IsUp guards: prevent spurious tap on CapsLock+LCtrl or LAlt+LCtrl release.
#HotIf TapHoldTapAction(TapHold, "left_ctrl") != "" and not LayerEnabled
~$SC01D::
{
	UpdateLastSentCharacter("LControl")
	; Bounded (unlike a bare KeyWait): a lost SC01D key-up can never wedge
	; this hotkey's tap/hold discrimination forever (hold-keywait-whole-class).
	TimeBefore := A_TickCount
	Released := KeyWait("SC01D", "T" . TapHoldDuration(TapHold, "left_ctrl"))
	TimeAfter := A_TickCount
	tap := Released and ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_ctrl") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "LControl"
		and KS_IsUp("SC03A") ; CapsLock must not be physically held
		and KS_IsUp("SC038") ; LAlt must not be physically held
	) {
		_LCtrlDispatch()
	}
}
#HotIf

; Dispatch the configured tap action for LCtrl.
_LCtrlDispatch() {
	_TapHoldFireAction("left_ctrl")
}
