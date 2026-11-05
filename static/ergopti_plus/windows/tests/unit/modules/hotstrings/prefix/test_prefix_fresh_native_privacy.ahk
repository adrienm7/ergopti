; tests/unit/modules/hotstrings/prefix/test_prefix_fresh_native_privacy.ahk

; Explicit native/focus ports qualify RAM receipt composition and revocation.
; The separate owned native Edit/InputHook/HTTP cases prove actual style capture.
_SFPN_Probe(Probe, Self, Hwnd, &Conclusive) {
	Probe.Calls += 1
	Conclusive := Probe.Revoke
	if Probe.Revoke
		SFD_InvalidateFocus()
	return false
}
_SFPN_Value(Value, Self, Args*) => Value
_SFPN_Feed(Char, State, Schedule, Focus, Probe) {
	Before := Probe.Calls
	Result := LLM_Bridge_FeedCharForPrefix(Char, Schedule, Focus, (*) => true)
	AssertEqual(Before, Probe.Calls, "the RAM policy must consume the supplied receipt without a native re-probe")
	return Result
}
_SFPN_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
	global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_BufferAgentSafe
	global _LLM_Bridge_PrefixObserver, _LLM_Agent_Auto, SFD_FIELD_CACHE
	Active := Mode != "gap-agent"
	_LLM_Bridge_Active := Active
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	State.Focus["NativeConclusive"] := true
	State.Focus["NativeSecure"] := false
	Probe := {Calls: 0, Revoke: false}
	Body() {
		global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
		global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_BufferAgentSafe
		global _LLM_Bridge_PrefixObserver, _LLM_Agent_Auto, SFD_FIELD_CACHE
		if Mode == "inconclusive-native" || Mode == "inconclusive-uia" || Mode == "malformed" {
			State.Focus["NativeConclusive"] := false
			State.Focus["NativeSecure"] := true
			if Mode == "inconclusive-native"
				SFD_CommitFieldVerdict(State.Focus["control"], false,
					SFD_FIELD_CACHE["focus_generation"], "hwnd:" . State.Focus["control"])
			if Mode == "malformed" {
				State.Focus["NativeConclusive"] := true
				State.Focus["NativeSecure"] := "0"
			}
			AssertTrue(_SFPN_Feed("u", State, Schedule, Focus, Probe))
			AssertEqual(Mode == "inconclusive-uia" ? "u" : "", _LLM_Bridge_Buffer,
				"only the exact UIA negative may survive a fresh inconclusive native read")
			AssertEqual(Mode != "inconclusive-uia", _LLM_Bridge_PrefixObserver.CapturedSecure)
			return
		}
		AssertTrue(_SFPN_Feed("a", State, Schedule, Focus, Probe))
		AssertEqual("a", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
		OldSource := Active ? _LLM_Bridge_BufferSource : _LLM_Bridge_AgentBufferSource
		OldPrivateFlag := OldSource.Get("NativeSecure", "absent")
		if Mode == "gateway-nonce" {
			Probe.Revoke := true
			Invoke() => LLM_Bridge_FeedCharForPrefix("s", Schedule, _LLM_Bridge_ReadFocusReceipt)
			WithControl() => _AAG_WithFn(WIGetFocusedControlToken,
				_SFPN_Value.Bind(State.Focus["control"]), Invoke)
			_AAG_WithFn(WIGetForegroundHwnd, _SFPN_Value.Bind(State.Focus["hwnd"]), WithControl)
			AssertEqual(1, Probe.Calls, "the real gateway must obtain the adapter's native observation")
			AssertEqual("a", _LLM_Bridge_Buffer, "a focus nonce revoked by the native port cannot be acquired afterwards")
			return
		}
		if Mode == "optout-agent-strict"
			_LLM_Engine["disable_password_fields"] := false
		State.Focus["NativeSecure"] := true
		AssertTrue(_SFPN_Feed("s", State, Schedule, Focus, Probe))
		AssertEqual(OldPrivateFlag, OldSource.Get("NativeSecure", "absent"),
			"the old shared identity Map must not be rewritten with fresh style hints")
		PrivateOwner := _LLM_Bridge_PrefixObserver
		PrivateCallback := PrivateOwner.Timer
		AssertTrue(PrivateOwner.CapturedSecure, "privacy belongs to this input frame, not its later current style")
		if Mode == "optout-agent-strict" {
			AssertEqual("as", _LLM_Bridge_Buffer, "the explicit prediction opt-out keeps its allowed raw context")
			AssertFalse(_LLM_Bridge_BufferAgentSafe)
			State.Focus["NativeSecure"] := false
			PrivateCallback.Call()
			AssertFalse(IsObject(_LLM_Agent_Auto["timer"]), "automatic-agent privacy is independent of the prediction opt-out")
			return
		}
		AssertEqual("", _LLM_Bridge_Buffer)
		AssertEqual("", _LLM_Bridge_AgentBuffer, "strong private input immediately retires all of its old context")
		AssertFalse(_LLM_Engine["timer_active"])
		if Active {
			AssertEqual("", _LLM_Engine["last_buffer"], "the retired context cannot remain in an armed prediction")
			AssertEqual("", _LLM_Engine["active_request_signature"])
		}
		State.Focus["NativeSecure"] := false
		if Mode == "captured-private" {
			PrivateCallback.Call()
			AssertEqual("", _LLM_Bridge_Buffer, "a later normal gateway cannot admit the original private frame")
			AssertFalse(IsObject(_LLM_Agent_Auto["timer"]))
			return
		}
		AssertTrue(_SFPN_Feed("b", State, Schedule, Focus, Probe))
		AssertEqual("b", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer,
			"new normal input cannot join text across a strongly attested private gap")
		Successor := _LLM_Bridge_PrefixObserver
		SuccessorCallback := Successor.Timer
		PrivateCallback.Call()
		AssertTrue(_LLM_Bridge_PrefixObserver == Successor)
		AssertTrue(Successor.Timer == SuccessorCallback, "old private unwind cannot detach the current normal callback")
		SuccessorCallback.Call()
		AssertEqual("b", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
	}
	_AAG_WithFn(SFD_DetectNative, _SFPN_Probe.Bind(Probe), Body)
	AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
}
_SFPN_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_SFPN_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _SFPN_Mode in ["gap-active", "gap-agent", "captured-private", "optout-agent-strict",
	"inconclusive-native", "inconclusive-uia", "malformed", "gateway-nonce"]
	Test("Prefix fresh native privacy: " . _SFPN_Mode . " preserves its input frame (prefix-fresh-native-privacy)", _SFPN_Case.Bind(_SFPN_Mode))
