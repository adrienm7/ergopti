; tests/unit/diagnostics/ui/test_field_report.ahk

; ==============================================================================
; MODULE: In-App Field Report Tests (Windows)
; DESCRIPTION:
; Débogage's « Lancer le field report (tous les tests) » over a real field run
; session in a temporary folder (diagnostics/engine/field_run/field_run.ahk) and the
; report (diagnostics/ui/field_check/field_report.ahk):
; 1. the menu routes the row, which stands just before Tests;
; 2. the session runs its field check steps in-process, writes the same result
;    files, leaves the timed reload out by name and tells its observer each
;    step and the end; a second run is refused while one goes on;
; 3. a cancelled run is closed as interrupted and its observer told once;
; 4. the report names the counts, each verdict, the steps not run with their
;    reason, the rows to run separately and the folder; its evidence line
;    follows the macOS and Linux grammar.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; A fresh field run folder.
_TFR_Folder() {
	Folder := A_Temp . "\ergopti_field_report_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Folder)
	return Folder
}

; A session over a three-step declaration: two checks and the timed reload.
_TFR_Session(Folder, Runners) {
	global _SharedDir
	Spec := FieldRun_LoadProtocol(_SharedDir . "\diagnostics\data\field_run_protocol.json")
	Path := Folder . "\steps.json"
	FileAppend('{"deadline_seconds":{"default":60,"min":30,"max":600},"steps":['
		. '{"id":"field_network","kind":"field_check","check":"network","deadline_seconds":5,"proves":"x"},'
		. '{"id":"driver_reload","kind":"reload","deadline_seconds":5,"proves":"x"},'
		. '{"id":"field_composer","kind":"field_check","check":"composer","deadline_seconds":5,"proves":"x"}]}',
		Path, "UTF-8-RAW")
	Steps := FieldRun_LoadSteps(Path, Spec, Runners)
	Session := FieldRunSession(Spec, Steps, Folder . "\run", 4242,
		Map("poll_ms", 50, "runners", Runners, "reload", () => false, "reload_ms", () => ""))
	Session.Start()
	return Session
}

; A passing tray check report.
_TFR_Report() {
	Report := ComposerCheck_NewReport()
	ComposerCheck_Step(Report, "probe", "pass")
	return Report
}

; Waits up to TimeoutMs for a condition, letting the session's timers run.
_TFR_WaitUntil(Condition, TimeoutMs := 3000) {
	Started := A_TickCount
	while !Condition.Call() && (A_TickCount - Started < TimeoutMs)
		Sleep(20)
	return Condition.Call()
}

_TFR_Translate(Key) {
	if Key == "common.label_value"
		return "{1} : {2}"
	if Key == "field_check.all.saved_in"
		return "saved {1}"
	return "[" . Key . "]"
}





; ===========================
; ===========================
; ======= 2/ The row ========
; ===========================
; ===========================

_TFR_RowIsRouted() {
	Body := _DriverFuncBody("_MI_BuildDebuggingMenu")
	Assert(Body != "", "the Debug builder must exist before checking its commands")
	; The driver source reads each generated constant as the string it stands for.
	AssertTrue(InStr(Body, _DriverResolveConstants("MenuCommand.FIELD_REPORT") . ", (*) => FieldReport_Command(),") > 0,
		"the Debug menu routes the field report row")
	Debug := _MM_GetManifestRoot()["debug_menu"]
	At := 0
	for Index, Row in Debug
		if Row.Get("id", "") == "field_report"
			At := Index
	AssertTrue(At > 0, "the Debug menu declares the field report row")
	AssertEqual("debug_tests", Debug[At + 1].Get("id", ""), "the field report row stands just before Tests")
}
Test("field report: the Debug menu routes the row just before Tests (field-report-in-app)", _TFR_RowIsRouted)





; ===========================
; ===========================
; ======= 3/ The run ========
; ===========================
; ===========================

_TFR_RunsInApp() {
	Folder := _TFR_Folder()
	Session := 0
	Events := []
	Runners := Map(
		"network", (Spec, Done) => Done.Call("pass", ["ok"], _TFR_Report()),
		"composer", (Spec, Done) => Done.Call("fail", ["probe_fail"]))
	try {
		Session := _TFR_Session(Folder, Runners)
		Observer := Map(
			"step_started", (Index, Step) => Events.Push("start:" . Step["id"]),
			"step_recorded", (Index, Step, Result) => Events.Push("record:" . Result["step"] . ":" . Result["verdict"]),
			"finished", (Done, Dir) => Events.Push("done:" . (Done["interrupted"] ? "1" : "0")))
		Run := Session.SubmitInApp(Observer, &Reason)
		Assert(IsObject(Run), "the in-app run starts")
		AssertTrue(InStr(Run["request_id"], Session.Spec["in_app_prefix"]) == 1, "an in-app request id")
		AssertEqual(1, Run["not_run"].Length, "the timed reload is left out")
		AssertEqual("driver_reload", Run["not_run"][1]["step"])
		AssertEqual("needs_collector", Run["not_run"][1]["reason"])
		AssertFalse(FileExist(Session.Path("request")), "no request file is written")
		Again := Session.SubmitInApp(Map(), &Busy)
		AssertFalse(IsObject(Again), "a second run is refused while one goes on")
		AssertEqual("busy", Busy)
		Done := Run["dir"] . "\" . Session.Spec["files"]["done"]
		Assert(_TFR_WaitUntil(() => FileExist(Done) != ""), "the run writes its done marker")
		AssertEqual("pass", JsonParse(FSReadUtf8Exact(Run["dir"] . "\01_field_network.json"))["verdict"])
		AssertEqual("fail", JsonParse(FSReadUtf8Exact(Run["dir"] . "\02_field_composer.json"))["verdict"])
		Joined := ""
		for Event in Events
			Joined .= (Joined == "" ? "" : " ") . Event
		AssertEqual("start:field_network record:field_network:pass start:field_composer record:field_composer:fail done:0",
			Joined, "the observer hears each step and the end")
	} finally {
		if IsObject(Session)
			try Session.Stop()
		try DirDelete(Folder, true)
	}
}
Test("field report: the session runs its field check steps in-app and tells its observer (field-report-in-app)",
	_TFR_RunsInApp)

_TFR_CancelClosesTheRun() {
	Folder := _TFR_Folder()
	Session := 0
	Finished := []
	; The network check never answers: the run waits on it
	Runners := Map("network", (Spec, Done) => true, "composer", (Spec, Done) => Done.Call("pass", []))
	try {
		Session := _TFR_Session(Folder, Runners)
		Run := Session.SubmitInApp(Map("finished", (Done, Dir) => Finished.Push(Done)), &Reason)
		Assert(IsObject(Run), "the in-app run starts")
		AssertTrue(Session.CancelInApp(), "the person cancels the run")
		AssertFalse(Session.CancelInApp(), "nothing is left to cancel")
		DoneText := FSReadUtf8Exact(Run["dir"] . "\" . Session.Spec["files"]["done"])
		AssertContains(DoneText, '"interrupted":true', "a cancelled run is closed as interrupted")
		AssertContains(DoneText, '"cause":"cancelled"', "its cause is named")
		AssertEqual(1, Finished.Length, "the observer is told once")
		AssertTrue(Finished[1]["interrupted"])
	} finally {
		if IsObject(Session)
			try Session.Stop()
		try DirDelete(Folder, true)
	}
}
Test("field report: a cancelled in-app run is closed as interrupted (field-report-in-app)", _TFR_CancelClosesTheRun)





; =============================
; =============================
; ======= 4/ The report =======
; =============================
; =============================

_TFR_Text() {
	Results := [
		Map("step", "field_network", "verdict", "pass", "codes", ["ok"], "report", _TFR_Report()),
		Map("step", "field_boot_cost", "verdict", "fail", "codes", ["boot_ms_3010", "budget_ms_2500"], "report", 0),
		Map("step", "field_composer", "verdict", "timeout", "codes", ["deadline_90s"], "report", 0)]
	Steps := [Map("id", "field_network", "check", "network"), Map("id", "field_boot_cost", "check", "boot_cost"),
		Map("id", "field_composer", "check", "composer")]
	Summary := FieldReport_Summary(Results, [Map("step", "driver_reload", "reason", "needs_collector")], Steps,
		Map("request_id", "app-20261124T120000Z", "interrupted", false), "C:\fr\results\app-20261124T120000Z")
	Text := FieldReport_Text(Summary, _TFR_Translate)
	AssertTrue(InStr(Text, "[field_check.all.verdict_fail]`n[OK] 1 · [X] 1 · [T] 1 · [-] 1") == 1, Text)
	AssertTrue(InStr(Text, "[OK] [menu.debug.field_check_network] — field_network`n    [OK] [field_check.step.probe]") > 0, Text)
	AssertTrue(InStr(Text, "[X] field_boot_cost`n    boot_ms_3010, budget_ms_2500") > 0, Text)
	AssertTrue(InStr(Text, "[T] [menu.debug.composer_check] — field_composer`n    deadline_90s") > 0, Text)
	AssertTrue(InStr(Text, "[field_check.all.not_run_header]`n[-] driver_reload : [field_check.all.reason.needs_collector]") > 0, Text)
	AssertTrue(InStr(Text, "[field_check.all.separate_header]") > 0, Text)
	AssertTrue(InStr(Text, "[menu.debug.send_probe]") > 0 && InStr(Text, "[menu.debug.hook_probe]") > 0,
		"the two input probes are run separately")
	AssertTrue(InStr(Text, "saved C:\fr\results\app-20261124T120000Z`n[field_check.all.attach]") > 0, Text)
	AssertEqual("check=field_report verdict=fail request=app-20261124T120000Z pass=1 fail=1 timeout=1 not_run=1"
		. " field_network=pass field_boot_cost=fail field_composer=timeout", FieldReport_LogLine(Summary))
	Cut := FieldReport_Summary([], [], [], Map("request_id", "app-1", "interrupted", true), "C:\fr")
	AssertTrue(InStr(FieldReport_Text(Cut, _TFR_Translate), "[field_check.all.interrupted]") == 1,
		"an interrupted run says so first")
}
Test("field report: the report names each verdict, the steps not run and the folder (field-report-in-app)", _TFR_Text)

_TFR_Command() {
	Box := {Shown: [], Notes: [], Refusals: []}
	Run := Map("request_id", "app-1", "dir", "C:\fr\results\app-1",
		"steps", [Map("id", "field_network", "check", "network")], "not_run", [])
	Fake := {Observer: 0}
	Fake.SubmitInApp := (Self, Observer, &Reason) => (Self.Observer := Observer, Reason := "", Run)
	Deps := Map("session", () => Fake,
		"notify", (Text) => Box.Notes.Push(Text),
		"busy", (Text) => Box.Refusals.Push(Text),
		"show", (Title, Text) => Box.Shown.Push(Title . "|" . Text))
	try {
		AssertTrue(FieldReport_Command(Deps), "the run starts")
		AssertEqual(1, Box.Notes.Length, "the start is announced")
		AssertFalse(FieldReport_Command(Deps), "a second click starts nothing")
		AssertEqual(1, Box.Refusals.Length, "the second click is refused")
		Fake.Observer["step_recorded"].Call(1, Run["steps"][1], Map("step", "field_network", "verdict", "pass",
			"codes", [], "report", _TFR_Report()))
		Fake.Observer["finished"].Call(Map("request_id", "app-1", "interrupted", false), Run["dir"])
		AssertEqual(1, Box.Shown.Length, "one report")
		AssertTrue(InStr(Box.Shown[1], t("menu.debug.field_report") . "|") == 1, Box.Shown[1])
		AssertTrue(FieldReport_Command(Deps), "a finished run can start again")
	} finally _FieldReport_SetBusy(false)
}
Test("field report: the command refuses a second click and shows one report (field-report-in-app)", _TFR_Command)
