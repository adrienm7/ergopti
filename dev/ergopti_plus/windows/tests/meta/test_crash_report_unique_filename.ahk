; tests/meta/test_crash_report_unique_filename.ahk

; ==============================================================================
; MODULE: Crash Report Unique Filename Meta Test
; DESCRIPTION:
; Static source guard for the "same-second crash report filename collision"
; finding (crash-report-same-second-collision).
;
; modules/diagnostics/crash_reporter.ahk previously derived the filename from a second-resolution
; timestamp and wrote with FileAppend. Two crashes within the same second would
; open the same path and append, producing concatenated JSON objects (}{) in one
; file — invalid JSON that no parser can consume.
;
; The fix introduces a uniqueness loop (FileExist + numeric suffix) and replaces
; FileAppend with FileOpen("w") (truncating write) so each report always lands in
; its own, newly-created file. These tests assert the fix is present and the
; buggy form is absent.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Uniqueness loop assertions ==========
; ================================================
; ================================================

_CRUN_HasFileExistLoop() {
	; Move-resilient: scan the module tree via the framework helper instead of
	; a pinned crash_reporter path. The FName/JsonStr tokens are unique to
	; crash_reporter within modules/diagnostics/, so the scope stays meaningful.
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileExist(FName)") > 0,
		"crash_reporter.ahk must contain a FileExist(FName) uniqueness loop to handle same-second collisions")
}
Test("crash_reporter: CrashReport_Save contains FileExist uniqueness loop (crash-report-same-second-collision)", _CRUN_HasFileExistLoop)

_CRUN_HasTruncatingWrite() {
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileOpen(FName, " . Chr(0x22) . "w" . Chr(0x22)) > 0,
		'crash_reporter.ahk must use FileOpen(FName, "w") truncating write instead of FileAppend')
}
Test("crash_reporter: CrashReport_Save uses FileOpen truncating write (crash-report-same-second-collision)", _CRUN_HasTruncatingWrite)

_CRUN_NoFileAppend() {
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileAppend(JsonStr") = 0,
		"crash_reporter.ahk must NOT use FileAppend for crash reports — same-second writes corrupt the JSON file")
}
Test("crash_reporter: CrashReport_Save does not use FileAppend (crash-report-same-second-collision)", _CRUN_NoFileAppend)