; platform/remap/rshift.ahk
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





; ==========================
; ==========================
; ======= 14/ RSHIFT =======
; ==========================
; ==========================

; Gate: any configured tap action activates the handler.
; The hold behaviour (Shift staying Shift) is provided by the OS passthrough
; via the ~ prefix — no explicit hold logic is needed here.
#HotIf TapHoldTapAction(TapHold, "right_shift") != "" and not LayerEnabled
~$SC036::
{
	; Bounded (unlike a bare KeyWait): a lost SC036 key-up can never wedge
	; this hotkey's tap/hold discrimination forever (hold-keywait-whole-class).
	TimeBefore := A_TickCount
	Released := KeyWait("SC036", "T" . TapHoldDuration(TapHold, "right_shift"))
	TimeAfter := A_TickCount
	tap := Released and ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "right_shift") * 1000)
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
	_TapHoldFireAction("right_shift")
}
