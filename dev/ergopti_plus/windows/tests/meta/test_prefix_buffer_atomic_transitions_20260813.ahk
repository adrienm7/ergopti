; tests/meta/test_prefix_buffer_atomic_transitions_20260813.ahk

; ==============================================================================
; MODULE: Prefix/Engine Buffer Atomic Transition Guard
; DESCRIPTION:
; Every user-reachable edit that mutates both HSE_Buffer and _PrefixBuffer must
; publish them through one Critical owner. A physical hook callback can interrupt
; TooltipHide or analytics after the first write; the next character would then
; enter only one buffer and make the tooltip disagree with the engine.
;
; Space is the deliberate exception: HSE keeps the terminator and left context
; for triggers containing an internal boundary, while the preview begins a new
; word. Its OnChar is the engine's one authoritative feed.
; ==============================================================================

#Requires AutoHotkey v2.0+

_PBAT_Count(Haystack, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, true, Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_PBAT_ContextResetSitesUseOneOwner() {
	Mouse := _DriverFuncBody("_OnMouseClickReset")
	KeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Wrap := _DriverFuncBody("_PrefixTryWrapSelection")
	Pair := _DriverFuncBody("_PrefixInvalidateInputContext")
	Commit := _DriverFuncBody("_PrefixCommitInputContext")
	Finish := _DriverFuncBody("_PrefixFinishInputContext")
	Synthetic := _DriverFuncBody("HS_CommitSyntheticEffect")
	Rebuild := _DriverFuncBody("_RebuildHotstringsLiveOnce")
	for Name, Body in Map("mouse", Mouse, "keydown", KeyDown, "wrap", Wrap,
		"pair", Pair, "commit", Commit, "finish", Finish,
		"synthetic", Synthetic, "rebuild", Rebuild)
		Assert(Body != "", Name . " buffer-transition body must be source-visible")

	Assert(InStr(Mouse, "_PrefixInvalidateInputContext(0, true)") > 0
		and InStr(Mouse, "HSE_FeedReset") == 0,
		"mouse reset must not restore the split engine-then-preview publication")
	Assert(InStr(Wrap, "_PrefixInvalidateInputContext(") > 0
		and InStr(Wrap, "HSE_FeedReset") == 0 and InStr(Wrap, "_ResetPrefixBuffer") == 0,
		"selection wrapping must use the paired context owner after successful output")
	Assert(InStr(KeyDown, "HSE_FeedReset") == 0,
		"physical context resets must not bypass the paired helper at sibling keydown sites")

	EnterCritical := InStr(Pair, 'Critical("On")')
	CommitCall := InStr(Pair, "_PrefixCommitInputContext(FocusToken, KnownBoundary)", true, EnterCritical)
	LeaveCritical := InStr(Pair, "Critical(PreviousCritical)", true, CommitCall)
	Effects := InStr(Pair, "_PrefixFinishInputContext(Commit)", true, LeaveCritical)
	Engine := InStr(Commit, "HSE_FeedReset(KnownBoundary, true)")
	Preview := InStr(Commit, '_PrefixSetBuffer("")', true, Engine)
	Assert(EnterCritical > 0 and CommitCall > EnterCritical and LeaveCritical > CommitCall
		and Effects > LeaveCritical and Engine > 0 and Preview > Engine,
		"the canonical owner must publish both buffers under Critical and run GUI/analytics only after releasing it")
	Assert(InStr(Finish, "_ResetPrefixBuffer(false, Commit.ClearedBuffer)") > 0,
		"the effects phase must retain the pre-clear buffer for dismissal/near-miss work")

	Assert(InStr(Synthetic, "if IsSet(_PrefixCommitInputContext)") > 0
		and InStr(Synthetic, "_PrefixCommitInputContext(0, true)") > 0,
		"synthetic caret movement must use the same paired in-memory commit")
	Assert(InStr(Rebuild, "_PrefixInvalidateInputContext(0, false)") > 0
		and InStr(Rebuild, "HSE_HardReset") == 0
		and InStr(Rebuild, "_ResetPrefixBuffer") == 0,
		"the long yielded registry rebuild must close through one paired reset owner")
}

_PBAT_BackspaceHasOneAtomicDecrement() {
	KeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Pair := _DriverFuncBody("_PrefixFeedBackspace")
	Commit := _DriverFuncBody("_PrefixCommitBackspace")
	Finish := _DriverFuncBody("_PrefixFinishBackspace")
	Synthetic := _DriverFuncBody("HS_CommitSyntheticEffect")
	Assert(KeyDown != "" and Pair != "" and Commit != "" and Finish != "" and Synthetic != "",
		"backspace transition bodies must be source-visible")

	Assert(InStr(KeyDown, "_PrefixFeedBackspace()") > 0
		and InStr(KeyDown, "HSE_FeedBackspace") == 0,
		"physical Backspace must have one owner instead of decrementing the engine before the preview helper")
	EnterCritical := InStr(Pair, 'Critical("On")')
	CommitCall := InStr(Pair, "_PrefixCommitBackspace()", true, EnterCritical)
	LeaveCritical := InStr(Pair, "Critical(PreviousCritical)", true, CommitCall)
	Effects := InStr(Pair, "_PrefixFinishBackspace(Commit)", true, LeaveCritical)
	Engine := InStr(Commit, "HSE_FeedBackspace(true)")
	Preview := InStr(Commit, "_PrefixSetBuffer(NextPrefixBuffer)", true, Engine)
	Hide := InStr(Finish, 'TooltipHide("Backspace", true)')
	Assert(EnterCritical > 0 and CommitCall > EnterCritical and LeaveCritical > CommitCall
		and Effects > LeaveCritical and Engine > 0 and Preview > Engine and Hide > 0,
		"one Critical transaction must decrement engine+preview before any tooltip work")

	WatcherBranch := InStr(Synthetic, "if HasPreviewCommit")
	Fallback := InStr(Synthetic, "else if IsSet(HSE_FeedBackspace)", true, WatcherBranch)
	Assert(WatcherBranch > 0 and Fallback > WatcherBranch
		and _PBAT_Count(Synthetic, "HSE_FeedBackspace(true)") == 1,
		"synthetic Backspace must choose the paired watcher OR the engine-only harness fallback, never both")
}

_PBAT_SpaceKeepsEngineLeftContext() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Space := InStr(Body, "else if (VK == 0x20)")
	SpaceReset := InStr(Body, "_ResetPrefixBuffer()", true, Space)
	NextBranch := InStr(Body, "else if ResetVKs.Has(VK)", true, SpaceReset)
	Assert(Space > 0 and SpaceReset > Space and NextBranch > SpaceReset,
		"Space must keep a dedicated preview-only branch before paired navigation resets")
	Window := SubStr(Body, Space, NextBranch - Space)
	Assert(InStr(Window, "HSE_FeedReset") == 0
		and InStr(Window, "_PrefixInvalidateInputContext") == 0,
		"Space keydown must not erase the engine's left context before HSE_FeedChar receives its terminator")
}

_PBAT_SyntheticDeclarationsCannotEscapeTheSendOwner() {
	Src := _DriverSourceNoComments()
	Funnel := _DriverFuncBody("_TextSenderSendInput")
	Final := _DriverFuncBody("SendFinalResult")
	Owner := _DriverFuncBody("HS_RunSyntheticInputTransaction")
	Assert(Src != "" and Funnel != "" and Final != "" and Owner != "",
		"synthetic send ownership must be source-visible")
	; Definition only. Any production call to the compatibility declaration API
	; reintroduces two interruptible statements: future buffer state, then OS send.
	AssertEqual(1, _PBAT_Count(Src, "HS_DeclareSyntheticEffect("),
		"no production sender may call the declaration-only compatibility API; every declared output must use the canonical transaction owner")
	Assert(InStr(Funnel, "HS_RunSyntheticInputTransaction(") > 0
		and InStr(Final, "HS_RunSyntheticInputTransaction(") > 0,
		"both general synthetic-send funnels must route declared output through the same transaction owner")
	Enter := InStr(Owner, 'Critical("On")')
	Commit := InStr(Owner, "HS_CommitSyntheticEffect(Payload)", true, Enter)
	SendAt := InStr(Owner, "SendFn.Call()", true, Commit)
	Restore := InStr(Owner, "Critical(PreviousCritical)", true, SendAt)
	Effects := InStr(Owner, "HS_FinishSyntheticEffect(Token)", true, Restore)
	Assert(Enter > 0 and Commit > Enter and SendAt > Commit and Restore > SendAt
		and Effects > Restore,
		"the owner must commit both buffers and send under Critical, then run tooltip/analytics effects after restoring the caller state")
}

Test("meta hotstrings: paired context resets have one atomic owner (prefix-buffer-atomic-transitions)",
	_PBAT_ContextResetSitesUseOneOwner)
Test("meta hotstrings: Backspace decrements both buffers exactly once (prefix-buffer-atomic-transitions)",
	_PBAT_BackspaceHasOneAtomicDecrement)
Test("meta hotstrings: Space preserves engine left context (prefix-buffer-atomic-transitions)",
	_PBAT_SpaceKeepsEngineLeftContext)
Test("meta hotstrings: synthetic declaration and OS send have one owner (prefix-buffer-atomic-transitions)",
	_PBAT_SyntheticDeclarationsCannotEscapeTheSendOwner)
