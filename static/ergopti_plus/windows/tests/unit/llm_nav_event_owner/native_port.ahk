; tests/unit/llm_nav_event_owner/native_port.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Deterministic Native Port
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
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





