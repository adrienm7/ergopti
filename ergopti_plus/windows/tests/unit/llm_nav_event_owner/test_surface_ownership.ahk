; tests/unit/llm_nav_event_owner/test_surface_ownership.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Surface Ownership
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 3/ Exact event-owner regressions =======
; ================================================
; ================================================

_LNEO_A7StaysWithExactOwnerAcrossReplacement() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	for BSlotCount in [7, 6] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			Sequence := 700 + BSlotCount
			Receipt := _LNEO_Receipt(Sequence, A.Token)
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence), Receipt)
			Event := _LNEO_DigitSevenEvent()
			Decision := LLM_NavEventOwner_TestDispatch(Event, State.Port)
			AssertTrue(Decision is Map,
				"an accepted native decision must cross the bridge as a Map")
			AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
				Decision["disposition"],
				"an accepted digit commit must suppress its physical key")
			AssertEqual(1, Decision["receipt_created"],
				"suppression must own one immutable receipt before returning")
			AssertEqual(1, State.DispatchCalls.Length,
				"the event must reach the injected native boundary exactly once")
			AssertEqual(ObjPtr(Event), ObjPtr(State.DispatchCalls[1]),
				"the bridge must pass the exact event object to the native seam")
			AssertEqual(1, State.Pending.Get(A.Token, 0),
				"the native receipt must retain A before any B publication")

			B := _LNEO_Presentation("B", BSlotCount, Lifecycle)
			AssertFalse(ObjPtr(A.Record) == ObjPtr(B.Record),
				"A and B must be distinct record generations")
			AssertFalse(ObjPtr(A.Surface) == ObjPtr(B.Surface),
				"A and B must be distinct surface generations")
			AssertEqual(ObjPtr(A.Record.Lifecycle),
				ObjPtr(B.Record.Lifecycle),
				"the regression must defeat lifecycle or OfferId owner aliases")
			_LNEO_Publish(A, B)
			AssertTrue(_LLM_NavEventOwnerRecords.Has(A.Token),
				"retiring A must retain it while its receipt remains pending")
			AssertEqual(1, B.Record.ActiveIdx,
				"publishing B must not pre-apply A's navigation target")

			State.ReenterOnComplete := true
			AssertTrue(LLM_NavEventOwner_Drain(),
				"the public drain must consume the pending native receipt")
			AssertTrue(LLM_NavEventOwner_Drain(),
				"a duplicate wake must be an idempotent empty drain")
			AssertEqual(7, A.Record.ActiveIdx,
				"the suppressed digit must navigate exact record A to slot seven")
			AssertEqual("A7", A.Record.Slots[7],
				"receipt application must use A's immutable slot snapshot")
			AssertEqual(1, B.Record.ActiveIdx,
				"A's delayed receipt must never mutate replacement record B")
			AssertEqual(BSlotCount, Lifecycle.Slots.Length,
				"the shared lifecycle must expose B's newer mutable slot list")
			AssertEqual(1, State.CompleteCalls.Length,
				"duplicate and reentrant drains must complete the receipt once")
			Completion := State.CompleteCalls[1]
			AssertEqual(Sequence, Completion["seq"],
				"completion must acknowledge the exact native sequence")
			AssertEqual(A.Token, Completion["owner_token"],
				"completion must acknowledge exact owner A")
			AssertEqual(7, Completion["applied_idx"],
				"completion must report the index actually applied to A")
			AssertFalse(State.ReentryResult,
				"claim-before-effect must reject a reentrant drain")
			AssertEqual(0, State.Pending.Get(A.Token, 0),
				"successful completion must release the native retention count")
			AssertFalse(_LLM_NavEventOwnerRecords.Has(A.Token),
				"retired A may be collected only after exact completion")
			AssertTrue(_LLM_NavEventOwnerRecords.Has(B.Token),
				"the active replacement record must remain owned")
			AssertEqual(ObjPtr(B.Surface), ObjPtr(_TooltipActiveSurface),
				"draining A must leave the newer B surface published")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: A7 remains exact across A-to-B7 and A-to-B6 replacement",
	_LNEO_A7StaysWithExactOwnerAcrossReplacement)

_LNEO_RepaintSwapRejectsStalePixels() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	for BSlotCount in [7, 6] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			SnapshotIdx := BSlotCount
			TargetIdx := BSlotCount - 1
			A := _LNEO_Presentation("A", 7, Lifecycle, SnapshotIdx)
			_LNEO_Publish(0, A)
			B := _LNEO_Presentation(
				"B", BSlotCount, Lifecycle, SnapshotIdx, true)
			Sequence := 1200 + BSlotCount
			Receipt := _LNEO_Receipt(Sequence, A.Token, TargetIdx)
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence), Receipt)
			AssertTrue(LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port) is Map,
				"the interposed event must commit against native owner A")
			AssertEqual(TargetIdx, State.OwnerIndices[A.Token],
				"native A must advance before the repaint fence opens")

			BeginBefore := State.BeginCalls.Length
			Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, B.Surface)
			AssertTrue(Transaction is Map && Transaction["retry"],
				"a stale repaint must be returned as a benign retry")
			AssertFalse(Transaction["native"],
				"a stale repaint must never publish a transition fence")
			AssertEqual(BeginBefore + 1, State.BeginCalls.Length,
				"the repaint must perform exactly one guarded comparison")
			AssertEqual(1,
				State.BeginCalls[State.BeginCalls.Length]["require_index_match"],
				"only a navigation repaint may require its rendered index")
			AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
				"stale B pixels must never replace visible surface A")
			AssertEqual(A.Token, State.CurrentToken,
				"stale B must leave native owner A published")
			AssertEqual(SnapshotIdx, B.Record.ActiveIdx,
				"the bridge must not rewrite semantics under already-built B pixels")
			AssertTrue(LLM_NavEventOwner_AbortSurfaceSwap(Transaction),
				"the benign retry must release its detached candidate")
			AssertFalse(_LLM_NavEventOwnerRecords.Has(B.Token),
				"a refused repaint candidate must not retain an owner token")

			Claimed := _LLM_NavEventOwnerPollReceipt()
			Entry := _LLM_NavEventOwnerApplyReceipt(Claimed)
			AssertTrue(IsObject(Entry),
				"the queued event must still apply to exact record A")
			AssertTrue(_LLM_NavEventOwnerCompleteReceipt(
				Sequence, A.Token, TargetIdx),
				"the exact A receipt must remain completable after retry")
			AssertEqual(TargetIdx, A.Record.ActiveIdx,
				"the retry source record must now expose the native index")

			C := _LNEO_Presentation(
				"C", BSlotCount, Lifecycle, TargetIdx, true)
			Retry := LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, C.Surface)
			AssertTrue(Retry is Map && Retry["native"] && !Retry["retry"],
				"a repaint rebuilt for the exact index must open its fence")
			_TooltipActiveSurface := C.Surface
			AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Retry),
				"the exact rebuilt repaint must publish")
			AssertEqual(TargetIdx, C.Record.ActiveIdx,
				"published semantics must equal the pixels C was built to show")
			AssertEqual(TargetIdx, State.OwnerIndices[C.Token],
				"native current owner and visible C must agree exactly")
			AssertEqual(1, State.CompleteCalls.Length,
				"the interposed suppressed event must complete once")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: repaint swap rejects stale pixels before reveal",
	_LNEO_RepaintSwapRejectsStalePixels)

_LNEO_UnprovedOwnerReadBlocksTextAndAcceptance() {
	for GetOwnerMode in ["zero", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			Sequence := GetOwnerMode == "zero" ? 1301 : 1302
			_LNEO_QueueNativeDecision(State,
				_LNEO_SuppressResult(Sequence),
				_LNEO_Receipt(Sequence, A.Token, 7))
			AssertTrue(LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port) is Map,
				GetOwnerMode . ": native owner must commit slot seven")
			AssertEqual(1, A.Record.ActiveIdx,
				GetOwnerMode . ": AHK must still hold the undrained snapshot")
			AssertEqual(7, State.OwnerIndices[A.Token],
				GetOwnerMode . ": native state must prove the divergence")
			State.GetOwnerMode := GetOwnerMode

			AssertEqual("", LLM_TooltipGetText(),
				GetOwnerMode . ": HotIf text must fail open when sync is unproved")
			AssertFalse(IsObject(LLM_TooltipGetAcceptSnapshot()),
				GetOwnerMode . ": Tab must not accept a stale semantic slot")
			AssertEqual(1, A.Record.ActiveIdx,
				GetOwnerMode . ": failed sync must not guess an index")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: unproved native read blocks text and acceptance",
	_LNEO_UnprovedOwnerReadBlocksTextAndAcceptance)

_LNEO_SemanticIndexCannotLeadPaintedSurface() {
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1357
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 6))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"native owner A must commit slot six before AHK repaint")

		AssertEqual("", LLM_TooltipGetText(),
			"Tab HotIf must fail open while pixels still mark slot one")
		AssertFalse(IsObject(LLM_TooltipGetAcceptSnapshot()),
			"acceptance must fail open until semantic and painted indices converge")
		AssertEqual(6, A.Record.ActiveIdx,
			"native synchronization must still update exact semantic owner A")
		AssertEqual(1, A.Surface.RenderedActiveIdx,
			"the immutable surface oracle must retain the actually painted index")

		C := _LNEO_Presentation("C", 7, Lifecycle, 6)
		_LNEO_Publish(A, C)
		AssertEqual("C6", LLM_TooltipGetText(),
			"text may resume only after C pixels and native owner both show six")
		Snapshot := LLM_TooltipGetAcceptSnapshot()
		AssertTrue(IsObject(Snapshot),
			"the converged C surface must become acceptable")
		AssertEqual(6, Snapshot.ActiveIdx,
			"acceptance must expose the exact painted/native index")
		AssertEqual("C6", Snapshot.Text,
			"acceptance text must belong to the exact painted C slot")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: semantic index never leads painted surface",
	_LNEO_SemanticIndexCannotLeadPaintedSurface)

_LNEO_TabAcceptanceClaimsExactNativeIndex() {
	global _LLM_NavEventOwnerRecords, _TooltipActiveSurface
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Snapshot := LLM_TooltipGetAcceptSnapshot()
		AssertTrue(IsObject(Snapshot) && Snapshot.ActiveIdx == 1,
			"acceptance must first freeze visible text and index one")
		Sequence := 1402
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 2))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"navigation must be able to win after the acceptance snapshot")
		Receipt := _LLM_NavEventOwnerPollReceipt()
		AssertTrue(IsObject(_LLM_NavEventOwnerApplyReceipt(Receipt)),
			"the winning navigation receipt must advance exact record A")
		AssertTrue(_LLM_NavEventOwnerCompleteReceipt(
			Sequence, A.Token, 2),
			"the interposed navigation receipt must remain completable")
		AssertEqual(2, A.Record.ActiveIdx,
			"the mutable record must expose the navigation winner")

		AssertFalse(IsObject(LLM_TooltipClaimAcceptance(
			Snapshot.Record, Snapshot.Surface, Snapshot.ActiveIdx)),
			"Tab must lose when native navigation changed the frozen index")
		AssertEqual("", Lifecycle.Outcome,
			"a refused native CAS must not publish an AHK acceptance claim")
		AssertEqual(1, State.ClaimCalls.Length,
			"the exact native CAS must be attempted once")
		AssertEqual(1, State.ClaimCalls[1]["expected_idx"],
			"the CAS must use the immutable snapshot index, not mutated Record.ActiveIdx")
		AssertEqual(A.Token, State.CurrentToken,
			"a lost CAS must leave the navigation winner active")
	} finally _LNEO_Teardown()

	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 1411
		_LNEO_QueueNativeDecision(State,
			_LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 1))
		AssertTrue(LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port) is Map,
			"a pre-claim same-index receipt must retain A")
		ClaimedLifecycle := LLM_TooltipClaimAcceptance(
			A.Record, A.Surface, 1)
		AssertEqual(ObjPtr(Lifecycle), ObjPtr(ClaimedLifecycle),
			"a winning CAS must claim the exact presented lifecycle")
		AssertEqual("claimed", Lifecycle.Outcome,
			"AHK claim publication must follow the native CAS")
		AssertEqual(0, State.CurrentToken,
			"a winning Tab CAS must clear the native owner atomically")
		Entry := _LLM_NavEventOwnerRecords[A.Token]
		AssertFalse(Entry.Active,
			"the detached native owner must not request later repaints")
		AssertFalse(Entry.Retired,
			"Tab claim alone must retain A until its pixels are hidden")
		AssertTrue(Entry.NativeDetached,
			"the bridge must remember that native A was already cleared")

		_LNEO_QueueNativeDecision(State, _LNEO_PassResult())
		AfterClaim := LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port)
		AssertEqual(_LNEO_DISPOSITION_PASS, AfterClaim["disposition"],
			"navigation after a winning acceptance CAS must pass untouched")
		AssertEqual(0, AfterClaim["receipt_created"],
			"post-claim input must never create a navigation receipt")

		BeginCalls := State.BeginCalls.Length
		HideTransaction := LLM_NavEventOwner_BeginSurfaceSwap(A.Surface, 0)
		AssertTrue(HideTransaction is Map,
			"hiding claimed A must still return a logical retirement transaction")
		AssertEqual(BeginCalls, State.BeginCalls.Length,
			"claimed A is already native-empty and must not open a second fence")
		_TooltipActiveSurface := 0
		AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(HideTransaction),
			"logical hide must retire the already-detached A")
		AssertTrue(_LLM_NavEventOwnerRecords.Has(A.Token),
			"a pre-claim receipt must retain hidden A until completion")
		AssertTrue(LLM_NavEventOwner_Drain(),
			"the exact pre-claim receipt must complete after logical hide")
		AssertEqual(1, State.CompleteCalls.Length,
			"the retained pre-claim receipt must complete exactly once")
		AssertFalse(_LLM_NavEventOwnerRecords.Has(A.Token),
			"hidden A may collect only after its last receipt completes")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: Tab acceptance CAS linearizes exact native index",
	_LNEO_TabAcceptanceClaimsExactNativeIndex)

_LNEO_ClaimedOwnerRejectsLateReplacementCandidate() {
	global _TooltipGeneration, _TooltipActiveSurface
	SavedGeneration := _TooltipGeneration
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle(151)
		Lifecycle.AcceptSource := Map("hwnd", 111, "thread_id", 11)
		Lifecycle.AppName := "owner-A.exe"
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		AssertEqual(ObjPtr(Lifecycle), ObjPtr(LLM_TooltipClaimAcceptance(
			A.Record, A.Surface, 1)),
			"setup must atomically claim exact owner A")
		AssertEqual(0, State.CurrentToken,
			"Tab claim must detach native A before the late candidate runs")

		OriginalSource := Lifecycle.AcceptSource
		OriginalSlots := Lifecycle.Slots
		OriginalApp := Lifecycle.AppName
		BeginCalls := State.BeginCalls.Length
		CandidateGeneration := SavedGeneration + 101
		_TooltipGeneration := CandidateGeneration
		CandidateSurface := {Generation: CandidateGeneration}
		CandidateSlots := ["B1", "B2", "B3", "B4", "B5", "B6", "B7"]
		CandidateSource := Map("hwnd", 222, "thread_id", 22)
		CandidateMeta := Map(
			"offer_id", Lifecycle.OfferId + 1,
			"accept_source", CandidateSource,
			"app_name", "owner-B.exe",
			"is_final", true,
			"timeout_ms", 0)

		Failure := 0
		try {
			_LLM_TooltipCommitSurfaceState(CandidateSlots, 2,
				CandidateGeneration, CandidateMeta, CandidateSurface, A.Surface)
			Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
				A.Surface, CandidateSurface)
			if Transaction is Map {
				_TooltipActiveSurface := CandidateSurface
				if !LLM_NavEventOwner_CommitSurfaceSwap(Transaction)
					throw Error("late candidate native publication failed")
			}
		} catch as Err
			Failure := Err

		AssertTrue(Failure is TooltipLlmTerminalOutcomeError,
			"a newer-offer candidate after Tab claim must lose at the state commit")
		AssertEqual("claimed", Lifecycle.Outcome,
			"late candidate refusal must preserve the terminal Tab claim")
		AssertEqual(ObjPtr(OriginalSource), ObjPtr(Lifecycle.AcceptSource),
			"terminal refusal must precede any AcceptSource replacement")
		AssertEqual(ObjPtr(OriginalSlots), ObjPtr(Lifecycle.Slots),
			"terminal refusal must precede any slot replacement")
		AssertEqual(OriginalApp, Lifecycle.AppName,
			"terminal refusal must precede any app-name replacement")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
			"claimed A pixels must remain the sole active surface until exact hide")
		AssertEqual(0, State.CurrentToken,
			"late B must never republish native ownership after the Tab CAS")
		AssertEqual(BeginCalls, State.BeginCalls.Length,
			"terminal state commit must fail before any native B fence")
		AssertFalse(CandidateSurface.HasOwnProp("LlmPresented"),
			"terminal B must remain a detached disposable candidate")

		ExplicitGeneration := CandidateGeneration + 1
		_TooltipGeneration := ExplicitGeneration
		ExplicitSurface := {Generation: ExplicitGeneration}
		ExplicitMeta := Map(
			"offer_id", Lifecycle.OfferId,
			"lifecycle", Lifecycle,
			"accept_source", CandidateSource,
			"app_name", "explicit-B.exe",
			"is_final", true,
			"timeout_ms", 0)
		ExplicitFailure := 0
		try _LLM_TooltipCommitSurfaceState(CandidateSlots, 2,
			ExplicitGeneration, ExplicitMeta, ExplicitSurface, 0)
		catch as Err
			ExplicitFailure := Err
		AssertTrue(ExplicitFailure is TooltipLlmTerminalOutcomeError,
			"an explicitly reused terminal lifecycle must also reject attachment")
		AssertFalse(ExplicitSurface.HasOwnProp("LlmPresented"),
			"explicit terminal reuse must remain detached before native ownership")
	} finally {
		_TooltipGeneration := SavedGeneration
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: Tab claim rejects every late replacement candidate",
	_LNEO_ClaimedOwnerRejectsLateReplacementCandidate)

_LNEO_ExpiredCommitCannotPoisonVisibleLifecycle() {
	global _TooltipGeneration, _TooltipActiveSurface
	SavedGeneration := _TooltipGeneration
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle(161)
		Lifecycle.AcceptSource := Map("hwnd", 111, "thread_id", 11)
		Lifecycle.AppName := "owner-A.exe"
		Lifecycle.Suggested := true
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Lifecycle.TimeoutOrigin := A_TickCount - 1000
		Lifecycle.TimeoutDurationMs := 1
		OriginalSource := Lifecycle.AcceptSource
		OriginalSlots := Lifecycle.Slots
		OriginalApp := Lifecycle.AppName

		CandidateGeneration := SavedGeneration + 161
		_TooltipGeneration := CandidateGeneration
		CandidateSurface := {Generation: CandidateGeneration}
		CandidateSlots := ["B1", "B2", "B3", "B4", "B5", "B6", "B7"]
		CandidateMeta := Map(
			"offer_id", Lifecycle.OfferId,
			"accept_source", Map("hwnd", 222, "thread_id", 22),
			"app_name", "owner-B.exe",
			"is_final", true,
			"timeout_ms", 1)

		Failure := 0
		try _LLM_TooltipCommitSurfaceState(CandidateSlots, 2,
			CandidateGeneration, CandidateMeta, CandidateSurface, A.Surface)
		catch as Err
			Failure := Err

		AssertTrue(Failure is Error && InStr(Failure.Message, "expired") > 0,
			"an expired same-offer candidate must be refused before publication")
		AssertEqual(ObjPtr(OriginalSource), ObjPtr(Lifecycle.AcceptSource),
			"expired refusal must not replace the visible owner's AcceptSource")
		AssertEqual(ObjPtr(OriginalSlots), ObjPtr(Lifecycle.Slots),
			"expired refusal must not replace the visible owner's metric slots")
		AssertEqual(OriginalApp, Lifecycle.AppName,
			"expired refusal must not misattribute the visible owner's app")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
			"expired refusal must leave exact A pixels visible")
		AssertEqual(A.Token, State.CurrentToken,
			"expired refusal must leave exact A as the native owner")
		AssertFalse(CandidateSurface.HasOwnProp("LlmPresented"),
			"expired B must remain semantically detached")
	} finally {
		_TooltipGeneration := SavedGeneration
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: expired commit preserves visible lifecycle (ahk026-expired-lifecycle-commit)",
	_LNEO_ExpiredCommitCannotPoisonVisibleLifecycle)

_LNEO_RenderIdentityOwnsReservationAndCommit() {
	global _TooltipGeneration, _TooltipTimerGeneration
	global _TooltipPendingRequest, _TooltipRequestSerial
	global _TooltipDequeueItems, _TooltipDequeueActive
	global _TooltipDequeueDeadlineTimer, _TooltipActiveSurface
	global _LLM_NavEventOwnerRecords
	Saved := {
		Generation: _TooltipGeneration,
		TimerGeneration: _TooltipTimerGeneration,
		PendingRequest: _TooltipPendingRequest,
		RequestSerial: _TooltipRequestSerial,
		DequeueItems: _TooltipDequeueItems,
		DequeueActive: _TooltipDequeueActive,
		DequeueDeadlineTimer: _TooltipDequeueDeadlineTimer,
		ActiveSurface: _TooltipActiveSurface
	}
	try {
		GuardState := Map("current", false)
		Meta := Map(
			"offer_id", 2026,
			"render_guard", (*) => GuardState["current"],
			"accept_source", Map("hwnd", 2026),
			"app_name", "candidate.exe",
			"is_final", false,
			"timeout_ms", 0)
		PendingSentinel := {Marker: "pending-A"}
		DequeueSentinel := ["dequeue-A"]
		_TooltipGeneration := 2600
		_TooltipTimerGeneration := 2600
		_TooltipPendingRequest := PendingSentinel
		_TooltipRequestSerial := 91
		_TooltipDequeueItems := DequeueSentinel
		_TooltipDequeueActive := true
		_TooltipDequeueDeadlineTimer := 0
		_TooltipActiveSurface := 0

		AssertFalse(_LLM_TooltipReserveLlmRender(Meta),
			"a request superseded before reservation must fail closed")
		AssertEqual(2600, _TooltipGeneration,
			"stale admission must not consume a render generation")
		AssertEqual(2600, _TooltipTimerGeneration,
			"stale admission must not steal the current timer generation")
		AssertEqual(91, _TooltipRequestSerial,
			"stale admission must not consume a request serial")
		AssertEqual(ObjPtr(PendingSentinel), ObjPtr(_TooltipPendingRequest),
			"stale admission must not cancel the exact pending request")
		AssertEqual(ObjPtr(DequeueSentinel), ObjPtr(_TooltipDequeueItems),
			"stale admission must not clear the current dequeue owner")
		AssertTrue(_TooltipDequeueActive,
			"stale admission must not disable the current dequeue lifecycle")

		GuardState["current"] := true
		Reservation := _LLM_TooltipReserveLlmRender(Meta)
		AssertTrue(Reservation is Map,
			"the exact current request must still reserve one detached render")
		Lifecycle := _LNEO_Lifecycle(2026)
		Lifecycle.AcceptSource := Map("hwnd", 111)
		Lifecycle.AppName := "visible-A.exe"
		Lifecycle.Slots := ["A1", "A2"]
		OriginalSource := Lifecycle.AcceptSource
		OriginalSlots := Lifecycle.Slots
		RetiredRecord := {
			Kind: "prediction", Slots: Lifecycle.Slots.Clone(), ActiveIdx: 1,
			Lifecycle: Lifecycle, IsFinal: false, ShownAt: 0,
			Generation: 2599, TimeoutRemainingMs: 0
		}
		RetiredSurface := {
			Generation: 2599, LlmPresented: RetiredRecord,
			RenderedActiveIdx: 1
		}
		CandidateSurface := {Generation: Reservation["generation"]}
		RecordsBefore := _LLM_NavEventOwnerRecords.Count
		GuardState["current"] := false
		Failure := 0
		try _LLM_TooltipCommitSurfaceState(
			["B1", "B2"], 2, Reservation["generation"], Meta,
			CandidateSurface, RetiredSurface)
		catch Error as Err
			Failure := Err

		AssertTrue(Failure is TooltipLlmStaleRenderError,
			"a request superseded during GUI/UIA work must lose at pixel commit")
		AssertFalse(CandidateSurface.HasOwnProp("LlmPresented"),
			"stale B must remain semantically detached")
		AssertEqual(RecordsBefore, _LLM_NavEventOwnerRecords.Count,
			"stale B must never publish a native owner token")
		AssertEqual(ObjPtr(OriginalSource), ObjPtr(Lifecycle.AcceptSource),
			"stale B must not rewrite A's acceptance source")
		AssertEqual(ObjPtr(OriginalSlots), ObjPtr(Lifecycle.Slots),
			"stale B must not rewrite A's visible or metric slots")
		AssertEqual("visible-A.exe", Lifecycle.AppName,
			"stale B must not rewrite A's application attribution")
		LoadingSurface := {Generation: Reservation["generation"]}
		LoadingFailure := 0
		try _LLM_TooltipCommitLoadingState(
			Meta, LoadingSurface, RetiredSurface)
		catch Error as Err
			LoadingFailure := Err
		AssertTrue(LoadingFailure is TooltipLlmStaleRenderError,
			"a cancelled deferred spinner must lose at its tokenless pixel commit")
		AssertFalse(LoadingSurface.HasOwnProp("LlmPresented"),
			"stale loading must remain detached and never replace A")
	} finally {
		_TooltipGeneration := Saved.Generation
		_TooltipTimerGeneration := Saved.TimerGeneration
		_TooltipPendingRequest := Saved.PendingRequest
		_TooltipRequestSerial := Saved.RequestSerial
		_TooltipDequeueItems := Saved.DequeueItems
		_TooltipDequeueActive := Saved.DequeueActive
		_TooltipDequeueDeadlineTimer := Saved.DequeueDeadlineTimer
		_TooltipActiveSurface := Saved.ActiveSurface
	}
}

Test("LLM nav event owner: render identity owns reservation and pixel commit (ahk026-render-identity-boundary)",
	_LNEO_RenderIdentityOwnsReservationAndCommit)

_LNEO_CaptureScheduledTimer(State, Callback, Period) {
	State.Calls.Push(Map("callback", Callback, "period", Period))
	return true
}

_LNEO_DeadlineDebtSurvivesCompensatedSuspend() {
	global _TooltipGeneration, _TooltipTimerGeneration, _TooltipActiveSurface
	global _TOOLTIP_OWNER_RETRY_MS
	for CallbackKind in ["canonical", "reservation"] {
		for PauseCompletes in [false, true] {
			SavedGeneration := _TooltipGeneration
			SavedTimerGeneration := _TooltipTimerGeneration
			State := _LNEO_Setup()
			try {
				Lifecycle := _LNEO_Lifecycle(
					CallbackKind == "canonical" ? 2601 : 2602)
				A := _LNEO_Presentation("A", 7, Lifecycle)
				Generation := SavedGeneration
					+ (CallbackKind == "canonical" ? 261 : 262)
				A.Record.Generation := Generation
				A.Surface.Generation := Generation
				A.Surface.Rows := []
				A.Surface.Border := 0
				A.Surface.ContentHwnds := []
				A.Surface.BorderHwnds := []
				_TooltipGeneration := Generation
				_TooltipTimerGeneration := Generation
				_LNEO_Publish(0, A)
				Schedule := {Calls: []}
				ScheduleFn := _LNEO_CaptureScheduledTimer.Bind(Schedule)

				Suspend(1)
				Retained := CallbackKind == "canonical"
					? _TooltipTimerHideOrRetry(
						Generation, A.Surface, ScheduleFn)
					: _LLM_TooltipReservationDeadlineFn(
						A.Surface, ScheduleFn)
				AssertTrue(Retained,
					CallbackKind . ": a due deadline must retain one exact retry while AHK is suspended")
				AssertEqual(1, Schedule.Calls.Length,
					CallbackKind . ": the suspended callback must schedule exactly one retry")
				AssertEqual(-_TOOLTIP_OWNER_RETRY_MS,
					Schedule.Calls[1]["period"],
					CallbackKind . ": the suspended callback must retain the canonical retry delay")
				AssertEqual(ObjPtr(A.Surface), ObjPtr(_TooltipActiveSurface),
					CallbackKind . ": the due callback must not hide A inside an unresolved pause")

				if PauseCompletes {
					AssertTrue(TooltipHide("Suspend", true, unset, A.Surface),
						CallbackKind . ": a successful pause teardown must hide exact A")
					Suspend(0)
					AssertFalse(Schedule.Calls[1]["callback"].Call(),
						CallbackKind . ": a retry must no-op after pause already retired A")
					AssertEqual(1, Schedule.Calls.Length,
						CallbackKind . ": a retired surface must not rearm its deadline")
				} else {
					Suspend(0)
					AssertTrue(Schedule.Calls[1]["callback"].Call(),
						CallbackKind . ": compensation must execute the retained exact deadline")
					AssertFalse(IsObject(_TooltipActiveSurface),
						CallbackKind . ": the compensated deadline must hide the expired A pixels")
					AssertEqual(0, State.CurrentToken,
						CallbackKind . ": deadline teardown must clear exact native ownership")
				}
			} finally {
				Suspend(0)
				_TooltipGeneration := SavedGeneration
				_TooltipTimerGeneration := SavedTimerGeneration
				_LNEO_Teardown()
			}
		}
	}
}

Test("LLM nav event owner: deadline debt survives compensated raw Suspend (ahk026-suspend-deadline-retry)",
	_LNEO_DeadlineDebtSurvivesCompensatedSuspend)

_LNEO_InvalidReceiptIsNeverAcknowledgedOrReleased() {
	global _LLM_NavEventOwnerRecords
	State := _LNEO_Setup()
	try {
		Lifecycle := _LNEO_Lifecycle()
		A := _LNEO_Presentation("A", 7, Lifecycle)
		_LNEO_Publish(0, A)
		Sequence := 808
		_LNEO_QueueNativeDecision(State, _LNEO_SuppressResult(Sequence),
			_LNEO_Receipt(Sequence, A.Token, 8))
		Decision := LLM_NavEventOwner_TestDispatch(
			_LNEO_DigitSevenEvent(), State.Port)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS, Decision["disposition"])
		B := _LNEO_Presentation("B", 6, Lifecycle)
		_LNEO_Publish(A, B)

		AssertTrue(LLM_NavEventOwner_Drain())
		AssertEqual(1, A.Record.ActiveIdx,
			"an out-of-range receipt must not mutate its retained record")
		AssertEqual(0, State.CompleteCalls.Length,
			"a refused application must never be reported as completed")
		AssertEqual(1, State.Pending.Get(A.Token, 0),
			"a refused application must preserve native retention")
		AssertTrue(_LLM_NavEventOwnerRecords.Has(A.Token),
			"a refused application must retain exact owner A for diagnosis or retry")
		AssertEqual(1, B.Record.ActiveIdx,
			"a malformed A receipt must not fall back to current record B")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: refused receipt application is not acknowledged or released",
	_LNEO_InvalidReceiptIsNeverAcknowledgedOrReleased)

_LNEO_CompletionFailureRetainsExactOwner() {
	global _LLM_NavEventOwnerRecords
	for CompletionMode in ["refuse", "throw"] {
		State := _LNEO_Setup()
		try {
			Lifecycle := _LNEO_Lifecycle()
			A := _LNEO_Presentation("A", 7, Lifecycle)
			_LNEO_Publish(0, A)
			Sequence := CompletionMode == "refuse" ? 901 : 902
			_LNEO_QueueNativeDecision(State, _LNEO_SuppressResult(Sequence),
				_LNEO_Receipt(Sequence, A.Token))
			LLM_NavEventOwner_TestDispatch(
				_LNEO_DigitSevenEvent(), State.Port)
			B := _LNEO_Presentation("B", 6, Lifecycle)
			_LNEO_Publish(A, B)
			State.CompleteMode := CompletionMode

			AssertTrue(LLM_NavEventOwner_Drain())
			AssertEqual(7, A.Record.ActiveIdx,
				CompletionMode . ": valid application must still target exact A")
			AssertEqual(1, State.CompleteCalls.Length,
				CompletionMode . ": completion must be attempted exactly once")
			AssertEqual(1, State.Pending.Get(A.Token, 0),
				CompletionMode . ": native refusal must preserve retention")
			AssertTrue(_LLM_NavEventOwnerRecords.Has(A.Token),
				CompletionMode . ": A cannot retire before native completion")
			AssertEqual(1, B.Record.ActiveIdx,
				CompletionMode . ": completion failure must never redirect to B")

			State.CompleteMode := "accept"
			AssertTrue(LLM_NavEventOwner_Drain(),
				CompletionMode . ": a later drain must retry the exact claimed receipt")
			AssertEqual(2, State.PollCalls,
				CompletionMode . ": retry may poll only after completing the claim")
			AssertEqual(2, State.CompleteCalls.Length,
				CompletionMode . ": completion must retry exactly after recovery")
			AssertEqual(0, State.Pending.Get(A.Token, 0),
				CompletionMode . ": successful retry must release native retention")
			AssertFalse(_LLM_NavEventOwnerRecords.Has(A.Token),
				CompletionMode . ": A may retire after exact retry completion")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: completion refusal and throw retain exact owner A",
	_LNEO_CompletionFailureRetainsExactOwner)




