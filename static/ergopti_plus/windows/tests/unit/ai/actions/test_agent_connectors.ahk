; tests/unit/ai/actions/test_agent_connectors.ahk

; ==============================================================================
; MODULE: LLM Agent Connectors and Automatic Mode
; DESCRIPTION:
; The agent's connectors (Outlook and friends), automatic detection,
; learning, the Jev and Backboard providers and the automatic mode's
; surface.
; ==============================================================================

#Requires AutoHotkey v2.0





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
	global _LLM_AgentConnector_PublishFn, _LLM_AgentConnector_ListFn
	global _LLM_AgentConnector_EnsureDirFn, _LLM_AgentConnector_IdFn, _LLM_AgentConnector_Tools
	Saved := {
		Com: _LLM_AgentConnector_ComFn, Open: _LLM_AgentConnector_OpenFn, Launch: _LLM_AgentConnector_LaunchFn,
		Publish: _LLM_AgentConnector_PublishFn, List: _LLM_AgentConnector_ListFn,
		Ensure: _LLM_AgentConnector_EnsureDirFn, Id: _LLM_AgentConnector_IdFn, Tools: _LLM_AgentConnector_Tools
	}
	Fx := { Outlook: Outlook, ProgIds: [], Opened: [], Launched: [], Written: [], Deleted: [], Dirs: [] }
	try {
		_LLM_AgentConnector_ComFn := (ProgId) => (Fx.ProgIds.Push(ProgId), Fx.Outlook)
		_LLM_AgentConnector_OpenFn := (Target) => Fx.Opened.Push(Target)
		_LLM_AgentConnector_LaunchFn := (Argv) => Fx.Launched.Push(Argv)
		_LLM_AgentConnector_PublishFn := (Text) => (Fx.Written.Push(Map("path", "C:\synthetic-calendar\invitation.ics", "text", Text)), "C:\synthetic-calendar\invitation.ics")
		_LLM_AgentConnector_ListFn := (Dir) => ["C:\t\Envoyer la facture.ps1", "C:\t\Mode focus.cmd",
			"C:\t\notes.txt", "C:\t\Ouvrir le CRM.ahk"]
		_LLM_AgentConnector_EnsureDirFn := (Dir) => Fx.Dirs.Push(Dir)
		_LLM_AgentConnector_IdFn := () => Map("uid", "abc123@ergopti", "stamp", "20260929T120500Z")
		_LLM_AgentConnector_Tools := ""
		Body.Call(Fx)
	} finally {
		_LLM_AgentConnector_ComFn := Saved.Com
		_LLM_AgentConnector_OpenFn := Saved.Open
		_LLM_AgentConnector_LaunchFn := Saved.Launch
		_LLM_AgentConnector_PublishFn := Saved.Publish
		_LLM_AgentConnector_ListFn := Saved.List
		_LLM_AgentConnector_EnsureDirFn := Saved.Ensure
		_LLM_AgentConnector_IdFn := Saved.Id
		_LLM_AgentConnector_Tools := Saved.Tools
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
		AssertEqual("C:\synthetic-calendar\invitation.ics", Path,
			"the file is placed in its private directory")
		AssertEqual(LLM_Agent_Ics(Config, Action, "abc123@ergopti", "20260929T120500Z"), Fx.Written[1]["text"],
			"with the shared bytes")
		AssertEqual("", _LVS_DeepEqual([Path], Fx.Opened), "opened with the default handler")

		Mail := _LAG_Action('{"type":"mail","to":["paul@example.com"],"subject":"Devis","body":"Bonjour"}')
		Result := LLM_AgentConnector_Execute(Mail, Config)
		AssertTrue(Result["ok"] && Result["path"] == "mailto", "without Outlook, a mailto: link")
		AssertEqual(LLM_Agent_Mailto(Mail), Fx.Opened[2], "opened with the mail client")
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

/** Observes native launch identity while delegating the complete genuine argv. */
_LAGNN_Launch(State, Argv) {
	State.Attempts += 1
	State.Vector := Argv.Clone()
	State.Pid := AL_LaunchArgvStrict(Argv)
}

_LAGNN_ArgvReceipt(Text) {
	Receipt := "1|" . StrLen(Text) . ":"
	Loop StrLen(Text)
		Receipt .= Format("{:04X}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Receipt
}

/** The exact JSON producer and connector dispatch reach the real native launcher. */
_LAGNN_Run(Position) {
	global _ConfigDir, _DriverDir, _LLM_AgentConnector_Tools
	global _LLM_AgentConnector_LaunchFn, _LLM_AgentConnector_ListFn, _LLM_AgentConnector_EnsureDirFn
	static Debt := 0
	AssertFalse(IsObject(Debt), "SETUP: a previous exact native tool still owns retirement debt")
	Saved := {ConfigDir: _ConfigDir, Tools: _LLM_AgentConnector_Tools,
		Launch: _LLM_AgentConnector_LaunchFn, List: _LLM_AgentConnector_ListFn,
		Ensure: _LLM_AgentConnector_EnsureDirFn, Critical: A_IsCritical, Suspended: A_IsSuspended}
	Root := A_Temp . "\ergopti_agent_native_input_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	State := {Attempts: 0, Pid: 0, Vector: 0, Process: 0, Ready: false, Joined: false, ExitKnown: false, ExitCode: -1}
	Primary := 0, Passed := false, HandleClosed := false, Result := 0, Created := false
	try {
		Critical("Off"), Suspend(false)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "SETUP: own the exact native-tool directory")
		DirCreate(Root . "\agent_tools")
		FileCopy(_DriverDir . "\tests\fixtures\ai\agent_native_tool_input.ahk", Root . "\agent_tools\Native receiver.ahk")
		AssertTrue(FSWriteCreateDurable(Root . "\parent", String(ProcessExist())), "SETUP: parent identity receipt")
		_ConfigDir := Root
		_LLM_AgentConnector_Tools := ""
		_LLM_AgentConnector_ListFn := 0, _LLM_AgentConnector_EnsureDirFn := 0
		_LLM_AgentConnector_LaunchFn := _LAGNN_Launch.Bind(State)
		Config := LLM_Agent_Config()
		Tools := LLM_AgentConnector_Tools(Config, true)
		AssertTrue(Tools["paths"].Has("Native receiver"), "SETUP: genuine native tool discovery must find the copied tool")
		Left := Position == "head" ? "" : "prefix"
		Right := Position == "tail" ? "" : "suffix"
		Legal := Position == "legal"
		InputJson := Legal ? JsonStringLiteral("é漢 " . Chr(0x1F642) . ' tail\"')
			: '"' . Left . '\u0000' . Right . '"'
		Raw := Config["system2"]["tag"] . '[{"type":"shortcut","name":"Native receiver","input":' . InputJson . '}]'
		Actions := LLM_Agent_ParseActions(Config, Raw, Tools["names"], &Rejected)
		AssertTrue(Actions is Array && Actions.Length == 1, "SETUP: actual System2 JSON action is admitted")
		AssertEqual(0, Rejected.Length, "SETUP: actual producer has no action rejection")
		Input := Actions[1]["input"]
		if !Legal {
			AssertEqual(StrLen(Left) + 1 + StrLen(Right), StrLen(Input), "SETUP: admitted producer retains its complete NUL input")
			AssertEqual(0, NumGet(StrPtr(Input), StrLen(Left) * 2, "UShort"), "SETUP: actual admitted input contains NUL")
		}
		Result := LLM_AgentConnector_Execute(Actions[1], Config)
		AssertEqual(1, State.Attempts, "BUSINESS: genuine connector reaches the real launcher once")
		if State.Pid {
			; Acquire only query/wait rights. Never kill a PID which could be reused.
			State.Process := DllCall("Kernel32\OpenProcess", "UInt", 0x101000,
				"Int", false, "UInt", State.Pid, "Ptr")
			AssertTrue(State.Process != 0, "SETUP: retain the actual native child for independent joining")
			Started := A_TickCount
			while !FileExist(Root . "\ready") && TickElapsed(Started) < 5000
				Sleep(10)
			AssertTrue(FileExist(Root . "\ready") != "", "SETUP: the actual tool script must run and report readiness")
			Identity := StrSplit(FSReadUtf8Exact(Root . "\ready"), "|")
			AssertEqual(2, Identity.Length, "SETUP: complete native tool identity receipt")
			AssertEqual(State.Pid, Integer(Identity[1]), "SETUP: returned PID and actual child PID agree")
			Times := Buffer(32, 0)
			AssertTrue(DllCall("Kernel32\GetProcessTimes", "Ptr", State.Process, "Ptr", Times,
				"Ptr", Times.Ptr + 8, "Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24, "Int"), "SETUP: exact child creation FILETIME")
			AssertEqual(Integer(Identity[2]), NumGet(Times, 0, "Int64"), "SETUP: retained process is the reporting tool, not a reused PID")
			State.Ready := true
			Observed := FSReadUtf8Exact(Root . "\argv")
			_TestPrint("# agent-native-input position=" . Position . " admitted_units=" . StrLen(Input)
				. " native_argv=" . Observed . " connector_ok=" . Result["ok"])
			if Legal
				AssertEqual(_LAGNN_ArgvReceipt(Input), Observed, "BUSINESS: native legal Unicode input arrives exactly once and whole")
		}
		if Legal {
			AssertTrue(Result["ok"] && State.Ready, "BUSINESS: legal Unicode tool dispatch remains successful")
		} else {
			AssertFalse(Result["ok"], "BUSINESS: native argument NUL must refuse rather than report a truncated tool input as complete")
			AssertEqual(0, State.Pid, "BUSINESS: refusal must precede native child creation")
			AssertFalse(FileExist(Root . "\ready"), "BUSINESS: refused NUL cannot run the tool")
			AssertContains(Result["reason"], "NUL", "BUSINESS: refusal explains the unsupported native argument boundary")
		}
		Passed := true
	} catch Any as Err {
		Primary := Err
	} finally {
		try {
			if State.Pid {
				; This private path is the only control signal; no PID-based kill exists.
				if !FileExist(Root . "\stop")
					AssertTrue(FSWriteCreateDurable(Root . "\stop", "stop"), "RETIREMENT: signal only the owned tool fixture")
				if State.Process
					State.Joined := DllCall("Kernel32\WaitForSingleObject", "Ptr", State.Process, "UInt", 5000, "UInt") == 0
				if State.Joined {
					State.ExitKnown := DllCall("Kernel32\GetExitCodeProcess", "Ptr", State.Process, "UInt*", &Code := 0, "Int") != 0
					State.ExitCode := Code
					HandleClosed := DllCall("Kernel32\CloseHandle", "Ptr", State.Process, "Int") != 0
					if HandleClosed
						State.Process := 0
				}
			} else
				State.Joined := true, HandleClosed := true
		} catch Any as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		if !State.Joined || !HandleClosed
			Debt := {State: State, Root: Root}
		_ConfigDir := Saved.ConfigDir
		_LLM_AgentConnector_Tools := Saved.Tools
		_LLM_AgentConnector_LaunchFn := Saved.Launch, _LLM_AgentConnector_ListFn := Saved.List
		_LLM_AgentConnector_EnsureDirFn := Saved.Ensure
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(State.Joined && HandleClosed, "RETIREMENT: exact native tool and handle debt must retire")
	if State.Pid {
		AssertTrue(State.ExitKnown, "RETIREMENT: query exact child exit status")
		AssertEqual(0, State.ExitCode, "RETIREMENT: exact child exited normally")
		AssertEqual("done", FSReadUtf8Exact(Root . "\done"), "RETIREMENT: actual child observed the stop signal and exited")
	}
	if Passed && Created
		DirDelete(Root, true)
}

for _LAGNN_Position in ["head", "middle", "tail", "legal"]
	Test("LLM agent: " . _LAGNN_Position . " native shortcut input survives JSON and obeys argv admission (agent-native-nul-input)",
		_LAGNN_Run.Bind(_LAGNN_Position))


_LAGICS_Done(State, ExitCode, Stdout, Stderr) {
	State["done"] := true, State["exit"] := ExitCode, State["stdout"] := Stdout, State["stderr"] := Stderr
}

; Model a registered handler which starts asynchronously but has not opened yet.
_LAGICS_Open(State, Target) {
	if InStr(Target, "mailto:") == 1
		return true
	State["target"] := Target
	Task := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", State["fixture"], State["root"], Target], _LAGICS_Done.Bind(State))
	State["task"] := Task
	if !Task.start()
		throw Error("SETUP: the delayed native reader could not start")
	State["pid"] := Task.processId()
	return true
}

_LAGICS_Wait(Path, Milliseconds := 10000) {
	Start := A_TickCount
	while !FileExist(Path) && TickElapsed(Start) < Milliseconds {
		_SR_TreePoll()
		Sleep(10)
	}
	return FileExist(Path) != ""
}

_LAGICS_Run(DoSecond) {
	global _LLM_Ollama_InstanceNonce, _LLM_AgentConnector_ComFn, _LLM_AgentConnector_OpenFn
	global _LLM_AgentConnector_PublishFn, _LLM_AgentConnector_ParentFn, _LLM_AgentConnector_IdFn
	global _DriverDir
	static Debt := 0
	AssertFalse(IsObject(Debt), "SETUP: a previous native reader still owns retirement debt")
	Saved := {Nonce: _LLM_Ollama_InstanceNonce, Com: _LLM_AgentConnector_ComFn, Open: _LLM_AgentConnector_OpenFn,
		Publish: _LLM_AgentConnector_PublishFn, Parent: _LLM_AgentConnector_ParentFn,
		Id: _LLM_AgentConnector_IdFn, Critical: A_IsCritical, Suspended: A_IsSuspended}
	Guid := Buffer(16, 0)
	AssertEqual(0, PLC_CreateGuid(Guid), "SETUP: unique private directory identity")
	Nonce := ""
	loop Guid.Size
		Nonce .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
	Root := _LLM_Ollama_BuildTempDir(A_Temp, ProcessExist(), Nonce)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue((Created is Integer) && Created == 1, "SETUP: exact private directory acquired")
	State := Map("root", Root, "fixture", _DriverDir . "\tests\fixtures\ai\agent_delayed_ics_reader.ahk",
		"target", "", "task", 0, "pid", 0, "done", false, "exit", -1, "stdout", "", "stderr", "")
	Primary := 0, Joined := true, Passed := false
	try {
		Critical("Off"), Suspend(false)
		_LLM_Ollama_InstanceNonce := Nonce
		_LLM_AgentConnector_ComFn := (*) => ""
		_LLM_AgentConnector_PublishFn := 0, _LLM_AgentConnector_ParentFn := () => Root
		_LLM_AgentConnector_IdFn := () => Map("uid", Nonce . "@ergopti", "stamp", "20260929T120500Z")
		_LLM_AgentConnector_OpenFn := _LAGICS_Open.Bind(State)
		Config := LLM_Agent_Config()
		Calendar := _LAG_Action('{"type":"calendar","title":"Devis","start":"2026-10-01T14:00"}')
		First := LLM_AgentConnector_Execute(Calendar, Config)
		AssertTrue(First["ok"] && First["path"] == "ics", "SETUP: real calendar connector accepted the file")
		AssertTrue(State["pid"] > 0, "SETUP: real owned reader started")
		SplitPath(State["target"], &TargetName, &TargetDir)
		AssertEqual("invitation.ics", TargetName, "SETUP: actual owner published its named file")
		AssertTrue(InStr(TargetDir, Root . "\ergopti_agent_") == 1, "SETUP: actual owner used the private proof root")
		Joined := false
		AssertTrue(_LAGICS_Wait(Root . "\ready"), "SETUP: reader reaches its pre-open barrier")
		AssertEqual(State["pid"], Integer(FSReadUtf8Exact(Root . "\ready")), "SETUP: ready belongs to the owned reader")
		Expected := FSReadUtf8Exact(State["target"])
		AssertTrue(Expected is String && InStr(Expected, "BEGIN:VCALENDAR"), "SETUP: exact real ICS exists before second action")
		if DoSecond {
			Mail := _LAG_Action('{"type":"mail","to":["paul@example.com"],"body":"Bonjour"}')
			Second := LLM_AgentConnector_Execute(Mail, Config)
			AssertTrue(Second["ok"] && Second["path"] == "mailto", "SETUP: second real connector accepted")
		}
		ExistsBeforeRelease := FileExist(State["target"]) != ""
		AssertTrue(FSWriteCreateDurable(Root . "\release", "release"), "SETUP: release only the owned reader")
		AssertTrue(_LAGICS_Wait(Root . "\result"), "SETUP: reader publishes its exact file result")
		Outcome := FSReadUtf8Exact(Root . "\result")
		Start := A_TickCount
		while !State["done"] && TickElapsed(Start) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Joined := State["done"]
		_TestPrint("# agent-ics-delayed second=" . DoSecond . " exists_before_release=" . ExistsBeforeRelease
			. " reader=" . Outcome . " joined=" . Joined . " exit=" . State["exit"])
		AssertTrue(Joined && State["exit"] == 0, "RETIREMENT: exact reader exited successfully")
		AssertEqual("", State["stderr"], "RETIREMENT: the shell runner reports no capture errors")
		AssertEqual("", State["stdout"], "RETIREMENT: merged child output contains no warnings or errors")
		AssertEqual("READ", Outcome, "BUSINESS: accepted calendar remains readable by its delayed handler")
		AssertEqual(Expected, FSReadUtf8Exact(Root . "\received.ics"), "BUSINESS: delayed reader sees exact accepted ICS")
		Passed := true
	} catch Any as Err {
		Primary := Err
	} finally {
		if IsObject(State["task"]) && !State["done"] {
			Joined := false
			if !FileExist(Root . "\release")
				try FSWriteCreateDurable(Root . "\release", "release")
			; A request alone is not a quiescence receipt. Retire the exact Job,
			; or accept only its dispatched completion after accounting reached zero.
			try State["task"].requestTerminate()
			RetireStart := A_TickCount
			while !State["done"] && TickElapsed(RetireStart) < 5000 {
				Retired := false
				try Retired := State["task"].terminate()
				if (Retired is Integer) && Retired == 1 {
					Joined := true
					break
				}
				_SR_TreePoll()
				Sleep(10)
			}
			if State["done"]
				Joined := true
		}
		if !Joined
			Debt := {State: State, Root: Root}
		_LLM_Ollama_InstanceNonce := Saved.Nonce, _LLM_AgentConnector_ComFn := Saved.Com
		_LLM_AgentConnector_OpenFn := Saved.Open, _LLM_AgentConnector_PublishFn := Saved.Publish
		_LLM_AgentConnector_ParentFn := Saved.Parent, _LLM_AgentConnector_IdFn := Saved.Id
		Suspend(Saved.Suspended), Critical(Saved.Critical)
		if Joined && DirExist(Root)
			DirDelete(Root, true)
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Passed && Joined, "the exact native reader and private directory retired")
}
Test("LLM agent: delayed native calendar handler reads without a second action (agent-ics-delayed)", _LAGICS_Run.Bind(false))
Test("LLM agent: delayed native calendar handler survives the next action (agent-ics-delayed)", _LAGICS_Run.Bind(true))



; Read the process token user into an owned SID buffer for ACL comparison.
_LAGICS_CurrentUserSid() {
	Token := 0
	if !DllCall("advapi32\OpenProcessToken", "Ptr", DllCall("kernel32\GetCurrentProcess", "Ptr"),
			"UInt", 0x8, "Ptr*", &Token, "Int")
		throw OSError(A_LastError, "open test token")
	try {
		Needed := 0
		DllCall("advapi32\GetTokenInformation", "Ptr", Token, "Int", 1,
			"Ptr", 0, "UInt", 0, "UInt*", &Needed, "Int")
		if Needed < A_PtrSize
			throw OSError(A_LastError, "size test token")
		User := Buffer(Needed, 0)
		if !DllCall("advapi32\GetTokenInformation", "Ptr", Token, "Int", 1,
				"Ptr", User, "UInt", User.Size, "UInt*", &Needed, "Int")
			throw OSError(A_LastError, "read test token")
		Sid := NumGet(User, 0, "Ptr")
		Size := DllCall("advapi32\GetLengthSid", "Ptr", Sid, "UInt")
		if !Size
			throw OSError(A_LastError, "size test SID")
		Copy := Buffer(Size, 0)
		if !DllCall("advapi32\CopySid", "UInt", Size, "Ptr", Copy, "Ptr", Sid, "Int")
			throw OSError(A_LastError, "copy test SID")
		return Copy
	} finally DllCall("kernel32\CloseHandle", "Ptr", Token, "Int")
}


; Inspect effective security, including on filesystems that ignore create descriptors.
_LAGICS_AssertPrivateAcl(Path, User) {
	Descriptor := 0
	try {
		Owner := 0, Dacl := 0
		Status := DllCall("advapi32\GetNamedSecurityInfoW", "Str", Path, "Int", 1, "UInt", 5,
			"Ptr*", &Owner, "Ptr", 0, "Ptr*", &Dacl, "Ptr", 0, "Ptr*", &Descriptor, "UInt")
		AssertEqual(0, Status, "the native descriptor is readable")
		AssertTrue(Descriptor && Owner && Dacl, "owner and DACL exist")
		AssertTrue(DllCall("advapi32\EqualSid", "Ptr", Owner, "Ptr", User, "Int"), "the token user owns the object")
		Control := 0, Revision := 0
		AssertTrue(DllCall("advapi32\GetSecurityDescriptorControl", "Ptr", Descriptor,
			"UShort*", &Control, "UInt*", &Revision, "Int"))
		AssertTrue((Control & 0x1000) != 0, "DACL inheritance is protected")
		AclInfo := Buffer(12, 0)
		AssertTrue(DllCall("advapi32\GetAclInformation", "Ptr", Dacl, "Ptr", AclInfo, "UInt", 12, "Int", 2, "Int"))
		AssertEqual(2, NumGet(AclInfo, 0, "UInt"), "exactly the user and SYSTEM have ACEs")
		SeenUser := false, SeenSystem := false
		loop 2 {
			Ace := 0
			AssertTrue(DllCall("advapi32\GetAce", "Ptr", Dacl, "UInt", A_Index - 1, "Ptr*", &Ace, "Int"))
			AssertEqual(0, NumGet(Ace, 0, "UChar"), "only allow ACEs are admitted")
			AssertEqual(0x1F01FF, NumGet(Ace, 4, "UInt"), "each owner receives file full access")
			Sid := Ace + 8
			IsUser := DllCall("advapi32\EqualSid", "Ptr", Sid, "Ptr", User, "Int") != 0
			IsSystem := DllCall("advapi32\IsWellKnownSid", "Ptr", Sid, "Int", 22, "Int") != 0
			if !IsUser && !IsSystem
				throw Error("unexpected handoff ACE SID")
			SeenUser := SeenUser || IsUser, SeenSystem := SeenSystem || IsSystem
		}
		AssertTrue(SeenUser && SeenSystem, "the exact two principals are user and SYSTEM")
	} finally {
		if Descriptor
			DllCall("kernel32\LocalFree", "Ptr", Descriptor, "Ptr")
	}
}

_LAGICS_PrivateAclAndCollision() {
	Guid := Buffer(16, 0)
	AssertEqual(0, PLC_CreateGuid(Guid), "SETUP: acquire unique directory identity")
	Nonce := ""
	loop Guid.Size
		Nonce .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
	Root := RTrim(A_Temp, "\/") . "\ergopti_agent_acl_test_" . Nonce
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue((Created is Integer) && Created == 1, "SETUP: own exact private proof root")
	try {
		Expected := "accepted-é"
		Path := FSWritePrivateRetained(Root, "handoff", "invitation.ics", Expected)
		AssertEqual(Root . "\handoff\invitation.ics", Path, "the real owner returns its exact path")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the real owner writes complete UTF-8 bytes")
		User := _LAGICS_CurrentUserSid()
		_LAGICS_AssertPrivateAcl(Root . "\handoff", User)
		_LAGICS_AssertPrivateAcl(Path, User)
		CollisionRefused := false
		try FSWritePrivateRetained(Root, "handoff", "invitation.ics", "foreign")
		catch
			CollisionRefused := true
		AssertTrue(CollisionRefused, "an existing directory is never adopted")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "collision leaves existing bytes intact")
		NulText := JsonParse('"prefix\u0000suffix"')
		AssertEqual(13, StrLen(NulText), "SETUP: the input really contains embedded NUL")
		NulRefused := false
		try FSWritePrivateRetained(Root, "invalid", "invitation.ics", NulText)
		catch
			NulRefused := true
		AssertTrue(NulRefused, "embedded NUL is refused instead of truncating the handoff")
		AssertFalse(FileExist(Root . "\invalid"), "NUL refusal precedes directory creation")
	} finally {
		if Created && DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("LLM agent: retained calendar owner verifies private ACL and refuses collision (agent-ics-private-acl)",
	_LAGICS_PrivateAclAndCollision)
