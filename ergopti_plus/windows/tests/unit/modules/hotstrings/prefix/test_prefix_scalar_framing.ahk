; tests/unit/modules/hotstrings/prefix/test_prefix_scalar_framing.ahk

; ==============================================================================
; MODULE: Prefix and Prediction Scalar Framing Tests
; DESCRIPTION:
; Replays raw callback fragments through actual prefix admission and the real
; bridge RAM mirror with passive Schedule/Focus ports. No keyboard input,
; application receiving, network request or visible tooltip is exercised.
; ==============================================================================

#Requires AutoHotkey v2.0

_PCSF_Snapshot(State) {
	global HSE_Buffer, _PrefixBuffer, LastSentCharacterKeyTime
	global _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Bridge_PrefixObserver
	global _PrefixContentGeneration, _PrefixRenderTimer, _PrefixRenderScheduledGeneration
	global _LLM_Engine, _LLM_Agent_Generation, _LLM_Agent_Auto, _UserHotstringsInputSerial
	Owner := _LLM_Bridge_PrefixObserver
	return { Engine: HSE_Buffer, Prefix: _PrefixBuffer, Mirror: _LLM_Bridge_Buffer,
		Agent: _LLM_Bridge_AgentBuffer, Times: LastSentCharacterKeyTime.Clone(),
		ObserverCount: State.Scheduled.Length, ObserverChar: IsObject(Owner) ? Owner.Char : "",
		OldObserverCurrent: _LLM_Bridge_PrefixObserverStillCurrent(State.OldObserver),
		ContentGeneration: _PrefixContentGeneration,
		RenderArmed: IsObject(_PrefixRenderTimer) || _PrefixRenderScheduledGeneration != -1,
		Request: _LLM_Engine["request_id"], AgentGeneration: _LLM_Agent_Generation,
		AgentTimer: _LLM_Agent_Auto["timer"], Physical: KS_GetPhysicalInputGeneration(), UserInput: _UserHotstringsInputSerial }
}

_PCSF_Sequence(Mode, State, Schedule, Focus) {
	global CategoryEnabled, Features, ScriptInformation, _SendHook, _HotstringRegistrar
	global _PrefixBuffer, _PrefixContentGeneration, _PrefixInputContextGeneration
	global _PrefixFocusedControlToken, _PrefixLastKeyTick, _PrefixPrivateResidue
	global _PrefixVisibleFireDecisions, _PrefixModifierIsDown, _PrefixWatcherSuppressed
	global _KLLastShownSuggestion, _HSResolveCache, _HSResolveGen, LastSentCharacterKeyTime
	global HSE_Buffer, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled, HSE_IdleResetSeconds, HSE_ArrowResetsWord
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
	global _PrefixRenderTimer, _PrefixRenderScheduledGeneration, _PrefixRenderQueuedWallMs
	global _LLM_Bridge_PrefixObserver, _LLM_Agent_Generation, _LLM_Agent_Auto
	global _PrefixInputHook, HSE_StartIsWordBoundary
	global _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc, _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	global _UserHotstringsOwner, _UserHotstringsInputSerial, _LLM_Bridge_LastLogTick
	global _Stub_OutputHostExe, _Stub_OutputHostTitle
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE, _OUTPUT_HOST_METADATA_PROBE
	global _OUTPUT_HOST_TITLE_PROBE, _OUTPUT_HOST_RESOLVE_SERIAL
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	Saved := { Categories: CategoryEnabled, Features: Features, Script: ScriptInformation,
		Send: _SendHook, Registrar: _HotstringRegistrar, Prefix: _PrefixBuffer,
		Content: _PrefixContentGeneration, Context: _PrefixInputContextGeneration,
		Focus: _PrefixFocusedControlToken, Last: _PrefixLastKeyTick, Private: _PrefixPrivateResidue,
		Decisions: _PrefixVisibleFireDecisions, Modifiers: _PrefixModifierIsDown, Suppressed: _PrefixWatcherSuppressed,
		Suggestion: _KLLastShownSuggestion, Resolver: _HSResolveCache, Times: LastSentCharacterKeyTime,
		Word: HSE_WORD_TERMINATORS, Consumed: HSE_CONSUMED_DELIMITERS,
		Repeat: HSE_RepeatEnabled, Combos: HSE_PersonalInfoCombosEnabled,
		Idle: HSE_IdleResetSeconds, Arrow: HSE_ArrowResetsWord,
		QueuedWall: _PrefixRenderQueuedWallMs, RenderTimer: _PrefixRenderTimer,
		RenderGeneration: _PrefixRenderScheduledGeneration,
		FireQueue: _HSE_FireLogQueue, FireScheduled: _HSE_FireLogScheduled,
		FireGeneration: _HSE_FireLogScheduledGeneration, FireTimer: _HSE_FireLogTimer,
		AgentGeneration: _LLM_Agent_Generation, AgentAuto: _LLM_Agent_Auto, Hook: _PrefixInputHook,
		KeyVk: _KS_LastPhysicalKeyVk, KeySc: _KS_LastPhysicalKeySc, KeyEpoch: _KS_LastPhysicalKeyEpoch,
		KeySources: _KS_LastPhysicalKeySources, UserOwner: _UserHotstringsOwner, UserInput: _UserHotstringsInputSerial,
		BridgeLog: _LLM_Bridge_LastLogTick, App: KLHook.prev_app, Title: KLHook.prev_title,
		HostExe: _Stub_OutputHostExe, HostTitle: _Stub_OutputHostTitle, HostCache: _OUTPUT_HOST_CACHE,
		HostIdentity: _OUTPUT_HOST_IDENTITY_PROBE, HostMetadata: _OUTPUT_HOST_METADATA_PROBE,
		HostTitleProbe: _OUTPUT_HOST_TITLE_PROBE, HostSerial: _OUTPUT_HOST_RESOLVE_SERIAL,
		Suspended: A_IsSuspended }
	Face := Chr(0x1F600), Other := Chr(0x1F601)
	High := Chr(0xD83D), Low := Chr(0xDE00)
	Initial := "word", Facts := { Frames: [], RawPrefeed: [], Sends: [], IncompleteCollections: 0 }
	State.Control := State.Focus["control"]
	Mirror(Raw) {
		Facts.RawPrefeed.Push(Raw)
		return LLM_Bridge_FeedCharForPrefix(Raw, Schedule, Focus, (*) => Mode == "agent-pair")
	}
	Context() => _PrefixEnsureInputContext(State.Control)
	Feed(Raw) {
		_OnPrefixChar(0, Raw, Mirror, Context)
		Facts.Frames.Push(_PCSF_Snapshot(State))
	}
	CollectIncomplete(Content, Context) {
		Facts.IncompleteCollections += 1
		return []
	}
	Capture(Name, Args*) {
		Facts.Sends.Push({ Name: Name, Payload: Args[1] })
		return true
	}
	PreviousCritical := Critical("On")
	try {
		; Park existing owners without cancelling them. The enclosing Critical
		; keeps their callbacks pending until their original state is restored.
		_KS_LastPhysicalKeySources := Saved.KeySources.Clone()
		_UserHotstringsOwner := 0
		_LLM_Agent_Auto := Saved.AgentAuto.Clone()
		_LLM_Agent_Auto["timer"] := 0
		_PrefixRenderTimer := 0, _PrefixRenderScheduledGeneration := -1
		_HSE_FireLogTimer := 0, _HSE_FireLogScheduled := false
		_HSE_FireLogScheduledGeneration := -1, _HSE_FireLogQueue := []
		HSE_TestReset()
		SimulateRegularApp()
		CategoryEnabled := Map("Hotstrings", Mode != "hotstrings-disabled")
		Features := Map()
		ScriptInformation := Map("MagicKey", Chr(0x2605))
		_SendHook := Capture
		_HotstringRegistrar := 0
		_PrefixBuffer := Initial
		HSE_Buffer := Initial
		_PrefixFocusedControlToken := State.Control
		_PrefixPrivateResidue := false
		_PrefixLastKeyTick := ""
		_PrefixWatcherSuppressed := 0
		_PrefixVisibleFireDecisions := []
		_PrefixModifierIsDown := (*) => false
		_KLLastShownSuggestion := ""
		LastSentCharacterKeyTime := Map()
		_HSResolveCache := Map("_scalar_probe|native", { gen: _HSResolveGen, val: { ShowTooltip: false } })
		HSE_WORD_TERMINATORS := Saved.Word . Face
		HSE_CONSUMED_DELIMITERS := Saved.Consumed . Face
		HSE_RepeatEnabled := false
		HSE_PersonalInfoCombosEnabled := false
		HSE_IdleResetSeconds := 0
		HSE_ArrowResetsWord := false
		_HSE_FireLogQueue := [], _HSE_FireLogScheduled := false
		_HSE_FireLogScheduledGeneration := -1, _HSE_FireLogTimer := 0
		_LLM_Bridge_Active := Mode != "agent-pair" && Mode != "timed-astral-body"
		_LLM_Bridge_Buffer := Initial
		_LLM_Bridge_AgentBuffer := Mode == "agent-pair" ? Initial : ""
		_LLM_Bridge_AgentFeeding := Mode == "agent-pair"
		if Mode == "agent-pair" || Mode == "direct-bridge" {
			AssertTrue(LLM_Agent_OnTyping(Initial), "the previous complete word owns a real agent pause")
			Facts.AgentGenerationBefore := _LLM_Agent_Generation
		}
		; A genuine preceding observer is invalidated by the raw physical edge;
		; no observer may then notify against a high-only replacement context.
		_LLM_Bridge_SchedulePrefixObserver("d", Schedule, Focus)
		State.OldObserver := _LLM_Bridge_PrefixObserver
		Facts.ObserverBaseline := State.Scheduled.Length
		_PrefixScheduleRender()
		Facts.ContentBefore := _PrefixContentGeneration
		if Mode == "retired-hook" {
			Current := {}, Retired := {}
			_PrefixInputHook := Current
			Facts.BeforeRetired := _PCSF_Snapshot(State)
			_OnPrefixCharGuarded(Retired, "x")
			_OnPrefixKeyDownGuarded(Retired, 0x08, 0x00E)
			Facts.AfterRetired := _PCSF_Snapshot(State)
			_OnPrefixCharGuarded(Current, "a")
			Facts.AfterCurrent := _PCSF_Snapshot(State)
		} else if Mode == "direct-bridge" {
			LLM_Bridge_OnChar(High)
			Facts.Frames.Push(_PCSF_Snapshot(State))
			LLM_Bridge_OnChar(Low)
			Facts.Frames.Push(_PCSF_Snapshot(State))
		} else if Mode == "whole-pair" {
			Feed(Face)
		} else if Mode == "whole-dead-key-chunk" {
			Feed("´.")
		} else {
			if Mode == "timed-astral-body" {
				CreateHotstring("*?C", Initial . Other . Chr(0x2605), "RESULT",
					Map("Category", "_scalar_probe", "Section", "native", "TimeActivationSeconds", 1))
				; Registering invalidates projections, not the already-visible body.
				_PrefixSetBuffer(Initial), HSE_Buffer := Initial
			}
			if Mode == "synthetic-navigation" {
				Ordinary := HS_CommitSyntheticEffect("{Left}")
				AssertEqual("kept", Ordinary.Kind)
				AssertEqual(Initial, HSE_Buffer, "ordinary words keep the existing navigation preference")
				AssertEqual(Initial, _PrefixBuffer)
			}
			Feed(High)
			if Mode != "hotstrings-disabled"
				_LookupAndRender(CollectIncomplete)
			switch Mode {
				case "backspace":
					_PrefixFeedBackspace()
					; This is the same RAM edit used by real bridge Backspace,
					; without invoking unrelated agent/prediction services.
					_LLM_Bridge_ApplyBufferEdit(_TextTailCodeUnits(_LLM_Bridge_Buffer, 1), "")
				case "focus-changed":
					State.Control := 202
					State.Focus["control"] := 202
				case "focus-unresolved":
					State.Control := 0
					State.Focus["control"] := 0
				case "navigation-keeps-word":
					AssertFalse(KS_IsDown("Control") || KS_IsDown("RAlt") || KS_IsDown("SC138"),
						"the passive physical-key callback requires released native modifiers")
					_OnPrefixKeyDown(0, 0x25, 0x14B)
				case "synthetic-navigation":
					Facts.Synthetic := HS_CommitSyntheticEffect("{Left}")
				case "refused-synthetic-navigation":
					Facts.RefusedResult := HS_RunSyntheticInputTransaction("{Left}", (*) => false)
					Facts.RefusedBoundary := HSE_StartIsWordBoundary
				case "suspend-resume":
					Suspend(true)
					HotstringPrefixWatcherOnSuspend()
					Suspend(false)
					HotstringPrefixWatcherOnResume(false)
			}
			Feed(Mode == "same-high" || Mode == "timed-astral-body" ? Chr(0xDE01) : Low)
			if Mode == "timed-astral-body"
				Feed(Chr(0x2605))
		}
		if Mode == "agent-pair" {
			Facts.CompletedObserverRan := _LLM_Bridge_RunPrefixObserver(_LLM_Bridge_PrefixObserver)
			Facts.CompletedAgentTimer := _LLM_Agent_Auto["timer"]
			Facts.CompletedAgentGeneration := _LLM_Agent_Generation
		}
		Facts.CategoryEnabled := Mode != "hotstrings-disabled"
		return Facts
	} finally {
		try {
			_LLM_Agent_CancelPause()
			_PrefixInvalidateDeferredEffects()
			LLM_Bridge_CancelPrefixObserver()
			HSE_TestReset()
		} finally {
			Suspend(Saved.Suspended)
			_LLM_Agent_Auto := Saved.AgentAuto, _LLM_Agent_Generation := Saved.AgentGeneration
			_PrefixInputHook := Saved.Hook
			_KS_LastPhysicalKeyVk := Saved.KeyVk, _KS_LastPhysicalKeySc := Saved.KeySc
			_KS_LastPhysicalKeyEpoch := Saved.KeyEpoch, _KS_LastPhysicalKeySources := Saved.KeySources
			_UserHotstringsOwner := Saved.UserOwner, _UserHotstringsInputSerial := Saved.UserInput
			_LLM_Bridge_LastLogTick := Saved.BridgeLog
			KLHook.prev_app := Saved.App, KLHook.prev_title := Saved.Title
			_Stub_OutputHostExe := Saved.HostExe, _Stub_OutputHostTitle := Saved.HostTitle
			_OUTPUT_HOST_CACHE := Saved.HostCache, _OUTPUT_HOST_IDENTITY_PROBE := Saved.HostIdentity
			_OUTPUT_HOST_METADATA_PROBE := Saved.HostMetadata, _OUTPUT_HOST_TITLE_PROBE := Saved.HostTitleProbe
			_OUTPUT_HOST_RESOLVE_SERIAL := Saved.HostSerial
			CategoryEnabled := Saved.Categories, Features := Saved.Features, ScriptInformation := Saved.Script
			_SendHook := Saved.Send, _HotstringRegistrar := Saved.Registrar
			_PrefixBuffer := Saved.Prefix, _PrefixContentGeneration := Saved.Content
			_PrefixInputContextGeneration := Saved.Context, _PrefixFocusedControlToken := Saved.Focus
			_PrefixLastKeyTick := Saved.Last, _PrefixPrivateResidue := Saved.Private
			_PrefixVisibleFireDecisions := Saved.Decisions, _PrefixModifierIsDown := Saved.Modifiers
			_PrefixWatcherSuppressed := Saved.Suppressed, _KLLastShownSuggestion := Saved.Suggestion
			_HSResolveCache := Saved.Resolver, LastSentCharacterKeyTime := Saved.Times
			HSE_WORD_TERMINATORS := Saved.Word, HSE_CONSUMED_DELIMITERS := Saved.Consumed
			HSE_RepeatEnabled := Saved.Repeat, HSE_PersonalInfoCombosEnabled := Saved.Combos
			HSE_IdleResetSeconds := Saved.Idle, HSE_ArrowResetsWord := Saved.Arrow
			_PrefixRenderTimer := Saved.RenderTimer
			_PrefixRenderScheduledGeneration := Saved.RenderGeneration
			_PrefixRenderQueuedWallMs := Saved.QueuedWall
			_HSE_FireLogQueue := Saved.FireQueue, _HSE_FireLogScheduled := Saved.FireScheduled
			_HSE_FireLogScheduledGeneration := Saved.FireGeneration, _HSE_FireLogTimer := Saved.FireTimer
			Critical(PreviousCritical)
		}
	}
}

_PCSF_Check(Mode, State, Schedule, Focus) {
	Facts := _PCSF_Sequence(Mode, State, Schedule, Focus)
	Face := Chr(0x1F600), Other := Chr(0x1F601), High := Chr(0xD83D), Low := Chr(0xDE00)
	if Mode == "retired-hook" {
		Before := Facts.BeforeRetired, After := Facts.AfterRetired
		for Name in ["Engine", "Prefix", "Mirror", "Agent", "ContentGeneration", "Physical", "ObserverCount", "UserInput"]
			AssertEqual(Before.%Name%, After.%Name%, "retired native callbacks must not mutate " . Name)
		AssertEqual(Before.Times.Count, After.Times.Count, "retired native characters must not acquire timestamps")
		AssertEqual("worda", Facts.AfterCurrent.Mirror, "the current hook still reaches the genuine bridge even if desktop focus refuses HSE")
		AssertEqual(0, Facts.Sends.Length)
		return
	}
	if Mode == "direct-bridge" {
		First := Facts.Frames[1], Last := Facts.Frames[2]
		AssertEqual("word" . High, First.Mirror, "direct fallback retains the original raw high once")
		AssertEqual("word" . Face, Last.Mirror, "direct fallback derives the completion from its own buffer")
		AssertTrue(First.AgentGeneration > Facts.AgentGenerationBefore)
		AssertEqual(0, First.AgentTimer, "direct fallback must not rearm the agent on an incomplete high")
		AssertTrue(IsObject(Last.AgentTimer), "the directly completed scalar may arm a new real agent pause")
		AssertTrue(Last.AgentGeneration > First.AgentGeneration)
		AssertEqual(0, Facts.Sends.Length)
		return
	}
	if Mode == "whole-pair" || Mode == "whole-dead-key-chunk" {
		Chunk := Mode == "whole-pair" ? Face : "´."
		AssertEqual(1, Facts.Frames.Length, "one complete native chunk remains one admission")
		AssertEqual(1, Facts.RawPrefeed.Length)
		AssertEqual(Chunk, Facts.RawPrefeed[1], "the real RAM mirror receives the original complete chunk")
		AssertEqual(Chunk, Facts.Frames[1].ObserverChar, "one observer retains the complete callback chunk")
		AssertEqual("word" . Chunk, Facts.Frames[1].Engine)
		AssertEqual("word" . Chunk, Facts.Frames[1].Mirror)
		AssertEqual("", Facts.Frames[1].Prefix, "the final complete delimiter owns the preview boundary")
		return
	}
	First := Facts.Frames[1], Last := Facts.Frames[Facts.Frames.Length]
	AssertEqual(Facts.ObserverBaseline, First.ObserverCount, "a high-only buffer must not arm a new observer")
	AssertFalse(First.OldObserverCurrent, "the prior complete context loses its observer on the physical edge")
	if Facts.CategoryEnabled {
		AssertFalse(First.RenderArmed, "an incomplete current character must retire the preceding render")
		AssertTrue(First.ContentGeneration > Facts.ContentBefore, "retained raw input must invalidate preceding presentation ownership")
		AssertEqual(0, Facts.IncompleteCollections, "a previously dispatched renderer must reject its incomplete snapshot before collecting decisions")
	}
	AssertFalse(First.Times.Has(High), "an orphan high surrogate must never become a time-activation key")
	AssertFalse(First.Times.Has(Low), "an unobserved low surrogate must never become a timestamp key")
	if Mode == "prediction-pair" || Mode == "agent-pair" || Mode == "hotstrings-disabled" || Mode == "same-high" {
		Scalar := Mode == "same-high" ? Other : Face
		AssertEqual(Scalar, Last.ObserverChar, "the completion observer receives one entire scalar from its own raw buffer")
		AssertEqual(Facts.ObserverBaseline + 1, Last.ObserverCount, "exactly one completion observer is scheduled")
		if Mode == "agent-pair" {
			AssertEqual("word" . Scalar, Last.Agent, "agent-only raw input is neither duplicated nor inferred from HSE")
			AssertTrue(First.AgentGeneration > Facts.AgentGenerationBefore, "the old complete pause loses its generation on raw high")
			AssertEqual(0, First.AgentTimer, "incomplete context must retire the previous agent pause without rearming")
			AssertTrue(Facts.CompletedObserverRan, "the genuinely completed observer is admitted")
			AssertTrue(IsObject(Facts.CompletedAgentTimer), "the completed scalar may arm a new real agent pause")
			AssertTrue(Facts.CompletedAgentGeneration > First.AgentGeneration)
		}
		else {
			AssertEqual("word" . Scalar, Last.Mirror, "prediction context retains each original unit once")
			AssertTrue(First.Request > 10, "the raw high immediately invalidates pre-existing prediction responses")
		}
		if Facts.CategoryEnabled {
			AssertEqual("word" . Scalar, Last.Engine, "HSE receives the original raw chunks once")
			AssertEqual(Mode == "same-high" ? "word" . Other : "", Last.Prefix,
				"a different complete scalar sharing a high surrogate is not a word boundary")
			AssertTrue(Last.Times.Has(Scalar), "the completed scalar owns its timestamp")
			AssertFalse(Last.Times.Has(High) || Last.Times.Has(Chr(0xDE01)) || Last.Times.Has(Low),
				"no constituent surrogate is a timestamp key")
		}
	} else if Mode == "timed-astral-body" {
		AssertTrue(Facts.Frames[2].Times.Has(Other), "a complete astral predecessor must satisfy the real time gate")
		AssertEqual(1, Facts.Sends.Length, "the genuine time-gated STAR dispatch occurs once after completion")
		AssertEqual("SendFinalResult", Facts.Sends[1].Name)
		AssertEqual("{BackSpace 6}{Text}RESULT", Facts.Sends[1].Payload)
		AssertEqual("RESULT", Last.Engine)
	} else {
		if Mode == "refused-synthetic-navigation" {
			AssertEqual(false, Facts.RefusedResult, "the native send refusal remains a refusal")
			AssertFalse(Facts.RefusedBoundary, "an uncertain failed send cannot promise a new word boundary")
		}
		AssertFalse(InStr(Last.Engine, Face, true), "a revoked fragment cannot complete in the next engine context")
		AssertFalse(InStr(Last.Prefix, Face, true), "a revoked fragment cannot complete in the next preview context")
		AssertFalse(InStr(Last.Mirror, Face, true), "a revoked fragment cannot complete in the next prediction context")
		AssertEqual(Facts.ObserverBaseline, Last.ObserverCount, "orphan completion after revocation must not arm an observer")
		AssertFalse(Last.Times.Has(Face) || Last.Times.Has(High) || Last.Times.Has(Low),
			"revoked fragments cannot borrow a complete key's activation timestamp")
	}
	if Mode != "timed-astral-body"
		AssertEqual(0, Facts.Sends.Length, "observation-only framing does not emit application text")
}

_PCSF_Case(Mode) {
	; Release parked callbacks only after BOTH nested fixtures have restored
	; their generation, engine, schedule ports and exact original timer owners.
	PreviousCritical := Critical("On")
	try {
		if Mode == "agent-pair" || Mode == "direct-bridge" {
			Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_PCSF_Check.Bind(Mode))
			_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), Body)
		} else {
			_PCA_WithObserverFixture(_PCSF_Check.Bind(Mode))
		}
	} finally {
		Critical(PreviousCritical)
	}
}

for _PCSF_Mode in ["prediction-pair", "agent-pair", "hotstrings-disabled", "same-high",
	"backspace", "focus-changed", "focus-unresolved", "navigation-keeps-word", "synthetic-navigation", "suspend-resume",
	"whole-pair", "whole-dead-key-chunk", "timed-astral-body",
	"retired-hook", "refused-synthetic-navigation", "direct-bridge"]
	Test("Prefix scalar framing: " . _PCSF_Mode . " keeps complete consumer ownership (prefix-scalar-framing)",
		_PCSF_Case.Bind(_PCSF_Mode))
