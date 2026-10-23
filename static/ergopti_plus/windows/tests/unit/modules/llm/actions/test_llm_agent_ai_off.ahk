; tests/unit/modules/llm/actions/test_llm_agent_ai_off.ahk

; ==============================================================================
; MODULE: LLM Agent With the AI Menu Off
; DESCRIPTION:
; With the AI menu off the agent triages a typing pause without predicting,
; the typing feed follows the mode and the pause, a missing local model
; only offers manual recovery, and the tool cache honours its exact TTL.
; ==============================================================================

#Requires AutoHotkey v2.0





_LAG_WithBridgeOff(Body) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding, _LLM_Bridge_AgentFeedErrorTick
	Saved := {
		Active: _LLM_Bridge_Active, Buffer: _LLM_Bridge_Buffer, Generation: _LLM_Bridge_ContentGeneration,
		Agent: _LLM_Bridge_AgentBuffer, Feeding: _LLM_Bridge_AgentFeeding, ErrorTick: _LLM_Bridge_AgentFeedErrorTick
	}
	try {
		_LLM_Bridge_Active := false
		_LLM_Bridge_Buffer := "earlier prediction context"
		_LLM_Bridge_AgentBuffer := ""
		_LLM_Bridge_AgentFeeding := false
		Body.Call()
	} finally {
		_LLM_Bridge_Active := Saved.Active
		_LLM_Bridge_Buffer := Saved.Buffer
		_LLM_Bridge_ContentGeneration := Saved.Generation
		_LLM_Bridge_AgentBuffer := Saved.Agent
		_LLM_Bridge_AgentFeeding := Saved.Feeding
		_LLM_Bridge_AgentFeedErrorTick := Saved.ErrorTick
	}
}

; Types Text character by character through the bridge's PrefixWatcher entry
; point and returns the newest pause callback the agent armed, "" when none.
_LAG_TypeThroughBridge(Fx, Text) {
	global LLM_AGENT_LEARNING_SAVE_DELAY_MS
	Before := Fx.Scheduled.Length
	for Char in StrSplit(Text)
		LLM_Bridge_FeedCharIfActive(Char)
	Index := Fx.Scheduled.Length
	while (Index > Before) {
		Entry := Fx.Scheduled[Index]
		if (Entry["period"] < 0 && Entry["period"] != -LLM_AGENT_LEARNING_SAVE_DELAY_MS)
			return Entry["fn"]
		Index -= 1
	}
	return ""
}

; The prediction state the agent-only feed must leave alone.
; @returns {Map}
_LAG_PredictionSnapshot(Fx) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration, _LLM_Engine, _Stub_LlmTooltipCalls
	return Map("buffer", _LLM_Bridge_Buffer, "generation", _LLM_Bridge_ContentGeneration,
		"timer", _LLM_Engine.Get("timer_active", false) ? true : false,
		"last_buffer", _LLM_Engine.Get("last_buffer", ""),
		"requests", Fx.Predictions.Length, "tooltips", _Stub_LlmTooltipCalls.Length)
}

; Asserts that nothing of the predictions moved while the agent watched.
_LAG_AssertNoPrediction(Fx, Before) {
	After := _LAG_PredictionSnapshot(Fx)
	AssertEqual("earlier prediction context", After["buffer"], "the prediction context is untouched")
	AssertEqual(Before["generation"], After["generation"], "its content generation too")
	AssertEqual(Before["timer"], After["timer"], "no prediction timer is armed")
	AssertEqual(Before["last_buffer"], After["last_buffer"], "the engine saw no keystroke")
	AssertEqual(0, After["requests"], "no prediction is requested")
	AssertEqual(Before["tooltips"], After["tooltips"], "no prediction tooltip or spinner")
}

; The root cause: turning the AI menu off stops the prediction bridge, and the
; bridge used to drop every keystroke then, so the automatic mode never saw one.
_LAG_AutoWithAiOff() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		_LAG_WithBridgeOff(_Typing)
		_Typing() {
			global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
			Before := _LAG_PredictionSnapshot(Fx)
			Pause := _LAG_TypeThroughBridge(Fx, LAG_TYPED . "x")
			AssertTrue(HasMethod(Pause, "Call"), "with the AI off, typing arms the agent's pause")
			AssertTrue(_LLM_Bridge_AgentFeeding, "the bridge feeds the agent alone")
			AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "feeds the AI agent's typing observer only"),
				"which is logged once")
			; Backspace erases in the agent's context and re-arms the pause
			LLM_Bridge_FeedKeyDownIfActive(0x08, true)
			AssertEqual(LAG_TYPED, _LLM_Bridge_AgentBuffer, "Backspace erased the last character")
			AssertFalse(Pause.Call(), "the pause armed before the Backspace fires for nothing")
			Pause := Fx.Scheduled[Fx.Scheduled.Length]
			AssertTrue(Pause["period"] < 0, "the Backspace armed a new pause")
			AssertTrue(Pause["fn"].Call(), "the pause triages the sentence")
			AssertEqual(1, Fx.Remote.Length, "one System 1 request")
			AssertEqual(LAG_SELECTION, _LAG_Request(Fx.Remote[1])["user"], "on the current sentence")
			_LAG_AssertNoPrediction(Fx, Before)
			; An expansion the hotstring engine mirrors reaches the agent's context only
			PreviousCritical := Critical("On")
			try _HSE_MirrorCanonicalEffectToLlm({ DeleteFromEnd: 5, InsertedText: "contrat" })
			finally Critical(PreviousCritical)
			AssertEqual("Bonjour. On se voit jeudi 14h avec Paul pour le contrat", _LLM_Bridge_AgentBuffer,
				"the expansion reached the agent's context")
			_LAG_AssertNoPrediction(Fx, Before)
			; Enter starts a fresh context, as it flushes the prediction one
			LLM_Bridge_FeedKeyDownIfActive(0x0D, true)
			AssertEqual("", _LLM_Bridge_AgentBuffer, "Enter empties the agent's context")
		}
	}
}
Test("LLM agent: with the AI menu off, a typing pause is triaged and nothing predicts", _LAG_AutoWithAiOff)

_LAG_ActionModeWithAiOff() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras", false), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		TooltipHide("AgentTest", true)
		_LAG_WithBridgeOff(_Typing)
		_Typing() {
			global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
			Before := _LAG_PredictionSnapshot(Fx)
			AssertEqual("", _LAG_TypeThroughBridge(Fx, LAG_TYPED), "on action, typing arms nothing")
			AssertFalse(_LLM_Bridge_AgentFeeding, "the bridge feeds nothing")
			AssertEqual("", _LLM_Bridge_AgentBuffer, "and keeps no context")
			AssertEqual(0, Fx.Scheduled.Length, "no timer at all")
			AssertEqual(0, Fx.Remote.Length, "no triage")
			_LAG_AssertNoPrediction(Fx, Before)
		}
	}
}
Test("LLM agent: with the AI menu off, the agent on action watches no typing", _LAG_ActionModeWithAiOff)

_LAG_ModeChangesStopTheFeed() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		TooltipHide("AgentTest", true)
		_LAG_WithBridgeOff(_Typing)
		_Typing() {
			global _LLM_Menu, _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
			Old := _LAG_TypeThroughBridge(Fx, "Envoie le devis")
			AssertTrue(_LLM_Bridge_AgentFeeding, "precondition: the feed runs")
			AssertTrue(LLM_Agent_SetMode("off"), "the agent is turned off")
			AssertFalse(_LLM_Bridge_AgentFeeding, "which stops the feed")
			AssertEqual("", _LLM_Bridge_AgentBuffer, "and drops its context")
			AssertEqual(0, Fx.Scheduled[Fx.Scheduled.Length]["period"], "and cancels the armed pause")
			AssertFalse(Old.Call(), "which would fire for nothing")
			AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "stopped feeding the AI agent's typing observer"),
				"the stop is logged")
			AssertEqual("", _LAG_TypeThroughBridge(Fx, " à Paul"), "typing then arms nothing")
			AssertEqual("", _LLM_Bridge_AgentBuffer, "nor keeps any context")
			; The toggle back to auto starts it again on a fresh context
			AssertTrue(LLM_Agent_ToggleAuto(), "the toggle turns the automatic mode on")
			AssertTrue(HasMethod(_LAG_TypeThroughBridge(Fx, "Rappelle-moi"), "Call"), "typing arms it again")
			AssertEqual("Rappelle-moi", _LLM_Bridge_AgentBuffer, "from what was typed since")
			; And the toggle to on action stops it
			AssertTrue(LLM_Agent_ToggleAuto(), "the toggle turns it back to on action")
			AssertEqual("action", _LLM_Menu["agent_mode"], "on action")
			AssertFalse(_LLM_Bridge_AgentFeeding, "the feed is stopped")
			AssertEqual("", _LAG_TypeThroughBridge(Fx, " le garage"), "and typing arms nothing")
			AssertEqual(0, Fx.Remote.Length, "none of this triaged anything")
		}
	}
}
Test("LLM agent: leaving the automatic mode stops the typing feed, entering it starts it",
	_LAG_ModeChangesStopTheFeed)

_LAG_PauseStopsTheFeed() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		TooltipHide("AgentTest", true)
		AssertTrue(InStr(_DriverFuncBody("Ergopti_OnSuspendEnter"), '"llm-agent-typing", LLM_Agent_OnSuspend') > 0,
			"pausing runs the agent's typing step")
		_LAG_WithBridgeOff(_Typing)
		_Typing() {
			global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
			Old := _LAG_TypeThroughBridge(Fx, LAG_TYPED)
			AssertTrue(_LLM_Bridge_AgentFeeding, "precondition: the feed runs")
			Suspend(true)
			try {
				AssertTrue(LLM_Agent_OnSuspend(), "the pause step runs")
				AssertFalse(_LLM_Bridge_AgentFeeding, "the pause stops the feed")
				AssertEqual("", _LLM_Bridge_AgentBuffer, "and drops its context")
				AssertEqual("", _LAG_TypeThroughBridge(Fx, " demain"), "a keystroke while paused arms nothing")
				AssertFalse(_LLM_Bridge_AgentFeeding, "nor starts the feed")
			} finally {
				Suspend(false)
			}
			AssertFalse(Old.Call(), "the pause armed before it fires for nothing")
			AssertEqual(0, Fx.Remote.Length, "no triage")
			Pause := _LAG_TypeThroughBridge(Fx, "Envoie le devis à Paul demain")
			AssertTrue(HasMethod(Pause, "Call"), "after the resume, typing feeds the agent again")
			AssertEqual("Envoie le devis à Paul demain", _LLM_Bridge_AgentBuffer, "on a fresh context")
			AssertTrue(Pause.Call(), "and its pause triages")
			AssertEqual(1, Fx.Remote.Length, "one System 1 request")
		}
	}
}
Test("LLM agent: a pause stops the typing feed, the resume lets it start again", _LAG_PauseStopsTheFeed)


_LAG_MissingLocalModelOffersOnlyCurrentFlow() {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(LAG_SELECTION), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_LocalModelOfferPort, LLM_OLLAMA_BASE_URL, _LLM_Agent_Generation
		Saved := _LLM_LocalModelOfferPort
		Offers := []
		try {
			_LLM_LocalModelOfferPort := Map("confirm", (Title, Text) => (Offers.Push(Text), false))
			AssertTrue(_LAG_Invoke("llm_agent_selection"), "the real action starts a local manual agent flow")
			AssertEqual(1, Fx.Ollama.Length)
			Request := Fx.Ollama[1]
			Model := JsonParse(Request["body"])["model"]
			Request["on_fail"].Call(LLM_LocalModelFailure(Model, LLM_OLLAMA_BASE_URL))
			AssertEqual(1, Offers.Length, "a current manual failure offers a download rather than a bare 404")
			AssertContains(Offers[1], Model, "the consent names the exact requested model")
			_LLM_Agent_Generation += 1
			Request["on_fail"].Call(LLM_LocalModelFailure(Model, LLM_OLLAMA_BASE_URL))
			AssertEqual(1, Offers.Length, "a superseded flow cannot open another prompt")
			AssertEqual(0, Sent.Length, "a missing model never injects an action")
		} finally _LLM_LocalModelOfferPort := Saved
	}
}
Test("LLM agent: missing local model offers explicit manual recovery only for current flow (todo-46-local-model)",
	_LAG_MissingLocalModelOffersOnlyCurrentFlow)

_LAG_AutomaticMissingModelNotifiesWithoutModal() {
	_LAG_Run(_LAG_Menu("auto", "local", "local"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, LLM_OLLAMA_BASE_URL
		Saved := Map("port", _LLM_LocalModelOfferPort, "notified", _LLM_LocalModelNotified)
		State := Map("notices", 0, "confirms", 0, "downloads", 0)
		try {
			_LLM_LocalModelNotified := Map()
			_LLM_LocalModelOfferPort := Map("notify", (*) => (State["notices"] += 1, true),
				"confirm", (*) => (State["confirms"] += 1, true), "install", (*) => (State["downloads"] += 1, true))
			Fx.App := "Slack"
			TooltipHide("AgentTest", true)
			Pause := _LAG_Type(Fx, LAG_TYPED)
			AssertTrue(Pause.Call(), "the actual typing pause starts local System 1")
			AssertEqual(1, Fx.Ollama.Length)
			Model := JsonParse(Fx.Ollama[1]["body"])["model"]
			Fx.Ollama[1]["on_fail"].Call(LLM_LocalModelFailure(Model, LLM_OLLAMA_BASE_URL))
			AssertEqual(1, State["notices"], "current automatic triage reports its missing model")
			AssertEqual(0, State["confirms"], "typing must not open a modal")
			AssertEqual(0, State["downloads"], "typing cannot download without consent")
			AssertEqual(1, Fx.Ollama.Length, "a failed triage cannot wake System 2")
		} finally {
			_LLM_LocalModelOfferPort := Saved["port"]
			_LLM_LocalModelNotified := Saved["notified"]
		}
	}
}
Test("LLM agent: actual automatic local triage missing-model notice has no modal or pull (todo-46-local-model)",
	_LAG_AutomaticMissingModelNotifiesWithoutModal)
/** A native Backspace and its AI admission must erase the same complete scalar. */
_LAG_UnicodePhysicalBackspace(Active) {
	Menu := _LAG_Menu(Active ? "off" : "auto", "cerebras", "cerebras", false)
	_LAG_Run(Menu, _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		_Typing() {
			global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer, _LLM_Engine
			Before := _LAG_PredictionSnapshot(Fx)
			SavedEnabled := _LLM_Engine["enabled"]
			Window := Gui()
			EditControl := Window.AddEdit(, "A" . Chr(0x1F600))
			Window.Show("Hide")
			SendMessage(0x00B1, StrLen(EditControl.Value), StrLen(EditControl.Value), EditControl)
			try {
				_LLM_Bridge_Active := Active
				if Active
					_LLM_Bridge_ClearBuffer()
				_LLM_Engine["enabled"] := false
				LLM_Bridge_FeedCharIfActive("A")
				LLM_Bridge_FeedCharIfActive(Chr(0x1F600))
				ControlSend("{BackSpace}", EditControl)
				LLM_Bridge_FeedKeyDownIfActive(0x08, true)
				Sleep(30)
				AssertEqual("A", EditControl.Value, "one native Backspace removes the complete surrogate pair")
				Actual := Active ? _LLM_Bridge_Buffer : _LLM_Bridge_AgentBuffer
				AssertEqual(EditControl.Value, Actual, "the AI must see the exact document after physical erasure")
				AssertEqual(0, Fx.Remote.Length, "no actual or simulated remote request runs")
				if !Active
					_LAG_AssertNoPrediction(Fx, Before)
			} finally {
				Window.Destroy()
				_LLM_Engine["enabled"] := SavedEnabled
			}
		}
		_LAG_WithBridgeOff(_Typing)
	}
}
Test("LLM agent: active prediction context matches native Unicode Backspace (unicode-erase)",
	_LAG_UnicodePhysicalBackspace.Bind(true))
Test("LLM agent: agent-only context matches native Unicode Backspace (unicode-erase)",
	_LAG_UnicodePhysicalBackspace.Bind(false))


/** Cache lifetime applies to actual enumerated tools across unsigned tick wrap. */
_LAG_ToolsCacheLifetime(StartTick) {
	_LAG_RunConnectors("", _Body)
	_Body(Fx) {
		global _LLM_AgentConnector_ListFn, LLM_AGENT_TOOLS_TTL_MS
		State := { Reads: 0, Files: ["C:\tools\old.ps1"] }
		List(Dir) {
			State.Reads += 1
			return State.Files.Clone()
		}
		_LLM_AgentConnector_ListFn := List
		Config := LLM_Agent_Config()
		Initial := LLM_AgentConnector_Tools(Config, true, StartTick)
		AssertEqual(1, State.Reads, "initial force actually enumerates the folder")
		AssertEqual("old", Initial["names"][1])
		State.Files := ["C:\tools\new.cmd"]
		Before := (StartTick + LLM_AGENT_TOOLS_TTL_MS - 1) & 0xFFFFFFFF
		Cached := LLM_AgentConnector_Tools(Config, false, Before)
		AssertEqual(1, State.Reads, "strictly before expiry the cache is reused")
		AssertEqual(ObjPtr(Initial), ObjPtr(Cached), "reuse retains the same cache owner")
		Now := (StartTick + LLM_AGENT_TOOLS_TTL_MS) & 0xFFFFFFFF
		Refreshed := LLM_AgentConnector_Tools(Config, false, Now)
		AssertEqual(2, State.Reads, "at the exact TTL the folder must be enumerated again")
		AssertEqual("new", Refreshed["names"][1], "removed tools disappear from the prompt list")
		AssertFalse(Refreshed["paths"].Has("old"), "removed tools cannot remain executable")
		AssertEqual("C:\tools\new.cmd", Refreshed["paths"]["new"])
		AssertEqual(Now, Refreshed["tick"], "the admitted snapshot uses the same clock observation")
		State.Files := ["C:\tools\forced.ahk"]
		Forced := LLM_AgentConnector_Tools(Config, true, Now)
		AssertEqual(3, State.Reads, "explicit force still bypasses a fresh cache")
		AssertEqual("forced", Forced["names"][1])
	}
}
Test("LLM agent: tool cache expires at its exact ordinary TTL (tools-cache-wrap)",
	_LAG_ToolsCacheLifetime.Bind(100))
Test("LLM agent: tool cache expires across tick wrap (tools-cache-wrap)",
	_LAG_ToolsCacheLifetime.Bind(0xFFFFFFF0))

#Include test_llm_agent_tools_native64_ttl.ahk
