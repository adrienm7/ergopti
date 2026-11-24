; diagnostics/ui/field_check/field_report.ahk

; ==============================================================================
; MODULE: In-App Field Report (Windows)
; DESCRIPTION:
; Débogage's « Lancer le field report (tous les tests) »: a click hands the
; driver's own field run session its field check steps in-process
; (diagnostics/engine/field_run/field_run.ahk SubmitInApp; the session is started on
; demand on the installed folder when no clone opened one), so the run is the
; field report's own, with no clone and no collector: the same steps,
; verdicts and result files. When the run ends, one window shows the report
; with a « Copy report » button and one evidence line goes to the log.
;
; FEATURES & RATIONALE:
; 1. The report reads as the macOS and Linux one
;    (_shared/diagnostics/engine/field_check/field_report.lua): the verdict
;    counts, each step's verdict, the steps not run here with their reason,
;    the Tests rows a person runs separately, and the folder of the result
;    files to attach to an issue. Windows has no field_todo_coverage.json yet,
;    so a step names no field point.
; 2. Nothing is pushed or committed: the results stay in the session folder.
; 3. One run at a time: a click while it runs only says so.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Logger tag of every line the report writes.
global FIELD_REPORT_TAG := "FieldReport"

; Locale key of the row and of the report's title (the row's own label).
global FIELD_REPORT_TITLE := "menu.debug." . MenuCommand.FIELD_REPORT

; True while the in-app run goes on.
global _FieldReportBusy := false

; The verdicts of the shared protocol, in the order the counts read.
global FIELD_REPORT_VERDICTS := ["pass", "fail", "timeout", "skip", "needs_person", "needs_typing"]

; The Windows Tests rows and the field run check each runs alone, as the Debug
; menu wires them (_MI_BuildDebuggingMenu); a probe the field run has no step
; for maps to "". A row whose check no step of the run takes is run separately.
FieldReport_RowChecks() {
	return Map(MenuCommand.FIELD_CHECK_NETWORK, "network", MenuCommand.COMPOSER_CHECK, "composer",
		MenuCommand.SEND_PROBE, "", MenuCommand.HOOK_PROBE, "")
}





; ===========================
; ===========================
; ======= 2/ The text =======
; ===========================
; ===========================

; The mark of a verdict; an undeclared one is a defect of the caller.
_FieldReport_Mark(Verdict) {
	static Marks := Map("pass", "[OK]", "fail", "[X]", "timeout", "[T]", "skip", "[-]",
		"needs_person", "[?]", "needs_typing", "[K]")
	if !Marks.Has(Verdict)
		throw ValueError("Field report: undeclared verdict.", -1, Verdict)
	return Marks[Verdict]
}

/**
 * Builds the summary of one in-app run.
 * @param {Array} Results - The step results the observer received, in order.
 * @param {Array} NotRun - Maps "step", "reason" the session left out.
 * @param {Array} Steps - The steps the run took.
 * @param {Map} Done - "request_id", "interrupted".
 * @param {String} Dir - The results folder.
 * @returns {Map}
 */
FieldReport_Summary(Results, NotRun, Steps, Done, Dir) {
	Counts := Map(), Passed := !Done["interrupted"]
	for Result in Results {
		Counts[Result["verdict"]] := Counts.Get(Result["verdict"], 0) + 1
		if Result["verdict"] != "pass" && Result["verdict"] != "skip"
			Passed := false
	}
	Taken := Map()
	for Step in Steps
		Taken[Step["check"]] := Step["id"]
	Rows := Map(), Separate := []
	for Row, Check in FieldReport_RowChecks() {
		if Check != "" && Taken.Has(Check)
			Rows[Taken[Check]] := Row
		else
			Separate.Push(Row)
	}
	return Map("passed", Passed, "interrupted", Done["interrupted"], "counts", Counts, "results", Results,
		"not_run", NotRun, "separate", Separate, "rows", Rows, "dir", Dir, "request_id", Done["request_id"])
}

/**
 * The one evidence line, in the macOS and Linux grammar:
 * check=field_report verdict=fail request=app-… pass=2 fail=1 not_run=1 field_network=pass …
 * @param {Map} Summary - From FieldReport_Summary.
 * @returns {String}
 */
FieldReport_LogLine(Summary) {
	global FIELD_REPORT_VERDICTS
	Parts := ""
	for Verdict in FIELD_REPORT_VERDICTS
		if Summary["counts"].Has(Verdict)
			Parts .= " " . Verdict . "=" . Summary["counts"][Verdict]
	Parts .= " not_run=" . Summary["not_run"].Length
	for Result in Summary["results"]
		Parts .= " " . Result["step"] . "=" . Result["verdict"]
	Verdict := Summary["interrupted"] ? "interrupted" : Summary["passed"] ? "pass" : "fail"
	return "check=field_report verdict=" . Verdict . " request=" . Summary["request_id"] . Parts
}

/**
 * The window and clipboard text: the verdict and the counts, each step with its
 * own report beneath it, the steps not run with their reason, the rows to run
 * separately and the folder. A step a Tests row also runs alone reads as that
 * row's sentences; another step reads as its closed codes.
 * @param {Map} Summary - From FieldReport_Summary.
 * @param {Func} TranslateFn - Locale key -> text.
 * @returns {String}
 */
FieldReport_Text(Summary, TranslateFn) {
	global FIELD_REPORT_VERDICTS
	Indent := "    "
	Key := Summary["interrupted"] ? "field_check.all.interrupted"
		: Summary["passed"] ? "field_check.all.verdict_pass" : "field_check.all.verdict_fail"
	Counts := ""
	for Verdict in FIELD_REPORT_VERDICTS
		if Summary["counts"].Has(Verdict)
			Counts .= (Counts == "" ? "" : " · ") . _FieldReport_Mark(Verdict) . " " . Summary["counts"][Verdict]
	if Summary["not_run"].Length > 0
		Counts .= (Counts == "" ? "" : " · ") . "[-] " . Summary["not_run"].Length
	Text := TranslateFn.Call(Key) . "`n" . Counts
	for Result in Summary["results"] {
		Row := Summary["rows"].Get(Result["step"], "")
		Heading := Row == "" ? Result["step"] : TranslateFn.Call("menu.debug." . Row) . " — " . Result["step"]
		Text .= "`n`n" . _FieldReport_Mark(Result["verdict"]) . " " . Heading
		Report := Result["report"]
		if (Row != "") && (Report is Map) && Report.Has("steps") {
			; The row's own text, without its verdict line and the blank line after it
			Lines := StrSplit(ComposerCheck_Text(Report, TranslateFn), "`n")
			loop Lines.Length - 2
				Text .= "`n" . Indent . Lines[A_Index + 2]
		} else if Result["codes"].Length > 0 {
			Joined := ""
			for Code in Result["codes"]
				Joined .= (Joined == "" ? "" : ", ") . Code
			Text .= "`n" . Indent . Joined
		}
	}
	if Summary["not_run"].Length > 0 {
		Text .= "`n`n" . TranslateFn.Call("field_check.all.not_run_header")
		for Item in Summary["not_run"]
			Text .= "`n" . LabelValue("[-] " . Item["step"], TranslateFn.Call("field_check.all.reason." . Item["reason"]),
				TranslateFn)
	}
	if Summary["separate"].Length > 0 {
		Text .= "`n`n" . TranslateFn.Call("field_check.all.separate_header")
		for Row in Summary["separate"]
			Text .= "`n[-] " . TranslateFn.Call("menu.debug." . Row)
	}
	Text .= "`n`n" . StrReplace(TranslateFn.Call("field_check.all.saved_in"), "{1}", Summary["dir"])
	Text .= "`n" . TranslateFn.Call("field_check.all.attach")
	return Text
}





; ==========================
; ==========================
; ======= 3/ The run =======
; ==========================
; ==========================

; The real collaborators: the session, the notices and the window.
_FieldReport_DefaultDeps() {
	global FIELD_REPORT_TITLE
	return Map(
		"session", FieldRun_StartInApp,
		"notify", (Text) => NotifierSend(Text, Map("title", t(FIELD_REPORT_TITLE))),
		"busy", (Text) => Ui_MsgBox(Text, t(FIELD_REPORT_TITLE), "Icon!"),
		"show", 0)
}

/**
 * Debug menu: « Lancer le field report (tous les tests) ». Hands the field run
 * session its steps and shows the report when the run ends.
 * @param {Map} Deps - Collaborators (tests) over the real ones: "session" (() ->
 *   session), "notify" (Text), "busy" (Text), "show" (Title, Text).
 * @returns {Boolean} False when nothing started.
 */
FieldReport_Command(Deps := 0, *) {
	global _FieldReportBusy, FIELD_REPORT_TAG
	Real := _FieldReport_DefaultDeps()
	if (Deps is Map)
		for Key, Value in Deps
			Real[Key] := Value
	if _FieldReportBusy {
		LoggerWarn(FIELD_REPORT_TAG, "The field report refused: it is still running.")
		Real["busy"].Call(t("field_check.busy"))
		return false
	}
	try Session := Real["session"].Call()
	catch as Err {
		LoggerError(FIELD_REPORT_TAG, "The field report cannot run: no field run session ({1}).", Err.Message)
		Real["busy"].Call(t("field_check.all.unavailable"))
		return false
	}
	State := {Results: [], Run: 0}
	Observer := Map(
		"step_recorded", (Index, Step, Result) => State.Results.Push(Result),
		"finished", _FieldReport_Finish.Bind(Real, State))
	_FieldReport_SetBusy(true)
	LoggerStart(FIELD_REPORT_TAG, "In-app field report started…")
	State.Run := Session.SubmitInApp(Observer, &Reason)
	if !IsObject(State.Run) {
		_FieldReport_SetBusy(false)
		LoggerWarn(FIELD_REPORT_TAG, "The field report refused by the field run session: {1}.", Reason)
		Real["busy"].Call(t(Reason == "busy" ? "field_check.busy" : "field_check.all.unavailable"))
		return false
	}
	Real["notify"].Call(StrReplace(t("field_check.all.started"), "{1}", State.Run["steps"].Length))
	return true
}

; Logs the evidence line and shows the report once the run ended.
_FieldReport_Finish(Deps, State, Done, Dir) {
	global FIELD_REPORT_TAG, FIELD_REPORT_TITLE
	_FieldReport_SetBusy(false)
	Summary := FieldReport_Summary(State.Results, State.Run["not_run"], State.Run["steps"], Done, Dir)
	LoggerEvidence(FIELD_REPORT_TAG, "Field report result: {1}", FieldReport_LogLine(Summary))
	LoggerSuccess(FIELD_REPORT_TAG, "In-app field report finished: {1}.",
		Summary["interrupted"] ? "interrupted" : Summary["passed"] ? "pass" : "fail")
	ComposerCheck_ShowText(FieldReport_Text(Summary, t), Deps["show"], FIELD_REPORT_TITLE)
}

; Sets the busy flag of the one run.
_FieldReport_SetBusy(Value) {
	global _FieldReportBusy
	_FieldReportBusy := Value
}
