; tests/unit/modules/shortcuts/workflows/test_workflow_runner.ahk

; ==============================================================================
; MODULE: User Workflow Runner and Owner (Windows)
; DESCRIPTION:
; Drives modules/shortcuts/workflows/runner.ahk and effects.ahk over recording
; ports, as _shared/tests/lua/workflows/workflow_owner_contract.lua and
; workflow_runner_contract.lua drive the shared owner on macOS and Linux:
; every step reaches its port, a failure is told naming its step, kind and
; reason, a screen step without the screen services is named, Escape stops a
; wait and cancels its timer, a deadline stops a run, a shell step gets the
; variables as ERGOPTI_VAR_ environment variables, an imported one runs
; nothing until approved, and the store refuses an invalid save. Also replays
; the workflow kind of the shared user action corpus through the gesture
; validator, and pins the run_workflow action and its single owner.
;
; ROOT CAUSE ENCODED:
; run_workflow had no Windows implementation: no action named it, nothing
; read workflows.json, and no Windows port performed a step.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Recording harness ===============
; ============================================
; ============================================

; A recording port: each call is kept with its arguments, then answered ok.
_TWFR_Record(World, Name) {
	return (Args*) => (World.Calls.Push(Map("name", Name, "args", Args)), Args[Args.Length].Call(true))
}

; An owner over recording ports and an in-memory config folder.
_TWFR_Harness(Files, Overrides := 0) {
	World := { Calls: [], Notices: [], Timers: [], Files: Files }
	Effects := Map()
	for Name in ["send_shortcut", "type_text", "open", "focus_app", "clipboard_set", "mouse_move", "mouse_click",
			"run_action", "notify"]
		Effects[Name] := _TWFR_Record(World, Name)
	Effects["clipboard_get"] := (Done) => (World.Calls.Push(Map("name", "clipboard_get", "args", [])), Done.Call(true, "clip"))
	Effects["after"] := _TWFR_After.Bind(World)
	Effects["shell"] := (Command, Env, Deadline, Done) => (World.Calls.Push(Map("name", "shell",
		"args", [Command, Env, Deadline])), Done.Call(true, "out"), 0)
	Effects["app_front"] := (App, Done) => Done.Call(true, App == "Front")
	if Overrides is Map
		for Name, Port in Overrides
			Effects[Name] := Port
	Owner := WorkflowOwner(Map(
		"store", Map("path", (Name) => "C:\cfg\" . Name, "read", (Path) => World.Files.Get(Path, 0),
			"write", (Path, Text) => World.Files[Path] := Text,
			"catalogue", WorkflowCatalogue(), "timings", Map("wait_max_ms", 600000)),
		"effects", WorkflowEffects(Effects), "after", Effects["after"],
		"translate", (Key) => "<" . Key . ">{1}|{2}|{3}|{4}",
		"notify", (Text) => World.Notices.Push(Text),
		"timeouts", Map("step_timeout_ms", 10, "screen_step_timeout_ms", 20, "shell_timeout_ms", 30,
			"wait_max_ms", 600000, "wait_for_poll_ms", 5)))
	return { Owner: Owner, World: World }
}

; A recorded timer: it fires only when the test says so.
_TWFR_After(World, Ms, Fn) {
	Timer := { Ms: Ms, Fn: Fn, Live: true }
	World.Timers.Push(Timer)
	return () => Timer.Live := false
}

; Fires the live recorded timers whose delay is Ms.
_TWFR_Fire(World, Ms) {
	for Timer in World.Timers.Clone()
		if Timer.Live && Timer.Ms == Ms {
			Timer.Live := false
			Timer.Fn.Call()
		}
}

; A workflows.json holding one workflow "wf_1" named Mine.
_TWFR_File(StepsJson, Origin := "local") {
	return Map("C:\cfg\workflows.json", '{"schema_version":1,"workflows":[{"id":"wf_1","name":"Mine","origin":"'
		. Origin . '","steps":' . StepsJson . '}]}')
}

_TWFR_Names(World) {
	Out := ""
	for Call in World.Calls
		Out .= (Out == "" ? "" : ",") . Call["name"]
	return Out
}




; ============================================
; ============================================
; ======= 2/ Owner ===========================
; ============================================
; ============================================

_TWFR_EveryStepReachesItsPort() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"send_keys","combo":"ctrl+a"},{"kind":"clipboard_get","into":"c"},'
		. '{"kind":"type_text","text":"<{{c}}>"},{"kind":"open","target_kind":"url","value":"https://x.invalid"},'
		. '{"kind":"focus_app","app":"A"},{"kind":"clipboard_set","text":"s"},{"kind":"mouse_move","x":1,"y":2},'
		. '{"kind":"mouse_click","x":3,"y":4},{"kind":"run_action","action":"select_all"},{"kind":"notify","text":"n"}]'))
	AssertTrue(H.Owner.RunAction(Map("id", "wf_1")), "run_workflow starts the workflow")
	AssertEqual("send_shortcut,clipboard_get,type_text,open,focus_app,clipboard_set,mouse_move,mouse_click,"
		. "run_action,notify", _TWFR_Names(H.World), "every step reaches its port, in order")
	AssertEqual("<clip>", H.World.Calls[3]["args"][1], "a step output is a variable of the next steps")
	AssertEqual("left", H.World.Calls[8]["args"][3], "a click defaults to the left button")
	AssertEqual(1, H.World.Calls[8]["args"][4], "a click defaults to one click")
	AssertEqual(0, H.World.Notices.Length, "a finished run tells nothing")
	AssertFalse(H.Owner.IsRunning(), "a finished run is no longer running")
}
Test("workflows: run_workflow runs every step through its Windows port (workflow-runner)", _TWFR_EveryStepReachesItsPort)

_TWFR_MissingAndInvalidAreTold() {
	H := _TWFR_Harness(Map())
	AssertFalse(H.Owner.RunAction(Map("id", "gone")), "a missing workflow does not run")
	AssertContains(H.World.Notices[1], "<workflows.notice.missing>gone", "a missing workflow is told")
	H.World.Files["C:\cfg\workflows.json"] := '{"schema_version":1,"workflows":[{"id":"a"}]}'
	AssertFalse(H.Owner.RunAction(Map("id", "a")), "an invalid file runs nothing")
	AssertContains(H.World.Notices[2], "<workflows.notice.file_invalid>missing_field|/workflows/0/name",
		"an invalid file is told with its reason and pointer")
	AssertFalse(H.Owner.RunAction(0), "a binding with no value runs nothing")
	AssertEqual(0, H.Owner.Choices(), "an invalid file offers no choice")
}
Test("workflows: a missing workflow and an invalid file are told (workflow-runner)", _TWFR_MissingAndInvalidAreTold)

_TWFR_FailureNamesItsStep() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"if","condition":{"type":"app_front","app":"Front"},'
		. '"then":[{"kind":"focus_app","app":"B"}]}]'), Map("focus_app", (App, Done) => Done.Call(false, "timeout")))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertEqual("<workflows.notice.failed>Mine|1 › ✓ 1|<workflows.step.focus_app>{1}|{2}|{3}|{4}|"
		. "<workflows.reason.timeout>{1}|{2}|{3}|{4}", H.World.Notices[1],
		"a failure names the workflow, the readable step path, its kind and the reason, once each")
}
Test("workflows: a failing step names the step, its kind and the reason (workflow-runner)", _TWFR_FailureNamesItsStep)

_TWFR_ScreenStepIsNamed() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"ocr","mode":"full","into":"t"}]'))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertContains(H.World.Notices[1], "<workflows.reason.screen_service_missing>",
		"a screen step without the screen services stops with its named reason")
	H := _TWFR_Harness(_TWFR_File('[{"kind":"if","condition":{"type":"visible","target":{"type":"text","text":"OK"}},'
		. '"then":[{"kind":"notify","text":"seen"}]}]'))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertContains(H.World.Notices[1], "<workflows.reason.screen_service_missing>",
		"the visible condition needs the screen services too")
	AssertEqual("", _TWFR_Names(H.World), "no later step runs")
}
Test("workflows: a screen step without the screen services is named (workflow-runner)", _TWFR_ScreenStepIsNamed)

_TWFR_EscapeStopsAWait() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"wait","duration_ms":5000},{"kind":"notify","text":"never"}]'))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertTrue(H.Owner.IsRunning("wf_1"), "a wait keeps the workflow running")
	AssertFalse(H.Owner.RunAction(Map("id", "wf_1")), "a second trigger of a running workflow is ignored")
	AssertEqual(1, H.Owner.AbortAll(), "Escape stops the running workflow")
	AssertFalse(H.Owner.IsRunning(), "nothing runs after Escape")
	for Timer in H.World.Timers
		AssertFalse(Timer.Live, "the wait and its deadline are cancelled")
	AssertContains(H.World.Notices[1], "<workflows.notice.aborted>Mine", "a stopped workflow is told")
	AssertEqual("", _TWFR_Names(H.World), "no step after the wait runs")
}
Test("workflows: Escape stops a wait at once (workflow-runner)", _TWFR_EscapeStopsAWait)

_TWFR_DeadlineStopsARun() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"type_text","text":"x"},{"kind":"notify","text":"never"}]'),
		Map("type_text", (Text, Done) => 0))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertTrue(H.Owner.IsRunning("wf_1"), "a step without an answer keeps the run pending")
	_TWFR_Fire(H.World, 10)
	AssertFalse(H.Owner.IsRunning(), "a step past its registry deadline ends the run")
	AssertContains(H.World.Notices[1], "<workflows.reason.timeout>", "the deadline is told as a timeout")
}
Test("workflows: a step past its deadline stops the run (workflow-runner)", _TWFR_DeadlineStopsARun)

_TWFR_ShellGetsItsEnvironment() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"set_variable","name":"who","value":"; del x"},'
		. '{"kind":"shell","command":"echo %ERGOPTI_VAR_who%","into":"out"},{"kind":"type_text","text":"{{out}}"}]'))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertEqual("shell", H.World.Calls[1]["name"], "a workflow the user made asks nothing")
	AssertEqual("echo %ERGOPTI_VAR_who%", H.World.Calls[1]["args"][1], "the command takes no placeholder")
	AssertEqual("; del x", H.World.Calls[1]["args"][2]["ERGOPTI_VAR_who"], "the variable is an environment variable")
	AssertEqual(30, H.World.Calls[1]["args"][3], "a shell step has the shell deadline")
	AssertEqual("out", H.World.Calls[2]["args"][1], "the output fills its variable")
	AssertFalse(H.World.Files.Has("C:\cfg\workflow_approvals.json"), "running writes no approval")
}
Test("workflows: a shell step runs with the variables in its environment (workflow-runner)", _TWFR_ShellGetsItsEnvironment)

_TWFR_ImportedShellWaitsForApproval() {
	H := _TWFR_Harness(_TWFR_File('[{"kind":"shell","command":"ver"}]', "import"))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertEqual(0, H.World.Calls.Length, "an imported shell step without approval runs nothing")
	AssertContains(H.World.Notices[1], "<workflows.reason.shell_not_approved>", "the refusal is told")
	Workflow := H.Owner.Store.Find("wf_1")
	H.Owner.Store.Approve("wf_1", WorkflowShellDigest(Workflow))
	H.Owner.RunAction(Map("id", "wf_1"))
	AssertEqual("shell", _TWFR_Names(H.World), "an approved import runs its shell step")
}
Test("workflows: an imported shell step runs only once approved (workflow-runner)", _TWFR_ImportedShellWaitsForApproval)

_TWFR_StoreRefusesAnInvalidSave() {
	H := _TWFR_Harness(Map())
	AssertFalse(H.Owner.Store.Save(JsonParseLossless('{"schema_version":1,"workflows":[{"id":"x y"}]}'), &Refusal),
		"an invalid document is not saved")
	AssertEqual("missing_field", Refusal["reason"], "the refusal is the model's")
	AssertFalse(H.World.Files.Has("C:\cfg\workflows.json"), "nothing reaches the disk")
	AssertTrue(H.Owner.Store.Save(JsonParseLossless(_TWFR_File("[]")["C:\cfg\workflows.json"])), "a valid one is")
	Choices := H.Owner.Choices()
	AssertEqual("wf_1", Choices[1]["value"], "a choice is the workflow id")
	AssertEqual("Mine", Choices[1]["label"], "its label is the workflow name")
	AssertEqual("1", WorkflowEnvironment(Map("a", "1"))["ERGOPTI_VAR_a"], "the environment names carry the prefix")
}
Test("workflows: the store refuses an invalid save and lists the choices (workflow-runner)", _TWFR_StoreRefusesAnInvalidSave)




; ============================================
; ============================================
; ======= 3/ Action and owner ================
; ============================================
; ============================================

_TWFR_ActionAndParameter() {
	global GESTURE_ACTIONS, _SharedDir
	AssertTrue(GESTURE_ACTIONS.Has("run_workflow"), "the gesture executor knows run_workflow")
	AssertEqual("workflow", GestureActionParameterSpec("run_workflow"), "run_workflow takes a workflow id")
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\action_parameters\user_action_vectors.json", "UTF-8"))
	Count := 0
	for Vector in Corpus["vectors"] {
		if Vector["kind"] != "workflow"
			continue
		Count += 1
		ErrorText := ""
		Valid := !Vector.Has("valid") || Vector["valid"]
		AssertEqual(Valid ? 1 : 0, GestureValidateActionParameter("run_workflow", Vector["value"], &ErrorText) ? 1 : 0,
			"workflow vector " . Vector["id"])
		if !Valid
			AssertTrue(ErrorText != "", "workflow vector " . Vector["id"] . " names its refusal")
	}
	AssertTrue(Count >= 10, "the corpus holds the workflow vectors, got " . Count)
	Refused := ""
	_WorkflowRunAction("run_command", (Ok, *) => Refused := Ok ? "ran" : "refused")
	AssertEqual("refused", Refused, "a workflow step cannot run a parameterised action")
}
Test("workflows: run_workflow is a Windows action with the shared parameter rule (workflow-runner)",
	_TWFR_ActionAndParameter)

_TWFR_OwnerIsBuiltOnce() {
	WorkflowsStop()
	Watched := []
	Overrides := Map("watch_escape", (Callback) => Watched.Push(Callback), "notify", (Text) => 0)
	try {
		Owner := WorkflowsInit(Overrides)
		AssertTrue(Owner == WorkflowsInit(), "a second plain call returns the same owner")
		AssertThrows(() => WorkflowsInit(Map()), "a second init with other ports raises")
		AssertEqual(1, Watched.Length, "Escape is watched once, by the owner")
		AssertEqual(0, WorkflowsAbortAll(), "nothing to stop when nothing runs")
		AssertFalse(WorkflowsOnEscape(), "Escape with no run stops nothing")
	} finally WorkflowsStop()
	AssertEqual(0, WorkflowsAbortAll(), "a stopped module holds no owner")
}
Test("workflows: the Windows owner is built once and released (workflow-runner)", _TWFR_OwnerIsBuiltOnce)
