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

_CRUN_UsesCompleteDurableWrite() {
	Body := _DriverFuncBody("CrashReport_Save")
	Assert(Body != "", "CrashReport_Save must remain reachable")
	Assert(InStr(Body, "FSWriteDurable") > 0,
		"a crash report must require complete UTF-8 bytes and a stable-storage receipt (AHK-087)")
	Assert(InStr(Body, ".Write(JsonStr)") = 0,
		"CrashReport_Save must not acknowledge an unchecked File.Write result")
}
Test("crash_reporter: CrashReport_Save requires a complete durable write (AHK-087)",
	_CRUN_UsesCompleteDurableWrite)

_CRUN_WriterRefusalCannotPublishSuccess() {
	global _ConfigDir, _CrashReporter_Subdir
	SavedConfigDir := _ConfigDir
	SavedSubdir := _CrashReporter_Subdir
	Root := A_Temp . "\ergopti_crash_report_refusal_" . A_TickCount . "\"
	WriterCalls := 0
	ObservedPath := ""

	_RefuseWriter(Path, Content) {
		WriterCalls += 1
		ObservedPath := Path
		return false
	}

	try {
		_ConfigDir := Root
		_CrashReporter_Subdir := "reports"
		Result := CrashReport_Save(Map(
			"timestamp", "2026-08-28T20:30:00Z",
			"driver", "autohotkey"), _RefuseWriter)
		Assert(Result = "" && WriterCalls = 1,
			"a refused durable writer must make CrashReport_Save fail instead of returning a success path")
		Assert(ObservedPath != "" && !FileExist(ObservedPath),
			"a failed crash report must leave no partial JSON artifact behind")
	} finally {
		_ConfigDir := SavedConfigDir
		_CrashReporter_Subdir := SavedSubdir
		try DirDelete(Root, true)
	}
}
Test("crash_reporter: writer refusal cannot publish a false success (AHK-087)",
	_CRUN_WriterRefusalCannotPublishSuccess)

_CRUN_NoFileAppend() {
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileAppend(JsonStr") = 0,
		"crash_reporter.ahk must NOT use FileAppend for crash reports — same-second writes corrupt the JSON file")
}
Test("crash_reporter: CrashReport_Save does not use FileAppend (crash-report-same-second-collision)", _CRUN_NoFileAppend)
