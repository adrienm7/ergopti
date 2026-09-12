; tests/unit/llm_nav_event_owner/test_receipt_repaint.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Receipt Repaint
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_IncidentalTooltipCannotStealPredictionRepaintSerial() {
	global _TooltipActiveSurface, _TooltipPendingRequest
	global _TooltipRequestSerial
	SavedSurface := _TooltipActiveSurface
	SavedPending := _TooltipPendingRequest
	SavedSerial := _TooltipRequestSerial
	Generation := 9107
	Record := { Kind: "prediction", Generation: Generation }
	Surface := { LlmPresented: Record, Generation: Generation }
	Pending := { TimerFn: 0, Marker: "prediction-repaint" }
	try {
		_TooltipActiveSurface := Surface
		_TooltipPendingRequest := Pending
		_TooltipRequestSerial := 313
		TooltipShow([{ Text: "ordinary hotstring preview" }])
		AssertEqual(313, _TooltipRequestSerial,
			"an incidental tooltip must lose before changing the repaint serial")
		AssertEqual(ObjPtr(Pending), ObjPtr(_TooltipPendingRequest),
			"an incidental tooltip must not replace the prediction repaint request")
	} finally {
		CurrentPending := _TooltipPendingRequest
		if IsObject(CurrentPending) && CurrentPending.HasOwnProp("TimerFn")
				&& IsObject(CurrentPending.TimerFn)
			SetTimer(CurrentPending.TimerFn, 0)
		_TooltipActiveSurface := SavedSurface
		_TooltipPendingRequest := SavedPending
		_TooltipRequestSerial := SavedSerial
	}
}

Test("LLM nav event owner: incidental tooltip cannot steal prediction repaint serial",
	_LNEO_IncidentalTooltipCannotStealPredictionRepaintSerial)

_LNEO_SuspendedDrainRetainsReceiptUntilResume() {
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1781
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 7))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"the native owner must queue one pre-suspend receipt")
		B := _LNEO_Presentation("B", 6, Lifecycle)
		_LNEO_Publish(A, B)

		Suspend(1)
		try {
			AssertFalse(LLM_NavEventOwner_Drain(),
				"the central receipt drain must refuse all work while AHK is suspended")
			AssertEqual(0, State.PollCalls,
				"suspension must block the receipt before it is claimed")
			AssertEqual(0, State.CompleteCalls.Length,
				"suspension must not acknowledge a suppressed event")
			AssertEqual(1, A.Record.ActiveIdx,
				"the retained owner record must remain immutable during pause")
			AssertEqual(1, State.Pending.Get(A.Token, 0),
				"the native receipt must remain retained throughout pause")
		} finally Suspend(0)

		AssertTrue(LLM_NavEventOwner_Drain(),
			"resume must make the retained receipt drainable again")
		AssertEqual(7, A.Record.ActiveIdx,
			"resume must apply the exact retained owner target")
		AssertEqual(1, State.CompleteCalls.Length,
			"resume must acknowledge the receipt exactly once")
		AssertEqual(0, State.Pending.Get(A.Token, 0),
			"the successful resumed drain must release native retention")
	} finally {
		if A_IsSuspended
			Suspend(0)
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: suspended drain retains receipt until resume",
	_LNEO_SuspendedDrainRetainsReceiptUntilResume)

_LNEO_PollClaimCannotCrossSuspend() {
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerPendingRepaints
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1782
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 7))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"the native owner must queue the receipt before the poll seam")
		State.PollReenterMode := "suspend"

		AssertTrue(LLM_NavEventOwner_Drain(),
			"the drain entered before suspension must retain its claimed receipt")
		AssertTrue(A_IsSuspended,
			"the poll seam must interpose a real AHK suspension after native claim")
		AssertEqual(1, A.Record.ActiveIdx,
			"a suspension winning after Poll must prevent record mutation")
		AssertEqual(0, State.CompleteCalls.Length,
			"a suspension winning after Poll must prevent native acknowledgement")
		AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map,
			"the exact claimed receipt must remain retained across the pause")
		AssertEqual(Sequence, _LLM_NavEventOwnerClaimedReceipt["seq"],
			"the retained receipt must preserve its native sequence")
		AssertEqual(1, State.Pending.Get(A.Token, 0),
			"the native owner must retain the suppressed event during pause")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"no repaint may be scheduled before the receipt is applied")

		Suspend(0)
		AssertTrue(LLM_NavEventOwner_Drain(),
			"resume must drain the exact already-claimed receipt")
		AssertEqual(7, A.Record.ActiveIdx,
			"resume must apply the retained receipt to its exact owner")
		AssertEqual(1, State.CompleteCalls.Length,
			"resume must acknowledge the retained receipt exactly once")
		AssertTrue(State.Completed.Has(Sequence),
			"resume must complete the original native sequence")
		AssertEqual(0, State.Pending.Get(A.Token, 0),
			"resume must release native receipt retention")
		AssertFalse(_LLM_NavEventOwnerClaimedReceipt is Map,
			"successful completion must clear the claimed receipt slot")
	} finally {
		if A_IsSuspended
			Suspend(0)
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: poll claim cannot cross suspension",
	_LNEO_PollClaimCannotCrossSuspend)

_LNEO_PollClaimCannotCrossLifecycleFence() {
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerLifecycleQuiesced
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1783
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 7))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"the native owner must queue the receipt before lifecycle quiescence")
		State.PollReenterMode := "quiesce"

		AssertTrue(LLM_NavEventOwner_Drain(),
			"the drain must retain a receipt claimed across lifecycle quiescence")
		AssertTrue(State.PollReenterResult,
			"the seam must publish a proved native lifecycle fence")
		AssertTrue(_LLM_NavEventOwnerLifecycleQuiesced,
			"the lifecycle fence must remain published before AHK suspension")
		AssertFalse(A_IsSuspended,
			"this regression must not rely on the later AHK suspended flag")
		AssertEqual(1, A.Record.ActiveIdx,
			"the published lifecycle fence must prevent record mutation")
		AssertEqual(0, State.CompleteCalls.Length,
			"the published lifecycle fence must prevent native acknowledgement")
		AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map,
			"the claimed receipt must survive until lifecycle resume")
		AssertEqual(Sequence, _LLM_NavEventOwnerClaimedReceipt["seq"],
			"the retained claim must keep the exact native sequence")
		AssertEqual(1, State.Pending.Get(A.Token, 0),
			"the native receipt must remain pending behind the lifecycle fence")

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(false),
			"lifecycle resume must release the receipt fence")
		AssertFalse(_LLM_NavEventOwnerLifecycleQuiesced,
			"successful resume must retire the lifecycle fence")
		AssertTrue(LLM_NavEventOwner_Drain(),
			"resume must drain the exact lifecycle-retained receipt")
		AssertEqual(7, A.Record.ActiveIdx,
			"resume must apply the retained target to owner A")
		AssertEqual(1, State.CompleteCalls.Length,
			"resume must acknowledge the retained receipt exactly once")
		AssertTrue(State.Completed.Has(Sequence),
			"resume must complete the original native sequence")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: poll claim cannot cross lifecycle fence",
	_LNEO_PollClaimCannotCrossLifecycleFence)

_LNEO_RepaintBuildRunsOutsideCriticalAndNeedsSuccess() {
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerRepaintFailures
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1784
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 7))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"the native owner must queue a real repaint receipt")
		Probe := { Calls: [], Critical: [], Results: [0, 1] }
		Renderer := _LNEO_RenderProbe.Bind(Probe)

		AssertTrue(LLM_NavEventOwner_Drain(Renderer),
			"the first drain must apply and acknowledge the native receipt")
		AssertEqual(1, Probe.Calls.Length,
			"the completed receipt must request one repaint")
		AssertEqual(0, Probe.Critical[1],
			"GUI/UIA repaint preparation must run outside Critical")
		AssertEqual(1, _LLM_NavEventOwnerPendingRepaints.Count,
			"a false renderer result must retain the repaint obligation")
		AssertEqual(1, _LLM_NavEventOwnerRepaintFailures.Get(A.Token, 0),
			"a transient failure must consume exactly one retry attempt")
		AssertEqual(1, State.CompleteCalls.Length,
			"repaint retry must not delay or duplicate native completion")

		AssertTrue(LLM_NavEventOwner_Drain(Renderer),
			"the retained repaint must remain independently retryable")
		AssertEqual(2, Probe.Calls.Length,
			"the retained repaint must call the renderer again")
		AssertEqual(0, Probe.Critical[2],
			"every repaint retry must remain outside Critical")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"only a positive renderer result may retire the repaint obligation")
		AssertEqual(0, _LLM_NavEventOwnerRepaintFailures.Count,
			"successful pixel publication must retire retry bookkeeping")
		AssertEqual(1, State.CompleteCalls.Length,
			"repaint retry must never acknowledge the receipt twice")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: repaint build is non-Critical and success-owned",
	_LNEO_RepaintBuildRunsOutsideCriticalAndNeedsSuccess)

_LNEO_PermanentRepaintFailureDegradesOnceAndRetiresDebt() {
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerRepaintFailures
	global LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 17841
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 7))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"setup must queue one exact suppressed navigation receipt")
		Render := { Calls: [], Critical: [], Results: [] }
		Loop LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS + 2
			Render.Results.Push(0)
		Degrade := { Calls: [], Critical: [], Throw: false, Result: true }
		Renderer := _LNEO_RenderProbe.Bind(Render)
		Degrader := _LNEO_RepaintDegradeProbe.Bind(Degrade)

		Loop LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS
			AssertTrue(LLM_NavEventOwner_Drain(Renderer, Degrader),
				"each bounded attempt must keep the service responsive")

		AssertEqual(LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS,
			Render.Calls.Length,
			"a permanent renderer fault must consume only its named retry budget")
		AssertEqual(1, Degrade.Calls.Length,
			"budget exhaustion must request exactly one visible degradation")
		AssertTrue(ObjPtr(Degrade.Calls[1]) == ObjPtr(A.Record),
			"degradation must target the exact record whose pixels could not converge")
		AssertEqual(0, Degrade.Critical[1],
			"tooltip hide/degradation must run outside Critical")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"terminal degradation must retire the repaint service debt")
		AssertEqual(0, _LLM_NavEventOwnerRepaintFailures.Count,
			"terminal degradation must retire its retry bookkeeping")
		AssertEqual(1, State.CompleteCalls.Length,
			"bounded repaint retries must never duplicate native acknowledgement")

		Loop 4
			_LLM_NavEventOwnerService(Renderer, Degrader)
		AssertEqual(LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS,
			Render.Calls.Length,
			"later watchdog ticks must not rebuild after terminal degradation")
		AssertEqual(1, Degrade.Calls.Length,
			"later watchdog ticks must not repeat terminal degradation")
	} finally _LNEO_Teardown()
}

_LNEO_RepaintDegradeFailureStillStopsRebuildLoop() {
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerRepaintFailures
	global LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 17842
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 6))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"setup must queue the repaint receipt")
		Render := { Calls: [], Critical: [], Results: [] }
		Loop LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS + 1
			Render.Results.Push(0)
		Degrade := { Calls: [], Critical: [], Throw: true, Result: false }
		Renderer := _LNEO_RenderProbe.Bind(Render)
		Degrader := _LNEO_RepaintDegradeProbe.Bind(Degrade)

		Loop LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS
			LLM_NavEventOwner_Drain(Renderer, Degrader)
		AssertEqual(1, Degrade.Calls.Length,
			"a throwing degradation boundary must still be invoked only once")
		AssertEqual(0, _LLM_NavEventOwnerPendingRepaints.Count,
			"a degradation exception must not resurrect the expensive repaint loop")
		AssertEqual(0, _LLM_NavEventOwnerRepaintFailures.Count,
			"a degradation exception must not retain retry bookkeeping")
		LLM_NavEventOwner_Drain(Renderer, Degrader)
		AssertEqual(LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS,
			Render.Calls.Length,
			"a degradation exception must still leave the GUI rebuild bounded")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: permanent repaint failure degrades once and stops rebuilding (ahk2-15)",
	_LNEO_PermanentRepaintFailureDegradesOnceAndRetiresDebt)
Test("LLM nav event owner: degradation failure cannot restart repaint loop (ahk2-15)",
	_LNEO_RepaintDegradeFailureStillStopsRebuildLoop)

_LNEO_QuiescenceBlocksCandidateButAllowsHide() {
	global _LLM_NavEventOwnerLifecycleQuiesced
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		B := _LNEO_Presentation("B", 7, _LNEO_Lifecycle())
		BeginBefore := State.BeginCalls.Length
		CommitBefore := State.CommitSwapCalls.Length

		AssertTrue(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"setup must publish and prove the lifecycle pause fence")
		AssertTrue(_LLM_NavEventOwnerLifecycleQuiesced,
			"quiescence must remain published for the whole pause")
		CandidateTx := LLM_NavEventOwner_BeginSurfaceSwap(
			A.Surface, B.Surface)
		AssertTrue(CandidateTx is Map && CandidateTx.Get("retry", false),
			"a detached candidate finishing after quiescence must be refused benignly")
		AssertEqual(BeginBefore, State.BeginCalls.Length,
			"the paused candidate must be rejected before any native Begin")
		AssertEqual(CommitBefore, State.CommitSwapCalls.Length,
			"the paused candidate must never reach native Commit")
		AssertEqual(A.Token, State.CurrentToken,
			"candidate refusal must retain native owner A")

		LoadingSurface := {
			Generation: 818,
			LlmPresented: {
				Kind: "loading", Slots: [], ActiveIdx: 0,
				Lifecycle: _LNEO_Lifecycle(818), IsFinal: false,
				ShownAt: 0, Generation: 818, TimeoutRemainingMs: 0
			}
		}
		LoadingTx := LLM_NavEventOwner_BeginSurfaceSwap(
			A.Surface, LoadingSurface)
		AssertTrue(LoadingTx is Map && LoadingTx.Get("retry", false),
			"a tokenless loading record must not masquerade as a teardown hide")
		AssertEqual(BeginBefore, State.BeginCalls.Length,
			"loading refusal must also precede every native Begin")

		HideTx := LLM_NavEventOwner_BeginSurfaceSwap(A.Surface, 0)
		AssertTrue(HideTx is Map && !HideTx.Get("retry", false),
			"the same lifecycle fence must still allow teardown to hide A")
		AssertEqual(BeginBefore + 1, State.BeginCalls.Length,
			"hide must cross exactly one native Begin under the pause fence")
		AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(HideTx),
			"hide must retire the native owner while quiesced")
		AssertEqual(0, State.CurrentToken,
			"the permitted hide must leave no suppressing native owner")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: quiescence blocks candidate but allows hide",
	_LNEO_QuiescenceBlocksCandidateButAllowsHide)

_LNEO_QuiescenceRefusesRenderBeforeReservationMutation() {
	global _TooltipActiveSurface, _TooltipPendingRequest
	global _TooltipRequestSerial, _TooltipGeneration, _TooltipTimerGeneration
	global _TooltipDequeueItems, _TooltipDequeueActive
	global _TooltipDequeueDeadlineTimer
	global _LLM_NavEventOwnerLifecycleQuiesced
	Saved := {
		Surface: _TooltipActiveSurface,
		Pending: _TooltipPendingRequest,
		Serial: _TooltipRequestSerial,
		Generation: _TooltipGeneration,
		TimerGeneration: _TooltipTimerGeneration,
		DequeueItems: _TooltipDequeueItems,
		DequeueActive: _TooltipDequeueActive,
		DeadlineTimer: _TooltipDequeueDeadlineTimer
	}
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		PendingTimer := (*) => 0
		Pending := {TimerFn: PendingTimer, Serial: 81}
		DequeueItems := ["A1", "A2"]
		DeadlineTimer := (*) => 0
		_TooltipPendingRequest := Pending
		_TooltipRequestSerial := 81
		_TooltipGeneration := 91
		_TooltipTimerGeneration := 91
		_TooltipDequeueItems := DequeueItems
		_TooltipDequeueActive := true
		_TooltipDequeueDeadlineTimer := DeadlineTimer
		State.SuspendMode := "refuse"
		State.StopMode := "refuse"
		State.SuspendReenterMode := "reserve_render"

		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"an unproved native pause must refuse the lifecycle transition")
		AssertEqual(0, State.SuspendReenterResult,
			"a render entering after the lifecycle latch must fail admission")
		State.SuspendReenterMode := "show_loading"
		State.SuspendReenterResult := true
		AssertFalse(LLM_NavEventOwner_QuiesceForLifecycle(true),
			"owned loading admission must also lose to the published lifecycle latch")
		AssertFalse(State.SuspendReenterResult,
			"TooltipShow must visibly reject loading before request publication")
		AssertFalse(_LLM_NavEventOwnerLifecycleQuiesced,
			"the refused pause must release its lifecycle latch")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
			"the rejected candidate must leave owner A visible")
		AssertEqual(ObjPtr(Pending), ObjPtr(_TooltipPendingRequest),
			"admission must not retire A's pending request owner")
		AssertEqual(81, _TooltipRequestSerial,
			"admission must not steal A's request serial")
		AssertEqual(91, _TooltipGeneration,
			"admission must not steal A's render generation")
		AssertEqual(91, _TooltipTimerGeneration,
			"admission must not invalidate A's timer generation")
		AssertEqual(ObjPtr(DequeueItems), ObjPtr(_TooltipDequeueItems),
			"admission must not retire A's dequeue items")
		AssertTrue(_TooltipDequeueActive,
			"admission must not deactivate A's dequeue owner")
		AssertEqual(ObjPtr(DeadlineTimer),
			ObjPtr(_TooltipDequeueDeadlineTimer),
			"admission must not replace A's deadline timer")
		AssertEqual("", Lifecycle.Outcome,
			"admission must not mutate A's acceptance lifecycle")
	} finally {
		if IsObject(_TooltipPendingRequest)
				&& _TooltipPendingRequest.HasOwnProp("TimerFn")
				&& IsObject(_TooltipPendingRequest.TimerFn)
			try SetTimer(_TooltipPendingRequest.TimerFn, 0)
		State.SuspendMode := "accept"
		State.StopMode := "accept"
		_LNEO_Teardown()
		_TooltipActiveSurface := Saved.Surface
		_TooltipPendingRequest := Saved.Pending
		_TooltipRequestSerial := Saved.Serial
		_TooltipGeneration := Saved.Generation
		_TooltipTimerGeneration := Saved.TimerGeneration
		_TooltipDequeueItems := Saved.DequeueItems
		_TooltipDequeueActive := Saved.DequeueActive
		_TooltipDequeueDeadlineTimer := Saved.DeadlineTimer
	}
}

Test("LLM nav event owner: quiescence rejects render before reservation",
	_LNEO_QuiescenceRefusesRenderBeforeReservationMutation)

_LNEO_SuspendedCommitCannotMutateSharedLifecycle() {
	global _TooltipGeneration, _TooltipActiveSurface
	SavedGeneration := _TooltipGeneration
	State := _LNEO_Setup()
	WasSuspended := A_IsSuspended
	try {
		Lifecycle := _LNEO_Lifecycle(181)
		Lifecycle.AcceptSource := Map("hwnd", 111, "thread_id", 11)
		Lifecycle.AppName := "owner-A.exe"
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		OriginalSource := Lifecycle.AcceptSource
		OriginalSlots := Lifecycle.Slots
		OriginalApp := Lifecycle.AppName
		CandidateGeneration := SavedGeneration + 181
		_TooltipGeneration := CandidateGeneration
		CandidateSurface := {Generation: CandidateGeneration}
		CandidateSlots := ["B1", "B2", "B3", "B4", "B5", "B6", "B7"]
		CandidateMeta := Map(
			"offer_id", Lifecycle.OfferId,
			"accept_source", Map("hwnd", 222, "thread_id", 22),
			"app_name", "owner-B.exe",
			"is_final", true,
			"timeout_ms", 0)
		BeginBefore := State.BeginCalls.Length

		Suspend(1)
		Failure := 0
		try _LLM_TooltipCommitSurfaceState(CandidateSlots, 2,
			CandidateGeneration, CandidateMeta, CandidateSurface, A.Surface)
		catch as Err
			Failure := Err

		AssertTrue(Failure is TooltipNavOwnerRetryError,
			"a pre-built candidate must lose when raw Suspend wins before commit")
		AssertFalse(CandidateSurface.HasOwnProp("LlmPresented"),
			"the refused candidate must remain semantically detached")
		AssertEqual(ObjPtr(OriginalSource), ObjPtr(Lifecycle.AcceptSource),
			"pause refusal must precede AcceptSource replacement")
		AssertEqual(ObjPtr(OriginalSlots), ObjPtr(Lifecycle.Slots),
			"pause refusal must precede slot replacement")
		AssertEqual(OriginalApp, Lifecycle.AppName,
			"pause refusal must precede application-name replacement")
		AssertEqual("", Lifecycle.Outcome,
			"pause refusal must preserve A's open acceptance lifecycle")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
			"pause refusal must preserve A as the sole visible surface")
		AssertEqual(A.Token, State.CurrentToken,
			"pause refusal must preserve A as the native event owner")
		AssertEqual(BeginBefore, State.BeginCalls.Length,
			"state refusal must occur before a late native Begin")

		LoadingSurface := {Generation: CandidateGeneration}
		LoadingFailure := 0
		try _LLM_TooltipCommitLoadingState(
			CandidateMeta, LoadingSurface, A.Surface)
		catch as Err
			LoadingFailure := Err
		AssertTrue(LoadingFailure is TooltipNavOwnerRetryError,
			"a tokenless loading candidate must lose the same final pause race")
		AssertFalse(LoadingSurface.HasOwnProp("LlmPresented"),
			"loading pause refusal must precede semantic attachment")
		AssertEqual(BeginBefore, State.BeginCalls.Length,
			"loading state refusal must precede a native Begin")
	} finally {
		if !WasSuspended
			Suspend(0)
		_TooltipGeneration := SavedGeneration
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: suspended commit preserves shared lifecycle",
	_LNEO_SuspendedCommitCannotMutateSharedLifecycle)

_LNEO_AllPlaceholderCannotReplaceVisiblePrediction() {
	global _TooltipActiveSurface, _TooltipPendingRequest
	global _TooltipRequestSerial, _TooltipGeneration, _TooltipTimerGeneration
	global _LLM_TooltipMetricQueue
	Saved := {
		Surface: _TooltipActiveSurface,
		Pending: _TooltipPendingRequest,
		Serial: _TooltipRequestSerial,
		Generation: _TooltipGeneration,
		TimerGeneration: _TooltipTimerGeneration,
		Metrics: _LLM_TooltipMetricQueue
	}
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle(183)
		Lifecycle.Suggested := true
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		PendingTimer := (*) => 0
		Pending := {TimerFn: PendingTimer, Serial: 271}
		Metrics := []
		_TooltipPendingRequest := Pending
		_TooltipRequestSerial := 271
		_TooltipGeneration := A.Surface.Generation
		_TooltipTimerGeneration := A.Surface.Generation
		_LLM_TooltipMetricQueue := Metrics
		Meta := Map("offer_id", 184, "is_final", false)

		AssertFalse(LLM_TooltipShow([""], 1, false, Meta),
			"an all-placeholder stream must not replace visible prediction A")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
			"the placeholder path must preserve A's exact visible surface")
		AssertEqual(A.Token, State.CurrentToken,
			"the placeholder path must preserve A's exact native owner")
		AssertEqual("", Lifecycle.Outcome,
			"the placeholder path must not dismiss A's acceptance lifecycle")
		AssertEqual(ObjPtr(Pending), ObjPtr(_TooltipPendingRequest),
			"loading refusal must precede pending-request replacement")
		AssertEqual(271, _TooltipRequestSerial,
			"loading refusal must precede request-serial mutation")
		AssertEqual(A.Surface.Generation, _TooltipGeneration,
			"loading refusal must preserve A's render generation")
		AssertEqual(A.Surface.Generation, _TooltipTimerGeneration,
			"loading refusal must preserve A's timer generation")
		AssertEqual(ObjPtr(Metrics), ObjPtr(_LLM_TooltipMetricQueue),
			"loading refusal must preserve the exact metric queue")
		AssertEqual(0, Metrics.Length,
			"loading refusal must not enqueue a false dismissal metric")

		HideTx := LLM_NavEventOwner_BeginSurfaceSwap(A.Surface, 0)
		AssertTrue(HideTx is Map,
			"the control path must detach A before testing an empty surface")
		_TooltipActiveSurface := 0
		AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(HideTx),
			"the control path must commit A-to-empty ownership")
		AssertTrue(LLM_TooltipShowLoading(Meta),
			"the same loading request must remain eligible on an empty surface")
		AssertTrue(IsObject(_TooltipPendingRequest)
				&& ObjPtr(_TooltipPendingRequest) != ObjPtr(Pending),
			"an eligible loading request must publish a fresh pending owner")
		AssertEqual(272, _TooltipRequestSerial,
			"an eligible loading request must advance the serial exactly once")
	} finally {
		if IsObject(_TooltipPendingRequest)
				&& _TooltipPendingRequest.HasOwnProp("TimerFn")
				&& IsObject(_TooltipPendingRequest.TimerFn)
			try SetTimer(_TooltipPendingRequest.TimerFn, 0)
		_LNEO_Teardown()
		_TooltipActiveSurface := Saved.Surface
		_TooltipPendingRequest := Saved.Pending
		_TooltipRequestSerial := Saved.Serial
		_TooltipGeneration := Saved.Generation
		_TooltipTimerGeneration := Saved.TimerGeneration
		_LLM_TooltipMetricQueue := Saved.Metrics
	}
}

Test("LLM nav event owner: all-placeholder stream preserves visible prediction (ahk026-placeholder-loading-owner)",
	_LNEO_AllPlaceholderCannotReplaceVisiblePrediction)

