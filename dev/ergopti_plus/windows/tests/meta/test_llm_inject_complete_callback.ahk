; tests/meta/test_llm_inject_complete_callback.ahk

; ==============================================================================
; MODULE: LLM Inject-Complete Callback Meta Test
; DESCRIPTION:
; Regression guard for the LLM accept injection callback wiring.
;
; Two related bugs in LLM_Bridge_OnAccept:
;
; (A) Synthetic-flag release was driven by a fixed 80 ms SetTimer regardless
;     of how long the injected keystrokes actually took to drain through the
;     OS message queue. For long predictions the timer could fire while
;     characters were still in flight, causing the tail of the injection to
;     be counted as human typing in keylogger metrics and potentially
;     re-triggering a hotstring on the model's own output.
;
; (B) After injection, HSE_HardReset cleared the hotstring buffer but the
;     last-sent-character ring (_LSC_RING) was left pointing at pre-prediction
;     characters. The first dead-key or ellipsis typed right after accepting
;     a prediction could then misfire because GetLastSentCharacterAt(-N) still
;     returned the character from before the accepted text.
;
; The fix passes a real completion callback (_LLM_Bridge_OnInjectComplete) to
; TextSend instead of 0. TextSend invokes it after the paste or direct send
; lands, so KL_ClearSynthetic / PrefixWatcherSuppress(false) are released at
; the correct time, and _LSCResetFrom is called to seed the ring with the
; prediction's trailing chars.
;
; This test asserts:
;   (a) LLM_Bridge_OnAccept passes a non-zero callback to TextSend.
;   (b) _LLM_Bridge_OnInjectComplete exists and calls KL_ClearSynthetic.
;   (c) _LLM_Bridge_OnInjectComplete calls _LSCResetFrom.
;   (d) The fixed-delay SetTimer for KL_ClearSynthetic is absent in OnAccept.
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
	Assert(Body != "", "_LLM_Bridge_OnInjectComplete must be defined in llm_bridge.ahk")

	; (b) Must clear synthetic flag
	Assert(InStr(Body, "KL_ClearSynthetic()"),
		"_LLM_Bridge_OnInjectComplete must call KL_ClearSynthetic()")

	; (c) Must resync LSC ring
	Assert(InStr(Body, "_LSCResetFrom"),
		"_LLM_Bridge_OnInjectComplete must call _LSCResetFrom to resync the last-sent-character ring")
}

_LICC_CheckNoFixedTimerForClear() {
	Src := _LICC_ReadSource("modules/keymap/llm_bridge.ahk")
	Assert(Src != "", "modules/keymap/llm_bridge.ahk must be readable")

	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be present in llm_bridge.ahk")

	; (d) Fixed-delay timer for KL_ClearSynthetic must not be in OnAccept body
	Assert(!InStr(Body, "SetTimer((*) => KL_ClearSynthetic()"),
		"LLM_Bridge_OnAccept must not use a fixed SetTimer for KL_ClearSynthetic — use injection callback instead")
}

_LICC_OutputStateCommitsOnlyOnSuccessfulCompletion() {
	Accept := _DriverFuncBody("LLM_Bridge_OnAccept")
	Complete := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Inline := _DriverFuncBody("LLM_Engine_OnResults")
	InlineComplete := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Sender := _DriverFuncBody("_TextSenderInvokeCallback")

	Assert(InStr(Accept, "_LLM_Bridge_Buffer .= text") = 0 && InStr(Accept, "LLM_Tooltip_Hide(true)") = 0,
		"LLM_Bridge_OnAccept must not hide/commit state before an async TextSend completes")
	Assert(InStr(Complete, "if !Ok") > 0 && InStr(Complete, "_LLM_Bridge_Buffer .= InjectedText") > 0
			&& InStr(Complete, "LLM_Bridge_DeferTooltipHide(true)") > 0,
		"accepted prediction state must commit only in the successful sender completion branch")
	Assert(InStr(Sender, "Callback(Ok, ErrorMessage)") > 0,
		"TextSender callback contract must report whether output was actually injected")
	Assert(InStr(Inline, "TextSend(text, 0, LLM_Engine_OnInlineInjectComplete.Bind(text))") > 0,
		"inline auto-type must use sender completion instead of a fixed cleanup delay")
	Assert(InStr(Inline, "SYNTH_CLEAR_DELAY_MS") = 0 && InStr(InlineComplete, "if !Ok") > 0,
		"inline auto-type must release/commit from success-aware completion, never a fixed timer")
}


Test("meta llm-inject-callback: LLM_Bridge_OnAccept passes inject-complete callback to TextSend",
	_LICC_CheckCallbackWired)

Test("meta llm-inject-callback: _LLM_Bridge_OnInjectComplete clears synthetic flag and resyncs LSC ring",
	_LICC_CheckCompleteFnExists)

Test("meta llm-inject-callback: LLM_Bridge_OnAccept does not use fixed-delay SetTimer for KL_ClearSynthetic",
	_LICC_CheckNoFixedTimerForClear)
Test("meta llm-inject-callback: output state commits only after successful sender completion",
	_LICC_OutputStateCommitsOnlyOnSuccessfulCompletion)
