; tests/meta/test_roi_current_word_unbounded_growth.ahk

; ==============================================================================
; MODULE: ROI Current-Word Cap Meta Test
; DESCRIPTION:
; Static source guard for the roi-current-word-unbounded-growth finding.
;
; KL_Roi_OnChar accumulates the in-progress word one character at a time and
; only flushes on a fixed set of boundary chars. A delimiter-free run (pasted
; JWT, long token) grew KLRoi.current_word without bound, turning the per-key
; O(1) append into an O(n) concat on the keystroke thread, and held a long
; secret-like token in RAM until a boundary appeared.
;
; The fix caps the buffer at KLRoiConst.MAX_INPROGRESS_WORD_LEN: once the run
; exceeds the cap, accumulation stops and the whole over-long run is discarded
; (via KLRoi.word_overflowed) at the next boundary so it never becomes a
; trigger candidate.
;
; This is a meta-static test (scans source text) because keylogger_trigger_roi
; is NOT in the run_all.ahk include graph — it is reached only through the
; keylogger module which registers top-level hooks, so it cannot be #Included
; in the headless runner without blocking clean exit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_RoiWord_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ===================================================
; ===================================================
; ======= 2/ Buffer-cap assertions ==================
; ===================================================
; ===================================================

; The cap constant must exist (named constant, not a magic number) so the
; in-progress buffer length is bounded.
_RoiWord_HasCapConstant() {
	Src := _RoiWord_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Assert(RegExMatch(Src, "static\s+MAX_INPROGRESS_WORD_LEN\s*:=\s*\d+"), "KLRoiConst.MAX_INPROGRESS_WORD_LEN must be defined so the in-progress word buffer is bounded (roi-current-word-unbounded-growth)")
}

; KL_Roi_OnChar must check the buffer length against the cap before appending,
; and reset the buffer once the cap is reached so growth is bounded on the
; keystroke thread.
_RoiWord_OnCharCapsBuffer() {
	Src := _RoiWord_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _DriverFuncBody("KL_Roi_OnChar")
	Assert(Body != "", "KL_Roi_OnChar must exist in keylogger_trigger_roi.ahk (roi-current-word-unbounded-growth)")
	Assert(InStr(Body, "MAX_INPROGRESS_WORD_LEN") > 0, "KL_Roi_OnChar must bound current_word against MAX_INPROGRESS_WORD_LEN before appending (roi-current-word-unbounded-growth)")
	Assert(InStr(Body, "StrLen(KLRoi.current_word)") > 0, "KL_Roi_OnChar must measure StrLen(current_word) to enforce the cap (roi-current-word-unbounded-growth)")
}

; The over-long run must be discarded, not kept as a fragment: KL_Roi_OnChar
; must use the word_overflowed flag and bail out at the boundary so an
; over-long run never reaches KL_Roi_ProcessWord and becomes a candidate.
_RoiWord_OverflowDiscardsRun() {
	Src := _RoiWord_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _DriverFuncBody("KL_Roi_OnChar")
	Assert(InStr(Body, "word_overflowed") > 0, "KL_Roi_OnChar must track an overflow flag so the over-long run is discarded (roi-current-word-unbounded-growth)")
	; The boundary path must early-return on overflow before calling ProcessWord.
	OverflowIdx := InStr(Body, "if (overflowed)")
	ProcessIdx := InStr(Body, "KL_Roi_ProcessWord(word)")
	Assert(OverflowIdx > 0, "KL_Roi_OnChar must branch on the overflow flag at the boundary (roi-current-word-unbounded-growth)")
	Assert(ProcessIdx > OverflowIdx, "KL_Roi_OnChar must check overflow and return BEFORE KL_Roi_ProcessWord so an over-long run never becomes a candidate (roi-current-word-unbounded-growth)")
}

Test("keylogger_trigger_roi: MAX_INPROGRESS_WORD_LEN constant exists (roi-current-word-unbounded-growth)", _RoiWord_HasCapConstant)
Test("keylogger_trigger_roi: KL_Roi_OnChar caps the in-progress buffer (roi-current-word-unbounded-growth)", _RoiWord_OnCharCapsBuffer)
Test("keylogger_trigger_roi: KL_Roi_OnChar discards the over-long run (roi-current-word-unbounded-growth)", _RoiWord_OverflowDiscardsRun)
