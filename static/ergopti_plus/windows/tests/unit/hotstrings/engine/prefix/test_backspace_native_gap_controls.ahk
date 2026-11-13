; tests/unit/hotstrings/engine/prefix/test_backspace_native_gap_controls.ahk

_SFBGC_RetireAtFocus(State, Self, Args*) {
	Self.DeleteProp("Call")
	try {
		State.Cuts += 1
		_LLM_Bridge_ClearBuffer()
		return Self.Call(Args*)
	} finally Self.DefineProp("Call", {Call: _SFBGC_RetireAtFocus.Bind(State)})
}
_SFBGC_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ReadLiveFocus
	global _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrefixObserver, _LLM_Engine, SFD_FIELD_CACHE
	_LLM_Bridge_Active := true
	State.Private := false, State.Cuts := 0
	State.Focus["NativeConclusive"] := true, State.Focus["NativeSecure"] := false
	SFD_CommitFieldVerdict(State.Focus["control"], false,
		SFD_FIELD_CACHE["focus_generation"], "hwnd:" . State.Focus["control"])
	_Body() {
		global _LLM_Bridge_Buffer, _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrefixObserver
		global _LLM_Bridge_ReadLiveFocus, _LLM_Engine
		AssertTrue(LLM_Bridge_FeedCharForPrefix("abc", Schedule, Focus))
		AssertEqual("abc", _LLM_Bridge_Buffer)
		if Mode == "optout" {
			_LLM_Engine["disable_password_fields"] := false
			State.Private := true, State.Focus["NativeSecure"] := true
			LLM_Bridge_FeedKeyDownIfActive(0x08)
			AssertEqual("ab", _LLM_Bridge_Buffer, "the explicit prediction opt-out still keeps its requested edit")
			AssertFalse(_LLM_Bridge_BufferAgentSafe, "a private edit cannot acquire automatic-agent permission through the prediction opt-out")
			AssertTrue(IsObject(_LLM_Bridge_PrefixObserver) && _LLM_Bridge_PrefixObserver.CapturedSecure,
				"the real scheduled Backspace callback must freeze its private capture")
		} else {
			RequestId := _LLM_Engine["request_id"]
			_AAG_WithFn(_LLM_Bridge_ReadLiveFocus, _SFBGC_RetireAtFocus.Bind(State),
				() => LLM_Bridge_FeedKeyDownIfActive(0x08))
			AssertEqual(1, State.Cuts, "the actual focus port must reach its canonical retirement cutpoint")
			AssertEqual("", _LLM_Bridge_Buffer)
			AssertFalse(IsObject(_LLM_Bridge_PrefixObserver), "an old Backspace frame cannot reacquire an observer after its context was retired")
			AssertEqual(RequestId, _LLM_Engine["request_id"], "the withdrawn frame cannot invalidate a new request generation")
		}
		LLM_Bridge_CancelPrefixObserver()
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
	}
	_AAG_WithFn(SFD_DetectNative, _SFBG_Detect.Bind(State), _Body)
}
_SFBGC_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_SFBGC_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _SFBGC_Mode in ["optout", "retired-focus"]
	Test("Backspace private frame control: " . _SFBGC_Mode . " preserves its owner (prefix-backspace-native-gap-controls)", _SFBGC_Case.Bind(_SFBGC_Mode))
