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
; called once at boot from lib/boot.ahk. They start at the sentinel 0 only as a
; declaration placeholder. IMPORTANT: AHK v2 executes a file's top-level
; `global X := ...` assignments at its #Include POSITION in the auto-execute flow,
; NOT before it -- so this file MUST be included before lib/boot.ahk (ErgoptiPlus.ahk
; does this explicitly in the early include manifest), otherwise these sentinel 0s
; would run AFTER TapHoldsLoadTimings() and re-zero the loaded values on every boot.

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
; Synthetic modifiers armed before a KeyWait must be released immediately when
; Suspend occurs. Native Suspend disarms the next hotkey but does not stop the
; already-running KeyWait pseudo-thread, so its normal finally can be seconds
; too late and the synthetic modifier would alter physical input while paused.
global _TH_SyntheticHeldKeys := Map()
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
global _TH_LastTapHoldCancelReason := ""

; Register a key-down as "potential tap-hold candidate". The key is tracked with
; a per-key canceled-by-activity flag so that a wheel, another key, or a mouse
; button used while it is held cancels the eventual tap emission on release.
TapHoldTrackKeyDownByScancode(vk, sc) {
	global _TH_TapHoldTrackState, _TH_TapHoldScToKeyId, _TH_TapHoldVkToKeyId
	keyId := TapHoldResolveKeyIdFromVkSc(vk, sc)
	if (keyId == "")
		return
	now := A_TickCount
	wasAlreadyDown := false
	if !_TH_TapHoldTrackState.Has(keyId) {
		_TH_TapHoldTrackState[keyId] := Map(
			"down", false,
			"down_at", 0,
			"canceled_by_activity", false,
			"canceled_by_scroll", false,
			"cancel_reason", "",
			"last_vk", 0,
			"last_sc", 0,
			"last_seen", 0
		)
	}
	state := _TH_TapHoldTrackState[keyId]
	wasAlreadyDown := state["down"]
	state["down"] := true
	; InputHook can report repeated key-down notifications while a key is held.
	; They belong to the same physical tap-hold gesture: do not clear a wheel,
	; chord, or mouse cancellation that was recorded between the first down and
	; the eventual release.
	if !wasAlreadyDown {
		state["down_at"] := now
		state["canceled_by_activity"] := false
		state["canceled_by_scroll"] := false
		state["cancel_reason"] := ""
	}
	state["last_vk"] := vk
	state["last_sc"] := sc
	state["last_seen"] := now
	if LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldTrack", "Key down tracked for tap-hold: key='{1}', vk=0x{2:X}, sc={3}, tick={4}, was_already_down={5}.",
			keyId, vk, sc, now, wasAlreadyDown ? "true" : "false")
	}
}

; Mark every currently held tap-hold key except the key that caused the event.
; This is the generic activity boundary for tap-hold disambiguation: Ctrl+C,
; Ctrl+V, Ctrl+wheel, and mouse activity must all prevent Ctrl's tap action
; from firing when Ctrl is released.
TapHoldTrackActivityCancel(ExceptKeyId := "", Reason := "other input") {
	global _TH_TapHoldTrackState
	for keyId, state in _TH_TapHoldTrackState {
		if (state.Has("down") and state["down"] and keyId != ExceptKeyId) {
			state["canceled_by_activity"] := true
			state["cancel_reason"] := Reason
		}
	}
}

; A keyboard activity event cancels other held tap-holds, but never cancels the
; tap-hold key's own initial/repeated key-down event.
TapHoldTrackOtherKeyActivityByScancode(vk, sc) {
	keyId := TapHoldResolveKeyIdFromVkSc(vk, sc)
	TapHoldTrackActivityCancel(keyId, "another key during hold")
}

; Clear the track flag on key release. State is kept until dispatch so
; _TapHoldFireAction can still read a cancellation decision even
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
		LoggerDebug("TapHoldTrack", "Key up tracked for tap-hold: key='{1}', canceled_by_activity={2}, reason='{3}', tick={4}.",
			keyId, state.Has("canceled_by_activity") && state["canceled_by_activity"] ? "true" : "false",
			state.Has("cancel_reason") ? state["cancel_reason"] : "", state["up_at"])
	}
}

; Cancel all currently held tap-hold keys when a wheel event occurs. Keep the
; wheel-specific field for diagnostics/backward compatibility, while the shared
; activity flag is what prevents the tap dispatch.
TapHoldTrackScrollCancel() {
	global _TH_TapHoldTrackState, _TH_LastTapHoldWheelCancelTick
	_TH_LastTapHoldWheelCancelTick := A_TickCount
	active := 0
	activeList := ""
	for keyId, state in _TH_TapHoldTrackState {
		if (state.Has("down") and state["down"]) {
			state["canceled_by_activity"] := true
			state["canceled_by_scroll"] := true
			state["cancel_reason"] := "wheel/trackpad during hold"
			active++
			activeList .= (active = 1 ? "" : ", ") . keyId
		}
	}
	if LoggerIsDebugEnabled() {
		if (active > 0) {
			LoggerDebug("TapHoldTrack", "Wheel canceled {1} held tap-hold key(s), tick={2}.", active, _TH_LastTapHoldWheelCancelTick)
			LoggerDebug("TapHoldTrack", "Wheel-cancelled key list: {1}.", activeList)
		} else {
			LoggerDebug("TapHoldTrack", "Wheel seen without active held tap-hold key, tick={1}.", _TH_LastTapHoldWheelCancelTick)
		}
	}
}

; Return the cancellation reason for this tap dispatch, or "" when dispatch is allowed.
; Keeping the reason as a return value lets us avoid ByRef quirks in AHK v2 and
; keeps all call sites compatible with debug logging.
TapHoldShouldCancelTap(KeyId, GuardMs := 250) {
	global _TH_TapHoldTrackState, _TH_LastTapHoldCancelReason
	_TH_LastTapHoldCancelReason := ""
	state := false
	if (_TH_TapHoldTrackState.Has(KeyId)) {
		state := _TH_TapHoldTrackState[KeyId]
		if (state.Has("canceled_by_activity") && state["canceled_by_activity"]) {
			CancelReason := state.Has("cancel_reason") && state["cancel_reason"] != ""
				? state["cancel_reason"]
				: "other input during key hold"
			_TH_LastTapHoldCancelReason := CancelReason
			if LoggerIsDebugEnabled() {
				LoggerDebug("TapHoldTrack", "Tap canceled for '{1}' because key was already marked canceled while held.", KeyId)
			}
			return CancelReason
		}
	}
	; The timestamp fallback is scoped to this physical press. A global
	; "wheel happened recently" check suppressed valid isolated taps performed
	; just after scrolling; only wheel activity at/after down_at is interruptive.
	if (state is Map
		and state.Has("down_at")
		and HookDispatcher.WasWheelSince(state["down_at"], GuardMs)) {
		CancelReason := "wheel activity within " . GuardMs . "ms"
		_TH_LastTapHoldCancelReason := CancelReason
		if LoggerIsDebugEnabled() {
			LoggerDebug("TapHoldTrack", "Tap canceled for '{1}' due to recent wheel activity (guard={2}ms).", KeyId, GuardMs)
		}
		return CancelReason
	}
	; Keep an explicit debug breadcrumb for no-cancel paths when detailed logs are on.
	if LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldTrack", "No tap cancel needed for '{1}' (guard={2}ms).", KeyId, GuardMs)
	}
	return ""
}

; Return true when a hold gesture should be blocked after the user has already
; held the key. This is a hold-specific wrapper over TapHoldShouldCancelTap()
; that keeps all cancel reasons and debug trail in one place.
TapHoldShouldSuppressHold(KeyId, GuardMs := 250) {
	global _TH_LastTapHoldCancelReason
	CancelReason := TapHoldShouldCancelTap(KeyId, GuardMs)
	; A KeyWait started before Suspend keeps its pseudo-thread alive even though
	; native Suspend disarms the hotkey that started it.  Every generic
	; hold-modifier branch calls this helper immediately before injecting its
	; synthetic modifier, so make the suspension transition an explicit
	; cancellation reason here rather than allowing a stale candidate to arm a
	; modifier after the driver has promised to be inert.
	if A_IsSuspended {
		_TH_LastTapHoldCancelReason := "driver suspended during hold"
		try LoggerDebug("TapHoldTrack", "Hold suppressed for '{1}' because the driver was suspended during its KeyWait.", KeyId)
		return true
	}
	if (CancelReason != "") {
		try LoggerDebug("TapHoldTrack", "Hold suppressed for '{1}' ({2}, guard={3}ms).", KeyId, CancelReason, GuardMs)
		return true
	}
	return false
}

; Acquire/release synthetic keys whose lifetime crosses a KeyWait. Reference
; counting keeps independently overlapping tap-hold branches from releasing a
; key another branch still owns; the physical Send happens only on the 0->1 and
; 1->0 transitions.
TapHoldSyntheticKeyDown(Key) {
	global _TH_SyntheticHeldKeys
	if A_IsSuspended {
		try LoggerDebug("TapHoldDispatch", "Not arming synthetic '{1}' while the driver is suspended.", Key)
		return false
	}
	Count := _TH_SyntheticHeldKeys.Has(Key) ? _TH_SyntheticHeldKeys[Key] : 0
	_TH_SyntheticHeldKeys[Key] := Count + 1
	if (Count = 0)
		TextPressKey(Key, "Down")
	return true
}

TapHoldSyntheticKeyUp(Key) {
	global _TH_SyntheticHeldKeys
	if !_TH_SyntheticHeldKeys.Has(Key) {
		; A suspend cleanup (TapHoldReleaseSyntheticKeys) may already have released the
		; key. Never inject a synthetic Up while suspended (« pause = tout éteint ») — it
		; would land in a paused session and could clear a modifier the user is
		; physically holding. Only re-balance an untracked key while the driver is live.
		if A_IsSuspended {
			try LoggerDebug("TapHoldDispatch", "Not releasing untracked synthetic '{1}' while the driver is suspended.", Key)
			return true
		}
		; Keep the ordinary finally path idempotent so it can still balance any direct
		; Send failure for a key that was armed but somehow lost from the map.
		TextPressKey(Key, "Up")
		return true
	}
	Count := _TH_SyntheticHeldKeys[Key] - 1
	if (Count > 0) {
		_TH_SyntheticHeldKeys[Key] := Count
		return true
	}
	_TH_SyntheticHeldKeys.Delete(Key)
	TextPressKey(Key, "Up")
	return true
}

TapHoldReleaseSyntheticKeys() {
	global _TH_SyntheticHeldKeys
	Keys := []
	for Key in _TH_SyntheticHeldKeys
		Keys.Push(Key)
	_TH_SyntheticHeldKeys := Map()
	for Key in Keys {
		try TextPressKey(Key, "Up")
	}
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

; Run any tap output through the single activity/suspend gate, then consume the
; tracked physical press. Native taps (Space, Enter, Backspace, Escape, Delete)
; must use this helper too; otherwise only GESTURE_ACTIONS-based taps are safe.
; @param KeyId {String} Canonical tap-hold key id.
; @param TapFn {Func} Zero-argument callback that emits the tap output.
; @return {Boolean} True when TapFn ran, false when the tap was suppressed.
TapHoldDispatchTap(KeyId, TapFn) {
	global TapHold
	try {
		if A_IsSuspended {
			try LoggerDebug("TapHoldDispatch", "Dispatch blocked for '{1}' because script is suspended.", KeyId)
			return false
		}
		LimitMs := TapHoldDuration(TapHold, KeyId) * 1100
		if (LimitMs < 250)
			LimitMs := 250
		CancelReason := TapHoldShouldCancelTap(KeyId, LimitMs)
		if (CancelReason != "") {
			try LoggerDebug("TapHoldDispatch", "Dispatch blocked for '{1}' ({2}, guard={3}ms).", KeyId, CancelReason, LimitMs)
			return false
		}
		; CapsWord ends on a word terminator, and capsword.ahk arms its own
		; `#HotIf CapsWordEnabled` Space/Enter hotkeys to do it. Those lose:
		; both variants' criteria are true at once, and this repo's own pinned
		; precedence is that the most-recently-DEFINED variant wins —
		; modules/tap_holds.ahk is included after modules/shortcuts.ahk, so the
		; tap-hold variant fires and the unlatch hotkey never runs. CapsWord then
		; survived the space and kept capitalising the following word.
		;
		; Unlatching here rather than in the two key modules keeps one owner for
		; the rule and covers every tap-hold variant that may later bind these
		; keys. DisableCapsWord is a no-op when CapsWord is inactive.
		if _TapHoldTapEndsCapsWord(KeyId)
			DisableCapsWord()
		TapFn.Call()
		return true
	}
	finally {
		TapHoldForgetTrackedKey(KeyId)
	}
}

; Tap-hold keys whose tap output is a word terminator, and therefore ends
; CapsWord. Mirrors the keys capsword.ahk binds for the same purpose; anything
; else (Backspace, Escape, Delete, CapsLock…) leaves CapsWord latched, which is
; what makes it usable for a whole word.
global TAP_HOLD_CAPSWORD_TERMINATORS := Map("space", true, "enter", true)

_TapHoldTapEndsCapsWord(KeyId) {
	global TAP_HOLD_CAPSWORD_TERMINATORS
	if !TAP_HOLD_CAPSWORD_TERMINATORS.Has(KeyId)
		return false
	; IsSet-guarded: the tap-hold layer is reachable in contexts where
	; shortcuts/capsword.ahk is not loaded (standalone tests, tools).
	return IsSet(CapsWordEnabled) and CapsWordEnabled and IsSet(DisableCapsWord)
}

; Invoke the configured GESTURE_ACTIONS callback without applying guards. This
; is deliberately separate so special native wrappers (CapsLock, etc.) can run
; their complete output atomically inside TapHoldDispatchTap().
_TapHoldInvokeConfiguredAction(KeyId) {
	global GESTURE_ACTIONS, TapHold
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
	GestureInvokeAction(ActionId, GestureBindingId("tap_hold", KeyId))
}

; Fire the configured generic tap action through the shared gate.
_TapHoldFireAction(KeyId) {
	return TapHoldDispatchTap(KeyId, _TapHoldInvokeConfiguredAction.Bind(KeyId))
}
