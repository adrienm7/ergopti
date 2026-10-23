; tests/fixtures/external_suspend_program_owner_body.ahk

; ==============================================================================
; MODULE: External Suspend Program Ownership Child
; DESCRIPTION:
; The refused case calls the real suspend reactor. Other cases are explicit
; transition controls over real ProgramActions_Stop and navigation preflight;
; they do not simulate a complete driver resume, native hook or program launch.
; ==============================================================================

#Requires AutoHotkey v2.0

_ESPO_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_ESPO_Icon(World) {
	World.Icons += 1
}

_ESPO_Suspend(World, Value) {
	World.SuspendCalls += 1
	Suspend(Value)
}

_ESPO_ResumePrograms(World) {
	World.Resumes += 1
	return ProgramActions_Stop(false)
}

_ESPO_RealEnter(World) {
	World.Enters += 1
	return Ergopti_OnSuspendEnter()
}

; These controls deliberately exercise the ledger, not a copied Enter body.
_ESPO_ControlEnter(World) {
	World.Enters += 1
	Transition := LifecycleTransitionBegin("suspend")
	if World.Mode != "preflight" {
		_LifecycleRunRequiredStep(Transition, "user-programs", ProgramActions_Stop.Bind(true), true)
		LifecycleTransitionMarkStarted(Transition)
	}
	_LifecycleRunRequiredStep(Transition, "navigation-event",
		_LifecycleSetNavEventOwnerSuspended.Bind(true), true)
	return LifecycleTransitionFinish(Transition)
}

_ESPO_Log(World, Line) {
	World.Logs += 1
}

_ESPO_Main() {
	global ConfigurationFile, GestureAssignments, GestureActionParameters
	global KeyboardShortcutAssignments, ScriptShortcutAssignments, TapKeyAssignments
	global _UserProgramPaused, _UserProgramGeneration, _UserProgramEntries, _UserProgramAcquiring, _UserProgramPollOwner
	global _LLM_NavEventOwnerProfileEffectActive, _LastSuspendState
	_ESPO_Require(A_Args.Length == 2, "the private child requires exactly two arguments")
	Mode := A_Args[1], Directory := A_Args[2]
	_ESPO_Require(Mode == "refused" || Mode == "preflight" || Mode == "partial" || Mode == "nominal",
		"the authored mode must be known")
	World := { Mode: Mode, Enters: 0, Resumes: 0, SuspendCalls: 0, Icons: 0, Logs: 0 }
	ConfigurationFile := Directory . "\configuration.toml"
	Scalar := '{"version":1,"executable":' . JsonStringLiteral(A_AhkPath) . ',"arguments":[]}'
	GestureAssignments := Map("tap_3", "run_program")
	GestureActionParameters := Map("gesture__tap_3__run_program", Scalar)
	KeyboardShortcutAssignments := Map(), ScriptShortcutAssignments := Map(), TapKeyAssignments := Map()
	Content := '[gestures]`ntap_3 = "run_program"`n[action_parameters]`n'
		. '"gesture__tap_3__run_program" = ' . JsonStringLiteral(Scalar) . "`n"
	_ESPO_Require(FSWriteCreateDurable(ConfigurationFile, Content) == 1,
		"the program assignment must have a real exclusive durable source")
	_ESPO_Require(!A_IsSuspended && !_UserProgramPaused, "the private program owner starts active")
	_ESPO_Require(!IsObject(_UserProgramAcquiring) && !IsObject(_UserProgramPollOwner)
		&& _UserProgramEntries.Count == 0, "no native program or timer can be borrowed")
	Before := _ProgramActions_Snapshot("gesture__tap_3")
	_ESPO_Require(Before is Map && _ProgramActions_Admitted(Before),
		"real canonical file and parameter decoding must admit the initial program")
	LoggerSetTestSink(_ESPO_Log.Bind(World))
	; A real in-flight profile-effect boundary is an existing native-owner
	; refusal state. No DLL, hook, timer or synthetic native handle is installed.
	_LLM_NavEventOwnerProfileEffectActive := Mode != "nominal"
	_LastSuspendState := false
	InitialGeneration := _UserProgramGeneration
	Primary := 0
	try {
		Suspend(true)
		_ESPO_Require(A_IsSuspended, "the external native pause must precede the watchdog helper")
		Enter := Mode == "refused" ? _ESPO_RealEnter.Bind(World) : _ESPO_ControlEnter.Bind(World)
		Result := _LLM_NavEventOwnerApplyExternalSuspendTransition(true,
			Enter, _ESPO_ResumePrograms.Bind(World), _ESPO_Suspend.Bind(World),
			_ESPO_Icon.Bind(World), LifecycleTransitionNeedsCompensation.Bind("suspend"))
		if Mode == "nominal" {
			_ESPO_Require(Result && A_IsSuspended && _LastSuspendState && _UserProgramPaused,
				"a successful transition retains the actual program pause until resume")
			_ESPO_Require(!_ProgramActions_Snapshot("gesture__tap_3"),
				"the genuine program snapshot must refuse while paused")
			Suspend(false)
			Result := _LLM_NavEventOwnerApplyExternalSuspendTransition(false,
				Enter, _ESPO_ResumePrograms.Bind(World), _ESPO_Suspend.Bind(World), _ESPO_Icon.Bind(World))
			_ESPO_Require(Result && World.Resumes == 1, "nominal resume runs the real program release once")
		} else {
			_ESPO_Require(!Result, "a navigation refusal cannot report successful suspension")
		}
		After := _ProgramActions_Snapshot("gesture__tap_3")
		Admitted := After is Map && _ProgramActions_Admitted(After)
		Debt := LifecycleTransitionDebtSnapshot("suspend")
		FileAppend("RECEIPT external-suspend-program " . Mode
			. " native_suspended=" . A_IsSuspended . " mirror=" . _LastSuspendState
			. " program_paused=" . _UserProgramPaused . " program_admitted=" . Admitted
			. " generation_delta=" . (_UserProgramGeneration - InitialGeneration)
			. " enters=" . World.Enters . " resumes=" . World.Resumes
			. " suspend_calls=" . World.SuspendCalls . " icons=" . World.Icons
			. " debt=" . Debt.Length . " entries=" . _UserProgramEntries.Count . "`n", "*")
		_ESPO_Require(!A_IsSuspended && !_LastSuspendState,
			"a refused or resumed transition leaves native and watchdog states active")
		_ESPO_Require(!_UserProgramPaused && Admitted,
			"a rejected external pause must not strand the actual program pause latch")
		_ESPO_Require(World.Enters == 1, "the selected transition enters once")
		if Mode == "partial"
			_ESPO_Require(World.Resumes == 1, "partial teardown must compensate its actual program owner")
		if Mode == "preflight"
			_ESPO_Require(World.Resumes == 0, "a pure administrative refusal requires no fabricated teardown")
		if Mode != "nominal"
			_ESPO_Require(Debt.Length == 1 && Debt[1].owner == "navigation-event",
				"the failed transition retains exactly its navigation-owner debt")
		_ESPO_Require(FSReadUtf8Exact(ConfigurationFile) == Before["source"],
			"transition handling cannot alter the actual program source")
	} catch as Failure {
		Primary := Failure
	} finally {
		Suspend(false)
		_LLM_NavEventOwnerProfileEffectActive := false
		try {
			_ESPO_Require(ProgramActions_Stop(false) == 1 && _UserProgramEntries.Count == 0
				&& !IsObject(_UserProgramPollOwner) && !IsObject(_UserProgramAcquiring),
				"the private child must leave no program or timer owner")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally LoggerClearTestSink()
	}
	if IsObject(Primary)
		throw Primary
}

try {
	_ESPO_Main()
	FileAppend("PASS external-suspend-program " . A_Args[1] . "`n", "*")
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL external-suspend-program type=" . Type(Failure) . " line=" . Failure.Line
		. " reason=" . Failure.Message . "`n", "*")
	ExitApp(1)
}
