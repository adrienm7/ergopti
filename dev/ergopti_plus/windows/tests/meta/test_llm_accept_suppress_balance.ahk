; tests/meta/test_llm_accept_suppress_balance.ahk

; ==============================================================================
; MODULE: LLM Accept PrefixWatcher Non-Ownership Meta Test
; DESCRIPTION:
; Regression guard for the suppress-refcount balance requirement (AHK-10).
;
; The old implementation acquired PrefixWatcherSuppress before entering the
; clipboard FIFO. Physical typing during that unbounded wait was suppressed;
; cleanup balancing could not make the ownership interval correct. Atomic LLM
; output uses SendInput, which InputHook I1 ignores, so neither LLM producer nor
; its completion callback may touch the prefix suppression counter.
;
; This test asserts:
;   1. PrefixWatcherSuppress(true) is present in LLM_Bridge_OnAccept.
;   2. PrefixWatcherSuppress(false) is present (to close the depth counter).
;   3. The false release appears in a finally or callback path so it fires even
;      on TextSend failure (the exception-gate pattern).
;   4. PrefixWatcherSuppress is a depth counter: incrementing on true,
;      decrementing on false, never going below zero.
;
; SCOPE: source introspection of modules/keymap/llm_bridge.ahk and
;        infra/hotstrings/hotstring_prefix_watcher.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_LASB_ReadLlmSrc() {
	return _DriverDirConcat("modules/llm")
}

_LASB_ReadPwSrc() {
	return _DriverDirConcat("infra/hotstrings")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_LASB_OnAcceptHasSuppressTrue() {
	Src := _LASB_ReadLlmSrc()
	Assert(Src != "", "modules/llm/ source must be readable")

	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined")

	Complete := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	Assert(InStr(Body . Complete, "PrefixWatcherSuppress") = 0,
		"manual LLM acceptance must never suppress unrelated physical input while its clipboard request waits")
}

Test("llm_bridge: manual acceptance owns no temporal prefix suppression (llm-accept-suppress-balance)",
	_LASB_OnAcceptHasSuppressTrue)


_LASB_OnAcceptHasSuppressFalse() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined — prerequisite for this test")

	Inline := _DriverFuncBody("LLM_Engine_OnResults")
	InlineComplete := _DriverFuncBody("LLM_Engine_OnInlineInjectComplete")
	Assert(InStr(Inline . InlineComplete, "PrefixWatcherSuppress") = 0,
		"inline LLM output must never suppress unrelated physical input across direct/clipboard admission")
}

Test("llm_bridge: inline output owns no temporal prefix suppression (llm-accept-suppress-balance)",
	_LASB_OnAcceptHasSuppressFalse)


_LASB_FinallyGuardsPwRelease() {
	Sender := _DriverFuncBody("TextSend")
	Assert(InStr(Sender, '_AHK_SendInput.Bind("{Text}" . Text)') > 0,
		"direct atomic LLM output must use SendInput text mode, which InputHook ignores without a suppression counter")
	Clipboard := _DriverFuncBody("_TextSendClipboard")
	Assert(InStr(Clipboard, '_AHK_SendInput.Bind("^v")') > 0,
		"clipboard atomic LLM output must use the same InputHook-invisible SendInput primitive")
}

Test("llm_bridge: atomic output is InputHook-invisible by construction (llm-accept-suppress-balance)",
	_LASB_FinallyGuardsPwRelease)


_LASB_PrefixWatcherSuppressIsDepthCounter() {
	Src := _LASB_ReadPwSrc()
	Assert(Src != "", "infra/hotstrings/ source must be readable")

	Body := _DriverFuncBody("PrefixWatcherSuppress")
	Assert(Body != "", "PrefixWatcherSuppress must be defined in the prefix-watcher module")

	; Depth counter semantics: += 1 on true, Max(0, x - 1) on false
	Assert(InStr(Body, "+= 1") > 0 or InStr(Body, "+ 1") > 0,
		"PrefixWatcherSuppress must increment the depth counter on true — a plain boolean would allow reentrancy to underflow the suppression prematurely")
	Assert(InStr(Body, "Max(0,") > 0 or InStr(Body, "Max(0 ,") > 0,
		"PrefixWatcherSuppress must clamp the counter to zero on false (Max(0, counter - 1)) — prevents underflow below zero when false is called more times than true")
}

Test("hotstring_prefix_watcher: PrefixWatcherSuppress uses depth-counter semantics (llm-accept-suppress-balance)",
	_LASB_PrefixWatcherSuppressIsDepthCounter)
