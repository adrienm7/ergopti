; tests/unit/test_llm_deadline_wrap.ahk

; ==============================================================================
; MODULE: LLM Deadline Wrap-Safety Test
; DESCRIPTION:
; Regression suite for the wrap-safe deadline helper _LLM_DeadlineExpired.
; Guards against the naive "A_TickCount >= start_tick + timeout_ms" pattern
; that silently breaks after the 32-bit A_TickCount rollover (~49.7 days).
;
; RATIONALE:
; When start_tick is near the 32-bit maximum (e.g. 0xFFFF0000) and timeout_ms
; pushes the sum past 0xFFFFFFFF, integer overflow makes the naive comparison
; always false -- the timer never expires. The modular subtraction approach
; ((A_TickCount - start_tick + 0x100000000) & 0xFFFFFFFF) >= timeout_ms
; stays correct across the wrap because subtraction wraps symmetrically in
; unsigned 32-bit space.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ Inline arithmetic helpers for testing =======
; ========================================================
; ========================================================

; Route every assertion through the production timing primitive.  The former
; version duplicated the formula locally, so it stayed green even when a
; production caller used an unsafe absolute deadline.
_TDW_DeadlineExpired(start_tick, timeout_ms, now_tick) {
	return TickExpired(start_tick, timeout_ms, now_tick)
}

; Naive (buggy) form for documentation: fails after 32-bit wrap.
_TDW_DeadlineExpiredNaive(start_tick, timeout_ms, now_tick) {
	return now_tick >= (start_tick + timeout_ms)
}





; ===================================================
; ===================================================
; ======= 2/ Post-wrap expiry detection tests =======
; ===================================================
; ===================================================



; start_tick near the 32-bit ceiling; timeout pushes the absolute deadline
; past 0xFFFFFFFF; now_tick has wrapped to a small positive value.
; elapsed = (now_tick - start_tick + 2^32) & 0xFFFFFFFF
;         = (120000 - 0xFFFF0000 + 0x100000000) & 0xFFFFFFFF
;         = (120000 + 65536) & 0xFFFFFFFF
;         = 185536
; 185536 >= 180000 => true (expired)
_TDW_PostWrapExpired() {
	start := 0xFFFF0000
	tms   := 180000
	now   := 120000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must detect expiry when now has wrapped past start_tick (llm-deadline-wrap)")
}
Test("_LLM_DeadlineExpired: detects expiry correctly after 32-bit A_TickCount wrap (llm-deadline-wrap)", _TDW_PostWrapExpired)





; =====================================================
; =====================================================
; ======= 3/ Naive form fails on the same input =======
; =====================================================
; =====================================================

; Documents the bug: the naive form returns false for the same synthetic
; values because (start_tick + timeout_ms) overflows to a small number --
; specifically: (0xFFFF0000 + 180000) mod 2^32 = 0xFFFFBF10 = 4294934288,
; which is far larger than now_tick=120000, so naive returns false (wrong).
_TDW_NaiveFailsPostWrap() {
	start := 0xFFFF0000
	tms   := 180000
	now   := 120000
	Assert(!_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive form must NOT detect expiry on post-wrap values -- documents the overflow bug (llm-deadline-wrap)")
}
Test("_LLM_DeadlineExpired (naive): naive form misses expiry after wrap -- documents the bug (llm-deadline-wrap)", _TDW_NaiveFailsPostWrap)





; =================================================
; =================================================
; ======= 4/ Normal (no-wrap) sanity checks =======
; =================================================
; =================================================

; Both forms must agree when no wrap occurs and the timeout has elapsed.
_TDW_NoWrapExpired() {
	start := 1000000
	tms   := 5000
	now   := 1006000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must detect expiry in the normal no-wrap case (llm-deadline-wrap)")
	Assert(_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive check must also detect expiry in the normal no-wrap case (llm-deadline-wrap)")
}
Test("_LLM_DeadlineExpired: both forms agree -- timeout elapsed with no 32-bit wrap (llm-deadline-wrap)", _TDW_NoWrapExpired)


; Both forms must agree when no wrap occurs and the timeout has NOT elapsed.
_TDW_NoWrapNotExpired() {
	start := 1000000
	tms   := 5000
	now   := 1003000
	Assert(!_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must return false when timeout has not elapsed (llm-deadline-wrap)")
	Assert(!_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive check must also return false when timeout has not elapsed (llm-deadline-wrap)")
}
Test("_LLM_DeadlineExpired: both forms agree -- timeout not yet elapsed with no 32-bit wrap (llm-deadline-wrap)", _TDW_NoWrapNotExpired)


; Exact boundary: elapsed == timeout_ms must count as expired.
_TDW_ExactBoundary() {
	start := 500000
	tms   := 3000
	now   := 503000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must treat elapsed == timeout_ms as expired (llm-deadline-wrap)")
}
Test("_LLM_DeadlineExpired: elapsed equal to timeout counts as expired (llm-deadline-wrap)", _TDW_ExactBoundary)


_TDW_SharedPrimitiveVectors() {
	start := 0xFFFFFFD0
	now := 40
	AssertEqual(88, TickElapsed(start, now),
		"TickElapsed must preserve elapsed time across rollover (llm-deadline-wrap)")
	AssertEqual(112, TickRemaining(start, 200, now),
		"TickRemaining must preserve the pre-expiry remainder across rollover (llm-deadline-wrap)")
	Assert(!TickExpired(start, 200, now),
		"TickExpired must not expire a live interval after rollover (llm-deadline-wrap)")

	start := 0xFFFFFF9C
	now := 150
	AssertEqual(250, TickElapsed(start, now),
		"TickElapsed must report the full post-rollover duration (llm-deadline-wrap)")
	AssertEqual(0, TickRemaining(start, 200, now),
		"TickRemaining must clamp expired intervals to zero (llm-deadline-wrap)")
	Assert(TickExpired(start, 200, now),
		"TickExpired must expire a post-rollover interval (llm-deadline-wrap)")
}
Test("Shared tick primitive handles elapsed, remaining, and expiry across rollover (llm-deadline-wrap)", _TDW_SharedPrimitiveVectors)
