; tests/meta/test_download_integrity_guard.ahk

; ==============================================================================
; MODULE: Download Integrity Guard Meta Test
; DESCRIPTION:
; Static source guard for the download-no-integrity-partial-safety finding.
;
; Updater_InstallRelease previously wrote the downloaded binary to disk and
; immediately launched the swap script with no verification. A CDN truncation,
; network timeout, or error-page body (e.g. "Service Unavailable" HTML) would
; silently produce a zero-byte or tiny file that the batch script then moved
; into place as the production exe — bricking the installation.
;
; The fix adds two complementary guards in lib/updater.ahk:
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

_DIG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the body of a named function up to the first unindented closing
; brace, stripping comment lines to avoid false positives.
_DIG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
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
	Src := _DIG_ReadSource("lib/updater.ahk")
	Assert(InStr(Src, "UPDATER_MIN_EXE_SIZE_BYTES") > 0,
		"lib/updater.ahk must declare UPDATER_MIN_EXE_SIZE_BYTES — the named constant for the minimum valid exe size (rule 5.1: no magic numbers; download-no-integrity-partial-safety)")
}
Test("updater: UPDATER_MIN_EXE_SIZE_BYTES constant declared (download-no-integrity-partial-safety)", _DIG_MinSizeConstantDeclared)







; ===================================================
; ===================================================
; ======= 3/ Integrity checks in install path =======
; ===================================================
; ===================================================

_DIG_ContentLengthCheckPresent() {
	Src := _DIG_ReadSource("lib/updater.ahk")
	; The install function is large; anchor on a unique string near the download path
	Idx := InStr(Src, "ADODB.Stream")
	Assert(Idx > 0, "Download via ADODB.Stream must exist in lib/updater.ahk")
	; Look for the Content-Length guard in the 3000 chars following the stream write
	Window := SubStr(Src, Idx, 3000)
	Assert(InStr(Window, "Content-Length") > 0,
		"Updater install path must check Content-Length response header to detect partial downloads (download-no-integrity-partial-safety)")
}
Test("updater: install path reads Content-Length header to detect truncated downloads (download-no-integrity-partial-safety)", _DIG_ContentLengthCheckPresent)

_DIG_MinSizeCheckPresent() {
	Src := _DIG_ReadSource("lib/updater.ahk")
	Idx := InStr(Src, "ADODB.Stream")
	Assert(Idx > 0, "Download via ADODB.Stream must exist in lib/updater.ahk")
	Window := SubStr(Src, Idx, 3000)
	Assert(InStr(Window, "UPDATER_MIN_EXE_SIZE_BYTES") > 0,
		"Updater install path must reject downloads below UPDATER_MIN_EXE_SIZE_BYTES to guard against error-page responses (download-no-integrity-partial-safety)")
}
Test("updater: install path rejects downloads smaller than UPDATER_MIN_EXE_SIZE_BYTES (download-no-integrity-partial-safety)", _DIG_MinSizeCheckPresent)

_DIG_PartialFileDeleted() {
	Src := _DIG_ReadSource("lib/updater.ahk")
	Idx := InStr(Src, "Content-Length")
	Assert(Idx > 0, "Content-Length guard must exist in lib/updater.ahk")
	; After the Content-Length check, a FileDelete must appear before a MsgBox abort
	Window := SubStr(Src, Idx, 1000)
	Assert(InStr(Window, "FileDelete") > 0,
		"Updater must delete the partial file on size mismatch — leaving it behind risks the swap script installing a corrupted binary (download-no-integrity-partial-safety)")
}
Test("updater: partial download file is deleted before aborting install (download-no-integrity-partial-safety)", _DIG_PartialFileDeleted)
