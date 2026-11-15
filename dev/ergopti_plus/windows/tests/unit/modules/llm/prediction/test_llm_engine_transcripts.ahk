; tests/unit/modules/llm/prediction/test_llm_engine_transcripts.ahk

; ==============================================================================
; MODULE: Shared Engine Transcripts (Windows)
; DESCRIPTION:
; Runs the real Windows prediction engine on recording fakes of its three ports
; (TimerScheduler, HttpClient, TooltipRenderer: modules/llm/prediction_ports.ahk)
; and compares the port calls with the shared corpus
; _shared/tests/corpus/llm/request_plan_engine_transcripts.json, which the macOS
; and Linux engines replay too. The live-mode fixture of test_llm_live_mode.ahk
; provides the menu, the bridge and the notices; the engine runs on the shared
; defaults with the scenario's menu settings over them.
;
; FEATURES & RATIONALE:
; 1. The same events in, the same port calls out: a keystroke is the engine's
;    LLM_Engine_OnKeystroke, time passes on the fake timer, the provider's answer
;    goes through the real response classifier, live mode is the bound action.
; 2. Only the corpus' watched delays are recorded, so the engine's own deferrals
;    stay out; the HTTP fake records the max_tokens of the real wire payload; a
;    tooltip paint that repeats the previous one is recorded once (corpus
;    difference "repaint").
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ The fake ports =======
; =================================
; =================================

; A virtual clock: After arms, Elapse runs what falls due, in due order.
class _LET_Timer {
	__New(Log, Watched) {
		this.Log := Log
		this.Watched := Watched
		this.NowMs := 0
		this.Pending := []
	}

	After(Callback, DelayMs) {
		; SetTimer's rule: arming the same callback again replaces its firing
		this.Cancel(Callback)
		if this.Watched.Has(DelayMs)
			this.Log.Push("timer.after " . DelayMs)
		this.Pending.Push({ Callback: Callback, Due: this.NowMs + DelayMs })
	}

	Cancel(Callback) {
		Index := this.Pending.Length
		while (Index >= 1) {
			if (ObjPtr(this.Pending[Index].Callback) == ObjPtr(Callback))
				this.Pending.RemoveAt(Index)
			Index -= 1
		}
	}

	Elapse(Ms) {
		Target := this.NowMs + Ms
		loop {
			Next := 0
			for Index, Entry in this.Pending {
				if (Entry.Due <= Target && (!Next || Entry.Due < this.Pending[Next].Due))
					Next := Index
			}
			if !Next
				break
			Entry := this.Pending.RemoveAt(Next)
			this.NowMs := Entry.Due
			Entry.Callback.Call()
		}
		this.NowMs := Target
	}
}

; Records each inference request by the max_tokens its real wire payload carries.
class _LET_Http {
	__New(Log) {
		this.Log := Log
		this.Posts := []
	}

	Post(Entry, SystemPrompt, Context, Temperature, OnSuccess, OnFail, Tail := "",
			MaxTokens := "", Kind := "", TimeoutMs := 0, CurrentFn := 0) {
		; The real transport refuses a requester that is no longer current
		if !_LLMRemote_RequesterCurrent(CurrentFn)
			return 0
		Resolved := _LLMRemoteResolveEntry(Entry)
		AssertTrue(Resolved is Map, "the scenario's API entry resolves")
		Request := _LLMRemote_BuildRequestContext(SystemPrompt, Context, Tail)
		Payload := _LLMRemoteBuildPayload(Resolved["Format"], Resolved["Model"], Request["system"],
			Request["user"], Temperature, MaxTokens)
		this.Log.Push("http.post " . JsonParse(Payload)["max_tokens"])
		this.Posts.Push(Map("resolved", Resolved, "on_success", OnSuccess, "on_fail", OnFail))
		return this.Posts.Length
	}

	Cancel(SpareKind := "") {
		return true
	}

	; The provider answers request Index with Text, through the real classifier
	Answer(Index, Text) {
		AssertTrue(this.Posts.Length >= Index, "request " . Index . " was sent")
		Post := this.Posts[Index]
		Body := '{"id":"chatcmpl-1","object":"chat.completion","model":' . JsonStringLiteral(Post["resolved"]["Model"])
			. ',"choices":[{"index":0,"message":{"role":"assistant","content":'
			. JsonStringLiteral(Text) . '},"finish_reason":"stop"}],'
			. '"usage":{"prompt_tokens":40,"completion_tokens":9,"total_tokens":49}}'
		Classified := _LLMRemoteClassifyResponse(Post["resolved"]["Format"], Body, Post["resolved"]["Model"])
		AssertTrue(Classified["ok"], "the provider answer classifies as a completion")
		Post["on_success"].Call(Classified["text"], Classified["usage"])
	}
}

; Records each paint that is not a loading placeholder: the candidates and the
; info bar pieces of the display options set before it.
class _LET_Tooltip {
	__New(Log) {
		this.Log := Log
		this.InfoParts := []
		this.Visible := false
		this.Loading := false
		this.Token := 0
		this.LastPaint := ""
	}

	SetDisplayOpts(Opts) {
		this.InfoParts := Opts["info_parts"]
	}

	Show(Slots, Active, IsFinal, Meta) {
		Info := ""
		for Part in this.InfoParts
			Info .= (A_Index == 1 ? "" : " | ") . Part
		Texts := ""
		for Slot in Slots
			Texts .= "`n" . (IsObject(Slot) ? Slot.Text : Slot)
		Entry := "tooltip.show " . Slots.Length . " [" . Info . "]"
		if (Entry . Texts != this.LastPaint)
			this.Log.Push(Entry)
		this.LastPaint := Entry . Texts
		this.Visible := true, this.Loading := false
		this.Token := { Slots: Slots }
		return 1
	}

	ShowLoading(Meta) {
		this.Visible := true, this.Loading := true
		this.Token := { Slots: [] }
		this.LastPaint := ""
	}

	IsVisible() {
		return this.Visible
	}

	IsLoading() {
		return this.Loading
	}

	PresentedToken() {
		return this.Token
	}

	Hide(Token) {
		if (ObjPtr(Token) != ObjPtr(this.Token))
			return false
		this.Visible := false, this.Loading := false
		this.Token := 0
		this.LastPaint := ""
		return true
	}

	MarkChainStart() {
	}

	MarkChainTiming(NowTick) {
	}
}





; ============================
; ============================
; ======= 2/ The world =======
; ============================
; ============================

_LET_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\request_plan_engine_transcripts.json", "UTF-8"))
}

; The shared Cerebras entry, with the model its provider defaults to
_LET_Entry() {
	return Map("Id", "cerebras-1", "Provider", "cerebras", "Label", "Cerebras", "Token", "k")
}

_LET_UserProfiles(Config) {
	if !Config.Has("user_prompt")
		return []
	Prompt := Config["user_prompt"]
	return [Map("id", Prompt["id"], "label", Prompt["label"],
		"system_single", Prompt["system_single"], "batch", false)]
}

_LET_Menu(Config) {
	Menu := _LPP_Menu()
	Menu["api_entries"] := [_LET_Entry()]
	Menu["api_entry_id"] := "cerebras-1"
	Menu["profile_id"] := Config["profile"]
	Menu["n_predictions"] := Config["count"]
	Menu["user_profiles"] := _LET_UserProfiles(Config)
	return Menu
}

; What a world offers the scenario steps
class _LET_World {
	__New(Timer, Http, Tooltip, Log) {
		this.Timer := Timer
		this.Http := Http
		this.Tooltip := Tooltip
		this.Log := Log
		this.Buffer := ""
	}

	Keystroke(Text) {
		global _LLM_Bridge_Buffer
		this.Buffer := Text
		_LLM_Bridge_Buffer := Text
		LLM_Engine_OnKeystroke(Text, "", 0, , Map("hwnd", 101, "control", 102))
	}

	Elapse(Ms) {
		this.Timer.Elapse(Ms)
	}

	Answer(Index, Text) {
		this.Http.Answer(Index, Text)
	}

	ToggleLive(Value) {
		return _LLV_Toggle(Value)
	}

	; The menu commits the deletion and applies it to the engine
	DeletePrompt(Id) {
		global _LLM_Menu
		Remaining := []
		for Profile in _LLM_Menu["user_profiles"] {
			if (Profile["id"] != Id)
				Remaining.Push(Profile)
		}
		AssertTrue(Remaining.Length < _LLM_Menu["user_profiles"].Length, "the prompt existed")
		_LLM_Menu["user_profiles"] := Remaining
		LLM_Engine_Init(Map("user_profiles", Remaining))
	}
}

/**
 * Runs Body(World) on the real engine with the three ports faked, the
 * scenario's menu settings over the shared defaults, then puts everything back.
 * @param {Map} Config The scenario's config.
 * @param {Func} Body Receives the world.
 */
_LET_WithWorld(Config, Body) {
	_LLV_Run("", _Inner, _LET_Menu(Config))
	_Inner(Calls, Lines, Builds) {
		global _LLM_Engine, LLM_Defaults
		LLM_Defaults_Load()
		Settings := Map(
			"api_entries", [_LET_Entry()], "api_entry_id", "cerebras-1",
			"profile_id", Config["profile"], "n_predictions", Config["count"],
			"user_profiles", _LET_UserProfiles(Config), "debounce_ms", Config["debounce_ms"],
			"min_words", LLM_Defaults["llm_min_words"], "max_words", LLM_Defaults["llm_max_words"],
			"show_info_bar", LLM_Defaults["llm_show_info_bar"],
			"show_all_at_once", LLM_DisplayShowAll(LLM_Defaults["llm_streaming_multi"]))
		for Key, Value in Settings
			_LLM_Engine[Key] := Value
		Watched := Map()
		for Ms in Config["watch_timers_ms"]
			Watched[Ms] := true
		Log := []
		World := _LET_World(_LET_Timer(Log, Watched), _LET_Http(Log), _LET_Tooltip(Log), Log)
		Saved := []
		try {
			Saved.Push(["timer", LLM_Engine_SetPort("timer", World.Timer)])
			Saved.Push(["http", LLM_Engine_SetPort("http", World.Http)])
			Saved.Push(["tooltip", LLM_Engine_SetPort("tooltip", World.Tooltip)])
			Body(World)
		} finally {
			try {
				LLM_Engine_LiveStop("scenario end")
				LLM_Engine_StopGeneration()
			} finally {
				Index := Saved.Length
				while (Index >= 1) {
					LLM_Engine_SetPort(Saved[Index][1], Saved[Index][2])
					Index -= 1
				}
			}
		}
	}
}





; =======================================
; =======================================
; ======= 3/ The corpus scenarios =======
; =======================================
; =======================================

; The corpus' expected calls in the recorded form, its symbols resolved.
_LET_Expected(Expected, Buffer) {
	global _LLM_Engine, LLM_API_PROVIDERS
	Calls := []
	for Call in Expected {
		Port := Call["port"]
		if (Port == "timer") {
			Calls.Push("timer.after " . Call["delay_ms"])
		} else if (Port == "http") {
			Symbol := Call["max_tokens"]
			Base := Integer(PromptBuilder().Build(Buffer, Map("max_words", _LLM_Engine["max_words"]))["max_tokens"])
			if (Symbol == "base")
				Tokens := Base
			else if (Symbol == "rewrite")
				Tokens := LLM_Rewrite_MaxTokens(Buffer)
			else if RegExMatch(Symbol, "^batch:(\d+)$", &Batch)
				Tokens := _LLM_Engine_CallTokenBudget(Base, Integer(Batch[1]))
			else
				throw ValueError("Unknown token symbol in the corpus: " . Symbol)
			Calls.Push("http.post " . Tokens)
		} else if (Port == "tooltip") {
			Info := ""
			for Part in Call["info"] {
				if (Part == "$model")
					Part := LLM_API_PROVIDERS["cerebras"]["DefaultModel"]
				else if RegExMatch(Part, "^\$profile:(.+)$", &Profile)
					Part := _LLM_Engine_TrimProfileLabel(LLM_Menu_GetProfileLabel(Profile[1]))
				Info .= (A_Index == 1 ? "" : " | ") . Part
			}
			Calls.Push("tooltip.show " . Call["candidates"] . " [" . Info . "]")
		} else
			throw ValueError("Unknown port in the corpus: " . Port)
	}
	return Calls
}

_LET_Join(Calls) {
	Text := ""
	for Call in Calls
		Text .= (A_Index == 1 ? "" : "; ") . Call
	return Text
}

_LET_ReplayScenario(Scenario) {
	_LET_WithWorld(Scenario["config"], _Body)
	_Body(World) {
		for Step in Scenario["steps"] {
			if Step.Has("keystroke")
				World.Keystroke(Step["keystroke"])
			else if Step.Has("elapse_ms")
				World.Elapse(Step["elapse_ms"])
			else if Step.Has("answer")
				World.Answer(Step["answer"]["request"], Step["answer"]["text"])
			else if Step.Has("toggle_live")
				AssertTrue(World.ToggleLive(Step["toggle_live"]), "live mode turns on")
			else if Step.Has("delete_prompt")
				World.DeletePrompt(Step["delete_prompt"])
			else
				throw ValueError("Unknown step in scenario " . Scenario["id"])
		}
		AssertEqual(_LET_Join(_LET_Expected(Scenario["expect"], World.Buffer)), _LET_Join(World.Log),
			"port calls of " . Scenario["id"])
	}
}

_LET_CorpusHoldsScenarios() {
	AssertTrue(_LET_Corpus()["scenarios"].Length >= 4, "the corpus holds its four scenarios")
}
Test("LLM engine transcripts: the shared corpus holds its scenarios (par-58)", _LET_CorpusHoldsScenarios)

for _LET_Scenario in _LET_Corpus()["scenarios"]
	Test("LLM engine transcripts: scenario '" . _LET_Scenario["id"] . "' (par-58)",
		_LET_ReplayScenario.Bind(_LET_Scenario))





; =====================================
; =====================================
; ======= 4/ The port contracts =======
; =====================================
; =====================================

class _LET_TimerWithoutCancel {
	After(Callback, DelayMs) {
	}
}

class _LET_HttpWithoutCancel {
	Post(Args*) {
	}
}

class _LET_TooltipWithoutHide {
	SetDisplayOpts(Opts) {
	}

	Show(Slots, Active, IsFinal, Meta) {
	}

	ShowLoading(Meta) {
	}

	IsVisible() {
	}

	IsLoading() {
	}

	PresentedToken() {
	}

	MarkChainStart() {
	}

	MarkChainTiming(NowTick) {
	}
}

_LET_PortsAreChecked() {
	Owners := Map(
		"timer", [_LET_TimerWithoutCancel(), "TimerScheduler lacks: Cancel"],
		"http", [_LET_HttpWithoutCancel(), "HttpClient lacks: Cancel"],
		"tooltip", [_LET_TooltipWithoutHide(), "TooltipRenderer lacks: Hide"])
	for Name, Pair in Owners {
		Message := ""
		try LLM_Engine_SetPort(Name, Pair[1])
		catch as Err
			Message := Err.Message
		AssertEqual(Pair[2], Message, "an incomplete " . Name . " port is refused, naming the missing method")
		AssertEqual(ObjPtr(LLM_ENGINE_DEFAULT_PORTS[Name]), ObjPtr(_LLM_Engine_Port(Name)),
			"the refused " . Name . " owner is not installed")
	}
	AssertThrows(() => LLM_Engine_SetPort("clock", 0), "an unknown port is refused")
}
Test("LLM engine transcripts: the engine checks its three ports, naming the missing method (par-58)",
	_LET_PortsAreChecked)

_LET_PortInstallIsRestored() {
	Owner := _LET_Timer([], Map())
	AssertEqual(0, LLM_Engine_SetPort("timer", Owner), "production runs on the default timer")
	AssertEqual(ObjPtr(Owner), ObjPtr(_LLM_Engine_Port("timer")), "the installed owner answers")
	AssertEqual(ObjPtr(Owner), ObjPtr(LLM_Engine_SetPort("timer", 0)), "0 hands the installed owner back")
	AssertEqual(ObjPtr(LLM_ENGINE_DEFAULT_PORTS["timer"]), ObjPtr(_LLM_Engine_Port("timer")),
		"and puts the default back")
}
Test("LLM engine transcripts: an installed port is handed back and the default restored (par-58)",
	_LET_PortInstallIsRestored)
