; tests/meta/test_llm_accept_cleanup_in_finally.ahk

; ==============================================================================
; MODULE: LLM Accept Completion Ownership Meta Test
; DESCRIPTION:
; Static source guard for the llm-accept-cleanup-in-finally finding.
;
; LLM output may wait asynchronously in the clipboard FIFO. Temporal
; synthetic/hotstring guards must NOT span that wait: physical input would be
; misclassified or suppressed. TextSender owns admission plus the SendInput/RAM
; commit; its success-aware callback owns metrics/UI and every failure path.
;
; This is a meta-static test (source scan) because simulating a TextSend
; failure in the headless runner requires the full AHK input stack. The
; source scan guarantees the structural invariant -- the finally block --
; can never be silently dropped during a refactor.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Source scan helpers ===========
; ==========================================
; ==========================================

_LACF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the substring of Body starting at the first "} finally {" token.
; The caller uses InStr on this result to assert that cleanup code appears
; inside (or after) the finally block, never only in the try block.
_LACF_AfterFinally(Body) {
	Idx := InStr(Body, "} finally {")
	if !Idx
		return ""
	return SubStr(Body, Idx)
}


; ==============================================
; ==============================================
; ======= 2/ LLM_Bridge_OnAccept assertions ===
; ==============================================
; ==============================================

_LACF_BridgeHasFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must exist in modules/keymap/llm_bridge.ahk")
	Assert(InStr(Body, "_LLM_Bridge_InjectionOptions(Transaction)") > 0
			and InStr(Body, "_LLM_Bridge_OnInjectComplete.Bind(Transaction)") > 0,
		"LLM_Bridge_OnAccept must delegate atomic output and status-aware completion with the same immutable transaction")
}
Test("llm_bridge: LLM_Bridge_OnAccept delegates cleanup to sender completion (llm-accept-cleanup-in-finally)", _LACF_BridgeHasFinally)

_LACF_BridgeKLClearInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Accept := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(InStr(Body, "if !Ok") > 0,
		"_LLM_Bridge_OnInjectComplete must handle every sender-reported failure")
	Assert(InStr(Accept . Body, "KL_MarkSynthetic") = 0
			and InStr(Accept . Body, "KL_ClearSynthetic") = 0,
		"LLM output must not mark the whole clipboard wait synthetic; SendInput is invisible to InputHook and metrics are recorded from accepted events")
}
Test("llm_bridge: acceptance owns no queue-wide keylogger guard (llm-accept-cleanup-in-finally)", _LACF_BridgeKLClearInFinally)

; PrefixWatcherSuppress(false) release timer must also be in the finally
; block -- a stuck suppression silences the hotstring engine permanently.
_LACF_BridgePrefixSupInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Accept := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(InStr(Accept . Body, "PrefixWatcherSuppress") = 0,
		"LLM output must not suppress physical prefix input while a deferred clipboard request waits")
}
Test("llm_bridge: acceptance owns no queue-wide prefix guard (llm-accept-cleanup-in-finally)", _LACF_BridgePrefixSupInFinally)


; ======================================================
; ======================================================
; ======= 3/ LLM_Engine_OnResults accept assertions ===
; ======================================================
; ======================================================

; The inline auto-type path in LLM_Engine_OnResults has the same invariant:
; the cleanup timers must be in a finally block, not inline after TextSend.
_LACF_EngineHasFinally() {
	Src := _LACF_ReadSource("modules/llm/prediction_engine.ahk")
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults must exist in modules/llm/prediction_exec.ahk")
	Assert(InStr(Body, "_LLM_Bridge_InjectionOptions(Transaction)") > 0
			and InStr(Body, "LLM_Engine_OnInlineInjectComplete.Bind(Transaction)") > 0,
		"inline auto-type must delegate output and completion through its immutable transaction")
}
Test("prediction_engine: inline accept delegates cleanup to sender completion (llm-accept-cleanup-in-finally)", _LACF_EngineHasFinally)

_LACF_EngineKLClearInFinally() {
	Src := _LACF_ReadSource("modules/llm/prediction_engine.ahk")
	Body := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Producer := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(InStr(Body, "if !Ok") > 0,
		"inline completion must handle sender-reported failure")
	Assert(InStr(Producer . Body, "KL_MarkSynthetic") = 0
			and InStr(Producer . Body, "KL_ClearSynthetic") = 0
			and InStr(Producer . Body, "PrefixWatcherSuppress") = 0,
		"inline output must not own temporal guards across direct/clipboard admission")
}
Test("prediction_engine: inline output owns no queue-wide guards (llm-accept-cleanup-in-finally)", _LACF_EngineKLClearInFinally)
