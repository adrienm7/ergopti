; tests/unit/ai/actions/test_agent_requester.ahk

; ==============================================================================
; MODULE: LLM Agent System Lists and Requester
; DESCRIPTION:
; The System list provider builds DATA without native effects, a committed
; requester withdrawal survives the held model, and the app picker's live
; tail keeps its requester.
; ==============================================================================

#Requires AutoHotkey v2.0





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
			; One declaration for every driver: the row carries no platforms list.
			AssertFalse(Item.Has("platforms"), "the System list is declared once for every driver")
			Restore() {
				if Item.Has("platforms")
					Item.Delete("platforms")
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
				AssertFalse(Item.Has("platforms"), "the exact original declaration owner is restored")
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

/** A committed requester withdrawal must survive the held model-consent dialog. */
_LAG_RequesterWithdrawal(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_LocalModelOfferPort, _LLM_Agent_Generation, _LLM_Agent_CommitFn
		Saved := _LLM_LocalModelOfferPort, Commit := _LLM_Agent_CommitFn
		State := Map("confirms", 0, "downloads", 0)
		try {
			_LLM_LocalModelOfferPort := Map("confirm", Confirm, "install", Install)
			AssertTrue(_LAG_Invoke("llm_agent_selection"))
			AssertEqual(1, Fx.Ollama.Length)
			Generation := _LLM_Agent_Generation
			Request := Fx.Ollama[1]
			Failure := LLM_LocalModelFailure(JsonParse(Request["body"])["model"], LLM_OllamaRequestOrigin())
			if Mode == "late-failure"
				AssertTrue(LLM_Agent_SetMode("off"))
			Request["on_fail"].Call(Failure)
			Allowed := Mode == "same-source" || Mode == "same-mode" || Mode == "unrelated"
				|| Mode == "refused-write"
			AssertEqual(Mode == "late-failure" ? 0 : 1, State["confirms"])
			AssertEqual(Allowed ? 1 : 0, State["downloads"])
			AssertEqual(Allowed, _LLM_Agent_RenderIsCurrent(Generation))
			AssertEqual(0, Sent.Length)
			if !Allowed {
				Request["on_fail"].Call(Failure)
				AssertEqual(Mode == "late-failure" ? 0 : 1, State["confirms"], "Retired callbacks cannot create a fresh offer.")
			}
		} finally {
			_LLM_LocalModelOfferPort := Saved
			_LLM_Agent_CommitFn := Commit
		}
		Confirm(*) {
			State["confirms"] += 1
			switch Mode {
				case "source-off": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", ""))
				case "source-remote": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "cerebras"))
				case "source-aba":
					AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "cerebras"))
					AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "local"))
				case "mode-off": AssertTrue(LLM_Agent_SetMode("off"))
				case "mode-aba":
					AssertTrue(LLM_Agent_SetMode("off")), AssertTrue(LLM_Agent_SetMode("action"))
				case "same-source": AssertFalse(_LLM_Agent_MenuSetBackend("agent_system2", "local"))
				case "same-mode": AssertFalse(LLM_Agent_SetMode("action"))
				case "unrelated": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", "local"))
				case "refused-write":
					_LLM_Agent_CommitFn := (*) => false
					AssertFalse(_LLM_Agent_MenuSetBackend("agent_system2", "cerebras"))
			}
			return true
		}
		Install(*) {
			State["downloads"] += 1
			return true
		}
	}
}

for _LAG_RequesterMode in ["source-off", "source-remote", "source-aba", "mode-off", "mode-aba",
	"same-source", "same-mode", "unrelated", "refused-write", "late-failure"]
	Test("LLM agent: requester currency " . _LAG_RequesterMode . " (todo46-manual-requester)",
		_LAG_RequesterWithdrawal.Bind(_LAG_RequesterMode))

/** Accepted async recovery retains its original requester, not a restored setting. */
_LAG_RequesterCompletion(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_LocalModelOfferPort, _LLM_Agent_Generation
		Saved := _LLM_LocalModelOfferPort, Published := 0, Receipt := 0, Downloads := 0
		try {
			_LLM_LocalModelOfferPort := Map("confirm", Confirm, "install", (*) => (Downloads += 1, true))
			AssertTrue(_LAG_Invoke("llm_agent_selection"))
			Request := Fx.Ollama[1]
			Failure := LLM_LocalModelFailure(JsonParse(Request["body"])["model"], LLM_OllamaRequestOrigin())
			Receipt := _LLM_LocalModelOfferCapture(Failure, _LLM_Agent_RenderIsCurrent.Bind(_LLM_Agent_Generation))
			Request["on_fail"].Call(Failure)
			AssertEqual(1, Downloads, "The original explicit install was actually admitted before asynchronous withdrawal.")
			if Mode == "source-aba" {
				AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "cerebras"))
				AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", "local"))
			} else if Mode == "mode-off"
				AssertTrue(LLM_Agent_SetMode("off"))
			AssertEqual(Mode == "unchanged", _LLM_LocalModelOfferPublished(Receipt, () => Published += 1))
			AssertEqual(Mode == "unchanged" ? 1 : 0, Published)
			AssertEqual(0, Sent.Length)
		} finally _LLM_LocalModelOfferPort := Saved
		Confirm(*) {
			return true
		}
	}
}
for _LAG_CompletionMode in ["unchanged", "source-aba", "mode-off"]
	Test("LLM agent: retained model completion " . _LAG_CompletionMode . " (todo46-manual-requester)",
		_LAG_RequesterCompletion.Bind(_LAG_CompletionMode))

_LAG_RequesterRejectsUntypedCommit() {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(""), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_CommitFn, _LLM_Agent_Generation
		Saved := _LLM_Agent_CommitFn, Generation := _LLM_Agent_Generation
		try {
			_LLM_Agent_CommitFn := (*) => "1"
			AssertFalse(LLM_Agent_CommitSetting("agent_system2", "cerebras"))
			AssertEqual(Generation, _LLM_Agent_Generation)
			AssertEqual(0, Fx.Rebuilds)
		} finally _LLM_Agent_CommitFn := Saved
	}
}
Test("LLM agent: requester commit requires typed admission (todo46-manual-requester)", _LAG_RequesterRejectsUntypedCommit)

/** The actual app-picker save binds the shared tail's previous value and candidate. */
_LAG_AppPickerLiveTail(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(""), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn, _LLM_Agent_Generation
		Generation := _LLM_Agent_Generation
		Selected := Mode == "same" ? [] : ["Slack.EXE"]
		Receipt := AppPicker_IssueReceipt("agent:disabled_apps", Mode == "stale" ? ["other.exe"] : [])
		try {
			if Mode == "refused"
				_LLM_Agent_CommitFn := (*) => false
			else if Mode == "float"
				_LLM_Agent_CommitFn := (*) => 1.0
			else if Mode == "string"
				_LLM_Agent_CommitFn := (*) => "accepted"
			Accepted := Mode == "accepted" || Mode == "same"
			AssertEqual(Accepted, LLM_Agent_OnAppPickerSave(Selected, Receipt))
			AssertEqual(Accepted ? 1 : 0, Fx.Rebuilds, "Only an exact acknowledged tail rebuilds the tray.")
			AssertEqual(Generation, _LLM_Agent_Generation, "App exclusions do not retire an unrelated manual requester.")
			Expected := Mode == "accepted" ? ["slack.exe"] : []
			AssertEqual("", _LVS_DeepEqual(Expected, _LLM_Menu["agent_disabled_apps"]))
			if Accepted {
				AssertEqual(1, Fx.Commits.Length, "The real candidate and shared live tail complete once.")
				AssertFalse(LLM_Agent_OnAppPickerSave(Selected, Receipt), "An accepted picker receipt cannot be reused.")
				AssertEqual(1, Fx.Rebuilds)
			}
		} finally AppPicker_RetireReceipt(Receipt)
	}
}
for _LAG_AppPickerMode in ["accepted", "same", "refused", "stale", "float", "string"]
	Test("LLM agent app picker: actual live tail " . _LAG_AppPickerMode . " (agent-app-picker-tail)",
		_LAG_AppPickerLiveTail.Bind(_LAG_AppPickerMode))

; Context, endpoint, body and prediction retirement all yield before dispatch.
; Observe the actual function, delegate its original result, then withdraw the
; requester through the genuine durable settings transaction.
_LAG_DispatchCustody(Backend, Phase) {
	_LAG_Run(_LAG_Menu("action", "", Backend), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_ContextProbe, _LLM_Remote_BackboardExchanges
		Observed := false
		Boundary := Phase == "cancel" ? _LLM_Vision_CancelEngine
			: Phase == "payload" ? (Backend == "local" ? LLM_Vision_BuildRequest : _LLMRemoteBuildPayload)
			: _LLM_Vision_ResolveTarget
		HadCall := Boundary.HasOwnProp("Call")
		SavedCall := HadCall ? Boundary.GetOwnPropDesc("Call") : 0
		Owners := _LLM_Remote_BackboardExchanges.Clone()
		try {
			AssertFalse(HadCall, "the observed production function retains its genuine Call boundary")
			_LLM_Agent_ContextProbe := Context
			_LAG_Invoke("llm_agent_selection")
			AssertTrue(Observed, "the actual dispatch boundary was reached")
			Expected := Phase == "unchanged" || Phase == "context-newer" ? 1 : 0
			AssertEqual(Expected, Fx.Remote.Length + Fx.Ollama.Length + Fx.Posts.Length,
				"only the unchanged or newer legitimate requester can send private text")
			AssertEqual(0, Sent.Length)
		} finally {
			if Boundary.HasOwnProp("Call")
				Boundary.DeleteProp("Call")
			if HadCall
				Boundary.DefineProp("Call", SavedCall)
			Retire := []
			for Id, Owner in _LLM_Remote_BackboardExchanges
				if !Owners.Has(Id)
					Retire.Push(Owner)
			for Owner in Retire
				_LLMRemote_BackboardRetire(Owner, true)
		}
		Context() {
			if !Observed && (InStr(Phase, "context") == 1 || Phase == "unchanged") {
				Observed := true
				switch Phase {
					case "context-off": AssertTrue(LLM_Agent_SetMode("off"))
					case "context-source": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", ""))
					case "context-newer":
						AssertTrue(_LAG_Invoke("llm_agent_selection"))
						AssertEqual(1, Fx.Remote.Length, "the newer legitimate selection really dispatched")
				}
			} else if !Observed
				Boundary.DefineProp("Call", {Call: Observe})
			return _LAG_Context(Fx)
		}
		Observe(Self, Args*) {
			Boundary.DeleteProp("Call")
			Result := Boundary.Call(Args*)
			Observed := true
			AssertTrue(LLM_Agent_SetMode("off"))
			return Result
		}
	}
}
for Backend in ["local", "cerebras", "backboard"] {
	for Phase in ["context-off", "context-source", "context-newer", "target", "cancel", "unchanged"]
		Test("LLM agent: dispatch retains original requester " . Backend . " " . Phase . " (agent-dispatch-custody)",
			_LAG_DispatchCustody.Bind(Backend, Phase))
	if Backend != "backboard"
		Test("LLM agent: dispatch retains original requester " . Backend . " payload (agent-dispatch-custody)",
			_LAG_DispatchCustody.Bind(Backend, "payload"))
}

; Run the genuine callback armed by typing; no scheduling or delay is replaced.
_LAG_TriageCustody(Backend, Phase) {
	_LAG_Run(_LAG_Menu("auto", Backend, "cerebras"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_ContextProbe, _LLM_Remote_BackboardExchanges
		Observed := false
		Boundary := Phase == "payload" ? (Backend == "local" ? LLM_Vision_BuildRequest : _LLMRemoteBuildPayload)
			: _LLM_Vision_ResolveTarget
		HadCall := Boundary.HasOwnProp("Call")
		SavedCall := HadCall ? Boundary.GetOwnPropDesc("Call") : 0
		Owners := _LLM_Remote_BackboardExchanges.Clone()
		try {
			AssertFalse(HadCall, "the real triage boundary starts with its original implementation")
			TooltipHide("AgentCustody", true)
			Pause := _LAG_Type(Fx, LAG_TYPED)
			AssertTrue(HasMethod(Pause, "Call"), "actual typing arms its unchanged pause callback")
			_LLM_Agent_ContextProbe := Context
			Pause.Call()
			AssertTrue(Observed, "the genuine triage callback reaches its yielding boundary")
			AssertEqual(Phase == "unchanged" || Phase == "context-newer" ? 1 : 0,
				Fx.Remote.Length + Fx.Ollama.Length + Fx.Posts.Length,
				"a retired automatic requester cannot send the typed sentence")
			AssertEqual(0, Sent.Length)
		} finally {
			if Boundary.HasOwnProp("Call")
				Boundary.DeleteProp("Call")
			if HadCall
				Boundary.DefineProp("Call", SavedCall)
			Retire := []
			for Id, Owner in _LLM_Remote_BackboardExchanges
				if !Owners.Has(Id)
					Retire.Push(Owner)
			for Owner in Retire
				_LLMRemote_BackboardRetire(Owner, true)
		}
		Context() {
			if !Observed && (InStr(Phase, "context") == 1 || Phase == "unchanged") {
				Observed := true
				switch Phase {
					case "context-off": AssertTrue(LLM_Agent_SetMode("off"))
					case "context-source": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system2", ""))
					case "context-source1": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", ""))
					case "context-source1aba":
						AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", ""))
						AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", Backend))
					case "context-newer":
						AssertTrue(_LAG_Invoke("llm_agent_selection"))
						AssertEqual(1, Fx.Remote.Length, "the newer legitimate selection really dispatched")
				}
			} else if !Observed
				Boundary.DefineProp("Call", {Call: Observe})
			return _LAG_Context(Fx)
		}
		Observe(Self, Args*) {
			Boundary.DeleteProp("Call")
			Result := Boundary.Call(Args*)
			Observed := true
			AssertTrue(LLM_Agent_SetMode("off"))
			return Result
		}
	}
}
for Backend in ["local", "cerebras", "backboard", "typesafe", "backboard|typesafe/jev-latest"] {
	for Phase in ["context-off", "context-source", "context-newer", "target", "unchanged"]
		Test("LLM agent: triage retains original requester " . Backend . " " . Phase . " (agent-triage-custody)",
			_LAG_TriageCustody.Bind(Backend, Phase))
	if Backend == "local" || Backend == "cerebras"
		Test("LLM agent: triage retains original requester " . Backend . " payload (agent-triage-custody)",
			_LAG_TriageCustody.Bind(Backend, "payload"))
}

for Backend in ["local", "cerebras", "backboard", "typesafe", "backboard|typesafe/jev-latest"]
	for Phase in ["context-source1", "context-source1aba"]
		Test("LLM agent: System1 source withdrawal " . Backend . " " . Phase . " (agent-source1-custody)",
			_LAG_TriageCustody.Bind(Backend, Phase))

_LAG_Source1Held(Backend, Mode) {
	_LAG_Run(_LAG_Menu("auto", Backend, "cerebras"), _LTN_Screen(""), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_CommitFn, _LLM_Remote_BackboardExchanges
		Owners := _LLM_Remote_BackboardExchanges.Clone()
		try {
			TooltipHide("AgentSource1", true)
			AssertTrue(_LAG_Type(Fx, LAG_TYPED).Call(), "the genuine pause starts its original triage")
			if InStr(Backend, "backboard") == 1 {
				AssertEqual(1, Fx.Posts.Length, "the real exchange creates one assistant")
				Fx.Posts[1]["on_success"].Call('{"assistant_id":"source1_assistant"}')
				AssertEqual(2, Fx.Posts.Length, "the real continuation dispatches its triage message")
				Request := Fx.Posts[2]
			} else
				Request := Backend == "local" ? Fx.Ollama[1] : Backend == "typesafe" ? Fx.Posts[1] : Fx.Remote[1]
			Before := Fx.Remote.Length + Fx.Ollama.Length + Fx.Posts.Length
			switch Mode {
				case "off": AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", ""))
				case "aba":
					AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", ""))
					AssertTrue(_LLM_Agent_MenuSetBackend("agent_system1", Backend))
				case "same": AssertFalse(_LLM_Agent_MenuSetBackend("agent_system1", LLM_Vision_Parse(Backend)["backend"]))
				case "refused":
					_LLM_Agent_CommitFn := (*) => false
					AssertFalse(_LLM_Agent_MenuSetBackend("agent_system1", ""))
			}
			Triage := "INTENT: calendar`nPROBABILITY: 0.9"
			Raw := Backend == "typesafe" ? '{"answers":' . _LAG_JevAnswers("calendar") . '}'
				: InStr(Backend, "backboard|") == 1 ? '{"system_one":{"answers":' . _LAG_JevAnswers("calendar") . '}}'
				: Backend == "backboard" ? '{"content":' . JsonStringLiteral(Triage) . ',"status":"COMPLETED"}' : Triage
			Request["on_success"].Call(Raw)
			AssertEqual(Before + (Mode == "off" || Mode == "aba" ? 0 : 1),
				Fx.Remote.Length + Fx.Ollama.Length + Fx.Posts.Length,
				"only a still-admitted triage can wake System 2")
			AssertEqual(0, Sent.Length)
		} finally {
			Retire := []
			for Id, Owner in _LLM_Remote_BackboardExchanges
				if !Owners.Has(Id)
					Retire.Push(Owner)
			for Owner in Retire
				_LLMRemote_BackboardRetire(Owner, true)
		}
	}
}
for Backend in ["local", "cerebras", "backboard", "typesafe", "backboard|typesafe/jev-latest"]
	for Mode in ["off", "aba", "same", "refused", "unchanged"]
		Test("LLM agent: held System1 answer retains source " . Backend . " " . Mode . " (agent-source1-held)",
			_LAG_Source1Held.Bind(Backend, Mode))

_LAG_BackboardAssistantCustody(Source, Mode) {
	Automatic := Source != "manual"
	Backend := Source == "jev" ? "backboard|typesafe/jev-latest" : "backboard"
	_LAG_Run(_LAG_Menu(Automatic ? "auto" : "action", Automatic ? Backend : "", Automatic ? "cerebras" : Backend),
		_LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Agent_CommitFn, _LLM_Remote_BackboardExchanges
		Owners := _LLM_Remote_BackboardExchanges.Clone()
		try {
			TooltipHide("AgentAssistant", true)
			AssertTrue(Automatic ? _LAG_Type(Fx, LAG_TYPED).Call() : _LAG_Invoke("llm_agent_selection"))
			AssertEqual(1, Fx.Posts.Length, "the genuine exchange is waiting for its assistant")
			AssertContains(Fx.Posts[1]["url"], "/assistants")
			switch Mode {
				case "off": AssertTrue(LLM_Agent_SetMode("off"))
				case "aba":
					AssertTrue(LLM_Agent_SetMode("off"))
					AssertTrue(LLM_Agent_SetMode(Automatic ? "auto" : "action"))
				case "source": AssertTrue(_LLM_Agent_MenuSetBackend(Automatic ? "agent_system1" : "agent_system2", ""))
				case "refused":
					_LLM_Agent_CommitFn := (*) => false
					AssertFalse(LLM_Agent_SetMode("off"))
			}
			Fx.Posts[1]["on_success"].Call('{"assistant_id":"delayed_assistant"}')
			AssertEqual(Mode == "unchanged" || Mode == "refused" ? 2 : 1, Fx.Posts.Length,
				"a withdrawn requester cannot post its private text after assistant creation")
			if Mode == "unchanged" || Mode == "refused"
				AssertContains(Fx.Posts[2]["url"], "/threads/messages", "unchanged exchange reaches its genuine next stage")
			AssertEqual(0, Sent.Length)
		} finally {
			Retire := []
			for Id, Owner in _LLM_Remote_BackboardExchanges
				if !Owners.Has(Id)
					Retire.Push(Owner)
			for Owner in Retire
				_LLMRemote_BackboardRetire(Owner, true)
		}
	}
}
for Source in ["manual", "automatic", "jev"]
	for Mode in ["off", "aba", "source", "refused", "unchanged"]
		Test("LLM agent: assistant continuation retains requester " . Source . " " . Mode . " (agent-assistant-custody)",
			_LAG_BackboardAssistantCustody.Bind(Source, Mode))

_LAG_BackboardNativeCustody(Withdraw) {
	_LAG_Run(_LAG_Menu("action", "", "backboard"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Remote_PostBodyFn, _LLM_Remote_BackboardExchanges
		SavedPost := _LLM_Remote_PostBodyFn
		Owners := _LLM_Remote_BackboardExchanges.Clone()
		Dispatch := _LLMRemote_DispatchManagedCurl
		AssertFalse(Dispatch.HasOwnProp("Call"), "the actual managed dispatcher starts with its original implementation")
		State := _ManagedCurlControlState()
		Seen := false
		try {
			_LLM_Remote_PostBodyFn := 0
			Dispatch.DefineProp("Call", {Call: ObserveDispatch})
			_LAG_Invoke("llm_agent_selection")
			AssertTrue(Seen, "the real managed request must reach its child acquisition boundary")
			AssertEqual(Withdraw ? 0 : 1, State["spawns"], "only an admitted original requester may acquire a native worker")
			AssertEqual(Withdraw ? 0 : 1, State["starts"])
			AssertEqual(0, Sent.Length)
		} finally {
			if Dispatch.HasOwnProp("Call")
				Dispatch.DeleteProp("Call")
			_LLM_Remote_PostBodyFn := SavedPost
			Retire := []
			for Id, Owner in _LLM_Remote_BackboardExchanges
				if !Owners.Has(Id)
					Retire.Push(Owner)
			for Owner in Retire
				_LLMRemote_BackboardRetire(Owner, true)
			if State.Has("id")
				_LLMRemote_PollRequest(State["id"])
			_ManagedCurlControlRelease(State)
		}
		ObserveDispatch(Self, Id, Reservation, Resolved, Url, Payload, Port := 0) {
			Dispatch.DeleteProp("Call")
			State["id"] := Id
			return Dispatch.Call(Id, Reservation, Resolved, Url, Payload,
				Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
					"create_http", Create))
		}
		Create() {
			Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(State), "before_launch", BeforeLaunch))
			State["request"] := Request
			return Request
		}
		BeforeLaunch(Request) {
			Seen := true
			if Withdraw
				AssertTrue(LLM_Agent_SetMode("off"))
		}
	}
}
for Withdraw in [true, false]
	Test("LLM agent: Backboard native launch retains original requester " . Withdraw . " (agent-assistant-native)",
		_LAG_BackboardNativeCustody.Bind(Withdraw))

_LAG_LocalNativeCustody(Phase, Withdraw) {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort, _LLM_Vision_OllamaTransport
		global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_Ollama_AsyncCounter, _LLM_Engine, _LLM_Agent_Generation
		Saved := [_LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort,
			_LLM_Vision_OllamaTransport, _LLM_AuxOwners, _LLM_AuxCleanupDebt]
		Origin := LLM_OllamaCaptureOriginCustody
		Spawn := _LLM_Ollama_DoSpawn
		AssertFalse(Origin.HasOwnProp("Call")), AssertFalse(Spawn.HasOwnProp("Call"))
		State := Map("timer", 0, "runs", 0, "writes", 0, "closed", 0, "seen", false, "paths", [], "polls", [])
		Port := Map("write", Write, "run", Run, "poll", (Id) => State["polls"].Push(Id),
			"terminate_process", (*) => true, "wait_process", (*) => 0, "close_process", Close)
		try {
			_LLM_Ollama_Async := Map(), _LLM_Ollama_Pending := ""
			_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map()
			_LLM_Vision_OllamaTransport := 0
			_LLM_Ollama_PreflightPort := Map("schedule", (Callback, Period) => State["timer"] := Callback,
				"list_models", List)
			Spawn.DefineProp("Call", {Call: ObserveSpawn})
			if Phase == "origin" || Phase == "origin-newer"
				Origin.DefineProp("Call", {Call: ObserveOrigin})
			if Phase == "queue-independent" {
				_LLM_Engine["enabled"] := !Withdraw
				AssertTrue(_LAG_Invoke("llm_agent_selection"))
				AssertTrue(_LAG_Invoke("llm_agent_selection"))
				AssertTrue(_LLM_Ollama_Pending is Map, "the second actual independent action owns a pending local job")
				AssertTrue(_LLM_Agent_RenderIsCurrent(_LLM_Agent_Generation))
				AssertTrue(_LLM_Ollama_Pending["requester_current"].Call(), "the original independent requester remains genuinely admitted")
				State["seen"] := true
			} else
				_LAG_Invoke("llm_agent_selection")
			if Phase == "preflight" {
				AssertTrue(HasMethod(State["timer"], "Call"), "the actual request reserved its deferred preflight")
				State["seen"] := true
				if Withdraw
					AssertTrue(LLM_Agent_SetMode("off"))
			}
			if Phase == "origin-newer" && Withdraw {
				AssertTrue(_LLM_Ollama_Pending is Map, "the newer legitimate request really occupies the pending slot")
				AssertEqual(State["newest"], _LLM_Ollama_Pending["req_id"], "the stale origin capture cannot replace its newer pending successor")
			}
			Loop 3 {
				if !HasMethod(State["timer"], "Call")
					break
				Tick := State["timer"], State["timer"] := 0
				Tick.Call()
			}
			AssertTrue(State["seen"], "the actual local request reached its selected boundary")
			if Phase == "spawn" && Withdraw {
				AssertFalse(_LLM_Ollama_Async.Has(State["retired_id"]), "the retired predecessor must leave its exact registry slot before cleanup")
				AssertFalse(_LLM_Ollama_Pending is Map, "the real pending successor must drain before fixture cleanup")
				AssertTrue(_LLM_Ollama_Async.Has(State["successor_id"]), "the successor must own the actual vacated slot")
				NextOwner := _LLM_Ollama_Async[State["successor_id"]]["process_owner"]
				AssertTrue(NextOwner is Map && ObjPtr(NextOwner) != ObjPtr(State["old_owner"]))
				AssertTrue(State["old_owner"]["released"])
				AssertFalse(NextOwner["released"], "old cleanup cannot close its live successor")
				AssertEqual(1, State["polls"].Length, "only the genuinely admitted successor may arm native polling")
				AssertEqual(State["successor_id"], State["polls"][1])
			}
			ExpectedRuns := Phase == "spawn" && Withdraw ? 2 : (Withdraw && Phase != "spawn" && Phase != "origin-newer" && Phase != "queue-independent" ? 0 : 1)
			AssertEqual(ExpectedRuns, State["runs"],
				"only the original local requester can acquire a curl process")
			if Phase == "spawn" && Withdraw
				AssertEqual(1, State["closed"], "withdrawal inside native acquisition retires the exact acquired process")
			AssertEqual(0, Sent.Length)
		} finally {
			if Origin.HasOwnProp("Call")
				Origin.DeleteProp("Call")
			if Spawn.HasOwnProp("Call")
				Spawn.DeleteProp("Call")
			try {
			for _, Entry in _LLM_Ollama_Async.Clone() {
				_LLM_CurlReleaseEntryProcess(Entry, true, Port)
				_LLM_Ollama_CleanupCurlFiles(Entry)
			}
			for _, Owner in _LLM_AuxOwners.Clone()
				_LLM_AuxRetireOwner(Owner, true)
			for Path in State["paths"]
				AssertFalse(FileExist(Path), "exact local payload custody must leave no private file")
			} finally {
			_LLM_Ollama_Async := Saved[1], _LLM_Ollama_Pending := Saved[2], _LLM_Ollama_PreflightPort := Saved[3]
			_LLM_Vision_OllamaTransport := Saved[4], _LLM_AuxOwners := Saved[5], _LLM_AuxCleanupDebt := Saved[6]
			}
		}
		ObserveOrigin(Self, Args*) {
			Origin.DeleteProp("Call")
			Result := Origin.Call(Args*)
			State["seen"] := true
			if Withdraw {
				if Phase == "origin-newer" {
					AssertTrue(_LAG_Invoke("llm_agent_selection"))
					AssertTrue(_LAG_Invoke("llm_agent_selection"))
					State["newest"] := _LLM_Ollama_AsyncCounter
					AssertTrue(_LLM_Ollama_Pending is Map, "the new request has a real reserved pending job")
					AssertEqual(State["newest"], _LLM_Ollama_Pending["req_id"])
				} else
					AssertTrue(LLM_Agent_SetMode("off"))
			}
			return Result
		}
		ObserveSpawn(Self, Id, Payload, PayloadPath, OutputPath, Job, OriginalPort := 0) {
			Spawn.DeleteProp("Call")
			State["id"] := Id
			return Spawn.Call(Id, Payload, PayloadPath, OutputPath, Job, Port)
		}
		List(Callback, Owner, Strict) {
			LLM_AuxBindResources(Owner, Map("finalizer", Owner["on_retired"]))
			Callback.Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200,
				"body", '{"models":[{"name":' . JsonStringLiteral(Owner["identity"]) . '}]}')))
		}
		Write(Path, Payload) {
			State["writes"] += 1
			State["paths"].Push(Path)
			Result := FSWrite(Path, Payload)
			if Phase == "write" {
				State["seen"] := true
				if Withdraw
					AssertTrue(LLM_Agent_SetMode("off"))
			}
			return Result
		}
		Run(Command, WorkingDir, Options, &Pid, &ProcessOwner) {
			State["runs"] += 1
			Pid := 990001
			ProcessOwner := Map("pid", Pid, "handle", 990001, "released", false)
			if Phase == "spawn" {
				State["seen"] := true
				if Withdraw && !State.Get("successor_created", false) {
					State["successor_created"] := true
					State["retired_id"] := State["id"], State["old_owner"] := ProcessOwner
					AssertTrue(LLM_Agent_SetMode("off"))
					AssertTrue(LLM_Agent_SetMode("action"))
					AssertTrue(_LAG_Invoke("llm_agent_selection"))
					State["successor_id"] := _LLM_Ollama_AsyncCounter
					AssertTrue(_LLM_Ollama_Pending is Map, "a genuine successor waits behind the acquired predecessor")
					AssertEqual(State["successor_id"], _LLM_Ollama_Pending["req_id"])
					AssertTrue(_LLM_Ollama_Pending["requester_current"].Call())
					Spawn.DefineProp("Call", {Call: ObserveSpawn})
				}
			}
		}
		Close(Handle) {
			AssertEqual(990001, Handle, "retirement receives the exact controlled native capability")
			State["closed"] += 1
			return true
		}
	}
}
for Phase in ["origin", "preflight", "write", "spawn"]
	for Withdraw in [true, false]
		Test("LLM agent: local requester native custody " . Phase . " withdrawal=" . Withdraw . " (agent-local-requester)",
			_LAG_LocalNativeCustody.Bind(Phase, Withdraw))
for Withdraw in [true, false]
	Test("LLM agent: local requester preserves newer pending job withdrawal=" . Withdraw . " (agent-local-pending-requester)",
		_LAG_LocalNativeCustody.Bind("origin-newer", Withdraw))

for MainDisabled in [true, false]
	Test("LLM agent: queued local source is independent from prediction switch disabled=" . MainDisabled . " (agent-local-independent-queue)",
		_LAG_LocalNativeCustody.Bind("queue-independent", MainDisabled))

; Pin the real timer window at the production busy-count read. A Critical RAM
; transaction defers this timer naturally; the fixture never invokes it there.
class _LAG_QP_BusyCount extends Map {
	__New(Registry, State) {
		super.__New()
		for Id, Entry in Registry
			this[Id] := Entry
		this.State := State
		this.Armed := false
	}
	Count {
		get {
			Captured := super.Count
			if this.Armed {
				this.Armed := false
				SetTimer(this.State["timer"], -1)
				if !A_IsCritical
					_LAG_QP_WaitForTimer(this.State)
			}
			return Captured
		}
	}
}

_LAG_QP_WaitForTimer(State) {
	Started := A_TickCount
	while !State["done"] && TickElapsed64(Started) < 2000
		Sleep(10)
	AssertTrue(State["done"], "the genuine publication-boundary timer must complete")
	if IsObject(State["error"])
		throw State["error"]
}

_LAG_QP_Publication(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "local"), _LTN_Screen(LAG_SELECTION), Body)
	Body(Fx, Lines, Sent) {
		global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort, _LLM_Ollama_AsyncCounter
		global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_Agent_Generation
		Saved := [_LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort,
			_LLM_Ollama_AsyncCounter, _LLM_AuxOwners, _LLM_AuxCleanupDebt]
		State := Map("done", false, "error", 0, "timer", Timer, "deferred", [], "failures", Map(),
			"successes", 0, "native_attempts", 0, "c_id", 0, "c_job", 0, "timer_critical", -1, "current_reads", 0, "pending_at_withdrawal", 0)
		Registry := 0
		Origin := LLM_OllamaCaptureOriginCustody
		AssertFalse(Origin.HasOwnProp("Call"), "the production origin owner must start unmodified")
		PreviousCritical := Critical("Off")
		try {
			_LLM_Ollama_Async := Map(), _LLM_Ollama_Pending := ""
			_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map()
			_LLM_Ollama_PreflightPort := Map("schedule", Schedule, "list_models", FailModelList, "spawn", RefuseNative)
			BusyId := Send("busy")
			AssertTrue(_LLM_Ollama_Async.Has(BusyId), "the actual public API must reserve its real active entry")
			AssertEqual(1, State["deferred"].Length, "the original active request owns a held preflight, not a process")
			if Mode != "busy-idle" {
				PriorId := Send("prior")
				PriorJob := _LLM_Ollama_Pending
			}
			Registry := _LAG_QP_BusyCount(_LLM_Ollama_Async, State)
			_LLM_Ollama_Async := Registry
			AdmissionBoundary := Mode == "admission-newer" || Mode == "admission-withdrawn"
			OriginBoundary := Mode == "origin-independent" || Mode == "origin-rejected"
			Registry.Armed := !AdmissionBoundary && !OriginBoundary
			if OriginBoundary
				Origin.DefineProp("Call", {Call: CaptureOrigin})
			Generation := _LLM_Agent_Generation
			Current := AdmissionBoundary ? AdmissionCurrent
				: (Mode == "newer-withdrawn" || Mode == "withdraw-only") ? _LLM_Agent_RenderIsCurrent.Bind(Generation) : 0
			OlderId := Send("older", Current)
			_LAG_QP_WaitForTimer(State)
			AssertEqual(0, State["timer_critical"], "the actual timer must run outside the publication transaction")
			AssertEqual(0, State["native_attempts"], "queue metadata controls cannot acquire a native transport")
			AssertEqual(0, State["successes"])
			AssertEqual(0, Fx.Ollama.Length, "the outer fixture recorder cannot replace the public local API")
			AssertEqual(0, Sent.Length)
			if Mode == "busy-idle" {
				AssertTrue(_LLM_Ollama_Async.Has(OlderId), "the genuine busy completion must drain the admitted older job into its active slot")
				AssertFalse(_LLM_Ollama_Pending is Map, "a stale busy snapshot cannot strand an idle pending job")
				AssertEqual(2, State["deferred"].Length, "the actual dispatcher must schedule the admitted successor")
				AssertEqual(1, State["failures"].Get("busy", 0))
			} else {
				WithdrawOnly := Mode == "withdraw-only" || Mode == "admission-withdrawn"
				WithdrewBeforePublication := WithdrawOnly && State["pending_at_withdrawal"] == PriorJob
				ExpectedId := Mode == "newer-independent" || Mode == "newer-withdrawn" || Mode == "callback-newer" || Mode == "admission-newer" || Mode == "origin-independent"
					? State["c_id"] : WithdrewBeforePublication ? PriorId : OlderId
				AssertTrue(_LLM_Ollama_Pending is Map, "the surviving accepted request owns a real pending job")
				AssertEqual(ExpectedId, _LLM_Ollama_Pending["req_id"], "an older invocation cannot replace a newer accepted pending job")
				AssertTrue(LLM_OllamaOriginCustodyCurrent(_LLM_Ollama_Pending["origin_custody"], _LLM_Ollama_Pending["base_url"]),
					"all scheduling controls preserve the genuine original transport origin")
				AssertEqual(WithdrewBeforePublication ? 0 : 1, State["failures"].Get("prior", 0),
					"only an admitted publication can displace and settle the independent predecessor")
				if WithdrawOnly {
					AssertFalse(Current.Call(), "the genuine source is withdrawn while transport origin remains current")
					if !WithdrewBeforePublication
						AssertEqual(OlderId, State["pending_at_withdrawal"]["req_id"], "a deferred withdrawal observes the already committed older job")
				}
				AssertEqual(0, State["failures"].Get("newer", 0), "the retained newer pending request has no terminal failure")
				if ExpectedId == State["c_id"]
					AssertTrue(_LLM_Ollama_Pending == State["c_job"], "the newer public call retains its exact published job")
				if Mode == "rejected-newer" || Mode == "origin-rejected"
					AssertTrue(State["c_id"] > OlderId, "a refused newer call really advances the raw request counter without publishing")
			}
			ExpectedOlderFailures := Mode == "newer-independent" || Mode == "callback-newer" || Mode == "admission-newer" || Mode == "origin-independent" ? 1 : 0
			AssertEqual(ExpectedOlderFailures, State["failures"].Get("older", 0),
				"an independent dropped older job settles once; withdrawn and still-pending owners stay silent")
		} finally {
			if Origin.HasOwnProp("Call")
				Origin.DeleteProp("Call")
			SetTimer(State["timer"], 0)
			if IsObject(Registry)
				Registry.Armed := false
			Owned := _LLM_Ollama_Async.Clone()
			_LLM_Ollama_Async := Map(), _LLM_Ollama_Pending := ""
			for _, Entry in Owned
				_LLM_Ollama_CleanupCurlFiles(Entry)
			for _, Owner in _LLM_AuxOwners.Clone()
				_LLM_AuxRetireOwner(Owner, true)
			_LLM_Ollama_Async := Saved[1], _LLM_Ollama_Pending := Saved[2], _LLM_Ollama_PreflightPort := Saved[3]
			_LLM_Ollama_AsyncCounter := Saved[4], _LLM_AuxOwners := Saved[5], _LLM_AuxCleanupDebt := Saved[6]
			State["deferred"] := [], State["timer"] := 0, State["c_job"] := 0, State["pending_at_withdrawal"] := 0
			if IsObject(Registry)
				Registry.State := 0
			Critical(PreviousCritical)
		}
		Send(Label, Current := 0) {
			Payload := '{"model":' . JsonStringLiteral(_LLM_LOCAL_DEFAULTS["llm_model"])
				. ',"messages":[{"role":"user","content":' . JsonStringLiteral(Label) . '}],"stream":false}'
			return LLM_OllamaChat_Async(Payload, (*) => State["successes"] += 1, Failure.Bind(Label), Current)
		}
		CaptureOrigin(Self, Args*) {
			Origin.DeleteProp("Call")
			Captured := Origin.Call(Args*)
			AssertFalse(A_IsCritical, "genuine origin capture stays outside queue publication")
			SetTimer(State["timer"], -1)
			_LAG_QP_WaitForTimer(State)
			return Captured
		}
		; Delay a genuine lifecycle read only to locate the scheduler window.
		; Under Critical the timer remains deferred; there is no direct reentry.
		AdmissionCurrent() {
			Captured := _LLM_Agent_RenderIsCurrent(Generation)
			State["current_reads"] += 1
			if State["current_reads"] == 2 {
				SetTimer(State["timer"], -1)
				if !A_IsCritical
					_LAG_QP_WaitForTimer(State)
			}
			return Captured
		}
		Failure(Label, *) {
			try {
				AssertFalse(A_IsCritical, "settlement callbacks must run outside the publication transaction")
				State["failures"][Label] := State["failures"].Get(Label, 0) + 1
				if Label == "prior" && Mode == "callback-newer"
					PublishNewer()
			} catch as Err
				State["error"] := Err
		}
		PublishNewer() {
			Current := Mode == "newer-withdrawn" ? _LLM_Agent_RenderIsCurrent.Bind(_LLM_Agent_Generation) : 0
			State["c_id"] := Send("newer", Current)
			State["c_job"] := _LLM_Ollama_Pending
		}
		Timer(*) {
			try {
				State["timer_critical"] := A_IsCritical
				if Mode == "withdraw-only" || Mode == "admission-withdrawn"
					State["pending_at_withdrawal"] := _LLM_Ollama_Pending
				if Mode == "newer-withdrawn" || Mode == "withdraw-only" || Mode == "admission-withdrawn" {
					AssertTrue(LLM_Agent_SetMode("off"), "a genuine committed mode withdrawal retires the older requester")
					if Mode == "newer-withdrawn"
						AssertTrue(LLM_Agent_SetMode("action"), "the newer requester enters the repaired same action owner")
				}
				if Mode == "newer-independent" || Mode == "newer-withdrawn" || Mode == "admission-newer" || Mode == "origin-independent"
					PublishNewer()
				else if Mode == "rejected-newer" || Mode == "origin-rejected"
					State["c_id"] := Send("rejected", (*) => false)
				else if Mode == "busy-idle"
					State["deferred"][1].Call()
			} catch as Err
				State["error"] := Err
			finally State["done"] := true
		}
		Schedule(Callback, Period) {
			State["deferred"].Push(Callback)
		}
		FailModelList(Callback, Owner, Strict) {
			LLM_AuxBindResources(Owner, Map("finalizer", Owner["on_retired"]))
			Callback.Call(LLM_LocalModelListReceipt(Map("ok", false, "status", 503, "body", "")))
		}
		RefuseNative(*) {
			State["native_attempts"] += 1
			throw Error("A queue-publication control cannot acquire a native transport.")
		}
	}
}
for _LAG_QP_Mode in ["newer-independent", "newer-withdrawn", "noop", "rejected-newer", "callback-newer", "busy-idle", "withdraw-only", "admission-newer", "admission-withdrawn", "origin-independent", "origin-rejected"]
	Test("Ollama pending publication: " . _LAG_QP_Mode . " (ollama-pending-publication)", _LAG_QP_Publication.Bind(_LAG_QP_Mode))

; Real automatic Jev producer -> real managed admission -> owned loopback HTTP.
; The existing agent context/menu isolation remains; no network subject is replaced.
global _JRO_Debt := []
_JRO_Cleanup(State) {
    global _LLM_Remote_Async, _JRO_Debt
    Errors := []
    try {
        if State.Id && State.Entry is Map && _LLM_Remote_Async.Get(State.Id, 0) == State.Entry {
            LLM_RemoteCancelAsync(State.Id)
            _LLMRemote_PollRequest(State.Id)
            AssertFalse(_LLM_Remote_Async.Has(State.Id), "the exact Jev reservation must retire")
        }
        if IsObject(State.Http)
            AssertTrue(State.Http.Abort(), "the exact managed native worker must acknowledge retirement")
    } catch Any as Err
        Errors.Push(Err)
    try {
        if State.Peer is Map && !State.Peer.Get("released", false) {
            AssertTrue(State.DirectoryOwned, "an unacknowledged root grants no stopfile publication authority")
            AssertTrue(FSWrite(State.StopPath, "owned stop"))
            Started := A_TickCount
            while !_LLM_CurlProcessExited(State.Peer) && TickElapsed64(Started) < 5000
                Sleep(10)
            AssertTrue(_LLM_CurlProcessExited(State.Peer))
            AssertTrue(_LLM_CurlReleaseProcess(State.Peer))
        }
    } catch Any as Err
        Errors.Push(Err)
    try {
        if Errors.Length == 0 && State.DirectoryOwned && State.Directory != "" && DirExist(State.Directory)
            DirDelete(State.Directory, true)
    } catch Any as Err
        Errors.Push(Err)
    if Errors.Length {
        for Err in Errors
            _TestPrint("# JEV_REQUEST_CLEANUP " . KL_JsonEncode(Map("error", Type(Err), "message", Err.Message)))
        throw Errors[1]
    }
}
_JRO_DrainDebt() {
    global _JRO_Debt
    Pending := []
    for State in _JRO_Debt {
        try _JRO_Cleanup(State)
        catch Any as Err
            Pending.Push(State)
    }
    _JRO_Debt := Pending
    AssertEqual(0, Pending.Length, "new probes cannot hide exact managed/peer cleanup debt")
}
; Observe only this fixture's already-owned HTTP/peer state. This diagnostic
; never completes, aborts or changes admission for the subject under test.
_JRO_Diagnostic(State, Lines, Phase, Current := 0) {
    global _LLM_Remote_Async
    try {
        Info := Map("phase", Phase, "critical", A_IsCritical, "suspended", A_IsSuspended,
            "id", State.Id, "directory_owned", State.DirectoryOwned,
            "reservation_present", State.Id > 0 && _LLM_Remote_Async.Has(State.Id),
            "exact_reservation", State.Id > 0 && State.Entry is Map && _LLM_Remote_Async.Get(State.Id, 0) == State.Entry)
        if HasMethod(Current, "Call")
            Info["original_requester_current"] := Current.Call()
        if State.Entry is Map {
            Info["entry_transport"] := State.Entry.Get("transport", "")
            Info["entry_format"] := State.Entry.Get("format", "")
            Info["entry_cancelled"] := State.Entry.Get("cancelled", false)
            Info["entry_elapsed_ms"] := TickElapsed64(State.Entry.Get("start_tick", A_TickCount))
            Info["entry_timeout_ms"] := State.Entry.Get("timeout_ms", 0)
            Info["entry_has_current_fn"] := HasMethod(State.Entry.Get("requester_current", 0), "Call")
        }
        if IsObject(State.Http) {
            Http := State.Http
            Info["http_completed"] := Http.Completed
            Info["http_aborted"] := Http.Aborted
            Info["http_status"] := Http.Status
            Info["http_managed"] := Http.ManagedTransport
            Info["http_payload_published"] := Http.ManagedPayloadPublished
            Info["http_handle_present"] := IsObject(Http.Handle)
            Info["http_admission_timer_present"] := IsObject(Http.ManagedAdmissionFn)
            Info["http_deadline_timer_present"] := IsObject(Http.DeadlineFn)
            Info["http_native_dispatch_refused"] := Http.HasOwnProp("NativeDispatchRefused") && Http.NativeDispatchRefused
            Info["http_native_receipt_present"] := Http.NativeReceipt is Map && Http.NativeReceipt.Count > 0
            Capture := Http.ManagedCapture
            if Capture is Map {
                Directory := Capture["CaptureDir"]
                for Name in ["admission.json", "transport.pending", "transport.json"]
                    Info["worker_has_" . Name] := FileExist(Directory . Name) != ""
            }
        }
        if State.Peer is Map {
            Info["peer_released"] := State.Peer.Get("released", false)
            if !Info["peer_released"]
                Info["peer_exited"] := _LLM_CurlProcessExited(State.Peer)
        }
        if State.DirectoryOwned {
            ReceiptPath := State.Directory . "\receipt.jsonl"
            Info["peer_receipt_present"] := FileExist(ReceiptPath) != ""
            if Info["peer_receipt_present"] {
                Bytes := FileGetSize(ReceiptPath)
                Info["peer_receipt_bytes"] := Bytes
                if Bytes <= 4096 {
                    Posts := 0, Statuses := []
                    for Line in StrSplit(FileRead(ReceiptPath, "UTF-8-RAW"), "`n", "`r") {
                        if Line == ""
                            continue
                        Row := JsonParse(Line)
                        if Row is Map && Row.Get("method", "") == "POST" {
                            Posts += 1
                            Statuses.Push(Row.Get("status", 0))
                        }
                    }
                    Info["peer_completed_posts"] := Posts, Info["peer_statuses"] := Statuses
                }
            }
        }
        Tail := []
        for Line in Lines {
            if A_Index > Max(0, Lines.Length - 8)
                Tail.Push(SubStr(Line, 1, 250))
        }
        Info["fixture_logger_tail"] := Tail
        _TestPrint("# JEV_REQUEST_PHASE " . KL_JsonEncode(Info))
    } catch Any as Err {
        _TestPrint("# JEV_REQUEST_PHASE_DIAGNOSTIC_ERROR " . KL_JsonEncode(Map("phase", Phase,
            "error", Type(Err), "message", SubStr(Err.Message, 1, 200))))
    }
}

_JRO_Body(Withdraw, Fx, Lines, Sent) {
    ; LAG -> LTN -> LPP is synchronous by default and holds Critical On.
    ; Only this real native fixture opens its message loop; restore the exact
    ; inherited scope after all genuine callbacks and cleanup have finished.
    PreviousCritical := Critical("Off")
    try _JRO_NativeBody(Withdraw, Fx, Lines, Sent)
    finally Critical(PreviousCritical)
}

_JRO_NativeBody(Withdraw, Fx, Lines, Sent) {
    global _DriverDir, _LLM_Menu, _LLM_Engine, _LLM_Remote_PostBodyFn
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _JRO_Debt
    global _LLM_Agent_Generation, _LLM_Agent_System1Revision
    AssertFalse(A_IsCritical, "native managed admission and polling need an open message loop")
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count)
    State := {Directory: "", DirectoryOwned: false, StopPath: "", Peer: 0, Id: 0, Entry: 0, Http: 0}
    Primary := 0
    try {
        State.Directory := A_Temp . "\ergopti_jev_owner_" . A_TickCount . "_" . Random(1, 1000000)
        Created := FSCreateDirectoryExclusiveStrict(State.Directory)
        if !(Created is Integer) || Created != 1
            throw Error("The private Jev directory has no exact exclusive-creation acknowledgement.")
        State.DirectoryOwned := true
        ReadyPath := State.Directory . "\ready.txt", ReceiptPath := State.Directory . "\receipt.jsonl"
        State.StopPath := State.Directory . "\owned.stop"
        PeerScript := _DriverDir . "\tests\fixtures\jev_request_ownership_peer.ahk"
        AssertTrue(FileExist(PeerScript))
        Command := _SR_BuildDirectCommandLine(A_AhkPath,
            ["/ErrorStdOut", PeerScript, ReadyPath, ReceiptPath, "200", "done", State.StopPath])
        PeerPid := 0
        _LLM_CurlArtifactRun(Command, State.Directory, "Hide", &PeerPid, &Peer)
        State.Peer := Peer
        Started := A_TickCount
        while !FileExist(ReadyPath) && !_LLM_CurlProcessExited(Peer) && TickElapsed64(Started) < 5000
            Sleep(10)
        AssertTrue(FileExist(ReadyPath), "the actual loopback peer publishes its OS-owned port")
        Ready := FileRead(ReadyPath, "UTF-8-RAW")
        AssertTrue(RegExMatch(Ready, "^[0-9]{1,5}`n\z"))
        Port := Integer(SubStr(Ready, 1, -1))
        AssertTrue(Port > 0 && Port <= 65535)
        ; Decisions base_url is the complete endpoint, so the private peer's
        ; existing /api/chat route is a valid configured Jev endpoint here.
        for Entry in _LLM_Menu["api_entries"]
            if Entry["Provider"] == "typesafe"
                Entry["BaseUrl"] := "http://127.0.0.1:" . Port . "/api/chat"
        for Entry in _LLM_Engine["api_entries"]
            if Entry["Provider"] == "typesafe"
                Entry["BaseUrl"] := "http://127.0.0.1:" . Port . "/api/chat"
        _LLM_Remote_PostBodyFn := 0
        Fx.App := "Slack"
        TooltipHide("JevOwnerProbe", true)
        Pause := _LAG_Type(Fx, LAG_TYPED)
        AssertTrue(HasMethod(Pause, "Call"), "real typing arms its genuine System1 pause callback")
        Before := _LLM_Remote_AsyncCounter
        AssertTrue(Pause.Call(), "the real automatic triage selects the decisions producer")
        State.Id := Before + 1
        AssertEqual(State.Id, _LLM_Remote_AsyncCounter, "System1 creates exactly one actual remote reservation")
        AssertTrue(_LLM_Remote_Async.Has(State.Id))
        State.Entry := _LLM_Remote_Async[State.Id], State.Http := State.Entry["http"]
        Http := State.Http
        AssertTrue(Http is CurlAsyncRequest && Http.ManagedTransport)
        Generation := _LLM_Agent_Generation, Revision := _LLM_Agent_System1Revision
        Current := _LLM_Agent_TriageIsCurrent.Bind(Generation, Revision)
        ; This bounded RAM transaction only verifies the genuine native
        ; pre-publication boundary and invokes the real typing withdrawal.
        PreviousCritical := Critical("On")
        try {
            AssertFalse(Http.ManagedPayloadPublished, "the fixture must reach the real worker before credential/payload publication")
            AssertTrue(Current.Call())
            if Withdraw
                LLM_Agent_InvalidateTyping()
            AssertEqual(!Withdraw, Current.Call(), "only the public withdrawal changes the original requester authority")
        } finally Critical(PreviousCritical)
        AssertFalse(A_IsCritical, "the short owner mutation must restore the open native loop")
        Started := A_TickCount
        while _LLM_Remote_Async.Has(State.Id) && TickElapsed64(Started) < 20000 {
            _SR_TreePoll()
            Sleep(10)
        }
        _JRO_Diagnostic(State, Lines, "after-native-wait", Current)
        AssertFalse(_LLM_Remote_Async.Has(State.Id), "the actual remote reservation settles before peer shutdown")
        AssertTrue(Http.Completed)
        AssertFalse(IsObject(Http.Handle), "the real managed worker has retired its exact native handle")
        AssertTrue(State.DirectoryOwned, "normal stop uses only the exclusively acknowledged root")
        AssertTrue(FSWrite(State.StopPath, "owned stop"))
        Started := A_TickCount
        while !_LLM_CurlProcessExited(Peer) && TickElapsed64(Started) < 5000
            Sleep(10)
        AssertTrue(_LLM_CurlProcessExited(Peer))
        ExitCode := -1, Diagnostic := ""
        AssertTrue(_SR_TreeReadExitCode(Peer["handle"], &ExitCode, &Diagnostic))
        AssertEqual(0, ExitCode)
        AssertTrue(_LLM_CurlReleaseProcess(Peer))
        Posts := 0
        if FileExist(ReceiptPath) {
            for Line in StrSplit(FileRead(ReceiptPath, "UTF-8-RAW"), "`n", "`r") {
                if Line == ""
                    continue
                Record := JsonParse(Line)
                AssertEqual("POST", Record["method"]), AssertEqual("/api/chat", Record["path"])
                AssertEqual(200, Record["status"])
                Posts += 1
            }
        }
        _TestPrint("# JEV_REQUEST_OWNER " . KL_JsonEncode(Map("withdraw", Withdraw,
            "requester_current", Current.Call(), "payload_published", Http.ManagedPayloadPublished,
            "http_posts", Posts, "completed", Http.Completed, "aborted", Http.Aborted,
            "reservation_present", _LLM_Remote_Async.Has(State.Id), "native_handle_retired", !IsObject(Http.Handle))))
        AssertEqual(Withdraw ? 0 : 1, Posts, "a withdrawn original System1 owner cannot publish a new HTTP request")
        AssertEqual(!Withdraw, Http.ManagedPayloadPublished)
        AssertEqual(0, Sent.Length)
        AssertEqual(0, Fx.Remote.Length + Fx.Ollama.Length + Fx.Posts.Length,
            "this test reaches the genuine transport, with no captured fake network subject")
        if !Withdraw
            AssertTrue(_LVS_LinesMentioning(Lines, "nothing suggested") > 0,
                "the live Jev none-choice reaches the actual triage consumer without waking System2")
    } catch Any as Err {
        Primary := Err
        _JRO_Diagnostic(State, Lines, "before-cleanup", IsSet(Current) ? Current : 0)
    } finally {
        try _JRO_Cleanup(State)
        catch Any as Err {
            _JRO_Debt.Push(State)
            if !IsObject(Primary)
                Primary := Err
        }
    }
    if IsObject(Primary)
        throw Primary
}
_JRO_AgentScope(Withdraw) {
    _LAG_Run(_LAG_Menu("auto", "typesafe", "cerebras"), _LTN_Screen(""), _JRO_Body.Bind(Withdraw))
}
_JRO_Run(Withdraw) {
    _JRO_DrainDebt()
    _ManagedRemoteFixtureWithLlmTimings(_LATHTTP_HostScope.Bind(_JRO_AgentScope.Bind(Withdraw)))
}
for _JRO_Withdraw in [false, true]
    Test("Jev native requester: " . (_JRO_Withdraw ? "withdrawn" : "live") . " retains managed publication authority (jev-native-requester)",
        _JRO_Run.Bind(_JRO_Withdraw))
