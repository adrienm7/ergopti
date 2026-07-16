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

; Track-tap-hold key state so a wheel/trackpad event can cancel a tap action.
; Key map intentionally only includes tap-hold keys exposed by Ergopti+.
global _TH_TapHoldTrackState := Map()
global _TH_TapHoldVkToKeyId := Map(
	0x1B, "escape",
	0x09, "tab",
	0x14, "caps_lock",
	0xA0, "left_shift",
	0xA2, "left_ctrl",
	0x5B, "win",
	0xA4, "left_alt",
	0x20, "space",
	0xA5, "alt_gr",
	0xA3, "right_ctrl",
	0xA1, "right_shift",
	0x0D, "enter",
	0x08, "backspace",
	0x2E, "delete"
)
global _TH_TapHoldScToKeyId := Map(
	0x001, "escape",
	0x00F, "tab",
	0x03A, "caps_lock",
	0x01D, "left_ctrl",
	0x2A, "left_shift",
	0x15B, "win",
	0x038, "left_alt",
	0x039, "space",
	0x138, "alt_gr",
	0x11D, "right_ctrl",
	0x036, "right_shift",
	0x01C, "enter",
	0x00E, "backspace",
	0x153, "delete",
	0x11D, "right_ctrl",
	0x036, "right_shift"
)



; Remember the latest wheel cancellation tick so we can expose the reason and
; keep a deterministic debug trail.
global _TH_LastTapHoldWheelCancelTick := 0

; Register a key-down as "potential tap-hold candidate". The key is tracked with
; a per-key canceled-by-scroll flag so that scrolls while it is held cancel the
; eventual tap emission on release.
TapHoldTrackKeyDownByScancode(vk, sc) {
	global _TH_TapHoldTrackState, _TH_TapHoldScToKeyId, _TH_TapHoldVkToKeyId
	keyId := TapHoldResolveKeyIdFromVkSc(vk, sc)
	if (keyId == "")
		return
	now := A_TickCount
	if !_TH_TapHoldTrackState.Has(keyId) {
		_TH_TapHoldTrackState[keyId] := Map(
			"down", false,
			"down_at", 0,
			"canceled_by_scroll", false,
			"last_vk", 0,
			"last_sc", 0,
			"last_seen", 0
		)
	}
	state := _TH_TapHoldTrackState[keyId]
	state["down"] := true
	state["down_at"] := now
	state["canceled_by_scroll"] := false
	state["last_vk"] := vk
	state["last_sc"] := sc
	state["last_seen"] := now
	if LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldTrack", "Key down tracked for tap-hold: key='{1}', vk=0x{2:X}, sc={3}, tick={4}.",
			keyId, vk, sc, now)
	}
}

; Clear the track flag on key release. State is kept until dispatch so
; _TapHoldFireAction can still read a "canceled_by_scroll" decision even
; for modules that dispatch after KeyWait completes.
TapHoldTrackKeyUpByScancode(vk, sc) {
	global _TH_TapHoldTrackState, _TH_TapHoldScToKeyId, _TH_TapHoldVkToKeyId
	keyId := TapHoldResolveKeyIdFromVkSc(vk, sc)
	if (keyId == "" || !_TH_TapHoldTrackState.Has(keyId))
		return
	state := _TH_TapHoldTrackState[keyId]
	state["down"] := false
	state["up_at"] := A_TickCount
	if LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldTrack", "Key up tracked for tap-hold: key='{1}', canceled_by_scroll={2}, tick={3}.",
			keyId, state["canceled_by_scroll"] ? "true" : "false", state["up_at"])
	}
}

; Cancel all currently held tap-hold keys when a wheel event occurs.
TapHoldTrackScrollCancel() {
	global _TH_TapHoldTrackState, _TH_LastTapHoldWheelCancelTick
	_TH_LastTapHoldWheelCancelTick := A_TickCount
	active := 0
	for keyId, state in _TH_TapHoldTrackState {
		if (state.Has("down") and state["down"]) {
			state["canceled_by_scroll"] := true
			active++
		}
	}
	if LoggerIsDebugEnabled() {
		if (active > 0) {
			LoggerDebug("TapHoldTrack", "Wheel canceled {1} held tap-hold key(s), tick={2}.", active, _TH_LastTapHoldWheelCancelTick)
		} else {
			LoggerDebug("TapHoldTrack", "Wheel seen without active held tap-hold key, tick={1}.", _TH_LastTapHoldWheelCancelTick)
		}
	}
}

; Return true when this tap dispatch should be suppressed. Reasons are written
; to CancelReason for traceability in debug logs.
TapHoldShouldCancelTap(KeyId, GuardMs := 250, ByRef CancelReason := "") {
	global _TH_TapHoldTrackState
	CancelReason := ""
	if (_TH_TapHoldTrackState.Has(KeyId)) {
		state := _TH_TapHoldTrackState[KeyId]
		if (state.Has("canceled_by_scroll") && state["canceled_by_scroll"]) {
			CancelReason := "trackpad/wheel during key hold"
			return true
		}
	}
	if HookDispatcher.WasWheelRecently(GuardMs) {
		CancelReason := "wheel activity within " . GuardMs . "ms"
		return true
	}
	return false
}

; Remove tracked state for a key once tap resolution has completed.
TapHoldForgetTrackedKey(KeyId) {
	global _TH_TapHoldTrackState
	if _TH_TapHoldTrackState.Has(KeyId) {
		_TH_TapHoldTrackState.Delete(KeyId)
		if LoggerIsDebugEnabled() {
			LoggerDebug("TapHoldTrack", "Track state forgotten for key='{1}'.", KeyId)
		}
	}
}

; Resolve a key id from raw key event fields.
TapHoldResolveKeyIdFromVkSc(vk, sc) {
	global _TH_TapHoldVkToKeyId, _TH_TapHoldScToKeyId
	if _TH_TapHoldScToKeyId.Has(sc)
		return _TH_TapHoldScToKeyId[sc]
	if _TH_TapHoldVkToKeyId.Has(vk)
		return _TH_TapHoldVkToKeyId[vk]
	return ""
}

; Fire the tap action configured for KeyId by delegating to GESTURE_ACTIONS.
; This is the single dispatch point for all simple tap-hold keys — no per-action
; switch needed. capslock.ahk and altgr.ahk keep their own dispatch because they
; require Blind modifiers, UpdateLastSentCharacter, or CtrlActivated wrapping.
_TapHoldFireAction(KeyId) {
	global GESTURE_ACTIONS, TapHold
	; Native Suspend() only disarms Hotkeys/Hotstrings, never a tap's dispatch
	; call itself — a key release landing inside the tap threshold shortly
	; after a pause toggle must not fire a configured action (script_reload,
	; open_url, take_note, …) while « pause = tout éteint ».
	try {
		if A_IsSuspended {
			try LoggerDebug("TapHoldDispatch", "Dispatch blocked for '{1}' because script is suspended.", KeyId)
			return
		}
		LimitMs := TapHoldDuration(TapHold, KeyId) * 1100
		if (LimitMs < 250)
			LimitMs := 250
		CancelReason := ""
		if (TapHoldShouldCancelTap(KeyId, LimitMs, CancelReason)) {
			try LoggerDebug("TapHoldDispatch", "Dispatch blocked for '{1}' ({2}, guard={3}ms).", KeyId, CancelReason, LimitMs)
			return
		}
		ActionId := TapHoldTapAction(TapHold, KeyId)
		if (ActionId == "") {
			try LoggerDebug("TapHoldDispatch", "No tap action configured for '{1}' (native pass-through).", KeyId)
			return
		}
		if !GESTURE_ACTIONS.Has(ActionId) {
			try LoggerWarn("TapHoldDispatch", "Missing tap action '{1}' for '{2}'.", ActionId, KeyId)
			return
		}
		try LoggerDebug("TapHoldDispatch", "Dispatching tap action '{1}' for '{2}'.", ActionId, KeyId)
		GESTURE_ACTIONS[ActionId].Fn.Call()
	}
	finally {
		TapHoldForgetTrackedKey(KeyId)
	}
}
