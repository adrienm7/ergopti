; tests/unit/llm_nav_event_owner/test_health_recovery.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Health Recovery
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_NativeMaskFailureWakeRestartsExactPlan() {
	global _LLM_NavEventOwnerCommittedPlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must publish the exact plan owned before the native health fault")
		State.LastOsError := 5
		State.Suspended := true

		_LLM_NavEventOwnerOnWake()

		AssertEqual(1, State.LastErrorCalls,
			"the native wake must read the observable Win32 health code once")
		AssertEqual(1, State.StopCalls,
			"the failed camouflage boundary must stop the suspended native runtime")
		AssertEqual(2, State.StartCalls.Length,
			"health recovery must start exactly one replacement runtime")
		AssertEqual(2, State.PrepareCalls,
			"health recovery must prepare the retained plan exactly once")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"health recovery must commit the retained plan exactly once")
		AssertTrue(State.Started,
			"health recovery must leave a real fake-native runtime started")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array
				&& ObjPtr(_LLM_NavEventOwnerCommittedPlan) == ObjPtr(Plan),
			"health recovery must republish the exact original plan object")
		AssertEqual(0, State.LastOsError,
			"the acknowledged Stop must clear the consumed native error")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: native menu-mask fault restarts exact plan (ahk026-native-mask-health-recovery)",
	_LNEO_NativeMaskFailureWakeRestartsExactPlan)

_LNEO_NativeMaskFailureWatchdogRestartsExactPlan() {
	global _LLM_NavEventOwnerCommittedPlan
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must publish the exact plan owned before a lost native wake")
		State.LastOsError := 5
		State.Suspended := true

		_LLM_NavEventOwnerService()

		AssertEqual(1, State.LastErrorCalls,
			"the periodic watchdog must read native health when the wake message is lost")
		AssertEqual(1, State.StopCalls,
			"watchdog health recovery must stop the failed runtime once")
		AssertEqual(2, State.StartCalls.Length,
			"watchdog health recovery must start one replacement runtime")
		AssertTrue(State.Started && !State.Suspended,
			"watchdog health recovery must leave one running fake-native owner")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array
				&& ObjPtr(_LLM_NavEventOwnerCommittedPlan) == ObjPtr(Plan),
			"watchdog health recovery must republish the exact original plan")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: lost mask-fault wake is recovered by watchdog (ahk026-native-mask-health-watchdog)",
	_LNEO_NativeMaskFailureWatchdogRestartsExactPlan)

_LNEO_NativeMaskFailureRefusedStopRetainsExactPlan() {
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must publish the exact plan retained across a refused health stop")
		State.LastOsError := 5
		State.Suspended := true
		State.StopMode := "refuse"

		_LLM_NavEventOwnerOnWake()

		AssertEqual(1, State.LastErrorCalls,
			"the health wake must consume the native fault exactly once")
		AssertEqual(1, State.StopCalls,
			"the first recovery boundary must attempt exactly one native Stop")
		AssertEqual(1, State.StartCalls.Length,
			"a refused Stop must not start a replacement beside the old runtime")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"an unacknowledged health Stop must remain visibly quarantined")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array
				&& ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan) == ObjPtr(Plan),
			"the refused Stop must retain the exact pre-fault plan object")

		State.StopMode := "accept"
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
		_LLM_NavEventOwnerService()

		AssertEqual(2, State.StopCalls,
			"the service watchdog must retry the unproved health Stop")
		AssertEqual(2, State.StartCalls.Length,
			"an acknowledged retry must start exactly one replacement runtime")
		AssertEqual(2, State.PrepareCalls,
			"the retry must prepare the retained plan exactly once")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"the retry must commit the retained plan exactly once")
		AssertTrue(State.Started && !_LLM_NavEventOwnerQuarantined,
			"the acknowledged retry must publish one healthy runtime")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array
				&& ObjPtr(_LLM_NavEventOwnerCommittedPlan) == ObjPtr(Plan),
			"the retry must republish the exact original plan object")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: refused health Stop retains exact recovery intent (ahk026-native-mask-health-stop-retry)",
	_LNEO_NativeMaskFailureRefusedStopRetainsExactPlan)

_LNEO_NativeMaskFailureDuringPauseNeverUnsuspendsFaultyRuntime() {
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must publish the exact plan owned before pause")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"setup must establish the native lifecycle pause fence")
		State.LastOsError := 5
		State.Suspended := true
		State.StopMode := "refuse"

		_LLM_NavEventOwnerOnWake()

		AssertEqual(1, State.LastErrorCalls,
			"a queued native fault wake must remain observable during lifecycle pause")
		AssertEqual(1, State.StopCalls,
			"paused health recovery must attempt one bounded Stop")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"a refused paused Stop must remain explicitly quarantined")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array
				&& ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan) == ObjPtr(Plan),
			"paused health recovery must retain the exact committed plan")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must hand the quarantined runtime to its retained service")
		AssertEqual(1, State.SuspendCalls.Length,
			"resume must never emit native suspend(0) toward a faulted runtime")
		AssertEqual(1, State.SuspendCalls[1],
			"the sole native suspend call must be the original pause boundary")

		State.StopMode := "accept"
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
		_LLM_NavEventOwnerService()

		AssertEqual(2, State.StopCalls,
			"the resumed service must retry the unproved paused Stop")
		AssertEqual(2, State.StartCalls.Length,
			"only the acknowledged Stop may start one replacement runtime")
		AssertTrue(State.Started && !State.Suspended,
			"the replacement runtime must be genuinely running and unsuspended")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array
				&& ObjPtr(_LLM_NavEventOwnerCommittedPlan) == ObjPtr(Plan),
			"pause recovery must republish the exact original plan")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: paused mask fault never unsuspends failed runtime (ahk026-native-mask-health-pause)",
	_LNEO_NativeMaskFailureDuringPauseNeverUnsuspendsFaultyRuntime)

_LNEO_NativeMaskFailureDuringResumeRetainsExactPlan() {
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must publish the exact plan owned before resume")
		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"setup must establish the native lifecycle pause fence")
		State.StopMode := "refuse"
		State.SuspendReenterMode := "health_wake"

		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must reject a stale suspend ACK after health recovery intervenes")

		AssertEqual(1, State.LastErrorCalls,
			"the suspend(0) reentry must consume the native health fault once")
		AssertTrue(State.SuspendReenterResult,
			"the fake suspend seam must deliver the health wake synchronously")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"refused recovery Stops must retain explicit quarantine")
		AssertTrue(_LLM_NavEventOwnerLifecycleResumePlan is Array
				&& ObjPtr(_LLM_NavEventOwnerLifecycleResumePlan) == ObjPtr(Plan),
			"stale resume success must never consume the reentrant exact-plan intent")
		AssertEqual(1, State.StartCalls.Length,
			"no replacement may start before the failed runtime has stopped")

		State.StopMode := "accept"
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
		_LLM_NavEventOwnerService()

		AssertEqual(2, State.StartCalls.Length,
			"the acknowledged watchdog retry must start one replacement runtime")
		AssertEqual(2, State.PrepareCalls,
			"watchdog recovery must prepare the retained plan exactly once")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"watchdog recovery must commit the retained plan exactly once")
		AssertTrue(State.Started && !_LLM_NavEventOwnerQuarantined,
			"watchdog recovery must publish one healthy replacement runtime")
		AssertTrue(_LLM_NavEventOwnerCommittedPlan is Array
				&& ObjPtr(_LLM_NavEventOwnerCommittedPlan) == ObjPtr(Plan),
			"watchdog recovery must republish the exact pre-fault plan object")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: resume health reentry retains exact plan (ahk026-native-mask-health-resume-reentry)",
	_LNEO_NativeMaskFailureDuringResumeRetainsExactPlan)

_LNEO_ResumeRearmsPendingStopReceiptService() {
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerServiceArmed
	global _LLM_NavEventOwnerStopPending
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertTrue(Generation > 0 && LLM_NavEventOwner_CommitPlan(Generation),
			"setup must commit the exact plan retained across pause")
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1785
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"setup must queue one receipt immediately before pause")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"native suspension must establish the lifecycle fence")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"successful pause must disarm the receipt watchdog")
		State.StopModes := ["pending", "accept"]
		AssertFalse(LLM_NavEventOwner_Stop(true),
			"a quarantine Stop with retained receipt must publish StopPending")
		AssertTrue(_LLM_NavEventOwnerStopPending,
			"the post-signal native drain must remain explicit")
		AssertFalse(LLM_NavEventOwner_Drain(),
			"a consumed pause wake must not cross the lifecycle fence")
		AssertEqual(0, State.CompleteCalls.Length,
			"the paused wake must leave the native receipt unacknowledged")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"resume must defer exact-plan replay until the receipt debt drains")
		AssertFalse(_LLM_NavEventOwnerLifecycleQuiesced,
			"resume must release the drain's lifecycle barrier")
		AssertTrue(_LLM_NavEventOwnerServiceArmed,
			"resume must re-arm the only recovery route for StopPending")
		Paint := {Calls: [], Critical: [], Results: [1]}
		_LLM_NavEventOwnerService(
			_LNEO_RenderAndPaintProbe.Bind(Paint))
		AssertTrue(State.Completed.Has(Sequence),
			"the resumed service must apply and acknowledge the exact receipt")
		AssertEqual(2, A.Record.ActiveIdx,
			"receipt recovery must preserve the exact pre-pause owner target")
		AssertEqual(2, A.Surface.RenderedActiveIdx,
			"service recovery must converge the visible pixels before replay")
		AssertEqual(1, State.CompleteCalls.Length,
			"receipt recovery must acknowledge the suppressed event once")
		AssertFalse(_LLM_NavEventOwnerStopPending,
			"the service must finalize the drained native Stop")
		AssertTrue(State.Started,
			"the service must restart a real native owner after final join")
		AssertEqual(2, State.StartCalls.Length,
			"recovery must start exactly one replacement hook")
		AssertEqual(2, State.PrepareCalls,
			"recovery must prepare the retained plan exactly once")
		AssertEqual(2, State.CommitPlanCalls.Length,
			"recovery must commit the retained plan exactly once")
		AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
			"recovery must replay the exact retained plan object")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: resume rearms pending-stop receipt service",
	_LNEO_ResumeRearmsPendingStopReceiptService)

_LNEO_QuarantineWatchdogDrainsRetainedReceipt() {
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerServiceArmed
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1782
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"the native owner must retain one receipt before quarantine")
		B := _LNEO_Presentation("B", 6, Lifecycle)
		_LNEO_Publish(A, B)
		_LLM_NavEventOwnerSetServiceTimer(true)
		_LNEO_DisarmNativeServiceTimerForManualTick()
		State.StopMode := "refuse"
		AssertFalse(_LLM_NavEventOwnerQuarantine(
			"Injected retained-receipt quarantine"),
			"a quarantine boundary must never claim ordinary success")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"a refused Stop must keep the ambiguity explicitly quarantined")
		AssertTrue(_LLM_NavEventOwnerServiceArmed,
			"the retained receipt watchdog must survive an unproved Stop")
		AssertEqual(1, State.Pending.Get(A.Token, 0),
			"the pre-quarantine receipt must still be retained")

		_LLM_NavEventOwnerService()
		AssertEqual(2, A.Record.ActiveIdx,
			"the quarantine watchdog must apply the exact retained owner")
		AssertEqual(1, State.CompleteCalls.Length,
			"the quarantine watchdog must acknowledge the receipt once")
		AssertEqual(0, State.Pending.Get(A.Token, 0),
			"the quarantine watchdog must release completed native retention")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: quarantine watchdog drains retained receipt",
	_LNEO_QuarantineWatchdogDrainsRetainedReceipt)

_LNEO_QuarantineWatchdogRetriesUnprovedStopAfterExactDebt() {
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerRecords
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerServiceArmed
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	global LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		_LLM_NavEventOwnerSetServiceTimer(true)
		_LNEO_DisarmNativeServiceTimerForManualTick()
		State.StopModes := ["refuse", "accept"]
		AssertFalse(_LLM_NavEventOwnerQuarantine(
			"Injected retryable quarantine"),
			"quarantine must remain visibly fail-open after its first refused Stop")
		AssertEqual(1, State.StopCalls,
			"the quarantine boundary must make one immediate bounded Stop attempt")

		_LLM_NavEventOwnerLastQuarantineStopAttemptTick :=
			A_TickCount - LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS
		_LLM_NavEventOwnerService()
		AssertEqual(2, State.StopCalls,
			"the retained watchdog must retry an unproved non-pending Stop")
		AssertFalse(_LLM_NavEventOwnerQuarantined,
			"an acknowledged watchdog retry must clear quarantine")
		AssertFalse(State.Started,
			"an acknowledged watchdog retry must stop the fake native owner")
		AssertEqual(0, _LLM_NavEventOwnerRecords.Count,
			"proved terminal Stop may release every retained owner record")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"proved terminal Stop must disarm the retained watchdog")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}

	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1786
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"setup must retain one exact receipt before quarantine")
		_LLM_NavEventOwnerSetServiceTimer(true)
		_LNEO_DisarmNativeServiceTimerForManualTick()
		State.StopModes := ["refuse", "accept"]
		AssertFalse(_LLM_NavEventOwnerQuarantine(
			"Injected repaint-debt quarantine"),
			"the repaint-debt boundary must remain visibly quarantined")
		Probe := {Calls: [], Critical: [], Results: [0, 1]}
		Renderer := _LNEO_RenderAndPaintProbe.Bind(Probe)
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick :=
			A_TickCount - LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS

		_LLM_NavEventOwnerService(Renderer)
		AssertEqual(1, State.CompleteCalls.Length,
			"the first watchdog tick must acknowledge the retained receipt once")
		AssertEqual(1, _LLM_NavEventOwnerPendingRepaints.Count,
			"a false renderer must retain the exact pixel publication debt")
		AssertEqual(1, State.StopCalls,
			"pixel debt must block the watchdog Stop retry before mutation")
		AssertTrue(_LLM_NavEventOwnerQuarantined,
			"unpainted acknowledged state must remain quarantined and retained")

		_LLM_NavEventOwnerService(Renderer)
		AssertEqual(2, A.Surface.RenderedActiveIdx,
			"the next watchdog tick must converge exact A pixels first")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"successful repaint must retire the pixel debt")
		AssertEqual(2, State.StopCalls,
			"only converged pixels may unlock the terminal Stop retry")
		AssertEqual(1, State.CompleteCalls.Length,
			"watchdog retry must never acknowledge the receipt twice")
		AssertFalse(_LLM_NavEventOwnerQuarantined || State.Started,
			"proved terminal cleanup must leave no quarantined native owner")
		AssertFalse(_LLM_NavEventOwnerServiceArmed,
			"terminal cleanup after repaint must disarm the watchdog")
	} finally {
		State.StopMode := "accept"
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: quarantine watchdog retries Stop after exact debt (ahk026-quarantine-stop-retry)",
	_LNEO_QuarantineWatchdogRetriesUnprovedStopAfterExactDebt)

_LNEO_ClaimedReceiptBlocksTerminalRecoveryClass() {
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	for RecoveryKind in ["stop_pending", "quarantine"] {
		State := _LNEO_Setup()
		try {
			Plan := _LNEO_Plan()
			Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
			AssertTrue(Generation > 0
					&& LLM_NavEventOwner_CommitPlan(Generation),
				RecoveryKind . ": setup must commit the exact recovery plan")
			Lifecycle := _LNEO_Lifecycle(
				RecoveryKind == "stop_pending" ? 2787 : 2788)
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			Sequence := RecoveryKind == "stop_pending" ? 1787 : 1788
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence),
				_LNEO_Receipt(Sequence, A.Token, 2))
			AssertTrue(LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port) is Map,
				RecoveryKind . ": setup must queue one suppressed receipt")

			State.StopModes := RecoveryKind == "stop_pending"
				? ["pending", "accept"] : ["refuse", "accept"]
			if RecoveryKind == "stop_pending" {
				State.SuspendMode := "refuse"
				AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
					"stop_pending: setup must retain a draining native Stop")
				AssertTrue(_LLM_NavEventOwnerStopPending,
					"stop_pending: setup must publish the terminal retry debt")
			} else {
				State.LastOsError := 5
				State.Suspended := true
				State.CompleteMode := "refuse"
				State.StopReenterMode := "drain"
				AssertFalse(_LLM_NavEventOwnerCheckNativeHealth(),
					"quarantine: setup must retain a refused health Stop")
				AssertTrue(_LLM_NavEventOwnerQuarantined,
					"quarantine: setup must publish the terminal retry debt")
				AssertFalse(State.ReentryResult,
					"quarantine: terminal admission must block a reentrant receipt drain")
				AssertEqual(0, State.PollCalls,
					"quarantine: no receipt may be claimed between the gate and Stop")
				AssertEqual(1, State.ReceiptQueue.Length,
					"quarantine: atomic terminal admission must retain the queued receipt")
			}
			AssertEqual(1, State.StopCalls,
				RecoveryKind . ": setup must make exactly one terminal Stop attempt")
			AssertEqual(1, State.StartCalls.Length,
				RecoveryKind . ": setup must retain the original runtime only")

			State.CompleteMode := "refuse"
			_LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
			Paint := {Calls: [], Critical: [], Results: [1]}
			Renderer := _LNEO_RenderAndPaintProbe.Bind(Paint)
			_LLM_NavEventOwnerService(Renderer)

			AssertEqual(1, State.CompleteCalls.Length,
				RecoveryKind . ": the first drain must attempt the exact ACK once")
			AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map,
				RecoveryKind . ": a refused ACK must retain the exact claimed receipt")
			AssertEqual(Sequence, _LLM_NavEventOwnerClaimedReceipt["seq"],
				RecoveryKind . ": terminal recovery must retain the native sequence")
			AssertEqual(1, State.Pending.Get(A.Token, 0),
				RecoveryKind . ": a refused ACK must retain native ownership")
			AssertEqual(1, State.StopCalls,
				RecoveryKind . ": claimed receipt debt must block terminal Stop")
			AssertEqual(1, State.StartCalls.Length,
				RecoveryKind . ": claimed receipt debt must block restart")
			AssertEqual(0, Paint.Calls.Length,
				RecoveryKind . ": pixels cannot repaint before native ACK")

			State.CompleteMode := "accept"
			_LLM_NavEventOwnerService(Renderer)
			AssertTrue(State.Completed.Has(Sequence),
				RecoveryKind . ": retry must ACK the original native sequence")
			AssertEqual(2, State.CompleteCalls.Length,
				RecoveryKind . ": ACK recovery must retry exactly once")
			AssertFalse(_LLM_NavEventOwnerClaimedReceipt is Map,
				RecoveryKind . ": successful ACK must retire the claim")
			AssertEqual(0, State.Pending.Get(A.Token, 0),
				RecoveryKind . ": successful ACK must release native retention")
			AssertEqual(1, Paint.Calls.Length,
				RecoveryKind . ": ACK recovery must repaint exactly once")
			AssertEqual(2, A.Surface.RenderedActiveIdx,
				RecoveryKind . ": exact owner pixels must converge before Stop")
			AssertEqual(2, State.StopCalls,
				RecoveryKind . ": terminal Stop may retry only after ACK and repaint")
			AssertEqual(2, State.StartCalls.Length,
				RecoveryKind . ": exact plan may restart only after ACK and repaint")

			_LLM_NavEventOwnerService(Renderer)
			AssertEqual(2, State.CompleteCalls.Length,
				RecoveryKind . ": later service must not duplicate the ACK")
			AssertEqual(1, Paint.Calls.Length,
				RecoveryKind . ": later service must not duplicate the repaint")
			AssertEqual(2, State.StopCalls,
				RecoveryKind . ": later service must not duplicate terminal Stop")
			AssertEqual(2, State.StartCalls.Length,
				RecoveryKind . ": later service must not duplicate restart")
		} finally {
			State.CompleteMode := "accept"
			State.StopMode := "accept"
			_LNEO_Teardown()
		}
	}
}

Test("LLM nav event owner: claimed receipt blocks every terminal recovery (ahk026-terminal-claim-debt)",
	_LNEO_ClaimedReceiptBlocksTerminalRecoveryClass)

