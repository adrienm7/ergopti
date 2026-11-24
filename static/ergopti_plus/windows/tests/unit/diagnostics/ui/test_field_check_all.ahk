; tests/unit/diagnostics/ui/test_field_check_all.ahk

; ==============================================================================
; MODULE: Test Everything Tests (Windows)
; DESCRIPTION:
; The Debug menu's « Test everything » (diagnostics/ui/field_check/run_all.ahk):
; 1. the shipped plan builds against this driver's field run steps, every
;    Windows Tests row is run or listed as « run separately », and the menu
;    routes the row;
; 2. the checks run one after the other from fresh timer turns; a refused, a
;    raising and a late check are failed entries and the sequence goes on;
; 3. the combined report names each check's verdict and field run step, a
;    developer check's steps as closed codes, then the rows to run separately,
;    and its evidence line follows the macOS and Linux grammar.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; A timer queue the test drains by hand: each handle is {At, Fn, Cancelled}.
_TFCA_Clock() {
	return {Now: 0, Queue: []}
}

_TFCA_Push(Clock, Ms, Fn) {
	Handle := {At: Clock.Now + Ms, Fn: Fn, Cancelled: false}
	Clock.Queue.Push(Handle)
	return Handle
}

; Runs every turn due by UntilMs, earliest first.
_TFCA_Drain(Clock, UntilMs) {
	loop {
		Best := 0, BestIndex := 0
		for Index, Handle in Clock.Queue
			if !Handle.Cancelled && Handle.At <= UntilMs && (!IsObject(Best) || Handle.At < Best.At)
				Best := Handle, BestIndex := Index
		if !IsObject(Best)
			return
		Clock.Queue.RemoveAt(BestIndex)
		Clock.Now := Max(Clock.Now, Best.At)
		Best.Fn.Call()
	}
}

_TFCA_Deps(Clock, StartFn) {
	return Map("start", StartFn,
		"after", (Ms, Fn) => _TFCA_Push(Clock, Ms, Fn),
		"cancel", (Handle) => Handle.Cancelled := true)
}

_TFCA_Report(State) {
	Report := ComposerCheck_NewReport()
	ComposerCheck_Step(Report, "probe", State)
	return Report
}

_TFCA_Steps() {
	return Map(
		"field_network", Map("id", "field_network", "kind", "field_check", "check", "network", "deadline_seconds", 60),
		"field_composer", Map("id", "field_composer", "kind", "field_check", "check", "composer", "deadline_seconds", 90),
		"field_boot_cost", Map("id", "field_boot_cost", "kind", "field_check", "check", "boot_cost", "deadline_seconds", 10),
		"driver_reload", Map("id", "driver_reload", "kind", "reload", "deadline_seconds", 60))
}

_TFCA_Declaration(Run, Separate := unset) {
	return Map("platforms", Map("ahk", Map("run", Run, "separate", IsSet(Separate) ? Separate : [])))
}

_TFCA_Translate(Key) {
	return Key == "common.label_value" ? "{1} : {2}" : "[" . Key . "]"
}





; ===========================
; ===========================
; ======= 2/ The plan =======
; ===========================
; ===========================

_TFCA_ShippedPlan() {
	Plan := _FieldCheckAll_LoadPlan()
	AssertTrue(Plan["run"].Length > 0, "the Windows plan runs checks")
	Classified := Map("field_report", true)
	for Entry in Plan["run"] {
		AssertTrue(FieldRun_Runners().Has(Entry["check"]), "a field run runner exists for " . Entry["check"])
		if Entry["row"] != ""
			Classified[Entry["row"]] := true
	}
	for Entry in Plan["separate"]
		Classified[Entry["row"]] := true
	Debug := _MM_GetManifestRoot()["debug_menu"]
	At := 0
	for Index, Row in Debug
		if Row.Get("id", "") == "field_report"
			At := Index
	AssertTrue(At > 0, "the Debug menu declares the field report row")
	AssertEqual("debug_tests", Debug[At + 1].Get("id", ""), "the field report row stands just before Tests")
	Rows := _MM_GetManifestRoot()["debug_tests_menu"]
	for Row in Rows {
		ForWindows := !Row.Has("platforms")
		if Row.Has("platforms")
			for Platform in Row["platforms"]
				if Platform == "ahk"
					ForWindows := true
		if ForWindows && Row["type"] == "command"
			AssertTrue(Classified.Has(Row["id"]), "Tests row neither run nor listed: " . Row["id"])
	}
	Body := _DriverFuncBody("_MI_BuildDebuggingMenu")
	AssertTrue(InStr(Body, "MenuCommand.FIELD_REPORT, (*) => FieldCheckAll_Command(),") > 0,
		"the Debug menu routes « Test everything »")
}
Test("test everything: the shipped plan classifies every Windows Tests row (field-check-all)", _TFCA_ShippedPlan)

_TFCA_PlanRefusals() {
	Steps := _TFCA_Steps()
	Plan := FieldCheckAll_Plan(_TFCA_Declaration([Map("step", "field_network", "row", "field_check_network")],
		[Map("row", "hook_probe")]), Steps)
	AssertEqual("network", Plan["run"][1]["check"])
	AssertEqual(60, Plan["run"][1]["deadline_seconds"])
	AssertEqual("hook_probe", Plan["separate"][1]["row"])
	for Bad in [[Map("step", "nope")], [Map("step", "driver_reload")]] {
		Raised := false
		try FieldCheckAll_Plan(_TFCA_Declaration(Bad), Steps)
		catch
			Raised := true
		AssertTrue(Raised, "an unknown or non-check step is refused")
	}
}
Test("test everything: the plan refuses an unknown or non-check step (field-check-all)", _TFCA_PlanRefusals)





; ==========================
; ==========================
; ======= 3/ The run =======
; ==========================
; ==========================

_TFCA_Sequence() {
	Clock := _TFCA_Clock()
	Plan := FieldCheckAll_Plan(_TFCA_Declaration([Map("step", "field_network"), Map("step", "field_composer"),
		Map("step", "field_boot_cost")]), _TFCA_Steps())
	Box := {Started: "", Pending: Map(), Done: 0}
	Start := (Planned, OnResult) => (Box.Started .= Planned["check"] . ",", Box.Pending[Planned["check"]] := OnResult, true)
	FieldCheckAll_Run(Plan, _TFCA_Deps(Clock, Start), (Summary) => Box.Done := Summary)
	AssertEqual("", Box.Started, "the first check waits for a timer turn")
	_TFCA_Drain(Clock, 0)
	AssertEqual("network,", Box.Started)
	Box.Pending["network"].Call(_TFCA_Report("pass"))
	AssertEqual("network,", Box.Started, "the next check waits for its own turn")
	_TFCA_Drain(Clock, 0)
	AssertEqual("network,composer,", Box.Started)
	Box.Pending["composer"].Call(_TFCA_Report("fail"))
	Box.Pending["composer"].Call(_TFCA_Report("pass"))
	_TFCA_Drain(Clock, 9999)
	AssertFalse(IsObject(Box.Done), "the boot cost check still has time")
	_TFCA_Drain(Clock, 10000)
	Box.Pending["boot_cost"].Call(_TFCA_Report("pass"))
	_TFCA_Drain(Clock, 99999)
	Assert(IsObject(Box.Done), "the run settles")
	AssertEqual("check=all verdict=fail checks=3 field_network=pass field_composer=fail field_boot_cost=fail:timeout separate=0",
		FieldCheckAll_LogLine(Box.Done))
}
Test("test everything: the checks run in turn and a late one is a timeout (field-check-all)", _TFCA_Sequence)

_TFCA_RefusedAndRaised() {
	Clock := _TFCA_Clock()
	Plan := FieldCheckAll_Plan(_TFCA_Declaration([Map("step", "field_network"), Map("step", "field_composer"),
		Map("step", "field_boot_cost")]), _TFCA_Steps())
	Box := {Done: 0}
	FieldCheckAll_Run(Plan, _TFCA_Deps(Clock, _TFCA_RefusingStart), (Summary) => Box.Done := Summary)
	_TFCA_Drain(Clock, 0)
	Assert(IsObject(Box.Done), "the run settles")
	AssertEqual("check=all verdict=fail checks=3 field_network=fail:refused field_composer=fail:raised field_boot_cost=pass separate=0",
		FieldCheckAll_LogLine(Box.Done))
	for Handle in Clock.Queue
		AssertTrue(Handle.Cancelled, "a settled check leaves no deadline behind")
}
Test("test everything: a refused and a raising check fail and the run goes on (field-check-all)",
	_TFCA_RefusedAndRaised)

_TFCA_RefusingStart(Planned, OnResult) {
	if Planned["check"] == "network"
		return false
	if Planned["check"] == "composer"
		throw Error("boom")
	OnResult.Call(_TFCA_Report("pass"))
	return true
}





; =============================
; =============================
; ======= 4/ The report =======
; =============================
; =============================

_TFCA_Text() {
	Clock := _TFCA_Clock()
	Plan := FieldCheckAll_Plan(_TFCA_Declaration([Map("step", "field_network", "row", "field_check_network"),
		Map("step", "field_boot_cost"), Map("step", "field_composer", "row", "composer_check")],
		[Map("row", "send_probe")]), _TFCA_Steps())
	Box := {Done: 0}
	FieldCheckAll_Run(Plan, _TFCA_Deps(Clock, _TFCA_ReportingStart), (Summary) => Box.Done := Summary)
	_TFCA_Drain(Clock, 999999)
	Text := FieldCheckAll_Text(Box.Done, _TFCA_Translate)
	AssertTrue(InStr(Text, "[field_check.all.verdict_fail]") == 1, Text)
	AssertTrue(InStr(Text, "[OK] [menu.debug.field_check_network] — field_network`n    [OK] [field_check.step.probe]") > 0, Text)
	AssertTrue(InStr(Text, "[X] field_boot_cost`n    [i] boot_total_ms : 3010`n    [X] boot_budget") > 0, Text)
	AssertTrue(InStr(Text, "[X] [menu.debug.composer_check] — field_composer`n    [field_check.all.timeout]") > 0, Text)
	AssertTrue(InStr(Text, "[field_check.all.separate_header]`n[-] [menu.debug.send_probe]") > 0, Text)
	AssertFalse(InStr(Text, "[field_check.verdict_pass]"), "a check's own verdict line is its mark")
}
Test("test everything: the report names each verdict, step and the rows to run separately (field-check-all)",
	_TFCA_Text)

_TFCA_ReportingStart(Planned, OnResult) {
	if Planned["check"] == "composer"
		return true
	if Planned["check"] == "boot_cost" {
		Report := ComposerCheck_NewReport()
		ComposerCheck_Step(Report, "boot_total_ms", "info", 3010)
		ComposerCheck_Step(Report, "boot_budget", "fail")
		OnResult.Call(Report)
		return true
	}
	OnResult.Call(_TFCA_Report("pass"))
	return true
}

_TFCA_Command() {
	Clock := _TFCA_Clock()
	Box := {Shown: [], Notes: [], Refusals: []}
	Plan := FieldCheckAll_Plan(_TFCA_Declaration([Map("step", "field_network", "row", "field_check_network")]),
		_TFCA_Steps())
	Deps := _TFCA_Deps(Clock, (Planned, OnResult) => (OnResult.Call(_TFCA_Report("pass")), true))
	Deps["plan"] := Plan
	Deps["notify"] := (Text) => Box.Notes.Push(Text)
	Deps["busy"] := (Text) => Box.Refusals.Push(Text)
	Deps["show"] := (Title, Text) => Box.Shown.Push(Title . "|" . Text)
	try {
		AssertTrue(FieldCheckAll_Command(Deps), "the run starts")
		AssertEqual(1, Box.Notes.Length, "the start is announced")
		AssertFalse(FieldCheckAll_Command(Deps), "a second click starts nothing")
		AssertEqual(1, Box.Refusals.Length, "the second click is refused")
		_TFCA_Drain(Clock, 999999)
		AssertEqual(1, Box.Shown.Length, "one combined report")
		AssertTrue(InStr(Box.Shown[1], t("menu.debug.field_report") . "|") == 1, Box.Shown[1])
		AssertTrue(FieldCheckAll_Command(Deps), "a finished run can start again")
		_TFCA_Drain(Clock, 999999)
	} finally _FieldCheckAll_Busy(false)
}
Test("test everything: the command refuses a second click and shows one report (field-check-all)", _TFCA_Command)
