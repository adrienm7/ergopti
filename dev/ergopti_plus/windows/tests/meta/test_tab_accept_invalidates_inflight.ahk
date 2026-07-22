; tests/meta/test_tab_accept_invalidates_inflight.ahk

; ==============================================================================
; MODULE: Tab-Accept In-Flight Invalidation Meta Test
; DESCRIPTION:
; Regression guard for the accept-invalidates-inflight fix (AHK-09).
;
; Before the fix, LLM_Bridge_OnAccept (the handler called when the user presses
; Tab to accept a prediction) injected the accepted text but left any concurrent
; streaming/async callbacks alive. Those callbacks could then re-show the tooltip
; with the superseded prediction on top of the newly injected text — a "ghost
; tooltip after accept" regression.
;
; The fix calls LLM_Engine_StopGeneration() BEFORE TextSend inside
; LLM_Bridge_OnAccept. StopGeneration bumps request_id (invalidating all live
; async callbacks by generation counter) and cancels active curl + WinHTTP
; streams so they cannot surface the tooltip again after the accept path is done.
;
; This test asserts:
;   1. LLM_Bridge_OnAccept calls LLM_Engine_StopGeneration().
;   2. The StopGeneration call precedes the TextSend injection call.
;   3. LLM_Engine_StopGeneration increments request_id so callbacks self-discard.
;
; SCOPE: source introspection of modules/keymap/llm_bridge.ahk and
;        modules/llm/prediction_keylogger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_TAII_ReadLlmSrc() {
	return _DriverDirConcat("modules/llm")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_TAII_OnAcceptCallsStopGeneration() {
	Src := _TAII_ReadLlmSrc()
	Assert(Src != "", "modules/llm/ source must be readable")

	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined in the LLM module")

	Assert(InStr(Body, "LLM_Engine_StopGeneration()") > 0,
		"LLM_Bridge_OnAccept must call LLM_Engine_StopGeneration() — without it, in-flight async callbacks survive the accept and can re-show a ghost tooltip over the injected text (AHK-09)")
}

Test("llm_bridge: LLM_Bridge_OnAccept calls LLM_Engine_StopGeneration (tab-accept-invalidates-inflight)",
	_TAII_OnAcceptCallsStopGeneration)


_TAII_StopGenerationBeforeTextSend() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined — prerequisite for this test")

	StopPos   := InStr(Body, "LLM_Engine_StopGeneration()")
	SendPos   := InStr(Body, "TextSend(")
	Assert(StopPos > 0,
		"LLM_Bridge_OnAccept must contain LLM_Engine_StopGeneration() call — prerequisite for ordering test")
	Assert(SendPos > 0,
		"LLM_Bridge_OnAccept must contain TextSend() call — prerequisite for ordering test")
	Assert(StopPos < SendPos,
		"LLM_Engine_StopGeneration() must be called BEFORE TextSend() in LLM_Bridge_OnAccept — the request_id must be bumped while the async callbacks are still live, not after the inject starts")
}

Test("llm_bridge: LLM_Engine_StopGeneration precedes TextSend in LLM_Bridge_OnAccept (tab-accept-invalidates-inflight)",
	_TAII_StopGenerationBeforeTextSend)


_TAII_StopGenerationBumpsRequestId() {
	Body := _DriverFuncBody("LLM_Engine_StopGeneration")
	Assert(Body != "", "LLM_Engine_StopGeneration must be defined in the prediction module")

	; The request_id bump is what causes all in-flight callbacks to self-discard
	Assert(InStr(Body, "request_id") > 0,
		"LLM_Engine_StopGeneration must increment request_id — the generation counter that in-flight async callbacks compare against to decide whether to discard themselves")
}

Test("prediction_engine: LLM_Engine_StopGeneration bumps request_id to invalidate in-flight callbacks (tab-accept-invalidates-inflight)",
	_TAII_StopGenerationBumpsRequestId)
