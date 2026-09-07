; tests/unit/llm_nav_event_owner/presentation_fixtures.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Presentation Fixtures
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0





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




