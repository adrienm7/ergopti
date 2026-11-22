; tests/unit/diagnostics/engine/field_run/test_reload_step.ahk

; ==============================================================================
; MODULE: Developer Field Run Reload Step (Windows)
; DESCRIPTION:
; The macOS and Linux field runs reload their driver on purpose, then resume
; the run in the successor and name the reload's duration; the Windows field
; run had no reload step, so a field report never measured a Windows reload
; (windows-field-reload, timing parity campaign TIM-05). Two real sessions
; share one temporary folder: the first runs the step up to its reload request
; and stops as the driver would at exit; the second starts as the successor,
; resumes, records the step with the measured reload and runs the next one.
; ==============================================================================

#Requires AutoHotkey v2.0

; A fresh field run folder with its own steps file.
_FRR_Folder() {
	Folder := A_Temp . "\ergopti_field_reload_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Folder)
	return Folder
}

; The protocol and a three-step declaration: a check, the reload, a check.
_FRR_Declaration(Folder, &Spec, &Steps, Runners) {
	global _SharedDir
	Spec := FieldRun_LoadProtocol(_SharedDir . "\diagnostics\data\field_run_protocol.json")
	Path := Folder . "\steps.json"
	FileAppend('{"deadline_seconds":{"default":60,"min":30,"max":600},"steps":['
		. '{"id":"first","kind":"field_check","check":"ok","deadline_seconds":5,"proves":"x"},'
		. '{"id":"driver_reload","kind":"reload","deadline_seconds":5,"proves":"x"},'
		. '{"id":"last","kind":"field_check","check":"ok","deadline_seconds":5,"proves":"x"}]}', Path, "UTF-8-RAW")
	Steps := FieldRun_LoadSteps(Path, Spec, Runners)
}

; Waits up to TimeoutMs for a file, letting the sessions' timers run.
_FRR_WaitFor(Path, TimeoutMs := 3000) {
	Started := A_TickCount
	while !FileExist(Path) && (A_TickCount - Started < TimeoutMs)
		Sleep(20)
	return FileExist(Path) != ""
}

; Writes the collector's request for every step.
_FRR_Request(Session, Spec, Id) {
	FileAppend('{"schema":' . Spec["schema"] . ',"request_id":"' . Id . '","steps":["all"]}',
		Session.Path("request"), "UTF-8-RAW")
	Session.Handle()
}

_FRR_Session(Spec, Steps, Folder, Pid, Runners, ReloadFn, ReloadMsFn) {
	return FieldRunSession(Spec, Steps, Folder . "\run", Pid,
		Map("poll_ms", 50, "runners", Runners, "reload", ReloadFn, "reload_ms", ReloadMsFn))
}

_FRR_ResumesInTheSuccessor() {
	Folder := _FRR_Folder()
	First := 0, Second := 0
	State := Map("asked", 0)
	Runners := Map("ok", (Spec, Done) => Done.Call("pass", ["ok"]))
	try {
		_FRR_Declaration(Folder, &Spec, &Steps, Runners)
		First := _FRR_Session(Spec, Steps, Folder, 111, Runners, () => (State["asked"] += 1, true), () => "")
		First.Start()
		_FRR_Request(First, Spec, "frr-one")
		Assert(_FRR_WaitFor(First.Path("resume")), "the reload step writes the resume file before the reload")
		AssertEqual(1, State["asked"], "the reload owner is asked once")
		First.Stop()
		Assert(FileExist(First.Path("running")) != "", "the running marker stays for the successor")
		Dir := First.Path("results") . "\frr-one"
		Assert(!FileExist(Dir . "\" . Spec["files"]["done"]), "the run is suspended, not closed")

		Second := _FRR_Session(Spec, Steps, Folder, 222, Runners, () => false, () => 1234)
		Second.Start()
		Assert(_FRR_WaitFor(Dir . "\" . Spec["files"]["done"]), "the successor resumes the run to its end")
		Reload := JsonParse(FSReadUtf8Exact(Dir . "\02_driver_reload.json"))
		AssertEqual("pass", Reload["verdict"], "a measured reload passes")
		AssertEqual("reload", Reload["kind"])
		AssertEqual(1234, Reload["elapsed_ms"], "the step names the reload's duration")
		AssertEqual("reloaded", Reload["codes"][1])
		AssertEqual("pass", JsonParse(FSReadUtf8Exact(Dir . "\03_last.json"))["verdict"], "the next step runs")
		DoneText := FSReadUtf8Exact(Dir . "\" . Spec["files"]["done"])
		AssertEqual(3, JsonParse(DoneText)["order"].Length, "the done marker lists the three steps")
		AssertContains(DoneText, '"interrupted":false', "the resumed run is not interrupted")
		Assert(!FileExist(Second.Path("resume")), "the resume file is consumed once")
		AssertEqual(222, JsonParse(FSReadUtf8Exact(Second.Path("ready")))["pid"], "the successor is the ready driver")
	} finally {
		if IsObject(First)
			try First.Stop()
		if IsObject(Second)
			try Second.Stop()
		try DirDelete(Folder, true)
	}
}
Test("field run: the reload step resumes in the successor and names the reload (windows-field-reload, TIM-05)",
	_FRR_ResumesInTheSuccessor)

_FRR_RefusedAndUnmeasured() {
	Folder := _FRR_Folder()
	Session := 0, Successor := 0, First := 0
	Runners := Map("ok", (Spec, Done) => Done.Call("pass", ["ok"]))
	try {
		_FRR_Declaration(Folder, &Spec, &Steps, Runners)
		Session := _FRR_Session(Spec, Steps, Folder, 333, Runners, () => false, () => "")
		Session.Start()
		_FRR_Request(Session, Spec, "frr-refused")
		Dir := Session.Path("results") . "\frr-refused"
		Assert(_FRR_WaitFor(Dir . "\" . Spec["files"]["done"]), "a refused reload does not stop the run")
		Reload := JsonParse(FSReadUtf8Exact(Dir . "\02_driver_reload.json"))
		AssertEqual("fail", Reload["verdict"])
		AssertEqual("reload_refused", Reload["codes"][1], "the refusal is named")
		Assert(!FileExist(Session.Path("resume")), "a refused reload leaves no resume file")
		Session.Stop(), Session := 0

		; A successor whose reload went unmeasured fails the step by name.
		First := _FRR_Session(Spec, Steps, Folder, 444, Runners, () => true, () => "")
		First.Start()
		_FRR_Request(First, Spec, "frr-unmeasured")
		Assert(_FRR_WaitFor(First.Path("resume")))
		First.Stop()
		Successor := _FRR_Session(Spec, Steps, Folder, 555, Runners, () => false, () => "")
		Successor.Start()
		Dir := Successor.Path("results") . "\frr-unmeasured"
		Assert(_FRR_WaitFor(Dir . "\" . Spec["files"]["done"]))
		Reload := JsonParse(FSReadUtf8Exact(Dir . "\02_driver_reload.json"))
		AssertEqual("fail", Reload["verdict"])
		AssertEqual("reload_unmeasured", Reload["codes"][2], "an unmeasured reload is named")
	} finally {
		if IsObject(Session)
			try Session.Stop()
		if IsObject(First)
			try First.Stop()
		if IsObject(Successor)
			try Successor.Stop()
		try DirDelete(Folder, true)
	}
}
Test("field run: a refused or unmeasured reload fails its step by name (windows-field-reload, TIM-05)",
	_FRR_RefusedAndUnmeasured)
