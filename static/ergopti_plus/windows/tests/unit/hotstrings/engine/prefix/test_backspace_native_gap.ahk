; tests/unit/hotstrings/engine/prefix/test_backspace_native_gap.ahk

; Explicit native/focus ports qualify the public Backspace producer's privacy
; receipt. Native owned-Edit composition is selected separately; no WinAPI
; classification or hardware origin is claimed by these protocol controls.
_SFBG_Detect(State, Self, Hwnd, &Conclusive) {
	Conclusive := true
	return State.Private
}
_SFBG_Sequence(Active, Private, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
	global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_AgentContentGeneration
	global _LLM_Bridge_ContentGeneration, _LLM_Bridge_PrefixObserver, SFD_FIELD_CACHE
	_LLM_Bridge_Active := Active
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	State.Private := false
	State.Focus["NativeConclusive"] := true
	State.Focus["NativeSecure"] := false
	SFD_CommitFieldVerdict(State.Focus["control"], false,
		SFD_FIELD_CACHE["focus_generation"], "hwnd:" . State.Focus["control"])
	_Body() {
		global _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
		global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource
		global _LLM_Bridge_ContentGeneration, _LLM_Bridge_AgentContentGeneration, _LLM_Bridge_PrefixObserver
		AssertTrue(LLM_Bridge_FeedCharForPrefix("abc", Schedule, Focus, (*) => true))
		AssertEqual("abc", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
		OriginalSource := Active ? _LLM_Bridge_BufferSource : _LLM_Bridge_AgentBufferSource
		OriginalGeneration := Active ? _LLM_Bridge_ContentGeneration : _LLM_Bridge_AgentContentGeneration
		if Active {
			_LLM_Engine["last_buffer"] := "abc"
			_LLM_Engine["active_request_signature"] := "owned-backspace-context"
		}
		NormalOwner := _LLM_Bridge_PrefixObserver
		State.Private := Private
		State.Focus["NativeSecure"] := Private
		LLM_Bridge_FeedKeyDownIfActive(0x08)
		Observed := Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer
		Owner := _LLM_Bridge_PrefixObserver
		Captured := IsObject(Owner) && Owner != NormalOwner ? Owner.CapturedSecure : -1
		_TestPrint("# PREFIX_BACKSPACE_PRIVACY active=" . Active . " private=" . Private
			. " buffer_units=" . StrLen(Observed) . " captured_private=" . Captured)
		AssertEqual(Private ? "" : "ab", Observed,
			"the real Backspace producer must retire private context or edit its current normal context")
		if Private {
			AssertFalse(_LLM_Bridge_TypingStateCurrent(OriginalSource, Active, OriginalGeneration),
				"the pre-private owner must be retired before a new normal invocation")
			if Active {
				AssertEqual("", _LLM_Engine["last_buffer"])
				AssertEqual("", _LLM_Engine["active_request_signature"])
			}
			if IsObject(Owner) && Owner != NormalOwner
				AssertTrue(Owner.CapturedSecure, "a scheduled private frame must not borrow a later normal verdict")
		} else if IsObject(Owner) && Owner != NormalOwner {
			AssertFalse(Owner.CapturedSecure)
		}
		; Own and cancel any real default Backspace timer before its callback can
		; leave this fixture. A synchronous rejection may legitimately schedule none.
		LLM_Bridge_CancelPrefixObserver()
		State.Private := false
		State.Focus["NativeSecure"] := false
		if Private {
			AssertTrue(LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus, (*) => true))
			AssertEqual("b", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer,
				"normal input after a private Backspace cannot reconnect pre-gap text")
		}
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
	}
	_AAG_WithFn(SFD_DetectNative, _SFBG_Detect.Bind(State), _Body)
}
_SFBG_Case(Active, Private) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_SFBG_Sequence.Bind(Active, Private, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _SFBG_Active in [true, false]
	for _SFBG_Private in [true, false]
		Test("Prefix Backspace privacy: active=" . _SFBG_Active . " private=" . _SFBG_Private . " preserves the current input frame (prefix-backspace-native-gap)",
			_SFBG_Case.Bind(_SFBG_Active, _SFBG_Private))
