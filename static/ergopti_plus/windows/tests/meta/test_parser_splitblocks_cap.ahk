; tests/meta/test_parser_splitblocks_cap.ahk

; ==============================================================================
; MODULE: Parser SplitBlocks Cap Meta Test
; DESCRIPTION:
; Static source guard for the "llm-split-batch-no-cap" audit finding in
; modules/llm/parser.ahk.
;
; ROOT CAUSE ENCODED:
; _LLM_Engine_SplitBatchBlocks(raw, max_count) was written and tested in
; isolation, but LLM_Parser_ParseResponse still called the unbounded
; LLM_Parser_SplitBlocks(raw) without a max_count parameter. A hallucinating
; model generating thousands of "===" separators could build a massive array
; before the outer slots.Length >= n_predictions guard ever fired, causing
; an unbounded memory allocation.
;
; The fix: LLM_Parser_SplitBlocks now accepts an optional max_count parameter
; and LLM_Parser_ParseResponse passes n_predictions as the cap.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ LLM_Parser_SplitBlocks max_count param =======
; =========================================================
; =========================================================

_PSC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_PSC_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_PSC_SplitBlocksHasMaxCount() {
	Src := _PSC_ReadSource("modules/llm/parser.ahk")

	Assert(InStr(Src, "LLM_Parser_SplitBlocks(raw, max_count") > 0,
		"LLM_Parser_SplitBlocks must accept a max_count parameter (llm-split-batch-no-cap)")

	Body := _DriverFuncBody("LLM_Parser_SplitBlocks")
	Assert(InStr(Body, "max_count") > 0 and InStr(Body, "blocks.Length >= max_count") > 0,
		"LLM_Parser_SplitBlocks must break when blocks.Length >= max_count (llm-split-batch-no-cap)")
}
Test("parser: LLM_Parser_SplitBlocks accepts and enforces max_count (llm-split-batch-no-cap)", _PSC_SplitBlocksHasMaxCount)





; =================================================================
; =================================================================
; ======= 2/ LLM_Parser_ParseResponse passes n_predictions ========
; =================================================================
; =================================================================

_PSC_ParseResponsePassesCap() {
	Src := _PSC_StripComments(_PSC_ReadSource("modules/llm/parser.ahk"))
	Body := _DriverFuncBody("LLM_Parser_ParseResponse")

	Assert(Body != "", "LLM_Parser_ParseResponse must exist in parser.ahk")

	; The call to LLM_Parser_SplitBlocks must now pass n_predictions as the cap
	Assert(RegExMatch(Body, "LLM_Parser_SplitBlocks\(raw\s*,\s*n_predictions\)") > 0,
		"LLM_Parser_ParseResponse must call LLM_Parser_SplitBlocks(raw, n_predictions) (llm-split-batch-no-cap)")

	; The old unbounded call must be gone
	Assert(!RegExMatch(Body, "LLM_Parser_SplitBlocks\(raw\s*\)"),
		"LLM_Parser_ParseResponse must NOT call LLM_Parser_SplitBlocks(raw) without a cap (llm-split-batch-no-cap)")
}
Test("parser: LLM_Parser_ParseResponse calls SplitBlocks with n_predictions cap (llm-split-batch-no-cap)", _PSC_ParseResponsePassesCap)
