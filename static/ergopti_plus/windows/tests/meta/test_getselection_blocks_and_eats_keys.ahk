; tests/meta/test_getselection_blocks_and_eats_keys.ahk

; ==============================================================================
; MODULE: GetSelection Fail-Fast ClipWait Guard Meta Test
; DESCRIPTION:
; Static source guard for the finding getselection-blocks-and-eats-keys.
;
; GetSelection runs on the keyboard thread (case-conversion / web-search
; chords). Before the fix it called ClipWait(2) and ignored the return value,
; so a slow or unresponsive app stalled input for up to 2 s and a timed-out
; capture was treated as a valid empty selection -- callers then pasted the
; restored (stale) clipboard via SendInstant.
;
; The fix (1) checks ClipWait's return and returns "" on a timeout so callers
; no-op, and (2) lowers GET_SELECTION_TIMEOUT_SEC to a tight interactive
; ceiling (0.5 s) so a non-responsive app cannot stall the keyboard thread.
;
; This is a meta-static test: GetSelection touches the real clipboard
; (ClipboardAll / A_Clipboard / ClipWait), so a direct behavioral call is
; unsafe in the headless runner. The test scans hotstring_engine.ahk source
; text instead. If the ClipWait return check is removed, or the timeout is
; raised back toward the old 2 s exposure window, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_GSBlk_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body -- from its declaration to the first closing
; brace at column 0 (AHK functions close with `}` flush-left). Returns "" when
; the declaration is absent.
_GSBlk_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Fail-fast ClipWait guard assertions ===
; ==================================================
; ==================================================

; GetSelection must check ClipWait's return and bail out (no stale paste) on
; a timeout. Before the fix it called ClipWait(...) and ignored the result.
_GSBlk_GetSelectionChecksClipWait() {
	Src := _GSBlk_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Seg := _GSBlk_FuncBody(Src, "GetSelection() {")
	Assert(Seg != "", "GetSelection() declaration must exist in hotstring_engine.ahk")
	Assert(InStr(Seg, "!ClipWait(") > 0,
		"GetSelection must check the ClipWait return value -- a timed-out copy must "
		. "not be treated as a valid empty selection that triggers a stale paste")
	Assert(InStr(Seg, "return " . Chr(34) . Chr(34)) > 0,
		"GetSelection must return an empty string on a ClipWait timeout so callers no-op")
}
Test("hotstring_engine: GetSelection checks ClipWait return and fails fast (getselection-blocks-and-eats-keys)",
	_GSBlk_GetSelectionChecksClipWait)

; The interactive ClipWait ceiling must be tight (< 1 s). A 2 s ceiling is a
; large LowLevelHooksTimeout exposure window on the keyboard thread.
_GSBlk_TimeoutIsTight() {
	Src := _GSBlk_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Assert(InStr(Src, "GET_SELECTION_TIMEOUT_SEC := 0.5") > 0,
		"GET_SELECTION_TIMEOUT_SEC must be a tight interactive ceiling (0.5 s) so a "
		. "non-responsive app cannot stall the keyboard thread for seconds")
}
Test("hotstring_engine: GetSelection ClipWait timeout is a tight interactive ceiling (getselection-blocks-and-eats-keys)",
	_GSBlk_TimeoutIsTight)

; The four case-conversion chords must no-op on an empty/failed capture so a
; ClipWait timeout cannot trigger a stale paste through SendInstant.
_GSBlk_CaseChordsNoOpOnEmpty() {
	WinSrc := _GSBlk_ReadSource("modules/shortcuts/win.ahk")
	GestSrc := _GSBlk_ReadSource("modules/gestures.ahk")
	EmptyGuard := "if (Text = " . Chr(34) . Chr(34) . ")"

	UpperSeg := _GSBlk_FuncBody(WinSrc, "ConvertToUppercase(*) {")
	Assert(InStr(UpperSeg, EmptyGuard) > 0,
		"ConvertToUppercase must no-op on an empty selection (no stale SendInstant)")

	TitleSeg := _GSBlk_FuncBody(WinSrc, "ConvertToTitleCase(*) {")
	Assert(InStr(TitleSeg, EmptyGuard) > 0,
		"ConvertToTitleCase must no-op on an empty selection (no stale SendInstant)")

	GUpperSeg := _GSBlk_FuncBody(GestSrc, "GestureToggleUppercase() {")
	Assert(InStr(GUpperSeg, EmptyGuard) > 0,
		"GestureToggleUppercase must no-op on an empty selection (no stale SendInstant)")

	GTitleSeg := _GSBlk_FuncBody(GestSrc, "GestureToggleTitleCase() {")
	Assert(InStr(GTitleSeg, EmptyGuard) > 0,
		"GestureToggleTitleCase must no-op on an empty selection (no stale SendInstant)")
}
Test("hotstring_engine: case-conversion chords no-op on empty selection (getselection-blocks-and-eats-keys)",
	_GSBlk_CaseChordsNoOpOnEmpty)
