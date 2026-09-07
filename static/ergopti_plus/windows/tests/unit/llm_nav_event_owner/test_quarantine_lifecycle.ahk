; tests/unit/llm_nav_event_owner/test_quarantine_lifecycle.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Quarantine Lifecycle
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_SwapCommitFailureQuarantinesAfterPublication() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	for CommitMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			B := _LNEO_Presentation("B", 6, Lifecycle)
			Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, B.Surface)
			AssertTrue(Transaction is Map,
				CommitMode . ": begin must return an abortable transition")
			AssertEqual(A.Token, State.CurrentToken,
				CommitMode . ": A remains native-current while the swap is fenced")
			_TooltipActiveSurface := B.Surface
			State.CommitSwapMode := CommitMode
			AssertFalse(LLM_NavEventOwner_CommitSurfaceSwap(Transaction),
				CommitMode . ": native swap commit failure must be visible")
			AssertEqual(1, State.StopCalls,
				CommitMode . ": post-publication failure must stop the owner once")
			AssertFalse(State.Started,
				CommitMode . ": the failed owner must be disabled fail-open")
			AssertFalse(State.StagedSwap is Map,
				CommitMode . ": stop must clear the unresolved native fence")
			AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
				CommitMode . ": stopped native state cannot retain stale owners")
			AssertEqual(ObjPtr(B.Surface), ObjPtr(_TooltipActiveSurface),
				CommitMode . ": quarantine must not roll the UI pointer back to A")
			Followup := LLM_NavEventOwner_BeginSurfaceSwap(B.Surface, 0)
			AssertTrue(Followup is Map && !Followup["native"],
				CommitMode . ": later UI swaps must not remain stuck behind the fence")
			AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Followup),
				CommitMode . ": fail-open UI ownership must remain usable")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: post-publication commit failure quarantines fail open",
	_LNEO_SwapCommitFailureQuarantinesAfterPublication)

_LNEO_TooltipHideContainsOwnerQuarantine() {
	global _LLM_NavEventOwnerQuarantined, _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerReportTimes, _TooltipActiveSurface
	for CommitMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			State.CommitSwapMode := CommitMode
			State.StopMode := "refuse"
			_LLM_NavEventOwnerReportTimes := Map()
			Failure := 0
			Result := "unset"
			try Result := TooltipHide("LLM", true, unset, A.Surface)
			catch Error as Err
				Failure := Err

			AssertFalse(IsObject(Failure),
				CommitMode . ": a proved fail-open quarantine must not escape the hide caller")
			AssertFalse(Result,
				CommitMode . ": a quarantined hide must return a contained false result")
			AssertFalse(IsObject(_TooltipActiveSurface),
				CommitMode . ": the quarantined hide must keep the already-retired pixels hidden")
			AssertTrue(_LLM_NavEventOwnerQuarantined,
				CommitMode . ": the native boundary must remain explicitly quarantined")
			AssertFalse(_LLM_NavEventOwnerStarted,
				CommitMode . ": AHK hotkey probes must stay fail-open after quarantine")
			AssertEqual(1, _LLM_NavEventOwnerReportTimes.Count,
				CommitMode . ": one failed hide boundary must publish one bounded diagnostic")
			Followup := LLM_NavEventOwner_BeginSurfaceSwap(0, 0)
			AssertTrue(Followup is Map && !Followup["native"],
				CommitMode . ": later UI teardown must remain available without the failed native owner")
			AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Followup),
				CommitMode . ": the contained fail-open path must remain usable")
		} finally {
			State.StopMode := "accept"
			SetTimer(_LLM_NavEventOwnerQuarantineNow, 0)
			_LNEO_Teardown()
		}
	}
}

Test("(ahk2-08-tooltip-hide-quarantine) real hide contains owner quarantine",
	_LNEO_TooltipHideContainsOwnerQuarantine)

_LNEO_CriticalCommitFailureDefersBlockingStop() {
	global _LLM_NavEventOwnerStarted, _TooltipActiveSurface
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		B := _LNEO_Presentation("B", 6, Lifecycle)
		Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
			A.Surface, B.Surface)
		_TooltipActiveSurface := B.Surface
		State.CommitSwapMode := "refuse"
		PreviousCritical := Critical("On")
		try {
			AssertFalse(LLM_NavEventOwner_CommitSurfaceSwap(Transaction),
				"post-publication refusal must remain visible under Critical")
			AssertFalse(_LLM_NavEventOwnerStarted,
				"quarantine must publish fail-open state synchronously")
			AssertEqual(0, State.StopCalls,
				"the Critical presentation path must never join the hook thread")
			SetTimer(_LLM_NavEventOwnerQuarantineNow, 0)
		} finally Critical(PreviousCritical)
		AssertTrue(_LLM_NavEventOwnerQuarantineNow(),
			"the deferred stop must complete after leaving Critical")
		AssertEqual(1, State.StopCalls,
			"deferred quarantine must stop the native owner exactly once")
		AssertFalse(State.StagedSwap is Map,
			"deferred stop must clear the unresolved native fence")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: Critical commit failure defers the blocking stop",
	_LNEO_CriticalCommitFailureDefersBlockingStop)

_LNEO_UnprovedQuarantineStopRetainsExactRecords() {
	global _LLM_NavEventOwnerQuarantined, _LLM_NavEventOwnerRecords
	global _TooltipActiveSurface
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		B := _LNEO_Presentation("B", 6, Lifecycle)
		Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
			A.Surface, B.Surface)
		_TooltipActiveSurface := B.Surface
		State.CommitSwapMode := "refuse"
		State.StopMode := "refuse"
		AssertFalse(LLM_NavEventOwner_CommitSurfaceSwap(Transaction),
			"unproved stop must keep the owner visibly quarantined")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"failed quarantine stop must retain an explicit unresolved state")
		AssertTrue(_LLM_NavEventOwnerRecords.Has(A.Token),
			"quarantine must retain exact old owner A")
		AssertTrue(_LLM_NavEventOwnerRecords.Has(B.Token),
			"quarantine must retain exact staged owner B")
		AssertFalse(LLM_NavEventOwner_SyncRecord(A.Record),
			"an unresolved quarantine must never certify stale AHK state")
		AssertFalse(LLM_NavEventOwner_ReleaseSurface(B.Surface),
			"disposal cannot collect B while native stop remains unproved")
		AssertTrue(_LLM_NavEventOwnerRecords.Has(B.Token),
			"unproved native state must keep B strongly reachable")
		FailedStopCalls := State.StopCalls
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"lifecycle must not treat an unresolved quarantine as a stopped hook")
		AssertEqual(FailedStopCalls + 1, State.StopCalls,
			"lifecycle must retry the unproved native stop exactly once")
		AssertEqual(0, State.SuspendCalls.Length,
			"quarantined state must never be certified by a skipped suspend call")
		AssertTrue(State.Started,
			"refused native stop must remain observable in the fake hook state")
		State.StopMode := "accept"
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"a later acknowledged stop must make the lifecycle transition safe")
		AssertEqual(FailedStopCalls + 2, State.StopCalls,
			"resolved quarantine must use one final bounded stop attempt")
		AssertFalse(_LLM_NavEventOwnerQuarantined,
			"successful stop must clear the unresolved-state latch")
		AssertFalse(State.Started,
			"successful stop must prove the native hook is no longer running")
		AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
			"successful stop may release all reset native owners")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: unproved quarantine stop retains exact records",
	_LNEO_UnprovedQuarantineStopRetainsExactRecords)

_LNEO_BeginFailureQuarantinesAmbiguousNativeOwner() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	for BeginMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			B := _LNEO_Presentation("B", 6, Lifecycle)
			State.BeginMode := BeginMode
			AssertFalse(LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, B.Surface),
				BeginMode . ": ambiguous native begin must be refused")
			AssertEqual(1, State.StopCalls,
				BeginMode . ": begin failure must quarantine the owner once")
			AssertFalse(State.Started,
				BeginMode . ": failed begin must disable native dispatch")
			AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
				BeginMode . ": successful quarantine stop must clear owner records")
			AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
				BeginMode . ": begin failure must leave the current UI owner unchanged")
			AssertFalse(ObjPtr(A.Surface) == ObjPtr(B.Surface),
				BeginMode . ": detached B must remain a distinct uncommitted candidate")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: begin refusal or throw quarantines ambiguity",
	_LNEO_BeginFailureQuarantinesAmbiguousNativeOwner)

_LNEO_AbortFailureQuarantinesWithoutDiscardingCandidate() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	for AbortMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			B := _LNEO_Presentation("B", 6, Lifecycle)
			Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, B.Surface)
			AssertTrue(Transaction is Map,
				AbortMode . ": begin must create an abortable native fence")
			State.AbortMode := AbortMode
			AssertFalse(LLM_NavEventOwner_AbortSurfaceSwap(Transaction),
				AbortMode . ": unproved abort must never report success")
			AssertEqual(1, State.StopCalls,
				AbortMode . ": unproved abort must stop the owner once")
			AssertFalse(State.Started,
				AbortMode . ": failed abort must quarantine native dispatch")
			AssertFalse(State.StagedSwap is Map,
				AbortMode . ": stop must clear the unresolved native fence")
			AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
				AbortMode . ": stopped native state cannot retain stale tokens")
			AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
				AbortMode . ": abort failure must not publish detached B")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: abort refusal or throw quarantines fail open",
	_LNEO_AbortFailureQuarantinesWithoutDiscardingCandidate)

_LNEO_LifecycleFailureStopsOrRefusesTransition() {
	global _LLM_NavEventOwnerStarted
	for SuspendMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			State.SuspendMode := SuspendMode
			AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
				SuspendMode . ": a successful stop must make suspend safe")
			AssertEqual(1, State.SuspendCalls.Length,
				SuspendMode . ": suspend boundary must be attempted once")
			AssertEqual(1, State.SuspendCalls[1],
				SuspendMode . ": lifecycle must request the suspended state")
			AssertEqual(1, State.StopCalls,
				SuspendMode . ": failed suspend must stop the hook once")
			AssertFalse(_LLM_NavEventOwnerStarted,
				SuspendMode . ": stopped hook must not remain published")
		} finally _LNEO_Teardown()
	}

	for StopMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			State.SuspendMode := "refuse"
			State.StopMode := StopMode
			AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
				StopMode . ": lifecycle must refuse when neither suspend nor stop is proven")
			AssertEqual(1, State.SuspendCalls.Length,
				StopMode . ": failed suspend must still be attempted exactly once")
			AssertEqual(1, State.StopCalls,
				StopMode . ": stop fallback must be attempted exactly once")
			AssertTrue(_LLM_NavEventOwnerStarted,
				StopMode . ": an unproved stop must not be published as complete")
			State.StopMode := "accept"
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: lifecycle failures stop safely or refuse suspend",
	_LNEO_LifecycleFailureStopsOrRefusesTransition)

_LNEO_PendingStopFinalizesAndRestartsExactPlan() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerPendingRepaints
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertEqual(_LNEO_PLAN_GENERATION, Generation,
			"setup must prepare the plan retained across drain timeout")
		AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the plan retained across drain timeout")
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1751
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		Decision := LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			Decision["disposition"],
			"setup must retain one already-suppressed receipt before Stop")

		State.SuspendMode := "refuse"
		State.StopModes := ["pending", "accept"]
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"a signaled but still-draining Stop cannot certify AHK suspension")
		AssertTrue(_LLM_NavEventOwnerStopPending,
			"the bridge must publish the exact post-signal recovery boundary")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"draining native state must remain visibly fail-open and retained")
		AssertFalse(_LLM_NavEventOwnerStarted,
			"a draining hook must not be advertised as accepting new owners")
		AssertTrue(State.Started && State.Suspended,
			"the fake native thread must remain present but fail-open while draining")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"the aborted suspend must retain the exact committed recovery plan")
		AssertEqual(ObjPtr(Plan), ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"pending recovery must not rebuild or clone the committed plan")
		AssertEqual(1, State.ReceiptQueue.Length,
			"pending Stop must retain the suppressed receipt for the service")
		AssertEqual(0, State.CompleteCalls.Length,
			"Stop itself must not acknowledge a receipt AHK has not applied")

		Probe := {Calls: [], Critical: [], Results: [0, 1]}
		Renderer := _LNEO_RenderAndPaintProbe.Bind(Probe)
		AssertTrue(LLM_NavEventOwner_Drain(Renderer),
			"the first recovery drain must acknowledge the exact receipt")
		AssertTrue(State.Completed.Has(Sequence),
			"the drain must apply and complete the retained receipt before join")
		AssertEqual(2, A.Record.ActiveIdx,
			"pending-stop recovery must preserve the exact committed target")
		AssertEqual(1, A.Surface.RenderedActiveIdx,
			"a refused repaint must leave the old pixels visibly authoritative")
		AssertEqual(1, _LLM_NavEventOwnerPendingRepaints.Count,
			"a refused repaint must remain an explicit recovery obligation")
		AssertFalse(_LLM_NavEventOwnerRecoverPendingStop(),
			"Stop finalization must wait for the acknowledged receipt's pixels")
		AssertEqual(1, State.StopCalls,
			"pixel debt must block the second native Stop before mutation")
		AssertTrue(_LLM_NavEventOwnerStopPending,
			"the native drain boundary must remain published until repaint")
		AssertTrue(LLM_NavEventOwner_Drain(Renderer),
			"the retained repaint must remain independently retryable")
		AssertEqual(2, A.Surface.RenderedActiveIdx,
			"a successful retry must converge pixels to the committed record")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"successful pixel publication must retire the repaint obligation")
		AssertEqual(1, State.CompleteCalls.Length,
			"repaint retry must never acknowledge the native receipt twice")
		AssertTrue(_LLM_NavEventOwnerRecoverPendingStop(),
			"only converged pixels may unlock final Stop and plan replay")
		AssertFalse(_LLM_NavEventOwnerStopPending,
			"converged recovery must finalize the native drain")
		AssertFalse(_LLM_NavEventOwnerQuarantined,
			"successful finalization must leave quarantine")
		AssertTrue(_LLM_NavEventOwnerStarted && State.Started,
			"the aborted suspend must restart the exact navigation owner")
		AssertFalse(State.Suspended,
			"the replacement owner must resume native dispatch")
		AssertEqual(2, State.StopCalls,
			"recovery must use one nonblocking Stop finalization retry")
		AssertEqual(2, State.StartCalls.Length,
			"recovery must start exactly one replacement hook")
		AssertEqual(2, State.PrepareCalls,
			"recovery must prepare the retained plan exactly once")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"recovery must commit the retained plan exactly once")
		AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
			"the replacement native plan must be the exact retained object")
		AssertTrue(A.Record.NavOwnerToken is Integer
				&& A.Record.NavOwnerToken > 0,
			"plan replay must attach a fresh native token to the visible record")
		AssertEqual(2, State.OwnerIndices.Get(A.Record.NavOwnerToken, 0),
			"replayed native ownership must inherit the converged painted index")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: pending Stop finalizes and restarts exact plan",
	_LNEO_PendingStopFinalizesAndRestartsExactPlan)

_LNEO_QuarantinePendingStopDoesNotInventResumeIntent() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleResumePlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the plan which quarantine must retire")
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1752
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port)["disposition"],
			"setup must retain one suppressed receipt before quarantine")

		State.StopModes := ["pending", "accept"]
		AssertFalse(_LLM_NavEventOwnerQuarantine(
			"Injected terminal quarantine"),
			"a quarantine boundary must remain visibly fail-open")
		AssertTrue(_LLM_NavEventOwnerStopPending,
			"the first Stop must retain its post-signal drain boundary")
		AssertFalse(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"terminal quarantine must not publish a lifecycle resume intent")

		Paint := {Calls: [], Critical: [], Results: [1]}
		_LLM_NavEventOwnerService(
			_LNEO_RenderAndPaintProbe.Bind(Paint))
		AssertTrue(State.Completed.Has(Sequence),
			"the watchdog must apply and acknowledge the retained receipt")
		AssertEqual(2, A.Record.ActiveIdx,
			"terminal drain must still apply the exact suppressed target")
		AssertEqual(2, A.Surface.RenderedActiveIdx,
			"terminal finalization must not erase an acknowledged repaint debt")
		AssertFalse(_LLM_NavEventOwnerStopPending,
			"the second Stop must finalize the drained native thread")
		AssertFalse(_LLM_NavEventOwnerStarted || State.Started,
			"terminal quarantine must remain stopped after finalization")
		AssertFalse(_LLM_NavEventOwnerQuarantined,
			"a proved final Stop must clear the visible quarantine flag")
		AssertFalse(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"finalization must not synthesize a retained plan from runtime state")
		AssertEqual(1, State.StartCalls.Length,
			"terminal recovery must not restart the hook")
		AssertEqual(1, State.PrepareCalls,
			"terminal recovery must not prepare the retired plan again")
		AssertEqual(1, State.CommitPlanCalls.Length,
			"terminal recovery must not recommit the retired plan")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"a later empty suspend boundary may complete as a no-op")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"a later empty resume boundary may complete as a no-op")
		AssertEqual(1, State.StartCalls.Length,
			"an unrelated lifecycle cycle must not resurrect quarantine")
		AssertEqual(1, State.PrepareCalls,
			"an unrelated lifecycle cycle must not recover a phantom plan")
		AssertEqual(1, State.CommitPlanCalls.Length,
			"an unrelated lifecycle cycle must not publish a phantom owner")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: quarantine drain stays terminal across lifecycle",
	_LNEO_QuarantinePendingStopDoesNotInventResumeIntent)

_LNEO_JoinedStopDiagnosticPublishesStoppedBoundary() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStopPending
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation))
		State.SuspendMode := "refuse"
		State.StopMode := "joined_error"

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"a joined thread with teardown diagnostic is still a proved Stop")
		AssertFalse(_LLM_NavEventOwnerStarted,
			"the adapter must publish the actually stopped runtime")
		AssertFalse(_LLM_NavEventOwnerStopPending,
			"joined teardown diagnostics must not invent an in-flight thread")
		AssertFalse(State.Started,
			"the fake native boundary must confirm the hook thread is absent")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must rebuild the retained plan after the diagnostic Stop")
		AssertTrue(_LLM_NavEventOwnerStarted && State.Started,
			"the retained plan must restore a real running boundary")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: joined Stop diagnostic is still stopped",
	_LNEO_JoinedStopDiagnosticPublishesStoppedBoundary)

_LNEO_ResumeFallbackRestartsCommittedPlan() {
	global _LLM_NavEventOwnerStarted
	for SuspendMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Plan := _LNEO_Plan()
			Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
			AssertEqual(_LNEO_PLAN_GENERATION, Generation,
				SuspendMode . ": setup must prepare the plan to recover")
			AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
				SuspendMode . ": setup must commit the plan to recover")
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)

			State.SuspendMode := SuspendMode
			AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
				SuspendMode . ": resume fallback must restart the stopped owner")
			AssertTrue(_LLM_NavEventOwnerStarted,
				SuspendMode . ": resumed navigation owner must be published")
			AssertTrue(State.Started,
				SuspendMode . ": native dispatch must be restarted after fallback")
			AssertEqual(2, State.StartCalls.Length,
				SuspendMode . ": recovery must start one replacement owner")
			AssertEqual(1, State.StopCalls,
				SuspendMode . ": recovery must stop the refused owner once")
			AssertEqual(2, State.PrepareCalls,
				SuspendMode . ": recovery must prepare the committed plan again")
			AssertEqual(2, State.CommitPlanCalls.Length,
				SuspendMode . ": recovery must commit the replacement generation")
			AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
				SuspendMode . ": recovery must reuse the exact committed plan")
			RecoveredToken := A.Record.NavOwnerToken
			AssertTrue(RecoveredToken is Integer && RecoveredToken > A.Token,
				SuspendMode . ": visible A must receive a fresh native owner token")
			Sequence := 1800 + State.SuspendCalls.Length
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence),
				_LNEO_Receipt(Sequence, RecoveredToken))
			Decision := LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port)
			AssertTrue(Decision is Map,
				SuspendMode . ": recovered dispatch must reach the native boundary")
			AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
				Decision["disposition"],
				SuspendMode . ": recovered navigation must suppress an owned digit")
			AssertEqual(1, Decision["receipt_created"],
				SuspendMode . ": recovered navigation must retain one exact receipt")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: resume fallback restarts committed plan",
	_LNEO_ResumeFallbackRestartsCommittedPlan)

_LNEO_SuspendStopRetainsExactResumePlan() {
	global _LLM_NavEventOwnerStarted
	for SuspendMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Plan := _LNEO_Plan()
			Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
			AssertEqual(_LNEO_PLAN_GENERATION, Generation,
				SuspendMode . ": setup must prepare the pre-suspend plan")
			AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
				SuspendMode . ": setup must commit the pre-suspend plan")
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)

			State.SuspendMode := SuspendMode
			AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
				SuspendMode . ": a proved Stop must make suspend safe")
			AssertFalse(_LLM_NavEventOwnerStarted,
				SuspendMode . ": suspend fallback must publish the stopped boundary")
			AssertFalse(State.Started,
				SuspendMode . ": native dispatch must be stopped while suspended")
			AssertEqual(1, State.StopCalls,
				SuspendMode . ": suspend fallback must stop exactly once")

			State.SuspendMode := "accept"
			AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
				SuspendMode . ": resume must consume the retained exact plan")
			AssertTrue(_LLM_NavEventOwnerStarted,
				SuspendMode . ": retained plan must republish the resumed owner")
			AssertTrue(State.Started,
				SuspendMode . ": retained plan must restart native dispatch")
			AssertEqual(2, State.StartCalls.Length,
				SuspendMode . ": resume must start exactly one replacement owner")
			AssertEqual(2, State.PrepareCalls,
				SuspendMode . ": resume must prepare the retained plan once")
			AssertEqual(2, State.CommitPlanCalls.Length,
				SuspendMode . ": resume must commit the replacement generation")
			AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
				SuspendMode . ": lifecycle Stop must retain the exact plan object")
			RecoveredToken := A.Record.NavOwnerToken
			AssertTrue(RecoveredToken is Integer && RecoveredToken > A.Token,
				SuspendMode . ": resumed A must receive a fresh native token")
			Sequence := 1900 + State.SuspendCalls.Length
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence),
				_LNEO_Receipt(Sequence, RecoveredToken))
			Decision := LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port)
			AssertTrue(Decision is Map,
				SuspendMode . ": resumed event must reach the replacement owner")
			AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
				Decision["disposition"],
				SuspendMode . ": resumed plan must own its physical digit")
			AssertEqual(1, Decision["receipt_created"],
				SuspendMode . ": resumed suppression must retain one receipt")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: suspend Stop retains exact resume plan",
	_LNEO_SuspendStopRetainsExactResumePlan)

_LNEO_ResumeRestartFailureIsVisibleAndRetryable() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerLifecycleResumePlan
	for FailurePhase in ["prepare", "commit"] {
		State := _LNEO_Setup()
		try {
			Plan := _LNEO_Plan()
			Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
			AssertEqual(_LNEO_PLAN_GENERATION, Generation,
				FailurePhase . ": setup must prepare the recoverable plan")
			AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
				FailurePhase . ": setup must commit the recoverable plan")
			State.SuspendMode := "refuse"
			if FailurePhase == "prepare"
				State.PrepareMode := "refuse"
			else
				State.CommitPlanMode := "refuse"

			AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(false),
				FailurePhase . ": an unproved restart must remain a visible failure")
			AssertFalse(_LLM_NavEventOwnerStarted,
				FailurePhase . ": failed restart must stop its fail-open hook")
			AssertFalse(State.Started,
				FailurePhase . ": fake native dispatch must be stopped after failure")
			AssertEqual(2, State.StopCalls,
				FailurePhase . ": fallback and failed-restart cleanup must each stop once")
			AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
				FailurePhase . ": exact resume intent must survive a failed retry")
			AssertEqual(ObjPtr(Plan),
				ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
				FailurePhase . ": retry intent must retain the exact committed plan")

			State.PrepareMode := "accept"
			State.CommitPlanMode := "accept"
			AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
				FailurePhase . ": a later lifecycle retry must restore the retained plan")
			AssertTrue(_LLM_NavEventOwnerStarted,
				FailurePhase . ": successful retry must republish native ownership")
			AssertTrue(State.Started,
				FailurePhase . ": successful retry must restart native dispatch")
			AssertEqual(3, State.StartCalls.Length,
				FailurePhase . ": retry must create only one final replacement owner")
			AssertFalse(_LLM_NavEventOwnerLifecycleResumePlan is Array,
				FailurePhase . ": successful retry must consume retained lifecycle intent")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: failed resume restart remains visible and retryable",
	_LNEO_ResumeRestartFailureIsVisibleAndRetryable)

_LNEO_ResumeCleanupRefusalRetainsRecoveryIntent() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerLifecycleResumePlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertEqual(_LNEO_PLAN_GENERATION, Generation,
			"setup must prepare the plan for composed resume failure")
		AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the plan for composed resume failure")
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)

		State.SuspendMode := "refuse"
		State.PrepareMode := "refuse"
		State.StopModes := ["accept", "refuse"]
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"a restart and cleanup refusal must remain a visible resume failure")
		AssertTrue(_LLM_NavEventOwnerStarted and State.Started,
			"refused cleanup must retain the observable fail-open hook boundary")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"resume intent must survive even when failed-restart cleanup refuses")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"the pending recovery must retain the exact committed plan")

		State.SuspendMode := "accept"
		State.PrepareMode := "accept"
		State.StopMode := "accept"
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"a later retry must first stop the pending hook and restore the plan")
		AssertEqual(3, State.StopCalls,
			"retry must prove one fresh Stop before starting the final owner")
		AssertEqual(3, State.StartCalls.Length,
			"retry must start only the failed and final replacement owners")
		AssertEqual(3, State.PrepareCalls,
			"retry must prepare the exact plan once after the clean boundary")
		AssertFalse(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"successful recovery must consume the pending lifecycle intent")
		RecoveredToken := A.Record.NavOwnerToken
		Sequence := 1950
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, RecoveredToken))
		Decision := LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port)
		AssertTrue(Decision is Map,
			"the recovered exact plan must reach native dispatch")
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			Decision["disposition"],
			"the recovered route must suppress its owned physical digit")
	} finally {
		State.StopMode := "accept"
		State.StopModes := []
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: composed resume cleanup failure retains exact recovery intent",
	_LNEO_ResumeCleanupRefusalRetainsRecoveryIntent)

_LNEO_StopPendingRecoveryPrecedesStartRollbackCleanup() {
	global _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleResumePlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the plan retained through composed rollback")
		State.SuspendMode := "refuse"
		State.StopModes := ["accept", "pending", "pending", "accept"]
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"the first proved Stop must establish the lifecycle pause")

		State.StartMode := "refuse"
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"pending rollback cleanup must keep resume visibly incomplete")
		AssertTrue(_LLM_NavEventOwnerStartRollbackPending,
			"the failed Start must retain its explicit rollback debt")
		AssertTrue(_LLM_NavEventOwnerStopPending,
			"post-signal Stop must remain the authoritative recovery boundary")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"composed rollback must retain the exact lifecycle plan")
		AssertEqual(ObjPtr(Plan),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"neither pending Stop may clone or replace the replay plan")

		State.StartMode := "accept"
		_LLM_NavEventOwnerService()
		AssertFalse(_LLM_NavEventOwnerStartRollbackPending
			|| _LLM_NavEventOwnerStopPending,
			"one service tick must retire both debts in authoritative order")
		AssertTrue(_LLM_NavEventOwnerStarted && State.Started,
			"service recovery must restart a real native owner")
		AssertEqual(3, State.StartCalls.Length,
			"recovery must include initial, failed, and final Start attempts")
		AssertEqual(4, State.StopCalls,
			"only the final post-signal Stop may precede replay")
		AssertEqual(2, State.PrepareCalls,
			"the exact plan must be prepared once initially and once on recovery")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"the exact plan must be committed once initially and once on recovery")
		AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
			"service recovery must replay the same plan object")
	} finally {
		State.StopMode := "accept"
		State.StopModes := []
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: StopPending recovery precedes Start rollback",
	_LNEO_StopPendingRecoveryPrecedesStartRollbackCleanup)

_LNEO_SuspendDisarmsAndResumeRearmsServiceTimer() {
	global _LLM_NavEventOwnerServiceArmed
	Helper := _DriverFuncBodyOrEmpty("_LLM_NavEventOwnerSetServiceTimer")
	Assert(Helper != ""
		and InStr(Helper,
			"SetTimer(_LLM_NavEventOwnerServiceFn, 100)") > 0
		and InStr(Helper,
			"SetTimer(_LLM_NavEventOwnerServiceFn, 0)") > 0,
		"the service timer helper must control the real repeating timer")
	State := _LNEO_Setup()
	try {
		AssertTrue(_LLM_NavEventOwnerSetServiceTimer(true),
			"test setup must arm the production watchdog")
		AssertTrue(_LLM_NavEventOwnerServiceArmed,
			"the running owner must publish its armed watchdog state")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"native suspend should remain a successful lifecycle boundary")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"a suspended owner must not poll while the application is paused")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"native resume should restore the live watchdog")
		AssertTrue(_LLM_NavEventOwnerServiceArmed,
			"a resumed owner must re-arm receipt recovery")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: suspend disarms and resume rearms the receipt watchdog",
	_LNEO_SuspendDisarmsAndResumeRearmsServiceTimer)

_LNEO_QuarantineStopCannotDestroyLifecycleFence() {
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResumePlan
	State := _LNEO_Setup()
	try {
		PlanP := _LNEO_Plan()
		GenerationP := LLM_NavEventOwner_PreparePlan(PlanP, State.Port)
		AssertTrue(GenerationP > 0
				&& LLM_NavEventOwner_CommitPlan(GenerationP),
			"setup must commit the exact plan retained during pause")
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("pause", 7, Lifecycle)
		_LNEO_Publish(0, A)
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"setup must publish the native pause fence")

		PreviousCritical := Critical("On")
		try _LLM_NavEventOwnerQuarantine(
			"Injected quarantine during lifecycle teardown")
		finally Critical(PreviousCritical)
		SetTimer(_LLM_NavEventOwnerQuarantineNow, 0)
		AssertTrue(_LLM_NavEventOwnerQuarantineNow(),
			"the deferred quarantine Stop must reach one proved native boundary")
		AssertTrue(_LLM_NavEventOwnerLifecycleQuiesced,
			"a nested Stop must not release the lifecycle fence it did not create")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array,
			"nested Stop must retain the exact committed resume plan")
		AssertEqual(ObjPtr(PlanP),
			ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan),
			"quarantine must retain the original plan object without rebuilding")

		PlanQ := _LNEO_Plan()
		PlanQ[3]["route_marker"] := 103
		AssertEqual(0, LLM_NavEventOwner_PreparePlan(PlanQ, State.Port),
			"no plan may restart the hook across the published pause fence")
		AssertEqual(1, State.StartCalls.Length,
			"paused admission must not start a replacement owner")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must replay the retained exact plan")
		AssertEqual(2, State.StartCalls.Length,
			"resume must start exactly one replacement hook")
		AssertEqual(2, State.PrepareCalls,
			"resume must prepare P once and must never prepare Q")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"resume must commit only the original and restored P generations")
		AssertEqual(ObjPtr(PlanP), ObjPtr(State.PreparedPlan),
			"the recovered native generation must use exact plan P")
	} finally {
		SetTimer(_LLM_NavEventOwnerQuarantineNow, 0)
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: quarantine Stop preserves lifecycle fence and plan",
	_LNEO_QuarantineStopCannotDestroyLifecycleFence)

