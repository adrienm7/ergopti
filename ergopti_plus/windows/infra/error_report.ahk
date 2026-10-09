; infra/error_report.ahk

; ==============================================================================
; MODULE: Error Report Text
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/error_report.lua: what the error window
; (_shared/ui/error_dialog/) shows, copies and sends to GitHub for one logged
; error — the Markdown report and the prefilled fields of the bug form. Both
; ports replay
; _shared/tests/corpus/diagnostics/error_report_vectors.json.
;
; FEATURES & RATIONALE:
; 1. Built from infra/issue_report.ahk: the same identity table and dump rules
;    as any other bug report. The report itself fills the form's report field
;    (HealthCheck_PerformAction), so no field here repeats it.
; 2. The issue's title is the error's module and the first line of its
;    message: what a maintainer triages by.
; 3. The recent warnings and errors of today's errors file travel with the
;    error: a failure is rarely the first thing that went wrong.
; 4. Nothing here redacts: the host redacts the finished texts with
;    Redact_Apply before showing them, and again before anything leaves the
;    machine.
; ==============================================================================

#Requires AutoHotkey v2.0

; The kinds of error the window reports: an ERROR logged by a running driver,
; and the notice of a crash found at the next launch
global ERROR_REPORT_KINDS := Map("error", true, "crash", true)





; ===============================
; ===============================
; ======= 1/ The Composer =======
; ===============================
; ===============================

; Checks the error record.
; @param Err {Map} { kind, module, message, time, recent }
; @throws {ValueError} When a field is missing or of the wrong type.
_ErrorReport_Check(Err) {
	global ERROR_REPORT_KINDS
	if !(Err is Map)
		throw ValueError("error_report: the error must be a Map.")
	if !ERROR_REPORT_KINDS.Has(Err.Get("kind", ""))
		throw ValueError("error_report: unknown kind " . String(Err.Get("kind", "")) . ".")
	for Field in ["module", "message", "time"]
		if !(Err.Get(Field, 0) is String)
			throw ValueError("error_report: " . Field . " must be a string.")
	if !(Err.Get("recent", 0) is Array)
		throw ValueError("error_report: recent must be an Array.")
}

; Builds the report of one error.
; @param Err {Map} { kind: "error"|"crash", module, message, time, recent: Array }
; @param Identity {Map} { version, commit, os, driver, generated_utc, warn_count, err_count }
; @returns {Map} { text, fields: { title, version, os, driver } }
ErrorReport_Compose(Err, Identity) {
	_ErrorReport_Check(Err)
	if !(Identity is Map)
		throw ValueError("error_report: the identity must be a Map.")
	Body := Map("error", Map("kind", Err["kind"], "module", Err["module"], "message", Err["message"],
		"time", Err["time"]))
	if (Err["recent"].Length > 0)
		Body["recent_issues"] := Err["recent"]

	FirstLine := StrSplit(StrReplace(Err["message"], "`r", "`n"), "`n")[1]

	return Map(
		"text", IssueReport_Markdown(Identity, IssueReport_Dump(Body)),
		"fields", Map(
			"title",   Err["module"] . ": " . FirstLine,
			"version", Identity["version"],
			"os",      Identity["os"],
			"driver",  Identity["driver"]))
}
