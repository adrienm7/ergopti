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

; Retained as an inert compatibility sentinel for lifecycle code which can run
; across a live reload from an older build. The immediate owner below no longer
; creates a Space InputHook.
global _SpaceHoldInputHook := ""





; ========================
; ========================
; ======= 5/ SPACE =======
; ========================
; ========================

; Design: Space that keeps its own key on a tap is decided by the order of
; the releases (tap_hold_roll.ahk): a letter struck before Space comes up is
; typed after the space, not under the hold. With a tap that is an action,
; both modifier and layer ownership begin synchronously on physical Space
; down, and only a quick, otherwise isolated press emits the tap action.
; The owned-press swallower at the end of this file silences Space's own
; auto-repeat while either hold is active.
;
; After sending Space on tap, HSE_FeedChar(" ") is called explicitly because
; SendInput bypasses the prefix-watcher InputHook.

SpaceTapHold() {
	Result := TapHoldOwnHoldModifier("space", "SC039",
		_SpaceHoldModKey(), TapHoldDuration(TapHold, "space"), _SpaceTapOrDispatch)
	if Result["tap"]
		_SpaceTapOrDispatch()
}

SpaceTapHoldLayer() {
	Result := TapHoldOwnHoldLayer("space", "SC039", TapHoldDuration(TapHold, "space"), _SpaceTapOrDispatch)
	if Result["tap"] {
		_SpaceTapOrDispatch()
		return
	}
	; A press the roll owner already typed as a tap recorded its own space.
	if (Result.Get("decision", "") == "tap")
		return
	UpdateLastSentCharacter("Space")
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
		global HSE_LastEndChar, _PrefixPrivateResidue
		try {
				; SC039 is suppressing, so the physical tap is not on screen yet. Emit it
				; before feeding the engine: HSE_DispatchMatch's backspace count includes
				; the end character and may only erase text which has actually landed.
				if !TextPressKey("Space", "")
						return false

				; IsPhysical=true: this space came from a real key tap, not the engine's
				; SendInput. Mirror the same proven screen character into the longer LLM
				; context inside this Critical transaction; the I1 watcher deliberately
				; ignores TextPressKey's synthetic replacement send.
				HSEMatch := HSE_FeedChar(" ", true)
				_HSE_MirrorLiteralEditToLlm(0, " ")
				CommittedScreenEffect := 0
				Fired := HSEMatch != "" and HSE_DispatchMatch(
						HSEMatch, HSE_LastEndChar, &CommittedScreenEffect)
				if (Fired is Map) && Fired.Has("Pending")
						return true
				if Fired {
						HotstringCategory := HSEMatch.HasOwnProp("IsRepeat") && HSEMatch.IsRepeat
								? "repeat_key"
								: (HSEMatch.HasOwnProp("Category") ? HSEMatch.Category : "")
						HotstringSection := HSEMatch.HasOwnProp("Section") ? HSEMatch.Section : ""
						HotstringRepl := HSEMatch.HasOwnProp("Replacement") ? HSEMatch.Replacement : HSEMatch.Trigger
						HotstringIsPrivate := HSEMatch.HasOwnProp("IsPrivate") && HSEMatch.IsPrivate
						if HotstringIsPrivate and IsSet(_PrefixPrivateResidue)
								_PrefixPrivateResidue := true
						; Consume the engine's canonical effect instead of re-deriving whether
						; the end character was emitted or consumed. The dispatcher owns the
						; output ring on this branch, so recording Space here would duplicate it.
						if IsSet(_PrefixCommitPostFireEffect)
								_PrefixCommitPostFireEffect(CommittedScreenEffect)
						if IsSet(_HSE_QueueFireLog)
								try _HSE_QueueFireLog(HSEMatch.Trigger, HotstringRepl, "endchar", HotstringCategory, HotstringSection, HotstringIsPrivate)
						return true
				}

				; No candidate, or a candidate which declined: the already-emitted Space
				; is the user's literal output. HSE and LLM already contain it; reset the
				; boundary preview and publish it to the ring exactly once.
				if IsSet(_ResetPrefixBuffer)
						try _ResetPrefixBuffer()
				UpdateLastSentCharacter(" ")
				return true
		} finally {
				Critical(PrevCrit ? PrevCrit : "Off")
		}
}

_SpaceHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "space"), "space")
}


; Tap-only (hold=none, tap action set to something other than space).
; No $ needed: AHK v2 defaults to #MaxThreadsPerHotkey 1 so auto-repeat
; cannot spawn a second thread while this handler is still executing.
#HotIf TapHoldTapAction(TapHold, "space") != "" and TapHoldTapAction(TapHold, "space") != "space" and TapHoldHoldModifier(TapHold, "space") == "" and TapHoldHoldLayer(TapHold, "space") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
SC039:: _SpaceDispatch()
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled and not TapHoldKanaAltGrHeld()
SC039:: SpaceTapHoldLayer()
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") != "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
SC039:: SpaceTapHold()
#HotIf

; The hold variants fire only with no modifier held, so the key stays itself
; under a held modifier, as on every driver. Its own auto-repeat arrives under
; the modifier or layer the hold owns and matches none of them: swallow it for
; as long as the owner resolves the press (see TapHoldPressIsOwned).
; An exact chord beats the wildcard: Space held as Shift repeated the layout
; emulation's Shift+Space hotkey. The bare key and every chord of Ctrl, Alt,
; Shift and Win are therefore declared too; a static variant is created before
; every Hotkey() one, and the first eligible variant of an identity fires.
#HotIf TapHoldPressIsOwned("space")
*SC039::
SC039::
^SC039::
!SC039::
^!SC039::
+SC039::
^+SC039::
!+SC039::
^!+SC039::
#SC039::
^#SC039::
!#SC039::
^!#SC039::
+#SC039::
^+#SC039::
!+#SC039::
^!+#SC039::
{
	return
}
#HotIf
