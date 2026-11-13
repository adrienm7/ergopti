; tests/unit/hotstrings/engine/prefix/test_cached_privacy_gap.ahk

; These are explicit cache/port protocol probes. They assert context continuity,
; not a private network disclosure or a native UIA classification claim.
_SFPG_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer
	global _LLM_Bridge_PrefixObserver, SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Active := Mode != "uia-positive"
	_LLM_Bridge_Active := Active
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	Ttl := SFD_FIELD_CACHE_TTL_MS
	try {
		AssertTrue(LLM_Bridge_FeedCharForPrefix("a", Schedule, Focus, (*) => true))
		AssertEqual("a", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
		Generation := SFD_FIELD_CACHE["focus_generation"]
		Element := SFD_FIELD_CACHE["current_element_id"]
		if Mode == "uia-positive"
			SFD_CommitFieldVerdict(State.Focus["control"], true, Generation, Element)
		else if Mode == "expired-unknown"
			SFD_FIELD_CACHE_TTL_MS := 0
		else {
			State.Focus["NativeConclusive"] := "1"
			State.Focus["NativeSecure"] := true
		}
		AssertTrue(LLM_Bridge_FeedCharForPrefix("s", Schedule, Focus, (*) => true))
		Denied := _LLM_Bridge_PrefixObserver
		DeniedCallback := Denied.Timer
		AssertTrue(Denied.CapturedSecure, "the middle character must really be refused by the current cache/receipt policy")
		AssertEqual(Generation, SFD_FIELD_CACHE["focus_generation"])
		AssertEqual(Element, SFD_FIELD_CACHE["current_element_id"], "this gap is not a fabricated field transition")
		if Mode == "uia-positive"
			SFD_CommitFieldVerdict(State.Focus["control"], false, Generation, Element)
		SFD_FIELD_CACHE_TTL_MS := Ttl
		if State.Focus.Has("NativeConclusive")
			State.Focus.Delete("NativeConclusive")
		if State.Focus.Has("NativeSecure")
			State.Focus.Delete("NativeSecure")
		; The denied observer has deliberately not run: B is the next public
		; producer, so it supersedes that deferred callback through its real owner.
		AssertTrue(LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus, (*) => true))
		Successor := _LLM_Bridge_PrefixObserver
		SuccessorCallback := Successor.Timer
		Buffer := Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer
		_TestPrint("# PREFIX_CACHED_GAP mode=" . Mode . " active=" . Active
			. " refused_middle=" . Denied.CapturedSecure . " fresh_b_only=" . (Buffer == "b")
			. " units=" . StrLen(Buffer))
		AssertEqual("b", Buffer, "a refused character cannot join pre-gap and post-gap input into a context never observed on screen")
		DeniedCallback.Call()
		AssertTrue(_LLM_Bridge_PrefixObserver == Successor)
		AssertTrue(Successor.Timer == SuccessorCallback)
		AssertEqual("b", Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer)
		AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
	} finally SFD_FIELD_CACHE_TTL_MS := Ttl
}
_SFPG_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_SFPG_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _SFPG_Mode in ["uia-positive", "expired-unknown", "malformed"]
	Test("Prefix cached privacy gap: " . _SFPG_Mode . " retires noncontiguous context (prefix-cached-privacy-gap)", _SFPG_Case.Bind(_SFPG_Mode))
