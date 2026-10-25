; tests/unit/modules/llm/prediction/test_llm_engine_read_guarded_in_timer.ahk

; ==============================================================================
; MODULE: Engine state read from a timer tick
;         (llm-engine-enabled-read-unguarded-in-timer)
; DESCRIPTION:
; _LLM_Ollama_DrainPending is a SetTimer tick. It guarded the engine Map with
; IsSet, which proves the VARIABLE exists, and then read _LLM_Engine["enabled"],
; which requires the KEY to exist. Reading an absent key raises in AHK v2, and a
; throw inside a timer thread is not a failed prediction: it is a fatal error
; that takes the whole driver down.
;
; It shipped green for months because the engine Map is populated during boot
; and the tick normally lands well after that. CI caught it on 2026-09-06 in a
; run whose only change was a Python file — the AHK suite was byte-identical to
; the previous green run — which is what an intermittent race looks like:
;
;   not ok 0 - FATAL STARTUP ERROR: Item has no value.
;   ollama_streaming.ahk (241) : If (IsSet(_LLM_Engine) and !_LLM_Engine["enabled"])
;   > Timer
;
; ROOT CAUSE ENCODED: a timer cannot assume a client's Map has already been
; initialized. Each queued request retains its own admission and origin; the
; transport must not read an unrelated prediction engine's switch. The agent
; remains independent while a retired prediction is still denied by its owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_LERG_WithEngine(Replacement, Callback) {
	global _LLM_Engine
	HadEngine := IsSet(_LLM_Engine)
	Saved := HadEngine ? _LLM_Engine : ""
	_LLM_Engine := Replacement
	try {
		return Callback()
	} finally {
		if HadEngine
			_LLM_Engine := Saved
		else
			_LLM_Engine := unset
	}
}

_LERG_DrainOnce() {
	_LLM_Ollama_DrainPending()
	return true
}





; ===============================================================
; ===============================================================
; ======= 1/ A tick against a half-built Map must not die =======
; ===============================================================
; ===============================================================

_LERG_DrainSurvivesAnEngineWithoutTheKey() {
	; Exactly the state the stack trace shows: the Map exists, the key does not.
	Result := _LERG_WithEngine(Map(), _LERG_DrainOnce)
	AssertTrue(Result,
		"a timer tick against an engine Map that has no 'enabled' key must "
		. "return, not raise: the throw lands in the timer thread and is fatal "
		. "(llm-engine-enabled-read-unguarded-in-timer)")
}

Test("llm timer: draining with a half-built engine Map does not throw (llm-engine-enabled-read-unguarded-in-timer)",
	_LERG_DrainSurvivesAnEngineWithoutTheKey)

_LERG_DrainSurvivesANonMapEngine() {
	; A stub or a partially torn-down engine can be any value at all.
	for Replacement in ["", 0, "not a map"] {
		Result := _LERG_WithEngine(Replacement, _LERG_DrainOnce)
		AssertTrue(Result,
			"a timer tick must survive an engine that is not a Map at all; "
			. "failed for " . Type(Replacement))
	}
}

Test("llm timer: draining with a non-Map engine does not throw (llm-engine-enabled-read-unguarded-in-timer)",
	_LERG_DrainSurvivesANonMapEngine)

_LERG_QueueUsesItsOriginalRequester() {
	Body := _DriverFuncBody("_LLM_Ollama_DrainPending")
	Assert(Body != "", "the actual transport queue must exist before any absence assertion")
	Stripped := _StripFullLineComments(Body)
	Assert(InStr(Stripped, "_LLM_Engine") == 0,
		"an independent request cannot inherit a prediction engine's disabled or incomplete state")
}

Test("llm timer: pending jobs retain their original requester (llm-engine-enabled-read-unguarded-in-timer)",
	_LERG_QueueUsesItsOriginalRequester)





; ===============================================================
; ===============================================================
; ======= 2/ No sibling tick may subscript the engine Map =======
; ===============================================================
; ===============================================================

; The whole class in this subsystem: the recurring defect here is the one
; sibling site that kept the raising spelling, and every function in the
; api_ollama tree is reachable from a poll tick.
_LERG_NoOllamaFunctionSubscriptsTheEngine() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm/api_ollama"))
	Assert(Src != "",
		"the api_ollama sources must be readable -- an empty scan would make "
		. "this guard pass vacuously")
	Assert(InStr(Src, "_LLM_Ollama_DrainPending() {") > 0,
		"the scan must include the actual queue owner before any absence assertion")
	Assert(InStr(Src, '_LLM_Engine["') = 0,
		'a bare _LLM_Engine["key"] subscript raises when the key is absent, and '
		. "every function here can be reached from a poll tick where a throw is "
		. "fatal. Use .Get(key, default) or guard with .Has(key) "
		. "(llm-engine-enabled-read-unguarded-in-timer)")
}

Test("llm timer: no api_ollama function subscripts the engine Map (llm-engine-enabled-read-unguarded-in-timer)",
	_LERG_NoOllamaFunctionSubscriptsTheEngine)
