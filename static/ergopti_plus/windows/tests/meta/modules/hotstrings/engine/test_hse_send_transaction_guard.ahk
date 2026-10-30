; tests/meta/modules/hotstrings/engine/test_hse_send_transaction_guard.ahk

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
	; One definition plus four user-reachable callers. A new caller raises the
	; count and must join these exact state/publication verdict checks.
	AssertEqual(5, _AHK04M_Count(Src, "HSE_DispatchMatch("),
		"every HSE_DispatchMatch caller must join the send-transaction guard")

	; ActivateHotstrings' verdict is driven in test_activate_hotstrings_commits_synchronously.ahk.
	OnChar := _DriverFuncBody("_OnPrefixChar")
	SpaceTap := _DriverFuncBody("_SpaceTap")
	for Name, Body in Map(
		"_OnPrefixChar", OnChar,
		"_SpaceTap", SpaceTap
	) {
		Assert(Body != "", Name . " must exist in the driver source")
	}
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
	Programmable := _DriverFuncBody("_UserHotstringsCommit")
	DispatchAt := InStr(Programmable, 'Verdict := HSE_DispatchMatch(Spec, "", &Effect)')
	PendingAt := InStr(Programmable, 'return Verdict.Has("Pending")', true, DispatchAt)
	RefusalAt := InStr(Programmable, "if !Verdict", true, PendingAt)
	CommitAt := InStr(Programmable, "_PrefixCommitPostFireEffect(Effect)", true, RefusalAt)
	Assert(DispatchAt > 0 && PendingAt > DispatchAt && RefusalAt > PendingAt && CommitAt > RefusalAt,
		"programmable output must transfer deferred ownership or consume successful dispatch before publishing canonical effects")
	Assert(InStr(Programmable, "PublicationCurrent: _UserHotstringsPublicationCurrent.Bind(") > 0,
		"programmable output must retain its source/control/enable receipt through deferred terminal publication")
	ReplayVisible := _DriverFuncBody("_HSE_ReplayVisibleTerminalChars")
	Assert(InStr(ReplayVisible, "_OnPrefixChar(0, Char)") > 0,
		"visible pre-admission suffixes must re-enter the real matcher after canonical commit")
	InputHookBody := _DriverFuncBody("_OnPrefixChar")
	Assert(InStr(InputHookBody, "_HSE_RetainTerminalReplayChar(Char)") > 0,
		"partial native replay callbacks must remain ordered behind visible suffixes")
}

/** Checks the actual asynchronous completion owner separately from keyboard dispatch. */
_AHK04M_NativeCommitPolicy(Commit := unset, Finish := unset, Complete := unset) {
	_NHAB_AssertNativeRoute()
	if !IsSet(Commit)
		Commit := _DriverFuncBody("_HSE_CommitNotepadOwner")
	if !IsSet(Finish)
		Finish := _DriverFuncBody("_HSE_FinishNotepadCommit")
	if !IsSet(Complete)
		Complete := _DriverFuncBody("_HSE_CompleteNotepadOwner")
	Assert(Commit != "" && Finish != "" && Complete != "", "native commit and completion owners must exist")
	Code := _DriverMaskNonCode(&Commit)
	CriticalGuard := InStr(Code, "if !A_IsCritical")
	OwnerGuard := InStr(Code, "if _HSE_TerminalOwner != Owner")
	ContextGuard := InStr(Code, "if A_IsSuspended || HSE_Buffer != Owner[")
	Mutation := InStr(Code, "HSE_Buffer := SubStr(HSE_Buffer,")
	Mirror := InStr(Code, "_HSE_MirrorCanonicalEffectToLlm(Effect)")
	Assert(CriticalGuard > 0 && OwnerGuard > CriticalGuard && ContextGuard > OwnerGuard && Mutation > ContextGuard,
		"native canonical mutation must retain Critical, exact owner and original context guards")
	Assert(Mirror > Mutation, "native canonical mirroring follows the admitted engine edit")
	Assert(RegExMatch(Code, "i)Owner\[\s*\]\s*:=\s*true", &ClaimCode),
		"native commit must claim the verified canonical effect")
	Claim := ClaimCode.Pos
	Assert(RegExMatch(SubStr(Commit, Claim), 'i)^Owner\["Committed"\]\s*:=\s*true'),
		"the canonical claim must belong to the actual Committed field")
	Finalizer := InStr(Code, "return _HSE_FinishNotepadCommit.Bind(Owner)")
	Assert(Claim > Mirror && Finalizer > Claim, "native commit claims its effect before returning presentation")
	FinishCode := _DriverMaskNonCode(&Finish)
	Fire := InStr(FinishCode, "_HSE_QueueFireLog(")
	Assert(RegExMatch(FinishCode, "i)Owner\[\s*\]\s*:=\s*true", &FinishClaim),
		"native fire finalizer must contain its actual once-only claim")
	Assert(RegExMatch(SubStr(Finish, FinishClaim.Pos), 'i)^Owner\["FinalizerClaimed"\]\s*:=\s*true'),
		"the finalizer claim belongs to the real FinalizerClaimed field")
	Assert(Fire > 0 && FinishClaim.Pos > 0 && FinishClaim.Pos < Fire,
		"native fire metrics must be claimed once by the post-commit finalizer")
	CompleteCode := _DriverMaskNonCode(&Complete)
	Assert(RegExMatch(CompleteCode, "i)Owner\[\s*\]\s*:=\s*\(Ok\s+is\s+Integer\)\s*&&\s*Ok\s*==\s*true\s*&&\s*Owner\[\s*\]", &Success),
		"native completion requires a typed sender and canonical commit")
	Assert(RegExMatch(SubStr(Complete, Success.Pos), 'i)^Owner\["FinalSucceeded"\]\s*:=\s*\(Ok\s+is\s+Integer\)\s*&&\s*Ok\s*==\s*true\s*&&\s*Owner\["Committed"\]'),
		"the actual final success field must consume the canonical Committed receipt")
	Assert(!RegExMatch(CompleteCode, "i)\b(?:HSE_ApplyExpansion|_HSE_QueueFireLog)\s*\("),
		"native completion cannot apply an effect or publish a fire from pending admission")
}

_AHK04M_NormalDispatchCommitsAfterOutput() {
	Body := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Body != "", "HSE_DispatchMatch must exist in the driver source")
	_AHK04M_NativeCommitPolicy()
	; The native branch returns its receipt; the atomic keyboard branch alone
	; publishes Fired inline from its owned AltGr lift and sender verdict.
	Branch := _NHAB_NativeBranch(Body)
	BranchCode := _DriverMaskNonCode(&Branch)
	Assert(!RegExMatch(BranchCode, "i)\b(?:HSE_ApplyExpansion|_HSE_QueueFireLog|_HSE_SendWithAltGrUp)\s*\("),
		"native scheduling cannot publish a fire or lift a keyboard modifier")
	HookVerdict := InStr(Body, 'return _SendVerdictSucceeded(Hook("SendFinalResult", Burst, false))')
	AtomicSend := InStr(Body, "_AHK_SendInput.Bind(Burst)")
	DirectVerdict := InStr(Body, "return true", , AtomicSend)
	DirectCommit := InStr(Body, "Fired := _HSE_SendWithAltGrUp(SendAtomicBurst)", , DirectVerdict)
	Apply := InStr(Body, "HSE_ApplyExpansion")
	Assert(HookVerdict > 0 && AtomicSend > HookVerdict && DirectVerdict > AtomicSend && DirectCommit > DirectVerdict,
		"both atomic sender implementations must publish success only after their sender succeeds")
	Assert(Apply > AtomicSend && Apply > DirectCommit, "inline HSE expansion must follow the proven atomic sender verdict")
	Assert(_AHK04M_Count(Body, "if !Fired") >= 2,
		"terminal and atomic keyboard dispatch must abort on failed output")
	Assert(InStr(Body, "if (!TerminalOwnershipTransferred and Fired and IsSet(_ResetPrefixBuffer))") > 0,
		"the preview reset remains gated on inline success outside transferred ownership")
	Assert(InStr(Body, "catch as Err", , AtomicSend) > AtomicSend,
		"the direct atomic SendInput path converts an OS exception into a failed transaction")
}

_AHK04M_NativePolicyRefusesMissingCommitGuard() {
	Commit := _DriverFuncBody("_HSE_CommitNotepadOwner")
	_AHK04M_NativeCommitPolicy(Commit)
	Bad := StrReplace(Commit, "if _HSE_TerminalOwner != Owner", "if false", true, &Changed)
	AssertEqual(1, Changed, "the inverse removes exactly the actual native owner admission guard")
	Refused := false
	try _AHK04M_NativeCommitPolicy(Bad)
	catch as Err {
		if Type(Err) != "Error" || InStr(Err.Message,
			"native canonical mutation must retain Critical, exact owner and original context guards", true) != 1
			throw Err
		Refused := true
	}
	AssertTrue(Refused, "the actual policy must reject an ownerless canonical commit")
}
Test("meta hotstrings: native canonical admission guard cannot be removed (AHK-04-send-transaction)",
	_AHK04M_NativePolicyRefusesMissingCommitGuard)

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

	; The callbacks and their publication are driven in test_hse_dispatch_behaviour.ahk,
	; their registration in test_hse_send_failure_transaction.ahk (notepad-raw-registration).
	TerminalDispatch := _StripFullLineComments(_DriverFuncBody("_HSE_DispatchTerminalRawCallback"))
	Assert(TerminalDispatch != "", "_HSE_DispatchTerminalRawCallback must exist in the driver source")
	PreparedCall := InStr(TerminalDispatch, "Spec.Callback)(EndChar, true")
	OwnerBegin := InStr(TerminalDispatch, "_HSE_BeginOwnedTerminalTransaction")
	Assert(PreparedCall > 0 and OwnerBegin > PreparedCall
		and InStr(TerminalDispatch, "SendNewResult(") = 0,
		"terminal raw callbacks must prepare first and delegate all output to the native-capture owner")
}

; _SpaceTap lives in the interactive remap module the headless runner does not
; load; the forced commit it parallels is driven in the unit suite.
_AHK04M_SpaceFallbackIsTransactional() {
	SpaceTap := _StripFullLineComments(_DriverFuncBody("_SpaceTap"))
	Assert(SpaceTap != "", "_SpaceTap must exist in the driver source")
	SpacePress := InStr(SpaceTap, 'if !TextPressKeyFed("Space")')
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
Test("meta hotstrings: Space fallback is transactional (AHK-04-send-transaction)",
	_AHK04M_SpaceFallbackIsTransactional)
