; static/ergopti_plus/windows/tests/unit/test_llm_agent.ahk

; ==============================================================================
; MODULE: AI Agent (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/agent_vectors.json, which the shared Lua
; module (macOS, Linux) replays too, through modules/llm/agent.ahk. Then drives
; the agent through the real code path with only the outer boundaries faked:
; the selection reader, the command dialog, the API transport, the clock and
; the focused application, the connectors' COM, file and process calls, the
; timer and the local state store.
;
; On action: a selection or a command -> one System 2 request -> one candidate
; per valid action -> accepting one runs its connector. Automatic: a typing pause
; -> one System 1 triage -> System 2 above the threshold. Learning: accepting or
; dismissing an automatic suggestion moves the threshold of its intent in its
; application, persisted in the local state store.
;
; The selection fixture is test_llm_tone.ahk's (_LTN_Screen, _LTN_Run); the
; network, keyboard and log fixtures are test_llm_prompt_prediction.ahk's; the
; structural JSON comparison is test_llm_vision.ahk's (_LVS_DeepEqual).
;
; ROOT CAUSE ENCODED:
; Turning a sentence into a calendar entry, a reminder or a mail meant leaving
; the text, opening the application and copying it over. The agent proposes
; the action and carries it out on the user's acceptance, and nothing a model
; writes runs without validation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Shared corpus (agent_vectors) =======
; ================================================
; ================================================

_LAG_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\agent_vectors.json"
	AssertTrue(FileExist(Path) != "", "the agent corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Asserts a triage against its vector: {"absent": true} means none.
_LAG_AssertTriage(Expected, Actual, Id) {
	if Expected.Get("absent", false) {
		AssertEqual("", Actual, Id . ": nothing readable")
		return
	}
	AssertTrue(Actual is Map, Id . ": a triage")
	AssertEqual(Expected["intent"], Actual["intent"], Id . ": intent")
	AssertTrue(Expected["probability"] == Actual["probability"], Id . ": probability")
}

_LAG_PromptVectors() {
	Config := LLM_Agent_Config()
	Corpus := _LAG_Corpus()
	Checked := 0
	for Vector in Corpus["system1_prompt"] {
		AssertEqual(Vector["prompt"], LLM_Agent_System1Prompt(Config, Vector["ctx"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["system2_prompt"] {
		AssertEqual(Vector["prompt"], LLM_Agent_System2Prompt(Config, Vector["ctx"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["system2_user_text"] {
		AssertEqual(Vector["user_text"], LLM_Agent_System2UserText(Config, Vector["text"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 prompt vectors, found " . Checked)
	AssertThrows(() => LLM_Agent_System2Prompt(Config, Map("source", "dream")), "an unknown source is refused")
}
Test("LLM agent: the prompts replay the shared corpus", _LAG_PromptVectors)

_LAG_TriageVectors() {
	Config := LLM_Agent_Config()
	Corpus := _LAG_Corpus()
	Checked := 0
	for Vector in Corpus["system1_answers"] {
		_LAG_AssertTriage(Vector["triage"], LLM_Agent_ParseSystem1(Config, Vector["raw"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["jev_answers"] {
		_LAG_AssertTriage(Vector["triage"], LLM_Agent_ParseJev(Config, Vector["response"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["jev_questions"] {
		AssertEqual("", _LVS_DeepEqual(Vector["questions"], LLM_Agent_JevQuestions(Config)), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["should_act"] {
		AssertEqual(Vector["act"] ? true : false, LLM_Agent_ShouldAct(Vector["triage"], Vector["threshold"]) ? true : false,
			Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 17, "expected at least 17 triage vectors, found " . Checked)
	AssertFalse(LLM_Agent_ShouldAct("", 0.1), "no triage never acts")
}
Test("LLM agent: the triage replays the shared corpus", _LAG_TriageVectors)

_LAG_DatetimeVectors() {
	Corpus := _LAG_Corpus()
	Checked := 0
	Invalid := 0
	for Vector in Corpus["datetimes"] {
		Minutes := LLM_Agent_ParseDatetime(Vector["text"])
		if Vector["expected"]["valid"] {
			AssertTrue(Minutes is Integer, Vector["id"] . ": valid")
			AssertEqual(Vector["expected"]["round_trip"], LLM_Agent_FormatDatetime(Minutes), Vector["id"] . ": round trip")
		} else {
			AssertEqual("", Minutes, Vector["id"] . ": refused")
			Invalid += 1
		}
		Checked += 1
	}
	for Vector in Corpus["datetime_add"] {
		AssertEqual(Vector["result"],
			LLM_Agent_FormatDatetime(LLM_Agent_ParseDatetime(Vector["text"]) + Vector["minutes"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 10 && Invalid >= 6, "the date vectors, invalid ones included, are replayed")
	AssertEqual(0, LLM_Agent_OleDate("1899-12-30T00:00"), "the OLE automation epoch is day 0")
	AssertEqual(2.5, LLM_Agent_OleDate("1900-01-01T12:00"), "noon is half a day")
	AssertEqual(25569, LLM_Agent_OleDate("1970-01-01T00:00"), "1970-01-01 is day 25569")
}
Test("LLM agent: local dates replay the shared corpus", _LAG_DatetimeVectors)

_LAG_ActionVectors() {
	Config := LLM_Agent_Config()
	Corpus := _LAG_Corpus()
	Checked := 0
	Refused := 0
	for Vector in Corpus["actions"] {
		Expected := Vector["expected"]
		Actions := LLM_Agent_ParseActions(Config, Vector["raw"], Corpus["tools"], &Rejected)
		if !Expected["readable"] {
			AssertEqual("", Actions, Vector["id"] . ": unreadable")
		} else {
			AssertTrue(Actions is Array, Vector["id"] . ": readable")
			AssertEqual("", _LVS_DeepEqual(Expected["actions"], Actions), Vector["id"] . ": actions")
			AssertEqual(Expected["rejected"], Rejected.Length, Vector["id"] . ": refused actions")
			Refused += Rejected.Length
		}
		Checked += 1
	}
	AssertTrue(Checked >= 10 && Refused >= 7, "the action vectors, refused ones included, are replayed")
}
Test("LLM agent: System 2's actions replay the shared corpus", _LAG_ActionVectors)

_LAG_PayloadVectors() {
	Config := LLM_Agent_Config()
	Corpus := _LAG_Corpus()
	Checked := 0
	for Vector in Corpus["labels"] {
		Label := LLM_Agent_Label(Vector["action"])
		AssertEqual(Vector["expected"]["key"], Label["key"], Vector["id"] . ": key")
		AssertEqual("", _LVS_DeepEqual(Vector["expected"]["args"], Label["args"]), Vector["id"] . ": args")
		Checked += 1
	}
	for Vector in Corpus["ics"] {
		AssertEqual(Vector["ics"], LLM_Agent_Ics(Config, Vector["action"], Vector["uid"], Vector["stamp"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["mailto"] {
		AssertEqual(Vector["url"], LLM_Agent_Mailto(Vector["action"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["applescript"] {
		AssertEqual(Vector["literal"], LLM_Agent_AppleScriptString(Vector["text"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["learn"] {
		AssertTrue(Vector["threshold_after"] == LLM_Agent_Learn(Config, Vector["threshold"], Vector["accepted"]),
			Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["resolve_model"] {
		Model := LLM_Agent_ResolveModel(LLM_Vision_Parse(Vector["value"]), Config, LLM_API_PROVIDERS)
		AssertEqual(Vector["expected"].Get("model", ""), Model, Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 24, "expected at least 24 label, payload, learning and model vectors, found " . Checked)
}
Test("LLM agent: labels, payloads, learning and models replay the shared corpus", _LAG_PayloadVectors)

_LAG_ShippedConfig() {
	Config := LLM_Agent_Config()
	AssertContains(Config["system2"]["prompt"], Config["system2"]["tag"], "the System 2 prompt asks for the tag")
	Broken := Map()
	for Key, Value in Config
		Broken[Key] := Value
	Broken["max_tools"] := 0
	AssertThrows(() => _LLM_Agent_ValidateConfig(Broken, "agent.json"), "a zero tool cap is refused")
	Broken["max_tools"] := Config["max_tools"]
	Broken.Delete("learning")
	AssertThrows(() => _LLM_Agent_ValidateConfig(Broken, "agent.json"), "a missing learning block is refused")
}
Test("LLM agent: agent.json holds what the agent needs", _LAG_ShippedConfig)





; ================================================
; ================================================
; ======= 2/ Settings and the tray submenu =======
; ================================================
; ================================================

_LAG_SettingsRoundTrip() {
	global Features
	Saved := Features
	try {
		AssertEqual("off", ManifestDefaultFor("llm.agent_mode"), "the agent is off by default")
		MenuState := _LLMST_Menu()
		MenuState["agent_system1"] := "local"
		MenuState["agent_system2"] := "cerebras|llama-3.3-70b"
		MenuState["agent_mode"] := "auto"
		MenuState["agent_disabled_apps"] := ["Slack.exe", " slack.exe "]
		Candidate := _LLMST_Features(true, "m", "ollama")
		AssertTrue(_LLM_Menu_SyncToFeatures(Candidate, MenuState), "the agent settings reach Features")
		Llm := Candidate["llm"]
		AssertEqual("local", Llm["agent_system1"], "System 1")
		AssertEqual("cerebras|llama-3.3-70b", Llm["agent_system2"], "System 2 with its model")
		AssertEqual("auto", Llm["agent_mode"], "the mode")
		AssertEqual("", _LVS_DeepEqual(["slack.exe"], Llm["agent_disabled_apps"]), "the apps, normalized")
		Features := Candidate
		Opts := LLM_Menu_BuildSavedOpts()
		for Key in ["agent_system1", "agent_system2", "agent_mode"]
			AssertEqual(Llm[Key], Opts[Key], Key . " comes back from Features")
		AssertEqual("", _LVS_DeepEqual(["slack.exe"], Opts["agent_disabled_apps"]), "the apps come back")
		MenuState["agent_mode"] := "sometimes"
		AssertFalse(_LLM_Menu_SyncToFeatures(_LLMST_Features(true, "m", "ollama"), MenuState),
			"an unknown mode is refused")
		AssertFalse(LLM_Option_TryNormalize("agent_mode", "AUTO", &Normalized), "modes compare exactly")
		AssertFalse(LLM_Option_TryNormalize("agent_disabled_apps", "slack", &Normalized), "the apps are a list")
	} finally {
		Features := Saved
	}
}
Test("LLM agent: the agent settings round-trip through Features", _LAG_SettingsRoundTrip)

; A committer standing in for LLM_Menu_CommitMutation: the candidate mutation
; is applied to the live menu state, then the live tail runs.
_LAG_FakeCommit(Fx, Context, MutateFn, ApplyFn) {
	global _LLM_Menu
	Candidate := LLM_Menu_DeepClone(_LLM_Menu)
	if !MutateFn.Call(Candidate)
		return false
	_LLM_Menu := Candidate
	Fx.Commits.Push(Context)
	return ApplyFn.Call(Candidate)
}

_LAG_SystemRows() {
	_LAG_Run(_LAG_Menu("action", "", "cerebras|llama-3.3-70b"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		Row := _LLM_Agent_SystemRow("agent_system2")
		AssertEqual(StrReplace(t("menu.agent.system2"), "{1}", "Cerebras"), Row["label"], "the current backend")
		Items := Row["items"]
		Choices := LLM_Vision_BackendChoices()
		AssertEqual(Choices.Length + 3, Items.Length, "off, every backend, a separator and the model")
		AssertEqual(t("menu.agent.off"), Items[1]["label"], "off first")
		AssertFalse(Items[1]["checked"], "unchecked")
		AssertEqual("local — " . t("llm.vision.local_backend"), Items[2]["label"], "then the local server")
		Checked := 0
		for Index, Choice in Choices {
			if Items[Index + 1]["checked"] {
				Checked += 1
				AssertEqual("cerebras", Choice["value"], "the chosen provider is checked")
			}
		}
		AssertEqual(1, Checked, "one backend checked")
		Model := Items[Items.Length]
		AssertEqual(StrReplace(t("menu.agent.model"), "{1}", "llama-3.3-70b"), Model["label"], "the model")

		Fx.PromptAnswers.Push(Map("ok", true, "value", ""))
		Model["action"].Call()
		AssertEqual(StrReplace(t("dialog.agent.model_prompt"), "{1}", "Cerebras"), Fx.Prompts[1]["text"],
			"the prompt names the provider")
		AssertEqual("llama-3.3-70b", Fx.Prompts[1]["default"], "and shows the current model")
		AssertEqual("cerebras", _LLM_Menu["agent_system2"], "an empty model keeps the default")
		AssertEqual(1, Fx.Rebuilds, "the tray is rebuilt")
		Row := _LLM_Agent_SystemRow("agent_system2")
		AssertEqual(StrReplace(t("menu.agent.model"), "{1}", LLM_API_PROVIDERS["cerebras"]["DefaultModel"]),
			Row["items"][Row["items"].Length]["label"], "the default model is shown")

		Fx.PromptAnswers.Push(Map("ok", true, "value", " qwen3:14b "))
		Row["items"][Row["items"].Length]["action"].Call()
		AssertEqual("cerebras|qwen3:14b", _LLM_Menu["agent_system2"], "a named model is stored with its backend")

		Row := _LLM_Agent_SystemRow("agent_system1")
		AssertEqual(StrReplace(t("menu.agent.system1"), "{1}", t("menu.agent.off")), Row["label"], "System 1 is off")
		AssertTrue(Row["items"][1]["checked"], "off is checked")
		AssertTrue(Row["items"][Row["items"].Length]["disabled"], "no model without a backend")
		Row["items"][2]["action"].Call()
		AssertEqual("local", _LLM_Menu["agent_system1"], "choosing the local server stores its id")
		AssertEqual(3, Fx.Commits.Length, "every change goes through the transaction")
	}
}
Test("LLM agent: the System 1 and System 2 submenus list, check and store backends and models", _LAG_SystemRows)

_LAG_ModeRow() {
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		Row := _LLM_Agent_ModeRow()
		AssertEqual(StrReplace(t("menu.agent.mode_title"), "{1}", t("menu.agent.mode_action")), Row["label"],
			"the current mode")
		AssertEqual(3, Row["items"].Length, "three modes")
		AssertTrue(Row["items"][2]["checked"] && !Row["items"][1]["checked"] && !Row["items"][3]["checked"],
			"the current one checked")
		Row["items"][3]["action"].Call()
		AssertEqual("action", _LLM_Menu["agent_mode"], "auto is refused without System 1")
		AssertEqual(t("llm.agent.no_system1"), _LPP_PendingNotice(), "with its notice")
		AssertEqual(0, Fx.Commits.Length, "and nothing is stored")
		_LLM_Menu["agent_system1"] := "cerebras"
		AssertTrue(LLM_Agent_ToggleAuto(), "the toggle turns the automatic mode on")
		AssertEqual("auto", _LLM_Menu["agent_mode"], "auto")
		AssertEqual(t("llm.agent.auto_on"), _LPP_PendingNotice(), "with its notice")
		AssertTrue(LLM_Agent_ToggleAuto(), "then back")
		AssertEqual("action", _LLM_Menu["agent_mode"], "to on action")
		AssertEqual(t("llm.agent.auto_off"), _LPP_PendingNotice(), "with its notice")
		_LLM_Agent_ModeRow()["items"][1]["action"].Call()
		AssertEqual("off", _LLM_Menu["agent_mode"], "the off row turns the agent off")
		AssertTrue(LLM_Agent_ToggleAuto(), "from off the toggle goes to auto")
		AssertEqual("auto", _LLM_Menu["agent_mode"], "auto")
		Row := _LLM_Agent_AppsRow()
		AssertEqual(StrReplace(t("menu.agent.disabled_apps"), "{1}", 0), Row["label"], "no excluded application")
	}
}
Test("LLM agent: the mode submenu and the toggle refuse auto without System 1", _LAG_ModeRow)

_LAG_PickerSelection() {
	Candidate := Map("agent_disabled_apps", [])
	Receipt := AppPicker_IssueReceipt("agent:disabled_apps", [])
	AssertTrue(_LLM_Agent_ApplyPickerSelection(["Slack.EXE"], Receipt, Candidate), "the selection is taken")
	AssertEqual("", _LVS_DeepEqual(["slack.exe"], Candidate["agent_disabled_apps"]), "normalized like the AI's")
	Stale := AppPicker_IssueReceipt("agent:disabled_apps", ["other.exe"])
	AssertFalse(_LLM_Agent_ApplyPickerSelection(["x.exe"], Stale, Candidate),
		"a picker opened on another selection loses")
}
Test("LLM agent: the excluded applications picker stores a normalized list", _LAG_PickerSelection)





; ================================================================
; ================================================================
; ======= 3/ Fixture: backends, dialogs, connectors, clock =======
; ================================================================
; ================================================================

global LAG_SELECTION := "On se voit jeudi 14h avec Paul pour le devis"

; A menu whose remote backend is ready, with the agent's settings.
_LAG_Menu(Mode, System1, System2, Enabled := true) {
	State := _LPP_Menu(Enabled)
	State["agent_mode"] := Mode
	State["agent_system1"] := System1
	State["agent_system2"] := System2
	State["agent_disabled_apps"] := []
	return State
}

; The menu's API entry for Cerebras, whose key the agent borrows.
_LAG_CerebrasEntry() {
	return Map("Id", "cerebras-a", "Provider", "cerebras", "BaseUrl", "https://cerebras.invalid/v1",
		"Token", "key-c", "Model", "some-chat-model")
}

; The fixed context: Mail's "Re: devis" window on Tuesday 2026-09-29 at 14:05.
_LAG_Context(Fx) {
	return Map("app", Fx.App, "window", "Re: devis", "now", "2026-09-29T14:05", "weekday", "Tuesday",
		"timezone", "Europe/Paris")
}

; Runs Body(Fx, Lines, Sent) with the selection fixture, the fake transports,
; dialog, clock, connectors, scheduler and state store; everything is put back.
_LAG_Run(Menu, Screen, Body) {
	global _I18nLocale, _LLM_Vision_RemoteTransport, _LLM_Vision_OllamaTransport
	global _LLM_Agent_PromptFn, _LLM_Agent_ContextProbe, _LLM_Agent_SourceProbe, _LLM_Agent_ConnectorFn
	global _LLM_Agent_ScheduleFn, _LLM_Agent_StateReader, _LLM_Agent_StateWriter, _LLM_Agent_SecureFieldFn
	global _LLM_Agent_CommitFn, _LLM_Agent_RebuildFn, _LLM_Agent_Generation, _LLM_Agent_Auto, _LLM_Agent_Learning
	global _LLM_AgentConnector_Tools, _LLM_AgentConnector_ListFn, _LLM_AgentConnector_EnsureDirFn
	global _Stub_LlmTooltipVisible, _Stub_LlmPresentedRecord
	Saved := {
		Locale: _I18nLocale, Remote: _LLM_Vision_RemoteTransport, Ollama: _LLM_Vision_OllamaTransport,
		Prompt: _LLM_Agent_PromptFn, Context: _LLM_Agent_ContextProbe, Source: _LLM_Agent_SourceProbe,
		Connector: _LLM_Agent_ConnectorFn, Schedule: _LLM_Agent_ScheduleFn, Reader: _LLM_Agent_StateReader,
		Writer: _LLM_Agent_StateWriter, Secure: _LLM_Agent_SecureFieldFn, Commit: _LLM_Agent_CommitFn,
		Rebuild: _LLM_Agent_RebuildFn, Generation: _LLM_Agent_Generation, Auto: _LLM_Agent_Auto,
		Learning: _LLM_Agent_Learning, Tools: _LLM_AgentConnector_Tools, List: _LLM_AgentConnector_ListFn,
		Ensure: _LLM_AgentConnector_EnsureDirFn, Visible: _Stub_LlmTooltipVisible,
		Presented: _Stub_LlmPresentedRecord
	}
	Fx := { Remote: [], Ollama: [], Connector: [], ConnectorResult: Map("ok", true, "path", "fake"),
		Prompts: [], PromptAnswers: [], Scheduled: [], Commits: [], Rebuilds: 0, Stored: "", Written: [],
		App: "Mail", Secure: false }
	try {
		_I18nLocale := "fr"
		_LLM_Vision_RemoteTransport := (Resolved, Url, Payload, OnSuccess, OnFail) => Fx.Remote.Push(Map(
			"resolved", Resolved, "url", Url, "body", Payload, "on_success", OnSuccess, "on_fail", OnFail))
		_LLM_Vision_OllamaTransport := (Payload, OnSuccess, OnFail) => Fx.Ollama.Push(Map(
			"body", Payload, "on_success", OnSuccess, "on_fail", OnFail))
		_LLM_Agent_PromptFn := _LAG_FakePrompt.Bind(Fx)
		_LLM_Agent_ContextProbe := () => _LAG_Context(Fx)
		_LLM_Agent_SourceProbe := () => Map("hwnd", 7, "control", 9)
		_LLM_Agent_ConnectorFn := _LAG_FakeConnector.Bind(Fx)
		_LLM_Agent_ScheduleFn := (Callback, Period) => Fx.Scheduled.Push(Map("fn", Callback, "period", Period))
		_LLM_Agent_StateReader := (Key, Default) => Fx.Stored
		_LLM_Agent_StateWriter := _LAG_FakeWrite.Bind(Fx)
		_LLM_Agent_SecureFieldFn := () => Fx.Secure
		_LLM_Agent_CommitFn := _LAG_FakeCommit.Bind(Fx)
		_LLM_Agent_RebuildFn := () => Fx.Rebuilds += 1
		_LLM_Agent_Auto := Map("timer", 0, "offer", "", "triaged", Map(), "order", [])
		_LLM_Agent_Learning := ""
		_LLM_AgentConnector_Tools := ""
		_LLM_AgentConnector_ListFn := (Dir) => []
		_LLM_AgentConnector_EnsureDirFn := (Dir) => false
		_Stub_LlmTooltipVisible := false
		_Stub_LlmPresentedRecord := 0
		_LTN_Run(Menu, Screen, _Inner)
	} finally {
		_I18nLocale := Saved.Locale
		_LLM_Vision_RemoteTransport := Saved.Remote
		_LLM_Vision_OllamaTransport := Saved.Ollama
		_LLM_Agent_PromptFn := Saved.Prompt
		_LLM_Agent_ContextProbe := Saved.Context
		_LLM_Agent_SourceProbe := Saved.Source
		_LLM_Agent_ConnectorFn := Saved.Connector
		_LLM_Agent_ScheduleFn := Saved.Schedule
		_LLM_Agent_StateReader := Saved.Reader
		_LLM_Agent_StateWriter := Saved.Writer
		_LLM_Agent_SecureFieldFn := Saved.Secure
		_LLM_Agent_CommitFn := Saved.Commit
		_LLM_Agent_RebuildFn := Saved.Rebuild
		_LLM_Agent_Generation := Saved.Generation
		_LLM_Agent_Auto := Saved.Auto
		_LLM_Agent_Learning := Saved.Learning
		_LLM_AgentConnector_Tools := Saved.Tools
		_LLM_AgentConnector_ListFn := Saved.List
		_LLM_AgentConnector_EnsureDirFn := Saved.Ensure
		_Stub_LlmTooltipVisible := Saved.Visible
		_Stub_LlmPresentedRecord := Saved.Presented
	}
	_Inner(Calls, Lines, Sent) {
		global _LLM_Engine
		_LLM_Engine["api_entries"].Push(_LAG_CerebrasEntry())
		Body.Call(Fx, Lines, Sent)
	}
}

_LAG_FakePrompt(Fx, Title, Text, Default) {
	Fx.Prompts.Push(Map("title", Title, "text", Text, "default", Default))
	return Fx.PromptAnswers.RemoveAt(1)
}

_LAG_FakeConnector(Fx, Action, Config) {
	Fx.Connector.Push(Action)
	return Fx.ConnectorResult
}

_LAG_FakeWrite(Fx, Key, Value) {
	Fx.Written.Push(Map("key", Key, "value", Value))
	Fx.Stored := LLM_Menu_DeepClone(Value)
	return true
}

; Stores nothing, runs the selection action through the gesture dispatcher.
_LAG_Invoke(ActionId) {
	return GestureInvokeAction(ActionId, "keyboard__agent_test")
}

; The one request of a flow, decoded: its system prompt, user turn and budget.
_LAG_Request(Call) {
	Body := JsonParse(Call["body"])
	return Map("system", Body["messages"][1]["content"], "user", Body["messages"][2]["content"],
		"max_tokens", Body["max_tokens"], "model", Body["model"], "body", Body)
}

; The System 2 prompt the fixed context gives a source.
_LAG_System2Prompt(Source, App := "Mail") {
	return LLM_Agent_System2Prompt(LLM_Agent_Config(), Map("source", Source, "app", App, "window", "Re: devis",
		"now", "2026-09-29T14:05", "weekday", "Tuesday", "timezone", "Europe/Paris", "language", "fr",
		"tools", []))
}





; ===================================================
; ===================================================
; ======= 4/ On action: selection and command =======
; ===================================================
; ===================================================

global LAG_ANSWER := 'Voici. ACTIONS: [{"type":"calendar","title":"Devis avec Paul","start":"2026-10-01T14:00",'
	. '"attendees":["paul@example.com"]},{"type":"mail","to":["paul@example.com"],"subject":"Devis",'
	. '"body":"Bonjour Paul,\nÀ jeudi."}]'

_LAG_SelectionEndToEnd() {
	Screen := _LTN_Screen(LAG_SELECTION)
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		global _Stub_LlmTooltipCalls
		Config := LLM_Agent_Config()
		AssertTrue(_LAG_Invoke("llm_agent_selection"), "the action reads the selection")
		AssertEqual(1, Screen.Reads, "once")
		AssertEqual(1, Fx.Remote.Length, "one request")
		Call := Fx.Remote[1]
		AssertEqual("cerebras", Call["resolved"]["Provider"], "to the Cerebras entry")
		AssertEqual("https://cerebras.invalid/v1/chat/completions", Call["url"], "at its address")
		AssertEqual("key-c", Call["resolved"]["Token"], "with its key")
		Request := _LAG_Request(Call)
		AssertEqual(LLM_API_PROVIDERS["cerebras"]["DefaultModel"], Request["model"],
			"the provider's default model")
		AssertEqual(_LAG_System2Prompt("selection"), Request["system"], "the System 2 prompt")
		AssertContains(Request["system"], "Now is 2026-09-29T14:05, a Tuesday, time zone Europe/Paris",
			"with the date, the weekday and the time zone")
		AssertContains(Request["system"], "selected in Mail (window: Re: devis)", "the application and window")
		AssertEqual("SOURCE:`n" . LAG_SELECTION, Request["user"], "the selection is the user turn")
		AssertEqual(Config["system2"]["max_tokens"], Request["max_tokens"], "within the System 2 budget")
		AssertEqual(1, _Stub_LlmTooltipCalls.Length, "a loading tooltip while waiting")
		AssertTrue(_Stub_LlmTooltipCalls[1].HasOwnProp("loading"), "the spinner")

		Call["on_success"].Call(LAG_ANSWER)
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the actions are offered")
		AssertEqual(2, Final.slots.Length, "two candidates")
		AssertEqual(_LLM_Agent_Format("llm.agent.label.calendar", ["Devis avec Paul", "2026-10-01 14:00"]),
			Final.slots[1].Text, "the calendar entry first")
		AssertEqual(_LLM_Agent_Format("llm.agent.label.mail_to", ["Devis", "paul@example.com"]),
			Final.slots[2].Text, "then the mail")
		AssertEqual(7, Final.meta["accept_source"]["hwnd"], "accepted in the focused window")
		Handler := _LLM_Bridge_AcceptedSlotHandler({ Slots: Final.slots, ActiveIdx: 1 })
		AssertTrue(HasMethod(Handler, "Call"), "Tab runs the slot's own handler")
		AssertEqual("", _LLM_Bridge_AcceptedSlotHandler({ Slots: ["text"], ActiveIdx: 1 }),
			"an ordinary prediction has none")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "Paul"), "neither the selection nor an action is logged")

		Handler.Call()
		AssertEqual(1, Fx.Connector.Length, "accepting the first runs its connector")
		Action := Fx.Connector[1]
		AssertEqual("calendar", Action["type"], "the calendar one")
		AssertEqual("2026-10-01T15:00", Action["end"], "with the default duration")
		AssertEqual(StrReplace(t("llm.agent.done_calendar"), "{1}", "Devis avec Paul"), _LPP_PendingNotice(),
			"and says it is done")
		AssertEqual(0, Sent.Length, "nothing is typed")
		Final.slots[2].OnAccept.Call()
		AssertEqual("mail", Fx.Connector[2]["type"], "the mail's own handler runs the mail connector")
		AssertEqual(t("llm.agent.done_mail"), _LPP_PendingNotice(), "a draft is open")
	}
}
Test("LLM agent: a selection becomes actions offered and carried out on acceptance", _LAG_SelectionEndToEnd)

_LAG_CommandDialog() {
	Screen := _LTN_Screen("")
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		Fx.PromptAnswers.Push(Map("ok", false, "value", ""))
		AssertFalse(_LAG_Invoke("llm_agent_command"), "a cancelled dialog")
		AssertEqual(t("dialog.agent.command_title"), Fx.Prompts[1]["title"], "the dialog's title")
		AssertEqual(t("dialog.agent.command_prompt"), Fx.Prompts[1]["text"], "and prompt")
		AssertEqual(0, Fx.Remote.Length, "sends nothing")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "command cancelled"), "and says so in the log")
		Fx.PromptAnswers.Push(Map("ok", true, "value", "  "))
		AssertFalse(_LAG_Invoke("llm_agent_command"), "an empty command does nothing either")
		Fx.PromptAnswers.Push(Map("ok", true, "value", "réunion demain 9h avec l'équipe"))
		AssertTrue(_LAG_Invoke("llm_agent_command"), "a command is sent")
		AssertEqual(0, Screen.Reads, "without reading the selection")
		Request := _LAG_Request(Fx.Remote[1])
		AssertEqual(_LAG_System2Prompt("command"), Request["system"], "as a command")
		AssertEqual("SOURCE:`nréunion demain 9h avec l'équipe", Request["user"], "the command is the user turn")
	}
}
Test("LLM agent: the command dialog sends its text; cancelling does nothing", _LAG_CommandDialog)

_LAG_Refusals() {
	Screen := _LTN_Screen(LAG_SELECTION)
	_LAG_Run(_LAG_Menu("action", "", ""), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "no System 2")
		AssertEqual(t("llm.agent.no_system2"), _LPP_PendingNotice(), "is told")
		_LLM_Menu["agent_system2"] := "openai_compat"
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "a provider without a model is not configured")
		AssertEqual(t("llm.agent.no_system2"), _LPP_PendingNotice(), "the same notice")
		_LLM_Menu["agent_system2"] := "cerebras"
		_LLM_Menu["agent_mode"] := "off"
		AssertFalse(_LAG_Invoke("llm_agent_command"), "the agent is off")
		AssertEqual(t("llm.agent.off_notice"), _LPP_PendingNotice(), "is told")
		_LLM_Menu["agent_mode"] := "action"
		_LLM_Menu["enabled"] := false
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "the AI is off")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
		_LLM_Menu["enabled"] := true
		_LLM_Menu["agent_system2"] := "anthropic"
		_LAG_Invoke("llm_agent_selection")
		AssertEqual(t("llm.agent.failed"), _LPP_PendingNotice(), "a provider without an API entry cannot answer")
		AssertEqual(0, Fx.Remote.Length, "no request left")
		AssertEqual(0, Fx.Prompts.Length, "and no dialog opened")
	}
}
Test("LLM agent: no System 2, an agent off or an AI off refuse with their notice", _LAG_Refusals)

_LAG_AnswersRefusedOrFailing() {
	Screen := _LTN_Screen(LAG_SELECTION)
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		global _Stub_LlmTooltipCalls
		_LAG_Invoke("llm_agent_selection")
		Fx.Remote[1]["on_success"].Call('ACTIONS: [{"type":"run","cmd":"format c:"},'
			. '{"type":"calendar","title":"X","start":"jeudi"},{"type":"reminder","title":"Rappeler Paul"}]')
		Final := _LPP_LastFinalRender()
		AssertEqual(1, Final.slots.Length, "the invalid actions are dropped")
		AssertEqual(_LLM_Agent_Format("llm.agent.label.reminder", ["Rappeler Paul"]), Final.slots[1].Text,
			"the valid one stays")
		AssertEqual(2, _LPP_LinesWith(Lines, "INFO", "an action was refused"), "each refusal is logged")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "unknown type run"), "with its reason")

		Fx.ConnectorResult := Map("ok", false, "reason", "boom")
		Final.slots[1].OnAccept.Call()
		AssertEqual(t("llm.agent.connector_failed"), _LPP_PendingNotice(), "a failing connector is reported")
		AssertEqual(1, _LPP_LinesWith(Lines, "ERROR", "boom"), "with its reason in the log")

		TooltipHide("AgentTest", true)
		_LAG_Invoke("llm_agent_selection")
		Fx.Remote[2]["on_success"].Call("I cannot help with that.")
		AssertEqual(t("llm.agent.failed"), _LPP_PendingNotice(), "an answer without actions fails")
		_LAG_Invoke("llm_agent_selection")
		Fx.Remote[3]["on_success"].Call("ACTIONS: []")
		AssertEqual(t("llm.agent.no_action"), _LPP_PendingNotice(), "an empty list has nothing to suggest")
		_LAG_Invoke("llm_agent_selection")
		Fx.Remote[4]["on_fail"].Call(_LLMRemote_FailInfo("timeout"))
		AssertEqual(t("llm.agent.failed"), _LPP_PendingNotice(), "a failed request is reported")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "timeout"), "with its reason")

		_LAG_Invoke("llm_agent_selection")
		_LAG_Invoke("llm_agent_selection")
		Calls := _Stub_LlmTooltipCalls.Length
		Fx.Remote[5]["on_success"].Call(LAG_ANSWER)
		AssertEqual(Calls, _Stub_LlmTooltipCalls.Length, "a superseded answer is not shown")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "a newer flow superseded it"), "its drop is logged")
		Fx.Remote[6]["on_success"].Call(LAG_ANSWER)
		AssertEqual(2, _LPP_LastFinalRender().slots.Length, "the newest one is")
	}
}
Test("LLM agent: invalid actions are dropped, failures reported, older answers ignored",
	_LAG_AnswersRefusedOrFailing)





; =============================
; =============================
; ======= 5/ Connectors =======
; =============================
; =============================

class _LAG_FakeOutlook {
	__New() {
		this.Items := []
	}
	CreateItem(Kind) {
		Item := _LAG_FakeItem(Kind)
		this.Items.Push(Item)
		return Item
	}
}

class _LAG_FakeItem {
	__New(Kind) {
		this.Kind := Kind
		this.Calls := []
		this.Recipients := _LAG_FakeRecipients()
	}
	Save() {
		this.Calls.Push("Save")
	}
	Display() {
		this.Calls.Push("Display")
	}
	Send() {
		this.Calls.Push("Send")
	}
}

class _LAG_FakeRecipients {
	__New() {
		this.Added := []
	}
	Add(Address) {
		this.Added.Push(Address)
	}
}

; Runs Body(Fx) with every connector boundary faked; Fx.Outlook is "" for a
; machine without Outlook.
_LAG_RunConnectors(Outlook, Body) {
	global _LLM_AgentConnector_ComFn, _LLM_AgentConnector_OpenFn, _LLM_AgentConnector_LaunchFn
	global _LLM_AgentConnector_WriteFn, _LLM_AgentConnector_DeleteFn, _LLM_AgentConnector_ListFn
	global _LLM_AgentConnector_EnsureDirFn, _LLM_AgentConnector_IdFn, _LLM_AgentConnector_Tools
	global _LLM_AgentConnector_TempFiles
	Saved := {
		Com: _LLM_AgentConnector_ComFn, Open: _LLM_AgentConnector_OpenFn, Launch: _LLM_AgentConnector_LaunchFn,
		Write: _LLM_AgentConnector_WriteFn, Delete: _LLM_AgentConnector_DeleteFn, List: _LLM_AgentConnector_ListFn,
		Ensure: _LLM_AgentConnector_EnsureDirFn, Id: _LLM_AgentConnector_IdFn, Tools: _LLM_AgentConnector_Tools,
		Temp: _LLM_AgentConnector_TempFiles
	}
	Fx := { Outlook: Outlook, ProgIds: [], Opened: [], Launched: [], Written: [], Deleted: [], Dirs: [] }
	try {
		_LLM_AgentConnector_ComFn := (ProgId) => (Fx.ProgIds.Push(ProgId), Fx.Outlook)
		_LLM_AgentConnector_OpenFn := (Target) => Fx.Opened.Push(Target)
		_LLM_AgentConnector_LaunchFn := (Argv) => Fx.Launched.Push(Argv)
		_LLM_AgentConnector_WriteFn := (Path, Text) => (Fx.Written.Push(Map("path", Path, "text", Text)), true)
		_LLM_AgentConnector_DeleteFn := (Path) => (Fx.Deleted.Push(Path), true)
		_LLM_AgentConnector_ListFn := (Dir) => ["C:\t\Envoyer la facture.ps1", "C:\t\Mode focus.cmd",
			"C:\t\notes.txt", "C:\t\Ouvrir le CRM.ahk"]
		_LLM_AgentConnector_EnsureDirFn := (Dir) => Fx.Dirs.Push(Dir)
		_LLM_AgentConnector_IdFn := () => Map("uid", "abc123@ergopti", "stamp", "20260929T120500Z")
		_LLM_AgentConnector_Tools := ""
		_LLM_AgentConnector_TempFiles := []
		Body.Call(Fx)
	} finally {
		_LLM_AgentConnector_ComFn := Saved.Com
		_LLM_AgentConnector_OpenFn := Saved.Open
		_LLM_AgentConnector_LaunchFn := Saved.Launch
		_LLM_AgentConnector_WriteFn := Saved.Write
		_LLM_AgentConnector_DeleteFn := Saved.Delete
		_LLM_AgentConnector_ListFn := Saved.List
		_LLM_AgentConnector_EnsureDirFn := Saved.Ensure
		_LLM_AgentConnector_IdFn := Saved.Id
		_LLM_AgentConnector_Tools := Saved.Tools
		_LLM_AgentConnector_TempFiles := Saved.Temp
	}
}

; A validated action from its JSON.
_LAG_Action(Json) {
	Action := LLM_Agent_ValidateAction(LLM_Agent_Config(), JsonParse(Json),
		["Envoyer la facture", "Mode focus", "Ouvrir le CRM"], &Reason)
	AssertTrue(Action is Map, "the fixture action is valid: " . Reason)
	return Action
}

_LAG_OutlookConnectors() {
	_LAG_RunConnectors(_LAG_FakeOutlook(), _Body)
	_Body(Fx) {
		Config := LLM_Agent_Config()
		Result := LLM_AgentConnector_Execute(_LAG_Action('{"type":"calendar","title":"Devis","start":"2026-10-01T14:00",'
			. '"location":"Salle B","notes":"Apporter le devis","attendees":["paul@example.com"]}'), Config)
		AssertTrue(Result["ok"], "the calendar entry is saved")
		AssertEqual("outlook", Result["path"], "through Outlook")
		AssertEqual("Outlook.Application", Fx.ProgIds[1], "reached through COM")
		Item := Fx.Outlook.Items[1]
		AssertEqual(1, Item.Kind, "an appointment")
		AssertEqual("Devis", Item.Subject, "titled")
		AssertEqual(LLM_Agent_OleDate("2026-10-01T14:00"), Item.Start, "starting at the local time")
		AssertEqual(LLM_Agent_OleDate("2026-10-01T15:00"), Item.End, "for the default duration")
		AssertEqual("Salle B", Item.Location, "at its place")
		AssertEqual("Apporter le devis", Item.Body, "with its notes")
		AssertEqual(1, Item.MeetingStatus, "a meeting")
		AssertEqual("", _LVS_DeepEqual(["paul@example.com"], Item.Recipients.Added), "with its attendee")
		AssertEqual("", _LVS_DeepEqual(["Save"], Item.Calls), "saved, never sent")

		Result := LLM_AgentConnector_Execute(_LAG_Action('{"type":"reminder","title":"Appeler le garage",'
			. '"due":"2026-09-30T09:00"}'), Config)
		Item := Fx.Outlook.Items[2]
		AssertEqual(3, Item.Kind, "a task")
		AssertEqual(LLM_Agent_OleDate("2026-09-30T09:00"), Item.DueDate, "due then")
		AssertTrue(Item.ReminderSet, "with a reminder")
		AssertEqual(LLM_Agent_OleDate("2026-09-30T09:00"), Item.ReminderTime, "at that time")
		AssertEqual("", _LVS_DeepEqual(["Save"], Item.Calls), "saved")

		Result := LLM_AgentConnector_Execute(_LAG_Action('{"type":"mail","to":["a@b.fr","c@d.fr"],'
			. '"subject":"Devis","body":"Bonjour"}'), Config)
		Item := Fx.Outlook.Items[3]
		AssertEqual(0, Item.Kind, "a mail")
		AssertEqual("a@b.fr; c@d.fr", Item.To, "to its recipients")
		AssertEqual("Devis", Item.Subject, "with its subject")
		AssertEqual("Bonjour", Item.Body, "and body")
		AssertEqual("", _LVS_DeepEqual(["Display"], Item.Calls), "displayed for review, never sent")
		AssertEqual(0, Fx.Opened.Length + Fx.Written.Length, "no file, no link")
	}
}
Test("LLM agent: Outlook saves events and tasks and only displays mails", _LAG_OutlookConnectors)

_LAG_FallbackConnectors() {
	_LAG_RunConnectors("", _Body)
	_Body(Fx) {
		Config := LLM_Agent_Config()
		Action := _LAG_Action('{"type":"calendar","title":"Devis","start":"2026-10-01T14:00"}')
		Result := LLM_AgentConnector_Execute(Action, Config)
		AssertTrue(Result["ok"] && Result["path"] == "ics", "without Outlook, an iCalendar file")
		AssertEqual(1, Fx.Written.Length, "written once")
		Path := Fx.Written[1]["path"]
		AssertTrue(InStr(Path, _LLM_Ollama_TempDir() . "\") == 1 && SubStr(Path, -4) == ".ics",
			"to a private temp .ics file")
		AssertEqual(LLM_Agent_Ics(Config, Action, "abc123@ergopti", "20260929T120500Z"), Fx.Written[1]["text"],
			"with the shared bytes")
		AssertEqual("", _LVS_DeepEqual([Path], Fx.Opened), "opened with the default handler")
		AssertEqual(0, Fx.Deleted.Length, "and not deleted before the application read it")

		Mail := _LAG_Action('{"type":"mail","to":["paul@example.com"],"subject":"Devis","body":"Bonjour"}')
		Result := LLM_AgentConnector_Execute(Mail, Config)
		AssertTrue(Result["ok"] && Result["path"] == "mailto", "without Outlook, a mailto: link")
		AssertEqual(LLM_Agent_Mailto(Mail), Fx.Opened[2], "opened with the mail client")
		AssertEqual("", _LVS_DeepEqual([Path], Fx.Deleted), "the earlier calendar file is deleted at this run")
	}
}
Test("LLM agent: without Outlook, an .ics file or a mailto: link is opened", _LAG_FallbackConnectors)

_LAG_ToolConnectors() {
	_LAG_RunConnectors("", _Body)
	_Body(Fx) {
		Config := LLM_Agent_Config()
		Tools := LLM_AgentConnector_Tools(Config, true)
		AssertEqual("", _LVS_DeepEqual(["Envoyer la facture", "Mode focus", "Ouvrir le CRM"], Tools["names"]),
			"the scripts of the tools folder, sorted, without other files")
		AssertEqual(LLM_AgentConnector_ToolsDir(), Fx.Dirs[1], "the folder is created when missing")
		Result := LLM_AgentConnector_Execute(_LAG_Action('{"type":"shortcut","name":"Envoyer la facture",'
			. '"input":"Facture 12 & \"urgent\""}'), Config)
		AssertTrue(Result["ok"], "the PowerShell tool runs")
		AssertEqual("", _LVS_DeepEqual(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
			"C:\t\Envoyer la facture.ps1", 'Facture 12 & "urgent"'], Fx.Launched[1]),
			"with the input as its only argument")
		LLM_AgentConnector_Execute(_LAG_Action('{"type":"shortcut","name":"Ouvrir le CRM"}'), Config)
		AssertEqual("", _LVS_DeepEqual([A_AhkPath, "C:\t\Ouvrir le CRM.ahk"], Fx.Launched[2]),
			"an AutoHotkey tool runs with AutoHotkey, without an input")
		Result := LLM_AgentConnector_Execute(_LAG_Action('{"type":"shortcut","name":"Mode focus",'
			. '"input":"100%"}'), Config)
		AssertFalse(Result["ok"], "a .cmd tool refuses an input cmd.exe would expand")
		AssertEqual(2, Fx.Launched.Length, "and nothing runs")
		AssertEqual('"a b"', AL_QuoteArgument("a b"), "an argument with a space is quoted")
		AssertEqual('"x\"y"', AL_QuoteArgument('x"y'), "a quote is escaped")
		AssertEqual('"C:\my dir\\"', AL_QuoteArgument("C:\my dir\"), "a final backslash is doubled inside quotes")
		AssertEqual("C:\dir\", AL_QuoteArgument("C:\dir\"), "a path without a space is left as is")
		AssertEqual('""', AL_QuoteArgument(""), "an empty argument stays one")
		AssertEqual("plain", AL_QuoteArgument("plain"), "a plain one is left as is")
	}
}
Test("LLM agent: a tool of the tools folder runs with the input as its argument", _LAG_ToolConnectors)





; ======================================
; ======================================
; ======= 6/ Automatic detection =======
; ======================================
; ======================================

global LAG_TYPED := "Bonjour. " . LAG_SELECTION

; Types Buffer and returns the pause callback it armed, "" when none.
_LAG_Type(Fx, Buffer) {
	global LLM_AGENT_LEARNING_SAVE_DELAY_MS
	Before := Fx.Scheduled.Length
	LLM_Agent_OnTyping(Buffer)
	for Entry in Fx.Scheduled {
		if (A_Index > Before && Entry["period"] < 0 && Entry["period"] != -LLM_AGENT_LEARNING_SAVE_DELAY_MS)
			return Entry["fn"]
	}
	return ""
}

_LAG_AutoEndToEnd() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _Stub_LlmTooltipCalls
		Config := LLM_Agent_Config()
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		Pause := _LAG_Type(Fx, LAG_TYPED)
		AssertTrue(HasMethod(Pause, "Call"), "typing arms the pause timer")
		AssertEqual(-Config["system1"]["pause_ms"], Fx.Scheduled[Fx.Scheduled.Length]["period"],
			"for agent.json's pause")
		AssertEqual(0, Fx.Remote.Length, "nothing is sent while typing")
		AssertTrue(Pause.Call(), "the pause triages the sentence")
		AssertEqual(1, Fx.Remote.Length, "one System 1 request")
		Triage := _LAG_Request(Fx.Remote[1])
		AssertEqual(LLM_Agent_System1Prompt(Config, Map("app", "Slack", "tools", [])), Triage["system"],
			"with the triage prompt")
		AssertEqual(LAG_SELECTION, Triage["user"], "on the current sentence")
		AssertEqual(Config["system1"]["max_tokens"], Triage["max_tokens"], "within the System 1 budget")
		AssertEqual("none", Triage["body"]["reasoning_effort"], "the provider's model fields ride along")

		Fx.Remote[1]["on_success"].Call("INTENT: calendar`nPROBABILITY: 0.86")
		AssertEqual(2, Fx.Remote.Length, "above the threshold, System 2 is asked")
		AssertEqual(_LAG_System2Prompt("typing", "Slack"), _LAG_Request(Fx.Remote[2])["system"],
			"about what is being typed")
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "discreetly: no spinner")
		Fx.Remote[2]["on_success"].Call(LAG_ANSWER)
		Final := _LPP_LastFinalRender()
		AssertEqual(2, Final.slots.Length, "the candidates are offered")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "Paul"), "the sentence is never logged")

		Final.slots[1].OnAccept.Call()
		AssertEqual(1, Fx.Connector.Length, "Tab runs the calendar connector")
		AssertEqual(0.65, LLM_Agent_Threshold("Slack", "calendar"), "and the accepted intent's threshold drops")
	}
}
Test("LLM agent: a typing pause is triaged, then System 2 offers its actions", _LAG_AutoEndToEnd)

_LAG_AutoGates() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _Stub_LlmTooltipVisible, _LLM_Live
		TooltipHide("AgentTest", true)
		; Below the threshold nothing more is asked
		_LAG_Type(Fx, LAG_TYPED).Call()
		Fx.Remote[1]["on_success"].Call("INTENT: calendar`nPROBABILITY: 0.5")
		AssertEqual(1, Fx.Remote.Length, "under the threshold, System 2 is not woken")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "nothing suggested"), "the decision is logged")
		; The same sentence is never triaged twice
		AssertFalse(_LAG_Type(Fx, LAG_TYPED).Call(), "the same sentence")
		AssertEqual(1, Fx.Remote.Length, "is not triaged again")
		; A keystroke retires the armed pause and the triage in flight
		Old := _LAG_Type(Fx, "Autre chose : rappelle-moi le garage")
		_LAG_Type(Fx, "Autre chose : rappelle-moi le garage demain")
		AssertFalse(Old.Call(), "an older pause fires for nothing")
		Pause := _LAG_Type(Fx, "Autre chose : rappelle-moi le garage demain matin")
		AssertTrue(Pause.Call(), "the newest one triages")
		LLM_Agent_OnTyping("Autre chose : rappelle-moi le garage demain matin.")
		Fx.Remote[2]["on_success"].Call("INTENT: reminder`nPROBABILITY: 0.99")
		AssertEqual(2, Fx.Remote.Length, "a triage the user typed past is dropped")
		; Too short
		AssertFalse(_LAG_Type(Fx, "Ok. Merci").Call(), "a short sentence is not triaged")
		; Another tooltip or live mode holds the surface
		_Stub_LlmTooltipVisible := true
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "an AI tooltip blocks the triage")
		_Stub_LlmTooltipVisible := false
		SavedLive := _LLM_Live["active"]
		_LLM_Live["active"] := true
		try AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "live mode blocks it")
		finally _LLM_Live["active"] := SavedLive
		; A secure field or an excluded application
		Fx.Secure := true
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "a secure field blocks it")
		Fx.Secure := false
		_LLM_Menu["agent_disabled_apps"] := ["mail.exe"]
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "an excluded application blocks it")
		_LLM_Menu["agent_disabled_apps"] := []
		; Paused... or not in the automatic mode
		_LLM_Menu["agent_mode"] := "action"
		AssertEqual("", _LAG_Type(Fx, "Envoie le devis à Paul demain"), "only the automatic mode watches typing")
		_LLM_Menu["agent_mode"] := "auto"
		_LLM_Menu["agent_system1"] := ""
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "no System 1, no triage")
		AssertEqual(2, Fx.Remote.Length, "none of these sent anything")
	}
}
Test("LLM agent: the automatic mode respects its threshold, the keystrokes and the other tooltips",
	_LAG_AutoGates)





; ===========================
; ===========================
; ======= 7/ Learning =======
; ===========================
; ===========================

_LAG_Learning() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Agent_Learning
		Config := LLM_Agent_Config()
		AssertEqual(Config["system1"]["threshold"], LLM_Agent_Threshold("Slack", "calendar"), "agent.json's at first")
		AssertEqual(0.65, LLM_Agent_LearnOutcome("Slack", "calendar", true), "an acceptance lowers it")
		AssertEqual(0.7, LLM_Agent_LearnOutcome("Slack", "calendar", false), "a dismissal raises it")
		AssertEqual(0.75, LLM_Agent_LearnOutcome("Slack", "calendar", false), "again")
		loop 10
			LLM_Agent_LearnOutcome("Slack", "mail", true)
		AssertEqual(Config["learning"]["min_threshold"], LLM_Agent_Threshold("Slack", "mail"), "within its floor")
		loop 10
			LLM_Agent_LearnOutcome("Slack", "reminder", false)
		AssertEqual(Config["learning"]["max_threshold"], LLM_Agent_Threshold("Slack", "reminder"), "and ceiling")
		AssertEqual(Config["system1"]["threshold"], LLM_Agent_Threshold("Mail", "calendar"),
			"another application keeps its own")

		Save := Fx.Scheduled[Fx.Scheduled.Length]
		AssertEqual(-LLM_AGENT_LEARNING_SAVE_DELAY_MS, Save["period"], "the write is debounced")
		AssertEqual(0, Fx.Written.Length, "nothing is written before it fires")
		Save["fn"].Call()
		AssertEqual(1, Fx.Written.Length, "then written once")
		AssertEqual(LLM_AGENT_LEARNING_KEY, Fx.Written[1]["key"], "under the agent's key of the local store")
		_LLM_Agent_Learning := ""
		AssertEqual(0.75, LLM_Agent_Threshold("Slack", "calendar"), "reloaded after a restart")
		AssertEqual(Config["learning"]["min_threshold"], LLM_Agent_Threshold("slack", "mail"),
			"application names compare without case")

		loop LLM_AGENT_LEARNING_MAX_APPS
			LLM_Agent_LearnOutcome("app" . A_Index, "calendar", true)
		AssertEqual(LLM_AGENT_LEARNING_MAX_APPS, _LLM_Agent_Learning["apps"].Count, "bounded")
		AssertEqual(Config["system1"]["threshold"], LLM_Agent_Threshold("Slack", "calendar"),
			"the least recently used application is dropped")
	}
}
Test("LLM agent: accepting and dismissing move a per-application threshold, kept locally", _LAG_Learning)

_LAG_DismissByTyping() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		_LAG_Type(Fx, LAG_TYPED).Call()
		Fx.Remote[1]["on_success"].Call("INTENT: mail`nPROBABILITY: 0.9")
		Fx.Remote[2]["on_success"].Call(LAG_ANSWER)
		AssertTrue(IsObject(_LPP_LastFinalRender()), "the suggestion is shown")
		LLM_Agent_OnTyping(LAG_TYPED . " !")
		AssertEqual(0.75, LLM_Agent_Threshold("Slack", "mail"), "typing over it dismisses it")
		LLM_Agent_OnTyping(LAG_TYPED . " !!")
		AssertEqual(0.75, LLM_Agent_Threshold("Slack", "mail"), "once")
	}
}
Test("LLM agent: typing over an automatic suggestion dismisses it", _LAG_DismissByTyping)
