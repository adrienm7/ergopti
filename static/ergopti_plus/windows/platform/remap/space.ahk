; platform/remap/space.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Space
; DESCRIPTION:
; Space tap-hold variants: Ctrl on hold, navigation Layer on hold, Shift on
; hold. SpaceTapHold() is the shared tap/hold dispatcher; each variant below
; hooks it to the appropriate hold-action function.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Multiplier applied to the tap-hold duration to derive the InputHook capture
; window — long enough that any realistic next keystroke lands before the hook
; times out, but short enough to avoid an indefinite wait if no key follows
global SPACE_HOLD_INPUT_TIMEOUT_FACTOR := 15
global _SpaceHoldInputHook := ""
global _SpaceHoldOwnerReleased := false





; ========================
; ========================
; ======= 5/ SPACE =======
; ========================
; ========================

; Design: two-phase tap/hold, modifier never held during auto-repeat window.
;
; Phase 1 — KeyWait with timeout discriminates tap from hold:
;   tap=1 → Space released before threshold → send Space.
;   tap=0 → Space held past threshold → enter hold phase.
;
; Phase 2 (hold, modifier variants) — InputHook L1 captures the next key
; without any modifier active, so Space auto-repeat cannot produce
; Shift+Space or Ctrl+Space. After the IH resolves, HoldFn receives
; ih.Input (the translated char) and emits the correct modified keystroke.
;
; Phase 2 (hold, layer variant) — mirrors LAlt: the layer is activated
; immediately at hold-threshold so physical keys land directly on the
; #HotIf LayerEnabled hotkeys. No InputHook is used; nav_layer.ahk
; already has SC039::return to silence Space auto-repeat while the layer
; is active.
;
; After sending Space on tap, HSE_FeedChar(" ") is called explicitly because
; SendInput bypasses the prefix-watcher InputHook.

SpaceTapHold(HoldFn) {
	global _SpaceHoldOwnerReleased
	TimeoutSec := TapHoldDuration(TapHold, "space")
	tap := KeyWait("SC039", "T" . TimeoutSec)
	if tap {
		_SpaceTapOrDispatch()
		return
	}
	InputTimeoutSec := TimeoutSec * SPACE_HOLD_INPUT_TIMEOUT_FACTOR ; Proportional window — slow typist must not time out
		ih := InputHook("L1 T" . Round(InputTimeoutSec, 1))
		; The capture belongs to the physical Space hold.  End it as soon as the
		; owner is released instead of keeping a suppressing L1 hook alive for the
		; next printable key.
		_SpaceHoldOwnerReleased := false
		ih.KeyOpt("{SC039}", "+N")
		ih.OnKeyUp := _SpaceHoldOnKeyUp
		global _SpaceHoldInputHook := ih
		try {
				ih.Start()
				ih.Wait()
		} finally {
				try ih.Stop()
				_SpaceHoldInputHook := ""
		}
	if _SpaceHoldOwnerReleased
		return
	; A live InputHook bypasses native Suspend; if a pause arrived while Wait() was
	; blocking, discard the capture so no phantom modified keystroke leaks into the
	; foreground app while the driver is paused (space-hold-inputhook-suspend-guard).
	if A_IsSuspended
		return
	HoldGuardMs := TapHoldDuration(TapHold, "space") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("space", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "Space hold suppressed because scroll activity was detected during hold window.")
		return
	}
	; Skip modifier on empty capture — no phantom modifier on empty chord.
	if (ih.Input != "" and ih.Input != " ")
		HoldFn.Call(ih.Input)
	KeyWait("SC039", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
}

; InputHook callbacks receive (hook, virtual-key, scan-code).  SC039 is the
; physical owner of this transaction; stopping before the next key arrives
; prevents the hook from swallowing that key after a completed Space hold.
_SpaceHoldOnKeyUp(ih, vk, sc) {
	global _SpaceHoldOwnerReleased
	if (sc != 0x039)
		return
	_SpaceHoldOwnerReleased := true
	try ih.Stop()
}

SpaceTapHoldLayer() {
		; Two-phase detection to avoid a CapsLock LED flash on tap:
		; Phase 1 — wait for the hold threshold; if Space is released first it was
		;            a tap, so send Space and return without ever activating the layer.
		; Phase 2 — threshold elapsed → real hold; activate the layer and let every
		;            subsequent physical key land on #HotIf LayerEnabled hotkeys.
		;            Disable the layer once Space is released.
		TimeoutSec := TapHoldDuration(TapHold, "space")
		tap := KeyWait("SC039", "T" . TimeoutSec)
		if tap {
				_SpaceTapOrDispatch()
				return
		}
		UpdateLastSentCharacter("Space")
		ActivateLayer()
		try {
				; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
				; must never latch it forever if the key-up event is lost. A hold LAYER holds no
				; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
				; dropped the layer out from under the user after five seconds of legitimate
				; navigation, and base-layer letters then landed in the document until it
				; re-armed. Re-arm the wait instead while the key is still physically down: every
				; iteration stays bounded, which is the property test_hold_layer_release_bounded
				; pins, and a timeout with the key already up means the key-up really was lost --
				; exactly the case the failsafe exists for.
				while !KeyWait("SC039", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
						if !GetKeyState("SC039", "P")
								break
				}
		} finally {
				DisableLayer()
		}
}

; Tap: send the configured tap action, or native Space if none / "space".
_SpaceTapOrDispatch() {
	_SpaceDispatch()
}

_SpaceDispatch() {
	local action := TapHoldTapAction(TapHold, "space")
	; "space" tap must go through _SpaceTap() to feed the hotstring engine.
	if (action == "space" or action == "") {
		TapHoldDispatchTap("space", _SpaceTap)
		return
	}
	_TapHoldFireAction("space")
}

_SpaceTap() {
		PrevCrit := A_IsCritical
		Critical("On")
		global HSE_LastEndChar
		; IsPhysical=true: this space came from a real key tap, not the engine's own
		; SendInput. Without the flag it is discarded whenever it lands inside the ~60 ms
		; post-expansion suppress window (which exists to filter the engine's output), so
		; the space silently never reaches the buffer and the next trigger mis-frames.
		HSEMatch := HSE_FeedChar(" ", true)
		; A match is only a CANDIDATE. HSE_DispatchMatch declines on the
		; time-activation gate, a mixed-case conform verdict, or a raw callback that
		; refused — and it says so through its return value. Discarding that verdict
		; swallowed the space entirely: no expansion reached the screen, no space was
		; typed, and KL_LogHotstring still recorded a fire that never happened while
		; HSE_Buffer kept a space the screen did not have. Falling through to the
		; literal-space path below is what makes the declined case indistinguishable
		; from "there was never a match". Same class as 356ba64c0's _OnPrefixChar
		; fix, at the sibling site it missed.
		if (HSEMatch != "" and HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)) {
				HotstringCategory := HSEMatch.HasOwnProp("IsRepeat") && HSEMatch.IsRepeat
						? "repeat_key"
						: (HSEMatch.HasOwnProp("Category") ? HSEMatch.Category : "")
				HotstringSection := HSEMatch.HasOwnProp("Section") ? HSEMatch.Section : ""
				HotstringRepl := HSEMatch.HasOwnProp("Replacement") ? HSEMatch.Replacement : HSEMatch.Trigger
				; Carried through for the same reason the prefix-watcher path carries
				; it: this sibling reaches the same metrics sink, and a fix applied to
				; only one of the three fire paths leaks from the other two.
				HotstringIsPrivate := HSEMatch.HasOwnProp("IsPrivate") && HSEMatch.IsPrivate
				; Queue the metrics record instead of writing it here. This runs under
				; Critical("On") on the keystroke thread, BEFORE the post-expansion
				; suppress release, and KL_LogHotstring is a buffer flush plus a JSONL
				; append plus WPM pushes — a disk spike inside that window swallows the
				; next physical keys (the abcd→acd class). The prefix-watcher fire path
				; was moved off KL_LogHotstring onto this queue for exactly that reason;
				; this sibling kept the synchronous call.
				if IsSet(_HSE_QueueFireLog)
						try _HSE_QueueFireLog(HSEMatch.Trigger, HotstringRepl, "endchar", HotstringCategory, HotstringSection, HotstringIsPrivate)
				UpdateLastSentCharacter(" ")
				Critical(PrevCrit ? PrevCrit : "Off")
				return
		}
		TextPressKey("Space", "")
		if IsSet(_ResetPrefixBuffer)
				try _ResetPrefixBuffer()
		UpdateLastSentCharacter(" ")
	Critical(PrevCrit ? PrevCrit : "Off")
}

_SpaceHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "space"), "space")
}

_SpaceHoldWithModifier(captured) {
	ModKey := _SpaceHoldModKey()
	if (ModKey == "") {
		_SpaceTapOrDispatch()
		return
	}
	TapHoldSyntheticKeyDown(ModKey)
	try {
		if (captured != "" and captured != " ")
			_SpaceSendWithModifiers(captured, ModKey)
		KeyWait("SC039", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}

_SpaceSendWithModifiers(captured, modKey) {
	Prefix := ""
	if (modKey is Array) {
		Prefix := _TextSenderModifierPrefixFromArray(modKey)
	} else if (modKey is String) {
		Prefix := _TextSenderModifierString(modKey)
	}
	if (Prefix == "") {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "No space hold prefix resolved for '{1}'. Falling back to raw key send.", modKey)
		Prefix := ""
	}
	_AHK_SendInput.Call(Prefix . RegExReplace(captured, "([!#^+{}])", "{$1}"))
}

; Tap-only (hold=none, tap action set to something other than space).
; No $ needed: AHK v2 defaults to #MaxThreadsPerHotkey 1 so auto-repeat
; cannot spawn a second thread while this handler is still executing.
#HotIf TapHoldTapAction(TapHold, "space") != "" and TapHoldTapAction(TapHold, "space") != "space" and TapHoldHoldModifier(TapHold, "space") == "" and TapHoldHoldLayer(TapHold, "space") == "" and not LayerEnabled
SC039:: _SpaceDispatch()
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
SC039:: SpaceTapHoldLayer()
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") != "" and not LayerEnabled
SC039:: SpaceTapHold(_SpaceHoldWithModifier)
#HotIf
