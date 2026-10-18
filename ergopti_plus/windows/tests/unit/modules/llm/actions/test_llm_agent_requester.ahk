; tests/unit/modules/llm/actions/test_llm_agent_requester.ahk

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

/** A committed requester withdrawal must survive the held model-consent dialog. */
_LAG_RequesterWithdrawal(Mode) {
	_LAG_Run(_LAG_Menu("action", "", "local", Mode != "prediction-off"), _LTN_Screen(LAG_SELECTION), Body)
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
				|| Mode == "refused-write" || Mode == "prediction-off"
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
	"same-source", "same-mode", "unrelated", "refused-write", "prediction-off", "late-failure"]
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
