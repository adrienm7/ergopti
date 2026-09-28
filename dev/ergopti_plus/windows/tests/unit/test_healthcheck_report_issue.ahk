; tests/unit/test_healthcheck_report_issue.ahk

; ==============================================================================
; MODULE: Diagnostics Page Actions And Suggest A Feature (Windows)
; DESCRIPTION:
; Drives HealthCheck_PerformAction, what the diagnostics page's buttons do once
; HealthCheck_ValidateAction accepted them, over recorded side effects (Debug >
; Report a bug opens the page at its preview; its report button sends the
; "report" action):
; 1. copy writes the redacted report, and a refused clipboard is a failure
;    that keeps the window (nothing closes here);
; 2. save writes the redacted report under the snapshot's diagnostics folder
;    and selects it in Explorer;
; 3. report copies, saves, selects, then opens the bug form last, its fields
;    redacted, and a refused clipboard stops it before the browser;
; 4. open_path opens the path the host collected, creating a missing folder,
;    and refuses a file that does not exist;
; 5. an unknown profile folder refuses everything: nothing could be redacted;
; 6. Suggest a feature opens the feature form with the version and the system.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ The Fixture =======
; ==============================
; ==============================

; Side effects that record every call in order.
; @param Calls {Array} Receives "name:argument" entries.
; @param Options {Map} { clipboard: Boolean, exists: Boolean }
; @returns {Map}
_THPA_Effects(Calls, Options := 0) {
	Options := (Options is Map) ? Options : Map()
	return Map(
		"copy",     (Text) => (Calls.Push("copy:" . Text), Options.Get("clipboard", true)),
		"save",     (Dir, Name, Text) => (Calls.Push("save:" . Dir . "\" . Name . ":" . Text), Dir . "\" . Name),
		"reveal",   (Path) => (Calls.Push("reveal:" . Path), true),
		"make_dir", (Dir) => (Calls.Push("make_dir:" . Dir), true),
		"exists",   (Path) => (Calls.Push("exists:" . Path), Options.Get("exists", true)),
		"open",     (Path) => (Calls.Push("open:" . Path), true),
		"open_url", (Url) => (Calls.Push("open_url:" . Url), true),
		"notify",   (Title, Body, Kind) => (Calls.Push("notify:" . Kind), true),
		"identity", () => Map("home", "C:\Users\JDoe", "user", "JDoe"))
}

; The snapshot's paths section of the fixture.
_THPA_Paths() {
	return Map(
		"logs_dir",        "C:\Users\JDoe\AppData\Local\ergopti_plus\logs",
		"diagnostics_dir", "C:\Users\JDoe\AppData\Local\ergopti_plus\logs\diagnostics",
		"errors_today",    "C:\Users\JDoe\AppData\Local\ergopti_plus\logs\ErgoptiPlus_errors_2026-09-24.log")
}

; Joins the recorded calls for a readable assertion.
_THPA_Join(Calls) {
	Out := ""
	for Index, Call in Calls
		Out .= (Index > 1 ? " | " : "") . Call
	return Out
}





; ============================
; ============================
; ======= 2/ The Tests =======
; ============================
; ============================

_THPA_CopyIsRedacted() {
	Calls := []
	Outcome := HealthCheck_PerformAction(Map("action", "copy", "text", "log at c:\users\jdoe\x by JDoe"),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	AssertTrue(Outcome["ok"])
	AssertEqual("copy:log at ~\x by <user>", _THPA_Join(Calls))
}
Test("Diagnostics page: copy writes the redacted report (page-actions)", _THPA_CopyIsRedacted)

_THPA_RefusedCopyFails() {
	Calls := []
	Outcome := HealthCheck_PerformAction(Map("action", "copy", "text", "report"), _THPA_Paths(), HealthCheck_Config(),
		_THPA_Effects(Calls, Map("clipboard", false)))
	AssertFalse(Outcome["ok"], "a refused clipboard must be reported to the page as a failure")
}
Test("Diagnostics page: a refused clipboard is a failure (healthcheck-copy-receipt)", _THPA_RefusedCopyFails)

_THPA_SaveUnderDiagnostics() {
	Calls := []
	Name := "ergopti-diagnostics-windows-2.1.0-20260924T100000Z.md"
	Outcome := HealthCheck_PerformAction(Map("action", "save", "text", "C:\Users\JDoe\file", "name", Name),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	Expected := _THPA_Paths()["diagnostics_dir"] . "\" . Name
	AssertTrue(Outcome["ok"])
	AssertEqual(Expected, Outcome["path"])
	AssertEqual("save:" . Expected . ":~\file | reveal:" . Expected, _THPA_Join(Calls))
}
Test("Diagnostics page: save writes under the diagnostics folder and selects it (page-actions)",
	_THPA_SaveUnderDiagnostics)

_THPA_ReportOrder() {
	Calls := []
	Name := "ergopti-diagnostics-windows-2.1.0-x.md"
	Fields := Map("version", "2.1.0", "os", "Windows 11", "driver", "windows",
		"diagnostics", "Last error: C:\Users\JDoe\boom")
	Outcome := HealthCheck_PerformAction(Map("action", "report", "text", "report", "name", Name, "fields", Fields),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	AssertTrue(Outcome["ok"])
	AssertEqual(4, Calls.Length, _THPA_Join(Calls))
	AssertTrue(InStr(Calls[1], "copy:") = 1 && InStr(Calls[2], "save:") = 1 && InStr(Calls[3], "reveal:") = 1
		&& InStr(Calls[4], "open_url:https://github.com/") = 1, "the browser must open last: " . _THPA_Join(Calls))
	AssertTrue(InStr(Calls[4], "template=bug_report.yml") > 0, Calls[4])
	AssertTrue(InStr(Calls[4], "JDoe") = 0, "the prefilled fields must be redacted: " . Calls[4])
}
Test("Diagnostics page: report copies, saves, selects, then opens the bug form (report-bug-flow)",
	_THPA_ReportOrder)

_THPA_ReportStopsOnRefusedClipboard() {
	Calls := []
	Outcome := HealthCheck_PerformAction(Map("action", "report", "text", "report", "name",
		"ergopti-diagnostics-w.md", "fields", Map()), _THPA_Paths(), HealthCheck_Config(),
		_THPA_Effects(Calls, Map("clipboard", false)))
	AssertFalse(Outcome["ok"])
	for Call in Calls
		AssertTrue(InStr(Call, "open_url:") = 0, "the browser must not open without the report in the clipboard")
}
Test("Diagnostics page: report stops before the browser when the clipboard refuses (report-bug-flow)",
	_THPA_ReportStopsOnRefusedClipboard)

_THPA_OpenPath() {
	Calls := []
	Outcome := HealthCheck_PerformAction(Map("action", "open_path", "id", "diagnostics_dir"), _THPA_Paths(),
		HealthCheck_Config(), _THPA_Effects(Calls))
	Dir := _THPA_Paths()["diagnostics_dir"]
	AssertTrue(Outcome["ok"])
	AssertEqual("make_dir:" . Dir . " | exists:" . Dir . " | open:" . Dir, _THPA_Join(Calls))

	Calls := []
	Outcome := HealthCheck_PerformAction(Map("action", "open_path", "id", "errors_today"), _THPA_Paths(),
		HealthCheck_Config(), _THPA_Effects(Calls, Map("exists", false)))
	AssertFalse(Outcome["ok"], "a missing errors file must not be reported as opened")
	for Call in Calls
		AssertTrue(InStr(Call, "make_dir:") = 0 && InStr(Call, "open:") = 0, "a file is never created: " . Call)
}
Test("Diagnostics page: open_path opens the collected path, creating only folders (page-actions)", _THPA_OpenPath)

; Today's errors file exists only once something went wrong today, so asking
; to open it earlier is no failure of the program. It was logged as an ERROR,
; which created that very file, counted as a session error and would raise
; the error dialog; the page is now told the file does not exist yet
; (open-missing-file).
_THPA_OpenMissingFile() {
	global _HealthCheckErrCount, _HealthCheckWarnCount
	Calls := []
	Errors := _HealthCheckErrCount
	Warnings := _HealthCheckWarnCount
	Outcome := HealthCheck_PerformAction(Map("action", "open_path", "id", "errors_today"), _THPA_Paths(),
		HealthCheck_Config(), _THPA_Effects(Calls, Map("exists", false)))
	AssertFalse(Outcome["ok"], "a missing file is not reported as opened")
	AssertTrue(Outcome.Get("missing", false), "the page is told the file does not exist yet")
	AssertEqual(Errors, _HealthCheckErrCount, "a file not created yet is no error")
	AssertEqual(Warnings, _HealthCheckWarnCount, "a file not created yet is no warning either")
}
Test("Diagnostics page: a file not created yet is said, not logged as an error (open-missing-file)",
	_THPA_OpenMissingFile)

_THPA_UnknownHomeRefuses() {
	Calls := []
	Effects := _THPA_Effects(Calls)
	Effects["identity"] := () => Map("home", "", "user", "JDoe")
	Outcome := HealthCheck_PerformAction(Map("action", "copy", "text", "C:\Users\JDoe"), _THPA_Paths(),
		HealthCheck_Config(), Effects)
	AssertFalse(Outcome["ok"])
	AssertEqual(0, Calls.Length, "nothing may leave the machine unredacted: " . _THPA_Join(Calls))
}
Test("Diagnostics page: an unknown profile folder refuses every export (page-actions)", _THPA_UnknownHomeRefuses)

_THPA_SuggestFeature() {
	global _SharedDir
	Calls := []
	AssertTrue(HealthCheck_SuggestFeature(_THPA_Effects(Calls)))
	AssertEqual(1, Calls.Length, _THPA_Join(Calls))
	GitHub := JsonParse(FileRead(_SharedDir . "\modules\updater\defaults.json", "UTF-8"))["github"]
	Prefix := "open_url:https://github.com/" . GitHub["owner"] . "/" . GitHub["repo"]
		. "/issues/new?template=feature_request.yml&"
	AssertEqual(Prefix, SubStr(Calls[1], 1, StrLen(Prefix)))
	AssertContains(Calls[1], "driver=windows")
	Assert(!InStr(Calls[1], "JDoe"), "the URL carries no account name")
}
Test("Suggest a feature: opens the feature form with the version and the system (report-bug-flow)",
	_THPA_SuggestFeature)
