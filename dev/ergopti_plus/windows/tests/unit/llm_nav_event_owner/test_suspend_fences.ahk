; tests/unit/llm_nav_event_owner/test_suspend_fences.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Suspend Fences
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_ExternalSuspendEnter(State) {
	State.EnterCalls += 1
	return false
}

_LNEO_ExternalSuspendResume(State) {
	State.ResumeCalls += 1
	return true
}

_LNEO_ExternalSuspendToggle(State, Value) {
	State.SuspendCalls.Push(Value)
}

_LNEO_ExternalSuspendIcon(State) {
	State.IconCalls += 1
}

_LNEO_ExternalSuspendRefusalRestoresRunningState() {
	global _LastSuspendState
	EnterBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	WatchdogBody := _DriverFuncBody("_SuspendStateWatchdog")
	HelperBody := _DriverFuncBodyOrEmpty(
		"_LLM_NavEventOwnerApplyExternalSuspendTransition")
	Barrier := InStr(EnterBody,
		'if !_LifecycleRunRequiredStep(Transition, "navigation-event"')
	NavCall := InStr(EnterBody,
		"_LifecycleSetNavEventOwnerSuspended(true)", , Max(1, Barrier))
	ReturnFalse := InStr(EnterBody, "return false", , Max(1, Barrier))
	FirstTeardown := InStr(EnterBody, "LLM_AuxInvalidate")
	Assert(Barrier > 0 and NavCall > Barrier and ReturnFalse > NavCall
		and FirstTeardown > ReturnFalse,
		"external suspend must record and reject a failed native owner boundary before any teardown")
	Assert(HelperBody != ""
		and InStr(WatchdogBody,
			"_LLM_NavEventOwnerApplyExternalSuspendTransition(") > 0,
		"the real watchdog must route external transitions through the tested rollback helper")
	SavedLast := IsSet(_LastSuspendState) ? _LastSuspendState : false
	State := {
		EnterCalls: 0, ResumeCalls: 0, SuspendCalls: [], IconCalls: 0
	}
	try {
		_LastSuspendState := false
		try TransitionResult := _LLM_NavEventOwnerApplyExternalSuspendTransition(true,
			_LNEO_ExternalSuspendEnter.Bind(State),
			_LNEO_ExternalSuspendResume.Bind(State),
			_LNEO_ExternalSuspendToggle.Bind(State),
			_LNEO_ExternalSuspendIcon.Bind(State))
		catch as Err
			Assert(false, "external transition helper raised: "
				. Err.Message . " | what=" . Err.What . " | " . Err.Stack)
		AssertFalse(TransitionResult,
			"a refused native boundary must reject the external suspend")
		AssertEqual(1, State.EnterCalls,
			"the external transition must attempt suspend teardown once")
		AssertEqual(0, State.ResumeCalls,
			"a refused enter must not run resume for teardown that never began")
		AssertEqual(1, State.SuspendCalls.Length,
			"the watchdog must issue one compensating native Suspend call")
		AssertEqual(0, State.SuspendCalls[1],
			"the compensating call must restore the running AHK state")
		AssertFalse(_LastSuspendState,
			"the watchdog state mirror must return to running")
		AssertEqual(2, State.IconCalls,
			"the tray icon must reflect both observed and restored states")
	} finally _LastSuspendState := SavedLast
}

Test("LLM nav event owner: refused external suspend restores running state before teardown",
	_LNEO_ExternalSuspendRefusalRestoresRunningState)

_LNEO_ExternalSuspendNeedsCompensation(State) {
	return true
}

_LNEO_ExternalSuspendPartialTeardownRunsResumeCompensation() {
	global _LastSuspendState
	SavedLast := IsSet(_LastSuspendState) ? _LastSuspendState : false
	State := {
		EnterCalls: 0, ResumeCalls: 0, SuspendCalls: [], IconCalls: 0
	}
	try {
		_LastSuspendState := false
		Result := _LLM_NavEventOwnerApplyExternalSuspendTransition(true,
			_LNEO_ExternalSuspendEnter.Bind(State),
			_LNEO_ExternalSuspendResume.Bind(State),
			_LNEO_ExternalSuspendToggle.Bind(State),
			_LNEO_ExternalSuspendIcon.Bind(State),
			_LNEO_ExternalSuspendNeedsCompensation.Bind(State))
		AssertFalse(Result,
			"a partial teardown remains a failed suspend transition")
		AssertEqual(1, State.SuspendCalls.Length,
			"partial teardown failure must lift native Suspend once")
		AssertEqual(0, State.SuspendCalls[1],
			"partial teardown compensation must restore native running state")
		AssertEqual(1, State.ResumeCalls,
			"partial teardown failure must run the resume reactor once")
		AssertFalse(_LastSuspendState,
			"compensated transition must leave the watchdog mirror running")
	} finally _LastSuspendState := SavedLast
}

Test("LLM nav event owner: partial external suspend teardown runs resume compensation",
	_LNEO_ExternalSuspendPartialTeardownRunsResumeCompensation)

_LNEO_CommitPlanAckCannotPublishAcrossRuntimeAba() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		State.CommitPlanReenterMode := "aba"
		AssertFalse(_LLM_NavEventOwnerRestartLifecyclePlan(Plan, State.Port),
			"an ACK from the retired runtime must not publish across Stop/Start ABA")
		AssertEqual(0, State.ReenterPrepareGeneration,
			"the recovery transaction must block a same-generation restart")
		AssertFalse(_LLM_NavEventOwnerStarted,
			"failed stale commit cleanup must leave one proved stopped boundary")
		AssertFalse(_LLM_NavEventOwnerCommittedPlan is Array,
			"the stale ACK must never resurrect a committed AHK plan")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"the exact plan must remain pending after stale ACK rejection")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"the recovery intent must retain the exact plan object")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"a later retry must start and commit the retained plan")
		AssertTrue(_LLM_NavEventOwnerStarted and State.Started,
			"the retry must publish one live native runtime")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array,
			"the final runtime must publish its own acknowledged plan")
		AssertEqual(ObjPtr(Plan), ObjPtr(_LLM_NavEventOwnerCommittedPlan),
			"the final commit must retain the exact intended plan")
		AssertEqual(2, State.StartCalls.Length,
			"only the initial and final proved runtimes may start")
		AssertEqual(2, State.PrepareCalls,
			"the blocked reentrant restart must never prepare a plan")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"only the stale and final generations may reach native commit")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: stale plan ACK cannot publish across runtime retirement",
	_LNEO_CommitPlanAckCannotPublishAcrossRuntimeAba)

_LNEO_StopFenceRejectsReentrantPlanPublication() {
	global _LLM_NavEventOwnerCommittedPlan
	State := _LNEO_Setup()
	try {
		PlanP := _LNEO_Plan()
		GenerationP := LLM_NavEventOwner_PreparePlan(PlanP, State.Port)
		AssertTrue(LLM_NavEventOwner_CommitPlan(GenerationP),
			"the fixture must begin with one live committed runtime plan")
		PlanQ := _LNEO_Plan()
		PlanQ[3]["route_marker"] := 103
		State.StopReenterPlan := PlanQ
		State.StopReenterMode := "plan"

		AssertTrue(LLM_NavEventOwner_Stop(),
			"the outer native Stop must still complete its acknowledged boundary")
		AssertEqual(0, State.StopReenterPrepareGeneration,
			"a plan must not prepare after native Stop ACK but before AHK reset")
		AssertFalse(State.StopReenterCommitStatus,
			"the stopped runtime must not acknowledge a reentrant plan commit")
		AssertFalse(_LLM_NavEventOwnerCommittedPlan is Array,
			"the stopped adapter must never publish a phantom committed plan")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: Stop fence rejects reentrant plan publication",
	_LNEO_StopFenceRejectsReentrantPlanPublication)

_LNEO_SuspendFallbackKeepsRestartFenceUntilResume() {
	global _LLM_NavEventOwnerCommittedPlan
	State := _LNEO_Setup()
	try {
		PlanP := _LNEO_Plan()
		GenerationP := LLM_NavEventOwner_PreparePlan(PlanP, State.Port)
		AssertTrue(LLM_NavEventOwner_CommitPlan(GenerationP),
			"the fixture must publish one exact pre-suspend plan")
		State.SuspendMode := "refuse"
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"a refused native suspend may fall back to one proved Stop")

		PlanQ := _LNEO_Plan()
		PlanQ[3]["route_marker"] := 203
		GenerationQ := LLM_NavEventOwner_PreparePlan(PlanQ, State.Port)
		CommitQ := GenerationQ > 0
			&& LLM_NavEventOwner_CommitPlan(GenerationQ)
		AssertEqual(0, GenerationQ,
			"no plan may restart the hook between quiesce and AHK Suspend")
		AssertFalse(CommitQ,
			"the suspended lifecycle fence must reject a replacement commit")
		AssertEqual(1, State.StartCalls.Length,
			"the blocked replacement must not create a second runtime")
		AssertEqual(1, State.PrepareCalls,
			"the blocked replacement must not cross the native prepare boundary")

		State.SuspendMode := "accept"
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must replay the retained exact plan and release the fence")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array,
			"resume must publish one acknowledged plan")
		AssertEqual(ObjPtr(PlanP), ObjPtr(_LLM_NavEventOwnerCommittedPlan),
			"resume must restore P, never the blocked replacement Q")
		AssertEqual(2, State.StartCalls.Length,
			"only the initial and resumed runtimes may start")
		AssertEqual(2, State.PrepareCalls,
			"only P may prepare once per proved runtime")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"only P may commit before suspend and after resume")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: suspend fallback fences restart until resume",
	_LNEO_SuspendFallbackKeepsRestartFenceUntilResume)

