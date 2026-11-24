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
;    follows the macOS and Linux grammar;
; 5. the progress window: a page that loads late gets the step states so far,
;    each change and the end reach the page, closing it during the run cancels
;    the run, and its buttons open the run's folder, copy its report and file
;    its issue with the evidence line; the command opens it, a second click
;    brings it back, and without a window the run goes on and its report opens
;    in the one-click dialog.
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

; A progress over recording effects, bound to a recording window.
_TFR_Progress(Box, CopyOk := true, IssueOk := true) {
	Effects := Map(
		"open_folder", (Dir) => (Box.Opened.Push(Dir), true),
		"copy", (Text) => (Box.Copies.Push(Text), CopyOk),
		"issue", (Line, Text) => (Box.Issues.Push(Line . "|" . Text), IssueOk))
	Progress := FieldReportProgress(Effects, (Step) => (Step["check"] == "network" ? "Network" : ""),
		() => (Box.Cancelled += 1, true))
	Window := {Pushed: Box.Pushed}
	Window.Push := (Self, Json) => (Self.Pushed.Push(Json), true)
	Window.Close := (Self) => (Box.Closed += 1)
	Progress.Bind(Window)
	return Progress
}

_TFR_Box() {
	return {Pushed: [], Opened: [], Copies: [], Issues: [], Cancelled: 0, Closed: 0}
}

_TFR_ProgressRun() {
	return Map("request_id", "app-1", "dir", "C:\fr\results\app-1",
		"steps", [Map("id", "field_network", "check", "network"), Map("id", "field_composer", "check", "composer")],
		"not_run", [Map("step", "driver_reload", "reason", "needs_collector")])
}

_TFR_ProgressSummary() {
	return FieldReport_Summary([Map("step", "field_network", "verdict", "pass", "codes", [], "report", 0),
		Map("step", "field_composer", "verdict", "fail", "codes", ["probe_fail"], "report", 0)],
		[Map("step", "driver_reload", "reason", "needs_collector")], _TFR_ProgressRun()["steps"],
		Map("request_id", "app-1", "interrupted", false), "C:\fr\results\app-1")
}

_TFR_ProgressReplaysAndPushes() {
	Box := _TFR_Box()
	Progress := _TFR_Progress(Box)
	Run := _TFR_ProgressRun()
	Progress.Started(Run["steps"][1])
	Progress.Attach(Run)
	AssertEqual(0, Box.Pushed.Length, "nothing reaches a page that has not loaded")
	Progress.OnReady()
	AssertEqual(1, Box.Pushed.Length, "one init message")
	Init := JsonParse(Box.Pushed[1])
	AssertEqual("init", Init["type"])
	AssertEqual("field_report.open_explorer", Init["open_key"])
	AssertEqual("Network", Init["steps"][1]["title"])
	AssertEqual("running", Init["steps"][1]["state"], "the step started before the page loaded")
	AssertEqual("field_composer", Init["steps"][2]["title"], "a step without a Tests row reads as its id")
	AssertEqual("pending", Init["steps"][2]["state"])
	AssertEqual("driver_reload", Init["not_run"][1]["id"])
	AssertEqual("needs_collector", Init["not_run"][1]["reason"])
	Progress.Recorded("field_network", "pass")
	Step := JsonParse(Box.Pushed[2])
	AssertEqual("step", Step["type"])
	AssertEqual("field_network", Step["id"])
	AssertEqual("pass", Step["state"])
	Progress.Finished(_TFR_ProgressSummary(), "the report")
	Done := JsonParse(Box.Pushed[3])
	AssertEqual("done", Done["type"])
	AssertFalse(Done["passed"])
	AssertFalse(Done["interrupted"])
	AssertEqual(1, Done["counts"]["fail"])
	AssertEqual("C:\fr\results\app-1", Done["folder"])
	Late := _TFR_Box()
	LateProgress := _TFR_Progress(Late)
	LateProgress.Attach(Run)
	LateProgress.Recorded("field_network", "pass")
	LateProgress.Finished(_TFR_ProgressSummary(), "the report")
	LateProgress.OnReady()
	AssertEqual(2, Late.Pushed.Length, "a page that loads after the end gets the init and the end")
	AssertEqual("pass", JsonParse(Late.Pushed[1])["steps"][1]["state"])
	AssertEqual("done", JsonParse(Late.Pushed[2])["type"])
}
Test("field report: the progress window gives a late page the states so far (field-report-window)",
	_TFR_ProgressReplaysAndPushes)

_TFR_ProgressCancels() {
	Box := _TFR_Box()
	Progress := _TFR_Progress(Box)
	Progress.Attach(_TFR_ProgressRun())
	Progress.OnAction("cancel")
	AssertEqual(1, Box.Cancelled, "Stop cancels the run")
	Progress.OnAction("close")
	AssertEqual(2, Box.Cancelled, "closing the window during the run cancels it")
	AssertEqual(1, Box.Closed)
	Boxed := _TFR_Box()
	BoxedProgress := _TFR_Progress(Boxed)
	BoxedProgress.Attach(_TFR_ProgressRun())
	BoxedProgress.OnClosed()
	BoxedProgress.OnClosed()
	AssertEqual(1, Boxed.Cancelled, "the close box cancels the run once")
	Ended := _TFR_Box()
	EndedProgress := _TFR_Progress(Ended)
	EndedProgress.Attach(_TFR_ProgressRun())
	EndedProgress.Finished(_TFR_ProgressSummary(), "the report")
	EndedProgress.OnAction("close")
	AssertEqual(0, Ended.Cancelled, "a finished run is not cancelled")
	AssertEqual(1, Ended.Closed)
}
Test("field report: closing the progress window during the run cancels it (field-report-window)",
	_TFR_ProgressCancels)

_TFR_ProgressActions() {
	Box := _TFR_Box()
	Progress := _TFR_Progress(Box)
	Progress.Attach(_TFR_ProgressRun())
	Progress.OnReady()
	Progress.Finished(_TFR_ProgressSummary(), "the report")
	Progress.OnAction("open_folder")
	AssertEqual("C:\fr\results\app-1", Box.Opened[1], "the run's own folder")
	Answer := JsonParse(Box.Pushed[Box.Pushed.Length])
	AssertEqual("open_folder", Answer["action"])
	AssertTrue(Answer["ok"])
	Progress.OnAction("copy")
	AssertEqual("the report", Box.Copies[1])
	AssertTrue(JsonParse(Box.Pushed[Box.Pushed.Length])["ok"])
	Progress.OnAction("issue")
	AssertEqual("check=field_report verdict=fail request=app-1 pass=1 fail=1 not_run=1"
		. " field_network=pass field_composer=fail|the report", Box.Issues[1],
		"the issue carries the run's evidence line and its report")
	AssertEqual("issue", JsonParse(Box.Pushed[Box.Pushed.Length])["action"])
	AssertTrue(JsonParse(Box.Pushed[Box.Pushed.Length])["ok"])
	Before := Box.Pushed.Length
	Progress.OnAction("delete_everything")
	AssertEqual(Before, Box.Pushed.Length, "an unknown action gets no answer")
	Refused := _TFR_Box()
	RefusedProgress := _TFR_Progress(Refused, false, false)
	RefusedProgress.Attach(_TFR_ProgressRun())
	RefusedProgress.OnReady()
	RefusedProgress.OnAction("issue")
	AssertFalse(JsonParse(Refused.Pushed[Refused.Pushed.Length])["ok"], "an issue before the end fails")
	AssertEqual(0, Refused.Issues.Length, "no form before the end")
	RefusedProgress.Finished(_TFR_ProgressSummary(), "the report")
	RefusedProgress.OnAction("copy")
	AssertFalse(JsonParse(Refused.Pushed[Refused.Pushed.Length])["ok"], "a refused clipboard is said")
	RefusedProgress.OnAction("issue")
	AssertFalse(JsonParse(Refused.Pushed[Refused.Pushed.Length])["ok"], "a form that did not open is said")
}
Test("field report: the progress window's buttons act on the run's own folder and report (field-report-window)",
	_TFR_ProgressActions)

_TFR_WindowHost() {
	Body := _DriverFuncBody("_FieldReport_DefaultDeps")
	Assert(Body != "", "the field report's collaborators must exist before checking them")
	AssertTrue(InStr(Body, '"window", (Owner) => FieldReportWindow.Open(Owner)') > 0,
		"the row opens the shared progress window")
	Finish := _DriverFuncBody("_FieldReport_Finish")
	Assert(Finish != "", "the end of the run must exist before checking where its report goes")
	AssertTrue(InStr(Finish, "Progress.Finished(Summary, Text)") > 0, "the report goes to the progress window")
	AssertTrue(InStr(Finish, "if !State.Windowed {") > 0, "the one-click dialog shows it only without a window")
	Deps := _DriverFuncBody("_FieldReport_DefaultDeps")
	AssertTrue(InStr(Deps, '"issue", (Line, Text) => HealthCheck_ReportFieldRun(Line, Text)') > 0,
		"the issue goes through the bug-report link owner")
	Window := FieldReportWindow()
	AssertTrue(Window is WebViewHost, "the window is a WebViewHost: manifest geometry, locale and reading choices")
	Told := {Count: 0}
	Owner := {}
	Owner.OnClosed := (Self) => (Told.Count += 1)
	Window.Owner := Owner
	Window.ResetDone := true
	Window.Opened := true
	Window.Close()
	Window.Close()
	AssertEqual(1, Told.Count, "closing the window tells its owner once")
	Unopened := FieldReportWindow()
	Unopened.Owner := Owner
	Unopened.ResetDone := true
	Unopened.Close()
	AssertEqual(1, Told.Count, "a window that never opened tells nobody: the run goes on")
	Box := _TFR_Box()
	Progress := _TFR_Progress(Box)
	Progress.Attach(_TFR_ProgressRun())
	Progress.Detach(Progress.Window)
	Progress.OnClosed()
	AssertEqual(0, Box.Cancelled, "a detached window cancels nothing")
	Progress.OnReady()
	AssertEqual(0, Box.Pushed.Length, "a detached window takes no push")
}
Test("field report: the progress window is a WebViewHost that tells its owner once (field-report-window)",
	_TFR_WindowHost)

_TFR_Command() {
	Box := {Refusals: [], Notes: [], Shown: [], Windows: 0, Fronts: 0, Owner: 0, RefuseWindow: false, Cancelled: 0}
	Run := Map("request_id", "app-1", "dir", "C:\fr\results\app-1",
		"steps", [Map("id", "field_network", "check", "network")], "not_run", [])
	Fake := {Observer: 0}
	Fake.SubmitInApp := (Self, Observer, &Reason) => (Self.Observer := Observer, Reason := "", Run)
	Fake.CancelInApp := (Self) => (Box.Cancelled += 1, true)
	Deps := Map("session", () => Fake,
		"notify", (Text) => Box.Notes.Push(Text),
		"busy", (Text) => Box.Refusals.Push(Text),
		"window", (Owner) => (Box.Windows += 1, Box.Owner := Owner, !Box.RefuseWindow),
		"front", () => (Box.Fronts += 1, !Box.RefuseWindow),
		"show", (Title, Text) => Box.Shown.Push(Title . "|" . Text),
		"effects", Map("open_folder", (Dir) => true, "copy", (Text) => true, "issue", (Line, Text) => true))
	try {
		AssertTrue(FieldReport_Command(Deps), "the run starts")
		AssertEqual(1, Box.Windows, "the progress window opens")
		AssertTrue(Box.Owner is FieldReportProgress, "the window follows the run's progress")
		AssertEqual(0, Box.Notes.Length, "the window replaces the start notice")
		AssertFalse(FieldReport_Command(Deps), "a second click starts nothing")
		AssertEqual(1, Box.Fronts, "a second click brings the window back")
		AssertEqual(0, Box.Refusals.Length)
		Fake.Observer["step_recorded"].Call(1, Run["steps"][1], Map("step", "field_network", "verdict", "pass",
			"codes", [], "report", _TFR_Report()))
		Fake.Observer["finished"].Call(Map("request_id", "app-1", "interrupted", false), Run["dir"])
		AssertTrue(InStr(Box.Owner.Text, "C:\fr\results\app-1") > 0, "the report names its folder")
		AssertEqual("C:\fr\results\app-1", Box.Owner.Summary["dir"])
		AssertEqual(0, Box.Shown.Length, "the report stays in its window")
		Box.RefuseWindow := true
		AssertTrue(FieldReport_Command(Deps), "without a window the run still starts")
		AssertEqual(1, Box.Notes.Length, "the start is announced")
		AssertFalse(FieldReport_Command(Deps), "a second click starts nothing")
		AssertEqual(1, Box.Refusals.Length, "with no window to bring back, it is refused")
		Fake.Observer["finished"].Call(Map("request_id", "app-1", "interrupted", false), Run["dir"])
		AssertEqual(1, Box.Shown.Length, "the report opens in the one-click dialog")
		AssertTrue(InStr(Box.Shown[1], t("menu.debug.field_report") . "|") == 1, Box.Shown[1])
		AssertEqual(0, Box.Cancelled, "no run was cancelled")
	} finally _FieldReport_SetBusy(false)
}
Test("field report: the command opens the progress window, or the dialog without one (field-report-window)",
	_TFR_Command)
