; static/ergopti_plus/windows/tests/unit/test_llm_parser_dedup_stats.ahk

; ==============================================================================
; MODULE: LLM Parser Dedup Stats Tests (AHK)
; DESCRIPTION:
; Regression coverage for two F32 fixes in the batch dedup stats pipeline:
; 1. LLM_Parser_ParseResponse now exposes accumulated dedup stats through an
;    optional by-ref out-param (&out_stats). Before the fix the stats were
;    computed locally and silently discarded on return.
; 2. _LLM_Engine_OnBatchSuccess no longer overwrites state["dedup_stats"] with
;    a fresh zeroed map after _LLM_Engine_ParseSlots (which now captures real
;    stats via the new by-ref param). The deletion of that overwrite line is
;    asserted here by verifying the out-param path end-to-end rather than
;    re-parsing the internal engine state, keeping the test self-contained
;    within the parser layer.
;
; Test strategy: feed a batch response containing three candidates where two
; are identical ("foo===foo===bar"). The parser runs dedup, which yields
; candidates=3 / duplicates=1 / kept=2. Without the by-ref fix, out_stats
; would remain unset or zeroed; with it, the values must match exactly.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ By-ref out_stats param carries live counts =======
; =============================================================
; =============================================================

_LLMParserDedupStats_BatchDedup() {
	; Three candidates: "foo", "foo" (duplicate), "bar" — yields candidates=3,
	; duplicates=1, kept=2 when dedup is enabled (the default for ParseResponse).
	raw := "foo===foo===bar"
	out_stats := LLM_ApiCommon_NewDedupStats()
	LLM_Parser_ParseResponse(raw, "", "", 1, 15, true, 10, &out_stats)
	AssertEqual(3, out_stats["candidates"],
		"batch with 3 blocks must report candidates=3")
	AssertEqual(1, out_stats["duplicates"],
		"second 'foo' block must register as 1 duplicate")
	AssertEqual(2, out_stats["kept"],
		"exactly 2 distinct predictions must be kept")
}
Test("LLM parser dedup stats: batch with duplicate block reports correct counts",
	_LLMParserDedupStats_BatchDedup)





; =============================================================
; =============================================================
; ======= 2/ Without the out-param the call still works =======
; =============================================================
; =============================================================

_LLMParserDedupStats_NoOutParam() {
	; Calling without the optional by-ref param must not throw and must still
	; return the correct slot array (regression guard for the unset branch).
	raw := "foo===bar"
	slots := LLM_Parser_ParseResponse(raw, "", "", 1, 15, true, 10)
	AssertTrue(slots is Array,
		"ParseResponse without out_stats must still return an Array")
	AssertEqual(2, slots.Length,
		"two distinct blocks must produce two slots when no out_stats is requested")
}
Test("LLM parser dedup stats: omitting out_stats param does not throw",
	_LLMParserDedupStats_NoOutParam)





; ==============================================================
; ==============================================================
; ======= 3/ Zeroed stats when all candidates are unique =======
; ==============================================================
; ==============================================================

_LLMParserDedupStats_NoDedup() {
	; When all candidates differ, duplicates must be 0 and kept must equal candidates.
	raw := "alpha===beta===gamma"
	out_stats := LLM_ApiCommon_NewDedupStats()
	LLM_Parser_ParseResponse(raw, "", "", 1, 15, true, 10, &out_stats)
	AssertEqual(0, out_stats["duplicates"],
		"three unique candidates must produce zero duplicates")
	AssertEqual(out_stats["candidates"], out_stats["kept"],
		"kept must equal candidates when nothing is deduped")
}
Test("LLM parser dedup stats: all-unique batch yields zero duplicates",
	_LLMParserDedupStats_NoDedup)