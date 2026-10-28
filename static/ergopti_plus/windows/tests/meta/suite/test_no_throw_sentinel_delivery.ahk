; tests/meta/suite/test_no_throw_sentinel_delivery.ahk

; ==============================================================================
; MODULE: No-Throw Sentinel Delivery
; DESCRIPTION: Execute complete original regression callbacks while a temporary
; exact-function observer throws an empty-message Error after real effects finish.
; Healthy controls and completed-effect receipts distinguish false greens from
; an unrelated failure or a fixture that never reached the production call.
; ==============================================================================

#Requires AutoHotkey v2.0

_AMSG_Observe(Observation, Self, Arguments*) {
	Observation.Entries += 1
	Self.DeleteProp("Call")
	Self.Call(Arguments*)
	Observation.Completions += 1
	throw Error("")
}

_AMSG_Receive(Callback, Target, Fault) {
	if Target.HasOwnProp("Call")
		throw Error("The production function already owns a call override.")
	Observation := {Entries: 0, Completions: 0}
	Observer := _AMSG_Observe.Bind(Observation)
	try {
		if Fault
			Target.DefineProp("Call", {Call: Observer})
		Threw := false
		try Callback.Call()
		catch Any
			Threw := true
		if Fault {
			AssertEqual(1, Observation.Entries, "the exact production call must be observed once")
			AssertEqual(1, Observation.Completions, "the original producer must finish its real effects before injection")
		}
		AssertEqual(Fault, Threw, "the complete original callback must reject a thrown empty-message Error")
	} finally {
		if Fault && Target.HasOwnProp("Call") {
			if Target.GetOwnPropDesc("Call").Call != Observer
				throw Error("The test cannot retire a foreign call observer.")
			Target.DeleteProp("Call")
		}
	}
}

_AMSG_Vectors := [
	["text sender containment", _TSSIF_AdapterMethodsContainSendInputFailure, TextEraseChars],
	["logger fanout", TestLogger_FanOutQueueSurvivesFlushSwap, _LoggerFanOut],
	["remote trim", _RemoteTrimRegistry_DetachesBeforeReentrantCallback, _LLMRemote_TrimAsyncRegistry],
	["Ollama trim", _OllamaTrimRegistry_DetachesBeforeReentrantCallback, _LLM_Ollama_TrimAsyncRegistry]
]
for _AMSG_Vector in _AMSG_Vectors {
	Test("no-throw sentinel: " . _AMSG_Vector[1] . " healthy control (empty-message-owner)",
		_AMSG_Receive.Bind(_AMSG_Vector[2], _AMSG_Vector[3], false))
	Test("no-throw sentinel: " . _AMSG_Vector[1] . " rejects empty errors (empty-message-owner)",
		_AMSG_Receive.Bind(_AMSG_Vector[2], _AMSG_Vector[3], true))
}
