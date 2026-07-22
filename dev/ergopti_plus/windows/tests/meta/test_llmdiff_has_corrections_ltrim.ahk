; tests/meta/test_llmdiff_has_corrections_ltrim.ahk

; ==============================================================================
; MODULE: LLM Diff HasCorrections LTrim Guard
; DESCRIPTION:
; Static source guard for the HasCorrections post-LTrim evaluation fix in
; lib/llm_diff.ahk.
;
; ROOT CAUSE ENCODED:
; HasCorrections was computed from the first chunk before its text was trimmed.
; When a prediction started with leading whitespace (common for next-word
; suggestions), the first chunk's type was "equal" (correction) but its text was
; just spaces. After LTrim, that text became empty — so the displayed correction
; highlight was spurious. HasCorrections should be false for a chunk that is
; entirely whitespace.
;
; The fix evaluates HasCorrections AFTER the LTrim pass on the first chunk, so
; a chunk whose text is empty after stripping leading spaces is not counted as a
; real correction. The specific guard is:
;   has_corrections := (chunks.Length > 0
;                       and chunks[1].type == "equal"
;                       and chunks[1].text != "")
; and it must appear AFTER the LTrim assignment on chunks[1].text.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================================
; ======================================================================
; ======= 1/ HasCorrections evaluated after LTrim on first chunk =======
; ======================================================================
; ======================================================================

_TLDHCL_HasCorrectionsAfterLTrim() {
	Src := _DriverDirConcat("lib")

	; LTrim on the first chunk must be present
	Assert(InStr(Src, "LTrim(chunks[1].text)") > 0,
		"lib/llm_diff.ahk must LTrim chunks[1].text to strip leading whitespace from the first equal chunk")

	; HasCorrections assignment must be present
	Assert(InStr(Src, "has_corrections") > 0,
		"lib/llm_diff.ahk must compute a has_corrections flag")

	; The empty-text guard (chunks[1].text != "") must be in the HasCorrections expression
	Assert(InStr(Src, "chunks[1].text != " . Chr(0x22) . Chr(0x22)) > 0,
		'lib/llm_diff.ahk must guard HasCorrections with chunks[1].text != "" to exclude whitespace-only corrections after LTrim')

	; Verify ordering: LTrim must appear before the has_corrections assignment
	LtrimPos    := InStr(Src, "LTrim(chunks[1].text)")
	HcorrPos    := InStr(Src, "has_corrections :=")
	Assert(LtrimPos > 0 and HcorrPos > 0,
		"Both LTrim(chunks[1].text) and has_corrections := must be present in lib/llm_diff.ahk")
	Assert(LtrimPos < HcorrPos,
		"lib/llm_diff.ahk must evaluate has_corrections AFTER the LTrim pass on chunks[1].text (ordering matters)")
}
Test("llm_diff: HasCorrections evaluated after LTrim so whitespace-only equal chunks are excluded", _TLDHCL_HasCorrectionsAfterLTrim)
