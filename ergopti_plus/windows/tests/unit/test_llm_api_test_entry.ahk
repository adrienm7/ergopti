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

; Entry rows show the automatic name, never the one the fixture's entry
; stored (api-entry-auto-name, test_llm_api_entry_names.ahk).
_LAT_EntryRowsShowNameOnly() {
	SavedMenu := _LAT_FixtureMenu()
	try {
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual("openai/b", Rows[1]["label"], "the entry row reads provider/model")
		for Row in Rows
			AssertFalse(Row.Get("label", "") == "Prod", "the stored name is never shown")
	} finally _LAT_RestoreMenu(SavedMenu)
}
Test("llm api test: entry rows show the automatic name (api-test-entry-row-name)",
	_LAT_EntryRowsShowNameOnly)

; The creation dialog asks the provider first, then the URL, the key and the
; model; it asks no name. Scanned comment-stripped.
_LAT_PromptOrder() {
	Code := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PromptApiEntry"))
	Assert(Code != "", "_LLM_Menu_PromptApiEntry must remain source-visible")
	Pos := Map()
	for Key in ["api_prompt_provider", "api_prompt_url", "api_prompt_token",
		"api_prompt_model"] {
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
	AssertEqual(0, InStr(Code, "api_prompt_name"), "the dialog asks no name")
}
Test("llm api test: creation asks provider, URL, key and model (api-test-entry-prompt-order)",
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

/** Native monotonic observations exercise ordinary and DWORD-boundary uptimes. */
_LAT_ProbeClockProgress(Origin, Elapsed, Budget := 120000) {
	global _LLM_Menu_ApiTestProgress
	Saved := _LLM_Menu_ApiTestProgress
	Label := { Text: "unpublished" }
	Bar := { Value: -1 }
	try {
		_LLM_Menu_ApiTestProgress := Map("entry", "prod", "name", "Prod",
			"start", Origin, "budget", Budget, "label", Label, "bar", Bar)
		_LLM_Menu_ApiTestProgressTick(Origin + Elapsed)
		AssertEqual(_LLM_Menu_ApiTestProgressText("Prod", Elapsed, Budget), Label.Text,
			"the real timer must publish full elapsed whole seconds from the native monotonic clock")
		AssertEqual(Budget > 0 ? Min(100, (Elapsed * 100) // Budget) : 0, Bar.Value,
			"the real timer must retain its capped progress and zero-budget behavior")
	} finally _LLM_Menu_ApiTestProgress := Saved
}
for Origin in [0, 100, 0xFFFFFFF0]
	for Elapsed in [0, 999, 1000, 119999, 120000, 120001]
		Test("llm api probe clock: progress origin=" . Origin . " elapsed=" . Elapsed,
			_LAT_ProbeClockProgress.Bind(Origin, Elapsed))
for Origin in [0, 100, 0xFFFFFFF0]
	Test("llm api probe clock: zero budget origin=" . Origin,
		_LAT_ProbeClockProgress.Bind(Origin, 1000, 0))

/** Completion retains real auxiliary ownership and publishes exact elapsed time. */
_LAT_ProbeClockCompletion(Origin, Elapsed := 1234) {
	global _LLM_Menu_ApiTestProgress, _LLM_AuxGeneration, _LLM_AuxOwnerCounter
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	SavedMenu := _LAT_FixtureMenu()
	SavedProgress := _LLM_Menu_ApiTestProgress
	SavedOwners := [_LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners,
		_LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter]
	Notices := []
	try {
		_LAT_ResetOwners()
		_LLM_Menu_ApiTestProgress := Map()
		Owner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_OnApiTestDone(true, "OK", "prod", "Prod", Origin,
			Owner, (Ok, Tip) => Notices.Push(Tip), "", Origin + Elapsed))
		AssertEqual(1, Notices.Length)
		AssertEqual(Format(t("menu.llm.api_test_ok_body"), "Prod", Elapsed, "OK"),
			Notices[1]["body"], "the actual completion must retain full native elapsed latency")
		AssertFalse(LLM_AuxIsCurrent(Owner), "successful publication must retire its exact owner")
	} finally {
		_LLM_Menu_ApiTestProgress := SavedProgress
		_LLM_AuxGeneration := SavedOwners[1]
		_LLM_AuxOwnerCounter := SavedOwners[2]
		_LLM_AuxOwners := SavedOwners[3]
		_LLM_AuxCleanupDebt := SavedOwners[4]
		_LLM_AuxCleanupDebtCounter := SavedOwners[5]
		_LAT_RestoreMenu(SavedMenu)
	}
}
for Origin in [0, 100, 0xFFFFFFF0]
	Test("llm api probe clock: completion origin=" . Origin,
		_LAT_ProbeClockCompletion.Bind(Origin))

for Origin in [100, 0x100000064]
	for Elapsed in [0x100000000, 0x10001D4BF, 0x10001D4C0, 0x10001D4C1, 0x2000004D2]
		Test("llm api probe clock: long progress origin=" . Origin . " elapsed=" . Elapsed,
			_LAT_ProbeClockProgress.Bind(Origin, Elapsed))
for Elapsed in [0x1000004D2, 0x2000004D2]
	Test("llm api probe clock: long completion elapsed=" . Elapsed,
		_LAT_ProbeClockCompletion.Bind(100, Elapsed))


_LAT_AddFrameCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\api_add_controls.json", "UTF-8"))
}

_LAT_AddFrameCaption() {
	global _LLM_Menu
	Corpus := _LAT_AddFrameCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Declaration := _MR_GetMenuDef(Corpus["command_section"])[1]
	Original := Declaration["i18n"]
	try {
		Declaration["i18n"] := Corpus["mutated_key"]
		Found := 0
		for Row in _LLM_Menu_ApiEntriesRows() {
			if Row.Get("label", "") == t(Corpus["mutated_key"]) {
				Found += 1
				AssertTrue(HasMethod(Row.Get("action", 0), "Call"), "the genuine Add dialog owner remains callable")
			}
		}
		AssertEqual(1, Found, "one native Add command reads the shared caption")
	} finally {
		Declaration["i18n"] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("API Add frame uses the shared command caption (api-add-controls)", _LAT_AddFrameCaption)

_LAT_AddFrameSeparator() {
	global _LLM_Menu
	Corpus := _LAT_AddFrameCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Definition := _MR_GetMenuDef(Corpus["separator_section"])
	Original := Definition[1]
	try {
		Definition[1] := Map("type", "label", "id", "api_add_marker", "i18n", Corpus["mutated_key"])
		Rows := _LLM_Menu_ApiEntriesRows()
		Position := 0
		for Index, Row in Rows {
			if Row.Get("label", "") == t(Corpus["label_key"])
				Position := Index
		}
		AssertTrue(Position > 0, "the native Add command remains in its original position")
		Marker := Rows[Position + 1]
		AssertEqual(t(Corpus["mutated_key"]), Marker.Get("label", ""), "the existing post-Add separator belongs to its declaration")
		AssertTrue(Marker.Get("disabled", false), "the marker is inert")
		AssertFalse(Marker.Has("action"), "status data cannot acquire the Add callback")
		_LLM_Menu["api_entries"] := []
		for Row in _LLM_Menu_ApiEntriesRows()
			AssertFalse(Row.Get("label", "") == t(Corpus["mutated_key"]), "empty entries retain the conditional absence")
	} finally {
		Definition[1] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("API Add frame retains its conditional shared separator (api-add-controls)", _LAT_AddFrameSeparator)


/** Independent inert status data, separate from selectable NoModel commands. */
_LAT_EmptyStatusCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\llm_empty_status.json", "UTF-8"))
}

_LAT_EmptyStatusCaption() {
	global _LLM_Menu
	Corpus := _LAT_EmptyStatusCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Definition := _MR_GetMenuDef(Corpus["api"]["section"])
	Original := Definition[1]
	try {
		_LLM_Menu["api_entries"] := []
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual(t(Corpus["api"]["key"]), Rows[1]["label"])
		AssertTrue(Rows[1].Get("disabled", false), "the original actionless status remains disabled")
		AssertFalse(Rows[1].Has("action"), "no selectable NoModel action is attached")
		AssertFalse(Rows[1].Has("items"), "the empty status never becomes a provider subtree")
		AssertTrue(HasMethod(Rows[2].Get("action", 0), "Call"), "the real Add owner retains the next row")
		Definition[1] := Map("type", "label", "id", Corpus["api"]["rows"][1]["id"],
			"i18n", Corpus["marker_key"], "platforms", ["ahk", "linux"], "unavailable", "hide")
		for Entries in [[], Map()] {
			_LLM_Menu["api_entries"] := Entries
			Rows := _LLM_Menu_ApiEntriesRows()
			AssertEqual(t(Corpus["marker_key"]), Rows[1]["label"], "both actual old fallback predicates read the shared label")
			AssertTrue(Rows[1].Get("disabled", false))
			AssertFalse(Rows[1].Has("action"))
		}
	} finally {
		Definition[1] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("API empty status uses the shared inert caption (llm-empty-status)", _LAT_EmptyStatusCaption)

_LAT_EmptyStatusRefusal() {
	global _LLM_Menu
	Corpus := _LAT_EmptyStatusCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Definition := _MR_GetMenuDef(Corpus["api"]["section"])
	Original := Definition[1]
	try {
		_LLM_Menu["api_entries"] := []
		Definition.Pop()
		AssertEqual(0, _LLM_Menu_ApiEntriesRows().Length, "a missing declaration refuses the empty provider before callbacks")
		Definition.Push(Map("type", "command", "id", "unowned_api_empty", "i18n", Corpus["api"]["key"],
			"platforms", ["ahk", "linux"], "unavailable", "hide"))
		AssertEqual(0, _LLM_Menu_ApiEntriesRows().Length, "unbound status cannot acquire an action")
		AssertEqual(0, _LLM_Menu["api_entries"].Length)
		Definition[1] := Original
		AssertEqual(t(Corpus["api"]["key"]), _LLM_Menu_ApiEntriesRows()[1]["label"], "the exact original declaration repairs admission")
	} finally {
		if Definition.Length == 0
			Definition.Push(Original)
		else
			Definition[1] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("API empty status refuses missing and unbound owners (llm-empty-status)", _LAT_EmptyStatusRefusal)


/** The existing native API list consumes the complete fixed Edit declaration. */
_LAT_CompleteEditCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\llm_complete_presentation_owners.json", "UTF-8"))["api_management"]
}

_LAT_CompleteEditFrame() {
	global _LLM_Menu
	Corpus := _LAT_CompleteEditCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Definition := _MR_GetMenuDef(Corpus["section"]), Original := Definition[1]
	try {
		Rows := _LLM_Menu_ApiEntriesRows()
		Position := Rows.Length - 2
		for Offset, Key in Corpus["keys"] {
			Row := Rows[Position + Offset - 1]
			AssertEqual(t(Key), Row["label"], "the independent management order remains Test, Edit, Remove")
			AssertTrue(HasMethod(Row.Get("action", 0), "Call"), "each actual retained native callback stays callable")
		}
		_LLM_Menu["api_entry_id"] := "missing"
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertFalse(Rows[Rows.Length - 1].Get("disabled", false), "Edit retains its old lazy callback and no new readiness guard")
		Definition[1] := Map("type", "command", "id", "api_edit_entry", "i18n", Corpus["mutated_key"],
			"platforms", Corpus["platforms"], "unavailable", "hide")
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual(t(Corpus["mutated_key"]), Rows[Rows.Length - 1]["label"], "the actual native Edit caption comes from its declaration")
		_LLM_Menu["api_entries"] := []
		for Row in _LLM_Menu_ApiEntriesRows()
			AssertFalse(Row.Get("label", "") == t(Corpus["mutated_key"]), "empty entries retain the absence of management rows")
	} finally {
		Definition[1] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("complete API Edit frame retains native management order and lazy posture", _LAT_CompleteEditFrame)

_LAT_CompleteEditRefusal() {
	global _LLM_Menu
	Corpus := _LAT_CompleteEditCorpus()
	SavedMenu := _LAT_FixtureMenu()
	Root := _MM_GetManifestRoot(), Original := Root[Corpus["section"]]
	try {
		Root.Delete(Corpus["section"])
		AssertEqual(0, _LLM_Menu_ApiEntriesRows().Length, "missing Edit declaration refuses the complete list before callbacks")
		Root[Corpus["section"]] := [Map("type", "command", "id", "unowned_api_edit", "i18n", Corpus["keys"][2])]
		AssertEqual(0, _LLM_Menu_ApiEntriesRows().Length, "unbound Edit command cannot acquire a native dialog owner")
		AssertEqual("prod", _LLM_Menu["api_entry_id"])
		AssertEqual(1, _LLM_Menu["api_entries"].Length, "construction and refusal never edit the actual entry source")
		Root[Corpus["section"]] := Original
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual(t(Corpus["keys"][2]), Rows[Rows.Length - 1]["label"], "exact original declaration repairs the same actual owner")
	} finally {
		Root[Corpus["section"]] := Original
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("complete API Edit frame refuses withdrawal and repairs its actual owner", _LAT_CompleteEditRefusal)
