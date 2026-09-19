; tests/unit/test_llm_api_test_entry.ahk

; ==============================================================================
; MODULE: LLM API Test-Entry Action Tests
; DESCRIPTION:
; The Test-selected-API row sends the shared minimal probe
; (api_providers.json test_request, verbatim) to the active entry and
; surfaces the verdict. Unlike the save-time /models ping this proves the
; full path: credentials, model id and body format. The token never reaches
; a tip or a log — only the entry name, latency and a short reply excerpt.
;
; Stale completions (entry changed or deleted mid-flight, driver suspended)
; are discarded exactly like the validation flow, and refusals (no active
; entry, missing shared spec) stay fail-closed without touching the network.
; ==============================================================================

#Requires AutoHotkey v2.0

_LAT_FixtureEntry() {
	return Map("Id", "prod", "Name", "Prod", "Provider", "openai",
		"BaseUrl", "https://b.invalid/v1", "Token", "secret", "Model", "b")
}

_LAT_FixtureMenu() {
	global _LLM_Menu
	SavedMenu := _LLM_Menu
	_LLM_Menu := Map("enabled", true, "backend", "api", "api_entry_id", "prod",
		"api_entries", [_LAT_FixtureEntry()])
	return SavedMenu
}

_LAT_RestoreMenu(SavedMenu) {
	global _LLM_Menu
	_LLM_Menu := SavedMenu
}

_LAT_ResetOwners() {
	global _LLM_AuxGeneration := 41
	global _LLM_AuxOwnerCounter := 0
	global _LLM_AuxOwners := Map()
	global _LLM_AuxCleanupDebt := Map()
	global _LLM_AuxCleanupDebtCounter := 0
}

_LAT_TestOwner(EntryId := "prod") {
	return LLM_AuxBegin("api_test:" . EntryId, Map(
		"backend", "api",
		"endpoint", "https://b.invalid/v1",
		"identity", EntryId))
}

; The rows builder must expose the Test row for the active entry, with a
; callable action. The row is the only user path to the probe.
_LAT_RowsExposeTestAction() {
	SavedMenu := _LAT_FixtureMenu()
	try {
		Rows := _LLM_Menu_ApiEntriesRows()
		Found := false
		for Row in Rows {
			if (Row.Has("label") && Row["label"] == t("menu.llm.api_test_entry")) {
				Found := true
				AssertTrue(HasMethod(Row["action"], "Call"),
					"the Test row must carry a callable action")
			}
		}
		AssertTrue(Found, "the API entries menu must offer a Test-selected-API row")
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: entries menu exposes a Test-selected-API row (api-test-entry-row)",
	_LAT_RowsExposeTestAction)

; Row order: entries, then Add, then the separator with the management
; rows (Test/Edit/Remove — most frequent first, destructive delete last).
; Add must sit before the separator so creating an entry is one glance
; away; with no entries there is no dangling separator at all.
_LAT_RowsOrder() {
	SavedMenu := _LAT_FixtureMenu()
	try {
		Rows := _LLM_Menu_ApiEntriesRows()
		Pos := Map()
		for i, Row in Rows {
			if Row.Has("separator") {
				if !Pos.Has("sep")
					Pos["sep"] := i
			} else if Row.Has("label") {
				for Key in ["api_add_entry", "api_edit_entry",
					"api_test_entry", "api_remove_entry"] {
					if (Row["label"] == t("menu.llm." . Key) && !Pos.Has(Key))
						Pos[Key] := i
				}
			}
		}
		AssertTrue(Pos.Has("api_add_entry"), "the Add row must exist with entries present")
		AssertTrue(Pos["sep"] > Pos["api_add_entry"], "the Add row must sit before the separator")
		AssertTrue(Pos["api_test_entry"] > Pos["sep"], "Test must come after the separator")
		AssertTrue(Pos["api_edit_entry"] > Pos["api_test_entry"], "Edit must come after Test")
		AssertTrue(Pos["api_remove_entry"] > Pos["api_edit_entry"], "Delete must come last")
		_LLM_Menu["api_entries"] := []
		Rows := _LLM_Menu_ApiEntriesRows()
		for Row in Rows {
			AssertFalse(Row.Has("separator"),
				"with no entries there must be no dangling separator")
		}
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: Add sits before the separator, none when empty (api-test-entry-row-order)",
	_LAT_RowsOrder)

; Entry rows show the defined name only: the provider/model suffix is
; folded into the default name at creation, so the list never repeats it.
_LAT_EntryRowsShowNameOnly() {
	SavedMenu := _LAT_FixtureMenu()
	try {
		Rows := _LLM_Menu_ApiEntriesRows()
		Found := false
		for Row in Rows {
			if (Row.Has("label") && InStr(Row["label"], "Prod") == 1) {
				Found := true
				AssertEqual("Prod", Row["label"])
			}
		}
		AssertTrue(Found, "the entry row must list the defined name")
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: entry rows show the defined name only (api-test-entry-row-name)",
	_LAT_EntryRowsShowNameOnly)

; A default name collides safely: creation appends a counter, editing
; keeps its own name untouched.
_LAT_UniqueEntryName() {
	Entries := [Map("Id", "a", "Name", "cerebras/qwen"),
		Map("Id", "b", "Name", "cerebras/qwen (2)")]
	AssertEqual("cerebras/qwen (3)",
		_LLM_Menu_UniqueApiEntryName("cerebras/qwen", Entries, ""),
		"a taken default name must count up")
	AssertEqual("mine", _LLM_Menu_UniqueApiEntryName("mine", Entries, ""),
		"a free name must pass through")
	AssertEqual("cerebras/qwen",
		_LLM_Menu_UniqueApiEntryName("cerebras/qwen", Entries, "a"),
		"editing must keep its own name without suffix")
}
Test("llm api test: default names dedupe, edits keep theirs (api-test-entry-unique-name)",
	_LAT_UniqueEntryName)

; The creation dialog asks the name LAST (provider, URL, token, model
; first) so the default can be provider/model. Scanned comment-stripped.
_LAT_PromptOrder() {
	Code := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PromptApiEntry"))
	Assert(Code != "", "_LLM_Menu_PromptApiEntry must remain source-visible")
	Pos := Map()
	for Key in ["api_prompt_provider", "api_prompt_url", "api_prompt_token",
		"api_prompt_model", "api_prompt_name"] {
		At := InStr(Code, Key)
		Assert(At > 0, "the dialog must prompt " . Key)
		Pos[Key] := At
	}
	AssertTrue(Pos["api_prompt_provider"] < Pos["api_prompt_url"],
		"provider comes first")
	AssertTrue(Pos["api_prompt_url"] < Pos["api_prompt_token"],
		"URL comes before the token")
	AssertTrue(Pos["api_prompt_token"] < Pos["api_prompt_model"],
		"token comes before the model")
	AssertTrue(Pos["api_prompt_model"] < Pos["api_prompt_name"],
		"name comes last so its default is provider/model")
	Assert(InStr(Code, 'provider_id . "/" . new_model') > 0,
		"the name default must be provider/model")
}
Test("llm api test: creation asks the name last with provider/model default (api-test-entry-prompt-order)",
	_LAT_PromptOrder)

; After a creation persist the flow offers the end-to-end probe on the new
; (now active) entry; edits never ask. The stubbed MsgBox declines, so the
; helper documents its headless default. Scanned comment-stripped.
_LAT_AskDefaultsDecline() {
	AssertFalse(_LLM_Menu_AskTestNewApiEntry(),
		"without a user answer the offer must decline, never probe")
	Code := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PromptApiEntry"))
	Assert(Code != "", "_LLM_Menu_PromptApiEntry must remain source-visible")
	PersistAt := InStr(Code, "LLM_Menu_CommitApiEntriesMutation")
	AskAt := InStr(Code, "_LLM_Menu_AskTestNewApiEntry(")
	TestAt := InStr(Code, "_LLM_Menu_TestActiveApiEntry(")
	Assert(PersistAt > 0 && AskAt > PersistAt,
		"the offer must come after the persist, never before")
	Assert(TestAt > AskAt,
		"a confirmed offer must dispatch the probe on the new entry")
}
Test("llm api test: creation offers the probe after persist (api-test-entry-add-offers-probe)",
	_LAT_AskDefaultsDecline)

; No active entry, or an entry id pointing nowhere: refuse before any owner,
; request or network. The refusal still surfaces through the seam (MsgBox in
; production) — a clicked Test action must never end in silence.
_LAT_RefusesWithNoActiveEntry() {
	SavedMenu := _LAT_FixtureMenu()
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	try {
		_LLM_Menu["api_entries"] := []
		_LLM_Menu["api_entry_id"] := ""
		AssertFalse(_LLM_Menu_TestActiveApiEntry(NotifyFn),
			"an empty entry list must refuse the probe")
		_LLM_Menu["api_entries"] := [_LAT_FixtureEntry()]
		_LLM_Menu["api_entry_id"] := "ghost"
		AssertFalse(_LLM_Menu_TestActiveApiEntry(NotifyFn),
			"an entry id pointing nowhere must refuse the probe")
		AssertEqual(2, Notices.Length, "each refusal must surface, not vanish")
		for Notice in Notices {
			AssertFalse(Notice["ok"])
			AssertEqual(t("menu.llm.api_dialog_title"), Notice["tip"]["title"])
			AssertEqual(t("menu.llm.api_no_entry"), Notice["tip"]["body"])
		}
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: refuses with no active entry, without dispatching (api-test-entry-no-active)",
	_LAT_RefusesWithNoActiveEntry)

; A missing shared spec must refuse loudly instead of probing with invented
; values (single-source contract).
_LAT_RefusesWithMissingSpec() {
	global LLM_REMOTE_TEST_REQUEST
	SavedMenu := _LAT_FixtureMenu()
	SavedSpec := LLM_REMOTE_TEST_REQUEST
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	try {
		LLM_REMOTE_TEST_REQUEST := Map()
		AssertFalse(_LLM_Menu_TestActiveApiEntry(NotifyFn),
			"a missing shared probe spec must refuse the probe")
		AssertEqual(1, Notices.Length, "the refusal must surface, not vanish")
		AssertFalse(Notices[1]["ok"])
		AssertEqual(t("menu.llm.api_providers_unavailable"), Notices[1]["tip"]["body"])
	} finally {
		LLM_REMOTE_TEST_REQUEST := SavedSpec
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("llm api test: refuses when the shared probe spec is unavailable (api-test-entry-no-spec)",
	_LAT_RefusesWithMissingSpec)

; The verdict triple is pure: success carries name, latency and excerpt (long
; replies truncated); empty replies and failures map to the unreachable pair.
_LAT_TipMapping() {
	Tip := _LLM_Menu_ApiTestTip(true, "Prod", 42, "OK")
	AssertTrue(Tip["ok"])
	AssertEqual(t("menu.llm.api_test_ok_title"), Tip["title"])
	AssertEqual(Format(t("menu.llm.api_test_ok_body"), "Prod", 42, "OK"), Tip["body"])
	Long := ""
	Loop 200
		Long .= "x"
	Tip := _LLM_Menu_ApiTestTip(true, "Prod", 7, Long)
	AssertTrue(InStr(Tip["body"], "Prod") > 0, "the body must name the entry")
	AssertTrue(InStr(Tip["body"], "7 ms") > 0, "the body must carry the latency")
	AssertFalse(InStr(Tip["body"], Long) > 0, "a long reply must be excerpted, not pasted whole")
	Tip := _LLM_Menu_ApiTestTip(true, "Prod", 7, "")
	AssertFalse(Tip["ok"], "an empty reply proves nothing and must read as failure")
	AssertEqual(t("menu.llm.api_unreachable_title"), Tip["title"])
	Tip := _LLM_Menu_ApiTestTip(false, "Prod", 9, "")
	AssertFalse(Tip["ok"])
	AssertEqual(t("menu.llm.api_unreachable_title"), Tip["title"])
	AssertEqual(StrReplace(t("menu.llm.api_unreachable_body"), "%s", "Prod"), Tip["body"])
}
Test("llm api test: verdict triple maps success, truncation and failure (api-test-entry-tip)",
	_LAT_TipMapping)

; One current completion notifies once through the seam; a superseded owner,
; a deleted entry and a suspended driver stay silent.
_LAT_CompletionOwnership() {
	SavedMenu := _LAT_FixtureMenu()
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	try {
		_LAT_ResetOwners()
		Owner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_OnApiTestDone(true, "OK", "prod", "Prod",
			A_TickCount - 12, Owner, NotifyFn),
			"the current completion must publish")
		AssertEqual(1, Notices.Length, "exactly one notification may survive")
		AssertTrue(Notices[1]["ok"])
		AssertEqual(t("menu.llm.api_test_ok_title"), Notices[1]["tip"]["title"])

		StaleOwner := LLM_AuxBegin("api_test:prod", Map(
			"backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		NewOwner := _LAT_TestOwner()
		AssertFalse(_LLM_Menu_OnApiTestDone(true, "OK", "prod", "Prod",
			A_TickCount, StaleOwner, NotifyFn),
			"a superseded probe result must not relabel the newer one")
		AssertEqual(1, Notices.Length)

		_LLM_Menu["api_entries"] := []
		AssertFalse(_LLM_Menu_OnApiTestDone(true, "OK", "prod", "Prod",
			A_TickCount, NewOwner, NotifyFn),
			"a deleted entry must never produce a late notification")
		AssertEqual(1, Notices.Length,
			"only the current completion may notify")
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: completion ownership silences stale and deleted entries (api-test-entry-ownership)",
	_LAT_CompletionOwnership)

; A failed probe notifies through the seam exactly like a success: the
; unreachable title, never silence. (Production shows it in a MsgBox; the
; 23:26 timeout proved a TrayTip-only verdict is invisible in practice.)
_LAT_FailureCompletionNotifies() {
	SavedMenu := _LAT_FixtureMenu()
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	try {
		_LAT_ResetOwners()
		Owner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_OnApiTestDone(false, "", "prod", "Prod",
			A_TickCount - 30031, Owner, NotifyFn),
			"a failed completion must publish like a success")
		AssertEqual(1, Notices.Length, "exactly one notification may survive")
		AssertFalse(Notices[1]["ok"])
		AssertEqual(t("menu.llm.api_unreachable_title"), Notices[1]["tip"]["title"])
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: failed probe notifies through the seam (api-test-entry-failure)",
	_LAT_FailureCompletionNotifies)

; The failure verdict carries the server's own words (status + message):
; a 402 quota refusal must read as quota, never as a generic unreachable.
_LAT_FailureServerMessageNotifies() {
	SavedMenu := _LAT_FixtureMenu()
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	try {
		_LAT_ResetOwners()
		Owner := _LAT_TestOwner()
		Info := Map("reason", "no_completion", "status", 402,
			"message", "Payment required to access this resource. Visit your billing tab.")
		AssertTrue(_LLM_Menu_OnApiTestDone(false, "", "prod", "Prod",
			A_TickCount - 120032, Owner, NotifyFn, Info),
			"a failed completion with server info must publish")
		AssertEqual(1, Notices.Length)
		AssertFalse(Notices[1]["ok"])
		AssertContains(Notices[1]["tip"]["body"], "402")
		AssertContains(Notices[1]["tip"]["body"], "Payment required")
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: failure verdict carries the server message (api-test-entry-server-message)",
	_LAT_FailureServerMessageNotifies)

; Contract: every remote on_fail hand-off carries a failure Info map, and
; both user-facing closures accept it (optional, so zero-arg callers keep
; working). Scanned comment-stripped so prose can never satisfy it.
_LAT_FailureInfoContract() {
	Poll := _StripFullLineComments(_DriverFuncBody("_LLMRemote_PollCurl"))
	Assert(Poll != "", "_LLMRemote_PollCurl must remain source-visible")
	Assert(InStr(Poll, "_LLMRemote_FailInfo(") > 0,
		"the curl poller must build failure info for on_fail")
	Assert(InStr(Poll, '"on_fail", _LLMRemote_FailInfo(') > 0,
		"the curl poller must hand the info to on_fail")
	Handler := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_TestActiveApiEntry"))
	Assert(InStr(Handler, "(Info := ") > 0,
		"the test on_fail closure must accept the failure info")
	Assert(InStr(Handler, "OnApiTestDone(false") > 0,
		"the test on_fail closure must forward to the verdict")
	Batch := _StripFullLineComments(_DriverFuncBody("_LLM_Engine_DispatchBatch"))
	Assert(InStr(Batch, "(failure := ") > 0,
		"the batch on_fail closure must accept the failure info")
}
Test("llm api test: failure info reaches every on_fail (api-test-entry-server-message)",
	_LAT_FailureInfoContract)

; Contract: every Test-action outcome ends in _LLM_Menu_ApiTestSurface (MsgBox
; in production), never a bare TrayTip. Scanned comment-stripped so prose can
; never satisfy the assertions.
_LAT_MsgBoxContract() {
	for FnName in ["_LLM_Menu_ApiTestSurface", "_LLM_Menu_TestActiveApiEntry",
			"_LLM_Menu_OnApiTestDone"] {
		Code := _StripFullLineComments(_DriverFuncBody(FnName))
		Assert(Code != "", FnName . " must remain source-visible")
	}
	Surface := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_ApiTestSurface"))
	Assert(InStr(Surface, "MsgBox(") > 0,
		"the surface seam must pop a MsgBox in production")
	Assert(InStr(Surface, "TrayTip(") == 0,
		"the surface seam must never fall back to a TrayTip")
	for FnName in ["_LLM_Menu_TestActiveApiEntry", "_LLM_Menu_OnApiTestDone"] {
		Code := _StripFullLineComments(_DriverFuncBody(FnName))
		Assert(InStr(Code, "_LLM_Menu_ApiTestSurface(") > 0,
			FnName . " must route its verdict through the surface seam")
		Assert(InStr(Code, "TrayTip(") == 0,
			FnName . " must not show a bare TrayTip for a Test verdict")
	}
}
Test("llm api test: verdicts surface through MsgBox, never TrayTip (api-test-entry-msgbox)",
	_LAT_MsgBoxContract)

; Contract: the probe tags its reservation with the owned-probe kind, and both
; engine cancel paths spare that kind. Otherwise every keystroke during the
; probe (ResetPredictions, per-keystroke CancelInflight) silently kills it:
; the poller sees a missing reservation and fires neither callback. Scanned
; comment-stripped so prose can never satisfy the assertions.
_LAT_SurvivesTypingCancels() {
	Handler := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_TestActiveApiEntry"))
	Assert(Handler != "", "_LLM_Menu_TestActiveApiEntry must remain source-visible")
	Assert(InStr(Handler, "LLM_REMOTE_KIND_API_TEST") > 0,
		"the probe must tag its reservation with the owned-probe kind")
	for FnName in ["LLM_Engine_StopGeneration", "LLM_Engine_CancelInflight"] {
		Code := _StripFullLineComments(_DriverFuncBody(FnName))
		Assert(Code != "", FnName . " must remain source-visible")
		Assert(InStr(Code, "LLM_RemoteCancelAllAsync(LLM_REMOTE_KIND_API_TEST)") > 0,
			FnName . " must spare the owned probe when cancelling prediction work")
	}
}
Test("llm api test: typing never cancels the probe (api-test-entry-survives-typing)",
	_LAT_SurvivesTypingCancels)

; Contract: the click shows a cancellable progress immediately, the completion
; hides it, Cancel aborts the request, and the probe gets a longer timeout
; than predictions (cold models need more than 30 s). Scanned
; comment-stripped so prose can never satisfy the assertions.
_LAT_ProgressContract() {
	Handler := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_TestActiveApiEntry"))
	Assert(Handler != "", "_LLM_Menu_TestActiveApiEntry must remain source-visible")
	Assert(InStr(Handler, "_LLM_Menu_ApiTestProgressShow(") > 0,
		"the click must show a cancellable progress immediately")
	Assert(InStr(Handler, "LLM_API_TEST_TIMEOUT_MS") > 0,
		"the probe must use its own longer timeout, not the prediction one")
	Done := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_OnApiTestDone"))
	Assert(Done != "", "_LLM_Menu_OnApiTestDone must remain source-visible")
	Assert(InStr(Done, "_LLM_Menu_ApiTestProgressHide(") > 0,
		"the completion must hide the progress before popping the verdict")
	Cancel := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_ApiTestProgressCancel"))
	Assert(Cancel != "", "_LLM_Menu_ApiTestProgressCancel must remain source-visible")
	Assert(InStr(Cancel, "LLM_RemoteCancelAsync(") > 0,
		"Cancel must abort the in-flight request")
	Gen := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(InStr(Gen, "TimeoutMs := 0") > 0,
		"the generator must accept a timeout override")
	Assert(InStr(Gen, "TimeoutMs > 0") > 0,
		"the generator must honor the timeout override")
}
Test("llm api test: progress, cancel and longer timeout are wired (api-test-entry-progress)",
	_LAT_ProgressContract)

; The progress label is pure: entry name, elapsed whole seconds, and the
; budget so the user sees the limit (no open-ended wait).
_LAT_ProgressText() {
	Label := _LLM_Menu_ApiTestProgressText("Cerebras", 62000, 120000)
	Assert(InStr(Label, "Cerebras") > 0, "the label must name the entry")
	Assert(InStr(Label, "62") > 0, "the label must carry elapsed seconds")
	Assert(InStr(Label, "120") > 0, "the label must show the budget")
}
Test("llm api test: progress label names entry and elapsed time (api-test-entry-progress-text)",
	_LAT_ProgressText)

; Cancelling with no window open is headless-safe: it aborts the request id,
; finishes the owner so a late completion stays silent, clears the state, and
; never touches UI.
_LAT_ProgressCancel() {
	global _LLM_Menu_ApiTestProgress
	_LAT_ResetOwners()
	Owner := _LAT_TestOwner()
	_LLM_Menu_ApiTestProgress := Map("entry", "prod", "name", "Prod",
		"req_id", 999888, "owner", Owner, "start", A_TickCount)
	AssertTrue(_LLM_Menu_ApiTestProgressCancel(),
		"cancel must succeed when a probe is showing")
	AssertFalse(_LLM_Menu_ApiTestProgress.Has("entry"),
		"cancel must clear the progress state")
	AssertFalse(LLM_AuxIsCurrent(Owner),
		"cancel must finish the owner so a late completion stays silent")
	AssertFalse(_LLM_Menu_ApiTestProgressCancel(),
		"cancel with nothing showing must report false, not throw")
}
Test("llm api test: cancel aborts headlessly and stays silent (api-test-entry-progress-cancel)",
	_LAT_ProgressCancel)
