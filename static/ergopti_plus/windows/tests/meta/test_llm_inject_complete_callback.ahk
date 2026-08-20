; tests/meta/test_llm_inject_complete_callback.ahk

; ==============================================================================
; MODULE: LLM Inject-Complete Callback Meta Test
; DESCRIPTION:
; Regression guard for the LLM accept injection callback wiring.
;
; Two related bugs in accepted-output ownership:
;
; (A) A queue-wide KL_MarkSynthetic/PrefixWatcherSuppress guard was armed before
;     clipboard FIFO admission. Physical typing while the request waited was
;     then misclassified or hidden. SendInput is ignored by InputHook, so output
;     needs no temporal synthetic flag: last-moment admission and an atomic RAM
;     commit are the real contract.
;
; (B) After injection, the hotstring buffer was reset but the
;     last-sent-character ring (_LSC_RING) was left pointing at pre-prediction
;     characters. The first dead-key or ellipsis typed right after accepting
;     a prediction could then misfire because GetLastSentCharacterAt(-N) still
;     returned the character from before the accepted text.
;
; The fix gives TextSender an admission predicate and RAM-only commit. It runs
; admission -> SendInput -> bridge/prefix/HSE/LSC commit in one short Critical
; transaction. The completion callback owns metrics/UI only and cannot mutate
; text state or release a guard it never legitimately owned.
;
; This test asserts:
;   (a) LLM_Bridge_OnAccept passes a non-zero callback to TextSend.
;   (b) the RAM commit owns bridge/prefix/HSE/LSC state under Critical.
;   (c) completion is state-free and the old temporal guards stay absent.
;   (d) both direct and clipboard output use the same atomic sender owner.
;
; SCOPE: source introspection of modules/keymap/llm_bridge.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_LICC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_LICC_CheckCallbackWired() {
	Src := _LICC_ReadSource("modules/keymap/llm_bridge.ahk")
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be present in llm_bridge.ahk")

	; (a) TextSend must not receive a bare 0 as callback
	Assert(!InStr(Body, "TextSend(text, 0, 0)"),
		"LLM_Bridge_OnAccept must pass a real callback to TextSend, not bare 0")

	; TextSend must be called with the inject-complete callback
	Assert(InStr(Body, "_LLM_Bridge_OnInjectComplete"),
		"LLM_Bridge_OnAccept must pass _LLM_Bridge_OnInjectComplete to TextSend")
}

_LICC_CheckCompleteFnExists() {
	Src := _LICC_ReadSource("modules/keymap/llm_bridge.ahk")
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

	Body := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Commit := _DriverFuncBody("_LLM_Bridge_CommitInjectedText")
	Assert(Body != "", "_LLM_Bridge_OnInjectComplete must be defined in llm_bridge.ahk")
	Assert(Commit != "" and InStr(Commit, "if !A_IsCritical") > 0,
		"the accepted-text RAM commit must require TextSender's atomic output transaction")
	for Needle in ["_LLM_Bridge_ApplyBufferEdit", "_PrefixCommitInputContext", "_LSCResetFrom"]
		Assert(InStr(Commit, Needle) > 0,
			"the atomic commit must own every output mirror: " . Needle)
	for Forbidden in ["_LLM_Bridge_ApplyBufferEdit", "_PrefixCommitInputContext",
			"_LSCResetFrom", "KL_ClearSynthetic", "PrefixWatcherSuppress"]
		Assert(InStr(Body, Forbidden) = 0,
			"open-thread completion must not mutate output state or temporal guards: " . Forbidden)
}

_LICC_CheckNoFixedTimerForClear() {
	Src := _LICC_ReadSource("modules/keymap/llm_bridge.ahk")
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be present in llm_bridge.ahk")

	; Fixed-delay or queue-wide synthetic ownership must not return.
	Assert(!InStr(Body, "SetTimer((*) => KL_ClearSynthetic()"),
		"LLM_Bridge_OnAccept must not use a fixed SetTimer for KL_ClearSynthetic — use injection callback instead")
	Assert(InStr(Body, "KL_MarkSynthetic") = 0 and InStr(Body, "PrefixWatcherSuppress") = 0,
		"LLM acceptance must not mark unrelated physical input while a clipboard request waits")
}

_LICC_OutputStateCommitsOnlyOnSuccessfulCompletion() {
	Accept := _DriverFuncBody("LLM_Bridge_OnAccept")
	Complete := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Inline := _DriverFuncBody("LLM_Engine_OnResults")
	InlineComplete := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Sender := _DriverFuncBody("_TextSenderInvokeCallback")
	Atomic := _DriverFuncBody("_TextSenderRunAtomicOutput")
	Commit := _DriverFuncBody("_LLM_Bridge_CommitInjectedText")

	Assert(InStr(Accept, "_LLM_Bridge_Buffer .= text") = 0 && InStr(Accept, "LLM_Tooltip_Hide(true)") = 0,
		"LLM_Bridge_OnAccept must not hide/commit state before an async TextSend completes")
	SenderPos := InStr(Atomic, "SenderFn.Call()")
	CommitPos := InStr(Atomic, "AtomicCommit.Call()", true, SenderPos)
	RestorePos := InStr(Atomic, "Critical(PreviousCritical)", true, CommitPos)
	Assert(SenderPos > 0 and CommitPos > SenderPos and RestorePos > CommitPos,
		"visible output and every RAM mirror must commit in order before Critical is restored")
	NormalizedComplete := RegExReplace(Complete, "\s+", " ")
	Assert(InStr(Commit, "_LLM_Bridge_ApplyBufferEdit") > 0
			and InStr(NormalizedComplete,
				"LLM_Tooltip_FinalizeAcceptance( Transaction.PresentedLifecycle, true)") > 0
			and InStr(NormalizedComplete,
				"LLM_Bridge_DeferTooltipHide(true, Transaction.PresentedRecord)") > 0
			and InStr(NormalizedComplete,
				"LLM_Tooltip_FinalizeAcceptance( Transaction.PresentedLifecycle, false)") > 0,
		"output mirrors must commit atomically; completion must finalize and hide the exact presented lifecycle according to sender success")
	Assert(InStr(Sender, "Callback(Ok, ErrorMessage)") > 0,
		"TextSender callback contract must report whether output was actually injected")
	Assert(InStr(Accept, "_LLM_Bridge_InjectionOptions(Transaction)") > 0
			and InStr(Inline, "_LLM_Bridge_InjectionOptions(Transaction)") > 0,
		"manual acceptance and inline auto-type must share the same admission/commit owner")
	Assert(InStr(Inline, "SYNTH_CLEAR_DELAY_MS") = 0 && InStr(InlineComplete, "if !Ok") > 0,
		"inline auto-type must report sender status, never use a fixed synthetic timer")
}


Test("meta llm-inject-callback: LLM_Bridge_OnAccept passes inject-complete callback to TextSend",
	_LICC_CheckCallbackWired)

Test("meta llm-inject-callback: atomic commit owns every output mirror without temporal guards",
	_LICC_CheckCompleteFnExists)

Test("meta llm-inject-callback: LLM_Bridge_OnAccept does not use fixed-delay SetTimer for KL_ClearSynthetic",
	_LICC_CheckNoFixedTimerForClear)
Test("meta llm-inject-callback: output state commits only after successful sender completion",
	_LICC_OutputStateCommitsOnlyOnSuccessfulCompletion)
