; tests/unit/hotstrings/engine/prefix/test_backspace_cached_privacy_gap.ahk

; Explicit cache/native-detector protocol ports, not a native UIA or network
; disclosure claim. The real keydown producer must preserve context continuity.
_SBCG_NativeInconclusive(Self, Hwnd, &Conclusive) {
	Conclusive := false
	return false
}
_SBCG_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
	global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_ContentGeneration
	global _LLM_Bridge_AgentContentGeneration, _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrefixObserver
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Active := !InStr(Mode, "agent-")
	Unknown := InStr(Mode, "unknown") > 0
	OptOut := InStr(Mode, "optout-") > 0 || !Active
	ExpectedPrivate := !OptOut || !Active
	_LLM_Bridge_Active := Active
	_LLM_Engine["disable_password_fields"] := !OptOut
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	Ttl := SFD_FIELD_CACHE_TTL_MS
	Body() {
		global _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
		global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_ContentGeneration
		global _LLM_Bridge_AgentContentGeneration, _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrefixObserver
		global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
		AssertTrue(LLM_Bridge_FeedCharForPrefix("abc", Schedule, Focus, (*) => true))
		AssertEqual("abc", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
		OriginalSource := Active ? _LLM_Bridge_BufferSource : _LLM_Bridge_AgentBufferSource
		OriginalGeneration := Active ? _LLM_Bridge_ContentGeneration : _LLM_Bridge_AgentContentGeneration
		FieldGeneration := SFD_FIELD_CACHE["focus_generation"]
		Element := SFD_FIELD_CACHE["current_element_id"]
		if Active {
			_LLM_Engine["last_buffer"] := "abc"
			_LLM_Engine["active_request_signature"] := "owned-cached-backspace"
		}
		if Unknown
			SFD_FIELD_CACHE_TTL_MS := 0
		else
			SFD_CommitFieldVerdict(State.Focus["control"], true, FieldGeneration, Element)
		AssertTrue(_LLM_Bridge_CachedTypingSecure(OriginalSource, Focus()),
			"The exact middle arrival must be refused by the real cache policy before the public Backspace.")
		NormalOwner := _LLM_Bridge_PrefixObserver
		LLM_Bridge_FeedKeyDownIfActive(0x08)
		Observed := Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer
		Denied := _LLM_Bridge_PrefixObserver
		Captured := IsObject(Denied) && Denied != NormalOwner ? Denied.CapturedSecure : -1
		_TestPrint("# BACKSPACE_CACHED_GAP mode=" . Mode . " active=" . Active
			. " unknown=" . Unknown . " optout=" . OptOut . " units=" . StrLen(Observed)
			. " captured=" . Captured)
		AssertEqual(FieldGeneration, SFD_FIELD_CACHE["focus_generation"])
		AssertEqual(Element, SFD_FIELD_CACHE["current_element_id"], "No field transition may explain context retirement.")
		AssertEqual(ExpectedPrivate ? "" : "ab", Observed,
			"The public Backspace must retire refused context immediately; only prediction opt-out may keep its edit.")
		if ExpectedPrivate {
			AssertFalse(_LLM_Bridge_TypingStateCurrent(OriginalSource, Active, OriginalGeneration))
			if Active {
				AssertEqual("", _LLM_Engine["last_buffer"])
				AssertEqual("", _LLM_Engine["active_request_signature"])
			}
		} else {
			AssertFalse(_LLM_Bridge_BufferAgentSafe, "Prediction opt-out never grants automatic-agent authority.")
		}
		if IsObject(Denied) && Denied != NormalOwner
			AssertTrue(Denied.CapturedSecure, "Any private Backspace observer must freeze its original refusal.")
		; Retire only this fixture's actual default timer before restoring cache
		; policy; the owner scope also does this if an earlier assertion fails.
		LLM_Bridge_CancelPrefixObserver()
		SFD_FIELD_CACHE_TTL_MS := Ttl
		SFD_CommitFieldVerdict(State.Focus["control"], false, FieldGeneration, Element)
		AssertTrue(LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus, (*) => true))
		AssertEqual(ExpectedPrivate ? "b" : "abb", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer,
			"Fresh normal input must not reconnect the pre-refusal context.")
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
	}
	try {
		_AAG_WithFn(SFD_DetectNative, _SBCG_NativeInconclusive, Body)
	} finally SFD_FIELD_CACHE_TTL_MS := Ttl
}
_SBCG_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_SBCG_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _SBCG_Mode in ["protected-uia", "protected-unknown", "optout-uia", "optout-unknown", "agent-uia"]
	Test("Backspace cached privacy gap: " . _SBCG_Mode . " preserves exact policy (backspace-cached-privacy-gap)", _SBCG_Case.Bind(_SBCG_Mode))
