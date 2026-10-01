; tests/meta/test_llm_tooltip_chunk_type_guard.ahk

; ==============================================================================
; MODULE: LLM Tooltip chunk.type Guard Meta Test
; DESCRIPTION:
; Static source guard for finding llm-tooltip-chunk-type-guard (F-L03).
;
; _TooltipBuildGuiLlm's active-slot chunk loop guarded chunk.text and (later)
; chunk.type with HasOwnProp, but the colour decision dereferenced chunk.type
; UNCONDITIONALLY. A chunk object carrying text but no `type` property makes that
; read throw in AHK v2 ("no property named type"); the throw unwinds into the
; build try/catch, which hides the tooltip — so the whole prediction silently
; vanishes.
;
; The chunk loop used to sit inside the Gui build, which cannot run headlessly,
; so this was a source scan for the guard's spelling. The loop is now
; _LLM_SlotSegments, a pure function the build calls for every line: the
; malformed chunks are handed to it directly.
; ==============================================================================

#Requires AutoHotkey v2.0


_LTCG_MalformedChunksDoNotThrow() {
	Slot := {
		Text: "ignored",
		Chunks: [{ text: "no type" }, { type: "insert" }, { type: "equal", text: "kept" }],
		NextWords: " next"
	}
	Segments := _LLM_SlotSegments(Slot)
	AssertEqual(2, Segments.Length,
		"a chunk with no type or no text is left out; the line still renders (llm-tooltip-chunk-type-guard)")
	AssertEqual("kept", Segments[1].Text, "the well-formed chunk is kept")
	AssertEqual("typed", Segments[1].Role, "with its role")
	AssertEqual(" next", Segments[2].Text, "and the next words follow")
	Build := _DriverFuncBody("_TooltipBuildGuiLlm")
	Assert(Build != "", "_TooltipBuildGuiLlm must exist in the driver source")
	Assert(InStr(Build, "_LLM_SlotSegments(") > 0 and InStr(Build, ".Chunks") == 0,
		"the Gui build must read a slot's chunks through _LLM_SlotSegments only, never on its own")
}
Test("tooltip: a chunk with no type or no text never breaks the line (llm-tooltip-chunk-type-guard)", _LTCG_MalformedChunksDoNotThrow)
