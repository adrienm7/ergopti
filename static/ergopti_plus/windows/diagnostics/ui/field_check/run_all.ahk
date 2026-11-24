; diagnostics/ui/field_check/run_all.ahk

; ==============================================================================
; MODULE: Test Everything (Windows)
; DESCRIPTION:
; The Debug menu's « Test everything »: a click runs, one after the other, every
; check of the Windows plan (_shared/diagnostics/data/field_check_all.json) and
; shows one combined report with a « Copy report » button: each check's verdict
; and its field run step, then the Tests rows to run separately. This is the
; interim Windows run: macOS and Linux hand their own field run session the
; steps in-app (diagnostics/engine/field_run/field_run.lua Session:submit_in_app),
; and Windows does the same once field_run.ahk can (TODO.md, « Lancer le field
; report »).
;
; FEATURES & RATIONALE:
; 1. Fail fast without stopping: a check that cannot start, raises or misses
;    its deadline is recorded as failed with a closed code, and the sequence
;    goes on; each deadline is its field run step's (diagnostics/data/field_run_steps.json).
; 2. Settle once: a check settles by its report or by its deadline, whichever
;    comes first; a late report is dropped. The run settles exactly once.
; 3. One check at a time, each started from a fresh timer turn, never from the
;    previous check's callback.
; 4. The checks are the tray checks themselves (NetworkCheck_Run,
;    ComposerCheck_Run) and the boot cost the developer field run measures;
;    the window is the one-click checks' own (ComposerCheck_ShowText).
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Logger tag of every line the run writes.
global FIELD_CHECK_ALL_TAG := "FieldCheckAll"

; Locale key of the row and of the combined report's title (the row's own label).
global FIELD_CHECK_ALL_TITLE := "menu.debug." . MenuCommand.FIELD_REPORT

; True while the sequence runs.
global _FieldCheckAllBusy := false





; ===============================
; ===============================
; ======= 2/ The run plan =======
; ===============================
; ===============================

/**
 * Builds this driver's run plan; any inconsistency throws, so a broken
 * declaration is found at the first click and never runs half a plan.
 * @param {Map} Declaration - Decoded _shared/diagnostics/data/field_check_all.json.
 * @param {Map} StepsById - Field run step id -> step Map (FieldRun_LoadSteps "by_id").
 * @returns {Map} "run" (Array of Map step, check, row, deadline_seconds) and
 *   "separate" (Array of Map row, step).
 */
FieldCheckAll_Plan(Declaration, StepsById) {
	if !(Declaration is Map) || !(Declaration.Get("platforms", 0) is Map)
		throw Error("Test everything: the declaration has no platforms.")
	; The manifest's platform token of this driver
	Own := Declaration["platforms"].Get("ahk", 0)
	if !(Own is Map) || !(Own.Get("run", 0) is Array) || !(Own.Get("separate", 0) is Array)
		throw Error("Test everything: the declaration has no Windows plan.")
	Plan := Map("run", [], "separate", [])
	for Entry in Own["run"] {
		Id := Entry.Get("step", "")
		if !StepsById.Has(Id)
			throw Error("Test everything: unknown field run step " . Id . ".")
		Step := StepsById[Id]
		if Step.Get("kind", "") != "field_check" || Step.Get("check", "") == ""
			throw Error("Test everything: step " . Id . " is not a field check.")
		Plan["run"].Push(Map("step", Id, "check", Step["check"], "row", Entry.Get("row", ""),
			"deadline_seconds", Step["deadline_seconds"]))
	}
	for Entry in Own["separate"] {
		Row := Entry.Get("row", "")
		if Row == ""
			throw Error("Test everything: a separate entry has no row.")
		Step := Entry.Get("step", "")
		if Step != "" && !StepsById.Has(Step)
			throw Error("Test everything: unknown field run step " . Step . ".")
		Plan["separate"].Push(Map("row", Row, "step", Step))
	}
	return Plan
}





; ==========================
; ==========================
; ======= 3/ The run =======
; ==========================
; ==========================

/**
 * Runs every check of the plan in order and delivers the summary once.
 * @param {Map} Plan - From FieldCheckAll_Plan.
 * @param {Map} Deps - "start" (Entry, OnResult) -> true when the check started,
 *   OnResult(Report) once; "after" (Ms, Fn) -> a timer handle; "cancel" (Handle).
 * @param {Func} OnDone - OnDone(Summary): Map "passed", "entries" (Array of Map
 *   step, check, row, verdict, code, report) and "separate".
 */
FieldCheckAll_Run(Plan, Deps, OnDone) {
	for Name in ["start", "after", "cancel"]
		if !Deps.Has(Name) || !HasMethod(Deps[Name], "Call")
			throw ValueError("Test everything: the collaborators lack " . Name . ".")
	State := {Plan: Plan, Deps: Deps, OnDone: OnDone, Index: 0, Entries: []}
	Deps["after"].Call(0, _FieldCheckAll_Next.Bind(State))
}

; Starts the next check, or settles the run after the last one.
_FieldCheckAll_Next(State) {
	State.Index += 1
	if State.Index > State.Plan["run"].Length {
		Passed := true
		for Entry in State.Entries
			if Entry["verdict"] == "fail"
				Passed := false
		State.OnDone.Call(Map("passed", Passed, "entries", State.Entries, "separate", State.Plan["separate"]))
		return
	}
	Planned := State.Plan["run"][State.Index]
	Entry := Map("step", Planned["step"], "check", Planned["check"], "row", Planned["row"],
		"verdict", "", "code", "", "report", 0)
	State.Entries.Push(Entry)
	Check := {State: State, Entry: Entry, Settled: false, Timer: 0}
	Check.Timer := State.Deps["after"].Call(Planned["deadline_seconds"] * 1000, _FieldCheckAll_Deadline.Bind(Check))
	try Started := State.Deps["start"].Call(Planned, _FieldCheckAll_OnReport.Bind(Check))
	catch as Err {
		LoggerError(FIELD_CHECK_ALL_TAG, "Test everything: the {1} check raised: {2}", Planned["check"], Err.Message)
		_FieldCheckAll_Settle(Check, "fail", "raised", 0)
		return
	}
	if Started != true
		_FieldCheckAll_Settle(Check, "fail", "refused", 0)
}

; A check's report, unless its deadline came first.
_FieldCheckAll_OnReport(Check, Report) {
	if !(Report is Map) || !(Report.Get("steps", 0) is Array)
		return _FieldCheckAll_Settle(Check, "fail", "raised", 0)
	_FieldCheckAll_Settle(Check, ComposerCheck_Passed(Report) ? "pass" : "fail", "", Report)
}

; A check that missed its deadline.
_FieldCheckAll_Deadline(Check) {
	Check.Timer := 0
	if Check.Settled
		return
	LoggerWarn(FIELD_CHECK_ALL_TAG, "Test everything: the {1} check missed its deadline.", Check.Entry["check"])
	_FieldCheckAll_Settle(Check, "fail", "timeout", 0)
}

; Settles one check once and starts the next from a fresh timer turn.
_FieldCheckAll_Settle(Check, Verdict, Code, Report) {
	if Check.Settled
		return
	Check.Settled := true
	if Check.Timer {
		try Check.State.Deps["cancel"].Call(Check.Timer)
		Check.Timer := 0
	}
	Check.Entry["verdict"] := Verdict
	Check.Entry["code"] := Code
	Check.Entry["report"] := Report
	Check.State.Deps["after"].Call(0, _FieldCheckAll_Next.Bind(Check.State))
}





; =============================
; =============================
; ======= 4/ The report =======
; =============================
; =============================

/**
 * The one evidence line, in the grammar macOS and Linux write:
 * check=all verdict=fail checks=3 field_network=pass field_composer=fail:timeout separate=2
 * @param {Map} Summary - From FieldCheckAll_Run.
 * @returns {String}
 */
FieldCheckAll_LogLine(Summary) {
	Parts := ""
	for Entry in Summary["entries"]
		Parts .= " " . Entry["step"] . "=" . Entry["verdict"] . (Entry["code"] != "" ? ":" . Entry["code"] : "")
	return "check=all verdict=" . (Summary["passed"] ? "pass" : "fail") . " checks=" . Summary["entries"].Length
		. Parts . " separate=" . Summary["separate"].Length
}

; The heading of a check or row: its menu label, or its field run step id when
; no Tests row starts it alone, then the step id.
_FieldCheckAll_Heading(TranslateFn, Row, Step) {
	if Row == ""
		return Step
	Name := TranslateFn.Call("menu.debug." . Row)
	return Step != "" ? Name . " — " . Step : Name
}

/**
 * The window and clipboard text: the verdict, then one line per check with its
 * own steps beneath it, then the rows to run separately. A check a Tests row
 * starts alone has a localized sentence per step; a developer field run check
 * has none, so its steps read as their closed codes, as in its evidence line.
 * @param {Map} Summary - From FieldCheckAll_Run.
 * @param {Func} TranslateFn - Locale key -> text.
 * @returns {String}
 */
FieldCheckAll_Text(Summary, TranslateFn) {
	Marks := Map("pass", "[OK]", "fail", "[X]", "info", "[i]", "skip", "[-]")
	Codes := Map("timeout", "field_check.all.timeout", "refused", "field_check.all.refused",
		"raised", "field_check.all.raised")
	Indent := "    "
	Text := TranslateFn.Call(Summary["passed"] ? "field_check.all.verdict_pass" : "field_check.all.verdict_fail")
	for Entry in Summary["entries"] {
		Text .= "`n`n" . Marks[Entry["verdict"]] . " " . _FieldCheckAll_Heading(TranslateFn, Entry["row"], Entry["step"])
		if !(Entry["report"] is Map) {
			if Codes.Has(Entry["code"])
				Text .= "`n" . Indent . TranslateFn.Call(Codes[Entry["code"]])
			continue
		}
		if Entry["row"] != "" {
			; The report's own text, without its verdict line and the blank line after it
			Lines := StrSplit(ComposerCheck_Text(Entry["report"], TranslateFn), "`n")
			loop Lines.Length - 2
				Text .= "`n" . Indent . Lines[A_Index + 2]
			continue
		}
		for Step in Entry["report"]["steps"] {
			Line := Marks.Get(Step["state"], "[-]") . " " . Step["id"]
			if Step["value"] != ""
				Line := LabelValue(Line, Step["value"], TranslateFn)
			Text .= "`n" . Indent . Line
		}
	}
	if Summary["separate"].Length > 0 {
		Text .= "`n`n" . TranslateFn.Call("field_check.all.separate_header")
		for Entry in Summary["separate"]
			Text .= "`n" . Marks["skip"] . " " . _FieldCheckAll_Heading(TranslateFn, Entry["row"], Entry["step"])
	}
	return Text
}





; ==================================
; ==================================
; ======= 5/ The real checks =======
; ==================================
; ==================================

; The boot that started this driver against [budgets] boot_total_ms, as a report
; in the field check grammar (the developer field run's boot cost step).
_FieldCheckAll_BootCost(OnResult) {
	Report := ComposerCheck_NewReport()
	Total := Round(BootProfile_CompletedBootMs())
	if Total < 0 {
		ComposerCheck_Step(Report, "boot_total_ms", "fail", "not_complete")
	} else {
		Budget := TimingsGet("budgets", "boot_total_ms")
		ComposerCheck_Step(Report, "boot_total_ms", Total <= Budget ? "pass" : "fail", Total)
		ComposerCheck_Step(Report, "boot_budget_ms", "info", Budget)
	}
	OnResult.Call(Report)
	return true
}

; Starts one planned check; a check this driver cannot run is a broken plan.
_FieldCheckAll_Start(Planned, OnResult) {
	switch Planned["check"], true {
		case "network": return NetworkCheck_Run(OnResult)
		case "composer": return ComposerCheck_Run(OnResult)
		case "boot_cost": return _FieldCheckAll_BootCost(OnResult)
	}
	throw ValueError("Test everything: no Windows runner for the " . Planned["check"] . " check.")
}

; The real collaborators: the tray checks, one-shot timers, the start notice
; and the busy refusal.
_FieldCheckAll_DefaultDeps() {
	global FIELD_CHECK_ALL_TITLE
	return Map(
		"start", _FieldCheckAll_Start,
		"after", (Ms, Fn) => (SetTimer(Fn, -Max(1, Ms)), Fn),
		"cancel", (Handle) => SetTimer(Handle, 0),
		"notify", (Text) => NotifierSend(Text, Map("title", t(FIELD_CHECK_ALL_TITLE))),
		"busy", (Text) => Ui_MsgBox(Text, t(FIELD_CHECK_ALL_TITLE), "Icon!"))
}

; This driver's plan from the shared declaration and its field run steps.
_FieldCheckAll_LoadPlan() {
	global _SharedDir, _DriverDir
	Text := FSReadUtf8Exact(_SharedDir . "\diagnostics\data\field_check_all.json")
	if !(Text is String)
		throw Error("Test everything: the plan could not be read.")
	Spec := FieldRun_LoadProtocol(_SharedDir . "\diagnostics\data\field_run_protocol.json")
	Steps := FieldRun_LoadSteps(_DriverDir . "\diagnostics\data\field_run_steps.json", Spec, FieldRun_Runners())
	return FieldCheckAll_Plan(JsonParse(Text), Steps["by_id"])
}

/**
 * Debug menu: « Test everything ». Runs the plan and shows the combined report.
 * @param {Map} Deps - Collaborators (tests) over the real ones: "start", "after",
 *   "cancel", "notify" (Text), "busy" (Text), "plan" (a built plan) and "show"
 *   (Title, Text).
 * @returns {Boolean} False when a run is already pending.
 */
FieldCheckAll_Command(Deps := 0, *) {
	global _FieldCheckAllBusy, FIELD_CHECK_ALL_TAG, FIELD_CHECK_ALL_TITLE
	Real := _FieldCheckAll_DefaultDeps()
	if (Deps is Map)
		for Key, Value in Deps
			Real[Key] := Value
	if _FieldCheckAllBusy {
		LoggerWarn(FIELD_CHECK_ALL_TAG, "Test everything refused: it is still running.")
		Real["busy"].Call(t("field_check.busy"))
		return false
	}
	Plan := Real.Has("plan") ? Real["plan"] : _FieldCheckAll_LoadPlan()
	_FieldCheckAll_Busy(true)
	LoggerStart(FIELD_CHECK_ALL_TAG, "Test everything started: {1} checks.", Plan["run"].Length)
	Real["notify"].Call(StrReplace(t("field_check.all.started"), "{1}", Plan["run"].Length))
	FieldCheckAll_Run(Plan, Real, _FieldCheckAll_Finish.Bind(Real))
	return true
}

; Logs the evidence line and shows the combined report.
_FieldCheckAll_Finish(Deps, Summary) {
	global FIELD_CHECK_ALL_TAG, FIELD_CHECK_ALL_TITLE
	_FieldCheckAll_Busy(false)
	LoggerEvidence(FIELD_CHECK_ALL_TAG, "Test everything result: {1}", FieldCheckAll_LogLine(Summary))
	LoggerSuccess(FIELD_CHECK_ALL_TAG, "Test everything finished: {1}.", Summary["passed"] ? "pass" : "fail")
	ComposerCheck_ShowText(FieldCheckAll_Text(Summary, t), Deps.Get("show", 0), FIELD_CHECK_ALL_TITLE)
}

; Sets the busy flag of the one run.
_FieldCheckAll_Busy(Value) {
	global _FieldCheckAllBusy
	_FieldCheckAllBusy := Value
}
