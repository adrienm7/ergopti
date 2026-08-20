; tests/meta/test_download_integrity_guard.ahk

; ==============================================================================
; MODULE: Download Integrity Guard Meta Test
; DESCRIPTION:
; Static source guard for the download-no-integrity-partial-safety finding.
;
; Updater_InstallRelease previously wrote the downloaded binary to disk and
; immediately launched the swap script with no verification. A CDN truncation,
; network timeout, or error-page body (e.g. "Service Unavailable" HTML) would
; silently produce a zero-byte or tiny file that the swap worker then published
; into place as the production exe — bricking the installation.
;
; The fix adds two complementary guards in modules/updater.ahk:
; a) Content-Length check: compares the Content-Length response header to the
;    actual saved file size. On mismatch the partial file is deleted and the
;    install is aborted with an error message.
; b) Minimum-size floor (UPDATER_MIN_EXE_SIZE_BYTES): rejects any download
;    that is too small to be a valid ErgoptiPlus binary even if Content-Length
;    was absent or incorrect, protecting against error-page downloads.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

; Extracts the body of a named function up to the first unindented closing
; brace, stripping comment lines to avoid false positives.
_DIG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ Minimum size constant ==================
; ===================================================
; ===================================================

_DIG_MinSizeConstantDeclared() {
	Src := _DriverDirConcat("modules/updater")
	Assert(InStr(Src, "UPDATER_MIN_EXE_SIZE_BYTES") > 0,
		"modules/updater.ahk must declare UPDATER_MIN_EXE_SIZE_BYTES — the named constant for the minimum valid exe size (rule 5.1: no magic numbers; download-no-integrity-partial-safety)")
}
Test("updater: UPDATER_MIN_EXE_SIZE_BYTES constant declared (download-no-integrity-partial-safety)", _DIG_MinSizeConstantDeclared)







; ===================================================
; ===================================================
; ======= 3/ Integrity checks in install path =======
; ===================================================
; ===================================================

_DIG_ContentLengthCheckPresent() {
	Worker := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(Worker != "", "The isolated staging worker must exist")
	Assert(InStr(Worker, "$ExpectedSize = [int64]$Response.ContentLength") > 0,
		"Worker must read Content-Length before accepting a downloaded executable (download-no-integrity-partial-safety)")
	Assert(InStr(Worker, "$ActualSize -ne $ExpectedSize") > 0,
		"Worker must reject a Content-Length mismatch before publishing the swap payload (download-no-integrity-partial-safety)")
}
Test("updater: install path reads Content-Length header to detect truncated downloads (download-no-integrity-partial-safety)", _DIG_ContentLengthCheckPresent)

_DIG_MinSizeCheckPresent() {
	Start := _DriverFuncBody("_Updater_StartStagingWorker")
	Worker := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(InStr(Start, "UPDATER_MIN_EXE_SIZE_BYTES") > 0 and InStr(Worker, "$ActualSize -lt $MinimumSize") > 0,
		"Worker must reject downloads below UPDATER_MIN_EXE_SIZE_BYTES to guard against error-page responses (download-no-integrity-partial-safety)")
}
Test("updater: install path rejects downloads smaller than UPDATER_MIN_EXE_SIZE_BYTES (download-no-integrity-partial-safety)", _DIG_MinSizeCheckPresent)

_DIG_PartialFileDeleted() {
	Worker := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Mismatch := InStr(Worker, "$ActualSize -ne $ExpectedSize")
	Remove := InStr(Worker, "Remove-Item -LiteralPath $NewExe -Force", false, Mismatch)
	Assert(Mismatch > 0 and Remove > Mismatch,
		"Worker must delete the partial file on size mismatch — leaving it behind risks the swap script installing a corrupted binary (download-no-integrity-partial-safety)")
}
Test("updater: partial download file is deleted before aborting install (download-no-integrity-partial-safety)", _DIG_PartialFileDeleted)
