; tests/unit/test_prefix_char_admission.ahk

; ==============================================================================
; MODULE: Ordered Prefix Character Admission Tests
; DESCRIPTION:
; A yielded pre-feed observer allowed the magic key to enter HSE before the
; trigger's last character. Actual callbacks and timer reentry reproduce that
; failure without a keyboard hook, foreground input, or a visible tooltip.
; ==============================================================================

#Requires AutoHotkey v2.0

_PCA_Call(Char, PrefeedFn) {
	_OnPrefixChar(0, Char, PrefeedFn, (*) => true)
}

_PCA_TimerOrderAndOutput() {
	global CategoryEnabled, Features, ScriptInformation, _SendHook
	global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixVisibleFireDecisions
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding, _KLLastShownSuggestion
	global HSE_Buffer
	global _HSResolveCache, _HSResolveGen, _SR_ActiveTasks
	Saved := { Categories: CategoryEnabled, Features: Features, Script: ScriptInformation,
		Send: _SendHook, Active: _LLM_Bridge_Active, Agent: _LLM_Bridge_AgentFeeding,
		Decisions: _PrefixVisibleFireDecisions, Suggestion: _KLLastShownSuggestion,
		ResolverCache: _HSResolveCache, Tasks: _SR_ActiveTasks.Count }
	State := { Screen: "", Sends: 0, AdmittedCritical: false, Completed: false }
	Timer := 0
	Prefeed(Char) {
		if Char != "t"
			return
		State.AdmittedCritical := A_IsCritical > 0
		Timer := Later
		SetTimer(Timer, -1)
		Started := A_TickCount
		while ((A_TickCount - Started) & 0xFFFFFFFF) < 50
			Sleep(-1)
	}
	Later() {
		Input("★")
		Input("x")
		State.Completed := true
	}
	Input(Char) {
		State.Screen .= Char
		_PCA_Call(Char, Prefeed)
	}
	Capture(Name, Args*) {
		AssertEqual("SendFinalResult", Name, "the regular application uses one atomic burst")
		Payload := Args[1]
		AssertEqual("{BackSpace 3}{Text}c’était", Payload)
		State.Screen := SubStr(State.Screen, 1, Max(0, StrLen(State.Screen) - 3)) . "c’était"
		State.Sends += 1
		return true
	}
	try {
		HSE_TestReset()
		SimulateRegularApp()
		CategoryEnabled := Map("Hotstrings", true)
		Features := Map()
		ScriptInformation := Map("MagicKey", "★")
		_LLM_Bridge_Active := false
		_LLM_Bridge_AgentFeeding := false
		_PrefixBuffer := ""
		_PrefixFocusedControlToken := 1
		_PrefixVisibleFireDecisions := []
		_KLLastShownSuggestion := ""
		; The scenario deliberately has no visual preview. A due render must not
		; launch a real position worker against the user's foreground application.
		_HSResolveCache := Map("magickey|replace", {
			gen: _HSResolveGen, val: { ShowTooltip: false } })
		_SendHook := Capture
		HSE_Register("*", "ct★", 0, Map("Replacement", "c’était", "OnlyText", true,
			"Category", "magickey", "Section", "replace"))
		Input("c")
		Input("t")
		AssertFalse(A_IsCritical, "the direct callback restores the caller's scheduler")
		Started := A_TickCount
		while !State.Completed && ((A_TickCount - Started) & 0xFFFFFFFF) < 300
			Sleep(-1)
		AssertTrue(State.Completed, "the queued completing key actually runs")
		AssertTrue(State.AdmittedCritical, "serialization starts before pre-feed work")
		AssertEqual(1, State.Sends, "one expansion fires without any painted preview")
		AssertEqual("c’étaitx", State.Screen, "the later character follows the complete expansion")
		AssertEqual(State.Screen, HSE_Buffer, "the engine agrees with the recorded screen")
		AssertEqual(Saved.Tasks, _SR_ActiveTasks.Count, "the callback fixture creates no native worker")
	} finally {
		if IsObject(Timer)
			SetTimer(Timer, 0)
		_PrefixInvalidateDeferredEffects()
		HSE_TestReset()
		CategoryEnabled := Saved.Categories
		Features := Saved.Features
		ScriptInformation := Saved.Script
		_SendHook := Saved.Send
		_LLM_Bridge_Active := Saved.Active
		_LLM_Bridge_AgentFeeding := Saved.Agent
		_PrefixVisibleFireDecisions := Saved.Decisions
		_KLLastShownSuggestion := Saved.Suggestion
		_HSResolveCache := Saved.ResolverCache
		_PrefixSetBuffer("")
	}
}
Test("prefix: rapid magic key keeps callback order and output without preview (prefix-char-admission)",
	_PCA_TimerOrderAndOutput)

_PCA_WithObserverFixture(Body) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding, _LLM_Engine
	global _PrefixDeferredGeneration, _KS_PhysicalInputGeneration
	Saved := { Active: _LLM_Bridge_Active, Buffer: _LLM_Bridge_Buffer,
		Content: _LLM_Bridge_ContentGeneration, Agent: _LLM_Bridge_AgentBuffer,
		Feeding: _LLM_Bridge_AgentFeeding, Engine: _LLM_Engine,
		Lifecycle: _PrefixDeferredGeneration, Physical: _KS_PhysicalInputGeneration }
	State := { Focus: Map("hwnd", 101, "control", 102), Scheduled: [] }
	Schedule(Fn, Period) => State.Scheduled.Push({ Fn: Fn, Period: Period })
	Focus() => State.Focus.Clone()
	LLM_Bridge_CancelPrefixObserver()
	try {
		_LLM_Bridge_Active := true
		_LLM_Bridge_Buffer := ""
		_LLM_Bridge_AgentBuffer := ""
		_LLM_Bridge_AgentFeeding := false
		_LLM_Engine := Map("enabled", false, "request_id", 10,
			"timer_active", false, "pending_timer", "")
		Body.Call(State, Schedule, Focus)
	} finally {
		LLM_Bridge_CancelPrefixObserver()
		_LLM_Bridge_Active := Saved.Active
		_LLM_Bridge_Buffer := Saved.Buffer
		_LLM_Bridge_ContentGeneration := Saved.Content
		_LLM_Bridge_AgentBuffer := Saved.Agent
		_LLM_Bridge_AgentFeeding := Saved.Feeding
		_LLM_Engine := Saved.Engine
		_PrefixDeferredGeneration := Saved.Lifecycle
		_KS_PhysicalInputGeneration := Saved.Physical
	}
}

_PCA_MirrorIsBoundedAndCoalesced() {
	_Body(State, Schedule, Focus) {
		global _LLM_Bridge_Buffer, _LLM_Bridge_PrefixObserver, _LLM_Engine
		PreviousCritical := Critical("On")
		try {
			LLM_Bridge_FeedCharForPrefix("c", Schedule, Focus)
			Old := _LLM_Bridge_PrefixObserver
			LLM_Bridge_FeedCharForPrefix("t", Schedule, Focus)
			AssertEqual("ct", _LLM_Bridge_Buffer)
			AssertEqual(12, _LLM_Engine["request_id"], "responses are invalidated synchronously")
			AssertFalse(_LLM_Engine["timer_active"], "prediction observers have not run inline")
			AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Old))
			_LLM_Bridge_ApplyBufferEdit(2, "expanded")
			AssertTrue(_LLM_Bridge_PrefixObserverStillCurrent(_LLM_Bridge_PrefixObserver),
				"the current observer reads the canonical expansion rather than its trigger")
			AssertEqual("expanded", _LLM_Bridge_Buffer)
		} finally {
			Critical(PreviousCritical)
		}
		AssertEqual(2, State.Scheduled.Length, "each snapshot has a single owned one-shot")
		AssertEqual(-1, State.Scheduled[2].Period)
	}
	_PCA_WithObserverFixture(_Body)
}
Test("prefix: AI context mirrors synchronously while observers coalesce (prefix-char-admission)",
	_PCA_MirrorIsBoundedAndCoalesced)

_PCA_ObserverRejectsStaleOwners() {
	_Body(State, Schedule, Focus) {
		global _LLM_Bridge_PrefixObserver, _PrefixDeferredGeneration
		global _KS_PhysicalInputGeneration, _LLM_Bridge_Active
		PreviousCritical := Critical("On")
		try LLM_Bridge_FeedCharForPrefix("c", Schedule, Focus)
		finally Critical(PreviousCritical)
		Owner := _LLM_Bridge_PrefixObserver
		AssertTrue(_LLM_Bridge_PrefixObserverStillCurrent(Owner))
		for Key in ["hwnd", "control"] {
			Old := State.Focus[Key]
			State.Focus[Key] += 1
			AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Owner), "changed " . Key)
			State.Focus[Key] := Old
		}
		_PrefixDeferredGeneration += 1
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Owner), "reload/suspend lifecycle ABA")
		_PrefixDeferredGeneration -= 1
		_KS_PhysicalInputGeneration += 1
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Owner), "intervening physical input")
		_KS_PhysicalInputGeneration -= 1
		_LLM_Bridge_Active := false
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Owner), "bridge mode changed")
		_LLM_Bridge_Active := true
		LLM_Bridge_CancelPrefixObserver()
		AssertFalse(_LLM_Bridge_PrefixObserverStillCurrent(Owner), "retired timer")
	}
	_PCA_WithObserverFixture(_Body)
}
Test("prefix: deferred AI work rejects stale focus input lifecycle and mode (prefix-char-admission)",
	_PCA_ObserverRejectsStaleOwners)

_PCA_AgentMirrorOwnsItsFeed() {
	_Body(State, Schedule, Focus) {
		global _LLM_Bridge_Active, _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
		_LLM_Bridge_Active := false
		PreviousCritical := Critical("On")
		try {
			AssertTrue(LLM_Bridge_FeedCharForPrefix("c", Schedule, Focus, (*) => true))
			AssertTrue(_LLM_Bridge_AgentFeeding)
			AssertEqual("c", _LLM_Bridge_AgentBuffer, "the first character is retained before notification")
			LLM_Bridge_MirrorAgentEdit(1, "expanded")
			AssertEqual("expanded", _LLM_Bridge_AgentBuffer)
			AssertFalse(LLM_Bridge_FeedCharForPrefix("t", Schedule, Focus, (*) => false))
			AssertFalse(_LLM_Bridge_AgentFeeding)
			AssertEqual("", _LLM_Bridge_AgentBuffer, "disabling observation clears its context immediately")
		} finally {
			Critical(PreviousCritical)
		}
	}
	_PCA_WithObserverFixture(_Body)
}
Test("prefix: agent-only mirroring owns enable disable and canonical edits (prefix-char-admission)",
	_PCA_AgentMirrorOwnsItsFeed)

_PCA_StalePredictionCannotCancel() {
	_Body(State, Schedule, Focus) {
		global _LLM_Engine
		Timer := (*) => true
		_LLM_Engine["enabled"] := true
		_LLM_Engine["pending_timer"] := Timer
		_LLM_Engine["timer_active"] := true
		AssertFalse(LLM_Engine_OnKeystroke("old", "", Schedule, (*) => false))
		AssertEqual(ObjPtr(Timer), ObjPtr(_LLM_Engine["pending_timer"]))
		AssertTrue(_LLM_Engine["timer_active"])
		AssertEqual(10, _LLM_Engine["request_id"], "a refused observer does not invalidate newer work")
		AssertEqual(0, State.Scheduled.Length)
	}
	_PCA_WithObserverFixture(_Body)
}
Test("prefix: stale prediction observer cannot cancel a newer timer (prefix-char-admission)",
	_PCA_StalePredictionCannotCancel)

_PCA_StaleTransportCancellationCannotMutate() {
	_Body(State, Schedule, Focus) {
		global _LLM_Engine
		_LLM_Engine["active_request_signature"] := "new request"
		AssertFalse(LLM_Engine_CancelInflight((*) => false))
		AssertEqual(10, _LLM_Engine["request_id"])
		AssertEqual("new request", _LLM_Engine["active_request_signature"])
	}
	_PCA_WithObserverFixture(_Body)
}
Test("prefix: stale observer cannot invalidate newer transport ownership (prefix-char-admission)",
	_PCA_StaleTransportCancellationCannotMutate)

_PCA_StaleAgentCannotCancel() {
	_Body(Fx, Lines, Sent) {
		global _LLM_Agent_Generation, _LLM_Agent_Auto
		Timer := (*) => true
		_LLM_Agent_Auto["timer"] := Timer
		Generation := _LLM_Agent_Generation
		Calls := 0
		Guard() => (++Calls == 1)
		AssertFalse(LLM_Agent_OnTyping("old", Guard), "cold preparation must revalidate before mutation")
		AssertEqual(2, Calls)
		AssertEqual(Generation, _LLM_Agent_Generation)
		AssertEqual(ObjPtr(Timer), ObjPtr(_LLM_Agent_Auto["timer"]))
	}
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), _Body)
}
Test("prefix: agent observer revalidates before replacing the pause owner (prefix-char-admission)",
	_PCA_StaleAgentCannotCancel)

_PCA_ProductionUsesOnlyRamPrefeed() {
	Watcher := _DriverFuncBody("_OnPrefixChar")
	Mirror := _DriverFuncBody("LLM_Bridge_FeedCharForPrefix")
	Reissue := _DriverFuncBody("LLM_Bridge_ReissueLiveAfterExpansion")
	Assert(Watcher != "" && Mirror != "" && Reissue != "", "all ordered input owners exist")
	Assert(InStr(Watcher, 'PreviousCritical := Critical("On")')
		< InStr(Watcher, "LLM_Bridge_FeedCharForPrefix(Char)"))
	AssertContains(Watcher, "Critical(PreviousCritical)")
	Assert(!InStr(Mirror, "LLM_Agent_Config("), "the mirror never reads cold agent configuration")
	Assert(!InStr(Mirror, "LLM_Agent_OnTyping("), "the mirror never runs the agent observer")
	Assert(!InStr(Mirror, "LLM_Engine_OnKeystroke("), "the mirror never runs prediction observers")
	Assert(!InStr(Reissue, "LLM_Engine_OnKeystroke("), "live expansions use the same deferred owner")
	AssertContains(Reissue, "_LLM_Bridge_SchedulePrefixObserver(")
}
Test("prefix: production pre-feed and live reissue exclude ancillary work (prefix-char-admission)",
	_PCA_ProductionUsesOnlyRamPrefeed)


/** Replay one already-visible native InputHook chunk through actual admission. */
_PCA_DeadKeyChunk(Scenario) {
	global CategoryEnabled, Features, ScriptInformation, _SendHook
	global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixVisibleFireDecisions
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding, _KLLastShownSuggestion
	global _HSResolveCache, _HSResolveGen, LastSentCharacterKeyTime
	global HSE_Buffer, HSE_LastEndChar, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	Saved := { Categories: CategoryEnabled, Features: Features, Script: ScriptInformation,
		Send: _SendHook, Prefix: _PrefixBuffer, Focus: _PrefixFocusedControlToken,
		Decisions: _PrefixVisibleFireDecisions, Active: _LLM_Bridge_Active,
		Agent: _LLM_Bridge_AgentFeeding, Suggestion: _KLLastShownSuggestion,
		Resolver: _HSResolveCache, Times: LastSentCharacterKeyTime,
		Terminators: HSE_WORD_TERMINATORS, Consumed: HSE_CONSUMED_DELIMITERS,
		Repeat: HSE_RepeatEnabled, Combos: HSE_PersonalInfoCombosEnabled }
	Window := Gui()
	EditControl := Window.AddEdit(, Scenario.Initial . Scenario.Chunk)
	Window.Show("Hide")
	SendMessage(0x00B1, StrLen(EditControl.Value), StrLen(EditControl.Value), EditControl)
	Payloads := []
	Observed := []
	Capture(Name, Args*) {
		AssertEqual("SendFinalResult", Name, "one complete burst owns the already-visible chunk")
		Payloads.Push(Args[1])
		return true
	}
	Prefeed(Char) => Observed.Push(Char)
	try {
		HSE_TestReset()
		SimulateRegularApp()
		CategoryEnabled := Map("Hotstrings", true)
		Features := Map()
		ScriptInformation := Scenario.HasOwnProp("Magic") ? Map("MagicKey", Scenario.Magic) : Map()
		if Scenario.HasOwnProp("Magic") {
			HSE_RepeatEnabled := true
			HSE_PersonalInfoCombosEnabled := false
		}
		_LLM_Bridge_Active := false
		_LLM_Bridge_AgentFeeding := false
		_PrefixBuffer := Scenario.Initial
		_PrefixFocusedControlToken := 1
		_PrefixVisibleFireDecisions := []
		_KLLastShownSuggestion := ""
		_HSResolveCache := Map("_chunk_probe|native", {
			gen: _HSResolveGen, val: { ShowTooltip: false } })
		LastSentCharacterKeyTime := Map()
		HSE_WORD_TERMINATORS := Saved.Terminators . Chr(0x1F600)
		if Scenario.HasOwnProp("Consume") && Scenario.Consume
			HSE_CONSUMED_DELIMITERS := Saved.Consumed . "."
		_SendHook := Capture
		if Scenario.Trigger != "" {
			Options := Map("Category", "_chunk_probe", "Section", "native",
				"TimeActivationSeconds", Scenario.HasOwnProp("Timed") && Scenario.Timed ? 1 : 0)
			CreateHotstring(Scenario.Flags, Scenario.Trigger, Scenario.Replacement, Options)
			if Scenario.HasOwnProp("ExtraEnd") && Scenario.ExtraEnd
				CreateHotstring("?C", "foo´", "SHORT", Options)
		}
		HSE_Buffer := Scenario.Initial
		_PCA_Call(Scenario.Chunk, Prefeed)
		_PrefixCancelRender()
		AssertEqual(1, Observed.Length, "prefeed receives one physical callback")
		AssertEqual(Scenario.Chunk, Observed[1], "prefeed preserves the exact chunk")
		AssertEqual(Scenario.Sends, Payloads.Length, "a chunk can own at most one suffix expansion")
		AssertEqual(Scenario.End, HSE_LastEndChar, "only the final complete scalar frames END matching")
		for Payload in Payloads
			ControlSend(Payload, EditControl)
		Sleep(30)
		AssertEqual(Scenario.Expected, EditControl.Value, "native output preserves the complete visible batch")
		AssertEqual(Scenario.Expected, HSE_Buffer, "the canonical buffer agrees with native output")
		if Scenario.HasOwnProp("Prefix")
			AssertEqual(Scenario.Prefix, _PrefixBuffer, "the preview keeps only the final word")
		if Scenario.HasOwnProp("Timed") && Scenario.Timed {
			Assert(LastSentCharacterKeyTime.Has("´") && LastSentCharacterKeyTime.Has("."),
				"delivered scalars receive timing metadata before the single match")
			AssertEqual(LastSentCharacterKeyTime["´"], LastSentCharacterKeyTime["."],
				"one physical chunk has one observed timestamp")
		}
	} finally {
		_PrefixInvalidateDeferredEffects()
		HSE_TestReset()
		Window.Destroy()
		CategoryEnabled := Saved.Categories
		Features := Saved.Features
		ScriptInformation := Saved.Script
		_SendHook := Saved.Send
		_PrefixSetBuffer(Saved.Prefix)
		_PrefixFocusedControlToken := Saved.Focus
		_PrefixVisibleFireDecisions := Saved.Decisions
		_LLM_Bridge_Active := Saved.Active
		_LLM_Bridge_AgentFeeding := Saved.Agent
		_KLLastShownSuggestion := Saved.Suggestion
		_HSResolveCache := Saved.Resolver
		LastSentCharacterKeyTime := Saved.Times
		HSE_WORD_TERMINATORS := Saved.Terminators
		HSE_CONSUMED_DELIMITERS := Saved.Consumed
		HSE_RepeatEnabled := Saved.Repeat
		HSE_PersonalInfoCombosEnabled := Saved.Combos
	}
}

Test("prefix dead-key-chunk: END strips only the final delimiter", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "?C", Trigger: "foo´",
		Replacement: "BAR", Expected: "ABAR.", Sends: 1, End: "." }))
Test("prefix dead-key-chunk: consumed delimiter preserves the complete trigger", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "?C", Trigger: "foo´",
		Replacement: "BAR", Expected: "ABAR", Sends: 1, End: ".", Consume: true }))
Test("prefix dead-key-chunk: a different body cannot borrow the whole chunk", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "?C", Trigger: "foo",
		Replacement: "BAR", Expected: "Afoo´.", Sends: 0, End: "", Prefix: "" }))
Test("prefix dead-key-chunk: STAR matches the complete physical suffix", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "*?C", Trigger: "foo´.",
		Replacement: "LONG", Expected: "ALONG", Sends: 1, End: "", ExtraEnd: true }))
Test("prefix dead-key-chunk: an interior STAR cannot erase already-visible trailing text", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "*?C", Trigger: "foo´",
		Replacement: "BAR", Expected: "Afoo´.", Sends: 0, End: "", Prefix: "" }))
Test("prefix dead-key-chunk: boundary followed by text starts a fresh preview", (*) =>
	_PCA_DeadKeyChunk({ Initial: "foo", Chunk: ".a", Flags: "", Trigger: "",
		Replacement: "", Expected: "foo.a", Sends: 0, End: "", Prefix: "a" }))
Test("prefix dead-key-chunk: supplementary completion remains one native key", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´" . Chr(0x1F600), Flags: "?C", Trigger: "foo´",
		Replacement: "BAR", Expected: "ABAR" . Chr(0x1F600), Sends: 1, End: Chr(0x1F600) }))
Test("prefix dead-key-chunk: time-gated STAR admits every scalar in the batch", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "´.", Flags: "*?C", Trigger: "foo´.",
		Replacement: "BAR", Expected: "ABAR", Sends: 1, End: "", Timed: true }))

Test("prefix dead-key-chunk: a distinct supplementary scalar is never half a delimiter", (*) =>
	_PCA_DeadKeyChunk({ Initial: "foo", Chunk: Chr(0x1F601), Flags: "", Trigger: "",
		Replacement: "", Expected: "foo" . Chr(0x1F601), Sends: 0, End: "", Prefix: "foo" . Chr(0x1F601) }))
Test("prefix dead-key-chunk: a boundary before a supplementary scalar keeps the full tail", (*) =>
	_PCA_DeadKeyChunk({ Initial: "foo", Chunk: "." . Chr(0x1F601), Flags: "", Trigger: "",
		Replacement: "", Expected: "foo." . Chr(0x1F601), Sends: 0, End: "", Prefix: Chr(0x1F601) }))

_UCAP_PrefixDecision(Capacity, Expected) {
	Effect := { ClearAll: false, KnownBoundaryAfter: false }
	Decision := _PrefixPostFireDecision(Effect, "A" . Chr(0x1F600) . "bc", Capacity)
	AssertEqual(Expected, Decision.Buffer, "post-fire preview is a complete contiguous suffix")
	AssertEqual(Expected == "", Decision.Reset)
	AssertEqual(Expected != "", Decision.Schedule)
}
Test("prefix unicode-context-cap: post-fire truncation preserves complete pairs", (*) =>
	_UCAP_PrefixDecision(3, "bc"))
Test("prefix unicode-context-cap: zero capacity clears and retires the preview", (*) =>
	_UCAP_PrefixDecision(0, ""))

_UCAP_PrefixTail() {
	global _MAX_BUFFER_LEN
	Saved := _MAX_BUFFER_LEN
	try {
		_MAX_BUFFER_LEN := 3
		AssertEqual("bc", _PrefixWordTail("A" . Chr(0x1F601) . "bc"),
			"the final word remains bounded without cutting a supplementary scalar")
	} finally {
		_MAX_BUFFER_LEN := Saved
	}
}
Test("prefix unicode-context-cap: final-word lookup keeps a pair-safe suffix", _UCAP_PrefixTail)

_UCAP_PrefixAppend() {
	global _MAX_BUFFER_LEN
	Saved := _MAX_BUFFER_LEN
	try {
		_MAX_BUFFER_LEN := 3
		_PCA_DeadKeyChunk({ Initial: "A" . Chr(0x1F601) . "b", Chunk: "c",
			Trigger: "", Flags: "", Replacement: "", Sends: 0, End: "",
			Expected: "A" . Chr(0x1F601) . "bc", Prefix: "bc" })
	} finally {
		_MAX_BUFFER_LEN := Saved
	}
}
Test("prefix unicode-context-cap: actual printable callback caps the native preview", _UCAP_PrefixAppend)

Test("prefix unicode-boundary-owner: replacement sharing only a low surrogate keeps its preview", (*) =>
	_PCA_DeadKeyChunk({ Initial: "Afoo", Chunk: "★", Flags: "*?C", Trigger: "foo★",
		Replacement: Chr(0x1FA00), Expected: "A" . Chr(0x1FA00), Sends: 1, End: "",
		Prefix: "A" . Chr(0x1FA00) }))
Test("prefix unicode-boundary-owner: STAR cannot use half of a configured delimiter", (*) =>
	_PCA_DeadKeyChunk({ Initial: Chr(0x1FA00) . "th", Chunk: "e", Flags: "*C", Trigger: "the",
		Replacement: "THE", Expected: Chr(0x1FA00) . "the", Sends: 0, End: "" }))
Test("prefix unicode-boundary-owner: END cannot use half of a configured delimiter", (*) =>
	_PCA_DeadKeyChunk({ Initial: Chr(0x1FA00) . "the", Chunk: ".", Flags: "C", Trigger: "the",
		Replacement: "THE", Expected: Chr(0x1FA00) . "the.", Sends: 0, End: "" }))
Test("prefix unicode-boundary-owner: the actual supplementary delimiter licenses STAR", (*) =>
	_PCA_DeadKeyChunk({ Initial: Chr(0x1F600) . "th", Chunk: "e", Flags: "*C", Trigger: "the",
		Replacement: "THE", Expected: Chr(0x1F600) . "THE", Sends: 1, End: "" }))
Test("prefix unicode-boundary-owner: the actual supplementary delimiter licenses END", (*) =>
	_PCA_DeadKeyChunk({ Initial: Chr(0x1F600) . "the", Chunk: ".", Flags: "C", Trigger: "the",
		Replacement: "THE", Expected: Chr(0x1F600) . "THE.", Sends: 1, End: "." }))

Test("prefix unicode-boundary-owner: repeat dispatch agrees with actual native Unicode output", (*) =>
	_PCA_DeadKeyChunk({ Initial: "a" . Chr(0x1F601), Chunk: "★", Magic: "★",
		Flags: "", Trigger: "", Replacement: "", Expected: "a" . Chr(0x1F601) . Chr(0x1F601),
		Sends: 1, End: "", Prefix: "a" . Chr(0x1F601) . Chr(0x1F601) }))
