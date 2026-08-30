; tests/unit/test_llm_nav_event_owner.ahk

; ==============================================================================
; MODULE: LLM Navigation Event Owner Unit Tests
; DESCRIPTION:
; Exercises the production AutoHotkey bridge through an injected native port.
; The port never installs a hook and never derives the expected navigation;
; tests pre-arm native ABI decisions, then independently verify exact-record
; application, receipt completion, retention, and surface-swap ownership.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Deterministic native port =======
; ============================================
; ============================================

global _LNEO_DISPOSITION_PASS := 0
global _LNEO_DISPOSITION_SUPPRESS := 1
global _LNEO_EVENT_DOWN := 1
global _LNEO_EVENT_UP := 2
global _LNEO_PLAN_GENERATION := 41

_LNEO_NewNativeState() {
	State := {
		StartMode: "accept", StopMode: "accept",
		StartReenterMode: "none", StartReenterResult: true,
		SuspendMode: "accept", SuspendReenterMode: "none",
		SuspendReenterResult: true,
		PrepareMode: "accept", CommitPlanMode: "accept",
		StopReenterMode: "none", StopReenterPlan: 0,
		StopReenterPrepareGeneration: -1, StopReenterCommitStatus: false,
		CommitPlanReenterMode: "none", CommitPlanReenterResult: true,
		ReenterPrepareGeneration: 0,
		BeginMode: "accept", BeginReenterMode: "none",
		BeginReenterResult: true, CommitSwapMode: "accept",
		AbortMode: "accept", ClaimMode: "accept", DispatchMode: "accept",
		ProfileBeginMode: "accept", ProfileCommitMode: "accept",
		ProfileAbortMode: "accept", ProfileBeginCalls: [],
		ProfileCommitCalls: [], ProfileAbortCalls: [],
		StagedProfileSwap: 0, CurrentProfileToken: 0,
		CompleteMode: "accept", Started: false, Suspended: false,
		CanStopMode: "accept", CanStopCalls: 0,
		GetOwnerMode: "accept", LastErrorMode: "accept", LastOsError: 0,
		StartCalls: [], StopCalls: 0, StopModes: [], SuspendCalls: [],
		PreparedPlan: 0, PrepareCalls: 0, CommitPlanCalls: [],
		BeginCalls: [], CommitSwapCalls: [], AbortSwapCalls: [], ClaimCalls: [],
		NextTicket: 100, StagedSwap: 0, CurrentToken: 0,
		OwnerIndices: Map(), DispatchCalls: [], DispatchQueue: [],
		ReceiptQueue: [], Claimed: Map(), Pending: Map(),
		CompleteCalls: [], Completed: Map(), PollCalls: 0,
		PollReenterMode: "none", PollReenterResult: true,
		ReenterOnComplete: false, ReentryResult: true,
		ResolverCalls: [], LogCalls: [], LastErrorCalls: 0
	}
	State.Port := Map(
		"start", _LNEO_PortStart.Bind(State),
		"stop", _LNEO_PortStop.Bind(State),
		"suspend", _LNEO_PortSuspend.Bind(State),
		"can_stop", _LNEO_PortCanStop.Bind(State),
		"prepare_plan", _LNEO_PortPreparePlan.Bind(State),
		"commit_plan", _LNEO_PortCommitPlan.Bind(State),
		"begin_swap", _LNEO_PortBeginSwap.Bind(State),
		"commit_swap", _LNEO_PortCommitSwap.Bind(State),
		"abort_swap", _LNEO_PortAbortSwap.Bind(State),
		"begin_profile_swap", _LNEO_PortBeginProfileSwap.Bind(State),
		"commit_profile_swap", _LNEO_PortCommitProfileSwap.Bind(State),
		"abort_profile_swap", _LNEO_PortAbortProfileSwap.Bind(State),
		"profile_pending_mask", _LNEO_PortProfilePendingMask.Bind(State),
		"claim_owner", _LNEO_PortClaimOwner.Bind(State),
		"test_dispatch", _LNEO_PortTestDispatch.Bind(State),
		"poll", _LNEO_PortPoll.Bind(State),
		"complete", _LNEO_PortComplete.Bind(State),
		"pending", _LNEO_PortPending.Bind(State),
		"get_owner", _LNEO_PortGetOwner.Bind(State),
		"last_error", _LNEO_PortLastError.Bind(State))
	return State
}

_LNEO_PortStart(State, Hwnd, WakeMessage) {
	State.StartCalls.Push(Map("hwnd", Hwnd, "wake_message", WakeMessage))
	if State.StartMode == "throw"
		throw Error("injected navigation-owner start failure")
	if State.StartMode != "accept"
		return 0
	State.Started := true
	if State.StartReenterMode == "stop" {
		State.StartReenterMode := "none"
		State.StartReenterResult := LLM_NavEventOwner_Stop()
	} else if State.StartReenterMode == "quiesce" {
		State.StartReenterMode := "none"
		State.StartReenterResult :=
			LLM_NavEventOwner_QuiesceForLifecycle(true)
	} else if State.StartReenterMode == "suspend" {
		State.StartReenterMode := "none"
		Suspend(1)
		State.StartReenterResult := A_IsSuspended
	}
	return 1
}

_LNEO_PortStop(State) {
	State.StopCalls += 1
	Mode := State.StopModes.Length > 0
		? State.StopModes.RemoveAt(1) : State.StopMode
	if State.StopReenterMode == "drain" {
		State.StopReenterMode := "none"
		State.ReentryResult := LLM_NavEventOwner_Drain()
	}
	if Mode == "throw"
		throw Error("injected navigation-owner stop failure")
	if Mode == "pending" {
		State.Suspended := true
		return Map("stopped", false, "pending", true)
	}
	if Mode == "joined_error" {
		State.Started := false
		State.Suspended := false
		State.StagedSwap := 0
		State.CurrentToken := 0
		State.OwnerIndices := Map()
		State.StagedProfileSwap := 0
		State.CurrentProfileToken := 0
		return Map("stopped", true, "diagnostic", true)
	}
	if Mode != "accept"
		return 0
	State.Started := false
	State.Suspended := false
	State.StagedSwap := 0
	State.CurrentToken := 0
	State.OwnerIndices := Map()
	State.StagedProfileSwap := 0
	State.CurrentProfileToken := 0
	State.LastOsError := 0
	if State.StopReenterMode == "plan" {
		State.StopReenterMode := "none"
		State.StopReenterPrepareGeneration :=
			LLM_NavEventOwner_PreparePlan(State.StopReenterPlan, State.Port)
		State.StopReenterCommitStatus :=
			State.StopReenterPrepareGeneration > 0
			&& LLM_NavEventOwner_CommitPlan(
				State.StopReenterPrepareGeneration)
	}
	return 1
}

_LNEO_PortLastError(State) {
	State.LastErrorCalls += 1
	if State.LastErrorMode == "throw"
		throw Error("injected navigation-owner health read failure")
	return State.LastErrorMode == "accept" ? State.LastOsError : -1
}

_LNEO_PortSuspend(State, Value) {
	State.SuspendCalls.Push(Value)
	if Value == 1 && State.SuspendReenterMode == "reserve_render" {
		State.SuspendReenterMode := "none"
		State.SuspendReenterResult := _LLM_TooltipReserveLlmRender()
	} else if Value == 1 && State.SuspendReenterMode == "show_loading" {
		State.SuspendReenterMode := "none"
		State.SuspendReenterResult := TooltipShow(
			[{Text: "loading"}], 0, false, (*) => true)
	} else if Value == 0
			&& State.SuspendReenterMode == "enter_then_ahk_suspend" {
		State.SuspendReenterMode := "none"
		State.SuspendReenterResult :=
			LLM_NavEventOwner_QuiesceForLifecycle(true)
		Suspend(1)
	} else if Value == 0
			&& State.SuspendReenterMode == "health_wake" {
		State.SuspendReenterMode := "none"
		State.LastOsError := 5
		State.Suspended := true
		_LLM_NavEventOwnerOnWake()
		State.SuspendReenterResult := true
	}
	if State.SuspendMode == "throw"
		throw Error("injected navigation-owner suspend failure")
	if State.SuspendMode != "accept"
		return 0
	State.Suspended := Value == 1
	return 1
}

_LNEO_PortCanStop(State) {
	State.CanStopCalls += 1
	if State.CanStopMode == "throw"
		throw Error("injected navigation-owner debt query failure")
	if State.CanStopMode != "accept"
		return 0
	for _, Pending in State.Pending
		if Pending > 0
			return 0
	return State.Claimed.Count == 0 ? 1 : 0
}

_LNEO_PortPreparePlan(State, Plan) {
	State.PrepareCalls += 1
	State.PreparedPlan := Plan
	if State.PrepareMode == "throw"
		throw Error("injected navigation-owner plan failure")
	return State.PrepareMode == "accept" ? _LNEO_PLAN_GENERATION : 0
}

_LNEO_PortCommitPlan(State, Generation) {
	State.CommitPlanCalls.Push(Generation)
	if State.CommitPlanMode == "throw"
		throw Error("injected navigation-owner plan commit failure")
	Status := State.CommitPlanMode == "accept" ? 1 : 0
	if Status == 1 and State.CommitPlanReenterMode == "stop" {
		State.CommitPlanReenterMode := "none"
		LLM_NavEventOwner_Stop()
	} else if Status == 1 and State.CommitPlanReenterMode == "aba" {
		State.CommitPlanReenterMode := "none"
		Plan := State.PreparedPlan
		Port := State.Port
		LLM_NavEventOwner_Stop()
		LLM_NavEventOwner_EnsureStarted(Port)
		State.ReenterPrepareGeneration :=
			LLM_NavEventOwner_PreparePlan(Plan, Port)
	} else if Status == 1 and State.CommitPlanReenterMode == "quiesce" {
		State.CommitPlanReenterMode := "none"
		State.CommitPlanReenterResult :=
			LLM_NavEventOwner_QuiesceForLifecycle(true)
	} else if Status == 1 and State.CommitPlanReenterMode == "suspend" {
		State.CommitPlanReenterMode := "none"
		Suspend(1)
		State.CommitPlanReenterResult := A_IsSuspended
	}
	return Status
}

_LNEO_PortBeginSwap(State, OldToken, NewToken, SlotCount, ActiveIdx,
		RequireIndexMatch := 0) {
	State.BeginCalls.Push(Map(
		"old_token", OldToken, "new_token", NewToken,
		"slot_count", SlotCount, "active_idx", ActiveIdx,
		"require_index_match", RequireIndexMatch))
	if State.BeginReenterMode == "stop" {
		State.BeginReenterMode := "none"
		State.BeginReenterResult := LLM_NavEventOwner_Stop()
	}
	if State.BeginMode == "throw"
		throw Error("injected navigation-owner swap failure")
	if State.BeginMode != "accept"
		return 0
	if State.CurrentToken != OldToken
		return RequireIndexMatch ? -1 : 0
	if RequireIndexMatch
			&& State.OwnerIndices.Get(State.CurrentToken, 0) != ActiveIdx
		return -1
	State.NextTicket += 1
	State.StagedSwap := Map(
		"ticket", State.NextTicket, "old_token", OldToken,
		"new_token", NewToken, "slot_count", SlotCount,
		"active_idx", ActiveIdx,
		"require_index_match", RequireIndexMatch)
	return State.NextTicket
}

_LNEO_PortCommitSwap(State, Ticket) {
	State.CommitSwapCalls.Push(Ticket)
	if State.CommitSwapMode == "throw"
		throw Error("injected navigation-owner swap commit failure")
	if State.CommitSwapMode != "accept" || !(State.StagedSwap is Map)
		return 0
	if State.StagedSwap["ticket"] != Ticket
		return 0
	State.CurrentToken := State.StagedSwap["new_token"]
	if State.CurrentToken > 0
		State.OwnerIndices[State.CurrentToken] := State.StagedSwap["active_idx"]
	State.StagedSwap := 0
	return 1
}

_LNEO_PortAbortSwap(State, Ticket) {
	State.AbortSwapCalls.Push(Ticket)
	if State.AbortMode == "throw"
		throw Error("injected navigation-owner swap abort failure")
	if State.AbortMode != "accept"
		return 0
	if State.StagedSwap is Map && State.StagedSwap["ticket"] == Ticket
		State.StagedSwap := 0
	return 1
}

_LNEO_PortProfilePendingMask(State, Token) {
	Mask := 0
	for Receipt in State.ReceiptQueue {
		if Receipt.Get("action", 0) == 3
				&& Receipt.Get("owner_token", 0) == Token
			Mask |= 1 << (Receipt.Get("target_idx", 0) - 1)
	}
	for _, Receipt in State.Claimed {
		if Receipt.Get("action", 0) == 3
				&& Receipt.Get("owner_token", 0) == Token
			Mask |= 1 << (Receipt.Get("target_idx", 0) - 1)
	}
	return Mask
}

_LNEO_PortBeginProfileSwap(State, ExpectedToken, Plan, NewToken,
		ProfileCount) {
	State.ProfileBeginCalls.Push(Map(
		"expected_token", ExpectedToken, "plan", Plan,
		"new_token", NewToken, "profile_count", ProfileCount))
	if State.ProfileBeginMode == "throw"
		throw Error("injected profile-owner preparation failure")
	if State.ProfileBeginMode != "accept"
			&& State.ProfileBeginMode != "malformed_mask"
			&& State.ProfileBeginMode != "malformed_ticket"
		return 0
	if State.CurrentProfileToken != ExpectedToken
		return 0
	State.NextTicket += 1
	State.StagedProfileSwap := Map(
		"ticket", State.NextTicket, "new_token", NewToken)
	if State.ProfileBeginMode == "malformed_mask"
		return Map("ticket", State.NextTicket, "pending_mask", 0xFFFF)
	if State.ProfileBeginMode == "malformed_ticket"
		return Map("ticket", 0, "pending_mask", 0)
	return Map("ticket", State.NextTicket,
		"pending_mask", _LNEO_PortProfilePendingMask(State, ExpectedToken))
}

_LNEO_PortCommitProfileSwap(State, Ticket) {
	State.ProfileCommitCalls.Push(Ticket)
	if State.ProfileCommitMode == "throw"
		throw Error("injected profile-owner commit failure")
	if State.ProfileCommitMode != "accept"
		return 0
	if !(State.StagedProfileSwap is Map)
			|| State.StagedProfileSwap["ticket"] != Ticket
		return 0
	State.CurrentProfileToken := State.StagedProfileSwap["new_token"]
	State.StagedProfileSwap := 0
	return 1
}

_LNEO_PortAbortProfileSwap(State, Ticket) {
	State.ProfileAbortCalls.Push(Ticket)
	if State.ProfileAbortMode == "throw"
		throw Error("injected profile-owner abort failure")
	if State.ProfileAbortMode != "accept"
		return 0
	if State.StagedProfileSwap is Map
			&& State.StagedProfileSwap["ticket"] == Ticket
		State.StagedProfileSwap := 0
	return 1
}

_LNEO_PortClaimOwner(State, Token, ExpectedIdx) {
	State.ClaimCalls.Push(Map("token", Token, "expected_idx", ExpectedIdx))
	if State.ClaimMode == "throw"
		throw Error("injected navigation-owner claim failure")
	if State.ClaimMode != "accept"
		return 0
	if State.CurrentToken != Token
			|| State.OwnerIndices.Get(Token, 0) != ExpectedIdx
		return 0
	State.CurrentToken := 0
	return 1
}

_LNEO_PortTestDispatch(State, Event) {
	State.DispatchCalls.Push(Event)
	if State.DispatchMode == "throw"
		throw Error("injected navigation-owner dispatch failure")
	if State.DispatchMode != "accept" || State.DispatchQueue.Length == 0
		return 0
	Envelope := State.DispatchQueue.RemoveAt(1)
	Receipt := Envelope.Get("receipt", 0)
	if Receipt is Map {
		ReceiptCopy := Receipt.Clone()
		State.ReceiptQueue.Push(ReceiptCopy)
		Token := ReceiptCopy.Get("owner_token", 0)
		if Token == State.CurrentToken
			State.OwnerIndices[Token] := ReceiptCopy.Get("target_idx", 0)
		State.Pending[Token] := State.Pending.Get(Token, 0) + 1
	}
	return Envelope["result"].Clone()
}

_LNEO_PortPoll(State) {
	State.PollCalls += 1
	if State.ReceiptQueue.Length == 0
		return 0
	Receipt := State.ReceiptQueue.RemoveAt(1)
	State.Claimed[Receipt["seq"]] := Receipt
	if State.PollReenterMode == "suspend" {
		State.PollReenterMode := "none"
		Suspend(1)
	} else if State.PollReenterMode == "quiesce" {
		State.PollReenterMode := "none"
		State.PollReenterResult :=
			LLM_NavEventOwner_QuiesceForLifecycle(true)
	}
	return Receipt.Clone()
}

_LNEO_PortComplete(State, Sequence, OwnerToken, AppliedIndex) {
	State.CompleteCalls.Push(Map(
		"seq", Sequence, "owner_token", OwnerToken,
		"applied_idx", AppliedIndex))
	if State.ReenterOnComplete && State.CompleteCalls.Length == 1
		State.ReentryResult := LLM_NavEventOwner_Drain()
	if State.CompleteMode == "throw"
		throw Error("injected navigation receipt completion failure")
	if State.CompleteMode != "accept" || !State.Claimed.Has(Sequence)
		return 0
	Receipt := State.Claimed[Sequence]
	if Receipt.Get("owner_token", 0) != OwnerToken
			|| Receipt.Get("target_idx", 0) != AppliedIndex
		return 0
	if State.Completed.Has(Sequence)
		return 0
	State.Completed[Sequence] := true
	State.Claimed.Delete(Sequence)
	Pending := State.Pending.Get(OwnerToken, 0)
	State.Pending[OwnerToken] := Max(0, Pending - 1)
	return 1
}

_LNEO_PortPending(State, Token) {
	return State.Pending.Get(Token, 0)
}

_LNEO_PortGetOwner(State, Token) {
	if State.GetOwnerMode == "throw"
		throw Error("injected navigation-owner read failure")
	if State.GetOwnerMode != "accept"
		return 0
	if State.CurrentToken != Token
		return 0
	return State.OwnerIndices.Get(Token, 0)
}

_LNEO_RenderProbe(State, Record, Surface) {
	State.Calls.Push(Map("record", Record, "surface", Surface))
	State.Critical.Push(A_IsCritical)
	if State.Results.Length == 0
		return 0
	return State.Results.RemoveAt(1)
}

_LNEO_RenderAndPaintProbe(State, Record, Surface) {
	Result := _LNEO_RenderProbe(State, Record, Surface)
	if (Result is Integer) && Result > 0
		Surface.RenderedActiveIdx := Record.ActiveIdx
	return Result
}

_LNEO_RepaintDegradeProbe(State, Record) {
	State.Calls.Push(Record)
	State.Critical.Push(A_IsCritical)
	if State.Throw
		throw Error("injected repaint degradation failure")
	return State.Result
}

_LNEO_QueueNativeDecision(State, Result, Receipt := 0) {
	Envelope := Map("result", Result)
	if Receipt is Map
		Envelope["receipt"] := Receipt
	State.DispatchQueue.Push(Envelope)
}





; ========================================
; ========================================
; ======= 2/ Presentation fixtures =======
; ========================================
; ========================================

_LNEO_Setup() {
	global _TooltipActiveSurface
	try LLM_NavEventOwner_Stop(false, true)
	_TooltipActiveSurface := 0
	State := _LNEO_NewNativeState()
	AssertTrue(LLM_NavEventOwner_EnsureStarted(State.Port),
		"the fake native owner must start through the production bridge")
	_LLM_NavEventOwnerSetServiceTimer(false)
	State.BeginCalls := []
	State.CommitSwapCalls := []
	State.AbortSwapCalls := []
	return State
}

_LNEO_Teardown() {
	global _TooltipActiveSurface
	try LLM_NavEventOwner_Stop(false, true)
	_TooltipActiveSurface := 0
}

; Watchdog-state tests invoke the service callback manually at exact boundaries.
; Keep the production logical ``armed`` state but cancel the real 100 ms timer,
; otherwise a loaded full-suite run can execute that callback between two
; adjacent assertions and consume the fixture before the test-owned tick.
_LNEO_DisarmNativeServiceTimerForManualTick() {
	global _LLM_NavEventOwnerServiceFn
	SetTimer(_LLM_NavEventOwnerServiceFn, 0)
}

_LNEO_Lifecycle(OfferId := 77) {
	return {
		OfferId: OfferId, AcceptSource: Map(), AppName: "owner-test.exe",
		Slots: [], Suggested: false, Outcome: "", TimeoutOrigin: 0,
		TimeoutDurationMs: 0
	}
}

_LNEO_Presentation(Label, SlotCount, Lifecycle, ActiveIdx := 1,
		RequireIndexMatch := false) {
	Slots := []
	Loop SlotCount
		Slots.Push(Label . A_Index)
	Lifecycle.Slots := Slots.Clone()
	Record := {
		Kind: "prediction", Slots: Slots.Clone(), ActiveIdx: ActiveIdx,
		NavOwnerRequireExactIndex:
			(RequireIndexMatch is Integer) && RequireIndexMatch == true,
		Lifecycle: Lifecycle, IsFinal: true, ShownAt: 0,
		Generation: SlotCount, TimeoutRemainingMs: 0
	}
	Surface := {
		LlmPresented: Record, Generation: SlotCount,
		RenderedActiveIdx: ActiveIdx,
		Rows: [], Border: 0, ContentHwnds: [], BorderHwnds: []
	}
	Token := LLM_NavEventOwner_AttachRecord(Record, Surface)
	AssertTrue(Token is Integer && Token > 0,
		"each detached presentation must receive a nonzero owner token")
	return {Record: Record, Surface: Surface, Token: Token}
}

_LNEO_Publish(Previous, Candidate) {
	global _TooltipActiveSurface
	OldSurface := IsObject(Previous) ? Previous.Surface : 0
	Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
		OldSurface, Candidate.Surface)
	AssertTrue(Transaction is Map,
		"the fake native owner must fence the deterministic surface swap")
	_TooltipActiveSurface := Candidate.Surface
	AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Transaction),
		"the deterministic surface swap must commit through the real bridge")
	return Transaction
}

_LNEO_DigitSevenEvent() {
	return Map(
		"vk", 0x37, "sc", 0x08, "modifiers", 0,
		"kind", _LNEO_EVENT_DOWN, "injected", 0, "extra_info", 0)
}

_LNEO_Receipt(Sequence, OwnerToken, TargetIdx := 7) {
	return Map(
		"seq", Sequence, "owner_token", OwnerToken,
		"owner_epoch", OwnerToken, "plan_generation", _LNEO_PLAN_GENERATION,
		"route_idx", 8, "action", 2, "delta", 0,
		"from_idx", 1, "target_idx", TargetIdx, "pass_through", 0)
}

_LNEO_SuppressResult(Sequence) {
	return Map(
		"disposition", _LNEO_DISPOSITION_SUPPRESS,
		"receipt_created", 1, "route_idx", 8, "seq", Sequence)
}

_LNEO_PassResult() {
	return Map(
		"disposition", _LNEO_DISPOSITION_PASS,
		"receipt_created", 0, "route_idx", 0xFF, "seq", 0)
}

_LNEO_Plan() {
	PhysicalIds := [
		"sc0148", "sc0150", "vk0031", "vk0032", "vk0033", "vk0034",
		"vk0035", "vk0036", "vk0037", "vk0038", "vk0039", "vk0030"
	]
	Plan := []
	Loop 12 {
		Plan.Push(Map(
			"route_marker", A_Index,
			"physical_id", PhysicalIds[A_Index],
			"jump_idx", A_Index <= 2 ? 0 : A_Index - 2))
	}
	return Plan
}

_LNEO_ResolveUsPhysicalKey(State, Key) {
	State.ResolverCalls.Push(Key)
	LowerKey := StrLower(Key)
	if LowerKey == "up"
		return Map("axis", "sc", "code", 0x148,
			"implicit_modifiers", "")
	if LowerKey == "down"
		return Map("axis", "sc", "code", 0x150,
			"implicit_modifiers", "")
	if RegExMatch(LowerKey, "^[0-9]$")
		return Map("axis", "vk", "code", Ord(LowerKey),
			"implicit_modifiers", "")
	return false
}

_LNEO_CaptureLog(State, Message) {
	State.LogCalls.Push(Message)
}





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

_LNEO_CompleteTwelveRoutePlanIsForwardedAndCommitted() {
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_Plan()
		Generation := LLM_NavEventOwner_PreparePlan(Plan, State.Port)
		AssertEqual(_LNEO_PLAN_GENERATION, Generation,
			"the native generation must cross the bridge unchanged")
		AssertEqual(1, State.PrepareCalls,
			"the complete navigation plan must be prepared exactly once")
		AssertEqual(ObjPtr(Plan), ObjPtr(State.PreparedPlan),
			"the bridge must forward the exact immutable plan object")
		AssertEqual(12, State.PreparedPlan.Length,
			"the native owner must receive Up, Down, and all ten digit routes")
		SubjectCount := 0
		Loop State.PreparedPlan.Length {
			SubjectCount += 1
			AssertEqual(A_Index,
				State.PreparedPlan[A_Index]["route_marker"],
				"the bridge must preserve every route and its ordering")
		}
		AssertEqual(12, SubjectCount,
			"the route-class assertion must not pass over an empty subject set")
		AssertTrue(LLM_NavEventOwner_CommitPlan(Generation),
			"the staged twelve-route generation must commit")
		AssertEqual(1, State.CommitPlanCalls.Length,
			"the native plan generation must be committed exactly once")
		AssertEqual(Generation, State.CommitPlanCalls[1],
			"commit must name the exact prepared generation")

		for PrepareMode in ["refuse", "throw"] {
			State.PrepareMode := PrepareMode
			AssertEqual(0,
				LLM_NavEventOwner_PreparePlan(Plan, State.Port),
				PrepareMode . ": a failed plan preparation must not publish a generation")
		}
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: complete twelve-route plan crosses one native generation",
	_LNEO_CompleteTwelveRoutePlanIsForwardedAndCommitted)

_LNEO_ProductionBindingSelectsInjectedNativeOwner() {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerRecoveryHandles
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound,
		SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot,
		TriggerAhk: _LLM_Menu_TriggerAhk,
		TriggerHandle: _LLM_Menu_TriggerHandle,
		RecoveryHandles: _LLM_Menu_TriggerRecoveryHandles
	}
	State := 0
	try {
		_LLM_Menu_NavHotkeysBound := []
		_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
		_LLM_Menu_NavActiveSlot := 0
		_LLM_Menu_TriggerAhk := ""
		_LLM_Menu_TriggerHandle := ""
		_LLM_Menu_TriggerRecoveryHandles := []
		State := _LNEO_Setup()
		CandidateMenu := Map(
			"nav_modifiers", "ctrl", "val_modifiers", "alt")
		Bound := LLM_Menu_BindNavHotkeys(CandidateMenu, 0, 0,
			_LNEO_CaptureLog.Bind(State), 0,
			_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)

		AssertTrue((Bound is Integer) && Bound == 1,
			"the real menu binder must publish its native generation")
		AssertEqual(0, State.LogCalls.Length,
			"a valid native-only binding must not enter a failure fallback")
		AssertEqual(1, State.PrepareCalls,
			"the real binder must select the injected native event owner")
		AssertEqual(1, State.CommitPlanCalls.Length,
			"the real binder must commit exactly its one prepared generation")
		AssertEqual(_LNEO_PLAN_GENERATION, State.CommitPlanCalls[1],
			"the menu publication must commit the generation returned by native")
		AssertEqual(12, State.PreparedPlan.Length,
			"native binding must replace all twelve legacy HotIf routes together")
		AssertTrue(State.ResolverCalls.Length >= 12,
			"the production plan must resolve a nonempty physical subject set")
		ResolvedKeys := Map()
		for Key in State.ResolverCalls
			ResolvedKeys[StrLower(Key)] := true
		AssertEqual(12, ResolvedKeys.Count,
			"the real resolver must observe Up, Down, and all ten digits")
		ExpectedSpecs := [
			"~^Up", "~^Down", "!1", "!2", "!3", "!4",
			"!5", "!6", "!7", "!8", "!9", "!0"
		]
		SeenPhysical := Map()
		Loop 12 {
			Entry := State.PreparedPlan[A_Index]
			AssertEqual(ExpectedSpecs[A_Index], Entry["spec"],
				"the native plan must preserve the exact logical route order")
			PhysicalId := Entry.Get("physical_id", "")
			AssertTrue(PhysicalId != "" && !SeenPhysical.Has(PhysicalId),
				"each production route must own one distinct physical identity")
			SeenPhysical[PhysicalId] := true
		}
		AssertEqual(12, SeenPhysical.Count,
			"the native route oracle must not pass over an empty plan")
		AssertEqual(1, _LLM_Menu_NavActiveSlot,
			"successful native commit must publish the candidate slot")
		AssertEqual(ObjPtr(State.PreparedPlan),
			ObjPtr(_LLM_Menu_NavHotkeysBound),
			"the binder must publish the exact plan accepted by native")
	} finally {
		_LLM_Menu_NavHotkeysBound := Saved.Bound
		_LLM_Menu_NavSlotPlans := Saved.SlotPlans
		_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
		_LLM_Menu_TriggerAhk := Saved.TriggerAhk
		_LLM_Menu_TriggerHandle := Saved.TriggerHandle
		_LLM_Menu_TriggerRecoveryHandles := Saved.RecoveryHandles
		if IsObject(State)
			_LNEO_Teardown()
	}
}

Test("LLM nav event owner: real menu binding selects one native twelve-route plan",
	_LNEO_ProductionBindingSelectsInjectedNativeOwner)





; =====================================
; =====================================
; ======= 5/ No-hook native ABI =======
; =====================================
; =====================================

_LNEO_NativeEvent(Vk, Sc, Modifiers, Kind, Injected := 0,
		ExtraInfo := 0) {
	return Map(
		"vk", Vk, "sc", Sc, "modifiers", Modifiers,
		"kind", Kind, "injected", Injected, "extra_info", ExtraInfo)
}

_LNEO_AssertNativePassWithoutReceipt(Result, Context) {
	AssertTrue(Result is Map, Context . ": dispatch must return an ABI Map")
	AssertEqual(_LNEO_DISPOSITION_PASS, Result["disposition"],
		Context . ": rejected input must pass through")
	AssertEqual(0, Result["receipt_created"],
		Context . ": rejected input must not reserve a receipt")
}

_LNEO_RealNativeAbiRoundTripDoesNotStartHook() {
	global _LNEO_EVENT_UP
	State := _LNEO_NewNativeState()
	OwnerToken := 0xA707
	try {
		AssertTrue(_LLM_NavEventOwnerNativeStop(),
			"native ABI reset must be harmless before Start")
		Built := _LLM_Menu_BuildNavBindingPlan(
			Map("nav_modifiers", "ctrl", "val_modifiers", "alt"))
		AssertTrue(Built is Map,
			"the ABI test must use the real production plan builder")
		Plan := Built["plan"]
		AssertTrue(_LLM_Menu_AttachPlanPhysicalIdentities(Plan,
			_LNEO_ResolveUsPhysicalKey.Bind(State)),
			"the ABI test must attach deterministic US physical descriptors")
		AssertEqual(12, Plan.Length,
			"the native marshaling subject must contain every production route")

		Generation := _LLM_NavEventOwnerNativePreparePlan(Plan)
		AssertTrue(Generation is Integer && Generation > 0,
			"native plan marshaling must return a nonzero generation")
		AssertTrue(_LLM_NavEventOwnerNativeCommitPlan(Generation),
			"the exact marshaled generation must commit")
		Ticket := _LLM_NavEventOwnerNativeBeginSwap(0, OwnerToken, 7, 1)
		AssertTrue(Ticket is Integer && Ticket > 0,
			"the native owner ABI must stage a nonzero swap ticket")
		AssertTrue(_LLM_NavEventOwnerNativeCommitSwap(Ticket),
			"the staged owner must commit without starting the hook")
		AssertEqual(1, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"the native owner snapshot must initially expose index one")

		DigitDown := _LNEO_NativeEvent(0x37, 0x008, 0x02, 1)
		DigitDecision := _LLM_NavEventOwnerNativeTestDispatch(DigitDown)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			DigitDecision["disposition"],
			"a physical Alt+7 down must be atomically suppressed")
		AssertEqual(1, DigitDecision["receipt_created"],
			"suppression must reserve its receipt before returning")
		DigitUp := _LNEO_NativeEvent(0x37, 0x008, 0x02, _LNEO_EVENT_UP)
		DigitUpDecision := _LLM_NavEventOwnerNativeTestDispatch(DigitUp)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			DigitUpDecision["disposition"],
			"the matching key-up must balance a suppressed key-down")
		AssertEqual(0, DigitUpDecision["receipt_created"],
			"the balancing key-up must not create a second receipt")
		DigitReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(DigitDecision["seq"], DigitReceipt["seq"],
			"Poll must return the exact reserved sequence")
		AssertEqual(OwnerToken, DigitReceipt["owner_token"],
			"the receipt must retain the exact native owner token")
		AssertEqual(7, DigitReceipt["target_idx"],
			"Alt+7 must marshal as one-based target seven")
		AssertEqual(7, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"native semantic state must advance before AHK completion")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			DigitReceipt["seq"], OwnerToken, 7),
			"completion must marshal sequence, token, and applied index")

		ArrowDecision := _LLM_NavEventOwnerNativeTestDispatch(
			_LNEO_NativeEvent(0x26, 0x148, 0x01, 1))
		AssertEqual(_LNEO_DISPOSITION_PASS, ArrowDecision["disposition"],
			"Ctrl+Up navigation must remain pass-through")
		AssertEqual(1, ArrowDecision["receipt_created"],
			"a pass-through arrow must still own one navigation receipt")
		ArrowReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(6, ArrowReceipt["target_idx"],
			"Ctrl+Up must cycle owner index seven to six")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			ArrowReceipt["seq"], OwnerToken, 6),
			"the pass-through arrow receipt must complete exactly once")

		SendLevelBase := 0xFFC3D44D
		LowDown := _LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 1,
			SendLevelBase - 1)
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(LowDown),
			"SendLevel equal to InputLevel")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02,
					_LNEO_EVENT_UP, 1, SendLevelBase - 1)),
			"keyup after fail-open SendLevel")
		AssertEqual(6, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"ineligible injection must leave native owner state unchanged")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 2)),
			"lower-integrity injected keydown")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02,
					_LNEO_EVENT_UP, 2)),
			"lower-integrity injected keyup")
		AssertEqual(6, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"lower-integrity input must never navigate the native owner")

		HighDown := _LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 1,
			SendLevelBase - 2)
		HighDecision := _LLM_NavEventOwnerNativeTestDispatch(HighDown)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			HighDecision["disposition"],
			"SendLevel above InputLevel must be eligible")
		AssertEqual(1, HighDecision["receipt_created"],
			"eligible injected input must reserve a receipt")
		HighUp := _LNEO_NativeEvent(0x31, 0x002, 0x02,
			_LNEO_EVENT_UP, 1, SendLevelBase - 2)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			_LLM_NavEventOwnerNativeTestDispatch(HighUp)["disposition"],
			"eligible injected key-up must balance suppression")
		HighReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(1, HighReceipt["target_idx"],
			"eligible injected Alt+1 must navigate to one")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			HighReceipt["seq"], OwnerToken, 1))
		AssertEqual(0,
			_LLM_NavEventOwnerNativePendingForToken(OwnerToken),
			"all native receipts must be released after exact completion")
		AssertTrue(_LLM_NavEventOwnerNativeClaimOwner(OwnerToken, 1),
			"the real ABI must atomically claim exact owner index one")
		AssertEqual(0, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"successful native acceptance must clear the active owner")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(DigitDown),
			"navigation after native acceptance claim")
		AssertEqual(0, _LLM_NavEventOwnerNativePollReceipt(),
			"duplicate polling after completion must be idempotently empty")
	} finally {
		try _LLM_NavEventOwnerNativeStop()
		finally _LLM_NavEventOwnerNativeUnload()
	}
}

Test("LLM nav event owner: real ABI round-trip never calls native Start",
	_LNEO_RealNativeAbiRoundTripDoesNotStartHook)





; ============================================
; ============================================
; ======= 6/ Profile receipt ownership =======
; ============================================
; ============================================

_LNEO_ProfilePlan() {
	Plan := []
	Loop 9
		Plan.Push(Map(
			"profile_idx", A_Index,
			"physical_id", "^vk00" . (30 + A_Index)))
	return Plan
}

_LNEO_QueueProfileReceipt(State, Sequence, Token, TargetIdx) {
	Receipt := Map(
		"seq", Sequence,
		"owner_token", Token,
		"owner_epoch", Token,
		"plan_generation", 1,
		"route_idx", TargetIdx,
		"action", 3,
		"delta", 0,
		"from_idx", 0,
		"target_idx", TargetIdx,
		"pass_through", 0)
	State.ReceiptQueue.Push(Receipt)
	State.Pending[Token] := State.Pending.Get(Token, 0) + 1
}

_LNEO_ProfileSelectProbe(State, ProfileId) {
	State.Calls.Push(ProfileId)
	if State.QuiesceDuring
		State.QuiesceResult := LLM_NavEventOwner_QuiesceForLifecycle(true)
	return State.Status
}

_LNEO_ProfileBeginAlwaysClosesOrQuarantinesFence() {
	Plan := _LNEO_ProfilePlan()
	Cases := [
		Map("mode", "refuse", "stops", 0, "aborts", 0),
		Map("mode", "throw", "stops", 1, "aborts", 0),
		Map("mode", "malformed_mask", "stops", 0, "aborts", 1),
		Map("mode", "malformed_ticket", "stops", 1, "aborts", 0)
	]
	for Scenario in Cases {
		State := _LNEO_Setup()
		try {
			State.ProfileBeginMode := Scenario["mode"]
			Result := LLM_NavEventOwner_BeginProfileSwap(
				Plan, ["a"], 1, ["a"], State.Port)
			AssertFalse(Result is Map,
				"a refused or ambiguous Begin must never publish a transaction")
			AssertEqual(Scenario["stops"], State.StopCalls,
				Scenario["mode"] . " must use the expected quarantine boundary")
			AssertEqual(Scenario["aborts"], State.ProfileAbortCalls.Length,
				Scenario["mode"] . " must use the expected exact Abort boundary")
			AssertFalse(State.StagedProfileSwap is Map,
				Scenario["mode"] . " must not leave a silent profile fence armed")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: malformed profile Begin closes its fence (ahk-029)",
	_LNEO_ProfileBeginAlwaysClosesOrQuarantinesFence)

_LNEO_ProfileReceiptRetainsAdmittedTargetAcrossReorder() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerProfileOwners
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First),
			"the first immutable profile order must publish")
		OldToken := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8001, OldToken, 2)

		Second := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["b", "c"], 1, ["b", "c"], State.Port)
		AssertTrue(Second is Map
			&& LLM_NavEventOwner_CommitProfileSwap(Second),
			"deleting an earlier profile must preserve a pending target")
		AssertTrue(_LLM_NavEventOwnerProfileOwners.Has(OldToken),
			"the retired order must remain retained while its receipt is pending")
		Probe := {Calls: [], Status: 1, QuiesceDuring: false,
			QuiesceResult: true}
		AssertTrue(LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe)))
		AssertEqual(1, Probe.Calls.Length,
			"one profile receipt must cause exactly one selection")
		AssertEqual("b", Probe.Calls[1],
			"the receipt must resolve through its admitted old order")
		AssertFalse(_LLM_NavEventOwnerProfileOwners.Has(OldToken),
			"the retired order may collect only after exact completion")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: admitted profile target survives earlier deletion (ahk-029)",
	_LNEO_ProfileReceiptRetainsAdmittedTargetAcrossReorder)

_LNEO_ProfileTargetDeletionIsRefusedWhilePending() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global _LLM_NavEventOwnerActiveProfileToken
	SavedMenu := _LLM_Menu
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	_LLM_Menu_ProfileHotkeyOwner := 0
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		LLM_PROFILE_BUILTIN_ORDER := []
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu := Map(
			"enabled", true,
			"profile_id", "a",
			"app_profile_overrides", Map(),
			"user_profiles", [
				Map("id", "a"), Map("id", "b"), Map("id", "c")])
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		_LLM_Menu_ProfileHotkeyOwner := Map(
			"ready", true, "degraded", false,
			"native", true, "plan", Plan)
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8002, Token, 2)
		Candidate := LLM_Menu_DeepClone(_LLM_Menu)
		AssertTrue(_LLM_Menu_DeleteProfileCandidate(Candidate, "b"),
			"the test must exercise the real detached deletion mutator")
		Rejected := _LLM_Menu_PrepareProfileOwnerCandidate(Candidate)
		AssertEqual(0, Rejected,
			"the real menu preparation must refuse deletion of its pending target")
		AssertEqual(1, State.ProfileBeginCalls.Length,
			"known retired debt must refuse before opening a second fence")
		AssertEqual(0, State.ProfileAbortCalls.Length)
		AssertEqual(Token, State.CurrentProfileToken,
			"refusal must retain the prior native owner")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: pending profile target blocks its deletion (ahk-029)",
	_LNEO_ProfileTargetDeletionIsRefusedWhilePending)

_LNEO_DeleteProfileB(Candidate) {
	return _LLM_Menu_DeleteProfileCandidate(Candidate, "b")
}

_LNEO_DisabledRetiredTargetBlocksDurableDelete() {
	global Features, _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global _LLM_NavEventOwnerActiveProfileToken, _LMT_WriterCalls
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	_LLM_Menu_ProfileHotkeyOwner := 0
	Previous := _LMT_InstallFixture()
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		LLM_PROFILE_BUILTIN_ORDER := []
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu["enabled"] := true
		_LLM_Menu["profile_id"] := "a"
		_LLM_Menu["app_profile_overrides"] := Map()
		_LLM_Menu["user_profiles"] := [
			Map("id", "a"), Map("id", "b"), Map("id", "c")]
		AssertTrue(_LLM_Menu_SyncToFeatures(Features, _LLM_Menu))
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		OldToken := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8004, OldToken, 2)
		Disabled := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 0, ["a", "b", "c"], State.Port)
		AssertTrue(Disabled is Map
			&& LLM_NavEventOwner_CommitProfileSwap(Disabled),
			"the active profile surface must disable while retaining old debt")
		_LLM_Menu["enabled"] := false
		Features["llm"]["enabled"] := false
		_LLM_Menu_ProfileHotkeyOwner := Map(
			"ready", true, "degraded", false,
			"native", true, "plan", Plan)
		_LMT_WriterCalls := 0
		AssertFalse(LLM_Menu_CommitMutation(
			"the pending profile deletion", _LNEO_DeleteProfileB,
			0, _LMT_Writer, _LMT_Notify, _LMT_Acquire,
			_LMT_Settle, _LMT_Quiesce, _LMT_Collect),
			"retired receipt debt must refuse the complete menu transaction")
		AssertEqual(0, _LMT_WriterCalls,
			"pending-target refusal must precede durable config I/O")
		AssertEqual(3, _LLM_Menu["user_profiles"].Length,
			"the failed candidate must not mutate live profiles")
	} finally {
		_LNEO_Teardown()
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
		_LMT_RestoreFixture(Previous)
	}
}

Test("LLM nav event owner: disabled retired target blocks durable deletion (ahk-029)",
	_LNEO_DisabledRetiredTargetBlocksDurableDelete)

_LNEO_ProfileEffectDoesNotReplayAfterAckFailure() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerClaimedReceipt
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8003, Token, 2)
		Probe := {Calls: [], Status: 1, QuiesceDuring: true,
			QuiesceResult: true}
		State.CompleteMode := "refuse"
		LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(1, Probe.Calls.Length)
		AssertFalse(Probe.QuiesceResult,
			"lifecycle quiescence must not begin during the profile effect")
		AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map
			&& _LLM_NavEventOwnerClaimedReceipt.Get(
				"profile_effect_done", false),
			"a completed effect must remain marked while its ACK is retried")

		State.CompleteMode := "accept"
		LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(1, Probe.Calls.Length,
			"an ACK retry must never replay the durable profile selection")
		AssertFalse(_LLM_NavEventOwnerClaimedReceipt is Map,
			"the exact claimed receipt must clear after its ACK succeeds")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: profile effect is exactly-once across ACK retry (ahk-029)",
	_LNEO_ProfileEffectDoesNotReplayAfterAckFailure)

_LNEO_ShutdownPreflightDrainsBeforeDebtProof() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerShutdownFenced
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8005, Token, 2)
		Probe := {Calls: [], Status: 1, QuiesceDuring: false,
			QuiesceResult: true}
		AssertTrue(LLM_NavEventOwner_PrepareShutdown(
			_LNEO_ProfileSelectProbe.Bind(Probe), State.Port),
			"shutdown may proceed only after the fenced receipt drain")
		AssertEqual(1, Probe.Calls.Length)
		AssertEqual("b", Probe.Calls[1])
		AssertEqual(1, State.CanStopCalls,
			"native terminal debt must be checked after AHK drain")
		AssertEqual(1, State.SuspendCalls.Length)
		AssertEqual(1, State.SuspendCalls[1],
			"native admission must be fenced before profile selection")
		AssertTrue(_LLM_NavEventOwnerShutdownFenced)
		AssertTrue(LLM_NavEventOwner_CancelShutdown(),
			"a later shutdown refusal must resume the native owner")
		AssertEqual(2, State.SuspendCalls.Length)
		AssertEqual(0, State.SuspendCalls[2])
		AssertFalse(_LLM_NavEventOwnerShutdownFenced)
		State.CanStopMode := "refuse"
		AssertFalse(LLM_NavEventOwner_PrepareShutdown(0, State.Port),
			"native debt refusal must keep shutdown reversible")
		AssertEqual(4, State.SuspendCalls.Length)
		AssertEqual(1, State.SuspendCalls[3])
		AssertEqual(0, State.SuspendCalls[4],
			"a refused debt proof must compensate native suspension")
		AssertFalse(_LLM_NavEventOwnerShutdownFenced)
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: shutdown fence drains profiles before debt proof (ahk-029)",
	_LNEO_ShutdownPreflightDrainsBeforeDebtProof)

_LNEO_ShutdownSourceCompensatesEveryRefusal() {
	Body := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	AssertTrue(Body != "", "the production shutdown handler must be scanned")
	Preflight := InStr(Body, "LLM_NavEventOwner_PrepareShutdown()")
	Bundle := InStr(Body, "ReloadTerminalHandoffClaim(reason)")
	Terminal := InStr(Body, "ShutdownTerminal := true")
	Stop := InStr(Body, "LLM_NavEventOwner_Stop(false, true)")
	AssertTrue(Preflight > 0 && Bundle > Preflight,
		"profile drain must run before the config bundle can block persistence")
	AssertTrue(Terminal > Bundle && Stop > Terminal,
		"shutdown may become irreversible only after every refusal gate")
	AssertTrue(InStr(Body, "if !ShutdownTerminal") > 0
		&& InStr(Body, "LLM_NavEventOwner_CancelShutdown()") > 0,
		"the outer finally must resume native admission after every refusal")
}

Test("LLM lifecycle: every shutdown refusal resumes profile admission (ahk-029)",
	_LNEO_ShutdownSourceCompensatesEveryRefusal)
