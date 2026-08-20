; tests/meta/test_hse_send_transaction_guard.ahk

; ==============================================================================
; MODULE: HSE Send-Transaction Class Guard
; DESCRIPTION:
; Enumerates every production hotstring fire caller and raw callback so a new
; sibling cannot publish engine, preview, ring, or metric state without first
; consuming an explicit successful sender verdict. This protects AHK-04 at the
; class boundary instead of pinning only the dispatcher that exposed it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Class-wide transaction guards =======
; ================================================
; ================================================

_AHK04M_Count(Haystack, Needle) {
	Count := 0
	Pos := 1
	while Found := InStr(Haystack, Needle, true, Pos) {
		Count += 1
		Pos := Found + StrLen(Needle)
	}
	return Count
}

_AHK04M_AllDispatchCallersConsumeTheVerdict() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the AHK-04 class guard")
	; One definition plus the three user-reachable callers. A fourth caller raises
	; the count and must be added below with its own state/metric verdict checks.
	AssertEqual(4, _AHK04M_Count(Src, "HSE_DispatchMatch("),
		"every HSE_DispatchMatch caller must join the send-transaction guard")

	Activate := _DriverFuncBody("ActivateHotstrings")
	OnChar := _DriverFuncBody("_OnPrefixChar")
	SpaceTap := _DriverFuncBody("_SpaceTap")
	for Name, Body in Map(
		"ActivateHotstrings", Activate,
		"_OnPrefixChar", OnChar,
		"_SpaceTap", SpaceTap
	) {
		Assert(Body != "", Name . " must exist in the driver source")
	}
	Assert(InStr(Activate, "Fired := HSE_DispatchMatch") > 0
		and InStr(Activate, "&CommittedScreenEffect, true") > 0
		and InStr(Activate, "if Fired") > 0
		and InStr(Activate, "_PrefixCommitPostFireEffect(CommittedScreenEffect)") > 0,
		"ActivateHotstrings must force-consume its temporary completion key and finalize the proven effect only on fire")
	Assert(InStr(OnChar, "_HseFired := HSE_DispatchMatch") > 0
		and InStr(OnChar, "&CommittedScreenEffect") > 0
		and InStr(OnChar, "if _HseFired") > 0
		and InStr(OnChar, "if !_HseFired") > 0
		and InStr(OnChar, "_PrefixCommitPostFireEffect(CommittedScreenEffect)") > 0,
		"_OnPrefixChar must gate metrics and buffer sync on the dispatch verdict")
	Assert(InStr(SpaceTap, 'Fired := HSEMatch != "" and HSE_DispatchMatch') > 0
		and InStr(SpaceTap, "&CommittedScreenEffect") > 0
		and InStr(SpaceTap, "_PrefixCommitPostFireEffect(CommittedScreenEffect)") > 0,
		"_SpaceTap must consume the verdict and canonical effect before committing fire-only state")
}

_AHK04M_NormalDispatchCommitsAfterOutput() {
	Body := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Body != "", "HSE_DispatchMatch must exist in the driver source")
	NotepadSend := InStr(Body, "Fired := SendInstant")
	HookVerdict := InStr(Body, 'Fired := _SendVerdictSucceeded(Hook("SendFinalResult", Burst, false))')
	AtomicSend := InStr(Body, "SendInput(Burst)")
	DirectCommit := InStr(Body, "Fired := true", , AtomicSend)
	Apply := InStr(Body, "HSE_ApplyExpansion")
	Assert(NotepadSend > 0 and HookVerdict > 0 and AtomicSend > HookVerdict
		and DirectCommit > AtomicSend,
		"both normal fire branches must publish success only after their atomic sender succeeds")
	Assert(Apply > NotepadSend and Apply > AtomicSend,
		"HSE_ApplyExpansion must run only after the selected output branch succeeds")
	Assert(_AHK04M_Count(Body, "if !Fired") >= 2,
		"both Notepad and atomic branches must abort on failed output")
	Assert(InStr(Body, "if (Fired and IsSet(_ResetPrefixBuffer))") > 0,
		"the preview reset must be gated on output success")
	Assert(InStr(Body, "catch as Err", , AtomicSend) > AtomicSend,
		"the direct atomic SendInput path must convert an OS exception into a failed transaction")
}

_AHK04M_SendInstantPreparesCleanupBeforeInjection() {
	Body := _StripFullLineComments(_DriverFuncBody("SendInstant"))
	Assert(Body != "", "SendInstant must exist in the driver source")
	Arm := InStr(Body, "SetTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)")
	Inject := InStr(Body, 'SendInput(Prefix . "^v")')
	Cancel := InStr(Body, "SetTimer(RestoreCallback, 0)")
	Assert(Arm > 0 and Inject > Arm,
		"SendInstant must arm clipboard cleanup before its irreversible erase/paste injection")
	Assert(Cancel > Inject,
		"SendInstant must cancel the exact armed callback when injection itself fails")
}

_AHK04M_RawCallbackClassDeclaresAStatus() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the raw-callback class guard")
	; One builder definition plus the deadkey and ellipsis registrations. A new raw
	; callback changes this count and must declare the same {Ok, Bs, Ins} contract.
	AssertEqual(3, _AHK04M_Count(Src, "CreateRawCallbackHotstring("),
		"every raw callback registration must join the explicit transaction contract")

	for Name in ["ShouldActivateDeadkey", "_EllipsisRawCallback"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must exist in the driver source")
		Assert(InStr(Body, "if SendNewResult(") > 0,
			Name . " must gate its buffer effect on sender success")
		Assert(InStr(Body, "Ok: true") > 0 and InStr(Body, "Ok: false") > 0,
			Name . " must return an explicit {Ok, Bs, Ins} transaction verdict")
	}

	Dispatch := _StripFullLineComments(_DriverFuncBody("_HSE_DispatchRawCallback"))
	Owner := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Dispatch != "", "_HSE_DispatchRawCallback must exist in the driver source")
	Assert(Owner != "", "HSE_DispatchMatch must exist in the driver source")
	Gate := InStr(Dispatch, 'Effect.HasOwnProp("Ok")')
	Mutation := InStr(Dispatch, "HSE_Buffer :=")
	Assert(Gate > 0 and Mutation > Gate,
		"raw callback effects must be validated before HSE_Buffer is mutated")
	Assert(InStr(Dispatch, "if (Fired and IsSet(_ResetPrefixBuffer))") > 0,
		"raw callback preview reset must remain gated on a proven fire")
	Assert(InStr(Dispatch, "CommittedEffect := CanonicalEffect") > Mutation,
		"a successful raw callback must publish its exact post-screen effect to the prefix watcher")
	Assert(InStr(Owner, "_HSE_DispatchRawCallback(Spec, EndChar, &CommittedEffect)") > 0,
		"HSE_DispatchMatch must forward the canonical-effect output across the raw callback branch")
}

_AHK04M_UIAWrapperPreparesBeforeErasing() {
	Wrap := _StripFullLineComments(_DriverFuncBody("_PrefixTryWrapSelection"))
	OnChar := _DriverFuncBody("_OnPrefixChar")
	Assert(Wrap != "", "_PrefixTryWrapSelection must exist in the driver source")
	Assert(OnChar != "", "_OnPrefixChar must exist in the driver source")
	SendAt := InStr(Wrap, 'Wrapped := SendInstant(Left . Selection . Right, "{BackSpace}")')
	SuccessGate := InStr(Wrap, "if Wrapped")
	ResetTransaction := InStr(Wrap, "_PrefixInvalidateInputContext(", true, SuccessGate)
	ResetHelper := _StripFullLineComments(_DriverFuncBody("_PrefixInvalidateInputContext"))
	ResetCommitHelper := _StripFullLineComments(_DriverFuncBody("_PrefixCommitInputContext"))
	EnterCritical := InStr(ResetHelper, 'Critical("On")')
	CommitCall := InStr(ResetHelper, "_PrefixCommitInputContext(FocusToken, KnownBoundary)", true, EnterCritical)
	LeaveCritical := InStr(ResetHelper, "Critical(PreviousCritical)", true, CommitCall)
	ResetEngine := InStr(ResetCommitHelper, "HSE_FeedReset(")
	ResetPreview := InStr(ResetCommitHelper, '_PrefixSetBuffer("")', true, ResetEngine)
	Assert(SendAt > 0,
		"UIA wrapping must pass the physical-symbol erase as SendInstant's atomic prefix")
	Assert(InStr(Wrap, "SendEvent(") = 0,
		"UIA wrapping must not erase the physical fallback before clipboard preparation")
	Assert(SuccessGate > SendAt and ResetTransaction > SuccessGate,
		"the paired UIA buffer reset must run only after wrapped output succeeds")
	Assert(EnterCritical > 0 and CommitCall > EnterCritical and LeaveCritical > CommitCall
		and ResetEngine > 0 and ResetPreview > ResetEngine,
		"the UIA reset helper must publish engine and preview invalidation in one Critical transaction")
	Assert(InStr(OnChar, "if _PrefixTryWrapSelection(UIASel, Pair)") > 0,
		"_OnPrefixChar must fall through to normal character handling when wrapping fails")
}

_AHK04M_ForcedCommitAndSpaceFallbackAreTransactional() {
	Activate := _StripFullLineComments(_DriverFuncBody("ActivateHotstrings"))
	SpaceTap := _StripFullLineComments(_DriverFuncBody("_SpaceTap"))
	Assert(Activate != "", "ActivateHotstrings must exist in the driver source")
	Assert(SpaceTap != "", "_SpaceTap must exist in the driver source")
	PokeGate := InStr(Activate, 'if !SendNewResult(" ", true, false)')
	PokeFeed := InStr(Activate, 'HSE_FeedChar(" ", true)')
	PokeLlm := InStr(Activate, '_HSE_MirrorLiteralEditToLlm(0, " ")')
	ForcedDispatch := InStr(Activate, "&CommittedScreenEffect, true")
	FireMetricGate := InStr(Activate, "if Fired", true, ForcedDispatch)
	FireReturnGate := InStr(Activate, "if Fired", true, FireMetricGate + 1)
	FireReturn := InStr(Activate, "return true", true, FireReturnGate)
	CleanupGate := InStr(Activate, 'if !SendNewResult("{BackSpace}", False, false)')
	CleanupFailureRing := InStr(Activate, 'UpdateLastSentCharacter(" ")', true, CleanupGate)
	CleanupFeed := InStr(Activate, "HSE_FeedBackspace(true)", true, CleanupGate)
	CleanupLlm := InStr(Activate, "_HSE_MirrorLiteralEditToLlm(1)", true, CleanupFeed)
	Assert(PokeGate > 0 and PokeFeed > PokeGate,
		"forced end-char commit must not feed a poke that failed to reach the screen")
	Assert(PokeLlm > PokeFeed and ForcedDispatch > PokeLlm,
		"forced end-char commit must put the temporary Space in HSE and LLM before dispatch")
	Assert(FireReturnGate > FireMetricGate and FireReturn > FireReturnGate
		and CleanupGate > FireReturn,
		"a successful forced dispatch must return before the no-fire cleanup can erase replacement output")
	Assert(CleanupFailureRing > CleanupGate and CleanupFeed > CleanupFailureRing
		and CleanupLlm > CleanupFeed,
		"failed cleanup must retain/ring the visible Space, while successful cleanup mutates HSE and LLM only after its backspace succeeds")
	SpacePress := InStr(SpaceTap, 'if !TextPressKey("Space", "")')
	SpaceFeed := InStr(SpaceTap, 'HSE_FeedChar(" ", true)')
	SpaceLlm := InStr(SpaceTap, '_HSE_MirrorLiteralEditToLlm(0, " ")')
	SpaceDispatch := InStr(SpaceTap, "HSE_DispatchMatch")
	Assert(SpacePress > 0 and SpaceFeed > SpacePress and SpaceLlm > SpaceFeed
		and SpaceDispatch > SpaceLlm and InStr(SpaceTap, "HSE_FeedBackspace") == 0,
		"intercepted Space must be proven on screen before both buffers are fed, with no speculative rollback path")
}

Test("meta hotstrings: all fire callers consume the sender verdict (AHK-04-send-transaction)",
	_AHK04M_AllDispatchCallersConsumeTheVerdict)
Test("meta hotstrings: normal fire state follows output success (AHK-04-send-transaction)",
	_AHK04M_NormalDispatchCommitsAfterOutput)
Test("meta hotstrings: clipboard cleanup is prepared before injection (AHK-04-send-transaction)",
	_AHK04M_SendInstantPreparesCleanupBeforeInjection)
Test("meta hotstrings: raw callback class declares status (AHK-04-send-transaction) (raw-callback-canonical-effect)",
	_AHK04M_RawCallbackClassDeclaresAStatus)
Test("meta hotstrings: UIA wrapping prepares before erase (AHK-04-send-transaction)",
	_AHK04M_UIAWrapperPreparesBeforeErasing)
Test("meta hotstrings: forced commit and Space fallback are transactional (AHK-04-send-transaction)",
	_AHK04M_ForcedCommitAndSpaceFallbackAreTransactional)
