; modules/tap_holds/constants.ahk

; ==============================================================================
; MODULE: Tap-Holds — Constants
; DESCRIPTION:
; Shared timing constants for the tap-hold engine. All modules in the
; tap_holds/ group read from these globals rather than embedding literals.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ============================
; ======= 1/ Constants =======
; ============================
; ==============================

; Minimum duration (ms) a tap must last to count as intentional -- filters
; spurious firings when another key is chord-pressed with LShift or LCtrl.
global TAP_MIN_DURATION_MS := 50

; Wrapper required: hotkey bodies may fire (e.g. via timers) before the top-
; level auto-execute has finished, so a direct read of TAP_MIN_DURATION_MS
; would error with "global variable has not been assigned a value".
TapMinDurationMs() {
	global TAP_MIN_DURATION_MS
	return IsSet(TAP_MIN_DURATION_MS) ? TAP_MIN_DURATION_MS : 50
}

; Initial delay (ms) before key-repeat starts when BackSpace is held on LAlt or RCtrl.
global KEY_REPEAT_INITIAL_DELAY_MS := 300

; Interval (ms) between successive BackSpace repeats while the key stays held.
global KEY_REPEAT_INTERVAL_MS := 100

; Timeout (s) for the OneShotShift InputHook: how long to wait for the next
; character before giving up and leaving the shift state active.
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2





; ======================================================
; =======================================
; ======= 2/ Generic tap dispatch =======
; =======================================
; ======================================================

; Fire the tap action configured for KeyId by delegating to GESTURE_ACTIONS.
; This is the single dispatch point for all simple tap-hold keys — no per-action
; switch needed. capslock.ahk and altgr.ahk keep their own dispatch because they
; require Blind modifiers, UpdateLastSentCharacter, or CtrlActivated wrapping.
_TapHoldFireAction(KeyId) {
	global GESTURE_ACTIONS
	ActionId := TapHoldTapAction(TapHold, KeyId)
	if GESTURE_ACTIONS.Has(ActionId) {
		GESTURE_ACTIONS[ActionId].Fn.Call()
	}
}
