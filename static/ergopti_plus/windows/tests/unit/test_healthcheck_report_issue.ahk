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
; 3. report copies the report, then opens the bug form last with that whole
;    report prefilled (cut to the URL budget), its fields redacted; it saves
;    and selects nothing, so the form keeps the focus, and a refused clipboard
;    stops it before the browser;
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

_THPA_Snapshot(Long := false) {
	Snapshot := Map("schema_version", 2, "driver", "windows", "generated_at", "2026-09-24T10:00:00Z",
		"sections", Map("versions", Map("ergopti_version", "2.1.0"), "issues", Map("recent", "private fixture text")),
		"probes", Map("github_api", Map("state", "error", "cleanup", "pending", "ms", 1)))
	if Long {
		Cohorts := []
		Loop 300
			Cohorts.Push(Map("probes", Map("github_api", Map("state", "timeout", "cleanup", "unknown", "ms", A_Index))))
		Snapshot["retired_probes"] := Cohorts
	}
	return Snapshot
}

_THPA_Approved(Long := false) {
	return HealthCheck_ShareDocument(_THPA_Snapshot(Long), HealthCheck_Config()["schema"])
}

_THPA_Perform(Action, Paths, Config, Effects) {
	Snapshot := _THPA_Snapshot(StrLen(Action.Get("text", "")) > Config["templates"]["max_url_bytes"])
	if Action["action"] == "copy" || Action["action"] == "save" || Action["action"] == "report" {
		Action := Action.Clone()
		Action["text"] := HealthCheck_ShareDocument(Snapshot, Config["schema"])["text"]
	}
	return HealthCheck_PerformAction(Action, Paths, Config, Effects, Snapshot)
}

_THPA_CopyIsRedacted() {
	Calls := []
	Outcome := _THPA_Perform(Map("action", "copy", "text", "log at c:\users\jdoe\x by JDoe"),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	AssertTrue(Outcome["ok"])
	AssertEqual("copy:" . _THPA_Approved()["text"], _THPA_Join(Calls))
	AssertFalse(InStr(Calls[1], "~\x"), "even redacted paths must be excluded")
}
Test("Diagnostics page: copy writes the redacted report (page-actions)", _THPA_CopyIsRedacted)

_THPA_RefusedCopyFails() {
	Calls := []
	Outcome := _THPA_Perform(Map("action", "copy", "text", "report"), _THPA_Paths(), HealthCheck_Config(),
		_THPA_Effects(Calls, Map("clipboard", false)))
	AssertFalse(Outcome["ok"], "a refused clipboard must be reported to the page as a failure")
}
Test("Diagnostics page: a refused clipboard is a failure (healthcheck-copy-receipt)", _THPA_RefusedCopyFails)

_THPA_SaveUnderDiagnostics() {
	Calls := []
	Name := _THPA_Approved()["name"]
	Outcome := _THPA_Perform(Map("action", "save", "text", "C:\Users\JDoe\file", "name", Name),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	Expected := _THPA_Paths()["diagnostics_dir"] . "\" . Name
	AssertTrue(Outcome["ok"])
	AssertEqual(Expected, Outcome["path"])
	AssertEqual("save:" . Expected . ":" . _THPA_Approved()["text"] . " | reveal:" . Expected, _THPA_Join(Calls))
}
Test("Diagnostics page: save writes under the diagnostics folder and selects it (page-actions)",
	_THPA_SaveUnderDiagnostics)

; The value of one query parameter of a URL, still percent-encoded.
_THPA_QueryValue(Url, Key) {
	return RegExMatch(Url, "[?&]" . Key . "=([^&]*)", &Match) ? Match[1] : ""
}

_THPA_ReportPrefillsTheReport() {
	Calls := []
	Fields := Map("version", "2.1.0", "os", "Windows 11 (C:\Users\JDoe)", "driver", "windows")
	Outcome := _THPA_Perform(Map("action", "report", "text", "report at C:\Users\JDoe\boom",
		"fields", Fields), _THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	Document := _THPA_Approved()
	AssertTrue(Outcome["ok"])
	AssertEqual(4, Calls.Length, _THPA_Join(Calls))
	AssertEqual("copy:" . Document["text"], Calls[1])
	AssertEqual("save:" . Outcome["path"] . ":" . Document["text"], Calls[2])
	AssertEqual("reveal:" . Outcome["path"], Calls[3])
	AssertTrue(InStr(Calls[4], "open_url:https://github.com/") = 1, Calls[4])
	AssertTrue(InStr(Calls[4], "template=bug_report.yml") > 0, Calls[4])
	AssertEqual(IssueLink_PercentEncode(Document["summary"]), _THPA_QueryValue(Calls[4], "diagnostics"),
		"Only the short English attachment summary reaches the editable form")
	AssertEqual(IssueLink_PercentEncode("windows"), _THPA_QueryValue(Calls[4], "os"))
	AssertTrue(InStr(Calls[4], "JDoe") = 0, "The form carries no private fields")
}
Test("Diagnostics page: report copies, then opens the bug form with the whole report (report-bug-flow)",
	_THPA_ReportPrefillsTheReport)

; The report used to be saved and selected in Explorer too: Explorer came up
; after the browser and took the focus from the form (report-focus).
_THPA_ReportSavesNothing() {
	Calls := []
	Outcome := _THPA_Perform(Map("action", "report", "text", "report", "fields",
		Map("driver", "windows")), _THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls))
	AssertTrue(Outcome["ok"])
	AssertEqual(4, Calls.Length)
	for Index, Kind in ["copy:", "save:", "reveal:", "open_url:"]
		AssertEqual(1, InStr(Calls[Index], Kind), "The browser opens last after the complete local attachment")
}
Test("Diagnostics page: report saves its attachment and opens the browser last (report-focus)", _THPA_ReportSavesNothing)

_THPA_ReportCutsALongReport() {
	Calls := []
	Long := "report"
	Loop 2000
		Long .= "line of diagnostics é`n"
	Config := HealthCheck_Config()
	Outcome := _THPA_Perform(Map("action", "report", "text", Long, "fields",
		Map("version", "2.1.0", "driver", "windows")), _THPA_Paths(), Config, _THPA_Effects(Calls))
	AssertTrue(Outcome["ok"])
	Document := _THPA_Approved(true)
	Assert(StrLen(Document["text"]) > Config["templates"]["max_url_bytes"], "The real report exceeds the URL budget")
	AssertEqual("copy:" . Document["text"], Calls[1], "The clipboard preserves the complete report")
	AssertEqual("save:" . Outcome["path"] . ":" . Document["text"], Calls[2], "The local attachment is complete")
	Url := SubStr(Calls[4], StrLen("open_url:") + 1)
	AssertTrue(StrLen(Url) < 1200 && StrLen(Url) <= Config["templates"]["max_url_bytes"], "The form URL stays short")
	AssertEqual("2.1.0", _THPA_QueryValue(Url, "version"), "The identity fields remain available")
	AssertEqual(IssueLink_PercentEncode(Document["summary"]), _THPA_QueryValue(Url, "diagnostics"))
}
Test("Diagnostics page: report keeps a long attachment out of the editable URL (report-bug-flow)",
	_THPA_ReportCutsALongReport)

_THPA_ReportStopsOnRefusedClipboard() {
	Calls := []
	Outcome := _THPA_Perform(Map("action", "report", "text", "report", "fields", Map()),
		_THPA_Paths(), HealthCheck_Config(), _THPA_Effects(Calls, Map("clipboard", false)))
	AssertFalse(Outcome["ok"])
	for Call in Calls
		AssertTrue(InStr(Call, "open_url:") = 0, "the browser must not open without the report in the clipboard")
}
Test("Diagnostics page: report stops before the browser when the clipboard refuses (report-bug-flow)",
	_THPA_ReportStopsOnRefusedClipboard)

_THPA_OpenPath() {
	Calls := []
	Outcome := _THPA_Perform(Map("action", "open_path", "id", "diagnostics_dir"), _THPA_Paths(),
		HealthCheck_Config(), _THPA_Effects(Calls))
	Dir := _THPA_Paths()["diagnostics_dir"]
	AssertTrue(Outcome["ok"])
	AssertEqual("make_dir:" . Dir . " | exists:" . Dir . " | open:" . Dir, _THPA_Join(Calls))

	Calls := []
	Outcome := _THPA_Perform(Map("action", "open_path", "id", "errors_today"), _THPA_Paths(),
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
	Outcome := _THPA_Perform(Map("action", "open_path", "id", "errors_today"), _THPA_Paths(),
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
	Outcome := _THPA_Perform(Map("action", "copy", "text", "C:\Users\JDoe"), _THPA_Paths(),
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


/** Replays the same synthetic sharing corpus as the JavaScript and Lua ports. */
_THPA_SharingVectors() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\healthcheck\share_vectors.json", "UTF-8"))
	Config := HealthCheck_Config()
	for Vector in Corpus["vectors"] {
		Snapshot := Vector["snapshot"]
		Document := HealthCheck_ShareDocument(Snapshot, Config["schema"])
		for Canary in Vector["canaries"]
			AssertFalse(InStr(Document["text"], Canary), "sharing corpus leaked " . Vector["name"])
		Readable := StrSplit(Document["text"], Chr(96) . Chr(96) . Chr(96) . "json")[1]
		for Id in ["versions", "hardware", "system", "input", "ai", "permissions", "issues"]
			AssertContains(Readable, "## " . Config["schema"]["export_strings"]["healthcheck.section." . Id])
		AssertContains(Readable, "| probes.appleevent_transport.native_status | -1744 |")
		AssertContains(Readable, "| probes.appleevent_transport.cleanup | pending |")
		AssertContains(Readable, "| retired_probes.1.probes.appleevent_transport.cleanup | unknown |")
		AssertEqual("timeout", Document["snapshot"]["probes"]["appleevent_transport"]["state"])
		AssertEqual("pending", Document["snapshot"]["probes"]["appleevent_transport"]["cleanup"])
		AssertEqual(-1744, Document["snapshot"]["probes"]["appleevent_transport"]["native_status"])
		for ActionName in ["copy", "save", "report"] {
			Calls := []
			Outcome := HealthCheck_PerformAction(Map("action", ActionName, "text", Document["text"],
				"name", "ergopti-diagnostics-PRIVATE_USER_ZEBRA.md", "fields", Map("os", "PRIVATE_ORG_SEQUOIA")),
				_THPA_Paths(), Config, _THPA_Effects(Calls), Snapshot)
			AssertTrue(Outcome["ok"], "the approved sharing sink remains usable")
			for Call in Calls
				for Canary in Vector["canaries"]
					AssertFalse(InStr(Call, Canary), "sharing sink leaked " . Vector["name"])
		}
		Calls := []
		Outcome := HealthCheck_PerformAction(Map("action", "copy", "text", Vector["canaries"][1]),
			_THPA_Paths(), Config, _THPA_Effects(Calls), Snapshot)
		AssertFalse(Outcome["ok"], "arbitrary page text cannot become a shared document")
		AssertEqual(0, Calls.Length, "the refused preview must not publish")
	}
}
Test("Diagnostics sharing: synthetic three-driver corpus excludes private fields", _THPA_SharingVectors)

_THPA_EnglishExport() {
	Config := HealthCheck_Config()
	Document := _THPA_Approved()
	AssertContains(Document["text"], Config["schema"]["export_strings"][Config["schema"]["share_policy"]["notice_key"]])
	AssertContains(Document["text"], "## " . Config["schema"]["export_strings"]["healthcheck.section.versions"])
	AssertFalse(InStr(Document["text"], "private fixture text"))
}
Test("Diagnostics export: canonical English labels independent of UI locale (english-attachment)", _THPA_EnglishExport)

_THPA_AttachmentSaveRefuses() {
	Calls := []
	Effects := _THPA_Effects(Calls)
	Effects["save"] := (*) => _THPA_RefuseAttachmentWrite()
	Outcome := _THPA_Perform(Map("action", "report", "text", "report", "fields", Map()),
		_THPA_Paths(), HealthCheck_Config(), Effects)
	AssertFalse(Outcome["ok"])
	AssertEqual(1, Calls.Length, "A refused attachment must stop before reveal and browser")
	AssertContains(Calls[1], "copy:")
}
_THPA_RefuseAttachmentWrite() {
	throw Error("inert attachment write refusal")
}
Test("Diagnostics export: write refusal prevents issue form (english-attachment)", _THPA_AttachmentSaveRefuses)

_THPA_PageObservations() {
	global _HC_Session, _HC_ResetDone
	Config := HealthCheck_Config(), Rows := Map()
	for Spec in Config["schema"]["diagnostic_checks"]["items"]
		Rows[Spec["id"]] := Spec.Has("reason") ? Map("state", "not_run", "scope", Spec["scope"], "reason", Spec["reason"])
			: Map("state", "ok", "scope", Spec["scope"], "ms", 3)
	Observed := HealthCheck_PageChecks(Rows, Config["schema"])
	Assert(Observed is Map)
	Snapshot := _THPA_Snapshot(false), Snapshot["export_revision"] := 1
	Action := Map("page_check_observations", Observed, "generated_at", Snapshot["generated_at"], "snapshot_revision", 2)
	AssertFalse(HealthCheck_CapturePageChecks(Snapshot, Action))
	AssertFalse(Snapshot.Has("page_check_observations"))
	Action["snapshot_revision"] := 1
	AssertTrue(HealthCheck_CapturePageChecks(Snapshot, Action))
	Doc := HealthCheck_ShareDocument(Snapshot, Config["schema"])
	AssertContains(Doc["text"], "installed_page_reported (unqualified)")
	AssertContains(Doc["text"], "page_check_observations.results.redaction.ms")
	AssertEqual("not_run", Doc["snapshot"]["page_check_observations"]["results"]["driver_suites"]["state"])
	SavedSession := _HC_Session, SavedReset := _HC_ResetDone
	try {
		_HC_ResetDone := true ; The actual sender refuses before any WebView operation.
		Current := _THPA_Snapshot(false), Current["export_revision"] := 1
		_HC_Session := Map("snapshot", Current)
		Action["action"] := "export_snapshot", Action["export_sequence"] := 1
		Action["snapshot_revision"] := 2
		_HC_PerformPageAction(0, Action, Config)
		AssertFalse(Current.Has("page_check_observations"), "The real host rejects a stale generation")
		Action["snapshot_revision"] := 1
		_HC_PerformPageAction(0, Action, Config)
		AssertTrue(Current.Has("page_check_observations"), "The real host retains current observations before formatting")
		AssertEqual(3, Current["page_check_observations"]["results"]["redaction"]["ms"])
	} finally {
		_HC_Session := SavedSession
		_HC_ResetDone := SavedReset
	}
	Rows["redaction"]["text"] := "PRIVATE_TEXT"
	AssertFalse(HealthCheck_PageChecks(Rows, Config["schema"]))
}
Test("Diagnostics export: retained page observations remain unqualified and current", _THPA_PageObservations)
