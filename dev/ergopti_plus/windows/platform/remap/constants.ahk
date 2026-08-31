; platform/remap/constants.ahk

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
; called once at boot from infra/boot.ahk. They start at the sentinel 0 only as a
; declaration placeholder. IMPORTANT: AHK v2 executes a file's top-level
; `global X := ...` assignments at its #Include POSITION in the auto-execute flow,
; NOT before it -- so this file MUST be included before infra/boot.ahk (ErgoptiPlus.ahk
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

; A failed synthetic Up keeps an explicit release owner and is retried without
; sleeping. Three immediate attempts bound the keyboard-thread work while
; still absorbing a transient injection failure before lifecycle cleanup runs.
global TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS := 3

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
; A zero-count key whose final Up was not proven must remain owned separately
; from active reference counts. Lifecycle cleanup retries this ledger instead
; of forgetting an OS-level modifier that may still be logically down.
global _TH_SyntheticReleasePendingKeys := Map()
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

_TapHoldModifierWaitRelease(KeyName, TimeoutSec) {
	return KeyWait(KeyName, "U T" . TimeoutSec)
}

_TapHoldModifierKeyIsDown(KeyName) {
	return GetKeyState(KeyName, "P")
}

_TapHoldModifierTickNow() {
	return A_TickCount
}

_TapHoldModifierIsSuspended() {
	return A_IsSuspended
}

; Own one configured synthetic-modifier gesture from physical key-down through
; release. The Down is published before the first interruptible wait, so the
; first chord belongs to the hold. Activity cancels only the eventual tap; it
; never retracts a hold after that hold has already owned an input event.
TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec,
	WaitReleaseFn := 0, KeyIsDownFn := 0, TickNowFn := 0,
	KeyDownFn := 0, KeyUpFn := 0, CancelTapFn := 0,
	PhysicalModifierPassthrough := false, IsSuspendedFn := 0) {
	if !IsObject(WaitReleaseFn)
		WaitReleaseFn := _TapHoldModifierWaitRelease
	if !IsObject(KeyIsDownFn)
		KeyIsDownFn := _TapHoldModifierKeyIsDown
	if !IsObject(TickNowFn)
		TickNowFn := _TapHoldModifierTickNow
	if !IsObject(KeyDownFn)
		KeyDownFn := TapHoldSyntheticKeyDown
	if !IsObject(KeyUpFn)
		KeyUpFn := TapHoldSyntheticKeyUp
	if !IsObject(CancelTapFn)
		CancelTapFn := TapHoldShouldCancelTap
	if !IsObject(IsSuspendedFn)
		IsSuspendedFn := _TapHoldModifierIsSuspended

	StartedAt := TickNowFn.Call()
	if !PhysicalModifierPassthrough {
		if !KeyDownFn.Call(ModKey) {
			return Map("activated", false, "released", false,
				"tap", false, "elapsed_ms", 0)
		}
	}

	Released := false
	ReleaseProved := false
	try {
		loop {
			if IsSuspendedFn.Call()
				break
			if WaitReleaseFn.Call(KeyName, STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
				Released := true
				break
			}
			if IsSuspendedFn.Call()
				break
			if !KeyIsDownFn.Call(KeyName) {
				Released := true
				break
			}
		}
	} finally {
		; A native modifier selected on its own physical key is already Down
		; before a ~ hotkey thread starts and its physical Up ends KeyWait. A
		; second synthetic Down would race the following key's hotkey admission.
		ReleaseProved := PhysicalModifierPassthrough ? true : KeyUpFn.Call(ModKey)
	}

	ElapsedMs := TickElapsed(StartedAt, TickNowFn.Call())
	GuardMs := TapThresholdSec * 1100
	if (GuardMs < 250)
		GuardMs := 250
	Suspended := IsSuspendedFn.Call()
	CancelReason := ""
	if (Released and ReleaseProved and !Suspended and !A_IsSuspended)
		CancelReason := CancelTapFn.Call(KeyId, GuardMs)
	TapAllowed := Released and ReleaseProved and !Suspended and !A_IsSuspended
		and ElapsedMs <= TapThresholdSec * 1000 and CancelReason == ""
	if LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldModifier", "Ownership complete for key='{1}', modifier='{2}', source={3}, released={4}, elapsed_ms={5}, tap={6}.",
			KeyId, _TH_SyntheticKeyLabel(ModKey), PhysicalModifierPassthrough ? "physical_passthrough" : "synthetic",
			Released ? "true" : "false", ElapsedMs, TapAllowed ? "true" : "false")
	}
	return Map(
		"activated", true,
		"released", ReleaseProved,
		"tap", TapAllowed,
		"elapsed_ms", ElapsedMs)
}

; Flatten a hold-modifier value into the list of individual key names it holds.
; A combination hold (« Ctrl + Maj ») is resolved by ResolveHoldModifierKey into
; a FRESHLY ALLOCATED Array on every single press, and AHK v2 Map keys are
; identity-based for objects: refcounting the Array itself gave every hold site
; its own private entry that could never collide with another branch's — not
; with an identical combination, and not with the scalar "LCtrl" a second key is
; holding. The count then degraded to "release on the first Up" for every combo,
; exactly the failure reference counting exists to prevent. Counting the
; individual key names is what makes the invariant true for both shapes.
; Empty and duplicate entries are dropped only for the Array shape, mirroring
; TextPressKey's combo branch while ensuring one caller cannot count the same
; physical modifier twice. A scalar "" stays visible so the owner can reject
; it with a false verdict instead of publishing fictional state.
; @param Key {String|Array} Scalar key name, or a combo array of key names.
; @return {Array} The individual key names to reference-count.
_TH_SyntheticKeyList(Key) {
	if !(Key is Array)
		return [Key]
	Names := []
	Seen := Map()
	for _, Name in Key {
		if (Name == "" or Seen.Has(Name))
			continue
		Seen[Name] := true
		Names.Push(Name)
	}
	return Names
}

; Human-readable label for a synthetic hold modifier, used in logs. Format()
; cannot stringify an Array, so a combo would otherwise silently lose its log.
_TH_SyntheticKeyLabel(Key) {
	Label := ""
	for _, Name in _TH_SyntheticKeyList(Key)
		Label .= (Label == "" ? "" : "+") . Name
	return Label
}

; Move a final active reference into the release-pending ledger before sending
; its Up. The OS transition is then owned even when injection fails.
_TH_MarkSyntheticKeyReleasePending(Key) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	if _TH_SyntheticHeldKeys.Has(Key)
		_TH_SyntheticHeldKeys.Delete(Key)
	_TH_SyntheticReleasePendingKeys[Key] := true
}

; Retry a release-pending key without sleeping or yielding. The caller holds
; the short synthetic-ledger Critical span, so success and ledger deletion are
; one commit and Suspend cannot interleave between them.
_TH_RetrySyntheticKeyRelease(Key) {
	global _TH_SyntheticReleasePendingKeys
	global TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS
	loop TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS {
		if !TextPressKey(Key, "Up", false)
			continue
		if _TH_SyntheticReleasePendingKeys.Has(Key)
			_TH_SyntheticReleasePendingKeys.Delete(Key)
		return true
	}
	return false
}

; End a pass-through PHYSICAL modifier before dispatching its tap action. This
; is deliberately separate from TapHoldSyntheticKeyUp: there is no synthetic
; Down/refcount to decrement, and the eventual physical key-up remains the
; release backstop if injection fails. Folding this into the synthetic ledger
; would let an unrelated synthetic owner consume the physical release (or make
; its active count fictional). The caller must consume the boolean verdict and
; suppress its tap action when this early release was not proven.
TapHoldReleasePhysicalKey(Key) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	if (Key == "") {
		try LoggerError("TapHoldDispatch", "Cannot release an empty pass-through physical key.")
		return false
	}

	PreviousCritical := Critical("On")
	Ok := false
	FailureKind := ""
	try {
		if A_IsSuspended {
			FailureKind := "suspended"
		} else if _TH_SyntheticHeldKeys.Has(Key) {
			; An unrelated synthetic owner still requires this OS key Down. Do not
			; consume its refcount and do not make that count fictional with a
			; force-Up; suppress the tap action until that owner releases normally.
			FailureKind := "active synthetic owner"
		} else if _TH_SyntheticReleasePendingKeys.Has(Key) {
			Ok := _TH_RetrySyntheticKeyRelease(Key)
			if !Ok
				FailureKind := "pending synthetic release"
		} else {
			Ok := TextPressKey(Key, "Up", false)
			if !Ok
				FailureKind := "physical release"
		}
	}
	finally {
		Critical(PreviousCritical)
	}

	if !Ok {
		if (FailureKind == "suspended" or FailureKind == "active synthetic owner") {
			try LoggerDebug("TapHoldDispatch", "Not releasing pass-through physical '{1}' ({2}).", Key, FailureKind)
		} else {
			try LoggerError("TapHoldDispatch", "Pass-through physical release failed for '{1}' ({2}); tap action suppressed.", Key, FailureKind)
		}
	}
	return Ok
}

; Acquire/release synthetic keys whose lifetime crosses a KeyWait. Reference
; counting keeps independently overlapping tap-hold branches from releasing a
; key another branch still owns; the physical Send happens only on the 0->1 and
; 1->0 transitions of each INDIVIDUAL key (see _TH_SyntheticKeyList).
TapHoldSyntheticKeyDown(Key) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	Keys := _TH_SyntheticKeyList(Key)
	if (Keys.Length = 0 or (Keys.Length = 1 and Keys[1] == "")) {
		try LoggerError("TapHoldDispatch", "Cannot arm an empty synthetic modifier — the hold resolver must return a key name.")
		return false
	}
	if A_IsSuspended {
		try LoggerDebug("TapHoldDispatch", "Not arming synthetic '{1}' while the driver is suspended.", _TH_SyntheticKeyLabel(Key))
		return false
	}

	PreviousCritical := Critical("On")
	Ok := true
	FailureKind := ""
	FailureKey := ""
	RollbackFailedKeys := []
	PressedKeys := []
	try {
		if A_IsSuspended {
			Ok := false
			FailureKind := "suspended"
		} else {
			KeysToPress := []
			for _, Name in Keys {
				; A new owner cannot adopt an indeterminate OS state. First prove
				; the previous failed Up, then include the key in this transaction.
				if _TH_SyntheticReleasePendingKeys.Has(Name) {
					if !_TH_RetrySyntheticKeyRelease(Name) {
						Ok := false
						FailureKind := "pending release"
						FailureKey := Name
						break
					}
				}
				if !_TH_SyntheticHeldKeys.Has(Name)
					KeysToPress.Push(Name)
			}

			; TextPressKey's Array branch is the sender-owned transaction: a
			; second Down failure rolls earlier Downs back in reverse order and
			; reports any rollback Up that could not be proven. Those keys may
			; still be down at the OS, so retain them before leaving Critical.
			if Ok and KeysToPress.Length > 0 {
				Transition := { RollbackFailedKeys: [] }
				if !TextPressKey(KeysToPress, "Down", false, Transition) {
					Ok := false
					FailureKind := "down transaction"
					for _, Name in Transition.RollbackFailedKeys {
						_TH_MarkSyntheticKeyReleasePending(Name)
						RollbackFailedKeys.Push(Name)
					}
				}
				if Ok {
					for _, Name in KeysToPress
						PressedKeys.Push(Name)
				}
			}
			; Counts describe only a fully proven OS transaction. No partial
			; send can publish an owner that never reached the keyboard state.
			if Ok {
				for _, Name in Keys
					_TH_SyntheticHeldKeys[Name] := _TH_SyntheticHeldKeys.Get(Name, 0) + 1
			}
		}
	}
	finally {
		Critical(PreviousCritical)
	}

	if !Ok {
		if (FailureKind == "suspended") {
			try LoggerDebug("TapHoldDispatch", "Not arming synthetic '{1}' because Suspend won the ownership race.", _TH_SyntheticKeyLabel(Keys))
		} else if (FailureKind == "pending release") {
			try LoggerError("TapHoldDispatch", "Cannot arm synthetic '{1}' because the prior release of '{2}' is still pending.", _TH_SyntheticKeyLabel(Keys), FailureKey)
		} else if (FailureKind == "down transaction") {
			if (RollbackFailedKeys.Length > 0) {
				try LoggerError("TapHoldDispatch", "Synthetic Down transaction failed for '{1}'; rollback remains release-pending for '{2}'.", _TH_SyntheticKeyLabel(Keys), _TH_SyntheticKeyLabel(RollbackFailedKeys))
			} else {
				try LoggerError("TapHoldDispatch", "Synthetic Down transaction failed for '{1}' — no ownership counts were published.", _TH_SyntheticKeyLabel(Keys))
			}
		}
	} else if (PressedKeys.Length > 0) and LoggerIsDebugEnabled() {
		LoggerDebug("TapHoldDispatch", "Synthetic Down acquired for key(s) '{1}'.",
			_TH_SyntheticKeyLabel(PressedKeys))
	}
	return Ok
}

TapHoldSyntheticKeyUp(Key) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	Keys := _TH_SyntheticKeyList(Key)
	if (Keys.Length = 0 or (Keys.Length = 1 and Keys[1] == "")) {
		try LoggerError("TapHoldDispatch", "Cannot release an empty synthetic modifier — the hold resolver must return a key name.")
		return false
	}

	PreviousCritical := Critical("On")
	Ok := true
	FailedKeys := []
	SkippedKeys := []
	ReleasedKeys := []
	try {
		for _, Name in Keys {
			; A tracked pending release is safe and necessary even during
			; Suspend. Only the untracked fallback is forbidden while paused.
			if _TH_SyntheticReleasePendingKeys.Has(Name) {
				if _TH_RetrySyntheticKeyRelease(Name) {
					ReleasedKeys.Push(Name)
				} else {
					Ok := false
					FailedKeys.Push(Name)
				}
				continue
			}
			if !_TH_SyntheticHeldKeys.Has(Name) {
				; Suspend cleanup may already have proven this Up. A second,
				; untracked Up could clear the same modifier held physically.
				if A_IsSuspended {
					Ok := false
					SkippedKeys.Push(Name)
					continue
				}
				_TH_MarkSyntheticKeyReleasePending(Name)
				if _TH_RetrySyntheticKeyRelease(Name) {
					ReleasedKeys.Push(Name)
				} else {
					Ok := false
					FailedKeys.Push(Name)
				}
				continue
			}

			Count := _TH_SyntheticHeldKeys[Name] - 1
			if (Count > 0) {
				_TH_SyntheticHeldKeys[Name] := Count
				continue
			}
			_TH_MarkSyntheticKeyReleasePending(Name)
			if _TH_RetrySyntheticKeyRelease(Name) {
				ReleasedKeys.Push(Name)
			} else {
				Ok := false
				FailedKeys.Push(Name)
			}
		}
	}
	finally {
		Critical(PreviousCritical)
	}

	for _, Name in SkippedKeys
		try LoggerDebug("TapHoldDispatch", "Not releasing untracked synthetic '{1}' while the driver is suspended.", Name)
	if (ReleasedKeys.Length > 0) and LoggerIsDebugEnabled()
		LoggerDebug("TapHoldDispatch", "Synthetic Up proven for key(s) '{1}'.",
			_TH_SyntheticKeyLabel(ReleasedKeys))
	if (FailedKeys.Length > 0)
		try LoggerError("TapHoldDispatch", "Synthetic release remains pending for '{1}' after bounded retries.", _TH_SyntheticKeyLabel(FailedKeys))
	return Ok
}

TapHoldReleaseSyntheticKeys() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	Keys := []
	Seen := Map()
	FailedKeys := []
	PreviousCritical := Critical("On")
	try {
		for Name in _TH_SyntheticHeldKeys {
			Seen[Name] := true
			Keys.Push(Name)
		}
		for Name in _TH_SyntheticReleasePendingKeys {
			if Seen.Has(Name)
				continue
			Seen[Name] := true
			Keys.Push(Name)
		}

		; Lifecycle teardown invalidates every active owner, but the failed
		; release remains explicit until an Up is proven.
		for _, Name in Keys
			_TH_MarkSyntheticKeyReleasePending(Name)
		for _, Name in Keys {
			if !_TH_RetrySyntheticKeyRelease(Name)
				FailedKeys.Push(Name)
		}
	}
	finally {
		Critical(PreviousCritical)
	}

	if (FailedKeys.Length > 0) {
		try LoggerError("TapHoldDispatch", "Lifecycle cleanup retained release-pending synthetic key(s) '{1}' after bounded retries.", _TH_SyntheticKeyLabel(FailedKeys))
		return false
	}
	return true
}

; OnExit must not destroy this process while a balancing Up is still owned by
; its release-pending ledger. The optional callback is a deterministic failure
; seam for the shutdown contract test; production uses the real bounded drain.
TapHoldShutdownReleaseGate(ReleaseFn := 0) {
	if !IsObject(ReleaseFn)
		ReleaseFn := TapHoldReleaseSyntheticKeys
	try return ReleaseFn.Call() == true
	catch
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
		; platform/remap.ahk is included after modules/shortcuts.ahk, so the
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
