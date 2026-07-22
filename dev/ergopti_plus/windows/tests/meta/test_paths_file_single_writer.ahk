; tests/meta/test_paths_file_single_writer.ahk

; ==============================================================================
; MODULE: paths.toml Single-Writer Meta Test
; DESCRIPTION:
; paths.toml decides where the ENTIRE driver reads and writes its config, so a
; write that fails silently is expensive: the user picks a new directory, the
; write is discarded, and the Reload() drops them straight back into the old one
; with nothing reported anywhere. The change simply appears not to have happened.
;
; There were two copies of that writer — the WebView2 editor's, which was
; hardened, and a verbatim pre-hardening twin in the action picker's
; ConfirmPath, still carrying the unprotected FileOpen and an `if f` with no
; else. The duplication is the ROOT CAUSE: hardening one copy could never fix
; the other, and nothing made them fail together.
;
; FEATURES & RATIONALE:
; 1. Asserts there is exactly ONE writer, rather than asserting both writers are
;    hardened — the latter is satisfiable by re-duplicating the hardened block,
;    which leaves the drift mechanism fully intact.
; 2. Pins the writer's failure contract, so it cannot regress to a silent skip.
;
; SCOPE: source introspection of ui/ via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Exactly one writer exists =========
; ==============================================
; ==============================================

_PFSW_OnlyOneWriter() {
	Src := _DriverDirConcat("ui")
	Assert(Src != "", "the ui/ source must be readable")

	; Count the sites that open paths.toml for writing. Anything above one means
	; the block was copied again and the two copies can drift apart, which is the
	; defect this guard exists to prevent.
	Needle := 'FileOpen(_PathsFile, "w"'
	Count := 0
	Pos := 1
	while (Pos := InStr(Src, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	Assert(Count == 1,
		"paths.toml must have exactly ONE writer (found " . Count . "). Two copies of this block already drifted once: the hardened one reported failures, its twin discarded the user's chosen directory in silence and reloaded them into the old one.")

	Assert(InStr(Src, "_PathsFile_Write(") > 0,
		"the shared writer _PathsFile_Write must exist and be the site both editors call")
}

; The writer must fail loudly. A silent skip here is indistinguishable from
; success to every caller, because the Reload() that follows hides the evidence.
_PFSW_WriterFailsLoudly() {
	Body := _DriverFuncBody("_PathsFile_Write")
	Assert(Body != "", "_PathsFile_Write() must exist")

	Assert(InStr(Body, "catch as") > 0,
		"_PathsFile_Write must catch explicitly — an unprotected FileOpen throws in v2 and would abort the caller mid-save")
	Assert(InStr(Body, "LoggerError") > 0,
		"a failed paths.toml write must reach the log")
	Assert(InStr(Body, "MsgBox") > 0,
		"a failed paths.toml write must be shown to the user — they are standing in front of the dialog, and the following Reload() erases the evidence")
	Assert(InStr(Body, "return false") > 0,
		"_PathsFile_Write must report failure to its caller so the Reload() is skipped")
}

; Both callers must honour that contract: reloading after a failed write is what
; puts the user back in the old directory with no explanation.
_PFSW_CallersSkipReloadOnFailure() {
	Src := _DriverDirConcat("ui")
	Pos := 1
	Checked := 0
	while (Pos := InStr(Src, "_PathsFile_Write(", , Pos)) {
		; Skip the definition itself.
		LineStart := InStr(Src, "`n", , Pos - 120) + 1
		Head := SubStr(Src, (Pos > 120) ? Pos - 120 : 1, 120)
		if (InStr(Head, "_PathsFile_Write(N) {") == 0 and InStr(SubStr(Src, Pos, 40), "(N) {") == 0) {
			Checked += 1
			Window := SubStr(Src, (Pos > 40) ? Pos - 40 : 1, 200)
			Assert(InStr(Window, "if !_PathsFile_Write") > 0,
				"every caller must branch on the writer's return value — reloading after a failed write drops the user back into the old config directory with nothing reported")
		}
		Pos += StrLen("_PathsFile_Write(")
	}
	Assert(Checked >= 2,
		"expected at least two call sites to police (found " . Checked . ") — both the WebView2 editor and the action picker must go through the shared writer")
}


Test("meta paths: paths.toml has exactly one writer",
	_PFSW_OnlyOneWriter)
Test("meta paths: the shared writer fails loudly rather than skipping",
	_PFSW_WriterFailsLoudly)
Test("meta paths: every caller skips the reload when the write failed",
	_PFSW_CallersSkipReloadOnFailure)
