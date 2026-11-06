; static/ergopti_plus/windows/tests/unit/modules/llm/actions/test_llm_agent.ahk

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
	global _LLM_Agent_System1Revision
	global _LLM_AgentConnector_Tools, _LLM_AgentConnector_ListFn, _LLM_AgentConnector_EnsureDirFn
	global _Stub_LlmTooltipVisible, _Stub_LlmPresentedRecord
	global _LLM_Remote_PostBodyFn, _LLM_Remote_BackboardAssistants
	Saved := {
		Locale: _I18nLocale, Remote: _LLM_Vision_RemoteTransport, Ollama: _LLM_Vision_OllamaTransport,
		Prompt: _LLM_Agent_PromptFn, Context: _LLM_Agent_ContextProbe, Source: _LLM_Agent_SourceProbe,
		Connector: _LLM_Agent_ConnectorFn, Schedule: _LLM_Agent_ScheduleFn, Reader: _LLM_Agent_StateReader,
		Writer: _LLM_Agent_StateWriter, Secure: _LLM_Agent_SecureFieldFn, Commit: _LLM_Agent_CommitFn,
		Rebuild: _LLM_Agent_RebuildFn, Generation: _LLM_Agent_Generation, Auto: _LLM_Agent_Auto, System1Revision: _LLM_Agent_System1Revision,
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
		_LLM_Vision_RemoteTransport := (Resolved, Url, Payload, OnSuccess, OnFail, CurrentFn) => Fx.Remote.Push(Map(
			"resolved", Resolved, "url", Url, "body", Payload, "on_success", OnSuccess, "on_fail", OnFail, "requester_current", CurrentFn))
		_LLM_Vision_OllamaTransport := (Payload, OnSuccess, OnFail, CurrentFn) => Fx.Ollama.Push(Map(
			"body", Payload, "on_success", OnSuccess, "on_fail", OnFail, "requester_current", CurrentFn))
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
		_LLM_Agent_System1Revision := Saved.System1Revision
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

; A native modal can admit a newer flow or commit a System 2 withdrawal.
; Its delayed answer must retain the original requester instead of replacing it.
_LAG_CommandModalCustody(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "cerebras"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_PromptFn, _LLM_Agent_CommitFn
		_LLM_Agent_PromptFn := Prompt
		Allowed := Mode == "unchanged" || Mode == "refused-write"
		Result := _LAG_Invoke("llm_agent_command")
		AssertEqual(Allowed || Mode == "newer-flow" ? 1 : 0, Fx.Remote.Length,
			"a withdrawn command dialog cannot dispatch its retained request")
		AssertEqual(Allowed, Result, "only an unchanged requester can send the typed command")
		AssertEqual(0, Fx.Ollama.Length)
		AssertEqual(0, Sent.Length)
		Prompt(Title, Text, Default) {
			switch Mode {
				case "mode-off": AssertTrue(LLM_Agent_SetMode("off"))
				case "mode-aba":
					AssertTrue(LLM_Agent_SetMode("off")), AssertTrue(LLM_Agent_SetMode("action"))
				case "source-off": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", ""))
				case "source-remote": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "local"))
				case "newer-flow": AssertTrue(_LAG_Invoke("llm_agent_selection"))
				case "refused-write":
					_LLM_Agent_CommitFn := (*) => false
					AssertFalse(LLM_Agent_SetMode("off"))
			}
			return Map("ok", true, "value", "create a meeting tomorrow")
		}
	}
}

for Mode in ["mode-off", "mode-aba", "source-off", "source-remote", "newer-flow", "unchanged", "refused-write"]
	Test("LLM agent: command dialog retains original requester " . Mode . " (agent-command-modal)", _LAG_CommandModalCustody.Bind(Mode))


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

; Nothing of the AI runs with its switch off, the manual agent included. It still
; never uses the prediction backend: that backend not ready refuses nothing.
_LAG_AiOffRefuses() {
	Screen := _LTN_Screen(LAG_SELECTION)
	_LAG_Run(_LAG_Menu("action", "", "cerebras", false), Screen, _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LOGGER_DEDUP_KEY
		; An earlier suite may have logged this very refusal within the dedup window.
		_LOGGER_DEDUP_KEY := ""
		AssertFalse(_LAG_Invoke("llm_agent_selection"), "the AI is off, the selection is refused")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(), "with the notice of the other AI actions")
		AssertEqual(0, Screen.Reads, "before anything is read")
		AssertFalse(_LAG_Invoke("llm_agent_command"), "the command too")
		AssertEqual(0, Fx.Prompts.Length, "no dialog opened")
		AssertEqual(0, Fx.Remote.Length, "no request left")
		AssertTrue(_LPP_LinesWith(Lines, "INFO", "Manual prediction refused (disabled)") > 0, "and logged")
		; The AI switch outranks the agent's own: its mode off is not what is told
		_LLM_Menu["agent_mode"] := "off"
		AssertFalse(_LAG_Invoke("llm_agent_selection"))
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(), "the AI switch is told first")
		_LLM_Menu["agent_mode"] := "action"
		_LLM_Menu["enabled"] := true
		_LLM_Menu["api_entry_id"] := "missing"
		AssertTrue(_LAG_Invoke("llm_agent_selection"), "switched on with no reload, its backend not ready refuses nothing")
		AssertEqual(1, Fx.Remote.Length, "System 2 is asked")
		AssertEqual("cerebras", Fx.Remote[1]["resolved"]["Provider"], "with its own provider's key")
	}
}
Test("LLM agent: the manual actions refuse with the AI off, not with its backend not ready (ai-off-picker)", _LAG_AiOffRefuses)

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


; Exercise accepted model JSON through the real action schema before rendering.
; Canonical line endings must not depend on how a JSON newline was spelled.
_LAG_LineBreakPayload(Connector, Mode) {
	Config := LLM_Agent_Config()
	switch Mode {
		case "lf-control":
			Escaped := "\n", IcsExpected := "first\nsecond", MailExpected := "first%0D%0Asecond"
		case "crlf-control":
			Escaped := "\r\n", IcsExpected := "first\nsecond", MailExpected := "first%0D%0Asecond"
		case "carriage":
			Escaped := "\r", IcsExpected := "first\nsecond", MailExpected := "first%0D%0Asecond"
		case "mixed":
			Escaped := "\r\nmiddle\rfinal\n"
			IcsExpected := "first\nmiddle\nfinal\nsecond"
			MailExpected := "first%0D%0Amiddle%0D%0Afinal%0D%0Asecond"
		case "literal-control":
			Escaped := "\\r", IcsExpected := "first\\rsecond", MailExpected := "first%5Crsecond"
		default:
			throw ValueError("Unknown agent payload line break mode")
	}
	Raw := Connector == "calendar"
		? '{"type":"calendar","title":"Fixture","start":"2026-10-01T14:00","notes":"first' . Escaped . 'second"}'
		: '{"type":"mail","subject":"Fixture","body":"first' . Escaped . 'second"}'
	Decoded := JsonParse(Raw)
	Action := LLM_Agent_ValidateAction(Config, Decoded, [], &Reason)
	AssertEqual("", Reason, "the actual schema accepts the genuinely decoded model field")
	AssertTrue(Action is Map)
	if Connector == "calendar" {
		AssertEqual(Decoded["notes"], Action["notes"], "validation must preserve the original admitted newline spelling")
		Payload := LLM_Agent_Ics(Config, Action, "owned-fixture", "20261105T000000Z")
		ExpectedRecord := "DESCRIPTION:" . IcsExpected . "`r`n"
		_TestPrint("# agent-payload-linebreak connector=" . Connector . " mode=" . Mode
			. " exact_record=" . !!InStr(Payload, ExpectedRecord, true)
			. " lone_break=" . !!RegExMatch(Payload, "(?<!\r)\n|\r(?!\n)"))
		AssertFalse(RegExMatch(Payload, "(?<!\r)\n|\r(?!\n)"), "all physical iCalendar delimiters must be complete CRLF pairs")
		AssertTrue(InStr(Payload, ExpectedRecord, true), "each accepted logical newline must be escaped within its original TEXT record")
	} else {
		AssertEqual(Decoded["body"], Action["body"])
		Payload := LLM_Agent_Mailto(Action)
		Expected := "mailto:?subject=Fixture&body=" . MailExpected
		_TestPrint("# agent-payload-linebreak connector=" . Connector . " mode=" . Mode . " uri=" . Payload)
		AssertEqual(Expected, Payload, "each accepted mail body newline must encode the complete RFC6068 CRLF sequence")
	}
}
for _LAG_LB_Connector in ["calendar", "mail"] {
	for _LAG_LB_Mode in ["lf-control", "crlf-control", "carriage", "mixed", "literal-control"]
		Test("LLM agent payload line breaks: " . _LAG_LB_Connector . "/" . _LAG_LB_Mode . " (agent-payload-line-breaks)",
			_LAG_LineBreakPayload.Bind(_LAG_LB_Connector, _LAG_LB_Mode))
}

; Simulates two sequential clock observations across a second boundary; it
; does not change the Windows clock, registry or configured time zone.
class _TZF_ClockProbe {
	__New(UtcStamp) {
		this.UtcStamp := UtcStamp, this.LocalCalls := 0, this.UtcCalls := 0, this.OffsetCalls := 0
	}
	Local() {
		this.LocalCalls += 1
		return "20261104150059"
	}
	Utc() {
		this.UtcCalls += 1
		return this.UtcStamp
	}
	OffsetMinutesEast() {
		this.OffsetCalls += 1
		return 60
	}
}
_TZF_ContextFromMissingRegistry(Probe) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_VOLUME
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED", "_LOGGER_VOLUME"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_VOLUME := _LOGGER_VOLUME.Clone()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		; No key is created. The actual registry adapter must observe this missing
		; value before the real context producer follows its fallback branch.
		RegistryKey := "HKCU\Software\ErgoptiMissingTimeZone-" . DllCall("GetCurrentProcessId")
			. "-" . A_TickCount . "-" . Random(100000, 999999)
		Critical("Off")
		AssertFalse(Reg_TryRead(RegistryKey, "TimeZoneKeyName", &Ignored := ""),
			"the native registry read confirms the fallback value is absent")
		return _LLM_Agent_SystemContext(Probe, RegistryKey)
	} finally {
		Critical("On")
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		Critical(PreviousCritical)
	}
}
_TZF_ContextCase(UtcStamp, Label) {
	Probe := _TZF_ClockProbe(UtcStamp)
	Context := _TZF_ContextFromMissingRegistry(Probe)
	_TestAppendProgress("# agent timezone " . Label . " zone=" . Context["timezone"]
		. " local_reads=" . Probe.LocalCalls . " utc_reads=" . Probe.UtcCalls . " offset_reads=" . Probe.OffsetCalls)
	AssertTrue((Probe.LocalCalls == 1 && Probe.UtcCalls == 1 && Probe.OffsetCalls == 0)
		|| (Probe.LocalCalls == 0 && Probe.UtcCalls == 0 && Probe.OffsetCalls == 1),
		"the producer consulted exactly one clock strategy")
	AssertEqual("UTC+01:00", Context["timezone"], "the simulated UTC+1 offset remains one hour")
}
Test("agent context: same-second timezone fallback (agent-timezone-native-fallback-control)",
	_TZF_ContextCase.Bind("20261104140059", "same-second"))
Test("agent context: timezone fallback across sampled second (agent-timezone-native-fallback-boundary)",
	_TZF_ContextCase.Bind("20261104140100", "boundary"))

; Independent native control: convert one UTC SYSTEMTIME to local time and
; compare the resulting FILETIMEs, without changing the OS clock or zone.
_TZF_ReferenceOffset() {
	Utc := Buffer(16, 0), LocalTime := Buffer(16, 0)
	UtcFile := Buffer(8, 0), LocalFile := Buffer(8, 0)
	DllCall("Kernel32\GetSystemTime", "Ptr", Utc)
	if !DllCall("Kernel32\SystemTimeToTzSpecificLocalTime", "Ptr", 0, "Ptr", Utc, "Ptr", LocalTime, "Int")
		throw OSError(A_LastError, "native UTC-to-local conversion")
	if !DllCall("Kernel32\SystemTimeToFileTime", "Ptr", Utc, "Ptr", UtcFile, "Int")
		throw OSError(A_LastError, "native UTC SYSTEMTIME conversion")
	if !DllCall("Kernel32\SystemTimeToFileTime", "Ptr", LocalTime, "Ptr", LocalFile, "Int")
		throw OSError(A_LastError, "native local SYSTEMTIME conversion")
	Ticks := NumGet(LocalFile, 0, "Int64") - NumGet(UtcFile, 0, "Int64")
	if Mod(Ticks, 600000000) != 0
		throw Error("The native time-zone offset was not an integral minute.")
	return Ticks // 600000000
}
_TZF_NativeOffsetControl() {
	Before := _TZF_ReferenceOffset()
	Actual := NativeTimeZoneOffsetMinutesEast()
	After := _TZF_ReferenceOffset()
	_TestAppendProgress("# agent timezone native-reference before=" . Before . " observed=" . Actual . " after=" . After)
	AssertEqual(Before, After, "the system time zone must remain stable during this observation")
	AssertTrue(Actual is Integer, "the native time-zone adapter must return an offset")
	AssertEqual(Before, Actual, "active bias agrees with an independent same-instant conversion")
}
Test("agent context: native active bias agrees with UTC-to-local conversion (agent-timezone-native-bias)", _TZF_NativeOffsetControl)

class _TZF_MissingOffset extends _TZF_ClockProbe {
	OffsetMinutesEast() {
		this.OffsetCalls += 1
		return ""
	}
}
_TZF_OffsetUnavailable() {
	Probe := _TZF_MissingOffset("20261104140100")
	Context := _TZF_ContextFromMissingRegistry(Probe)
	AssertEqual(1, Probe.OffsetCalls)
	AssertEqual(0, Probe.LocalCalls + Probe.UtcCalls, "an unavailable offset cannot fall back to torn samples")
	AssertEqual("", Context["timezone"], "an unavailable offset is not fabricated")
}
Test("agent context: unavailable timezone offset is not fabricated (agent-timezone-offset-refusal)", _TZF_OffsetUnavailable)


; Retained callbacks must not erase the cancellation capability of a newer
; pause. These units use the real agent and the existing scheduler port.
_LAPO_Sequence(Mode, Fx, Lines, Sent) {
	global _LLM_Agent_Auto
	Fx.App := "Slack"
	Gate := {Allowed: true}
	AssertTrue(LLM_Agent_OnTyping(LAG_TYPED, () => Gate.Allowed))
	Older := _LLM_Agent_Auto["timer"]
	AssertTrue(HasMethod(Older, "Call"))
	if Mode == "current" {
		AssertTrue(Older.Call())
		AssertEqual(0, _LLM_Agent_Auto["timer"])
		AssertEqual(1, Fx.Remote.Length, "the admitted pause must dispatch its genuine System 1 request")
		return
	}
	if Mode == "withdrawn" {
		Gate.Allowed := false
		AssertFalse(Older.Call())
		AssertEqual(0, _LLM_Agent_Auto["timer"], "a withdrawn current pause still retires its own capability")
		AssertEqual(0, Fx.Remote.Length)
		return
	}
	AssertTrue(LLM_Agent_OnTyping(LAG_TYPED . " later"))
	Newer := _LLM_Agent_Auto["timer"]
	AssertTrue(HasMethod(Newer, "Call") && Newer != Older)
	Before := Fx.Scheduled.Length
	Result := Older.Call()
	OwnerPreserved := _LLM_Agent_Auto["timer"] == Newer
	; Subsequent actual invalidation must retain the exact timer cancellation
	; operation, rather than merely changing a logical generation.
	LLM_Agent_InvalidateTyping()
	CancelledNewer := false
	for Index, Entry in Fx.Scheduled {
		if Index > Before && Entry["fn"] == Newer && Entry["period"] == 0
			CancelledNewer := true
	}
	_TestPrint("# agent-pause-owner result=" . Result . " newer_owner=" . OwnerPreserved
		. " cancelled_newer=" . CancelledNewer . " requests=" . Fx.Remote.Length)
	AssertFalse(Result)
	AssertTrue(OwnerPreserved, "a retired pause cannot erase the exact successor timer owner")
	AssertTrue(CancelledNewer, "the current pause must remain cancellable after a stale callback")
	AssertEqual(0, Fx.Remote.Length)
}
_LAPO_Case(Mode) {
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _LAPO_Sequence.Bind(Mode))
}
for _LAPO_Mode in ["stale", "current", "withdrawn"]
	Test("LLM agent pause ownership: " . _LAPO_Mode . " retains its exact cancellation capability (agent-pause-timer-owner)",
		_LAPO_Case.Bind(_LAPO_Mode))
