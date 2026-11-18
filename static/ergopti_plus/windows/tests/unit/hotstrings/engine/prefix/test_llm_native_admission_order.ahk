; tests/unit/hotstrings/engine/prefix/test_llm_native_admission_order.ahk

_LNAO_ProduceLater(State) {
	State.LaterCalls += 1
	State.Started := true
	try LLM_Bridge_FeedCharIfActive("b")
	catch Any as Failure
		State.Failure := Failure
	finally State.Done := true
}
; Delay the real detector through its existing callable object. The genuine
; implementation is restored before both reads, so no verdict is fabricated.
_LNAO_DelayedDetector(State, Callback, Self, Args*) {
	; A serialized admission can deliver the one-shot after the first read but
	; before _AAG_WithFn unwinds. Later reads still use the real detector and
	; must not rearm the callback which is currently delivering that character.
	if State.Intercepted {
		Self.DeleteProp("Call")
		try return Self.Call(Args*)
		finally Self.DefineProp("Call", {Call: _LNAO_DelayedDetector.Bind(State, Callback)})
	}
	State.Intercepted := true
	State.CriticalAtRead := !!A_IsCritical
	Self.DeleteProp("Call")
	try {
		AssertTrue(TimerSetCallback(Callback, -1))
		Started := A_TickCount
		while !State.Done && TickElapsed64(Started) < 80 {
			Sleep(-1)
			if !State.Done
				Sleep(1)
		}
		State.LaterBeforeRead := State.Done
		State.Secure := Self.Call(Args*)
		return State.Secure
	} finally Self.DefineProp("Call", {Call: _LNAO_DelayedDetector.Bind(State, Callback)})
}
_LNAO_Sequence(Active, Fx, Lines, Sent, Scope, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer
	global _LLM_Bridge_AgentFeeding, _LLM_Bridge_ContentGeneration
	_LLM_Bridge_Active := Active
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	_LLM_Bridge_AgentFeeding := !Active
	; The ordinary producer establishes the same source and normal detector
	; receipt. Its exact public edits must also survive the interrupting case.
	LLM_Bridge_FeedCharIfActive("a")
	LLM_Bridge_FeedCharIfActive("b")
	AssertEqual("ab", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
	LLM_Agent_InvalidateTyping()
	if Active
		_LLM_Bridge_ApplyBufferEdit()
	else
		LLM_Bridge_MirrorAgentEdit(0, "", true)
	State := {Started: false, Done: false, Failure: 0, CriticalAtRead: false, Intercepted: false, LaterCalls: 0,
		LaterBeforeRead: false, Secure: true}
	Callback := _LNAO_ProduceLater.Bind(State)
	PreviousCritical := Critical("Off")
	try {
		_AAG_WithFn(SFD_IsSecureField, _LNAO_DelayedDetector.Bind(State, Callback),
			() => LLM_Bridge_FeedCharIfActive("a"))
		Started := A_TickCount
		while !State.Done && TickElapsed64(Started) < 1500
			Sleep(5)
		if IsObject(State.Failure)
			throw State.Failure
		AssertTrue(State.Done, "the actual native timer must deliver the later producer once")
	} finally {
		Critical("On")
		AssertTrue(TimerSetCallback(Callback, 0))
		Critical(PreviousCritical)
	}
	Buffer := Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer
	_TestPrint("# LLM_NATIVE_ADMISSION_ORDER " . KL_JsonEncode(Map("active", Active,
		"later_before_read", State.LaterBeforeRead, "critical_at_read", State.CriticalAtRead,
		"actual_detector_secure", State.Secure, "later_done", State.Done, "later_calls", State.LaterCalls,
		"units", StrLen(Buffer), "ordered_ab", Buffer == "ab", "requests", Fx.Remote.Length)))
	AssertEqual(1, State.LaterCalls, "the probe delivers exactly one later public character")
	AssertFalse(State.Secure, "the actual isolated normal detector must establish the same allowed verdict")
	AssertEqual("ab", Buffer, "native classification must not reorder or discard the earlier character in the same field")
	AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
}
_LNAO_Case(Active) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_LNAO_Sequence.Bind(Active, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _LNAO_Active in [true, false]
	Test("LLM native admission order: active=" . _LNAO_Active . " retains both public producer edits (llm-native-admission-order)",
		_LNAO_Case.Bind(_LNAO_Active))
