; tests/unit/llm_nav_event_owner/test_route_binding.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Route Binding
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

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





