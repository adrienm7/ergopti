; tests/unit/test_healthcheck_issues_from_errors_file.ahk

; ==============================================================================
; MODULE: Recent Issues Come From Today's Errors File
; DESCRIPTION:
; The window's "Recent warnings / errors" were filtered out of the 200-line
; in-memory ring, which holds every level: at DEBUG a few minutes of routine
; lines evicted the very problems the window is opened to show. They now come
; from a bounded tail of today's errors file (WARNING and ERROR only), and the
; ring answers only when that file does not exist yet (errors-file-issues).
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ The errors file first =======
; ========================================
; ========================================

; Writes a Windows-style errors file (BOM, CRLF) and returns its path.
_THIE_WriteErrorsFile() {
	Path := A_Temp . "\ergopti_hc_errors_" . A_TickCount . "_" . Random(1000, 9999) . ".log"
	FileAppend(Chr(0xFEFF) . "2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file`r`n"
		. "2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file`r`n", Path, "UTF-8-RAW")
	return Path
}

_THIE_ReadsTheErrorsFile() {
	Path := _THIE_WriteErrorsFile()
	try {
		Result := _HealthCheck_RecentIssues(Path)
		AssertEqual("errors_file", Result["source"], "an existing errors file must answer")
		AssertEqual(2, Result["entries"].Length, "both entries of the file")
		AssertEqual("2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file", Result["entries"][1])
		AssertEqual("2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file", Result["entries"][2])
	} finally {
		try FileDelete(Path)
	}
}

Test("HealthCheck: recent issues are read from today's errors file (errors-file-issues)",
	_THIE_ReadsTheErrorsFile)


_THIE_RingOnlyWhenTheFileIsAbsent() {
	Missing := A_Temp . "\ergopti_hc_missing_" . A_TickCount . ".log"
	Assert(!FileExist(Missing), "the fixture path must not exist")
	Marker := "ring-fallback-" . A_TickCount
	LoggerWarn("HcRing", "{1}", Marker)
	Result := _HealthCheck_RecentIssues(Missing)
	AssertEqual("ring", Result["source"], "without the file the ring answers")
	Found := false
	for Entry in Result["entries"]
		Found := Found || InStr(Entry, Marker) > 0
	Assert(Found, "the ring fallback must carry the warning just logged")
}

Test("HealthCheck: the ring answers only before today's errors file exists (errors-file-issues)",
	_THIE_RingOnlyWhenTheFileIsAbsent)


_THIE_RunReportsTheSource() {
	global LOGGER_ERRORS_LOG_PATH
	Saved := LOGGER_ERRORS_LOG_PATH
	Path := _THIE_WriteErrorsFile()
	try {
		LOGGER_ERRORS_LOG_PATH := Path
		Result := HealthCheck_Run()
		AssertEqual("errors_file", Result["recent_issues_source"], "the snapshot names its source")
		; The logger may append its own lines to this file during the run, so
		; the fixture's entry is searched for rather than expected last
		Found := false
		for Entry in Result["recent_issues"]
			Found := Found || (Entry == "2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file")
		Assert(Found, "the snapshot must carry the errors file's entries")
	} finally {
		LOGGER_ERRORS_LOG_PATH := Saved
		try FileDelete(Path)
	}
}

Test("HealthCheck: the snapshot carries the errors-file issues and their source (errors-file-issues)",
	_THIE_RunReportsTheSource)
