; modules/tap_holds/constants.ahk

; ==============================================================================
; MODULE: Tap-Holds — Constants
; DESCRIPTION:
; Shared timing constants for the tap-hold engine. All modules in the
; tap_holds/ group read from these globals rather than embedding literals.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; The tap-hold timing constants below are sourced from the shared cross-driver
; registry (_shared/modules/timings/constants.toml [tap_hold]) by TapHoldsLoadTimings(),
; called once at boot from the auto-execute body. They start at the sentinel 0
; because AHK v2 runs global initializers BEFORE the auto-execute body, so the
; registry is not yet loaded here; the reassign runs well before any tap-hold
; hotkey can fire (those arm only when modules/tap_holds.ahk loads, far later).

; Minimum duration (ms) a tap must last to count as intentional -- filters
; spurious firings when another key is chord-pressed with LShift or LCtrl.
global TAP_MIN_DURATION_MS := 0

; Accessor kept for the call sites in lalt.ahk / rctrl.ahk. The global is always
; assigned (sentinel 0, then the registry value at boot), so this is a thin read.
TapMinDurationMs() {
	global TAP_MIN_DURATION_MS
	return TAP_MIN_DURATION_MS
}

; Initial delay (ms) before key-repeat starts when BackSpace is held on LAlt or RCtrl.
global KEY_REPEAT_INITIAL_DELAY_MS := 0

; Interval (ms) between successive BackSpace repeats while the key stays held.
global KEY_REPEAT_INTERVAL_MS := 0

; Timeout (s) for the OneShotShift InputHook: how long to wait for the next
; character before giving up and leaving the shift state active.
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 0

; Failsafe ceiling (s) on any KeyWait that holds a SYNTHETIC modifier Down while
; waiting for the physical tap-hold key to be released. The arm/release pair is
; guarded by try/finally, but an unbounded wait could still latch the modifier
; forever if the key-up event is lost (focus stolen by a UAC prompt, the global
; Suspend hotkey toggled mid-press, etc.). Capping the wait guarantees the paired
; Up runs within a bounded time so the modifier can never stay stuck. Not a
; tunable behaviour, so it stays a fixed local constant rather than a registry key.
global STUCK_MODIFIER_RELEASE_TIMEOUT_SEC := 5

; Reassign the tap-hold timing constants from the shared registry. Called once
; from the auto-execute body at boot (after TimingsLoadShared(), before any
; tap-hold hotkey arms). Fail-fast: a missing key throws via TimingsGet.
TapHoldsLoadTimings() {
	global TAP_MIN_DURATION_MS, KEY_REPEAT_INITIAL_DELAY_MS
	global KEY_REPEAT_INTERVAL_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC
	TAP_MIN_DURATION_MS         := TimingsGet("tap_hold", "tap_min_duration_ms")
	KEY_REPEAT_INITIAL_DELAY_MS := TimingsGet("tap_hold", "key_repeat_initial_delay_ms")
	KEY_REPEAT_INTERVAL_MS      := TimingsGet("tap_hold", "key_repeat_interval_ms")
	ONE_SHOT_SHIFT_TIMEOUT_SEC  := TimingsGetSec("tap_hold", "one_shot_shift_timeout_ms")
}





; =======================================
; =======================================
; ======= 2/ Generic tap dispatch =======
; =======================================
; =======================================

; Fire the tap action configured for KeyId by delegating to GESTURE_ACTIONS.
; This is the single dispatch point for all simple tap-hold keys — no per-action
; switch needed. capslock.ahk and altgr.ahk keep their own dispatch because they
; require Blind modifiers, UpdateLastSentCharacter, or CtrlActivated wrapping.
_TapHoldFireAction(KeyId) {
	global GESTURE_ACTIONS, TapHold
	ActionId := TapHoldTapAction(TapHold, KeyId)
	if GESTURE_ACTIONS.Has(ActionId) {
		GESTURE_ACTIONS[ActionId].Fn.Call()
	}
}
