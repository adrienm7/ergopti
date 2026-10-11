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
		Choices := LLM_Agent_BackendChoices("agent_system2")
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

; Snapshot the real native choice, retaining its owned tree until assertions finish.
_LAG_NativeModeRow(Owned) {
	global _MenuDispatchCallbacks
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", 0, "ptr")
	Assert(Handle != 0, "the first declared agent row opens its mode choices")
	Sub := MenuFromHandle(Handle)
	Items := []
	loop TrayMenuItemCount(Sub) {
		Position := A_Index - 1
		Id := DllCall("GetMenuItemID", "ptr", Handle, "int", Position, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "each native mode uses the actual dispatcher")
		Items.Push(Map("label", _CTC_LabelAt(Sub, Position),
			"checked", _CTC_IsChecked(Sub, Position), "action", _MenuDispatchCallbacks[Id]))
	}
	State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
	Assert(State != 0xFFFFFFFF, "the actual mode parent has native flags")
	return Map("label", _CTC_LabelAt(Built, 0), "items", Items, "disabled", ((State & 0xFF) & 0x3) != 0)
}

; Read the independently captured three-mode menu matrix.
_LAG_ModeMenuCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\menus\agent_mode_rows.json"
	Assert(FileExist(Path), "the shared independent mode-menu corpus must exist")
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LAG_ModeMenuGolden() {
	Corpus := _LAG_ModeMenuCorpus()
	AssertEqual(3, Corpus["modes"].Length, "the independent catalogue contains three modes")
	AssertEqual(3, Corpus["states"].Length, "all three native states must be exercised")
	for State in Corpus["states"] {
		_LAG_Run(_LAG_Menu(State["selected"], "cerebras", "cerebras"), _LTN_Screen(""), _Body.Bind(Corpus, State))
		_Body(Corpus, State, Fx, Lines, Sent) {
			global _LLM_Menu
			Owned := []
			try {
				Row := _LAG_NativeModeRow(Owned)
				AssertEqual(3, Row["items"].Length, "all three independent choices are present")
				AssertFalse(Row["disabled"], "the native parent stays available with its actual command owner")
				for Index, Expected in Corpus["modes"] {
					Actual := Row["items"][Index]
					AssertEqual(t(Expected["label_key"]), Actual["label"], "mode order and label")
					AssertEqual(State["checked"][Index], Actual["checked"], "one exact native check")
					if Expected["value"] == State["selected"]
						AssertEqual(StrReplace(t("menu.agent.mode_title"), "{1}", Actual["label"]), Row["label"])
				}
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
Test("LLM agent: actual native mode choices replay the independent three-state menu matrix", _LAG_ModeMenuGolden)

_LAG_ModeMenuSharedDeclaration() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn
		Corpus := _LAG_ModeMenuCorpus()
		Mode := _MR_GetManifestRoot()["agent_menu"][1]
		Previous := Mode.Get("choices", "")
		Keys := Map(), Owned := []
		for Expected in Corpus["modes"]
			Keys[Expected["value"]] := Expected["label_key"]
		Mode["choices"] := []
		for Value in Corpus["reordered_values"]
			Mode["choices"].Push(Map("value", Value, "i18n", Keys[Value]))
		try {
			Row := _LAG_NativeModeRow(Owned)
			for Index, Value in Corpus["reordered_values"]
				AssertEqual(t(Keys[Value]), Row["items"][Index]["label"], "the declaration owns actual native order")
			_LLM_Agent_CommitFn := (*) => false
			AssertFalse(Row["items"][2]["action"].Call(), "the actual transaction refuses Off")
			AssertEqual("action", _LLM_Menu["agent_mode"], "runtime state remains unchanged")
			AssertEqual(0, Fx.Commits.Length, "no write is acknowledged")
			AssertEqual(0, Fx.Rebuilds, "a refused native choice never redraws as success")
		} finally {
			Mode["choices"] := Previous
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared mode declaration controls native rows without bypassing refusal", _LAG_ModeMenuSharedDeclaration)

_LAG_ModeRow() {
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		Owned := []
		try {
			Row := _LAG_NativeModeRow(Owned)
			AssertEqual(StrReplace(t("menu.agent.mode_title"), "{1}", t("menu.agent.mode_action")), Row["label"],
				"the current mode")
			AssertEqual(3, Row["items"].Length, "three modes")
			AssertTrue(Row["items"][2]["checked"] && !Row["items"][1]["checked"] && !Row["items"][3]["checked"],
				"the current one checked")
			Row["items"][3]["action"].Call()
			AssertEqual("action", _LLM_Menu["agent_mode"], "auto is refused without System 1")
			AssertEqual(t("llm.agent.no_system1"), _LPP_PendingNotice(), "with its notice")
			AssertEqual(0, Fx.Commits.Length, "and nothing is stored")
			AssertEqual(0, Fx.Rebuilds, "a refused automatic mode never redraws as success")
			_LLM_Menu["agent_system1"] := "cerebras"
			AssertTrue(LLM_Agent_ToggleAuto(), "the toggle turns the automatic mode on")
			AssertEqual("auto", _LLM_Menu["agent_mode"], "auto")
			AssertEqual(t("llm.agent.auto_on"), _LPP_PendingNotice(), "with its notice")
			AssertTrue(LLM_Agent_ToggleAuto(), "then back")
			AssertEqual("action", _LLM_Menu["agent_mode"], "to on action")
			AssertEqual(t("llm.agent.auto_off"), _LPP_PendingNotice(), "with its notice")
			_LAG_NativeModeRow(Owned)["items"][1]["action"].Call()
			AssertEqual("off", _LLM_Menu["agent_mode"], "the off row turns the agent off")
			AssertTrue(LLM_Agent_ToggleAuto(), "from off the toggle goes to auto")
			AssertEqual("auto", _LLM_Menu["agent_mode"], "auto")
			Row := _LLM_Agent_AppsRow()
			AssertEqual(StrReplace(t("menu.agent.disabled_apps"), "{1}", 0), Row["label"], "no excluded application")
		} finally {
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
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

; The menu's API entry for TypeSafe, whose key System 1 borrows for Jev.
_LAG_JevEntry() {
	return Map("Id", "typesafe-a", "Provider", "typesafe", "BaseUrl", "https://typesafe.invalid/v1/systemone",
		"Token", "key-t", "Model", "jev-latest")
}

; The menu's API entry for Backboard.
_LAG_BackboardEntry() {
	return Map("Id", "backboard-a", "Provider", "backboard", "BaseUrl", "https://backboard.invalid/api",
		"Token", "key-b", "Model", "openai/gpt-4o-mini")
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
	global _LLM_Remote_PostBodyFn, _LLM_Remote_BackboardAssistants
	Saved := {
		Locale: _I18nLocale, Remote: _LLM_Vision_RemoteTransport, Ollama: _LLM_Vision_OllamaTransport,
		Prompt: _LLM_Agent_PromptFn, Context: _LLM_Agent_ContextProbe, Source: _LLM_Agent_SourceProbe,
		Connector: _LLM_Agent_ConnectorFn, Schedule: _LLM_Agent_ScheduleFn, Reader: _LLM_Agent_StateReader,
		Writer: _LLM_Agent_StateWriter, Secure: _LLM_Agent_SecureFieldFn, Commit: _LLM_Agent_CommitFn,
		Rebuild: _LLM_Agent_RebuildFn, Generation: _LLM_Agent_Generation, Auto: _LLM_Agent_Auto,
		Learning: _LLM_Agent_Learning, Tools: _LLM_AgentConnector_Tools, List: _LLM_AgentConnector_ListFn,
		Ensure: _LLM_AgentConnector_EnsureDirFn, Visible: _Stub_LlmTooltipVisible,
		Presented: _Stub_LlmPresentedRecord, Post: _LLM_Remote_PostBodyFn,
		Assistants: _LLM_Remote_BackboardAssistants
	}
	Fx := { Remote: [], Ollama: [], Posts: [], Connector: [], ConnectorResult: Map("ok", true, "path", "fake"),
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
		_LLM_Remote_PostBodyFn := _LRF_FakePost.Bind(Fx)
		_LLM_Remote_BackboardAssistants := Map()
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
		_LLM_Remote_PostBodyFn := Saved.Post
		_LLM_Remote_BackboardAssistants := Saved.Assistants
	}
	_Inner(Calls, Lines, Sent) {
		global _LLM_Engine, _LLM_Menu
		; The agent borrows the AI menu's entries, which it owns even while the AI is off
		for Entry in [_LAG_CerebrasEntry(), _LAG_JevEntry(), _LAG_BackboardEntry()] {
			_LLM_Menu["api_entries"].Push(Entry)
			_LLM_Engine["api_entries"].Push(Entry.Clone())
		}
		; The prediction engine's requests, which the agent's scenarios expect none of
		Fx.Predictions := Calls
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
		_LLM_Menu["agent_system2"] := "anthropic"
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "a provider without an API entry")
		AssertEqual(t("llm.agent.no_system2"), _LPP_PendingNotice(), "is not a usable System 2")
		_LLM_Menu["agent_system2"] := "typesafe"
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "a decisions provider cannot write actions")
		AssertEqual(t("llm.agent.no_system2"), _LPP_PendingNotice(), "the same notice")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "answers typed questions only"), "and the log says why")
		_LLM_Menu["agent_system2"] := "cerebras"
		Suspend(true)
		try AssertFalse(_LAG_Invoke("llm_agent_selection"), "paused, nothing runs")
		finally Suspend(false)
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "Manual prediction refused (paused)"), "and the pause is logged")
		AssertEqual(0, Fx.Remote.Length, "no request left")
		AssertEqual(0, Fx.Prompts.Length, "and no dialog opened")
	}
}
Test("LLM agent: no usable System 2, an agent off or a pause refuse with their notice", _LAG_Refusals)

; The agent never uses the AI menu's prediction backend: the AI switched off
; or its backend not ready refuse nothing.
_LAG_AiMenuOffDoesNotRefuse() {
	Screen := _LTN_Screen(LAG_SELECTION)
	_LAG_Run(_LAG_Menu("action", "", "cerebras", false), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		AssertTrue(_LAG_Invoke("llm_agent_selection"), "the AI menu is off, the agent still runs")
		AssertEqual(1, Fx.Remote.Length, "System 2 is asked")
		AssertEqual("cerebras", Fx.Remote[1]["resolved"]["Provider"], "with its own provider's key")
		_LLM_Menu["enabled"] := true
		_LLM_Menu["api_entry_id"] := "missing"
		Fx.PromptAnswers.Push(Map("ok", true, "value", "réunion demain"))
		AssertTrue(_LAG_Invoke("llm_agent_command"), "a prediction backend not ready refuses nothing either")
		AssertEqual(2, Fx.Remote.Length, "the command is sent")
	}
}
Test("LLM agent: the actions run with the AI menu off or its backend not ready", _LAG_AiMenuOffDoesNotRefuse)

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





; =====================================================
; =====================================================
; ======= 8/ Providers: Jev, Backboard, choices =======
; =====================================================
; =====================================================

_LAG_BackendChoices() {
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Positions := Map("agent_system1", Map(), "agent_system2", Map())
		for Key, Found in Positions {
			for Choice in LLM_Agent_BackendChoices(Key)
				Found[Choice["value"]] := A_Index
		}
		System1 := Positions["agent_system1"]
		System2 := Positions["agent_system2"]
		AssertTrue(System1.Has("typesafe") && System1.Has("openrouter_jev"), "Jev is offered as System 1")
		AssertFalse(System2.Has("typesafe") || System2.Has("openrouter_jev"), "never as System 2")
		for ProviderId in ["openrouter", "groq", "together", "fireworks", "backboard"]
			AssertTrue(System1.Has(ProviderId) && System2.Has(ProviderId), ProviderId . " serves both systems")
		Previous := 0
		for ProviderId in LLM_API_PROVIDER_ORDER {
			AssertTrue(System1[ProviderId] > Previous, ProviderId . " keeps provider_order's place")
			Previous := System1[ProviderId]
		}
		AssertThrows(() => LLM_Agent_BackendChoices("agent_system3"), "an unknown system is refused")
		Row := _LLM_Agent_SystemRow("agent_system1")
		AssertEqual(System1.Count + 3, Row["items"].Length, "System 1's submenu lists its own backends")
		Row := _LLM_Agent_SystemRow("agent_system2")
		AssertEqual(System2.Count + 3, Row["items"].Length, "System 2's lists only chat backends")
		AssertEqual(LLM_API_PROVIDERS["typesafe"]["Label"], LLM_Agent_BackendLabel("typesafe"), "Jev keeps its label")
	}
}
Test("LLM agent: Jev is offered as System 1 only, every chat provider as both", _LAG_BackendChoices)

; The Jev answer of the triage fixtures, with or without a stated choice.
_LAG_JevAnswers(Choice := "") {
	return '{"intent":{"type":"choice",' . (Choice != "" ? '"choice":"' . Choice . '",' : "")
		. '"probabilities":{"calendar":0.9,"reminder":0.05,"none":0.05}}}'
}

_LAG_JevThroughDecisions() {
	_LAG_Run(_LAG_Menu("auto", "typesafe", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Config := LLM_Agent_Config()
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		AssertTrue(_LAG_Type(Fx, LAG_TYPED).Call(), "the pause triages through Jev")
		AssertEqual(0, Fx.Remote.Length, "no chat request")
		AssertEqual(1, Fx.Posts.Length, "one decisions request")
		Post := Fx.Posts[1]
		AssertEqual(_LAG_JevEntry()["BaseUrl"], Post["url"], "to the entry's full endpoint")
		AssertContains(_LLMRemote_BuildCurlConfig(Post["resolved"]["Format"], Post["resolved"]["Token"], Post["url"]),
			"Authorization: Bearer key-t", "with the key as a Bearer")
		Expected := LLM_RemoteFormats_DecisionsBody("jev-latest", "App: Slack`nText: " . LAG_SELECTION,
			LLM_Agent_JevQuestions(Config))
		AssertEqual("", _LVS_DeepEqual(JsonParse(LLM_RemoteFormats_Encode(Expected)), Post["body"]),
			"asking the triage question about the application and the sentence")
		Post["on_success"].Call('{"answers":' . _LAG_JevAnswers("calendar") . ',"model":"jev-latest"}')
		AssertEqual(1, Fx.Remote.Length, "the chosen intent wakes System 2")
		AssertEqual(_LAG_System2Prompt("typing", "Slack"), _LAG_Request(Fx.Remote[1])["system"],
			"about what is being typed")

		AssertTrue(_LAG_Type(Fx, "Autre chose : rappelle-moi le garage demain matin").Call(), "another sentence")
		Fx.Posts[2]["on_success"].Call('{"answers":' . _LAG_JevAnswers() . '}')
		AssertEqual(2, Fx.Remote.Length, "without a choice, the most probable intent wakes System 2")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "garage"), "the sentence is never logged")
	}
}
Test("LLM agent: System 1 asks Jev through a decisions provider", _LAG_JevThroughDecisions)

_LAG_JevThroughBackboard() {
	_LAG_Run(_LAG_Menu("auto", "backboard|typesafe/jev-latest", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Config := LLM_Agent_Config()
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		Answers := _LAG_JevAnswers("calendar")
		Locations := [
			["system_one", "Envoie le devis à Paul demain matin", '{"system_one":{"answers":' . Answers . '},"thread_id":"t"}'],
			["answers", "Réunion avec Claire vendredi à midi", '{"answers":' . Answers . ',"thread_id":"t"}'],
			["content", "Rappelle-moi le dentiste lundi soir",
				'{"content":' . JsonStringLiteral('{"answers":' . Answers . '}') . ',"thread_id":"t"}']
		]
		for Index, Location in Locations {
			Before := Fx.Posts.Length
			AssertTrue(_LAG_Type(Fx, Location[2]).Call(), Location[1] . ": the pause triages through Backboard")
			if (Index == 1) {
				AssertEqual(Before + 1, Fx.Posts.Length, "the first triage creates the assistant")
				AssertContains(Fx.Posts[Before + 1]["url"], "/assistants", "at /assistants")
				Fx.Posts[Before + 1]["on_success"].Call('{"assistant_id":"asst_7"}')
			}
			AssertEqual(Before + (Index == 1 ? 2 : 1), Fx.Posts.Length, Location[1] . ": then one message")
			Message := Fx.Posts[Fx.Posts.Length]
			AssertContains(Message["url"], "/threads/messages", Location[1] . ": on a new thread")
			Body := Message["body"]
			AssertEqual("", _LVS_DeepEqual(JsonParse(LLM_RemoteFormats_Encode(LLM_Agent_JevQuestions(Config))),
				Body["system_one"]["questions"]), Location[1] . ": the questions ride system_one")
			AssertEqual("App: Slack`nText: " . Location[2], Body["content"], Location[1] . ": about the sentence")
			AssertEqual("", Body["system_prompt"], Location[1] . ": without a system prompt")
			AssertEqual("typesafe", Body["llm_provider"], Location[1] . ": Jev's provider")
			AssertEqual("jev-latest", Body["model_name"], Location[1] . ": and model")
			AssertEqual("asst_7", Body["assistant_id"], Location[1] . ": the assistant is reused")
			RemoteBefore := Fx.Remote.Length
			Message["on_success"].Call(Location[3])
			AssertEqual(RemoteBefore + 1, Fx.Remote.Length, Location[1] . ": the triage wakes System 2")
			AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "read from Backboard's '" . Location[1] . "'"),
				Location[1] . ": where the answers were is logged")
		}
		AssertTrue(_LAG_Type(Fx, "Commande du papier pour le bureau").Call(), "a fourth sentence")
		RemoteBefore := Fx.Remote.Length
		Fx.Posts[Fx.Posts.Length]["on_success"].Call('{"content":"I think calendar.","status":"COMPLETED","thread_id":"t"}')
		AssertEqual(RemoteBefore, Fx.Remote.Length, "no answers, no System 2")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "top-level keys: content, status, thread_id"),
			"a miss names the answer's top-level keys")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "I think"), "never its content")
	}
}
Test("LLM agent: System 1 asks Jev through Backboard and logs where the answers were", _LAG_JevThroughBackboard)

_LAG_System2ThroughBackboard() {
	_LAG_Run(_LAG_Menu("action", "", "backboard"), _LTN_Screen(LAG_SELECTION), _Body)
	_Body(Fx, Lines, Sent) {
		Config := LLM_Agent_Config()
		AssertTrue(_LAG_Invoke("llm_agent_selection"), "the selection goes to Backboard")
		Fx.Posts[1]["on_success"].Call('{"assistant_id":"asst_2"}')
		Body := Fx.Posts[2]["body"]
		AssertEqual(_LAG_System2Prompt("selection"), Body["system_prompt"], "with the System 2 prompt")
		AssertEqual("SOURCE:`n" . LAG_SELECTION, Body["content"], "the selection is the message")
		AssertEqual("openai", Body["llm_provider"], "the entry's default model's provider")
		Fx.Posts[2]["on_success"].Call('{"content":' . JsonStringLiteral(LAG_ANSWER) . ',"status":"COMPLETED"}')
		AssertEqual(2, _LPP_LastFinalRender().slots.Length, "its actions are offered")
	}
}
Test("LLM agent: System 2 chats through Backboard", _LAG_System2ThroughBackboard)





; ===============================================
; ===============================================
; ======= 9/ The automatic mode's surface =======
; ===============================================
; ===============================================

_LAG_AutoOverPrediction() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Engine, _Stub_LlmTooltipCalls, _Stub_LlmPresentedRecord, _TooltipActiveSurface
		global _LLM_Agent_Generation
		Fx.App := "Slack"
		TooltipHide("AgentTest", true)
		_LLM_Engine["explicit_request_id"] := 0
		Pause := _LAG_Type(Fx, LAG_TYPED)
		; The automatic prediction appears before the pause ends
		LLM_Tooltip_Show(["demain"], 1, true, Map("offer_id", 41))
		AssertTrue(Pause.Call(), "an automatic prediction tooltip does not hold the triage back")
		Fx.Remote[1]["on_success"].Call("INTENT: calendar`nPROBABILITY: 0.9")
		AssertEqual(2, Fx.Remote.Length, "System 2 is asked")
		Calls := _Stub_LlmTooltipCalls.Length
		Fx.Remote[2]["on_success"].Call(LAG_ANSWER)
		AssertTrue(_Stub_LlmTooltipCalls.Length > Calls && _Stub_LlmTooltipCalls[Calls + 1].HasOwnProp("hide"),
			"the prediction is dismissed")
		AssertEqual("agent_" . _LLM_Agent_Generation, _Stub_LlmPresentedRecord.Lifecycle.OfferId,
			"and the actions take its place")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "replace the prediction tooltip"), "which is logged")

		; A prediction the user asked for holds the surface
		LLM_Tooltip_Show(["demain"], 1, true, Map("offer_id", 42))
		_LLM_Engine["explicit_request_id"] := 42
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "an explicit prediction holds it")
		_LLM_Engine["explicit_request_id"] := 0
		; Another AI action's tooltip too
		LLM_Tooltip_Show(["x"], 1, true, Map("offer_id", "vision_3"))
		AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "another AI action's tooltip holds it")
		; A hotstring tooltip still does, over an automatic prediction
		LLM_Tooltip_Show(["demain"], 1, true, Map("offer_id", 43))
		_TooltipActiveSurface := {}
		try AssertFalse(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(), "a hotstring tooltip holds it")
		finally _TooltipActiveSurface := 0
		AssertEqual(2, Fx.Remote.Length, "none of these sent anything")
		AssertTrue(_LAG_Type(Fx, "Envoie le devis à Paul demain").Call(),
			"the automatic prediction alone lets it through")
	}
}
Test("LLM agent: the automatic mode triages over an automatic prediction and replaces it",
	_LAG_AutoOverPrediction)

_LAG_ManualPredictionIsExplicit() {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Engine, _LLM_Bridge_Buffer
		_LLM_Bridge_Buffer := "On se voit"
		AssertTrue(LLM_Menu_TriggerPrediction((Context) => _LLM_Engine["request_id"] := 77),
			"a manual prediction is requested")
		AssertEqual(77, _LLM_Engine["explicit_request_id"], "and marked as asked for")
		AssertFalse(_LLM_Agent_IsAutoPrediction({ Lifecycle: { OfferId: 77 } }), "so its tooltip is no automatic one")
		AssertTrue(_LLM_Agent_IsAutoPrediction({ Lifecycle: { OfferId: 78 } }), "unlike the next automatic one")
		AssertFalse(_LLM_Agent_IsAutoPrediction(0), "no tooltip is none")
	}
}
Test("LLM agent: a manual prediction's tooltip is not an automatic one", _LAG_ManualPredictionIsExplicit)

; A repeating timer would tick on the keystroke thread: the agent's scheduler
; takes one-shots and cancels only (test_fast_timer_inventory reads its source).
_LAG_SchedulerIsOneShot() {
	AssertThrows(() => _LLM_Agent_Schedule((*) => 0, 250), "a repeating period is refused")
	AssertThrows(() => _LLM_Agent_Schedule((*) => 0, "-5"), "a period is an integer")
}
Test("LLM agent: the agent's timers are one-shots", _LAG_SchedulerIsOneShot)





; ======================================================
; ======================================================
; ======= 10/ The automatic mode with the AI off =======
; ======================================================
; ======================================================

; Runs Body() with the prediction bridge inactive, as the AI menu's switch
; leaves it, and its agent-only feed and prediction state put back afterwards.
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


; Both native systems consume one independently authored shared Off declaration.
_LAG_SystemOffCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_system_off.json", "UTF-8"))
}

; Observe the actual native system submenu and its dispatcher-owned first row.
_LAG_NativeSystemOffRow(System, Owned) {
	global _MenuDispatchCallbacks
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	Position := System == "system1" ? 2 : 3
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr")
	Assert(Handle != 0, "each actual system owns its native child menu")
	Sub := MenuFromHandle(Handle)
	Id := DllCall("GetMenuItemID", "ptr", Handle, "int", 0, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the actual Off row keeps its native dispatcher")
	return Map("label", _CTC_LabelAt(Sub, 0), "checked", _CTC_IsChecked(Sub, 0),
		"action", _MenuDispatchCallbacks[Id])
}

_LAG_SystemOffSharedRow() {
	Corpus := _LAG_SystemOffCorpus()
	for Vector in Corpus["states"] {
		_LAG_Run(_LAG_Menu("action", Vector["spec"], Vector["spec"]), _LTN_Screen(""), _Body.Bind(Corpus, Vector))
		_Body(Corpus, Vector, Fx, Lines, Sent) {
			Owned := []
			try {
				for System in Corpus["systems"] {
					Off := _LAG_NativeSystemOffRow(System, Owned)
					AssertEqual(t(Corpus["label_key"]), Off["label"], "the same canonical Off label owns both systems")
					AssertEqual(Vector["checked"], Off["checked"], "native checked state stays unchanged")
					AssertTrue(HasMethod(Off["action"], "Call"))
				}
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
Test("LLM agent: shared system Off rows replay independent native states (agent-system-off)", _LAG_SystemOffSharedRow)

_LAG_SystemOffOwnerRefusal() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn
		Corpus := _LAG_SystemOffCorpus()
		Declaration := _MR_GetManifestRoot()["agent_system_controls"][1]
		Label := Declaration["i18n"]
		Declaration["i18n"] := Corpus["mutated_label_key"]
		Commit := _LLM_Agent_CommitFn
		Owned := []
		try {
			Off := _LAG_NativeSystemOffRow("system1", Owned)
			AssertEqual(t(Corpus["mutated_label_key"]), Off["label"], "the actual child follows shared label changes")
			_LLM_Agent_CommitFn := (*) => false
			AssertFalse(Off["action"].Call())
			AssertEqual("cerebras", _LLM_Menu["agent_system1"])
			AssertEqual("cerebras", _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds, "a refused transaction cannot refresh as success")
			_LLM_Agent_CommitFn := Commit
			AssertTrue(Off["action"].Call(), "the retained callback retries through its actual owner")
			AssertEqual("", _LLM_Menu["agent_system1"])
			AssertEqual("cerebras", _LLM_Menu["agent_system2"])
			AssertEqual(1, Fx.Rebuilds)
			AssertFalse(Off["action"].Call(), "Windows keeps its existing already-Off no-op policy")
			AssertEqual(1, Fx.Rebuilds)
		} finally {
			Declaration["i18n"] := Label
			_LLM_Agent_CommitFn := Commit
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared system Off preserves transaction refusal and no-op (agent-system-off)", _LAG_SystemOffOwnerRefusal)


; Independent model-control identity and caption; never emitted by the generator.
_LAG_SystemModelCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_system_model.json", "UTF-8"))
}

; Read the actual last native child and its dispatcher-owned callback.
_LAG_NativeSystemModelRow(System, Owned) {
	global _MenuDispatchCallbacks
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	Position := System == "system1" ? 2 : 3
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr")
	Assert(Handle != 0, "the actual system owns its native submenu")
	Sub := MenuFromHandle(Handle)
	Count := DllCall("GetMenuItemCount", "ptr", Handle, "int")
	Assert(Count >= 3, "the model row follows the backend choices")
	Id := DllCall("GetMenuItemID", "ptr", Handle, "int", Count - 1, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the model command keeps the real dispatcher")
	return Map("label", _CTC_LabelAt(Sub, Count - 1), "action", _MenuDispatchCallbacks[Id])
}

_LAG_SystemModelSharedOwner() {
	Corpus := _LAG_SystemModelCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn
		Declaration := _MR_GetManifestRoot()[Corpus["section"]][2]
		Label := Declaration["i18n"]
		Commit := _LLM_Agent_CommitFn
		Owned := []
		try {
			for System in Corpus["systems"] {
				Model := _LAG_NativeSystemModelRow(System, Owned)
				AssertEqual(StrReplace(t(Corpus["label_key"]), "{1}", Corpus["model"]), Model["label"])
			}
			Declaration["i18n"] := Corpus["mutated_label_key"]
			Model := _LAG_NativeSystemModelRow("system1", Owned)
			AssertEqual(StrReplace(t(Corpus["mutated_label_key"]), "{1}", Corpus["model"]), Model["label"],
				"the actual native child follows the shared label")
			Fx.PromptAnswers.Push(Map("ok", true, "value", "changed-model"))
			_LLM_Agent_CommitFn := (*) => false
			AssertFalse(Model["action"].Call())
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Rebuilds)
			AssertEqual(0, Fx.Commits.Length)
			_LLM_Agent_CommitFn := Commit
			Fx.PromptAnswers.Push(Map("ok", true, "value", "changed-model"))
			AssertTrue(Model["action"].Call())
			AssertEqual("cerebras|changed-model", _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(1, Fx.Rebuilds)
		} finally {
			Declaration["i18n"] := Label
			_LLM_Agent_CommitFn := Commit
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared Model caption keeps actual dispatcher and refusal (agent-system-model)", _LAG_SystemModelSharedOwner)

_LAG_SystemModelSharedOrder() {
	Corpus := _LAG_SystemModelCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu
		Root := _MR_GetManifestRoot()
		Original := Root[Corpus["section"]]
		try {
			Root[Corpus["section"]] := [Original[2], Original[1],
				Map("type", "label", "id", "model_tail_marker", "i18n", "menu.agent.off")]
			Row := _LLM_Agent_SystemRow("agent_system1")
			Items := Row["items"]
			AssertEqual(StrReplace(t(Corpus["label_key"]), "{1}", Corpus["model"]), Items[Items.Length - 2]["label"])
			AssertTrue(Items[Items.Length - 1]["separator"])
			AssertEqual(t("menu.agent.off"), Items[Items.Length]["label"])
			Root[Corpus["section"]] := [Map("type", "---"),
				Map("type", "command", "id", "unowned_agent_model", "i18n", Corpus["label_key"])]
			AssertEqual(0, _LLM_Agent_SystemRow("agent_system1")["items"].Length,
				"an unowned canonical command refuses the whole native provider")
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
		} finally {
			Root[Corpus["section"]] := Original
		}
	}
}
Test("LLM agent: shared Model order and unowned-command refusal (agent-system-model)", _LAG_SystemModelSharedOrder)

; Independent prior physical captions; native renderer never emits this corpus.
_LAG_ModelCaptionGetterCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_linux_system_frames.json", "UTF-8"))
}

; Keep all native locale/cache identities and load the actual physical catalogue.
_LAG_WithModelCaptionLocale(Code, Body) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity
	Saved := Map("locale", _I18nLocale, "cache_set", IsSet(_I18nCache),
		"loaded_set", IsSet(_I18nCacheLoaded), "identity_set", IsSet(_I18nActiveCacheIdentity))
	if Saved["cache_set"]
		Saved["cache"] := _I18nCache
	if Saved["loaded_set"]
		Saved["loaded"] := _I18nCacheLoaded
	if Saved["identity_set"]
		Saved["identity"] := _I18nActiveCacheIdentity
	try {
		_I18nLocale := Code
		_I18nLoadFile(_I18nLocalePath(Code))
		AssertTrue(_I18nCacheLoaded, "the physical native locale loaded")
		Body.Call()
	} finally {
		_I18nLocale := Saved["locale"]
		_I18nCache := Saved["cache_set"] ? Saved["cache"] : unset
		_I18nCacheLoaded := Saved["loaded_set"] ? Saved["loaded"] : unset
		_I18nActiveCacheIdentity := Saved["identity_set"] ? Saved["identity"] : unset
	}
}

_LAG_ModelCaptionGetterLocale(Code) {
	Corpus := _LAG_ModelCaptionGetterCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Code, Corpus))
	_Body(Code, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale(Code, _Read.Bind(Corpus, Code, Fx))
		_Read(Corpus, Code, Fx) {
			Owned := []
			try {
				for System in ["system1", "system2"] {
					Model := _LAG_NativeSystemModelRow(System, Owned)
					AssertEqual(Corpus["locales"][Code]["windows_native_model"], Model["label"])
					AssertTrue(HasMethod(Model["action"], "Call"))
				}
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
for Code in ["ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
	"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh"]
	Test("LLM agent: canonical native Model caption " . Code . " (agent-model-caption-getter)",
		_LAG_ModelCaptionGetterLocale.Bind(Code))

_LAG_ModelCaptionGetterRefusal() {
	Corpus := _LAG_ModelCaptionGetterCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu
		Declaration := _MR_GetManifestRoot()["agent_system_model_controls"][2]
		Getter := Declaration["caption_getter"]
		try {
			Declaration["caption_getter"] := "foreign_model_caption"
			for Key in ["agent_system1", "agent_system2"]
				AssertEqual(0, _LLM_Agent_SystemRow(Key)["items"].Length)
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
		} finally {
			Declaration["caption_getter"] := Getter
		}
		Owned := []
		try {
			for System in ["system1", "system2"]
				AssertTrue(HasMethod(_LAG_NativeSystemModelRow(System, Owned)["action"], "Call"))
		} finally {
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: canonical Model getter refusal and native repair (agent-model-caption-getter)",
	_LAG_ModelCaptionGetterRefusal)


; Original 21-language provider captions captured before this shared migration.
_LAG_WindowsProviderCaptionCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_agent_fixed_captions_original.json", "UTF-8"))
}

_LAG_WindowsProviderCaptionLocale(Code) {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Code, Corpus))
	_Body(Code, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale(Code, _Read.Bind(Code, Corpus, Fx))
		_Read(Code, Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks
			Expected := Corpus["locales"][Code]
			Owned := []
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				AssertEqual(Expected["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Expected["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				AssertEqual(Expected["apps"]["2"], _CTC_LabelAt(Built, 5))
				CommandId := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", 5, "uint")
				AssertTrue(_MenuDispatchCallbacks.Has(CommandId), "the actual picker command reaches the native dispatcher")
				for System in ["system1", "system2"] {
					Row := _LLM_Agent_SystemRow("agent_" . System)
					AssertEqual(Expected["systems"][System]["cerebras"], Row["label"])
					Literal := _LLM_Agent_MenuSystemFrame("agent_" . System, Corpus["literal_native"], Row["items"])
					AssertEqual(Expected["systems"][System]["literal_native"], Literal["label"])
					AssertTrue(Literal["items"] == Row["items"], "the declared group keeps the finished native children")
					_LLM_Menu["agent_" . System] := ""
					AssertEqual(Expected["systems"][System]["off"], _LLM_Agent_SystemRow("agent_" . System)["label"])
				}
				for Count in Corpus["counts"] {
					Apps := []
					Loop Count
						Apps.Push("app" . A_Index . ".exe")
					_LLM_Menu["agent_disabled_apps"] := Apps
					Row := _LLM_Agent_AppsRow()
					AssertEqual(Expected["apps"]["" . Count], Row["label"])
					AssertTrue(HasMethod(Row["action"], "Call"))
				}
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
for Code in ["ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
	"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh"]
	Test("LLM agent: shared Windows fixed provider captions " . Code . " (agent-windows-provider-captions)",
		_LAG_WindowsProviderCaptionLocale.Bind(Code))

_LAG_WindowsProviderFrameRefusal() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Root := _MR_GetManifestRoot()
		Owned := []
		try {
			for Entry in [["agent_linux_system1_frame", "agent_system1", 2],
				["agent_linux_system2_frame", "agent_system2", 3],
				["agent_menu", "agent_disabled_apps", 5]] {
				Section := Entry[1], Key := Entry[2], Original := Root[Section]
				try {
					for Fault in ["missing", "foreign getter", "foreign row"] {
						if Key == "agent_disabled_apps"
							Root[Section] := _LAG_WindowsAppsCommandFaultRows(Original, Fault)
						else if Fault == "missing"
							Root.Delete(Section)
						else if Fault == "foreign getter" {
							Broken := Original[1].Clone()
							Broken["caption_getter"] := "unowned_agent_caption"
							Root[Section] := [Broken]
						} else
							Root[Section] := [Original[1], Map("type", "label", "id", "foreign_agent_tail", "i18n", "menu.agent.off")]
						Row := Key == "agent_disabled_apps" ? _LLM_Agent_AppsRow() : _LLM_Agent_SystemRow(Key)
						AssertFalse(Row, Fault . " refuses the actual provider before native append")
						Built := LLM_Agent_MenuBuild()
						Owned.Push(Built)
						AssertTrue(Built is Menu, "other actual Agent providers still build")
						AssertEqual(0, Fx.Commits.Length)
						AssertEqual(0, Fx.Rebuilds)
						Root[Section] := Original
					}
				} finally Root[Section] := Original
				Row := Key == "agent_disabled_apps" ? _LLM_Agent_AppsRow() : _LLM_Agent_SystemRow(Key)
				AssertTrue(Row is Map, "same canonical declaration repair restores its native provider")
			}
		} finally {
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared Windows provider declaration refusal and repair (agent-windows-provider-captions)",
	_LAG_WindowsProviderFrameRefusal)


; Observe the original applications leaf before promoting its dynamic route.
_LAG_OriginalAppsNativeFlags(HostState) {
	AssertTrue(HostState == "paused" || HostState == "off" || HostState == "operational",
		"the original native observation has an explicit host state")
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"], HostState != "off"),
		_LTN_Screen(""), _Body.Bind(HostState, Corpus))
	_Body(HostState, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(HostState, Corpus, Fx))
		_Read(HostState, Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
			SavedSuspend := A_IsSuspended, PickerOwner := AppPicker_Show
			HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
			Owned := [], PickerCalls := []
			try {
				Suspend(HostState == "paused")
				AssertEqual(HostState == "paused", A_IsSuspended ? true : false,
					"the host's real suspension state is established")
				AssertEqual(HostState != "off", _LLM_Menu["enabled"] ? true : false,
					"the actual prediction-menu switch establishes the off state")
				AssertEqual(HostState != "off", _LLM_Menu_BackendIsReadyForUse() ? true : false,
					"the unchanged native readiness reader admits the actual selected API entry")
				AssertEqual("action", LLM_Agent_Setting("agent_mode"),
					"the separately owned Agent mode stays fixed across host states")
				for Count in Corpus["counts"]
					_LAG_ObserveOriginalAppsNativeFlags(HostState, Count, Corpus, Owned, PickerCalls)
				AssertEqual(3, PickerCalls.Length, "each actual native apps callback reaches the picker boundary once")
				AssertEqual(0, Fx.Commits.Length, "observing the original leaf acknowledges no configuration writes")
				AssertEqual(0, Fx.Rebuilds, "the original observations do not request a tray rebuild")
				AssertEqual(0, Fx.Remote.Length, "the original menu observation starts no remote Agent request")
				AssertEqual(0, Fx.Ollama.Length, "the original menu observation starts no local Agent request")
				AssertEqual(0, Fx.Predictions.Length, "native readiness is read without a prediction request")
			} finally {
				if HadPickerCall
					Object.Prototype.DefineProp.Call(PickerOwner, "Call", PickerDescriptor)
				else if Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
					Object.Prototype.DeleteProp.Call(PickerOwner, "Call")
				for Built in Owned
					_CTC_ReleaseMenu(Built)
				Suspend(SavedSuspend)
			}
		}
	}
}

; Count is a helper parameter: no assertion captures an AHK loop variable.
_LAG_ObserveOriginalAppsNativeFlags(HostState, Count, Corpus, Owned, PickerCalls) {
	global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
	Apps := []
	Loop Count
		Apps.Push("app" . A_Index . ".exe")
	_LLM_Menu["agent_disabled_apps"] := Apps
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	AssertTrue(Built is Menu, HostState . ": the unchanged Agent builder returns a real native menu")
	AssertEqual(6, TrayMenuItemCount(Built), HostState . ": original mode, two systems, separators and apps order")
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 0, "ptr") != 0,
		HostState . ": the original mode submenu stays first")
	AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", 1, "uint", 0x400, "uint") & 0x800) != 0,
		HostState . ": the original separator follows the mode")
	AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
	AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 2, "ptr") != 0)
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 3, "ptr") != 0)
	AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", 4, "uint", 0x400, "uint") & 0x800) != 0,
		HostState . ": the original separator immediately precedes the apps command")
	AssertEqual(Corpus["locales"]["fr"]["apps"]["" . Count], _CTC_LabelAt(Built, 5),
		HostState . ": the native apps count caption matches the untouched independent original corpus")
	AssertEqual(0, DllCall("GetSubMenu", "ptr", Built.Handle, "int", 5, "ptr"),
		HostState . ": apps is an actual leaf, so its flags have no submenu-count high byte")
	Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 5, "uint", 0x400, "uint")
	AssertTrue(Flags != 0xFFFFFFFF, HostState . ": GetMenuState actually acquired the apps leaf")
	AssertEqual(0, Flags,
		HostState . ": original apps leaf is enabled, unchecked, non-default and not a separator")
	CommandId := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", 5, "uint")
	AssertTrue(CommandId != 0 && CommandId != 0xFFFFFFFF, "the actual apps leaf has a native command id")
	AssertTrue(_MenuDispatchCallbacks.Has(CommandId), "the original leaf has an actual dispatcher callback")
	AssertTrue(_MenuDispatchTokens.Has(CommandId), "the actual registration retains its dispatcher token")
	AssertTrue(_MenuDispatchOwnerHandles.Has(Built.Handle), "the dispatcher retains the actual native menu owner")
	AssertTrue(_MenuDispatchCallbacks[CommandId] is Func, "the original native apps callback is callable")

	; All flags above came from the unchanged native builder. Only the GUI boundary
	; is observed below, through the actual callback and LLM_Agent_OpenAppPicker.
	PickerOwner := AppPicker_Show, Before := PickerCalls.Length
	HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
	PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
	try {
		Object.Prototype.DefineProp.Call(PickerOwner, "Call", {Call: (ThisPicker, Options) =>
			(AssertTrue(ThisPicker == PickerOwner, "the actual immutable picker entry owns the GUI observer"), PickerCalls.Push(Options))})
		_MenuDispatchCallbacks[CommandId].Call()
		AssertEqual(Before + 1, PickerCalls.Length, "one actual apps callback opens its original picker boundary")
		Options := PickerCalls[PickerCalls.Length]
		AssertTrue(Options is Map)
		AssertEqual("agent:disabled_apps", Options["owner"], "the callback reaches the Agent apps picker owner")
		AssertEqual(Corpus["locales"]["fr"]["apps"]["" . Count], Options["title"],
			"the real picker entry preserves the original independent count caption")
		AssertTrue(Options["initial"] == Apps, "the real picker entry receives the actual native settings list")
		AssertTrue(Options["on_save"] == LLM_Agent_OnAppPickerSave,
			"the original dispatcher callback reaches the genuine Agent save callback")
	} finally {
		if HadPickerCall
			Object.Prototype.DefineProp.Call(PickerOwner, "Call", PickerDescriptor)
		else if Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			Object.Prototype.DeleteProp.Call(PickerOwner, "Call")
	}
}

Test("LLM agent: original native apps flags while paused (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("paused"))
Test("LLM agent: original native apps flags with prediction off (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("off"))
Test("LLM agent: original native apps flags with operational prediction (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("operational"))

; The Windows command is selected within its sole shared menu, preserving hidden
; Lua siblings and unrelated genuine Agent rows. Ambiguity duplicates that owner.
_LAG_WindowsAppsCommandFaultRows(Original, Fault) {
	Rows := []
	for Item in Original {
		if (Item is Map) && _MR_Get(Item, "id") == "agent_disabled_apps" && _MR_IsForAhk(Item) {
			if Fault == "missing"
				continue
			if Fault == "foreign getter" {
				Broken := Item.Clone()
				Broken["caption_getter"] := "unowned_agent_caption"
				Rows.Push(Broken)
			} else {
				Rows.Push(Item)
				Rows.Push(Item.Clone())
			}
		} else
			Rows.Push(Item)
	}
	return Rows
}

; The central leaf receiver reads the actual native count before finite withdrawal.
_LAG_AgentAppsCommandCustody() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			for Fault in ["before getter Call", "before callback Call", "before current Call", "before renderer Call", "before ambiguity",
				"after getter Call", "after callback Call", "after current Call", "after foreign getter",
				"after foreign callback", "after declaration", "after declaration Has", "after ambiguity", "integer count", "empty count"]
				_LAG_AgentAppsCommandFault(Fault, Corpus)
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
			AssertEqual(0, Fx.Remote.Length)
			AssertEqual(0, Fx.Ollama.Length)
		}
	}
}

; Fault is a fresh parameter; count reads never capture a mutable loop variable.
_LAG_AgentAppsCommandFault(Fault, Corpus) {
	global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens
	Root := _MR_GetManifestRoot(), Rows := Root["agent_menu"], SavedRows := Rows.Clone()
	Item := _MR_FindItemById("agent_menu", "agent_disabled_apps"), SavedItem := Item.Clone()
	Action := LLM_Agent_OpenAppPicker, NativeCount := _LLM_Agent_MenuDisabledAppsCount
	Native := Menu(), Calls := Map("count", 0, "foreign", 0)
	Commands := Map("agent_disabled_apps", Action)
	Getters := Map("agent_disabled_apps_count", ReadCount)
	PoisonedOwner := false, DescriptorName := "Call", HadCall := false, SavedCall := false, TeardownPrimary := false
	Poison(Owner, Name := "Call") {
		PoisonedOwner := Owner, DescriptorName := Name
		HadCall := Object.Prototype.HasOwnProp.Call(Owner, Name)
		SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, Name) : false
		Object.Prototype.DefineProp.Call(Owner, Name, {Call: (*) => (Calls["foreign"] += 1, false)})
	}
	Withdraw() {
		if InStr(Fault, "getter Call", true)
			Poison(ReadCount)
		else if InStr(Fault, "callback Call", true)
			Poison(Action)
		else if InStr(Fault, "current Call", true)
			Poison(_MR_NumberedCommandCurrent)
		else if Fault == "before renderer Call"
			Poison(_MR_RenderCommand)
		else if InStr(Fault, "ambiguity", true)
			Rows.Push(Item.Clone())
		else if Fault == "after foreign getter"
			Getters["agent_disabled_apps_count"] := () => (Calls["foreign"] += 1, "0")
		else if Fault == "after foreign callback"
			Commands["agent_disabled_apps"] := (*) => Calls["foreign"] += 1
		else if Fault == "after declaration"
			Item["caption_getter"] := "unowned_agent_caption"
		else if Fault == "after declaration Has"
			Poison(Item, "Has")
	}
	ReadCount() {
		Value := NativeCount.Call()
		Calls["count"] += 1
		if Fault == "integer count"
			return Integer(Value)
		if Fault == "empty count"
			return ""
		Withdraw()
		return Value
	}
	RestoreAuthorities() {
		if PoisonedOwner
			_LAG_AgentAppsRestoreDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall)
		Rows.Length := 0
		for Original in SavedRows
			Rows.Push(Original)
		Item.Clear()
		for Field, Value in SavedItem
			Item[Field] := Value
		Commands.Clear(), Commands["agent_disabled_apps"] := Action
		Getters.Clear(), Getters["agent_disabled_apps_count"] := ReadCount
	}
	try {
		_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
		AssertEqual("2", NativeCount.Call(), "the observer starts with the actual production count reader")
		RegisterMenuItem(Native, "Retained apps command destination", Action)
		Native.Check("Retained apps command destination")
		Native.Disable("Retained apps command destination")
		Before := _MR_FrameDestinationSnapshot(Native)
		BeforeRead := InStr(Fault, "before ", true) == 1
		if BeforeRead
			Withdraw()
		Added := MenuRenderer_AppendCommand(Native, "agent_menu", "agent_disabled_apps", Commands, Getters)
		RestoreAuthorities()
		AssertEqual(0, Added, Fault . ": the genuine central command refuses before its first native leaf write")
		AssertEqual(BeforeRead ? 0 : 1, Calls["count"], "withdrawal has the exact actual native-count boundary")
		AssertEqual(0, Calls["foreign"], "foreign getter, callback and currentness observers never execute")
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			"refusal preserves actual destination caption, command id, flags, callback and token")
		AssertEqual(1, TrayMenuItemCount(Native))
		if PoisonedOwner
			_LAG_AgentAppsAssertDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall)
		AssertTrue(_MR_FindItemById("agent_menu", "agent_disabled_apps") == Item,
			"the same sole Windows-visible shared command owns exact repair")
		AssertEqual(1, MenuRenderer_AppendCommand(Native, "agent_menu", "agent_disabled_apps", Commands,
			Map("agent_disabled_apps_count", NativeCount)), "exact repair enters the same actual command receiver")
		AssertEqual(2, TrayMenuItemCount(Native))
		AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Native, 1))
		AssertEqual(0, DllCall("GetSubMenu", "ptr", Native.Handle, "int", 1, "ptr"))
		AssertEqual(0, DllCall("GetMenuState", "ptr", Native.Handle, "uint", 1, "uint", 0x400, "uint"),
			"the repaired actual apps command keeps the original enabled unchecked leaf flags")
		Id := DllCall("GetMenuItemID", "ptr", Native.Handle, "int", 1, "uint")
		AssertTrue(Id != 0 && Id != 0xFFFFFFFF)
		AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Action,
			"the actual native repaired command retains the genuine picker callback")
		AssertTrue(_MenuDispatchTokens.Has(Id))
		AssertEqual(0, Calls["foreign"])
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_LAG_AgentAppsRunCleanup(TeardownPrimary, RestoreAuthorities, () => _CTC_ReleaseMenu(Native),
			() => PoisonedOwner ? _LAG_AgentAppsAssertDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall) : false)
	}
}

; This subject reaches the actual producer's command registration, not a fake builder.
_LAG_AgentAppsActualBuildRefusal() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			global _LLM_Menu
			Owner := _LLM_Agent_MenuDisabledAppsCount, Calls := Map("foreign", 0)
			HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
			SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
			Owned := [], TeardownPrimary := false
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Object.Prototype.DefineProp.Call(Owner, "Call", {Call: (*) => (Calls["foreign"] += 1, "2")})
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				_LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)
				_LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall)
				AssertTrue(Built is Menu)
				AssertEqual(0, Calls["foreign"], "the genuine Build never invokes a withdrawn actual count getter")
				AssertEqual(4, TrayMenuItemCount(Built), "the existing mode, separator and two actual system groups still build")
				AssertTrue(TrayMenuSubmenuHandle(Built.Handle, 0) != 0)
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				Repaired := LLM_Agent_MenuBuild()
				Owned.Push(Repaired)
				AssertEqual(6, TrayMenuItemCount(Repaired))
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Repaired, 5))
				AssertEqual(0, DllCall("GetMenuState", "ptr", Repaired.Handle, "uint", 5, "uint", 0x400, "uint"))
				AssertEqual(0, Calls["foreign"])
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
				AssertEqual(0, Fx.Remote.Length)
				AssertEqual(0, Fx.Ollama.Length)
			} catch as Failure {
				TeardownPrimary := Failure
				throw Failure
			} finally {
				Cleanup := [() => _LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)]
				for Built in Owned
					Cleanup.Push(_CTC_ReleaseMenu.Bind(Built))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall))
				_LAG_AgentAppsRunCleanup(TeardownPrimary, Cleanup*)
			}
		}
	}
}

_LAG_AgentAppsRestoreDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	if Object.Prototype.HasOwnProp.Call(Owner, Name)
		Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadProperty
		Object.Prototype.DefineProp.Call(Owner, Name, SavedDescriptor)
}
_LAG_AgentAppsAssertDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	AssertEqual(HadProperty, Object.Prototype.HasOwnProp.Call(Owner, Name))
	if !HadProperty
		return
	Actual := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	ExpectedCount := 0, ActualCount := 0
	for Field, Expected in ObjOwnProps(SavedDescriptor) {
		ExpectedCount += 1
		AssertTrue(Object.Prototype.HasOwnProp.Call(Actual, Field) && Actual.%Field% == Expected)
	}
	for Field in ObjOwnProps(Actual)
		ActualCount += 1
	AssertEqual(ExpectedCount, ActualCount)
}
_LAG_AgentAppsRunCleanup(OriginalFailure, Cleanup*) {
	CleanupFailure := false
	for Operation in Cleanup {
		try Operation.Call()
		catch as Failure {
			if !CleanupFailure
				CleanupFailure := Failure
		}
	}
	if !OriginalFailure && CleanupFailure
		throw CleanupFailure
}
Test("LLM agent: actual shared apps command custody, first leaf refusal and exact native repair (agent-apps-command)",
	_LAG_AgentAppsCommandCustody)
Test("LLM agent: actual Build rejects withdrawn native apps getter and repairs (agent-apps-command)",
	_LAG_AgentAppsActualBuildRefusal)

; Actual producer pre-entry callee authority, observed through its native result.
_LAG_AgentAppsActualBuildEntryRefusal() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens
			Owner := _MR_RenderCommand, Calls := Map("foreign", 0)
			HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
			SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
			PickerOwner := AppPicker_Show, PickerCalls := []
			HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
			Owned := [], TeardownPrimary := false
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Object.Prototype.DefineProp.Call(Owner, "Call", {Call: (*) => (Calls["foreign"] += 1, "2")})
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				_LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)
				_LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall)
				AssertTrue(Built is Menu)
				AssertEqual(0, Calls["foreign"], "the genuine Build rejects its actual renderer own Call before invoking a foreign callee")
				AssertEqual(4, TrayMenuItemCount(Built), "the existing mode, separator and two actual system groups still build")
				AssertTrue(TrayMenuSubmenuHandle(Built.Handle, 0) != 0)
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				Repaired := LLM_Agent_MenuBuild()
				Owned.Push(Repaired)
				AssertEqual(6, TrayMenuItemCount(Repaired))
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Repaired, 5))
				AssertEqual(0, DllCall("GetMenuState", "ptr", Repaired.Handle, "uint", 5, "uint", 0x400, "uint"))
				Id := DllCall("GetMenuItemID", "ptr", Repaired.Handle, "int", 5, "uint")
				AssertTrue(Id != 0 && Id != 0xFFFFFFFF)
				AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] is Func,
					"the repaired actual builder registers its genuine apps dispatcher callback")
				AssertTrue(_MenuDispatchTokens.Has(Id))
				Object.Prototype.DefineProp.Call(PickerOwner, "Call", {Call: (ThisPicker, Options) =>
					(AssertTrue(ThisPicker == PickerOwner), PickerCalls.Push(Options))})
				_MenuDispatchCallbacks[Id].Call()
				_LAG_AgentAppsRestoreDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)
				_LAG_AgentAppsAssertDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)
				AssertEqual(1, PickerCalls.Length, "the actual repaired native callback reaches the real GUI boundary once")
				AssertEqual("agent:disabled_apps", PickerCalls[1]["owner"])
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], PickerCalls[1]["title"])
				AssertTrue(PickerCalls[1]["initial"] == _LLM_Menu["agent_disabled_apps"])
				AssertTrue(PickerCalls[1]["on_save"] == LLM_Agent_OnAppPickerSave)
				AssertEqual(0, Calls["foreign"])
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
				AssertEqual(0, Fx.Remote.Length)
				AssertEqual(0, Fx.Ollama.Length)
			} catch as Failure {
				TeardownPrimary := Failure
				throw Failure
			} finally {
				Cleanup := [() => _LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall),
					() => _LAG_AgentAppsRestoreDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)]
				for Built in Owned
					Cleanup.Push(_CTC_ReleaseMenu.Bind(Built))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor))
				_LAG_AgentAppsRunCleanup(TeardownPrimary, Cleanup*)
			}
		}
	}
}

Test("LLM agent: actual Build guards renderer entry and repairs native apps dispatch (agent-apps-command)",
	_LAG_AgentAppsActualBuildEntryRefusal)


; System providers return DATA without acquiring a native destination or dispatch owner.
_LAG_SystemListData() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _MenuDispatchCallbacks, _MenuDispatchTokens
		Callbacks := _MenuDispatchCallbacks, Tokens := _MenuDispatchTokens
		SavedCallbacks := Callbacks.Clone(), SavedTokens := Tokens.Clone()
		for Key in ["agent_system1", "agent_system2"] {
			Rows := _LLM_Agent_MenuSystemRows(Key)
			AssertTrue(Rows is Array, "the genuine provider returns detached row DATA")
			AssertEqual(1, Rows.Length)
			AssertTrue(Rows[1] is Map)
			AssertEqual(_LLM_Agent_SystemRow(Key)["label"], Rows[1]["label"])
			AssertTrue(Rows[1]["items"] is Array, "the completed children remain DATA, not a native Menu")
		}
		AssertTrue(Callbacks == _MenuDispatchCallbacks && Tokens == _MenuDispatchTokens,
			"the actual producer preserves both held dispatcher owners")
		AssertEqual(SavedCallbacks.Count, Callbacks.Count, "DATA construction registers no native command")
		AssertEqual(SavedTokens.Count, Tokens.Count, "DATA construction registers no native token")
		for Id, Callback in SavedCallbacks
			AssertTrue(Callbacks.Has(Id) && Callbacks[Id] == Callback, "existing callbacks stay exact")
		for Id, Token in SavedTokens
			AssertTrue(Tokens.Has(Id) && Tokens[Id] == Token, "existing tokens stay exact")
		AssertEqual(0, Fx.Commits.Length)
		AssertEqual(0, Fx.Rebuilds)
	}
}
Test("LLM agent: genuine System list provider creates DATA without native dispatch effects (agent-system-list)",
	_LAG_SystemListData)

_LAG_SystemListReceiving() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			Owned := [], TeardownPrimary := false
			Item := _MR_FindItemById("agent_menu", "agent_system1")
			AssertTrue(Item is Map, "the genuine Windows declaration is uniquely visible")
			AssertEqual("list", Item["type"], "central list receiving is the actual production route")
			Platforms := Item["platforms"]
			Restore() {
				Item["platforms"] := Platforms
			}
			try {
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				AssertEqual(6, TrayMenuItemCount(Built), "the complete original mode/System/apps order stays native")
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				AssertTrue(TrayMenuSubmenuHandle(Built.Handle, 2) != 0 && TrayMenuSubmenuHandle(Built.Handle, 3) != 0,
					"the central renderer publishes both real completed native children")
				Item["platforms"] := ["hs"]
				Refused := LLM_Agent_MenuBuild()
				Owned.Push(Refused)
				AssertEqual(5, TrayMenuItemCount(Refused), "a withdrawn Windows list cannot execute through a dynamic handler")
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Refused, 2),
					"the independent current System remains in its declared native position")
				Restore()
				Repaired := LLM_Agent_MenuBuild()
				Owned.Push(Repaired)
				AssertEqual(6, TrayMenuItemCount(Repaired), "repair reopens the same genuine declaration route")
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Repaired, 2))
				AssertTrue(Item["platforms"] == Platforms, "the exact original declaration owner is restored")
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
			} catch as Failure {
				TeardownPrimary := Failure
				throw Failure
			} finally {
				Cleanup := [Restore]
				for Built in Owned
					Cleanup.Push(_CTC_ReleaseMenu.Bind(Built))
				_LAG_AgentAppsRunCleanup(TeardownPrimary, Cleanup*)
			}
		}
	}
}
Test("LLM agent: complete Build receives declared System lists and respects withdrawal/repair (agent-system-list)",
	_LAG_SystemListReceiving)
