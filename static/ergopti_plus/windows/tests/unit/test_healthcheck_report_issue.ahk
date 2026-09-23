; tests/unit/test_healthcheck_report_issue.ahk

; ==============================================================================
; MODULE: Report A Bug / Suggest A Feature (Windows)
; DESCRIPTION:
; Debug > Report a bug copies the full diagnostics to the clipboard, saves them
; as a Markdown file beside today's errors file, selects it in Explorer, then
; opens the GitHub bug form with a bounded prefill; Suggest a feature opens the
; feature form. Everything that leaves the machine is redacted: the profile
; folder and the account name must reach neither the clipboard, the file nor
; the URL (report-bug-flow).
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Recording side effects =======
; =========================================
; =========================================

; The fixture's account: its folder appears in the snapshot's config dir.
global _THRI_HOME := "C:\Users\JDoe"

; Builds side effects that record every call instead of acting.
_THRI_Effects(Calls) {
	for Name in ["copy", "save", "reveal", "open_url", "notify"]
		Calls[Name] := []
	return Map(
		"identity", () => Map("home", _THRI_HOME, "user", "JDoe"),
		"now_utc",  () => "20260921141320",
		"copy",     (Text) => (Calls["copy"].Push(Text), true),
		"save",     (Dir, Name, Text) => (Calls["save"].Push(Map("dir", Dir, "name", Name, "text", Text)), Dir . "\" . Name),
		"reveal",   (Path) => (Calls["reveal"].Push(Path), true),
		"open_url", (Url) => (Calls["open_url"].Push(Url), true),
		"notify",   (Title, Body, Kind) => (Calls["notify"].Push(Map("title", Title, "kind", Kind)), true))
}

; The repository the URLs must point at, read from its single source.
_THRI_UrlPrefix(Template) {
	global _SharedDir
	GitHub := JsonParse(FileRead(_SharedDir . "\modules\updater\defaults.json", "UTF-8"))["github"]
	return "https://github.com/" . GitHub["owner"] . "/" . GitHub["repo"]
		. "/issues/new?template=" . Template . "&version="
}

; Runs Body with a config dir under the fixture account and a known errors file.
_THRI_WithFixture(Body) {
	global _ConfigDir, LOGGER_ERRORS_LOG_PATH
	SavedConfig := IsSet(_ConfigDir) ? _ConfigDir : ""
	SavedErrors := LOGGER_ERRORS_LOG_PATH
	try {
		_ConfigDir := _THRI_HOME . "\Documents\ergopti_plus"
		LOGGER_ERRORS_LOG_PATH := A_Temp . "\ergopti_report_logs\ErgoptiPlus_errors_2026-09-21.log"
		Body.Call()
	} finally {
		_ConfigDir := SavedConfig
		LOGGER_ERRORS_LOG_PATH := SavedErrors
	}
}





; ===================================
; ===================================
; ======= 2/ The report flows =======
; ===================================
; ===================================

_THRI_ReportBug() {
	_THRI_WithFixture(_THRI_ReportBugBody)
}

_THRI_ReportBugBody() {
	Calls := Map()
	AssertTrue(HealthCheck_ReportBug(_THRI_Effects(Calls)), "the report must succeed")
	AssertEqual(1, Calls["copy"].Length, "the diagnostics reach the clipboard once")
	Markdown := Calls["copy"][1]
	AssertEqual("# ErgoptiPlus diagnostics`n", SubStr(Markdown, 1, 26), "a Markdown report")
	AssertContains(Markdown, "config_dir: ~\Documents\ergopti_plus", "the profile folder becomes ~")
	Assert(!InStr(Markdown, "JDoe"), "the account name never leaves the machine")

	AssertEqual(1, Calls["save"].Length)
	AssertEqual(A_Temp . "\ergopti_report_logs\diagnostics", Calls["save"][1]["dir"])
	Assert(RegExMatch(Calls["save"][1]["name"], "^ergopti-diagnostics-windows-[\w.\-]+-20260921T141320Z\.md$"),
		"the saved name carries the driver, the version and the UTC time: " . Calls["save"][1]["name"])
	AssertEqual(Markdown, Calls["save"][1]["text"], "the saved file is what was copied")
	AssertEqual(Calls["save"][1]["dir"] . "\" . Calls["save"][1]["name"], Calls["reveal"][1])

	AssertEqual(1, Calls["open_url"].Length)
	Url := Calls["open_url"][1]
	Prefix := _THRI_UrlPrefix("bug_report.yml")
	AssertEqual(Prefix, SubStr(Url, 1, StrLen(Prefix)))
	AssertContains(Url, "&driver=windows&diagnostics=Version%3A%20")
	Assert(StrLen(Url) <= 7000, "the prefill stays within the URL budget")
	Assert(!InStr(Url, "JDoe"), "the URL carries no account name")
	AssertEqual("info", Calls["notify"][1]["kind"])
}

Test("Report a bug: copies, saves, reveals, then opens the bug form (report-bug-flow)", _THRI_ReportBug)


_THRI_RefusedClipboard() {
	_THRI_WithFixture(_THRI_RefusedClipboardBody)
}

_THRI_RefusedClipboardBody() {
	Calls := Map()
	Effects := _THRI_Effects(Calls)
	Effects["copy"] := (Text) => false
	AssertFalse(HealthCheck_ReportBug(Effects), "a refused clipboard fails the report")
	AssertEqual(0, Calls["save"].Length, "nothing is saved")
	AssertEqual(0, Calls["open_url"].Length, "the form never opens without its report")
	AssertEqual("error", Calls["notify"][1]["kind"])
}

Test("Report a bug: stops before the browser when the clipboard refuses (report-bug-flow)", _THRI_RefusedClipboard)


_THRI_UnknownHome() {
	_THRI_WithFixture(_THRI_UnknownHomeBody)
}

; Nothing could remove the profile folder, so every path under it would leak.
_THRI_UnknownHomeBody() {
	Calls := Map()
	Effects := _THRI_Effects(Calls)
	Effects["identity"] := () => Map("home", "", "user", "JDoe")
	AssertFalse(HealthCheck_ReportBug(Effects), "an unknown profile folder fails the report")
	AssertEqual(0, Calls["copy"].Length, "nothing unredacted reaches the clipboard")
	AssertEqual(0, Calls["save"].Length, "nothing is saved")
	AssertEqual(0, Calls["open_url"].Length, "the form never opens")
	AssertEqual("error", Calls["notify"][1]["kind"])
}

Test("Report a bug: refuses to report when the profile folder is unknown (report-bug-flow)", _THRI_UnknownHome)


_THRI_SuggestFeature() {
	_THRI_WithFixture(_THRI_SuggestFeatureBody)
}

_THRI_SuggestFeatureBody() {
	Calls := Map()
	AssertTrue(HealthCheck_SuggestFeature(_THRI_Effects(Calls)))
	AssertEqual(0, Calls["copy"].Length, "a feature request copies nothing")
	Prefix := _THRI_UrlPrefix("feature_request.yml")
	AssertEqual(Prefix, SubStr(Calls["open_url"][1], 1, StrLen(Prefix)))
	AssertContains(Calls["open_url"][1], "&driver=windows")
}

Test("Suggest a feature: opens the feature form with the version and the system (report-bug-flow)", _THRI_SuggestFeature)
