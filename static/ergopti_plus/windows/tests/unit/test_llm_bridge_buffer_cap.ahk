; tests/unit/test_llm_bridge_buffer_cap.ahk

; ==============================================================================
; MODULE: LLM Bridge Buffer Cap Regression Test
; DESCRIPTION:
; Regression guard for F47 — _LLM_Bridge_Buffer grew unbounded on every
; keystroke. Unlike every sibling hot-path buffer (HSE_Buffer,
; KLRoi.current_word, both capped at 64 chars), the LLM prediction bridge's
; per-keystroke buffer had no cap, so a long uninterrupted typing run bound an
; ever-growing string into a fresh SetTimer closure (Bind(buffer)) on every
; keystroke.
;
; The fix caps _LLM_Bridge_Buffer at LLM_BRIDGE_BUFFER_MAX_CHARS (10000 — must
; stay >= the max ctx_chars accepted by LLM_Menu_PromptCtxChars, or a user
; with a high context-length setting would silently lose context), mirroring
; HSE_FeedChar's trim-to-tail pattern.
;
; LLM_Bridge_OnChar is in the run_all include graph and its collaborators
; (TooltipIsVisible, LLM_Tooltip_IsVisible) are cheap real functions with no
; side effects when no tooltip is showing, so this is a headless-safe
; behavioural test. _LLM_Engine["enabled"] is forced false so
; LLM_Engine_OnKeystroke's real call is a fast no-op (no timer armed, no HTTP).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Helpers ================================================
; ===================================================================
; ===================================================================

_LBBC_Setup() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Engine
	_LLM_Bridge_Buffer := ""
	_LLM_Bridge_Active := true
	_LLM_Engine["enabled"] := false
}

_LBBC_Teardown() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := ""
	_LLM_Bridge_Active := false
}




; ===================================================================
; ===================================================================
; ======= 2/ Test cases =============================================
; ===================================================================
; ===================================================================

_LBBC_BufferNeverExceedsCap() {
	_LBBC_Setup()
	global _LLM_Bridge_Buffer, LLM_BRIDGE_BUFFER_MAX_CHARS
	; Feed far more characters than the cap — a pathological unbroken typing run.
	loop (LLM_BRIDGE_BUFFER_MAX_CHARS + 500)
		LLM_Bridge_OnChar("a")
	AssertEqual(LLM_BRIDGE_BUFFER_MAX_CHARS, StrLen(_LLM_Bridge_Buffer),
		"_LLM_Bridge_Buffer must never grow past LLM_BRIDGE_BUFFER_MAX_CHARS, no matter how long the unbroken typing run (F47)")
	_LBBC_Teardown()
}
Test("llm_bridge: LLM_Bridge_OnChar caps the buffer at LLM_BRIDGE_BUFFER_MAX_CHARS (F47)", _LBBC_BufferNeverExceedsCap)

_LBBC_KeepsTailNotHead() {
	_LBBC_Setup()
	global _LLM_Bridge_Buffer, LLM_BRIDGE_BUFFER_MAX_CHARS
	loop (LLM_BRIDGE_BUFFER_MAX_CHARS)
		LLM_Bridge_OnChar("x")
	LLM_Bridge_OnChar("Z")  ; one char past the cap
	AssertEqual("Z", SubStr(_LLM_Bridge_Buffer, -1),
		"once capped, the buffer must drop the OLDEST characters and keep the most recent typing, not the reverse")
	AssertEqual(LLM_BRIDGE_BUFFER_MAX_CHARS, StrLen(_LLM_Bridge_Buffer))
	_LBBC_Teardown()
}
Test("llm_bridge: capped buffer keeps the most recent characters, not the oldest (F47)", _LBBC_KeepsTailNotHead)
