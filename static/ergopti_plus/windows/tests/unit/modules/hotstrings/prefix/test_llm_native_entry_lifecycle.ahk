; tests/unit/modules/hotstrings/prefix/test_llm_native_entry_lifecycle.ahk

; Actual producer and buffer/lifecycle owners with isolated focus/cache and
; scheduler ports. Native Suspend is real; a process-wide bridge Stop is not
; fabricated. Buffer retirement below is its exact RAM owner protocol.
_LNEL_Clear(Active) {
	if Active
		_LLM_Bridge_ApplyBufferEdit()
	else
		LLM_Bridge_MirrorAgentEdit(0, "", true)
	LLM_Agent_InvalidateTyping()
}
_LNEL_Cut(Active, Mode, Cut) {
	global _PrefixDeferredGeneration, _LLM_Bridge_ContentGeneration
	global _LLM_Bridge_AgentContentGeneration, _LLM_Bridge_Active
	Cut.EpochBefore := _PrefixDeferredGeneration
	Cut.GenerationBefore := Active ? _LLM_Bridge_ContentGeneration : _LLM_Bridge_AgentContentGeneration
	if Mode == "pause-resume" {
		Suspend(true)
		try {
			Cut.NativePaused := !!A_IsSuspended
			; This is the production allocator called by the prefix lifecycle's
			; suspend hook. Its timer slots are privately isolated by the caller.
			_PrefixInvalidateDeferredEffects()
		} finally Suspend(false)
	} else if Active {
		; The same mode ABA and canonical retirement performed by bridge Stop:
		; do not touch unrelated global pointer, UI, stream or listener owners.
		_LLM_Bridge_Active := false
		try _LLM_Bridge_ClearBuffer()
		finally _LLM_Bridge_Active := true
	} else {
		LLM_Bridge_ResetAgentFeed("the entry-lifecycle fixture retired its private feed")
	}
	Cut.EpochAfter := _PrefixDeferredGeneration
	Cut.GenerationAfter := Active ? _LLM_Bridge_ContentGeneration : _LLM_Bridge_AgentContentGeneration
}
_LNEL_Intercept(Active, Mode, Cut, Self, Args*) {
	Self.DeleteProp("Call")
	try {
		if !Cut.Invoked {
			Cut.Invoked := true
			_LNEL_Cut(Active, Mode, Cut)
		}
		return Self.Call(Args*)
	} finally Self.DefineProp("Call", {Call: _LNEL_Intercept.Bind(Active, Mode, Cut)})
}
_LNEL_Sequence(Active, Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding
	global _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer
	global _HSE_FireLogScheduled, _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	Saved := {FireScheduled: _HSE_FireLogScheduled, FireGeneration: _HSE_FireLogScheduledGeneration,
		FireTimer: _HSE_FireLogTimer, RenderGeneration: _PrefixRenderScheduledGeneration,
		RenderTimer: _PrefixRenderTimer}
	Cut := {Invoked: false, NativePaused: false, EpochBefore: 0, EpochAfter: 0,
		GenerationBefore: 0, GenerationAfter: 0}
	AssertFalse(A_IsSuspended, "the fixture cannot resume a foreign native pause")
	_LLM_Bridge_Active := Active
	_LLM_Bridge_AgentFeeding := !Active
	_HSE_FireLogScheduled := false, _HSE_FireLogScheduledGeneration := -1, _HSE_FireLogTimer := 0
	_PrefixRenderScheduledGeneration := -1, _PrefixRenderTimer := 0
	try {
		_LNEL_Clear(Active)
		LLM_Bridge_FeedCharIfActive("c")
		AssertEqual("c", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer,
			"the unchanged source must admit an ordinary control before the cut")
		_LNEL_Clear(Active)
		; Both callbacks execute after the producer's entry stamp and before its
		; source Bind. The actual settings implementation still supplies its result.
		Fn := Active ? LLM_Agent_WatchesTyping : LLM_Agent_Setting
		_AAG_WithFn(Fn, _LNEL_Intercept.Bind(Active, Mode, Cut),
			() => LLM_Bridge_FeedCharIfActive("a"))
		AssertTrue(Cut.Invoked, "the actual preparatory port must reach the lifecycle cut")
		AssertFalse(A_IsSuspended)
		AssertEqual(Active, _LLM_Bridge_Active, "the source mode is restored; a Boolean-only check cannot reject this ABA")
		if Mode == "pause-resume" {
			AssertTrue(Cut.NativePaused)
			AssertTrue(Cut.EpochAfter > Cut.EpochBefore, "the actual lifecycle allocator advances the input epoch")
		} else {
			AssertEqual(Cut.EpochBefore, Cut.EpochAfter, "buffer retirement does not borrow a fabricated lifecycle epoch")
			AssertTrue(Cut.GenerationAfter > Cut.GenerationBefore, "the canonical owner acknowledges its retirement")
		}
		AssertEqual("", _LLM_Bridge_Buffer, "the withdrawn callback must not append prediction context")
		AssertEqual("", _LLM_Bridge_AgentBuffer, "the withdrawn callback must not append agent context")
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
		LLM_Bridge_FeedCharIfActive("b")
		AssertEqual("b", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer,
			"a new current invocation must resume without inheriting the retired character")
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
	} finally {
		if A_IsSuspended
			Suspend(false)
		_HSE_FireLogScheduled := Saved.FireScheduled
		_HSE_FireLogScheduledGeneration := Saved.FireGeneration
		_HSE_FireLogTimer := Saved.FireTimer
		_PrefixRenderScheduledGeneration := Saved.RenderGeneration
		_PrefixRenderTimer := Saved.RenderTimer
	}
}
_LNEL_Case(Active, Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_LNEL_Sequence.Bind(Active, Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _LNEL_Active in [true, false]
	for _LNEL_Mode in ["pause-resume", "buffer-retire"]
		Test("LLM native entry lifecycle: active=" . _LNEL_Active . " " . _LNEL_Mode . " refuses the withdrawn preparation (llm-native-entry-lifecycle)",
			_LNEL_Case.Bind(_LNEL_Active, _LNEL_Mode))
