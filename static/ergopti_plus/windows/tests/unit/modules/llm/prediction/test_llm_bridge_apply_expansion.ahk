; tests/unit/modules/llm/prediction/test_llm_bridge_apply_expansion.ahk

; ==============================================================================
; MODULE: LLM Bridge Apply Expansion Unit Tests
; DESCRIPTION:
; Regression guard for AHK-23: physical characters typed inside the 60 ms
; post-expansion suppression window were dropped from _LLM_Bridge_Buffer because
; LLM_Bridge_FeedCharIfActive is called AFTER the suppressed-branch early-return
; in _OnPrefixChar. After every hotstring fire the LLM rolling context was
; permanently desynced: the trigger chars stayed in the buffer, the replacement
; text was never appended, and any chars typed during the drain window were lost.
; The LLM then predicted completions against a context that no longer matched
; the document.
;
; The engine now publishes one canonical edit and HSE_DispatchMatch mirrors that
; exact value into the LLM buffer. No bridge-local expansion predictor remains.
;
; These tests assert that the engine effect covers consumed delimiters,
; typographic spaces and Send-key syntax, then that production applies it once.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Helpers ================================================
; ===================================================================
; ===================================================================

_TLBAE_MakeSpec(trigger) {
	Spec := {}
	Spec.Trigger := trigger
	Spec.Length := StrLen(trigger)
	return Spec
}

_TLBAE_SetupBuffer(buf) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := buf
	_LLM_Bridge_Active := true
}

_TLBAE_Teardown() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := ""
	_LLM_Bridge_Active := false
}




; ===================================================================
; ===================================================================
; ======= 2/ Test cases =============================================
; ===================================================================
; ===================================================================

_TLBAE_TestEnginePublishesCanonicalEffect() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_TypoNbspStripped
	global HSE_CONSUMED_DELIMITERS
	SavedBuffer := HSE_Buffer
	SavedBoundary := HSE_StartIsWordBoundary
	SavedTypoNbsp := HSE_TypoNbspStripped
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	try {
		HSE_CONSUMED_DELIMITERS := " "
		HSE_TypoNbspStripped := true
		HSE_StartIsWordBoundary := true
		HSE_Buffer := "left" . Chr(0x202F) . "ab "
		Effect := HSE_ApplyExpansion(_TLBAE_MakeSpec("ab"), "Z", " ")

		Assert(IsObject(Effect),
			"hotstring-llm-canonical-effect: the engine must publish the exact committed edit")
		AssertEqual(4, Effect.DeleteFromEnd,
			"the canonical delete count must include trigger, end char, and stripped typographic nbsp")
		AssertEqual("Z", Effect.InsertedText,
			"a consumed delimiter must be absent from the canonical inserted text")
		AssertFalse(Effect.KnownBoundaryAfter,
			"a consumed delimiter must not claim a boundary which is absent from the screen")
		AssertEqual("leftZ", HSE_Buffer,
			"the engine must apply the same canonical edit it publishes")

		HSE_Buffer := 'leftab'
		HSE_StartIsWordBoundary := true
		SendModeSpec := _TLBAE_MakeSpec("ab")
		SendModeSpec.OnlyText := false
		SendModeEffect := HSE_ApplyExpansion(SendModeSpec, '""{Left}')
		AssertEqual(true, SendModeEffect.ClearAll,
			"Send-key syntax must publish an explicit clear effect instead of pretending its payload is literal text")
		AssertEqual("", HSE_Buffer,
			"the engine must clear an unknowable post-command caret context")
		AssertEqual(false, HSE_StartIsWordBoundary,
			"a cleared Send-key context must not invent a word boundary")
	} finally {
		HSE_Buffer := SavedBuffer
		HSE_StartIsWordBoundary := SavedBoundary
		HSE_TypoNbspStripped := SavedTypoNbsp
		HSE_CONSUMED_DELIMITERS := SavedConsumed
	}
}

_TLBAE_TestDispatchMirrorsCanonicalEffect() {
	Body := _DriverFuncBody("HSE_DispatchMatch")
	Assert(Body != "", "HSE_DispatchMatch must exist in the driver source")
	ApplyPos := InStr(Body, "ExpansionEffect := HSE_ApplyExpansion")
	MirrorPos := InStr(Body, "_HSE_MirrorCanonicalEffectToLlm(ExpansionEffect)")
	Assert(ApplyPos > 0 and MirrorPos > ApplyPos,
		"hotstring-llm-canonical-effect: production dispatch must mirror the engine's returned effect")
	Assert(InStr(Body, "CommittedEffect := ExpansionEffect") > MirrorPos,
		"the watcher must receive that same committed effect instead of re-deriving its post-fire state")
	Assert(InStr(Body, "LLM_Bridge_ApplyExpansionIfActive") == 0,
		"production dispatch must not re-derive expansion semantics through the legacy bridge helper")

	RawBody := _StripFullLineComments(_DriverFuncBody("_HSE_DispatchRawCallback"))
	Assert(RawBody != "", "_HSE_DispatchRawCallback must exist in the driver source")
	EffectPos := InStr(RawBody, "CanonicalEffect :=")
	MirrorPos := EffectPos > 0
		? InStr(RawBody, "_HSE_MirrorCanonicalEffectToLlm(CanonicalEffect)", true, EffectPos)
		: 0
	PublishPos := EffectPos > 0
		? InStr(RawBody, "CommittedEffect := CanonicalEffect", true, EffectPos)
		: 0
	Assert(EffectPos > 0,
		"a successful raw callback must construct one named canonical effect")
	EffectBlock := (MirrorPos > EffectPos)
		? SubStr(RawBody, EffectPos, MirrorPos - EffectPos)
		: ""
	for Field in ["ClearAll:", "DeleteFromEnd:", "InsertedText:", "KnownBoundaryAfter:"] {
		Assert(InStr(EffectBlock, Field) > 0,
			"the raw callback canonical effect must publish field " . Field)
	}
	Assert(MirrorPos > EffectPos and PublishPos > EffectPos,
		"raw callbacks must route that SAME canonical effect to both the LLM mirror "
		. "and the caller instead of rebuilding either sink from Bs/Ins")
}

_TLBAE_TestCanonicalMirrorMutatesLlmOnce() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	SavedBuffer := _LLM_Bridge_Buffer
	SavedActive := _LLM_Bridge_Active
	SavedGeneration := _LLM_Bridge_ContentGeneration
	PreviousCritical := Critical("On")
	try {
		_LLM_Bridge_Buffer := "leftab"
		_LLM_Bridge_Active := true
		_LLM_Bridge_ContentGeneration := 40
		_HSE_MirrorCanonicalEffectToLlm({ IsPrivate: false, DeleteFromEnd: 2, InsertedText: "Z" })
		AssertEqual("leftZ", _LLM_Bridge_Buffer,
			"the canonical mirror must apply the declared delete and insert exactly once")
		AssertEqual(41, _LLM_Bridge_ContentGeneration,
			"the canonical mirror must advance the LLM content epoch exactly once")
		_HSE_MirrorCanonicalEffectToLlm({
			IsPrivate: false, ClearAll: true, DeleteFromEnd: 0, InsertedText: ""
		})
		AssertEqual("", _LLM_Bridge_Buffer,
			"an unknowable Send-key effect must clear the LLM context rather than append command syntax")
		AssertEqual(42, _LLM_Bridge_ContentGeneration,
			"the clear effect must advance the LLM content epoch exactly once")
	} finally {
		_LLM_Bridge_Buffer := SavedBuffer
		_LLM_Bridge_Active := SavedActive
		_LLM_Bridge_ContentGeneration := SavedGeneration
		Critical(PreviousCritical)
	}
}


Test("unit G5: HSE publishes one canonical expansion effect including consumed delimiters and typo nbsp (hotstring-llm-canonical-effect)",
	_TLBAE_TestEnginePublishesCanonicalEffect)

Test("meta G5: production hotstring dispatch mirrors the canonical HSE effect into the LLM buffer (hotstring-llm-canonical-effect)",
	_TLBAE_TestDispatchMirrorsCanonicalEffect)

Test("unit G5: the canonical hotstring sink mutates the LLM buffer and epoch exactly once (hotstring-llm-canonical-effect)",
	_TLBAE_TestCanonicalMirrorMutatesLlmOnce)


; Private expansions retain their screen/matching edit while AI contexts restart.
global _LPI_Marker := "PRIVATE_CONTEXT_ASCII_SENTINEL_QZX"

_LPI_Refuse(State, Name, Receiver, Args*) {
	State["forbidden"] += 1
	throw Error("Forbidden proof boundary: " . Name)
}

_LPI_WithSafety(Mode, Private, OnlyText, Body) {
	global _LLM_Bridge_ContentGeneration, _LLM_Live
	SavedGeneration := _LLM_Bridge_ContentGeneration
	SavedLive := _LLM_Live
	State := Map("mode", Mode, "private", Private, "only_text", OnlyText,
		"forbidden", 0, "capture_count", 0, "marker_in_prompt", false)
	SavedCalls := []
	Failure := 0
	try {
		_LLM_Live := SavedLive.Clone()
		_LLM_Live["active"] := false
		for Port in [{ Fn: CurlAsyncRequest, Name: "CurlAsyncRequest" },
			{ Fn: ShellRunner_SpawnTreeOwned, Name: "ShellRunner_SpawnTreeOwned" },
			{ Fn: _LLM_CurlArtifactRun, Name: "_LLM_CurlArtifactRun" }] {
			Fn := Port.Fn
			SavedCalls.Push({ Fn: Fn, Own: Fn.HasOwnProp("Call"),
				Descriptor: Fn.HasOwnProp("Call") ? Fn.GetOwnPropDesc("Call") : 0 })
			Fn.DefineProp("Call", { Call: _LPI_Refuse.Bind(State, Port.Name) })
		}
		Body.Call(State)
	} catch as Err {
		Failure := Err
	} finally {
		_LLM_Bridge_ContentGeneration := SavedGeneration
		_LLM_Live := SavedLive
		for Item in SavedCalls {
			if Item.Own
				Item.Fn.DefineProp("Call", Item.Descriptor)
			else
				Item.Fn.DeleteProp("Call")
		}
	}
	FileAppend("# PRIVATE_CONTEXT_PROOF " . KL_JsonEncode(State) . "`n", "*", "UTF-8")
	AssertEqual(0, State["forbidden"], "No HTTP or native worker may be launched by this proof")
	if IsObject(Failure)
		throw Failure
}

_LPI_Expand(State) {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RegistryByGroup, _LPI_Marker
	global HSE_DisabledGroups, HSE_SeqCounter, HSE_RegistryGeneration, HSE_RegistryTransitionDepth
	global _AHK04_SendCalls, _HotstringRegistrar
	Group := "private-ai-context-fixture"
	AssertFalse(HSE_RegistryByGroup.Has(Group), "the fixture must own its registration group")
	Saved := [HSE_RegistryByGroup, HSE_DisabledGroups, HSE_SeqCounter,
		HSE_RegistryGeneration, HSE_RegistryTransitionDepth, _HotstringRegistrar]
	try {
		; A disabled private group exercises the genuine builder and registrar
		; without changing foreign live indexes or scheduling preview work.
		HSE_RegistryByGroup := Saved[1].Clone()
		HSE_DisabledGroups := Saved[2].Clone()
		HSE_DisabledGroups[Group] := true
		HSE_RegistryTransitionDepth += 1
		_HotstringRegistrar := 0
		CreateHotstring("*C", "qzx", (*) => _LPI_Marker,
			Map("Group", Group, "IsPrivate", State["private"], "OnlyText", State["only_text"],
				"FinalResult", true, "Priority", 10))
		AssertTrue(HSE_RegistryByGroup.Has(Group), "The genuine builder must register the mapping")
		Spec := HSE_RegistryByGroup[Group][1]
		AssertEqual(State["private"], Spec.IsPrivate)
		AssertEqual(State["only_text"], Spec.OnlyText)
		AssertTrue(Spec.FinalResult, "Windows final-result metadata must not be assumed to clear context")
		HSE_Buffer := "Before qzx"
		HSE_StartIsWordBoundary := true
		_AHK04_SetSendVerdict(true)
		Effect := 0
		AssertTrue(HSE_DispatchMatch(Spec, "", &Effect), "The genuine dispatch must commit through its captured sender")
		AssertEqual(1, _AHK04_SendCalls.Length, "Exactly one captured atomic output is committed")
		AssertEqual("SendFinalResult", _AHK04_SendCalls[1].Name)
		State["output_captured"] := true
		State["effect_private_present"] := Effect.HasOwnProp("IsPrivate")
		State["effect_clear_all"] := Effect.ClearAll
		State["effect_contains_marker"] := InStr(Effect.InsertedText, _LPI_Marker) > 0
		AssertEqual(State["only_text"] ? "Before " . _LPI_Marker : "", HSE_Buffer,
			"AI privacy must not alter the canonical screen/matching buffer")
		return Effect
	} finally {
		HSE_RegistryByGroup := Saved[1]
		HSE_DisabledGroups := Saved[2]
		HSE_SeqCounter := Saved[3]
		HSE_RegistryGeneration := Saved[4]
		HSE_RegistryTransitionDepth := Saved[5]
		_HotstringRegistrar := Saved[6]
	}
}

_LPI_PredictionCase(Mode, Private, OnlyText) {
	_LPI_WithSafety(Mode, Private, OnlyText, Run)
	Run(State) {
		_AHK04_RunIsolated(Dispatch)
		Dispatch() {
			_LPP_Run(_LPP_Menu(), "Before qzx", Body)
		}
		Body(Calls, Lines) {
			global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LPI_Marker
			Saved := _LLM_Bridge_Active
			try {
				_LLM_Bridge_Active := true
				_LPI_Expand(State)
				State["bridge_contains_marker"] := InStr(_LLM_Bridge_Buffer, _LPI_Marker) > 0
				if !OnlyText {
					AssertEqual("", _LLM_Bridge_Buffer, "The existing Send-mode path clears the context")
					AssertFalse(LLM_Menu_TriggerPrediction(), "An empty context must refuse before transport")
					AssertEqual(0, Calls.Length)
					return
				}
				; Resume ordinary typing after the committed expansion. The private
				; replacement remains on screen but must not reenter an AI prompt.
				_LLM_Bridge_ApplyBufferEdit(0, " after typing")
				if Mode == "automatic" {
					Timer := 0
					Schedule(Fn, Period) {
						if Period < 0
							Timer := Fn
					}
					LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer, "", Schedule)
					AssertTrue(HasMethod(Timer, "Call"), "The real automatic owner must publish a callback")
					Timer.Call()
				} else if Mode == "named" {
					AssertTrue(LLM_Menu_TriggerPredictionWith("advanced"))
				} else {
					AssertTrue(LLM_Menu_TriggerPrediction())
				}
				AssertEqual(1, Calls.Length, "The actual prediction pipeline must reach its capture-only transport")
				State["capture_count"] := Calls.Length
				State["marker_in_prompt"] := InStr(Calls[1]["ctx"], _LPI_Marker) > 0
				Request := _LLMRemote_BuildRequestContext(Calls[1]["system"], Calls[1]["ctx"], Calls[1]["tail"])
				State["marker_in_user_body"] := InStr(Request["user"], _LPI_Marker) > 0
				AssertEqual(!Private, State["marker_in_prompt"], "A private expansion must be absent from the real PromptBuilder context")
			} finally {
				LLM_Engine_CancelTimer()
				_LLM_Bridge_Active := Saved
			}
		}
	}
}

_LPI_AgentCase(Private, OnlyText) {
	_LPI_WithSafety("agent-off", Private, OnlyText, Run)
	Run(State) {
		_AHK04_RunIsolated(Dispatch)
		Dispatch() {
			_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), Body)
		}
		Body(Fx, Lines, Sent) {
			global _LLM_Bridge_Active, _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding, _LPI_Marker
			Saved := { Active: _LLM_Bridge_Active, Buffer: _LLM_Bridge_AgentBuffer, Feeding: _LLM_Bridge_AgentFeeding }
			try {
				_LLM_Bridge_Active := false
				_LLM_Bridge_AgentFeeding := false
				_LLM_Bridge_AgentBuffer := ""
				AssertTrue(_LLM_Bridge_AgentFeedIsWanted(), "The real automatic policy must admit its separate typing feed")
				LLM_Bridge_MirrorAgentEdit(0, "Before qzx")
				_LPI_Expand(State)
				State["bridge_contains_marker"] := InStr(_LLM_Bridge_AgentBuffer, _LPI_Marker) > 0
				if !OnlyText {
					AssertEqual("", _LLM_Bridge_AgentBuffer, "The Send-mode witness clears the separate agent context too")
					AssertEqual(0, Fx.Remote.Length)
					return
				}
				Pause := _LAG_TypeThroughBridge(Fx, " after typing please schedule a meeting tomorrow")
				AssertTrue(HasMethod(Pause, "Call"), "The actual agent typing owner must arm a pause")
				AssertTrue(Pause.Call(), "The actual pause must build a System1 prompt")
				AssertEqual(1, Fx.Remote.Length, "The actual agent prompt must reach a capture-only HTTP port")
				State["capture_count"] := Fx.Remote.Length
				State["marker_in_prompt"] := InStr(Fx.Remote[1]["body"], _LPI_Marker) > 0
				AssertEqual(!Private, State["marker_in_prompt"], "A private expansion must be absent from the automatic agent prompt")
			} finally {
				LLM_Engine_CancelTimer()
				_LLM_Bridge_Active := Saved.Active
				_LLM_Bridge_AgentBuffer := Saved.Buffer
				_LLM_Bridge_AgentFeeding := Saved.Feeding
			}
		}
	}
}

for Mode in ["manual", "named", "automatic"]
	Test("LLM private context " . Mode . " private literal (private-ai-context)", _LPI_PredictionCase.Bind(Mode, true, true))
Test("LLM private context public literal control (private-ai-context)", _LPI_PredictionCase.Bind("manual", false, true))
Test("LLM private context private Send-mode control (private-ai-context)", _LPI_PredictionCase.Bind("manual", true, false))
for Vector in [{ Private: true, OnlyText: true }, { Private: false, OnlyText: true }, { Private: true, OnlyText: false }]
	Test("LLM private context agent private=" . Vector.Private . " literal=" . Vector.OnlyText . " (private-ai-context)",
		_LPI_AgentCase.Bind(Vector.Private, Vector.OnlyText))


; Every committed output route must preserve the same privacy provenance.
_LPI_CommittedOwner(Mode, Private) {
	_LPI_WithSafety(Mode, Private, true, Run)
	Run(State) {
		_HNP_Run(Body)
		Body() {
			global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer, _LPI_Marker
			HSE_Buffer := "Before ab"
			_PrefixBuffer := HSE_Buffer
			_LLM_Bridge_Buffer := HSE_Buffer
			Effect := 0
			if Mode == "callback" {
				Spec := { Callback: (*) => { Ok: true, Bs: 2, Ins: _LPI_Marker }, IsPrivate: Private }
				AssertTrue(_HSE_DispatchRawCallback(Spec, "", &Effect), "the outer callback commits one declared output")
			} else if Mode == "notepad" || Mode == "notepad-raw" {
				OutputHostResolverPrimeForTest("notepad.exe")
				if Mode == "notepad" {
					Spec := _AHK04_NormalSpec()
					Spec.Replacement := _LPI_Marker
					Spec.IsPrivate := Private
				} else {
					Spec := { Trigger: "ab", RawCallback: true, SupportsPreparation: true,
						Callback: Prepare, IsPrivate: Private }
				}
				Request := Map("Requests", [])
				Owner := HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_Record.Bind(Request))
				AssertTrue(Owner is Map, "the real native dispatch must publish its pending owner")
				AssertEqual(1, Request["Requests"].Length, "one native request is captured without execution")
				AssertEqual("Before ab", _LLM_Bridge_Buffer, "pending output has not changed AI context")
				_HNP_Settle(Request)
				AssertTrue(Owner["Committed"], "the actual atomic hook must prove its commit")
				Effect := Owner["Effect"]
			} else {
				Owner := Map("EraseUnits", 2, "OnlyText", true, "PlainInsertedText", _LPI_Marker,
					"EndCharPart", "", "IsPrivate", Private, "Trigger", "ab",
					"ReplacementForLog", _LPI_Marker, "HType", "star", "Category", "fixture", "Section", "fixture")
				if Mode == "terminal-raw"
					Owner["RawEffect"] := { Ins: _LPI_Marker }
				Effect := _HSE_CommitTerminalOwner(Owner, "")
			}
			AssertEqual(Private ? "" : "Before " . _LPI_Marker, _LLM_Bridge_Buffer,
				"every committed owner must restart private AI context while preserving public edits")
			AssertTrue(Effect.HasOwnProp("IsPrivate"), "every committed effect must carry its provenance")
			AssertEqual(Private, Effect.IsPrivate, "privacy must come from the original spec or owner")
			AssertEqual("Before " . _LPI_Marker, HSE_Buffer, "privacy must preserve the screen and matching edit")
			AssertEqual(_LPI_Marker, Effect.InsertedText, "privacy must not erase canonical output metadata")
			Prepare(EndChar, PrepareOnly) {
				return { Prepared: true, Ok: true, Bs: 2, Ins: _LPI_Marker }
			}
		}
	}
}

for _LPI_OwnerMode in ["callback", "terminal", "terminal-raw", "notepad", "notepad-raw"] {
	Test("LLM private context committed " . _LPI_OwnerMode . " private (private-ai-context)",
		_LPI_CommittedOwner.Bind(_LPI_OwnerMode, true))
	Test("LLM private context committed " . _LPI_OwnerMode . " public (private-ai-context)",
		_LPI_CommittedOwner.Bind(_LPI_OwnerMode, false))
}


_LPI_InvalidProvenance(Kind) {
	_LPP_Run(_LPP_Menu(), "retained public context", Body)
	Body(Calls, Lines) {
		global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
		SavedActive := _LLM_Bridge_Active
		SavedGeneration := _LLM_Bridge_ContentGeneration
		PreviousCritical := Critical("On")
		try {
			_LLM_Bridge_Active := true
			Effect := { DeleteFromEnd: 3, InsertedText: "must not publish" }
			if Kind == "string"
				Effect.IsPrivate := "false"
			else if Kind == "integer"
				Effect.IsPrivate := 2
			Refused := false
			try _HSE_MirrorCanonicalEffectToLlm(Effect)
			catch as Err {
				if Type(Err) != "Error" || Err.Message != "Canonical hotstring effect requires DeleteFromEnd, InsertedText and Boolean IsPrivate."
					throw Err
				Refused := true
			}
			AssertTrue(Refused, "invalid provenance must fail before publication")
			AssertEqual("retained public context", _LLM_Bridge_Buffer, "invalid metadata cannot edit AI context")
			AssertEqual(SavedGeneration, _LLM_Bridge_ContentGeneration, "a refused effect cannot advance the content epoch")
			AssertEqual(0, Calls.Length, "refusal cannot create a transport")
		} finally {
			_LLM_Bridge_Active := SavedActive
			_LLM_Bridge_ContentGeneration := SavedGeneration
			Critical(PreviousCritical)
		}
	}
}

for _LPI_InvalidKind in ["missing", "string", "integer"]
	Test("LLM private context refuses " . _LPI_InvalidKind . " provenance (private-ai-context)",
		_LPI_InvalidProvenance.Bind(_LPI_InvalidKind))
