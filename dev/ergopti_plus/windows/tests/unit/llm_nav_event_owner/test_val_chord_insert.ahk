; tests/unit/llm_nav_event_owner/test_val_chord_insert.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Validation Chord Insertion
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; A consumed validation chord (val_modifiers + digit N) is a native jump
; receipt; completing it must arm insertion of slot N for the exact record and
; surface it named, while an Up/Down cycle receipt only moves the active slot
; (llm-val-chord-inserts).
; ==============================================================================

#Requires AutoHotkey v2.0

_LNEO_SlotAcceptProbe(Probe, Record, Surface, SlotIdx) {
	Probe.Calls.Push(Map("record", Record, "surface", Surface, "slot", SlotIdx))
	return true
}

_LNEO_DrainOneReceipt(State, Receipt, Probe) {
	_LNEO_QueueNativeDecision(State,
		_LNEO_SuppressResult(Receipt["seq"]), Receipt)
	AssertTrue(LLM_NavEventOwner_TestDispatch(
		_LNEO_DigitSevenEvent(), State.Port) is Map,
		"the native owner must queue the receipt")
	AssertTrue(LLM_NavEventOwner_Drain(0, 0, 0,
		_LNEO_SlotAcceptProbe.Bind(Probe)),
		"the receipt must drain")
}

_LNEO_JumpReceiptArmsSlotInsertion() {
	State := _LNEO_Setup()
	try {
		A := _LNEO_Presentation("A", 3, _LNEO_Lifecycle())
		_LNEO_Publish(0, A)
		Probe := {Calls: []}
		_LNEO_DrainOneReceipt(State, _LNEO_Receipt(1901, A.Token, 2), Probe)
		AssertEqual(1, Probe.Calls.Length,
			"a consumed validation chord must arm exactly one slot insertion")
		Call := Probe.Calls[1]
		AssertEqual(ObjPtr(A.Record), ObjPtr(Call["record"]),
			"insertion must target the exact record the receipt named")
		AssertEqual(ObjPtr(A.Surface), ObjPtr(Call["surface"]),
			"insertion must target the exact surface the receipt named")
		AssertEqual(2, Call["slot"], "insertion must target the chosen slot")

		Cycle := _LNEO_Receipt(1902, A.Token, 3)
		Cycle["action"] := 1
		Cycle["delta"] := 1
		_LNEO_DrainOneReceipt(State, Cycle, Probe)
		AssertEqual(1, Probe.Calls.Length,
			"an Up/Down cycle receipt must only move the active slot, never insert")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: validation chord receipt arms slot insertion (llm-val-chord-inserts)",
	_LNEO_JumpReceiptArmsSlotInsertion)

_LNEO_SlotAcceptWaitSteps() {
	State := Map("generation", 5, "deadline", 1000)
	AssertEqual("insert", _LLM_SlotAccept_Step(State, 5, false, 10),
		"released modifiers must insert")
	AssertEqual("wait", _LLM_SlotAccept_Step(State, 5, true, 999),
		"a still-held modifier must keep waiting before the deadline")
	AssertEqual("drop", _LLM_SlotAccept_Step(State, 5, true, 1000),
		"a lost key-up must not keep the insertion armed past its deadline")
	AssertEqual("drop", _LLM_SlotAccept_Step(State, 6, false, 10),
		"a newer chord supersedes an older pending insertion")
}

Test("LLM val chord: the release wait inserts, waits, or drops (llm-val-chord-inserts)",
	_LNEO_SlotAcceptWaitSteps)
