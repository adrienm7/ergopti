; tests/unit/hotstrings/engine/prefix/test_llm_typing_privacy.ahk

; Pure adapter-cache and focus ports exercise the actual buffer owners and
; callbacks. Native owned-Edit probes separately qualify SFD and HTTP delivery.
_LTPP_Verdict(State, Secure, Element := "fixture:bridge-field", Advance := false) {
	global SFD_FIELD_CACHE
	if Advance
		SFD_InvalidateFocus()
	SFD_CommitFieldVerdict(State.Focus["control"], Secure,
		SFD_FIELD_CACHE["focus_generation"], Element)
}
_LTPP_Sequence(Mode, Fx, Lines, Sent, State, Schedule, Focus) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration, _LLM_Bridge_BufferSource
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentContentGeneration, _LLM_Bridge_Active
	global _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrefixObserver, _LLM_Engine
	global _LLM_Agent_Auto, _LLM_Agent_Generation, _LLM_Agent_System1Revision
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS, _LLM_Bridge_ReadLiveFocus
	_LTPP_Verdict(State, false)
	_LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
	_LLM_Engine["disable_password_fields"] := true
	if Mode == "secure-prefix" || Mode == "expired-prefix" || Mode == "agent-secure" {
		_LLM_Bridge_Active := Mode != "agent-secure"
		VerdictTtl := SFD_FIELD_CACHE_TTL_MS
		if Mode == "expired-prefix"
			SFD_FIELD_CACHE_TTL_MS := 0
		else
			_LTPP_Verdict(State, true)
		AssertTrue(LLM_Bridge_FeedCharForPrefix("source_private_canary_07", Schedule, Focus, (*) => true))
		SFD_FIELD_CACHE_TTL_MS := VerdictTtl
		Owner := _LLM_Bridge_PrefixObserver
		OwnerCallback := Owner.Timer
		AssertTrue(Owner.CapturedSecure, "the original unknown/secure receipt must be captured before deferred work")
		AssertEqual("", _LLM_Bridge_Buffer)
		AssertEqual("", _LLM_Bridge_AgentBuffer, "private input must never enter either canonical LLM buffer")
		; Same HWND, generation and element: the later normal verdict is genuine
		; cache state, but cannot retroactively authorize the captured secret.
		_LTPP_Verdict(State, false)
		if Mode == "expired-prefix" {
			; The old classifier has not delivered its callback. A new normal input
			; replaces it without inheriting a private byte or an unsafe marker.
			LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus)
			AssertEqual("b", _LLM_Bridge_Buffer)
			AssertTrue(_LLM_Bridge_BufferAgentSafe, "discarded input must not taint future normal context")
			Newer := _LLM_Bridge_PrefixObserver
			NewerCallback := Newer.Timer
			NewerCallback.Call()
			AssertEqual(0, Newer.Timer, "completion must detach the exact finished callback")
			AssertTrue(IsObject(_LLM_Agent_Auto["timer"]), "the actual agent pause must resume on admitted normal input")
			OwnerCallback.Call()
			AssertEqual("b", _LLM_Bridge_Buffer)
			AssertTrue(IsObject(_LLM_Agent_Auto["timer"]), "the retired private classifier must not cancel the fresh normal pause")
			AssertEqual(0, Fx.Remote.Length), AssertEqual(0, Fx.Ollama.Length)
			for Line in Lines
				AssertFalse(InStr(Line, "source_private_canary_07"))
			return
		}
		OwnerCallback.Call()
		AssertEqual("", _LLM_Bridge_Buffer)
		AssertEqual("", _LLM_Bridge_AgentBuffer)
		AssertFalse(_LLM_Engine["timer_active"])
		AssertFalse(IsObject(_LLM_Agent_Auto["timer"]))
		AssertEqual(0, Fx.Remote.Length)
		AssertEqual(0, Fx.Ollama.Length)
		for Line in Lines
			AssertFalse(InStr(Line, "source_private_canary_07"), "private input must never reach the per-character diagnostics")
		if Mode != "agent-secure" {
			LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus)
			AssertEqual("b", _LLM_Bridge_Buffer, "the new normal verdict opens only future characters")
		}
	} else if Mode == "field-generation" || Mode == "field-element" {
		LLM_Bridge_FeedCharForPrefix("a", Schedule, Focus)
		Old := _LLM_Bridge_PrefixObserver
		OldCallback := Old.Timer
		AssertEqual("a", _LLM_Bridge_Buffer)
		_LTPP_Verdict(State, false, "fixture:second-field", Mode == "field-generation")
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Old), "same-HWND fields must not share an input owner")
		LLM_Bridge_FeedCharForPrefix("b", Schedule, Focus)
		AssertEqual("b", _LLM_Bridge_Buffer, "a new field cannot inherit A's context")
		Newer := _LLM_Bridge_PrefixObserver
		NewerCallback := Newer.Timer
		AssertEqual(0, Old.Timer, "cancellation must detach the retired owner callback")
		OldCallback.Call()
		AssertTrue(_LLM_Bridge_PrefixObserver == Newer, "a retired callback cannot withdraw its successor")
		AssertTrue(Newer.Timer == NewerCallback, "a retired finally cannot detach the successor callback")
		AssertEqual("b", _LLM_Bridge_Buffer)
		AssertFalse(_LLM_Engine["timer_active"])
	} else if Mode == "agent-strict" {
		_LLM_Engine["disable_password_fields"] := false
		_LTPP_Verdict(State, true)
		LLM_Bridge_OnChar("s")
		AssertEqual("s", _LLM_Bridge_Buffer, "the explicit prediction preference still permits its own context")
		AssertFalse(_LLM_Bridge_BufferAgentSafe)
		AssertFalse(IsObject(_LLM_Agent_Auto["timer"]), "automatic agent security remains active independently")
		AssertEqual(0, Fx.Remote.Length)
		AssertEqual(0, Fx.Ollama.Length)
	} else if Mode == "backspace-target" {
		LLM_Bridge_FeedCharForPrefix("a", Schedule, Focus)
		State.Focus["control"] += 1
		_LTPP_Verdict(State, false, "fixture:second-field", true)
		LLM_Bridge_FeedKeyDownIfActive(0x08)
		AssertEqual("", _LLM_Bridge_Buffer, "Backspace in B cannot edit or publish A's private local buffer")
		Owner := _LLM_Bridge_PrefixObserver
		OwnerCallback := Owner.Timer
		AssertEqual(State.Focus["control"], Owner.Source["control"])
		OwnerCallback.Call()
		AssertEqual("", _LLM_Bridge_Buffer)
		AssertEqual(0, Fx.Remote.Length)
		AssertEqual(0, Fx.Ollama.Length)
	} else if Mode == "stale-refusal" {
		Source := _LLM_Bridge_BindTypingSource(Focus.Call(), true)
		_LLM_Bridge_ApplyBufferEdit(0, "a")
		Generation := _LLM_Bridge_ContentGeneration
		State.Focus["control"] += 1
		_LTPP_Verdict(State, false, "fixture:second-field", true)
		_LLM_Bridge_BindTypingSource(Focus.Call(), true)
		_LLM_Bridge_ApplyBufferEdit(0, "b")
		_LLM_Bridge_RejectPrivateTyping(true, Source, Generation)
		AssertEqual("b", _LLM_Bridge_Buffer, "a retired A refusal must not clear the successor B context")
	} else if Mode == "guard-reentry" {
		Source := _LLM_Bridge_BindTypingSource(Focus.Call(), true)
		_LLM_Bridge_ApplyBufferEdit(0, "a")
		Generation := _LLM_Bridge_ContentGeneration
		Reenter() {
			_LLM_Bridge_ApplyBufferEdit(0, "b")
			return State.Focus.Clone()
		}
		_LLM_Bridge_ReadLiveFocus := Reenter
		AssertFalse(_LLM_Bridge_TypingSourceCurrent(Source, true, Generation),
			"native focus ports must not pair their old receipt with a newer buffer generation")
		AssertEqual("ab", _LLM_Bridge_Buffer)
		Surface := {Current: true}
		RetireSurface() {
			Surface.Current := false
			return State.Focus.Clone()
		}
		_LLM_Bridge_ReadLiveFocus := RetireSurface
		AssertFalse(_LLM_Bridge_TypingSourceCurrent(Source, true, _LLM_Bridge_ContentGeneration, () => Surface.Current),
			"a native focus callout may retire the external surface guard without changing the source or text")
		AssertEqual("ab", _LLM_Bridge_Buffer, "the external-guard case changes neither target nor buffer content")
		_LLM_Bridge_ReadLiveFocus := Focus
		LLM_Bridge_FeedCharForPrefix("c", Schedule, Focus)
		Older := _LLM_Bridge_PrefixObserver
		Supersede() {
			_LLM_Bridge_SchedulePrefixObserver("c", Schedule, Focus, _LLM_Bridge_BufferSource)
			return State.Focus.Clone()
		}
		Older.FocusFn := Supersede
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Older),
			"a focus-port callout that replaces an observer cannot authenticate its retired caller")
		OldGeneration := _LLM_Agent_Generation
		AdvanceAgent() {
			global _LLM_Agent_Generation
			_LLM_Agent_Generation += 1
			return true
		}
		StaleFlow := Map("generation", OldGeneration, "system1_revision", _LLM_Agent_System1Revision,
			"typing_guard", AdvanceAgent)
		AssertFalse(_LLM_Agent_IsCurrent(StaleFlow), "flow admission must recheck agent generation after its guard")
		OldRevision := _LLM_Agent_System1Revision
		AdvanceRevision() {
			global _LLM_Agent_System1Revision
			_LLM_Agent_System1Revision += 1
			return true
		}
		AssertFalse(_LLM_Agent_TypingTriageCurrent(_LLM_Agent_Generation, OldRevision, AdvanceRevision),
			"triage admission must recheck System 1 revision after its guard")
	} else if Mode == "agent-persistent" {
		LLM_Bridge_FeedCharForPrefix("a", Schedule, Focus)
		Source := _LLM_Bridge_BufferSource
		Generation := _LLM_Bridge_ContentGeneration
		Receipt := _LLM_Bridge_ReadTypingPrivacy(Source, true)
		Current := _LLM_Bridge_AdmittedTypingCurrent.Bind(
			_LLM_Bridge_TypingStateCurrent.Bind(Source, true, Generation), Receipt, true)
		Flow := Map("generation", _LLM_Agent_Generation, "system1_revision", _LLM_Agent_System1Revision,
			"typing_guard", Current)
		LLM_Bridge_CancelPrefixObserver()
		AssertTrue(_LLM_Agent_IsCurrent(Flow), "retiring the one-shot observer must not retire a valid automatic typing flow")
		_LTPP_Verdict(State, false, "fixture:second-field", true)
		AssertFalse(_LLM_Agent_IsCurrent(Flow), "System 1 and System 2 must retain the original field admission")
		; Exercise both actual agent stages. Only the explicit upstream probes
		; may call the native focus port; each transport Current remains pure RAM.
		Source := _LLM_Bridge_BindTypingSource(Focus.Call(), true)
		_LLM_Bridge_ApplyBufferEdit(, LAG_TYPED)
		Generation := _LLM_Bridge_ContentGeneration
		Receipt := _LLM_Bridge_ReadTypingPrivacy(Source, true)
		Current := _LLM_Bridge_AdmittedTypingCurrent.Bind(
			_LLM_Bridge_TypingStateCurrent.Bind(Source, true, Generation), Receipt, true)
		NativeProbe := _LLM_Bridge_TypingSourceCurrent.Bind(Source, true, Generation)
		ProbeCalls := 0
		CountFocus() {
			ProbeCalls += 1
			return State.Focus.Clone()
		}
		_LLM_Bridge_ReadLiveFocus := CountFocus
		_LLM_Engine["temperature"] := 0.25
		Fx.App := "Slack"
		AssertTrue(LLM_Agent_OnTyping(LAG_TYPED, Current, NativeProbe))
		AssertEqual(0, ProbeCalls, "arming claims use only the RAM guard")
		Pause := _LLM_Agent_Auto["timer"]
		AssertTrue(Pause.Call())
		AssertEqual(1, ProbeCalls, "System 1 performs its explicit native probe before transport")
		AssertEqual(1, Fx.Remote.Length)
		AssertTrue(Fx.Remote[1]["requester_current"].Call())
		AssertEqual(1, ProbeCalls, "System 1 transport admission never probes focus")
		Fx.Remote[1]["on_success"].Call("INTENT: calendar`nPROBABILITY: 0.99")
		AssertEqual(2, Fx.Remote.Length)
		AssertEqual(2, ProbeCalls, "System 2 performs one explicit native probe before transport")
		AssertTrue(Fx.Remote[2]["requester_current"].Call())
		AssertEqual(2, ProbeCalls, "System 2 transport admission never probes focus")
	}
}
_LTPP_Case(Mode) {
	PreviousCritical := Critical("On")
	try {
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_LTPP_Sequence.Bind(Mode, Fx, Lines, Sent))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), Body)
	} finally Critical(PreviousCritical)
}
for _LTPP_Mode in ["secure-prefix", "expired-prefix", "agent-secure", "field-generation", "field-element",
	"agent-strict", "backspace-target", "stale-refusal", "guard-reentry", "agent-persistent"]
	Test("LLM typing provenance: " . _LTPP_Mode . " retains the original privacy owner (llm-typing-source-privacy)",
		_LTPP_Case.Bind(_LTPP_Mode))
