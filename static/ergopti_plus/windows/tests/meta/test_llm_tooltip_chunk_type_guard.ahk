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
; vanishes. The fix mirrors the sibling guard: every chunk.type read must be
; co-located with a HasOwnProp("type") check.
;
; Meta-static because the tooltip build path constructs a real Gui and cannot be
; exercised headlessly; it scans ui/tooltip source for any unguarded chunk.type read.
; ==============================================================================

#Requires AutoHotkey v2.0


_LTCG_AssertChunkTypeGuarded() {
	Q := Chr(34)
	Src := _DriverDirConcat("ui/tooltip")
	Assert(InStr(Src, "chunk.type ==") > 0, "the tooltip render must compare chunk.type (sanity check)")
	pos := 0
	unguarded := 0
	while (pos := InStr(Src, "chunk.type ==", , pos + 1)) {
		; The text just before each read must contain the HasOwnProp("type") guard.
		ctx := SubStr(Src, Max(1, pos - 45), 45)
		if !InStr(ctx, "HasOwnProp(" . Q . "type" . Q . ")")
			unguarded += 1
	}
	Assert(unguarded == 0,
		"every chunk.type read in the tooltip render must be guarded by HasOwnProp(" . Q . "type" . Q . ") — an unguarded read on a type-less chunk throws and silently hides the whole prediction (llm-tooltip-chunk-type-guard)")
}
Test("tooltip: every chunk.type read is HasOwnProp-guarded (llm-tooltip-chunk-type-guard)", _LTCG_AssertChunkTypeGuarded)
