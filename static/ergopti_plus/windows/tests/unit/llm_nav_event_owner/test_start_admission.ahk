; tests/unit/llm_nav_event_owner/test_start_admission.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Start Admission
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 4/ Fail-open and lifecycle =======
; ==========================================
; ==========================================

_LNEO_DispatchRefusalAndThrowDoNotClaimInput() {
	State := _LNEO_Setup()
	try {
		Event := _LNEO_DigitSevenEvent()
		for DispatchMode in ["refuse", "throw"] {
			State.DispatchMode := DispatchMode
			Result := LLM_NavEventOwner_TestDispatch(Event, State.Port)
			AssertEqual(0, Result,
				DispatchMode . ": a failed native test decision must not claim suppression")
			AssertEqual(0, State.ReceiptQueue.Length,
				DispatchMode . ": fail-open dispatch must not publish a receipt")
		}
		State.DispatchMode := "accept"
		PassResult := Map(
			"disposition", _LNEO_DISPOSITION_PASS,
			"receipt_created", 0, "route_idx", 0, "seq", 0)
		_LNEO_QueueNativeDecision(State, PassResult)
		Result := LLM_NavEventOwner_TestDispatch(Event, State.Port)
		AssertEqual(_LNEO_DISPOSITION_PASS, Result["disposition"],
			"an explicit native PASS must cross the bridge unchanged")
		AssertEqual(0, Result["receipt_created"],
			"native pass-through must never manufacture a receipt")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: native dispatch refusal and throw fail open",
	_LNEO_DispatchRefusalAndThrowDoNotClaimInput)

_LNEO_StartRefusalDoesNotPublishOwner() {
	global _LLM_NavEventOwnerStarted
	try LLM_NavEventOwner_Stop()
	for StartMode in ["refuse", "throw"] {
		State := _LNEO_NewNativeState()
		State.StartMode := StartMode
		AssertFalse(LLM_NavEventOwner_EnsureStarted(State.Port),
			StartMode . ": a refused native hook start must fail closed")
		AssertFalse(_LLM_NavEventOwnerStarted,
			StartMode . ": a failed start must not publish an active owner")
		AssertEqual(1, State.StartCalls.Length,
			StartMode . ": native start must be attempted exactly once")
		AssertEqual(1, State.StopCalls,
			StartMode . ": failed start must run one bounded native rollback")
		LLM_NavEventOwner_Stop()
	}
}

Test("LLM nav event owner: hook installation refusal never publishes ownership",
	_LNEO_StartRefusalDoesNotPublishOwner)

_LNEO_StartAckCannotCrossStopOrLifecycleFence() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerLifecycleQuiesced
	for ReenterMode in ["stop", "quiesce"] {
		_LNEO_Teardown()
		State := _LNEO_NewNativeState()
		State.StartReenterMode := ReenterMode
		try {
			AssertFalse(LLM_NavEventOwner_EnsureStarted(State.Port),
				ReenterMode . ": an invalidated Start ACK must roll back")
			AssertFalse(State.StartReenterResult,
				ReenterMode . ": the competing transition cannot certify an in-flight Start")
			AssertFalse(_LLM_NavEventOwnerStarted || State.Started,
				ReenterMode . ": neither bridge nor port may retain a phantom runtime")
			AssertFalse(_LLM_NavEventOwnerStarting,
				ReenterMode . ": the completed rollback must release the start latch")
			AssertFalse(_LLM_NavEventOwnerStartRollbackPending,
				ReenterMode . ": acknowledged rollback must leave no retry debt")
			AssertFalse(_LLM_NavEventOwnerLifecycleQuiesced,
				ReenterMode . ": a refused concurrent lifecycle must release its fence")
			AssertEqual(1, State.StopCalls,
				ReenterMode . ": exact native rollback must run once after the ACK")
		} finally {
			State.StopMode := "accept"
			_LNEO_Teardown()
		}
	}
}

Test("LLM nav event owner: Start ACK cannot cross Stop or lifecycle fence",
	_LNEO_StartAckCannotCrossStopOrLifecycleFence)

_LNEO_LifecycleReplayCannotCrossRawSuspend() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	WasSuspended := A_IsSuspended
	_LNEO_Teardown()
	try {
		Plan := _LNEO_Plan()
		State := _LNEO_NewNativeState()
		_LLM_NavEventOwnerLifecycleQuiesced := true
		_LLM_NavEventOwnerLifecycleResumePlan := Plan
		_LLM_NavEventOwnerLifecycleResumePort := State.Port
		Suspend(1)
		AssertFalse(_LLM_NavEventOwnerRestartLifecyclePlan(
			Plan, State.Port),
			"a replay request must fail open while AHK is already suspended")
		AssertEqual(0, State.StartCalls.Length,
			"suspended admission must refuse before starting a native thread")
		AssertFalse(_LLM_NavEventOwnerStarted || State.Started,
			"a refused suspended replay must leave no native owner")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"suspended admission must retain the exact replay plan")

		Suspend(0)
		State := _LNEO_NewNativeState()
		Plan := _LNEO_Plan()
		_LLM_NavEventOwnerLifecycleQuiesced := true
		_LLM_NavEventOwnerLifecycleResumePlan := Plan
		_LLM_NavEventOwnerLifecycleResumePort := State.Port
		State.StartReenterMode := "suspend"
		AssertFalse(LLM_NavEventOwner_EnsureStarted(State.Port, true),
			"a raw suspend after native Start ACK must invalidate publication")
		AssertTrue(State.StartReenterResult && A_IsSuspended,
			"the seam must prove suspension won after the native ACK")
		AssertFalse(_LLM_NavEventOwnerStarted || State.Started,
			"invalidated startup must roll the acknowledged native thread back")
		AssertEqual(1, State.StopCalls,
			"post-ACK suspension must perform one bounded native rollback")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"lifecycle startup rollback must preserve the exact retry plan")
	} finally {
		if !WasSuspended
			Suspend(0)
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: lifecycle replay cannot cross raw Suspend",
	_LNEO_LifecycleReplayCannotCrossRawSuspend)

_LNEO_LifecycleReplayOwnsTransactionAndKeepsTerminalOwnerDetached() {
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerRecords
	global _TooltipActiveSurface
	_LNEO_Teardown()
	State := _LNEO_NewNativeState()
	try {
		Plan := _LNEO_Plan()
		State.CommitPlanReenterMode := "quiesce"
		AssertTrue(_LLM_NavEventOwnerRestartLifecyclePlan(Plan, State.Port),
			"the exact replay should commit while it owns the recovery transaction")
		AssertFalse(State.CommitPlanReenterResult,
			"a competing lifecycle transition must not cross an in-flight replay")
		AssertFalse(_LLM_NavEventOwnerPendingStopRecovery,
			"successful replay must release its recovery transaction")
		AssertFalse(_LLM_NavEventOwnerLifecycleQuiesced,
			"a refused competing pause must not leave a lifecycle fence")

		AssertTrue(LLM_NavEventOwner_Stop(false, true),
			"the first replay owner must stop before terminal-owner recovery")
		Lifecycle := _LNEO_Lifecycle(901)
		Lifecycle.Outcome := "claimed"
		Candidate := _LNEO_Presentation("terminal", 7, Lifecycle)
		_TooltipActiveSurface := Candidate.Surface
		AssertTrue(LLM_NavEventOwner_Stop(false, true),
			"the terminal fixture must retain only its visible AHK surface")
		State := _LNEO_NewNativeState()
		Plan := _LNEO_Plan()
		AssertTrue(_LLM_NavEventOwnerRestartLifecyclePlan(Plan, State.Port),
			"plan recovery may succeed without re-owning accepted pixels")
		AssertEqual(0, State.CurrentToken,
			"a terminal prediction must remain natively detached after replay")
		AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
			"terminal pixels must not recreate a retained native owner record")
		AssertEqual("claimed", Lifecycle.Outcome,
			"replay must not reopen or replace the terminal lifecycle")
		AssertFalse(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"successful detached replay must consume only its plan intent")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: lifecycle replay is exclusive and preserves terminal detachment",
	_LNEO_LifecycleReplayOwnsTransactionAndKeepsTerminalOwnerDetached)

_LNEO_ResumeAckCannotCrossNewSuspendEnter() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerServiceArmed
	WasSuspended := A_IsSuspended
	_LNEO_Teardown()
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the plan retained across a lost resume race")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"setup must establish a proved suspended native owner")
		State.SuspendReenterMode := "enter_then_ahk_suspend"
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"a new raw Suspend must invalidate the in-flight resume ACK")
		AssertFalse(State.SuspendReenterResult,
			"Suspend-enter must not reuse the resume transaction's old fence")
		AssertTrue(A_IsSuspended,
			"the seam must prove raw AHK suspension won during native resume")
		AssertTrue(!State.Started || State.Suspended,
			"AHK suspension must never coexist with an unsuspended native owner")
		AssertFalse(_LLM_NavEventOwnerStarted,
			"the invalidated resume must stop the ambiguous native runtime")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"the invalidated resume must retain its exact plan intent")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"resume invalidation must not clone or replace the plan")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"an invalidated resume must not leave the receipt timer armed")
	} finally {
		if !WasSuspended
			Suspend(0)
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: resume ACK cannot cross a new Suspend enter (nav-owner-resume-race)",
	_LNEO_ResumeAckCannotCrossNewSuspendEnter)

_LNEO_CommitSuspendRollbackMustProveFailOpenBoundary() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerServiceArmed
	WasSuspended := A_IsSuspended
	for StopMode in ["refuse", "throw"] {
		_LNEO_Teardown()
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle(902)
			A := _LNEO_Presentation("commit-suspend", 7, Lifecycle)
			_LNEO_Publish(0, A)
			Plan := _LNEO_Plan()
			Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
			AssertTrue(Generation > 0,
				StopMode . ": setup must prepare the post-ACK plan")
			State.CommitPlanReenterMode := "suspend"
			State.StopMode := StopMode
			AssertFalse(LLM_NavEventOwner_CommitPlan(Generation),
				StopMode . ": raw Suspend must invalidate the native commit ACK")
			AssertTrue(A_IsSuspended,
				StopMode . ": the seam must prove AHK pause won after ACK")
			AssertEqual(A.Token, State.CurrentToken,
				StopMode . ": the repro must retain a real native surface owner")
			AssertTrue(!State.Started || State.Suspended,
				StopMode . ": failed Stop must still prove native fail-open suspension")
			AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
				StopMode . ": ambiguous commit cleanup must retain the exact plan")
			AssertEqual(ObjPtr(Plan),
				ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
				StopMode . ": cleanup must not clone or replace retry intent")
			AssertFalse(_LLM_NavEventOwnerServiceArmed,
				StopMode . ": no receipt timer may run under AHK suspension")
		} finally {
			if !WasSuspended
				Suspend(0)
			State.StopMode := "accept"
			_LNEO_Teardown()
		}
	}
}

Test("LLM nav event owner: commit Suspend rollback proves fail-open boundary (nav-owner-commit-suspend-rollback)",
	_LNEO_CommitSuspendRollbackMustProveFailOpenBoundary)

_LNEO_StartPublicationCannotOutliveReentrantStop() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerRecords
	global _LLM_NavEventOwnerServiceArmed
	global _LLM_NavEventOwnerWakeFn, _LLM_NavEventOwnerServiceFn
	global _TooltipActiveSurface
	_LNEO_Teardown()
	State := _LNEO_NewNativeState()
	Lifecycle := _LNEO_Lifecycle()
	Candidate := _LNEO_Presentation("startup", 7, Lifecycle)
	_TooltipActiveSurface := Candidate.Surface
	State.BeginReenterMode := "stop"
	try {
		AssertFalse(LLM_NavEventOwner_EnsureStarted(State.Port),
			"Stop during current-surface publication must invalidate Start")
		AssertFalse(State.BeginReenterResult,
			"the nested Stop must cancel rather than cross the start ticket")
		AssertFalse(_LLM_NavEventOwnerStarted || State.Started,
			"rollback must not publish an acknowledged but stopped runtime")
		AssertEqual(1, State.StopCalls,
			"publication invalidation must retire the native owner exactly once")
		AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
			"rollback must release every candidate owner record")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"rollback must not leave the receipt watchdog armed")
		AssertFalse(IsObject(_LLM_NavEventOwnerWakeFn)
				|| IsObject(_LLM_NavEventOwnerServiceFn),
			"rollback must disconnect every startup callback")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: startup publication cannot outlive reentrant Stop",
	_LNEO_StartPublicationCannotOutliveReentrantStop)
