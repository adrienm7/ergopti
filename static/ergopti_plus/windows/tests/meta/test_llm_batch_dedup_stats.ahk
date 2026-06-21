; tests/meta/test_llm_batch_dedup_stats.ahk

; ==============================================================================
; MODULE: LLM Batch State dedup_stats Meta Test
; DESCRIPTION:
; Regression guard for HIGH-06: fix-llm-batch-dedup-stats-missing.
;
; _LLM_Engine_FirePrediction builds a "state" Map for the batch path
; (n_predictions > 1 and is_batch_profile) that omitted the "dedup_stats" key.
; _LLM_Engine_ParseSlots unconditionally reads state["dedup_stats"] via bracket
; access (no .Has guard). AHK v2 Map access on a missing key THROWS. This throw
; occurs inside the WinHTTP/SetTimer async success callback, where AHK swallows
; exceptions silently — so every batch prediction produced zero results with
; no log line, no tooltip, and no diagnostic. The batch_advanced profile
; (auto-selected for >=4B models) was therefore completely dead.
;
; Fix (primary): add "dedup_stats", LLM_ApiCommon_NewDedupStats() to the batch
; state Map literal, mirroring the sequential state Map.
; Fix (defensive): harden _LLM_Engine_ParseSlots to use state.Has("dedup_stats")
; ? state["dedup_stats"] : LLM_ApiCommon_NewDedupStats() so a missing key can
; never crash the parser again.
;
; This test asserts:
;   (a) The batch state Map literal contains a "dedup_stats" key.
;   (b) _LLM_Engine_ParseSlots uses state.Has("dedup_stats") rather than a bare
;       bracket access as the primary dedup_ref assignment.
;
; SCOPE: source introspection of modules/llm/prediction_engine.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =======================================================
; =======================================================
; ======= 1/ Source scan helpers ========================
; =======================================================
; =======================================================

; Extracts the batch state Map literal from the source — the block between
; "if (n_predictions > 1 and is_batch_profile) {" and the first "state := Map("
; after it, up to the matching closing parenthesis.
_LBDS_ExtractBatchStateMap(Src) {
	GatePos := InStr(Src, "if (n_predictions > 1 and is_batch_profile) {")
	if (!GatePos)
		return ""
	MapPos := InStr(Src, "state := Map(", , GatePos)
	if (!MapPos)
		return ""
	; Walk to the matching closing parenthesis.
	depth := 0
	i := MapPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "(")
			depth++
		else if (ch == ")") {
			depth--
			if (depth <= 0)
				return SubStr(Src, MapPos, i - MapPos + 1)
		}
		i++
	}
	return SubStr(Src, MapPos)
}

; Extracts the dedup_ref assignment line inside _LLM_Engine_ParseSlots.
_LBDS_ExtractParseSlotsDedup(Src) {
	FnPos := InStr(Src, "_LLM_Engine_ParseSlots(raw, state) {")
	if (!FnPos)
		return ""
	; Return the substring of the first 40 lines of the function body.
	Segment := SubStr(Src, FnPos, 2000)
	DeducPos := InStr(Segment, "dedup_ref")
	if (!DeducPos)
		return ""
	; Return ~80 chars around the assignment for the assertion.
	return SubStr(Segment, DeducPos, 120)
}


; =====================================================
; =====================================================
; ======= 2/ Test implementations =====================
; =====================================================
; =====================================================

_LBDS_CheckBatchMapHasDedupStats() {
	Src := _DriverDirConcat("modules/llm")

	BatchMap := _LBDS_ExtractBatchStateMap(Src)
	Assert(BatchMap != "",
		'Batch state Map must be present after "if (n_predictions > 1 and is_batch_profile) {"')

	; (a) The batch Map must include the dedup_stats key.
	Assert(InStr(BatchMap, '"dedup_stats"'),
		'Batch state Map must include "dedup_stats" key to prevent a throw in _LLM_Engine_ParseSlots (HIGH-06 fix-llm-batch-dedup-stats-missing)')

	; Also assert it references LLM_ApiCommon_NewDedupStats() as the value.
	Assert(InStr(BatchMap, "LLM_ApiCommon_NewDedupStats()"),
		'Batch state "dedup_stats" value must be LLM_ApiCommon_NewDedupStats() — matching the sequential state Map')
}

_LBDS_CheckParseSlotsDefensiveGuard() {
	Src := _DriverDirConcat("modules/llm")

	DeducSegment := _LBDS_ExtractParseSlotsDedup(Src)
	Assert(DeducSegment != "",
		"dedup_ref assignment must be present inside _LLM_Engine_ParseSlots")

	; (b) The dedup_ref assignment must use a .Has guard rather than bare bracket access.
	Assert(InStr(DeducSegment, 'state.Has("dedup_stats")'),
		'_LLM_Engine_ParseSlots must use state.Has("dedup_stats") for the dedup_ref assignment — bare bracket access throws on missing key (HIGH-06 fix-llm-batch-dedup-stats-missing)')

	; Bare bracket access state["dedup_stats"] alone (without .Has) must not be
	; the primary form — if it appears it must be inside the ternary branch.
	; We check that the .Has guard is present (already done above), which is sufficient
	; to confirm the defensive form is in use.
}


Test("meta fix-llm-batch-dedup-stats: batch state Map includes dedup_stats key",
	_LBDS_CheckBatchMapHasDedupStats)

Test("meta fix-llm-batch-dedup-stats: _LLM_Engine_ParseSlots uses state.Has guard for dedup_ref",
	_LBDS_CheckParseSlotsDefensiveGuard)
