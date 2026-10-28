; tests/unit/modules/llm/api/test_llm_api_aux_timer_retirement.ahk

; ==============================================================================
; MODULE: Native Auxiliary Timer Retirement Tests
; DESCRIPTION:
; Genuine one-shot native timers must release the exact callbacks they execute
; or cancel. Passive witnesses retain only counters, never timer/owner references.
; ==============================================================================

#Requires AutoHotkey v2.0

; A passive witness has no reference to the request, owner or callbacks.
class _LLM_TestRetirementWitness {
	__New(Counter) {
		this.Counter := Counter
	}
	__Delete() {
		this.Counter["deleted"] += 1
	}
}

_LLM_TestReleaseIndependentWitness(Counter) {
	Witness := _LLM_TestRetirementWitness(Counter)
}


_LlmAuxTimer_Observe(Witness, Counter, *) {
	Counter["fired"] += 1
}

_LlmAuxTimer_RejectSchedule(Callback, Period) {
	throw Error("Injected native scheduling admission refusal.")
}

_LlmAuxTimer_RunLifetime(Mode, Counter) {
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt
	SavedOwners := _LLM_AuxOwners, SavedDebt := _LLM_AuxCleanupDebt
	Owner := 0, Callback := 0
	PreviousCritical := Critical("Off")
	try {
		_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map()
		Owner := LLM_AuxBegin("test_native_timer_lifetime")
		Callback := _LlmAuxTimer_Observe.Bind(_LLM_TestRetirementWitness(Counter), Counter)
		if Mode == "refused" {
			AssertFalse(LLM_AuxSchedule(Owner, Callback, -1, _LlmAuxTimer_RejectSchedule),
				"a rejected scheduler acquires no native timer")
			AssertFalse(LLM_AuxIsCurrent(Owner), "a refused native schedule retires its exact owner")
		} else {
			AssertTrue(LLM_AuxSchedule(Owner, Callback, Mode == "cancelled" ? -10000 : -1),
				"the actual AHK scheduler must acknowledge the genuine one-shot timer")
			if Mode == "executed" {
				Started := A_TickCount
				while Counter["fired"] == 0 && TickElapsed(Started) < 2000
					Sleep(10)
				AssertEqual(1, Counter["fired"], "the actual native timer must execute exactly once")
				AssertEqual(0, Owner["timer"], "execution consumes the exact timer reservation")
				AssertEqual(0, Owner["timer_cancel"], "execution consumes its native cancel capability")
			}
			AssertTrue(LLM_AuxFinish(Owner), "the exact auxiliary owner must retire after its timer settles")
		}
		AssertEqual(Mode == "executed" ? 1 : 0, Counter["fired"], "cancelled/refused native timers cannot deliver callbacks")
		AssertEqual(0, _LLM_AuxOwners.Count, "no auxiliary owner remains registered")
		AssertEqual(0, _LLM_AuxCleanupDebt.Count, "native timer retirement acknowledges all cleanup")
	} finally {
		Callback := 0
		if Owner is Map && LLM_AuxIsCurrent(Owner)
			_LLM_AuxRetireOwner(Owner, true)
		Owner := 0
		_LLM_AuxOwners := SavedOwners, _LLM_AuxCleanupDebt := SavedDebt
		Critical(PreviousCritical)
	}
}

_LlmAuxTimer_Lifetime(Mode) {
	Counter := Map("deleted", 0, "fired", 0)
	_LLM_TestReleaseIndependentWitness(Counter)
	AssertEqual(1, Counter["deleted"], "an independent passive witness proves synchronous object destruction")
	Counter["deleted"] := 0
	_LlmAuxTimer_RunLifetime(Mode, Counter)
	AssertEqual(1, Counter["deleted"], "a retired native timer must release its private callback capture")
}

for _LlmAuxTimerMode in ["executed", "cancelled", "refused"]
	Test("LLM native auxiliary timer: " . _LlmAuxTimerMode . " releases its callback (llm-native-aux-timer-retirement)",
		_LlmAuxTimer_Lifetime.Bind(_LlmAuxTimerMode))
