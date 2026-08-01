; tests/meta/test_llm_accept_suppress_balance.ahk

; ==============================================================================
; MODULE: LLM Accept PrefixWatcher Suppress Balance Meta Test
; DESCRIPTION:
; Regression guard for the suppress-refcount balance requirement (AHK-10).
;
; LLM_Bridge_OnAccept calls PrefixWatcherSuppress(true) before injecting the
; accepted prediction and PrefixWatcherSuppress(false) after the injection
; completes (via a callback or in the finally block on TextSend failure).
; _PrefixWatcherSuppressed is a DEPTH COUNTER — every true/false pair must be
; perfectly balanced. An unmatched true leaves the prefix watcher permanently
; suppressed; an unmatched false could underflow the counter below zero and
; re-enable the watcher prematurely.
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

	Assert(InStr(Body, "PrefixWatcherSuppress(true)") > 0,
		"LLM_Bridge_OnAccept must call PrefixWatcherSuppress(true) before injection so the prefix InputHook does not re-enter the engine on the synthetic characters (AHK-10)")
}

Test("llm_bridge: LLM_Bridge_OnAccept calls PrefixWatcherSuppress(true) before injection (llm-accept-suppress-balance)",
	_LASB_OnAcceptHasSuppressTrue)


_LASB_OnAcceptHasSuppressFalse() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined — prerequisite for this test")

	Assert(InStr(Body, "PrefixWatcherSuppress(false)") > 0,
		"LLM_Bridge_OnAccept must call PrefixWatcherSuppress(false) to release the depth counter — an unmatched true leaves the prefix watcher permanently suppressed (AHK-10)")
}

Test("llm_bridge: LLM_Bridge_OnAccept calls PrefixWatcherSuppress(false) to release (llm-accept-suppress-balance)",
	_LASB_OnAcceptHasSuppressFalse)


_LASB_FinallyGuardsPwRelease() {
	Body := _DriverFuncBody("LLM_Bridge_OnAccept")
	Assert(Body != "", "LLM_Bridge_OnAccept must be defined — prerequisite for this test")

	; The release must be gated so clipboard-mode defers do not release synchronously ahead of the paste.
	; The finally block contains the exception-gate that fires ONLY on TextSend failure.
	FinallyPos := InStr(Body, "finally")
	Assert(FinallyPos > 0,
		"LLM_Bridge_OnAccept must use a finally block to release PrefixWatcherSuppress on TextSend failure — without it an exception in TextSend leaks the depth-counter acquire (AHK-10)")

	; After the finally there must be a conditional release (not an unconditional one)
	FinallyBody := SubStr(Body, FinallyPos, 300)
	Assert(InStr(FinallyBody, "_threw") > 0,
		"finally block must gate the PrefixWatcherSuppress(false) release on the '_threw' exception flag — clipboard-mode defers release via the callback, not the finally, so an unconditional release would double-decrement the counter")
}

Test("llm_bridge: LLM_Bridge_OnAccept finally block gates suppress release on _threw (llm-accept-suppress-balance)",
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
