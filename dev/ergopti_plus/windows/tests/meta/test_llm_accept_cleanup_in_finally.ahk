; tests/meta/test_llm_accept_cleanup_in_finally.ahk

; ==============================================================================
; MODULE: LLM Accept Cleanup-In-Finally Meta Test
; DESCRIPTION:
; Static source guard for the llm-accept-cleanup-in-finally finding.
;
; LLM output may complete asynchronously through a clipboard transaction. The
; release of synthetic/hotstring guards must therefore be owned by TextSend's
; success-aware completion callback, which runs both for a successful output
; and every terminal failure. Fixed timers or an inline post-TextSend cleanup
; either release early or leak guards when a delayed paste fails.
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
	Assert(InStr(Body, "_LLM_Bridge_OnInjectComplete.Bind(text)") > 0,
		"LLM_Bridge_OnAccept must delegate cleanup ownership to the success-aware TextSend completion callback")
}
Test("llm_bridge: LLM_Bridge_OnAccept delegates cleanup to sender completion (llm-accept-cleanup-in-finally)", _LACF_BridgeHasFinally)

; KL_ClearSynthetic must be scheduled from the finally block so it fires
; unconditionally -- not only on the success path after TextSend.
_LACF_BridgeKLClearInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Assert(InStr(Body, "KL_ClearSynthetic") > 0 && InStr(Body, "if !Ok") > 0,
		"_LLM_Bridge_OnInjectComplete must release KL synthetic state on both success and sender-reported failure")
}
Test("llm_bridge: KL_ClearSynthetic is released by success-aware completion (llm-accept-cleanup-in-finally)", _LACF_BridgeKLClearInFinally)

; PrefixWatcherSuppress(false) release timer must also be in the finally
; block -- a stuck suppression silences the hotstring engine permanently.
_LACF_BridgePrefixSupInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Assert(InStr(Body, "PrefixWatcherSuppress(false)") > 0 && InStr(Body, "if !Ok") > 0,
		"_LLM_Bridge_OnInjectComplete must release prefix suppression on both success and sender-reported failure")
}
Test("llm_bridge: PrefixWatcher suppression is released by success-aware completion (llm-accept-cleanup-in-finally)", _LACF_BridgePrefixSupInFinally)


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
	Assert(InStr(Body, "LLM_Engine_OnInlineInjectComplete.Bind(text)") > 0,
		"inline auto-type must delegate cleanup ownership to sender completion")
}
Test("prediction_engine: inline accept delegates cleanup to sender completion (llm-accept-cleanup-in-finally)", _LACF_EngineHasFinally)

_LACF_EngineKLClearInFinally() {
	Src := _LACF_ReadSource("modules/llm/prediction_engine.ahk")
	Body := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Assert(InStr(Body, "KL_ClearSynthetic") > 0 && InStr(Body, "if !Ok") > 0,
		"inline completion must release KL synthetic state on both success and sender-reported failure")
}
Test("prediction_engine: KL_ClearSynthetic is released by success-aware inline completion (llm-accept-cleanup-in-finally)", _LACF_EngineKLClearInFinally)
