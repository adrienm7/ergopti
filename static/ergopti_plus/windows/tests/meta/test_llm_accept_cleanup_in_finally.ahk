; tests/meta/test_llm_accept_cleanup_in_finally.ahk

; ==============================================================================
; MODULE: LLM Accept Cleanup-In-Finally Meta Test
; DESCRIPTION:
; Static source guard for the llm-accept-cleanup-in-finally finding.
;
; LLM_Bridge_OnAccept and the inline auto-type path of LLM_Engine_OnResults
; both call TextSend to inject the prediction, then schedule cleanup timers
; (KL_ClearSynthetic, PrefixWatcherSuppress release). Before the fix the
; timers were scheduled inline after TextSend: if TextSend raised an AHK
; runtime error the timers never fired, leaving KL_Synthetic active
; indefinitely and silently tagging every subsequent manual keystroke as
; synthetic.
;
; The fix wraps TextSend (and the buffer / HSE resets that logically belong
; to the injection) in try { ... } and moves both cleanup timers into a
; finally { ... } block so they fire whether or not TextSend succeeds.
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

; LLM_Bridge_OnAccept must use try { ... } finally { ... } so the cleanup
; timers fire even when TextSend raises an error.
_LACF_BridgeHasFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must exist in modules/keymap/llm_bridge.ahk")
	Assert(InStr(Body, "} finally {") > 0,
		"LLM_Bridge_OnAccept must use try { ... } finally { ... } so cleanup timers fire even when TextSend fails (llm-accept-cleanup-in-finally)")
}
Test("llm_bridge: LLM_Bridge_OnAccept wraps TextSend in try/finally (llm-accept-cleanup-in-finally)", _LACF_BridgeHasFinally)

; KL_ClearSynthetic must be scheduled from the finally block so it fires
; unconditionally -- not only on the success path after TextSend.
_LACF_BridgeKLClearInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must exist in modules/keymap/llm_bridge.ahk")
	FinallyBlock := _LACF_AfterFinally(Body)
	Assert(FinallyBlock != "", "LLM_Bridge_OnAccept must have a } finally { block (llm-accept-cleanup-in-finally)")
	Assert(InStr(FinallyBlock, "KL_ClearSynthetic") > 0,
		"KL_ClearSynthetic timer must appear in the finally block of LLM_Bridge_OnAccept -- moving it inline after TextSend leaves KL_Synthetic permanently set on TextSend failure (llm-accept-cleanup-in-finally)")
}
Test("llm_bridge: KL_ClearSynthetic timer is scheduled from the finally block (llm-accept-cleanup-in-finally)", _LACF_BridgeKLClearInFinally)

; PrefixWatcherSuppress(false) release timer must also be in the finally
; block -- a stuck suppression silences the hotstring engine permanently.
_LACF_BridgePrefixSupInFinally() {
	Src := _LACF_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	FinallyBlock := _LACF_AfterFinally(Body)
	Assert(FinallyBlock != "", "LLM_Bridge_OnAccept must have a } finally { block (llm-accept-cleanup-in-finally)")
	Assert(InStr(FinallyBlock, "PrefixWatcherSuppress(false)") > 0,
		"PrefixWatcherSuppress(false) timer must be scheduled from the finally block of LLM_Bridge_OnAccept -- a stuck suppression silences the hotstring engine permanently (llm-accept-cleanup-in-finally)")
}
Test("llm_bridge: PrefixWatcherSuppress release timer is scheduled from the finally block (llm-accept-cleanup-in-finally)", _LACF_BridgePrefixSupInFinally)


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
	Assert(Body != "", "LLM_Engine_OnResults must exist in modules/llm/prediction_engine.ahk")
	Assert(InStr(Body, "} finally {") > 0,
		"The inline auto-type path of LLM_Engine_OnResults must use try/finally so cleanup timers fire even when TextSend fails (llm-accept-cleanup-in-finally)")
}
Test("prediction_engine: LLM_Engine_OnResults inline accept wraps TextSend in try/finally (llm-accept-cleanup-in-finally)", _LACF_EngineHasFinally)

_LACF_EngineKLClearInFinally() {
	Src := _LACF_ReadSource("modules/llm/prediction_engine.ahk")
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults must exist in modules/llm/prediction_engine.ahk")
	FinallyBlock := _LACF_AfterFinally(Body)
	Assert(FinallyBlock != "", "LLM_Engine_OnResults must have a } finally { block in its auto-type path (llm-accept-cleanup-in-finally)")
	Assert(InStr(FinallyBlock, "KL_ClearSynthetic") > 0,
		"KL_ClearSynthetic timer must appear in the finally block of LLM_Engine_OnResults' auto-type path (llm-accept-cleanup-in-finally)")
}
Test("prediction_engine: KL_ClearSynthetic is scheduled from the finally block (llm-accept-cleanup-in-finally)", _LACF_EngineKLClearInFinally)
