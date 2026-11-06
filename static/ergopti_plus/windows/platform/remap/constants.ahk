; platform/remap/constants.ahk

; ==============================================================================
; MODULE: Tap-Holds — Constants
; DESCRIPTION:
; Shared timing constants for the tap-hold engine. All modules in the
; tap_holds/ group read from these globals rather than embedding literals.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk





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

; The GLOBAL tap-hold delay (s): what every key waits before its hold fires until
; the user sets the global delay or the key's own (TapHoldDuration). No key ships a
; delay. The one declaration is the registry's tap_hold.default_activation_ms,
; which Linux and macOS read too; tools/test/test-tap-hold-threshold-parity.cjs
; pins this loader to it.
global TAPHOLD_DEFAULT_ACTIVATION_SECONDS := 0

; How long (ms) a key whose hold is a modifier, pressed alone, still types its
; tap (tap_holds.lone_modifier_tap_max_ms; 0 = the strict tap-hold). The
; manifest default until the configuration sets it (TapHoldSetLoneTapMaxMs);
; "" means not set yet. Same rule as _shared/lua/tap_hold/lone_tap.lua on
; macOS and Linux.
global TAP_HOLD_LONE_TAP_MAX_MS := ""

; Wait (ms) before a tap-hold copy reads the clipboard's sequence number, for
; the copy and again for its one retry (section 2.1).
global TAP_COPY_VERIFY_MS := 0

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

; Refuses a lone tap window that is neither 0 nor a positive whole number.
; @param Ms {Number} Milliseconds.
; @returns {Integer}
TapHoldValidLoneTapMaxMs(Ms) {
	if !(Ms is Integer) || Ms < 0
		throw ValueError("tap_holds.lone_modifier_tap_max_ms must be 0 or a positive whole number of milliseconds.", -1, String(Ms))
	return Ms
}

; Sets the lone tap window from the configuration.
; @param Ms {Integer} 0 (strict) or a positive whole number of milliseconds.
TapHoldSetLoneTapMaxMs(Ms) {
	global TAP_HOLD_LONE_TAP_MAX_MS
	TAP_HOLD_LONE_TAP_MAX_MS := TapHoldValidLoneTapMaxMs(Ms)
}

; Reads the lone tap window from config.toml at boot. Absent, the manifest
; default applies; a value that is neither 0 nor a positive whole number is
; reported and the manifest default applies, as for [mod_combos].
; @param Cache {Map} The parsed config (IniCacheGet's source).
TapHoldLoneTapReadConfig(Cache) {
	global TAP_HOLD_LONE_TAP_MAX_MS
	TAP_HOLD_LONE_TAP_MAX_MS := ""
	Stored := (Cache is Map) && Cache.Has(ConfigLeaf.TAP_HOLDS) && (Cache[ConfigLeaf.TAP_HOLDS] is Map)
		? Cache[ConfigLeaf.TAP_HOLDS] : Map()
	if !Stored.Has(ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS) {
		LoggerInfo("TapHold", "Lone modifier tap window not set: the default {1} ms applies.", TapHoldLoneTapMaxMs())
		return
	}
	Value := Stored[ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS]
	; Native Boolean and numeric values share AHK Integer storage; the actual
	; boot source owns the authored type. Detached runtime maps keep their reader.
	if ConfigTomlTryReadBootValue(Cache, ConfigLeaf.TAP_HOLDS, ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS, &Admitted)
		Value := Admitted
	try TapHoldSetLoneTapMaxMs(IsInteger(Value) ? Integer(Value) : Value)
	catch as Err {
		LoggerWarn("TapHold", "[tap_holds] lone_modifier_tap_max_ms = '{1}' is refused ({2}): the default {3} ms applies.",
			(Value is Object) ? Type(Value) : Value, Err.Message, TapHoldLoneTapMaxMs())
		return
	}
	LoggerInfo("TapHold", "Lone modifier tap window read: {1} ms.", TapHoldLoneTapMaxMs())
}

; The longest press (ms) that still types KeyId's tap: its threshold, or the
; lone tap window when KeyId's hold is a modifier taken at key-down and the
; window is longer. The typing keys ([tap_hold.rollover]) and a one-shot
; Shift tap never take the window: a one-shot armed by a long press would
; shift the next letter of a Shift held and let go unused. Alone (no other
; key, click or wheel) is the prior-key guard and the activity tracker of the
; caller, as for any tap.
; @param KeyId {String} Canonical tap-hold key id.
; @param ThresholdSec {Number} The key's tap / hold threshold.
; @returns {Number}
TapHoldTapMaxMs(KeyId, ThresholdSec) {
	global TAP_HOLD_LONE_TAP_MAX_MS, TAPHOLD_ROLL_KEYS, TapHold
	ThresholdMs := ThresholdSec * 1000
	if IsSet(TAPHOLD_ROLL_KEYS) && TAPHOLD_ROLL_KEYS.Has(KeyId)
		return ThresholdMs
	if IsSet(TapHold) && TapHoldTapAction(TapHold, KeyId) == "one_shot_shift"
		return ThresholdMs
	return Max(ThresholdMs, TapHoldLoneTapMaxMs())
}

; The lone tap window in force (ms, 0 = strict).
; @returns {Integer}
TapHoldLoneTapMaxMs() {
	global TAP_HOLD_LONE_TAP_MAX_MS
	if (TAP_HOLD_LONE_TAP_MAX_MS == "")
		TAP_HOLD_LONE_TAP_MAX_MS := TapHoldValidLoneTapMaxMs(ManifestDefaultFor(ConfigKey.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS))
	return TAP_HOLD_LONE_TAP_MAX_MS
}

; Reassign the tap-hold timing constants from the shared registry. Called once
; from the auto-execute body at boot (after TimingsLoadShared(), before any
; tap-hold hotkey arms). Fail-fast: a missing key throws via TimingsGet.
TapHoldsLoadTimings() {
	global TAP_MIN_DURATION_MS, KEY_REPEAT_INITIAL_DELAY_MS
	global KEY_REPEAT_INTERVAL_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC, TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	global TAP_COPY_VERIFY_MS
	TAP_COPY_VERIFY_MS          := TimingsGet("tap_hold", "copy_verify_ms")
	TAP_MIN_DURATION_MS         := TimingsGet("tap_hold", "tap_min_duration_ms")
	KEY_REPEAT_INITIAL_DELAY_MS := TimingsGet("tap_hold", "key_repeat_initial_delay_ms")
	KEY_REPEAT_INTERVAL_MS      := TimingsGet("tap_hold", "key_repeat_interval_ms")
	ONE_SHOT_SHIFT_TIMEOUT_SEC  := TimingsGetSec("tap_hold", "one_shot_shift_timeout_ms")
	TAPHOLD_DEFAULT_ACTIVATION_SECONDS := TimingsGetSec("tap_hold", "default_activation_ms")
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
; Teardown revokes complete gestures, including frames that have not sent Down.
global _TH_SyntheticEpoch := 0
global _TH_ModifierOwners := Map()
global _TH_TabAltOwner := 0
; A zero-count key whose final Up was not proven must remain owned separately
; from active reference counts. Lifecycle cleanup retries this ledger instead
; of forgetting an OS-level modifier that may still be logically down.
global _TH_SyntheticReleasePendingKeys := Map()
; Keys the user already held down, delivered to the system, when a synthetic
; hold first pressed them. Windows keeps one down bit per key: releasing such a
; key at the last owner's Up lifted it under the user (LCtrl held, a CapsLock
; tap held as Ctrl, then C typed "c"). The user's own Up releases it instead.
global _TH_SyntheticUserHeldKeys := Map()
; Tap-hold key id -> number of owners (TapHoldOwnImmediateModifier or
; TapHoldOwnImmediateLayer) resolving that key's suppressed physical press right
; now. Tab, Space, Enter, Escape, Backspace and Delete fire their tap-hold only
; with no modifier held, so their hotkeys carry no * wildcard; their own
; auto-repeat, arriving under the modifier the owner holds, then matched no
; hotkey and reached the application as that chord (Enter held as Ctrl typed
; Ctrl+Enter repeatedly, measured with AutoHotkey 2.0.26). Under a layer hold no
; variant of any tap-hold key is eligible, so the repeat fell to the layer's
; mapping of the same key. Every key's repeat swallower is gated on
; TapHoldPressIsOwned.
global _TH_OwnedPresses := Map()
; Tap-hold key id -> the modifier its owner holds synthetically right now, and
; key id -> true once that hold was handed back mid-press, and key id -> true
; while an LCtrl is held for the AltGr press the key's press turned out to be
; (see TapHoldAltGrTakesItsLCtrl).
global _TH_OwnedModifiers := Map()
global _TH_RetractedOwners := Map()
global _TH_AltGrLCtrlOwners := Map()
; Tap-hold key id -> true once its current press was found to be AltGr's fake
; LCtrl (TapHoldAltGrTakesItsLCtrl); read once with _TH_TakeAltGrPress.
global _TH_AltGrPresses := Map()
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

; The reason the tracker records when another key was struck during a press.
; Named because one reader tells it from the pointer reasons: the keys struck
; around the tap of a typing key are text, not a chord (TapHoldDispatchTap).
global TAPHOLD_CANCEL_BY_OTHER_KEY := "another key during hold"

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
	global TAPHOLD_CANCEL_BY_OTHER_KEY
	keyId := TapHoldResolveKeyIdFromVkSc(vk, sc)
	TapHoldTrackActivityCancel(keyId, TAPHOLD_CANCEL_BY_OTHER_KEY)
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

; The reason a tap is cancelled with when a key combination used the key's
; press as its first key (infra/key_combinations.ahk).
global TAPHOLD_CANCEL_BY_COMBINATION := "first key of a key combination"
; Tap-hold key id -> the tick a key combination used its press as its first
; key. The activity tracker only sees the keys the hook passes on, and the
; second key of a pair is suppressed by its hotkey, so the pair says so itself.
global _TH_PressesTakenByCombination := Map()

; Record that a key combination used KeyId's current press as its first key:
; that press is a hold, and its tap must not follow on release.
; @param KeyId {String} Canonical tap-hold key id.
; @param TickNow {Integer} Test seam; A_TickCount by default.
TapHoldMarkPressTakenByCombination(KeyId, TickNow := unset) {
	global _TH_PressesTakenByCombination
	_TH_PressesTakenByCombination[KeyId] := IsSet(TickNow) ? TickNow : A_TickCount
}

; Whether a key combination used the press KeyId's owner is now deciding;
; clears the mark. The owner asks on release, and only a press shorter than
; GuardMs can be a tap, so an older mark belongs to a press nobody asked
; about (a key with no tap) and is dropped rather than charged to this one.
; @param KeyId {String} Canonical tap-hold key id.
; @param GuardMs {Integer} The longest press the asking owner calls a tap.
; @param TickNow {Integer} Test seam; A_TickCount by default.
; @return {Boolean}
_TH_TakePressTakenByCombination(KeyId, GuardMs, TickNow := unset) {
	global _TH_PressesTakenByCombination
	if !_TH_PressesTakenByCombination.Has(KeyId)
		return false
	TakenAt := _TH_PressesTakenByCombination[KeyId]
	_TH_PressesTakenByCombination.Delete(KeyId)
	return TickElapsed64(TakenAt, IsSet(TickNow) ? TickNow : A_TickCount) <= GuardMs
}

; Return the cancellation reason for this tap dispatch, or "" when dispatch is allowed.
; Keeping the reason as a return value lets us avoid ByRef quirks in AHK v2 and
; keeps all call sites compatible with debug logging.
TapHoldShouldCancelTap(KeyId, GuardMs := 250) {
	global _TH_TapHoldTrackState, _TH_LastTapHoldCancelReason
	_TH_LastTapHoldCancelReason := ""
	if _TH_TakePressTakenByCombination(KeyId, GuardMs) {
		_TH_LastTapHoldCancelReason := TAPHOLD_CANCEL_BY_COMBINATION
		if LoggerIsDebugEnabled() {
			LoggerDebug("TapHoldTrack", "Tap canceled for '{1}' because a key combination used its press.", KeyId)
		}
		return TAPHOLD_CANCEL_BY_COMBINATION
	}
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
	return KS_WaitReleased(KeyName, TimeoutSec)
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

; Release the synthetic modifier a tap-hold owned, masking it first when it can
; open a menu. A lone Alt or Win release puts the focused window's menu bar in
; menu mode (or opens the Start menu), and the tap output that follows lands
; there: the default Tab tap-hold holds Alt, so every Tab tap did this in classic
; applications (measured with SendInput). The mask is harmless after a chord,
; so it is sent whenever the held modifier includes Alt or Win.
; @param ModKey {String|Array} The owned modifier key name, or a combination.
; @return {Boolean} True when the release was proven.
_TapHoldReleaseOwnedModifier(ModKey, Owner := 0) {
	PreviousCritical := Critical("On")
	try {
		if IsObject(Owner) {
			if !TapHoldOwnerCurrent(Owner)
				return false
			if Owner.Closed
				return Owner.ReleaseOk
		}
		MaskSent := _TH_MaskMenuModifierRelease(ModKey)
	} finally Critical(PreviousCritical)
	if !MaskSent
		try LoggerError("TapHoldDispatch", "Menu mask before releasing '{1}' could not be sent.", _TH_SyntheticKeyLabel(ModKey))
	return TapHoldSyntheticKeyUp(ModKey, Owner)
}

; The native Tab-up fallback and its waiting Down frame share one receipt.
_TapHoldReleaseTabAltOwner() {
	global _TH_TabAltOwner
	Owner := _TH_TabAltOwner
	return IsObject(Owner) ? _TapHoldReleaseOwnedModifier("LAlt", Owner) : false
}

; Send the menu mask once when Key (a name or a combination) includes an Alt or
; a Win key about to be released, the only releases that can open a menu. RAlt
; counts: it is a plain Alt wherever right Alt is not AltGr, and the mask is
; harmless under AltGr. The Kana AltGr (SC138) opens nothing. It never logs
; (TextSendMenuMask does not), so it can run under the ledger's Critical.
; @param Key {String|Array} Key name, or the key names about to be released.
; @return {Boolean} False only when a needed mask could not be sent.
_TH_MaskMenuModifierRelease(Key) {
	for _, Name in _TH_SyntheticKeyList(Key) {
		if KS_IsMenuModifier(Name)
			return TextSendMenuMask()
	}
	return true
}

; Whether a tap-hold owner is resolving KeyId's physical press: the key's
; auto-repeat then belongs to that owner, never to the application.
; @param KeyId {String} Canonical tap-hold key id.
; @return {Boolean}
TapHoldPressIsOwned(KeyId) {
	global _TH_OwnedPresses
	; Called from #HotIf criteria, which are live before this file's globals are
	; assigned (a key pressed during the boot pump evaluates them).
	return IsSet(_TH_OwnedPresses) and _TH_OwnedPresses.Has(KeyId)
}

; Claim KeyId's physical press for one owner, before its first wait.
_TapHoldClaimPress(KeyId) {
	global _TH_OwnedPresses
	_TH_OwnedPresses[KeyId] := _TH_OwnedPresses.Get(KeyId, 0) + 1
}

; End one owner's claim on KeyId's press. Claims are paired by try/finally, so
; a missing one is a broken invariant, not a condition to paper over.
_TapHoldEndPressClaim(KeyId) {
	global _TH_OwnedPresses
	if !_TH_OwnedPresses.Has(KeyId)
		throw Error("Ending a tap-hold press claim that was never made.", -1, KeyId)
	Count := _TH_OwnedPresses[KeyId] - 1
	if (Count > 0)
		_TH_OwnedPresses[KeyId] := Count
	else
		_TH_OwnedPresses.Delete(KeyId)
}

; One physical gesture owns one acquisition and one acknowledged release.
TapHoldNewOwner() {
	global _TH_SyntheticEpoch
	return {Epoch: _TH_SyntheticEpoch, Held: false, Closed: false,
		ReleaseOk: false, Retracted: false}
}

TapHoldOwnerCurrent(Owner) {
	global _TH_SyntheticEpoch
	return IsObject(Owner) && Owner.Epoch == _TH_SyntheticEpoch
}

; Publishing the name and its authority is one bounded RAM transaction.
_TapHoldPublishModifierOwner(KeyId, ModKey, Owner) {
	global _TH_OwnedModifiers, _TH_ModifierOwners
	PreviousCritical := Critical("On")
	try {
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return false
		if Owner.Closed
			return Owner.Retracted && _TH_ModifierOwners.Has(KeyId) && _TH_ModifierOwners[KeyId] == Owner
		if _TH_ModifierOwners.Has(KeyId) && _TH_ModifierOwners[KeyId] != Owner
				&& TapHoldOwnerCurrent(_TH_ModifierOwners[KeyId])
			return false
		Owner.Held := true
		_TH_OwnedModifiers[KeyId] := ModKey
		_TH_ModifierOwners[KeyId] := Owner
		return true
	} finally Critical(PreviousCritical)
}

; Own one configured synthetic-modifier gesture from physical key-down through
; release. The Down is published before the first interruptible wait, so the
; first chord belongs to the hold. Activity cancels only the eventual tap; it
; never retracts a hold after that hold has already owned an input event. The
; press stays claimed (TapHoldPressIsOwned) for the whole gesture.
; @param PhysicalModifierPassthrough {Boolean|String} false for a press the
;        hotkey suppressed: the owner presses the whole ModKey. true for a
;        press passed through (~) whose key is the whole hold: the owner
;        presses nothing. The name of one member of ModKey for a press passed
;        through whose key is that member (the AltGr key held as Shift+AltGr):
;        the owner presses only the other members.
TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec,
	WaitReleaseFn := 0, KeyIsDownFn := 0, TickNowFn := 0,
	KeyDownFn := 0, KeyUpFn := 0, CancelTapFn := 0,
	PhysicalModifierPassthrough := false, IsSuspendedFn := 0, Owner := 0) {
	global _TH_ModifierOwners, _TH_OwnedModifiers
	if !IsObject(Owner)
		Owner := TapHoldNewOwner()
	if !TapHoldOwnerCurrent(Owner)
		return Map("activated", false, "released", false, "tap", false, "elapsed_ms", 0)
	Owner.KeyId := KeyId
	if !IsObject(WaitReleaseFn)
		WaitReleaseFn := _TapHoldModifierWaitRelease
	if !IsObject(KeyIsDownFn)
		KeyIsDownFn := _TapHoldModifierKeyIsDown
	if !IsObject(TickNowFn)
		TickNowFn := _TapHoldModifierTickNow
	if !IsObject(KeyDownFn)
		KeyDownFn := (Key) => TapHoldSyntheticKeyDown(Key, Owner)
	if !IsObject(KeyUpFn)
		KeyUpFn := (Key) => _TapHoldReleaseOwnedModifier(Key, Owner)
	if !IsObject(CancelTapFn)
		CancelTapFn := TapHoldShouldCancelTap
	if !IsObject(IsSuspendedFn)
		IsSuspendedFn := _TapHoldModifierIsSuspended

	; A pass-through press already reached the system, and so must its repeats:
	; a swallowed repeat makes AHK suppress the physical release as well, which
	; would leave the modifier down in the system. Only a suppressed press is
	; claimed.
	Claimed := !PhysicalModifierPassthrough
	; From here ModKey is what this owner presses itself: the whole hold,
	; nothing, or the members of a combination the passed-through key is not.
	OwnerPresses := !PhysicalModifierPassthrough
	if (PhysicalModifierPassthrough is String) {
		ModKey := _TH_HoldMembersBesides(ModKey, PhysicalModifierPassthrough)
		OwnerPresses := ModKey.Length > 0
	}
	if Claimed
		_TapHoldClaimPress(KeyId)
	try {
		StartedAt := TickNowFn.Call()
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return Map("activated", false, "released", false, "tap", false, "elapsed_ms", 0)
		if OwnerPresses {
			if !KeyDownFn.Call(ModKey) {
				return Map("activated", false, "released", false,
					"tap", false, "elapsed_ms", 0)
			}
			; Published so the press can be handed back mid-hold when it turns
			; out to be AltGr's fake LCtrl (TapHoldAltGrTakesItsLCtrl).
			if !_TapHoldPublishModifierOwner(KeyId, ModKey, Owner) {
				if TapHoldOwnerCurrent(Owner)
					KeyUpFn.Call(ModKey)
				return Map("activated", false, "released", false, "tap", false, "elapsed_ms", 0)
			}
		}

		Released := false
		ReleaseProved := false
		try {
			loop {
				if !TapHoldOwnerCurrent(Owner) || IsSuspendedFn.Call()
					break
				if WaitReleaseFn.Call(KeyName, STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
					Released := true
					break
				}
				if !TapHoldOwnerCurrent(Owner) || IsSuspendedFn.Call()
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
			; A hold handed back mid-press was released then, and its press was
			; AltGr's, never a tap; the LCtrl given to that AltGr ends with it.
			Retracted := _TH_TakeRetractedOwner(KeyId, Owner)
			if !TapHoldOwnerCurrent(Owner)
				ReleaseProved := false
			else if !OwnerPresses
				ReleaseProved := true
			else if Retracted
				ReleaseProved := Owner.ReleaseOk
			else
				ReleaseProved := KeyUpFn.Call(ModKey)
			if !_TH_ReleaseAltGrLCtrl(KeyId, Owner)
				ReleaseProved := false
		}

		ElapsedMs := TickElapsed(StartedAt, TickNowFn.Call())
		; Pressed alone, a modifier key still taps up to the lone tap window.
		TapMaxMs := TapHoldTapMaxMs(KeyId, TapThresholdSec)
		GuardMs := TapMaxMs * 1.1
		if (GuardMs < 250)
			GuardMs := 250
		Suspended := IsSuspendedFn.Call()
		CancelReason := ""
		if (Released and ReleaseProved and !Suspended and !A_IsSuspended and TapHoldOwnerCurrent(Owner))
			CancelReason := CancelTapFn.Call(KeyId, GuardMs)
		; A release sooner than the shared tap minimum is a key bounce: CapsLock held
		; as Ctrl typed its tap on a 20 ms brush (tap_hold/decision_vectors.json).
		; Owned here so no hold-modifier hotkey can miss it, as Linux does in its engine.
		TapAllowed := Released and ReleaseProved and !Suspended and !A_IsSuspended and !Retracted
			and TapHoldOwnerCurrent(Owner)
			and ElapsedMs >= TapMinDurationMs() and ElapsedMs <= TapMaxMs and CancelReason == ""
		if LoggerIsDebugEnabled() {
			LoggerDebug("TapHoldModifier", "Ownership complete for key='{1}', modifier='{2}', source={3}, released={4}, elapsed_ms={5}, tap={6}.",
				KeyId, _TH_SyntheticKeyLabel(ModKey), PhysicalModifierPassthrough ? "physical_passthrough" : "synthetic",
				Released ? "true" : "false", ElapsedMs, TapAllowed ? "true" : "false")
		}
		TapAllowed := TapAllowed && TapHoldOwnerCurrent(Owner) && !A_IsSuspended
		return Map(
			"activated", true,
			"released", ReleaseProved,
			"tap", TapAllowed,
			"elapsed_ms", ElapsedMs)
	} finally {
		PreviousCritical := Critical("On")
		try {
			if _TH_ModifierOwners.Has(KeyId) && _TH_ModifierOwners[KeyId] == Owner {
				_TH_ModifierOwners.Delete(KeyId)
				if _TH_OwnedModifiers.Has(KeyId)
					_TH_OwnedModifiers.Delete(KeyId)
			}
		} finally Critical(PreviousCritical)
		if Claimed
			_TapHoldEndPressClaim(KeyId)
	}
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

; The members of a hold other than Member, the one a passed-through key holds
; itself. Empty names are dropped, so a key that holds nothing leaves nothing.
; @param Key {String|Array} Resolved hold modifier.
; @param Member {String} Key name the physical key already holds.
; @return {Array} The key names its owner must press.
_TH_HoldMembersBesides(Key, Member) {
	Others := []
	for _, Name in _TH_SyntheticKeyList(Key) {
		if (Name != "" and Name != Member)
			Others.Push(Name)
	}
	return Others
}

; Human-readable label for a synthetic hold modifier, used in logs. Format()
; cannot stringify an Array, so a combo would otherwise silently lose its log.
_TH_SyntheticKeyLabel(Key) {
	Label := ""
	for _, Name in _TH_SyntheticKeyList(Key)
		Label .= (Label == "" ? "" : "+") . Name
	return Label
}

; Whether key Name is down, logically (Mode "") or physically (Mode "P"). A
; global holding a function, as _AHK_SendInput is, so tests can stand in for
; the keyboard state.
global _TapHoldKeyIsDown := (Name, Mode) => (Mode == "") ? GetKeyState(Name) : GetKeyState(Name, Mode)

; Whether the user holds key Name down, delivered to the system. A key's
; logical state only follows events that reached the system, so logically and
; physically down before any synthetic owner pressed it means the user's press
; went through, and so will the user's release. A press a hotkey suppressed (a
; tap-hold key holding its own modifier, the LAlt one-shot Shift) is physically
; down but logically up: its release is swallowed too.
_TH_UserHoldsDeliveredKey(Name) {
	global _TapHoldKeyIsDown
	return _TapHoldKeyIsDown.Call(Name, "") and _TapHoldKeyIsDown.Call(Name, "P")
}

; Whether the last owner of Name must leave it down: the user held it down,
; delivered, when the synthetic hold began, and still holds it physically.
_TH_SyntheticReleaseStaysWithUser(Name) {
	global _TH_SyntheticUserHeldKeys, _TapHoldKeyIsDown
	return _TH_SyntheticUserHeldKeys.Has(Name) and _TapHoldKeyIsDown.Call(Name, "P")
}

; End the synthetic ownership of a key the user still holds, without an Up.
_TH_ForgetSyntheticKeyForUser(Name) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticUserHeldKeys
	if _TH_SyntheticHeldKeys.Has(Name)
		_TH_SyntheticHeldKeys.Delete(Name)
	if _TH_SyntheticUserHeldKeys.Has(Name)
		_TH_SyntheticUserHeldKeys.Delete(Name)
}

; Move a final active reference into the release-pending ledger before sending
; its Up. The OS transition is then owned even when injection fails.
_TH_MarkSyntheticKeyReleasePending(Key) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	if _TH_SyntheticHeldKeys.Has(Key)
		_TH_SyntheticHeldKeys.Delete(Key)
	if _TH_SyntheticUserHeldKeys.Has(Key)
		_TH_SyntheticUserHeldKeys.Delete(Key)
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
TapHoldSyntheticKeyDown(Key, Owner := 0) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_ModifierOwners, _TH_OwnedModifiers, _TapHoldKeyIsDown
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
		if IsObject(Owner) {
			if !TapHoldOwnerCurrent(Owner) || Owner.Closed
				return false
			if Owner.Held
				return true
			if Owner.HasOwnProp("KeyId") && _TH_ModifierOwners.Has(Owner.KeyId)
					&& _TH_ModifierOwners[Owner.KeyId] != Owner
					&& TapHoldOwnerCurrent(_TH_ModifierOwners[Owner.KeyId])
				return false
		}
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

			; Snapshot, before this owner presses them, the keys the user already
			; holds down and delivered: the last owner leaves those to the user.
			UserHeld := [], PhysicalBefore := Map()
			if Ok {
				for _, Name in KeysToPress {
					PhysicalBefore[Name] := !!_TapHoldKeyIsDown.Call(Name, "P")
					if _TH_UserHoldsDeliveredKey(Name)
						UserHeld.Push(Name)
				}
			}
			; The sender retains proven and uncertain Down attempts. This owner
			; defers rollback so user and sibling custody are checked before every
			; release, and an unproven Up survives in the existing pending ledger.
			if Ok and KeysToPress.Length > 0 {
				Transition := { RollbackFailedKeys: [], SentKeys: [], AttemptedKey: "", DeferRollback: true }
				if !TextPressKey(KeysToPress, "Down", false, Transition) {
					Ok := false
					FailureKind := "down transaction"
					; The failed port may have emitted its Down before refusing.
					; Recover every edge through this ledger, never an adapter's
					; blind Up of a key a user or reentrant sibling now owns.
					Recover := Transition.SentKeys.Clone()
					if Transition.AttemptedKey != ""
						Recover.Push(Transition.AttemptedKey)
					for _, Name in Transition.RollbackFailedKeys
						Recover.Push(Name)
					Admitted := Map(), UserOwned := Map(), Recovered := Map()
					for _, Name in KeysToPress
						Admitted[Name] := true
					for _, Name in UserHeld
						UserOwned[Name] := true
					loop Recover.Length {
						Name := Recover[Recover.Length - A_Index + 1]
						if !Admitted.Has(Name) || Recovered.Has(Name)
							continue
						Recovered[Name] := true
						if _TH_SyntheticHeldKeys.Has(Name)
							continue
						if UserOwned.Has(Name) {
							if _TapHoldKeyIsDown.Call(Name, "P")
								continue
						} else if !PhysicalBefore[Name] && _TH_UserHoldsDeliveredKey(Name)
							continue
						; A new physical hold can arrive while the native port runs.
						; An already suppressed own press is not that new custody:
						; our uncertain injected Down alone made it logically down.
						; Recheck after the key-state port before touching counts.
						if _TH_SyntheticHeldKeys.Has(Name)
							continue
						_TH_MarkSyntheticKeyReleasePending(Name)
						if !_TH_RetrySyntheticKeyRelease(Name)
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
				for _, Name in UserHeld
					_TH_SyntheticUserHeldKeys[Name] := true
				if IsObject(Owner) {
					Owner.Held := true
					; A DEBUG callout below may deliver AltGr's handback. Publish
					; its exact parent before releasing the native admission fence.
					if Owner.HasOwnProp("KeyId") {
						_TH_OwnedModifiers[Owner.KeyId] := Key
						_TH_ModifierOwners[Owner.KeyId] := Owner
					}
				}
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

TapHoldSyntheticKeyUp(Key, Owner := 0) {
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
		if IsObject(Owner) {
			if !TapHoldOwnerCurrent(Owner)
				return false
			if Owner.Closed
				return Owner.ReleaseOk
			Owner.Closed := true
			if !Owner.Held
				return false
			Owner.Held := false
		}
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
			; The user held this key before the hold and still does: their own
			; release will reach the system, an Up now would lift it under them.
			if _TH_SyntheticReleaseStaysWithUser(Name) {
				_TH_ForgetSyntheticKeyForUser(Name)
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
		if IsObject(Owner)
			Owner.ReleaseOk := Ok
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
	; Deferred copy retries are synthetic input owners too: revoke them before
	; the first yielding key-release operation of suspend or shutdown.
	TapCopyCheckStop()
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	global _TH_SyntheticEpoch, _TH_OwnedModifiers, _TH_ModifierOwners, _TH_AltGrLCtrlOwners
	global LayerEnabled, _TH_LayerOwner, NumberOfRepetitions, _TH_TabAltOwner
	Keys := []
	Seen := Map()
	FailedKeys := []
	MaskSent := true
	PreviousCritical := Critical("On")
	try {
		_TH_SyntheticEpoch += 1
		LayerWasEnabled := IsSet(LayerEnabled) && LayerEnabled
		LayerEnabled := false, _TH_LayerOwner := 0, NumberOfRepetitions := 1
		_TH_OwnedModifiers := Map(), _TH_ModifierOwners := Map(), _TH_AltGrLCtrlOwners := Map(), _TH_TabAltOwner := 0
		UserKeys := []
		for Name in _TH_SyntheticHeldKeys {
			Seen[Name] := true
			; A key the user held before the hold and still holds is theirs to
			; release, even when every owner is invalidated.
			if _TH_SyntheticReleaseStaysWithUser(Name)
				UserKeys.Push(Name)
			else
				Keys.Push(Name)
		}
		for _, Name in UserKeys
			_TH_ForgetSyntheticKeyForUser(Name)
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
		; Suspend, shutdown and the fatal cleanup end a hold mid-press, usually
		; with nothing typed under it: a lone Alt or Win released here put the
		; focused window's menu bar in menu mode (or opened Start) exactly as the
		; owner's own release would have without its mask, and the keys typed
		; after the pause went to the menu. Mask once before the Ups; the owner's
		; own masked release comes later, after these Ups, too late.
		MaskSent := _TH_MaskMenuModifierRelease(Keys)
		for _, Name in Keys {
			if !_TH_RetrySyntheticKeyRelease(Name)
				FailedKeys.Push(Name)
		}
	}
	finally {
		Critical(PreviousCritical)
	}

	if LayerWasEnabled && IsSet(UpdateCapsLockLED) {
		try UpdateCapsLockLED()
		catch as Err
			try LoggerWarn("TapHoldDispatch", "Could not refresh the navigation layer indicator after input retirement: {1}.", Err.Message)
	}

	if !MaskSent
		try LoggerError("TapHoldDispatch", "Lifecycle cleanup could not mask the release of '{1}'; a menu may open.", _TH_SyntheticKeyLabel(Keys))
	if (FailedKeys.Length > 0) {
		try LoggerError("TapHoldDispatch", "Lifecycle cleanup retained release-pending synthetic key(s) '{1}' after bounded retries.", _TH_SyntheticKeyLabel(FailedKeys))
		return false
	}
	return true
}

; Run SendFn with key Name up, for output the key would otherwise modify: the
; Kana-style layout's AltGr changes every character typed while it is down.
; Whoever held the key keeps it: a tap-hold that holds Name synthetically, and
; the user holding it down themselves (AltGr held as AltGr passes the key
; through; AltGr with no tap-hold is the plain key). The key is pressed again
; after the output, but only if that holder still holds it then, so a hold that
; ended meanwhile is never overridden and an owner's count stays true.
; @param Name {String} AHK key name, e.g. KS_AltGrKeyName().
; @param SendFn {Func} Zero-argument sender; its result is returned.
; @return The sender's result, or false when the lift could not be sent.
TapHoldSendWithKeyUp(Name, SendFn) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TapHoldKeyIsDown
	; A key nobody holds needs no lift: logically up, owned by no tap-hold, with
	; no release pending (a press a hotkey swallowed is logically up too). The
	; Kana layout lifted AltGr before every expansion anyway, one extra
	; SendInput and an orphan AltGr release in front of each burst.
	if !(_TapHoldKeyIsDown.Call(Name, "") or _TH_SyntheticHeldKeys.Has(Name)
			or _TH_SyntheticReleasePendingKeys.Has(Name))
		return SendFn.Call()
	; Read before the lift: once the Up is sent the key is logically up, and a
	; hold the system saw can no longer be told from a press a hotkey swallowed.
	UserHeld := _TH_UserHoldsDeliveredKey(Name)
	if !TapHoldLiftKey(Name)
		return false
	try
		return SendFn.Call()
	finally
		TapHoldRestoreLiftedKey(Name, UserHeld)
}

; Lift key Name for an output, whoever holds it. Pair with
; TapHoldRestoreLiftedKey once the output is sent. A lifted Alt or Win is
; masked first: RAlt is a plain Alt where right Alt is not AltGr, and its
; release after nothing typed would open the window menu the output lands in.
; @return {Boolean} False when the Up could not be sent; skip the output then.
TapHoldLiftKey(Name) {
	if !_TH_MaskMenuModifierRelease(Name)
		try LoggerError("TapHoldDispatch", "Menu mask before lifting '{1}' could not be sent.", Name)
	if TextPressKey(Name, "Up", false)
		return true
	try LoggerError("TapHoldDispatch", "Could not lift '{1}' before an output; the output was not sent.", Name)
	return false
}

; Run SendFn with key Name up only while a tap-hold holds it synthetically. A
; modifier the driver pressed with {X Down} is one AutoHotkey keeps down
; around every later non-blind Send (keyboard_mouse.cpp: "any modifiers
; pressed down by the script itself ... are intended to stay down"), so a
; synthetic AltGr (CapsLock held as AltGr) modified every expansion: Backspace
; became Ctrl+Alt+Backspace on an AltGr layout and Alt+Backspace (Undo) where
; right Alt is a plain Alt. A key the user holds is not the driver's: a
; non-blind Send already lifts it around its output and restores it.
; @param Name {String} AHK key name, e.g. KS_AltGrKeyName().
; @param SendFn {Func} Zero-argument sender; its result is returned.
; @return The sender's result, or false when the lift could not be sent.
TapHoldSendWithOwnedKeyUp(Name, SendFn) {
	global _TH_SyntheticHeldKeys
	if !_TH_SyntheticHeldKeys.Has(Name)
		return SendFn.Call()
	return TapHoldSendWithKeyUp(Name, SendFn)
}

; Press Name again after an output that lifted it, when a synthetic owner still
; holds it, or when the user held it down before the lift (UserHeld) and still
; holds it physically; the user's own release then passes through as usual.
; The native attempt and recovery share one Critical span. Native user input
; and an emission port can still change custody during that attempt, so current
; counts and physical custody are checked again even when Down returned false.
; @param UserHeld {Boolean} _TH_UserHoldsDeliveredKey(Name) before the lift.
; @return {Boolean} False when a Down or Up could not be sent.
TapHoldRestoreLiftedKey(Name, UserHeld := false) {
	global _TH_SyntheticHeldKeys, _TapHoldKeyIsDown
	PreviousCritical := Critical("On")
	ReleaseFailed := false
	try {
		Owned := _TH_SyntheticHeldKeys.Has(Name)
		if !Owned && !UserHeld
			return true
		PhysicalBefore := !!_TapHoldKeyIsDown.Call(Name, "P")
		if !Owned && !PhysicalBefore
			return true
		; The one-key transaction retains an uncertain Down even when its port
		; reports failure after delivery. Its Boolean ACK remains unchanged.
		Transition := { AttemptedKey: "", DeferRollback: true }
		Ok := TextPressKey([Name], "Down", false, Transition)
		if !_TH_SyntheticHeldKeys.Has(Name) {
			PhysicalNow := !!_TapHoldKeyIsDown.Call(Name, "P")
			UserStillHolds := PhysicalNow && (UserHeld || !PhysicalBefore)
			; The sender or state port may have published a sibling owner. An
			; old captured Owned Boolean cannot authorize releasing that key.
			if !UserStillHolds && !_TH_SyntheticHeldKeys.Has(Name)
					&& (Ok || Transition.AttemptedKey == Name) {
				_TH_MarkSyntheticKeyReleasePending(Name)
				Released := _TH_RetrySyntheticKeyRelease(Name)
				ReleaseFailed := !Released
				if Ok
					Ok := Released
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	if ReleaseFailed {
		try LoggerError("TapHoldDispatch", "Could not balance restoration of '{1}' after its holder released it; the exact Up remains pending for retry.", Name)
	} else if !Ok {
		try LoggerError("TapHoldDispatch", "Restoring '{1}' after an output was not acknowledged; any unowned attempted Down was reconciled through the synthetic release owner.", Name)
	}
	return Ok
}

; Release key Name unless a synthetic owner holds it; that owner's own release
; ends it. Used to clear a key a chord may have left logically down.
; @param ReleaseFn {Func} Optional sender taking Name and returning a verdict,
;        for a caller whose Up must take another path; TextSender by default.
; @return {Boolean} True when the key is released or left to its owner.
TapHoldReleaseUnlessOwned(Name, ReleaseFn := 0) {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	PreviousCritical := Critical("On")
	try {
		if _TH_SyntheticHeldKeys.Has(Name)
			return true
		if _TH_SyntheticReleasePendingKeys.Has(Name)
			Ok := _TH_RetrySyntheticKeyRelease(Name)
		else if HasMethod(ReleaseFn, "Call")
			Ok := ReleaseFn.Call(Name)
		else
			Ok := TextPressKey(Name, "Up", false)
	} finally {
		Critical(PreviousCritical)
	}
	if !Ok
		try LoggerError("TapHoldDispatch", "Could not release '{1}'.", Name)
	return Ok
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

; Physical scan code of tap-hold key KeyId, the one its hotkeys are bound to.
; @param KeyId {String} Canonical tap-hold key id.
; @return {Integer} The scan code (extended keys carry 0x100).
_TapHoldScanCodeOf(KeyId) {
	global _TH_TapHoldScToKeyId
	for Sc, Id in _TH_TapHoldScToKeyId {
		if (Id == KeyId)
			return Sc
	}
	throw ValueError("Unknown tap-hold key id for the prior-key guard.", -1, KeyId)
}

; Whether the last key pressed before this release was tap-hold key KeyId
; itself, i.e. nothing else was pressed during the hold. A_PriorKey is the name
; AHK derives from the recorded virtual key and scan code through the active
; layout: never an "SCxxx" string, "Backspace" rather than "BackSpace", and "^"
; for the Kana AltGr of the Ergopti layout. The expected name is therefore
; derived by the same function from the key's own scan code at call time; a
; hand-written name broke on AHK's spelling or on the layout.
; When the layout puts the key on a virtual key with no name at all, AHK answers
; "" here and an undocumented placeholder for A_PriorKey, so the name cannot
; decide: the scan-code activity tracker that every tap dispatch also consults
; stays the guard, and the situation is logged once per key.
; @param KeyId {String} Canonical tap-hold key id.
; @param PriorKey {String} Test seam; production reads A_PriorKey.
; @param KeyNameFn {Func} Test seam; production uses GetKeyName.
; @return {Boolean} True when the prior key is KeyId's own physical key.
TapHoldPriorKeyIsSelf(KeyId, PriorKey := unset, KeyNameFn := 0) {
	static UnnamedReported := Map()
	Sc := _TapHoldScanCodeOf(KeyId)
	if !IsSet(PriorKey)
		PriorKey := A_PriorKey
	if !IsObject(KeyNameFn)
		KeyNameFn := GetKeyName
	Expected := KeyNameFn.Call(Format("SC{:03X}", Sc))
	if (Expected == "") {
		if !UnnamedReported.Has(KeyId) {
			UnnamedReported[KeyId] := true
			try LoggerWarn("TapHoldTrack", "Tap-hold key '{1}' has no key name on this layout; its tap is guarded by the activity tracker only.", KeyId)
		}
		return PriorKey != ""
	}
	return PriorKey == Expected
}

; The tap-hold key whose physical tap TapHoldDispatchTap is running now, or "".
; Only the hotkeys of the physical tap-hold keys dispatch a tap, on the release
; of the key they own, so a keystroke sent inside that dispatch is the user's
; own key: a Tab tapped there accepts a shown prediction as the physical Tab
; does (TapHoldTapProvenance, llm-accept-inserts).
global _TapHoldTapInDispatch := ""

; @return {String} The key id whose physical tap is being dispatched, or "".
TapHoldTapInDispatch() {
	global _TapHoldTapInDispatch
	return IsSet(_TapHoldTapInDispatch) ? _TapHoldTapInDispatch : ""
}

; The provenance of a keystroke tap sent now: the tap-hold key the user just
; tapped, or false outside a dispatch (a gesture, a macro, a timer, a text
; send). The acceptance policy trusts it only while that same tap is still
; being dispatched.
; @return {Map|Boolean} Map("kind", "tap_hold_tap", "key_id", KeyId), or false.
TapHoldTapProvenance() {
	KeyId := TapHoldTapInDispatch()
	return KeyId == "" ? false : Map("kind", "tap_hold_tap", "key_id", KeyId)
}

; Run any tap output through the single activity/suspend gate, then consume the
; tracked physical press. Native taps (Space, Enter, Backspace, Escape, Delete)
; must use this helper too; otherwise only GESTURE_ACTIONS-based taps are safe.
; @param KeyId {String} Canonical tap-hold key id.
; @param TapFn {Func} Zero-argument callback that emits the tap output.
; @return {Boolean} True when TapFn ran, false when the tap was suppressed.
TapHoldDispatchTap(KeyId, TapFn) {
	global TapHold, _TapHoldTapInDispatch
	Owner := TapHoldNewOwner()
	try {
		if A_IsSuspended {
			try LoggerDebug("TapHoldDispatch", "Dispatch blocked for '{1}' because script is suspended.", KeyId)
			return false
		}
		LimitMs := TapHoldDuration(TapHold, KeyId) * 1100
		if (LimitMs < 250)
			LimitMs := 250
		CancelReason := TapHoldShouldCancelTap(KeyId, LimitMs)
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return false
		; The keys struck around the tap of a typing key are text, not a chord:
		; only a click or the wheel makes its press something else than a tap.
		if (CancelReason == TAPHOLD_CANCEL_BY_OTHER_KEY && TapHoldRollTapIsRunning(KeyId))
			CancelReason := ""
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
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return false
		; A command tap (paste, a window switch…) starts a new word, or leaves
		; the word open, as hotstrings.tap_hold_resets_word says; its keystroke,
		; if any, is then attributed to the tap-hold (TapHoldOwnsShortcut).
		if (TapHoldTapIsCommand(KeyId) and IsSet(HS_ApplyEventWordReset))
			HS_ApplyEventWordReset(ConfigLeaf.TAP_HOLD_RESETS_WORD, "tap of " . KeyId)
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return false
		; A tap that types Enter or Tab goes out through the driver's own send, which
		; the watcher never sees: it completes a hotstring here, as Space does.
		EndChar := HotstringEndCharOfTap(KeyId)
		if (EndChar != "" and HotstringCompleteEndKey(EndChar,
				TapHoldRollTapIsRunning(KeyId) ? TapHoldRollTapDownTick() : 0))
			return true
		if !TapHoldOwnerCurrent(Owner) || A_IsSuspended
			return false
		PreviousTap := TapHoldTapInDispatch()
		_TapHoldTapInDispatch := KeyId
		try TapFn.Call()
		finally _TapHoldTapInDispatch := PreviousTap
		return true
	}
	finally {
		; A retired dispatch must not erase the resumed physical press.
		if TapHoldOwnerCurrent(Owner)
			TapHoldForgetTrackedKey(KeyId)
	}
}

; Tap actions that type, as the key would: hotstrings.tap_hold_resets_word
; leaves them to the key they emit (TapHoldTapIsCommand).
global TAP_HOLD_TYPING_TAP_ACTIONS := Map("one_shot_shift", true, "caps_word", true, "caps_lock", true)

; Whether the configured tap of KeyId is a command rather than typing: an
; action of the catalogue (copy, paste, a window switch, an AI request…), a
; keystroke under Ctrl, Alt or Win included. The native tap (the key itself),
; the keystroke of a key (Tab, Enter, Backspace, an arrow) and the typing
; actions keep the effect of the key they emit on the hotstring word.
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Boolean}
TapHoldTapIsCommand(KeyId) {
	global GESTURE_ACTIONS, TapHold, TAP_HOLD_TYPING_TAP_ACTIONS
	ActionId := TapHoldTapAction(TapHold, KeyId)
	if (ActionId == "" or ActionId == KeyId or TAP_HOLD_TYPING_TAP_ACTIONS.Has(ActionId))
		return false
	if !(IsSet(GESTURE_ACTIONS) and GESTURE_ACTIONS.Has(ActionId))
		return false
	Action := GESTURE_ACTIONS[ActionId]
	if !Action.HasOwnProp("Key")
		return true
	for _, ModifierName in Action.Mods {
		if (ModifierName = "Ctrl" or ModifierName = "Alt" or ModifierName = "Win")
			return true
	}
	return false
}

; Whether a shortcut made now is a tap-hold key's own output, which
; hotstrings.tap_hold_resets_word governs instead of
; hotstrings.shortcut_resets_word: a tap being dispatched, the navigation
; layer held, or a hold whose owner presses Ctrl, Alt or Win itself (CapsLock
; held as Ctrl). A key held as its own modifier (LCtrl as Ctrl, passed
; through) is the native modifier, and Shift or the layout's AltGr only type.
; @returns {Boolean}
TapHoldOwnsShortcut() {
	global _TH_OwnedModifiers, LayerEnabled
	if (TapHoldTapInDispatch() != "")
		return true
	if (IsSet(LayerEnabled) and LayerEnabled)
		return true
	for _, ModKey in _TH_OwnedModifiers {
		if _TH_HoldMakesShortcuts(ModKey)
			return true
	}
	return false
}

; Whether a held modifier combination makes shortcuts: any member besides
; Shift and the layout's AltGr (on QWERTY right Alt is a plain Alt).
; @param ModKey {String|Array} Resolved hold modifier.
; @returns {Boolean}
_TH_HoldMakesShortcuts(ModKey) {
	for _, Name in _TH_SyntheticKeyList(ModKey) {
		if RegExMatch(Name, "i)^[LR]?Shift$")
			continue
		if (KS_LayoutHasAltGr() and Name = KS_AltGrKeyName())
			continue
		return true
	}
	return false
}

; Whether a tap-hold key's tap ends CapsWord: its id names a word delimiter of
; the hotstring catalogue ("space", "enter", "tab") that the CapsWord auto-off
; settings check. The tap is sent at level 0, which the auto-off InputHook
; never sees, so the dispatcher asks here. Any other key (Backspace, Escape,
; Delete, CapsLock…) leaves CapsWord latched, which is what makes it usable for
; a whole word.
_TapHoldTapEndsCapsWord(KeyId) {
	; IsSet-guarded: the tap-hold layer is reachable in contexts where
	; shortcuts/capsword.ahk is not loaded (standalone tests, tools).
	if !IsSet(CapsWordEnabled) or !CapsWordEnabled or !IsSet(DisableCapsWord)
		return false
	return CapsWordAutoOffIsTerminatorKey(KeyId) and CapsWordAutoOffEndsOnNativeKey(KeyId)
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
	; A keystroke action is typed like the key it names, under the held
	; modifiers. Its gesture callback stays modifier-free: a touchpad gesture
	; or a shortcut slot fires it while its own carrier modifier is down.
	Action := GESTURE_ACTIONS[ActionId]
	if Action.HasOwnProp("Key") {
		; Keep key metadata and the tap's Blind/provenance path, while sharing
		; the catalogue paste's admission before any temporary payload is read.
		if ActionId == "paste"
			return _GestureWithPasteAdmission(TapHoldEmitKeyTap.Bind(Action.Key, Action.Mods))
		if ActionId == "copy"
			return TapCopySend(KeyId, TapHoldEmitKeyTap.Bind(Action.Key, Action.Mods))
		TapHoldEmitKeyTap(Action.Key, Action.Mods)
		return
	}
	GestureInvokeAction(ActionId, GestureBindingId("tap_hold", KeyId))
}

; Fire the configured generic tap action through the shared gate.
_TapHoldFireAction(KeyId) {
	return TapHoldDispatchTap(KeyId, _TapHoldInvokeConfiguredAction.Bind(KeyId))
}





; =====================================
; =====================================
; ======= 2.1) Copy check =============
; =====================================
; =====================================

; A tap's copy (Ctrl+C) is proved by the clipboard's sequence number
; (GetClipboardSequenceNumber), never by its content: copying the same text
; again moves the number and leaves the content as it was. The number is read
; before Ctrl+C is sent, read again by a one-shot timer (never a Sleep on the
; hook thread), Ctrl+C is sent once more when it did not move, and the user is
; warned when it still did not. The states and outcomes are those of
; _shared/lua/tap_hold/copy_check.lua, which the macOS and Linux drivers run.

; How many times a copy is sent again when the clipboard did not move.
global TAP_COPY_RETRIES := 1
; The pending check (a Map), or 0. A newer copy supersedes it.
global _TapCopyPending := 0
global _TapCopyGeneration := 0
; Seams for the test suite: the counter, the timer and the notice.
global _TapCopyCounterFn := () => CB_GetSequenceNumber()
global _TapCopyTimerFn := (Callback, DelayMs) => TimerAfter(DelayMs / 1000, Callback)
global _TapCopyFocusFn := () => WIGetFocusedControlToken()
global _TapCopyPhysicalTickFn := () => (A_TickCount - A_TimeIdlePhysical) & 0xFFFFFFFF
global _TapCopyWarnFn := () => NotifierSend(t("notify.tap_hold.copy_failed"), Map("level", "warning"))

; Sends one tap-hold copy and starts its check.
; @param KeyId {String} The tap-hold key that tapped, for the log.
; @param SendFn {Func} Sends the copy keystroke; returns the sender's verdict.
;   The retry calls it again.
; A missing focus or physical-input timestamp cannot establish a safe retry.
_TapCopyContext() {
	global _TapCopyFocusFn, _TapCopyPhysicalTickFn
	try {
		Focus := _TapCopyFocusFn.Call()
		Tick := _TapCopyPhysicalTickFn.Call()
		if !(Focus is Integer) or Focus == 0 or !(Tick is Integer)
			return 0
		return Map("focus", Focus, "tick", Tick)
	} catch {
		return 0
	}
}

_TapCopySameContext(First, Second) {
	return IsObject(First) and IsObject(Second)
		and First["focus"] == Second["focus"] and First["tick"] == Second["tick"]
}

TapCopySend(KeyId, SendFn) {
	global _TapCopyCounterFn
	if A_IsSuspended
		return false
	Generation := TapCopyCheckStop()
	Baseline := _TapCopyCounterFn.Call()
	Context := _TapCopyContext()
	if !_TapCopyGenerationCurrent(Generation)
		return false
	Sent := SendFn.Call()
	if !_TapCopySameContext(Context, _TapCopyContext())
		Context := 0
	if _TapCopyGenerationCurrent(Generation)
		TapCopyCheckStart(Baseline, KeyId, SendFn, Generation, Context)
	return Sent
}

; Starts checking only the copy whose sender still owns this lifecycle generation.
; @param Context {Map|Integer} The focus and physical-input proof, or 0 when none.
TapCopyCheckStart(Baseline, Source, SendFn, ExpectedGeneration := unset, Context := 0) {
	global _TapCopyPending, _TapCopyGeneration, _TapCopyTimerFn, TAP_COPY_VERIFY_MS
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || (IsSet(ExpectedGeneration) && ExpectedGeneration != _TapCopyGeneration)
			return false
		_TapCopyGeneration += 1
		Generation := _TapCopyGeneration
		_TapCopyPending := 0
		if (Baseline is Integer) && Baseline != 0 {
			Pending := Map("baseline", Baseline, "attempts", 1, "source", Source,
				"generation", Generation, "send", SendFn, "context", Context)
			_TapCopyPending := Pending
		}
	} finally Critical(PreviousCritical)
	; GetClipboardSequenceNumber returns zero when the session cannot access it.
	if !IsSet(Pending) {
		if _TapCopyGenerationCurrent(Generation)
			try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} could not be checked (counter_unreadable).", Source)
		return false
	}
	if !_TapCopyCheckCurrent(Pending)
		return false
	_TapCopyTimerFn.Call(() => _TapCopyCheckTick(Generation), TAP_COPY_VERIFY_MS)
	return _TapCopyCheckCurrent(Pending)
}

; Abandons both a pending check and any sender that has not published one yet.
TapCopyCheckStop() {
	global _TapCopyPending, _TapCopyGeneration
	PreviousCritical := Critical("On")
	try {
		_TapCopyPending := 0
		_TapCopyGeneration += 1
		return _TapCopyGeneration
	} finally Critical(PreviousCritical)
}

_TapCopyGenerationCurrent(Generation) {
	global _TapCopyGeneration
	return !A_IsSuspended && Generation == _TapCopyGeneration
}
_TapCopyCheckCurrent(Pending) {
	global _TapCopyPending
	return IsObject(Pending) && _TapCopyPending == Pending
		&& _TapCopyGenerationCurrent(Pending["generation"])
}

; Completion may retire only its exact record, never a copy started in a callout.
_TapCopyCheckRetire(Pending, Revoke := false) {
	global _TapCopyPending, _TapCopyGeneration
	PreviousCritical := Critical("On")
	try {
		if !IsObject(Pending) || _TapCopyPending != Pending || Pending["generation"] != _TapCopyGeneration
			return false
		_TapCopyPending := 0
		if Revoke
			_TapCopyGeneration += 1
		return true
	} finally Critical(PreviousCritical)
}

_TapCopyCheckTick(Generation) {
	global _TapCopyPending, _TapCopyCounterFn, _TapCopyTimerFn
	global TAP_COPY_RETRIES, TAP_COPY_VERIFY_MS
	Pending := _TapCopyPending
	if !IsObject(Pending) || Pending["generation"] != Generation
		return
	if A_IsSuspended {
		_TapCopyCheckRetire(Pending, true)
		return
	}
	Counter := _TapCopyCounterFn.Call()
	if !_TapCopyCheckCurrent(Pending) {
		if A_IsSuspended
			_TapCopyCheckRetire(Pending, true)
		return
	}
	WaitedMs := Pending["attempts"] * TAP_COPY_VERIFY_MS
	if !(Counter is Integer) || Counter == 0 {
		if _TapCopyCheckRetire(Pending) && _TapCopyGenerationCurrent(Generation)
			try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} could not be checked (counter_unreadable).", Pending["source"])
		return
	}
	if Counter != Pending["baseline"] {
		if !_TapCopyCheckRetire(Pending) || !_TapCopyGenerationCurrent(Generation)
			return
		if Pending["attempts"] > 1 {
			try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} reached the clipboard only when sent again ({2} ms).", Pending["source"], WaitedMs)
		} else {
			try LoggerDebug("TapHoldCopy", "Tap-hold copy from {1} verified: the clipboard changed within {2} ms.", Pending["source"], WaitedMs)
		}
		return
	}
	if Pending["attempts"] > TAP_COPY_RETRIES {
		if !_TapCopyCheckRetire(Pending) || !_TapCopyGenerationCurrent(Generation)
			return
		try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} never reached the clipboard (not_copied after {2} ms); the user is warned.", Pending["source"], WaitedMs)
		_TapCopyWarnUser(Generation)
		return
	}
	Context := _TapCopyContext()
	if !_TapCopyCheckCurrent(Pending)
		return
	if !_TapCopySameContext(Pending["context"], Context) {
		if _TapCopyCheckRetire(Pending) && _TapCopyGenerationCurrent(Generation)
			try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} could not be retried because its original context is no longer proven.", Pending["source"])
		return
	}
	PreviousCritical := Critical("On")
	try {
		if !_TapCopyCheckCurrent(Pending)
			return
		Pending["attempts"] += 1
		Pending["baseline"] := Counter
	} finally Critical(PreviousCritical)
	Refusal := ""
	if !_TapCopyCheckCurrent(Pending)
		return
	try {
		if !Pending["send"].Call()
			Refusal := "the sender refused the keystroke"
	} catch as Err
		Refusal := Err.Message
	if !_TapCopyCheckCurrent(Pending)
		return
	if Refusal != "" {
		if !_TapCopyCheckRetire(Pending) || !_TapCopyGenerationCurrent(Generation)
			return
		try LoggerWarn("TapHoldCopy", "Tap-hold copy from {1} never reached the clipboard (retry_refused after {2} ms: {3}); the user is warned.", Pending["source"], WaitedMs, Refusal)
		_TapCopyWarnUser(Generation)
		return
	}
	_TapCopyTimerFn.Call(() => _TapCopyCheckTick(Generation), TAP_COPY_VERIFY_MS)
}

; Shows the localized notice; a refused notice is logged, never fatal.
_TapCopyWarnUser(Generation) {
	global _TapCopyWarnFn
	if !_TapCopyGenerationCurrent(Generation)
		return
	try {
		Shown := _TapCopyWarnFn.Call()
	} catch as Err {
		try LoggerError("TapHoldCopy", "Copy failure notice was not delivered: {1}.", Err.Message)
		return
	}
	if !Shown
		try LoggerError("TapHoldCopy", "Copy failure notice was not delivered.")
}

; Whether modifier Name is logically down. A global holding a function, as
; _AHK_SendInput is, so tests can stand in for the keyboard state.
global _TapHoldModifierIsHeld := (Name) => GetKeyState(Name)

; Send a tap-hold key's keystroke tap (Tab, Enter, an arrow, a shortcut) as the
; key itself would be typed: under every modifier held when it is sent. A plain
; Send lifts the modifiers the user holds on other keys, so Shift held then an
; AltGr tap gave Tab instead of Shift+Tab, while a modifier held by another
; tap-hold survived only because AHK never lifts the ones it pressed itself.
; {Blind} keeps them all, whatever their source. The tapped key's own hold
; modifier is released before its tap dispatches, so it is never among them.
; With nothing held the payload stays the bare key, the exact "{BackSpace}"
; the hotstring buffer recognizes as a plain edit.
; @param Key {String} AHK key name.
; @param Mods {Array} The keystroke's own modifiers ("Ctrl", "Shift", "Alt", "Win").
; @return {Boolean} The sender's verdict.
TapHoldEmitKeyTap(Key, Mods := []) {
	Modifiers := _TapHoldKeyTapModifiers(Mods)
	; Every Tab producer goes through the guarded LLM wrapper. A Tab tapped from
	; a tap-hold's dispatch is the user's own Tab key (AltGr taps Tab in the
	; recommended preset): it carries that key as its provenance and accepts a
	; shown prediction like the physical Tab. Outside a dispatch it only types.
	if (Key = "Tab" and Mods.Length == 0)
		return LLM_Tooltip_FireTabOrAccept(Modifiers, TapHoldTapProvenance())
	return TextPressKey(Key, Modifiers)
}

; TextPressKey modifiers for a keystroke tap: "Blind" and Mods when any
; modifier is held, Mods unchanged otherwise.
_TapHoldKeyTapModifiers(Mods) {
	if !TapHoldAnyModifierHeld()
		return Mods
	Words := "Blind"
	for _, ModifierName in Mods
		Words .= " " . ModifierName
	return Words
}

; Whether any modifier is logically down, whatever holds it: a physical key or
; a tap-hold's synthetic hold. Synthetic output typed under it must then carry
; {Blind}, or Send lifts the modifiers it did not press itself. The Kana
; layout's AltGr (VK_OEM_8) is deliberately not asked: AutoHotkey's Send does
; not treat it as a modifier and never lifts it, so a tap under it keeps it
; either way, and the bare payload ("{BackSpace}") stays the one the hotstring
; buffer recognizes as a plain edit.
; @return {Boolean}
TapHoldAnyModifierHeld() {
	global _TapHoldModifierIsHeld
	static Modifiers := ["LCtrl", "RCtrl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"]
	for _, Name in Modifiers {
		if _TapHoldModifierIsHeld.Call(Name)
			return true
	}
	return false
}

; Whether the layout's AltGr is held on a Kana-style layout, where it is a key
; AutoHotkey does not count as a modifier (VK_OEM_8). Tab, Space, Enter,
; Escape, Backspace and Delete stay the key itself under a held modifier on
; every driver, which on Windows their tap-hold hotkeys without * give for
; free: under a held Kana AltGr no modifier was down for AutoHotkey, so the
; hotkey matched and AltGr+Tab ran the Tab tap action (the window switcher)
; instead of the layout's AltGr+Tab. Their #HotIf asks this instead. The
; logical state counts the user's pass-through AltGr and a tap-hold's synthetic
; one. Elsewhere AltGr is LCtrl+RAlt or RAlt, modifiers AutoHotkey counts
; already, so this is false there. Read by parse-time #HotIf criteria, which are
; live before this file's globals exist.
; @return {Boolean}
TapHoldKanaAltGrHeld() {
	global _ALTGR_KANA_FIXUP, _TapHoldModifierIsHeld
	return IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP
		and IsSet(_TapHoldModifierIsHeld) and _TapHoldModifierIsHeld.Call(KS_AltGrKeyName())
}

; Whether the user physically holds LCtrl, AltGr's own LCtrl excluded. On a
; standard AltGr layout Windows adds a fake LCtrl to every AltGr press, which
; AutoHotkey records as physically down (hook.cpp: "For backward-compatibility,
; fake LCtrl is marked as physical"): "LCtrl physically held" was then true
; under AltGr alone, and AltGr+LAlt tapped as Backspace deleted a whole word
; (Ctrl+Backspace) where the Kana layout, whose AltGr adds no Ctrl, deleted one
; character. AutoHotkey keeps one physical LCtrl state for the real LCtrl and
; the fake one, so on such a layout a real LCtrl held with AltGr reads as
; AltGr's. Only there: QWERTY's right Alt is a plain Alt and a Kana AltGr is no
; RAlt, neither adds a fake LCtrl (KS_AltGrAddsFakeLCtrl), so a physical LCtrl
; is always the user's and LCtrl+RAlt then LAlt tapped as Backspace is the
; Ctrl+Backspace special. The native ledger does tell them apart (raw 0x21D is the
; alias), so a real LCtrl held with AltGr is the user's whenever an owner runs;
; with none running, the LCtrl under AltGr stays AltGr's, as AltGr alone needs. The
; ledger forgets a release missed on the secure desktop, so a stale LCtrl cannot
; turn a later AltGr alone into the user's Ctrl.
; @param KeyIsDownFn {Func} Test seam taking a key name, KS_IsDown by default.
; @param RealPressFn {Func} Test seam taking a key name, KS_RealPressState by default.
; @return {Boolean}
TapHoldUserLCtrlHeld(KeyIsDownFn := 0, RealPressFn := 0) {
	if !IsObject(KeyIsDownFn)
		KeyIsDownFn := KS_IsDown
	if !KeyIsDownFn.Call("SC01D")
		return false
	if !KS_AltGrAddsFakeLCtrl() or !KeyIsDownFn.Call("RAlt")
		return true
	if !IsObject(RealPressFn)
		RealPressFn := KS_RealPressState
	return RealPressFn.Call("SC01D") == 1
}

; Hand back the synthetic hold the owner of KeyId took for this press, now.
; Its owner then releases nothing more and dispatches no tap.
; @param KeyId {String} Tap-hold key id.
; @return {Boolean} True when a hold was handed back.
TapHoldRetractOwnedModifier(KeyId, ExpectedOwner := 0) {
	global _TH_OwnedModifiers, _TH_ModifierOwners, _TH_RetractedOwners
	PreviousCritical := Critical("On")
	try {
		if !_TH_OwnedModifiers.Has(KeyId) || !_TH_ModifierOwners.Has(KeyId)
			return false
		Owner := _TH_ModifierOwners[KeyId]
		if IsObject(ExpectedOwner) && Owner != ExpectedOwner
			return false
		if !TapHoldOwnerCurrent(Owner) || Owner.Retracted
			return false
		ModKey := _TH_OwnedModifiers[KeyId]
		Owner.Retracted := true
		_TH_RetractedOwners[KeyId] := Owner
	} finally Critical(PreviousCritical)
	if !_TapHoldReleaseOwnedModifier(ModKey, Owner)
		try LoggerError("TapHoldDispatch", "Could not hand back the hold of '{1}'.", KeyId)
	return true
}

; Whether KeyId's hold was handed back during this press; clears the mark.
_TH_TakeRetractedOwner(KeyId, ExpectedOwner := 0) {
	global _TH_RetractedOwners
	PreviousCritical := Critical("On")
	try {
		if !_TH_RetractedOwners.Has(KeyId)
			return false
		if IsObject(ExpectedOwner) && _TH_RetractedOwners[KeyId] != ExpectedOwner
			return false
		_TH_RetractedOwners.Delete(KeyId)
		return true
	} finally Critical(PreviousCritical)
}

; On a standard AltGr layout every AltGr press starts with a fake LCtrl, which
; the hook reads as SC01D (hook.cpp: "sc &= 0xFF") before it sees the RAlt. A
; left_ctrl tap-hold holding anything but Ctrl suppressed that fake LCtrl and
; pressed its own hold instead: the system then got the hold and RAlt without
; LCtrl, which is not AltGr, so the layout's AltGr characters were lost (and a
; lone RAlt opened the window menu). When the RAlt of that press arrives, the
; hold is handed back and, where the AltGr key is AltGr, LCtrl is held for it,
; so LCtrl+RAlt is AltGr again; the LCtrl ends with the left_ctrl press, which
; the AltGr release ends. Only on a layout with an AltGr level (the layout probe's
; "altgr_level"): on QWERTY right Alt is a plain Alt and LCtrl then RAlt is the
; user's own chord. A Kana layout has no fake LCtrl at all.
; @param AsAltGr {Boolean} True to give AltGr its LCtrl back, false when the
;        AltGr key holds another modifier (its owner presses that one).
; @return {Boolean} True when the press was AltGr's.
TapHoldAltGrTakesItsLCtrl(AsAltGr) {
	global _TapHoldKeyIsDown, _TH_OwnedModifiers, _TH_ModifierOwners, _TH_AltGrLCtrlOwners, _TH_AltGrPresses
	Companion := TapHoldNewOwner()
	if !KS_AltGrAddsFakeLCtrl()
		return false
	if !_TapHoldKeyIsDown.Call("SC01D", "P")
		return false
	PreviousCritical := Critical("On")
	try {
		if !TapHoldOwnerCurrent(Companion) || A_IsSuspended
			return true
		_TH_AltGrPresses["left_ctrl"] := true
		if !_TH_OwnedModifiers.Has("left_ctrl") || !_TH_ModifierOwners.Has("left_ctrl")
			return true
		Parent := _TH_ModifierOwners["left_ctrl"]
		if !TapHoldOwnerCurrent(Parent) || Companion.Epoch != Parent.Epoch
			return true
	} finally Critical(PreviousCritical)
	TapHoldRetractOwnedModifier("left_ctrl", Parent)
	if !AsAltGr
		return true
	PreviousCritical := Critical("On")
	try {
		if !TapHoldOwnerCurrent(Parent) || !_TH_ModifierOwners.Has("left_ctrl")
				|| _TH_ModifierOwners["left_ctrl"] != Parent || _TH_AltGrLCtrlOwners.Has("left_ctrl")
			return true
		Companion.Parent := Parent
		_TH_AltGrLCtrlOwners["left_ctrl"] := Companion
	} finally Critical(PreviousCritical)
	try {
		if !TapHoldSyntheticKeyDown("LCtrl", Companion)
			return true
	} finally {
		PreviousCritical := Critical("On")
		try {
			if (!TapHoldOwnerCurrent(Companion) || !Companion.Held)
					&& _TH_AltGrLCtrlOwners.Has("left_ctrl") && _TH_AltGrLCtrlOwners["left_ctrl"] == Companion
				_TH_AltGrLCtrlOwners.Delete("left_ctrl")
		} finally Critical(PreviousCritical)
	}
	return true
}

; Whether KeyId's current press was found to be AltGr's fake LCtrl; clears
; the mark. Read once when the press ends, and once when it begins so a mark
; left by a press that never reached its end cannot leak into the next one.
; @param KeyId {String} Tap-hold key id.
; @return {Boolean}
_TH_TakeAltGrPress(KeyId) {
	global _TH_AltGrPresses
	if !_TH_AltGrPresses.Has(KeyId)
		return false
	_TH_AltGrPresses.Delete(KeyId)
	return true
}

; Record a left_ctrl press in the typed stream once it has resolved: an LCtrl
; press ends a roll or hotstring sequence as a typed key does (the last-sent
; ring), unless it was the fake LCtrl an AltGr press begins with on an AltGr
; layout. That one reached the left_ctrl hotkey on every AltGr press and pushed
; "LControl", so a roll across AltGr characters ('<' then AltGr+the = key)
; never completed there. By the time the press has resolved, the AltGr that
; followed it has marked it (TapHoldAltGrTakesItsLCtrl), and no character has
; been typed yet.
TapHoldRecordLCtrlPress() {
	if !_TH_TakeAltGrPress("left_ctrl")
		UpdateLastSentCharacter("LControl")
}

; End the LCtrl held for AltGr by KeyId's press, if any.
; @return {Boolean} False only when its release could not be proven.
_TH_ReleaseAltGrLCtrl(KeyId, ExpectedParent := 0) {
	global _TH_AltGrLCtrlOwners
	PreviousCritical := Critical("On")
	try {
		if !_TH_AltGrLCtrlOwners.Has(KeyId)
			return true
		Owner := _TH_AltGrLCtrlOwners[KeyId]
		if IsObject(ExpectedParent) && Owner.Parent != ExpectedParent
			return true
		_TH_AltGrLCtrlOwners.Delete(KeyId)
	} finally Critical(PreviousCritical)
	return TapHoldSyntheticKeyUp("LCtrl", Owner)
}

; A key-down the hook passed to the system, seen by HookDispatcher: an AltGr
; RAlt claims the fake LCtrl a left_ctrl tap-hold took (TapHoldAltGrTakesItsLCtrl).
; The AltGr owner does the same when it suppresses that RAlt instead.
TapHoldTrackAltGrLCtrl(vk, sc) {
	if (TapHoldResolveKeyIdFromVkSc(vk, sc) == "alt_gr")
		TapHoldAltGrTakesItsLCtrl(AltGrKeyIsAltGr())
}
