; tests/unit/ai/api/test_test_entry.ahk

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

; @returns {Array} The registry it replaced, for _LAT_RestoreOwners.
_LAT_ResetOwners() {
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	Saved := [_LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners,
		_LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter]
	_LLM_AuxGeneration := 41
	_LLM_AuxOwnerCounter := 0
	_LLM_AuxOwners := Map()
	_LLM_AuxCleanupDebt := Map()
	_LLM_AuxCleanupDebtCounter := 0
	return Saved
}

; A scenario's owners are records of its own private registry: putting the
; suite's back keeps them from reading as requests still in flight.
_LAT_RestoreOwners(Saved) {
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	_LLM_AuxGeneration := Saved[1]
	_LLM_AuxOwnerCounter := Saved[2]
	_LLM_AuxOwners := Saved[3]
	_LLM_AuxCleanupDebt := Saved[4]
	_LLM_AuxCleanupDebtCounter := Saved[5]
}

_LAT_TestOwner(EntryId := "prod") {
	return LLM_AuxBegin("api_test:" . EntryId, Map(
		"backend", "api",
		"endpoint", "https://b.invalid/v1",
		"identity", EntryId))
}



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
	SavedOwners := _LAT_ResetOwners()
	try {
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
	} finally {
		_LAT_RestoreOwners(SavedOwners)
		_LAT_RestoreMenu(SavedMenu)
	}
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
	SavedOwners := _LAT_ResetOwners()
	try {
		Owner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_OnApiTestDone(false, "", "prod", "Prod",
			A_TickCount - 30031, Owner, NotifyFn),
			"a failed completion must publish like a success")
		AssertEqual(1, Notices.Length, "exactly one notification may survive")
		AssertFalse(Notices[1]["ok"])
		AssertEqual(t("menu.llm.api_unreachable_title"), Notices[1]["tip"]["title"])
	} finally {
		_LAT_RestoreOwners(SavedOwners)
		_LAT_RestoreMenu(SavedMenu)
	}
}
Test("llm api test: failed probe notifies through the seam (api-test-entry-failure)",
	_LAT_FailureCompletionNotifies)

; The failure verdict carries the server's own words (status + message):
; a 402 quota refusal must read as quota, never as a generic unreachable.
_LAT_FailureServerMessageNotifies() {
	SavedMenu := _LAT_FixtureMenu()
	Notices := []
	NotifyFn := (Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))
	SavedOwners := _LAT_ResetOwners()
	try {
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
	} finally {
		_LAT_RestoreOwners(SavedOwners)
		_LAT_RestoreMenu(SavedMenu)
	}
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
		Assert(InStr(Code, '_LLM_Engine_Port("http").Cancel(LLM_REMOTE_KIND_API_TEST)') > 0,
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
	SavedOwners := _LAT_ResetOwners()
	try {
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
	} finally _LAT_RestoreOwners(SavedOwners)
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



/** Independent inert status data, separate from selectable NoModel commands. */



/** The existing native API list consumes the complete fixed Edit declaration. */



class _LAT_ProgressReentrantDestroy {
	Fired := false
	__New(Window) {
		this.Window := Window
	}
	Destroy() {
		global _LLM_Menu_ApiTestProgress
		if this.Fired
			return
		this.Fired := true
		this.Window.Destroy()
		this.NextOwner := _LAT_TestOwner()
		_LLM_Menu_ApiTestProgressShow("prod", "Private reentrant progress", this.NextOwner)
		this.NextState := _LLM_Menu_ApiTestProgress
	}
}

_LAT_ProgressNativeEvent(Receipt, *) {
	Receipt.Delivered := true
}

_LAT_ProgressCloseDuringShow(Receipt, Showing, Param, Message, Hwnd) {
	global _LLM_Menu_ApiTestProgress
	if !Showing || Receipt.Delivered || !_LLM_Menu_ApiTestProgress.Has("gui")
		return
	Window := _LLM_Menu_ApiTestProgress["gui"]
	if Window.Hwnd != Hwnd
		return
	Receipt.Delivered := true
	Receipt.Hwnd := Hwnd
	DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int")
	Started := A_TickCount
	while _LLM_Menu_ApiTestProgress.Has("entry") && A_TickCount - Started < 2000
		Sleep(1)
}

_LAT_ProgressNativeCancellation(Event) {
	global _LLM_Menu_ApiTestProgress, _LLM_AuxGeneration, _LLM_AuxOwnerCounter
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	SavedMenu := _LAT_FixtureMenu()
	SavedProgress := _LLM_Menu_ApiTestProgress
	SavedOwners := [_LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners,
		_LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter]
	SavedCritical := Critical("Off")
	Window := 0, DestroyProbe := 0, ShowCallback := 0
	try {
		_LAT_ResetOwners()
		_LLM_Menu_ApiTestProgress := Map()
		Owner := _LAT_TestOwner()
		if Event == "DuringShow" {
			Receipt := {Delivered: false, Hwnd: 0}
			ShowCallback := _LAT_ProgressCloseDuringShow.Bind(Receipt)
			OnMessage(0x18, ShowCallback)
			Opened := _LLM_Menu_ApiTestProgressShow("prod", "Private opening cancellation", Owner)
			AssertTrue(Receipt.Delivered, "real WM_SHOWWINDOW must expose the published native owner")
			AssertFalse(Opened, "closing while Show pumps messages cannot authorize request dispatch")
			AssertFalse(LLM_AuxIsCurrent(Owner), "early cancellation retires the owner before dispatch")
			AssertFalse(_LLM_Menu_ApiTestProgress.Has("entry"))
			AssertFalse(WMHandleExists(Receipt.Hwnd))
			return
		}
		AssertTrue(_LLM_Menu_ApiTestProgressShow("prod", "Private progress cancellation", Owner))
		State := _LLM_Menu_ApiTestProgress
		AssertTrue(State.Has("gui"), "the real progress factory must create its native window")
		Window := State["gui"], Hwnd := Window.Hwnd
		AssertTrue(LLM_AuxIsCurrent(Owner), "the native progress must begin with a real live auxiliary owner")
		Receipt := {Delivered: false}
		Window.OnEvent(Event, _LAT_ProgressNativeEvent.Bind(Receipt), -1)
		AssertTrue(DllCall("PostMessageW", "Ptr", Hwnd, "UInt", Event == "Close" ? 0x10 : 0x100,
			"Ptr", Event == "Close" ? 0 : 0x1B, "Ptr", 0, "Int"),
			"the private progress window must receive its cancellation message")
		Started := A_TickCount
		while (!Receipt.Delivered || LLM_AuxIsCurrent(Owner)) && A_TickCount - Started < 2000
			Sleep(1)
		AssertTrue(Receipt.Delivered, "the native cancellation event must really run")
		AssertFalse(LLM_AuxIsCurrent(Owner), "closing progress must retire the probe instead of leaving hidden work")
		AssertFalse(WMHandleExists(Hwnd), "native cancellation must destroy the progress window")
		AssertFalse(_LLM_Menu_ApiTestProgress.Has("entry"), "native cancellation must clear progress state")
		Notices := []
		AssertFalse(_LLM_Menu_OnApiTestDone(true, "late answer", "prod", "Private progress cancellation",
			A_TickCount, Owner, (Ok, Tip) => Notices.Push(Tip)))
		AssertEqual(0, Notices.Length, "a closed probe cannot publish a later verdict")
		ReplacementOwner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_ApiTestProgressShow("prod", "Private replacement progress", ReplacementOwner))
		Replacement := _LLM_Menu_ApiTestProgress
		AssertFalse(_LLM_Menu_ApiTestProgressCancel(State), "a delayed old cancellation cannot claim a replacement")
		AssertTrue(_LLM_Menu_ApiTestProgress == Replacement)
		AssertTrue(LLM_AuxIsCurrent(ReplacementOwner), "the replacement keeps its exact owner")
		DestroyProbe := _LAT_ProgressReentrantDestroy(Replacement["gui"])
		Replacement["gui"] := DestroyProbe
		AssertTrue(_LLM_Menu_ApiTestProgressCancel(Replacement))
		AssertFalse(LLM_AuxIsCurrent(ReplacementOwner))
		AssertTrue(DestroyProbe.Fired, "native retirement must reach the controlled reentrant boundary")
		AssertTrue(_LLM_Menu_ApiTestProgress == DestroyProbe.NextState,
			"retiring an old HWND cannot erase progress opened by that native callout")
		AssertTrue(LLM_AuxIsCurrent(DestroyProbe.NextOwner), "the reentrant progress retains its own live owner")
		AssertTrue(DestroyProbe.NextState.Has("gui"), "the replacement owns an actual native progress window")
		AssertTrue(WMHandleExists(DestroyProbe.NextState["gui"].Hwnd))
		AssertTrue(_LLM_Menu_ApiTestProgressCancel(DestroyProbe.NextState))
	} finally {
		if HasMethod(ShowCallback, "Call")
			OnMessage(0x18, ShowCallback, 0)
		_LLM_Menu_ApiTestProgressHide()
		SetTimer(_LLM_Menu_ApiTestProgressTick, 0)
		if IsObject(DestroyProbe) && DestroyProbe.HasOwnProp("NextState") {
			if DestroyProbe.NextState.Has("gui")
				try DestroyProbe.NextState["gui"].Destroy()
			try LLM_AuxFinish(DestroyProbe.NextOwner)
		}
		if IsObject(Window)
			try Window.Destroy()
		_LLM_Menu_ApiTestProgress := SavedProgress
		_LLM_AuxGeneration := SavedOwners[1]
		_LLM_AuxOwnerCounter := SavedOwners[2]
		_LLM_AuxOwners := SavedOwners[3]
		_LLM_AuxCleanupDebt := SavedOwners[4]
		_LLM_AuxCleanupDebtCounter := SavedOwners[5]
		_LAT_RestoreMenu(SavedMenu)
		Critical(SavedCritical)
	}
}
for _LAT_NativeCancelEvent in ["Close", "Escape", "DuringShow"]
	Test("llm api progress: " . _LAT_NativeCancelEvent . " cancels the live probe (api-progress-native-cancel)",
		_LAT_ProgressNativeCancellation.Bind(_LAT_NativeCancelEvent))


_LAT_RefuseProbeTransport(Calls, *) {
	Calls.Push(true)
	throw Error("Controlled probe transport refusal before network work.")
}

_LAT_ProgressShowSupersession() {
	global _LLM_Menu_ApiTestProgress, _LLM_AuxGeneration, _LLM_AuxOwnerCounter
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LLM_Menu_ApiFailureEpoch
	global LLM_REMOTE_TEST_REQUEST
	SavedMenu := _LAT_FixtureMenu()
	SavedProgress := _LLM_Menu_ApiTestProgress
	SavedOwners := [_LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners,
		_LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter]
	SavedRemote := [_LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LLM_Menu_ApiFailureEpoch]
	HadConstructor := CurlAsyncRequest.HasOwnProp("Call")
	SavedConstructor := HadConstructor ? CurlAsyncRequest.GetOwnPropDesc("Call") : 0
	SavedCritical := Critical("Off")
	DestroyProbe := 0, Window := 0
	Calls := [], Notices := []
	try {
		_LAT_ResetOwners()
		_LLM_Menu_ApiTestProgress := Map()
		_LLM_Remote_Async := Map()
		_LLM_Remote_AsyncCounter := 0
		CurlAsyncRequest.DefineProp("Call", {Call: _LAT_RefuseProbeTransport.Bind(Calls)})
		AssertTrue(LLM_REMOTE_TEST_REQUEST is Map && LLM_REMOTE_TEST_REQUEST.Count > 0,
			"the public probe must have the genuine shared request specification")
		Owner := _LAT_TestOwner()
		AssertTrue(_LLM_Menu_ApiTestProgressShow("prod", "Private predecessor progress", Owner))
		OldState := _LLM_Menu_ApiTestProgress
		Window := OldState["gui"]
		DestroyProbe := _LAT_ProgressReentrantDestroy(Window)
		OldState["gui"] := DestroyProbe
		AssertFalse(_LLM_Menu_TestActiveApiEntry((Ok, Tip) => Notices.Push(Tip)),
			"a reentrant replacement withdraws the outer probe request")
		AssertTrue(DestroyProbe.Fired, "the real public probe must retire its predecessor HWND")
		AssertEqual(0, Calls.Length, "a withdrawn probe cannot construct an outgoing HTTP transport")
		AssertEqual(0, _LLM_Remote_AsyncCounter, "withdrawal must precede even remote request reservation")
		AssertTrue(_LLM_Menu_ApiTestProgress == DestroyProbe.NextState,
			"the outer opening cannot overwrite progress opened by predecessor destruction")
		AssertTrue(LLM_AuxIsCurrent(DestroyProbe.NextOwner))
		AssertTrue(WMHandleExists(DestroyProbe.NextState["gui"].Hwnd),
			"the latest native progress remains independently owned and visible")
		AssertEqual(0, Notices.Length, "a withdrawn probe cannot report a transport verdict")
	} finally {
		RequestIds := []
		for RequestId in _LLM_Remote_Async
			RequestIds.Push(RequestId)
		for RequestId in RequestIds
			LLM_RemoteCancelAsync(RequestId)
		_LLM_Menu_ApiTestProgressHide()
		SetTimer(_LLM_Menu_ApiTestProgressTick, 0)
		if IsObject(DestroyProbe) && DestroyProbe.HasOwnProp("NextState") {
			if DestroyProbe.NextState.Has("gui")
				try DestroyProbe.NextState["gui"].Destroy()
			try LLM_AuxFinish(DestroyProbe.NextOwner)
		}
		if IsObject(Window)
			try Window.Destroy()
		if HadConstructor
			CurlAsyncRequest.DefineProp("Call", SavedConstructor)
		else
			CurlAsyncRequest.DeleteProp("Call")
		_LLM_Menu_ApiTestProgress := SavedProgress
		_LLM_AuxGeneration := SavedOwners[1]
		_LLM_AuxOwnerCounter := SavedOwners[2]
		_LLM_AuxOwners := SavedOwners[3]
		_LLM_AuxCleanupDebt := SavedOwners[4]
		_LLM_AuxCleanupDebtCounter := SavedOwners[5]
		_LLM_Remote_Async := SavedRemote[1]
		_LLM_Remote_AsyncCounter := SavedRemote[2]
		_LLM_Menu_ApiFailureEpoch := SavedRemote[3]
		_LAT_RestoreMenu(SavedMenu)
		Critical(SavedCritical)
	}
}
Test("llm api progress: public probe cannot overwrite reentrant teardown ownership (api-progress-opening-supersession)",
	_LAT_ProgressShowSupersession)


; Native thinking-retry requester ownership: genuine Menu and managed HTTP.
; Native Windows/GUI qualification required. The subject functions are not replaced.
; This uses existing _LAT, _LTO, _TLOG and managed-LLM-timings test helpers.
global _LATRT_Debt := Map()

_LATRT_Done(State, Code, Output, ErrorText) {
    State.PeerCalls += 1
    State.PeerCode := Code
    State.PeerOutput := Output
    State.PeerErrors := ErrorText
}

_LATRT_Marker(State) {
    State.AfterCutpoint := true
}

_LATRT_Sink(State, Line) {
    global _LLM_Menu_ApiTestProgress, _LLM_Remote_Async
    if InStr(Line, "[LLM.remote]", true) || InStr(Line, "[LLM]", true) {
        State.Logs.Push(SubStr(Line, 1, 400))
        if State.Logs.Length > 12
            State.Logs.RemoveAt(1)
    }
    if State.Cutpoint || !InStr(Line,
            "Provider 'deepseek' refused the thinking field 'thinking'", true)
        return
    State.Cutpoint := true
    try {
        if _LLM_Menu_ApiTestProgress != State.Progress
            throw Error("The exact probe progress was replaced before the cutpoint.")
        State.OriginalGone := !_LLM_Remote_Async.Has(State.OriginalId)
        State.OwnerCurrentAtCutpoint := LLM_AuxIsCurrent(State.Owner)
        if !State.OriginalGone || !State.OwnerCurrentAtCutpoint
            throw Error("The actual retired-original/live-requester cutpoint was not reached.")
        if State.Cancel {
            State.Cancelled := _LLM_Menu_ApiTestProgressCancel(State.Progress)
            State.OwnerRetiredAtCutpoint := !LLM_AuxIsCurrent(State.Owner)
            State.WindowRetiredAtCutpoint := !WMHandleExists(State.ProgressHwnd)
        }
        ; The principal test thread cannot resume _LATRT_Wait's predicate before
        ; this synchronous poll callback, or the timer interrupting it, returns.
        ; The marker itself does not claim a separate quiet-time guarantee.
        SetTimer(State.Marker, -1)
    } catch Any as Failure {
        ; Logger intentionally catches sink exceptions; preserve ours explicitly.
        State.Failure := Failure
        State.AfterCutpoint := true
    }
}

_LATRT_Wait(Predicate, Milliseconds) {
    Started := A_TickCount
    while !Predicate.Call() && TickElapsed(Started) < Milliseconds {
        _SR_TreePoll()
        Sleep(10)
    }
    return Predicate.Call()
}

_LATRT_RegistryKey(Nonce) {
    ; Exclusive native acquisition, never reuse/delete an existing key.
    Subkey := "Software\Ergopti\Tests\ThinkingRetry\" . Nonce
    Handle := 0, Disposition := 0
    Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
        "Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0x20006,
        "Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
    if Handle
        DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
    if Status != 0 || Disposition != 1
        throw Error("Exclusive private registry acquisition refused.")
    return "HKCU\" . Subkey
}

_LATRT_HoldRetry(State) {
    global _LLM_Remote_RetryOf, _LLM_Remote_Async
    RetryId := _LLM_Remote_RetryOf.Get(State.OriginalId, 0)
    if RetryId {
        State.RetryId := RetryId
        if _LLM_Remote_Async.Has(RetryId)
            State.RetryEntry := _LLM_Remote_Async[RetryId]
    }
}

_LATRT_RequestsGone(State) {
    global _LLM_Remote_Async
    _LATRT_HoldRetry(State)
    return !_LLM_Remote_Async.Has(State.OriginalId)
        && (!State.RetryId || !_LLM_Remote_Async.Has(State.RetryId))
}

_LATRT_CancelRequests(State) {
    global _LLM_Remote_Async
    _LATRT_HoldRetry(State)
    if State.OriginalId && _LLM_Remote_Async.Has(State.OriginalId)
            && IsObject(State.OriginalEntry)
            && _LLM_Remote_Async[State.OriginalId] == State.OriginalEntry
        LLM_RemoteCancelAsync(State.OriginalId)
    if State.RetryId && _LLM_Remote_Async.Has(State.RetryId)
            && IsObject(State.RetryEntry)
            && _LLM_Remote_Async[State.RetryId] == State.RetryEntry
        LLM_RemoteCancelAsync(State.RetryId)
}

_LATRT_Control(State, Name) {
    Path := State.Directory . "\" . Name
    if FSStrictExists(Path) {
        if FSReadUtf8Exact(Path) != State.Nonce
            throw Error("Foreign private control refused.")
        return 1
    }
    Pending := Path . ".pending"
    if FSWriteCreateDurable(Pending, State.Nonce) != 1
        throw Error("Private control write refused.")
    FileMove(Pending, Path, false)
    return 1
}

_LATRT_StopPeer(State) {
    if !IsObject(State.Peer)
        return true
    _LATRT_Control(State, "stop")
    _LATRT_Wait(() => State.PeerCalls > 0, 5000)
    Started := A_TickCount
    loop {
        Ack := State.Peer.terminate()
        if Ack is Integer && Ack == 1
            return true
        if TickElapsed(Started) >= 5000
            return false
        _SR_TreePoll()
        Sleep(10)
    }
}

_LATRT_Retire(State) {
    global _LLM_Menu_ApiTestProgress
    Complete := true
    try SetTimer(State.Marker, 0)
    if State.Progress is Map {
        try {
            if _LLM_Menu_ApiTestProgress == State.Progress
                _LLM_Menu_ApiTestProgressCancel(State.Progress)
            ; Retain the exact GUI object if a prior Destroy refused.
            if WMHandleExists(State.ProgressHwnd) && State.Progress.Has("gui")
                State.Progress["gui"].Destroy()
            if WMHandleExists(State.ProgressHwnd) {
                State.CleanupIssues.Push("gui:live")
                Complete := false
            }
        } catch Any as Failure {
            State.CleanupIssues.Push("gui:" . Type(Failure))
            Complete := false
        }
    }
    if State.Owner is Map {
        try {
            if LLM_AuxIsCurrent(State.Owner)
                LLM_AuxFinish(State.Owner)
            if LLM_AuxIsCurrent(State.Owner) {
                State.CleanupIssues.Push("owner:current")
                Complete := false
            }
        } catch Any as Failure {
            State.CleanupIssues.Push("owner:" . Type(Failure))
            Complete := false
        }
    }
    try {
        _LATRT_CancelRequests(State)
        if !_LATRT_Wait(() => _LATRT_RequestsGone(State), 10000) {
            State.CleanupIssues.Push("requests:pending")
            Complete := false
        }
    } catch Any as Failure {
        State.CleanupIssues.Push("requests:" . Type(Failure))
        Complete := false
    }
    try {
        if !_LATRT_StopPeer(State) {
            State.CleanupIssues.Push("peer:ack-pending")
            Complete := false
        }
    } catch Any as Failure {
        State.CleanupIssues.Push("peer:" . Type(Failure))
        Complete := false
    }
    return Complete
}

_LATRT_DeletePrivate(State) {
    ; Called only after exact native peer ACK and remote-request retirement.
    if State.Registry != "" {
        RegDeleteKey(State.Registry)
        State.Registry := ""
    }
    if State.Directory != "" && DirExist(State.Directory) {
        DirDelete(State.Directory, true)
        State.Directory := ""
    }
}

_LATRT_DrainDebt() {
    global _LATRT_Debt
    Keys := []
    for Key in _LATRT_Debt
        Keys.Push(Key)
    for Key in Keys {
        State := _LATRT_Debt[Key]
        if !_LATRT_Retire(State)
            return false
        try _LATRT_DeletePrivate(State)
        catch
            return false
        _LATRT_Debt.Delete(Key)
    }
    return true
}

_LATRT_Diagnostic(State, Notices, Phase) {
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LOGGER_WARN_ENABLED
    Data := Map("phase", Phase, "case", State.Mode, "remote_counter", _LLM_Remote_AsyncCounter,
        "counter_delta", _LLM_Remote_AsyncCounter - State.CounterBefore,
        "remote_census", _LLM_Remote_Async.Count, "peer_calls", State.PeerCalls,
        "peer_code", State.PeerCode, "peer_output", SubStr(State.PeerOutput, 1, 600),
        "peer_errors", SubStr(State.PeerErrors, 1, 600), "notices", Notices,
        "logger_warn_enabled", _LOGGER_WARN_ENABLED, "logs", State.Logs,
        "cleanup_issues", State.CleanupIssues, "original_id", State.OriginalId,
        "original_present", _LLM_Remote_Async.Has(State.OriginalId),
        "retry_id", State.RetryId, "cutpoint", State.Cutpoint)
    if State.Owner is Map
        Data["owner_current"] := LLM_AuxIsCurrent(State.Owner)
    Data["window_alive"] := WMHandleExists(State.ProgressHwnd)
    if State.OriginalEntry is Map && State.OriginalEntry.Has("http") {
        Http := State.OriginalEntry["http"]
        try Data["http"] := Map("status", Http.Status, "completed", Http.Completed,
            "aborted", Http.Aborted, "managed_payload_published", Http.ManagedPayloadPublished,
            "encoding_valid", Http.ResponseEncodingValid)
    }
    ReceiptPath := State.Directory . "\receipt.json"
    if FSStrictExists(ReceiptPath)
        Data["peer_receipt"] := JsonParse(FSReadUtf8ExactBounded(ReceiptPath, 16384))
    _TestPrint("# THINKING_RETRY_DEBUG " . KL_JsonEncode(Data))
}

_LATRT_Case(Cancel, AliasMode := "") {
    global _DriverDir, _LLM_Menu, _LLM_Menu_ApiTestProgress
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LLM_Remote_RetryOf
    global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_ThinkingRefused
    global STORAGE_REG_BASE, LLM_API_TEST_TIMEOUT_MS
    global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
    global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_FLUSH_ACTIVE
    global _HealthCheckWarnCount, _HealthCheckErrCount, _HealthCheckLastError, _LATRT_Debt
    if !_LATRT_DrainDebt()
        throw Error("An earlier exact thinking-retry fixture still owns retirement debt.")
    AssertFalse(A_IsSuspended, "native managed admission requires an active driver")
    AssertEqual(0, _LLM_Remote_Async.Count, "no foreign remote request may be borrowed")
    AssertEqual(0, _LLM_AuxOwners.Count, "the private probe requires an idle auxiliary census")
    AssertEqual(0, _LLM_AuxCleanupDebt.Count, "foreign cleanup debt cannot be serviced by this fixture")
    AssertFalse(_LOGGER_FLUSH_ACTIVE, "foreign logger flush cannot be borrowed")
    AssertFalse(_LLM_Menu_ApiTestProgress.Has("entry"), "no foreign progress can be replaced")

    Nonce := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount . "_" . Random(100000, 999999)
    Mode := AliasMode != "" ? AliasMode : (Cancel ? "cancel" : "positive")
    State := {Cancel: Cancel, Nonce: Nonce, Mode: Mode, Directory: "", Registry: "",
        AliasBefore: _LLM_Remote_RetryOf.Count, Peer: 0, PeerPid: 0, PeerCalls: 0, PeerCode: -1, PeerOutput: "", PeerErrors: "",
        Progress: 0, ProgressHwnd: 0, Logs: [], CleanupIssues: [], Owner: 0, OriginalId: 0, OriginalEntry: 0, RetryId: 0, RetryEntry: 0,
        Cutpoint: false, AfterCutpoint: false, OriginalGone: false, Cancelled: false,
        OwnerCurrentAtCutpoint: false, OwnerRetiredAtCutpoint: false,
        WindowRetiredAtCutpoint: false, Failure: 0, Marker: 0}
    State.Marker := _LATRT_Marker.Bind(State)
    Saved := {Menu: _LLM_Menu, Progress: _LLM_Menu_ApiTestProgress, Storage: STORAGE_REG_BASE,
        Thinking: _LLM_ThinkingRefused, Budget: LLM_API_TEST_TIMEOUT_MS,
        Sink: _LOGGER_TEST_SINK, Repeat: _LOGGER_REPEAT_ENABLED, Clock: _LOGGER_CLOCK_FN,
        Stamp: _LOGGER_STAMP_FN, Warn: _HealthCheckWarnCount, Errors: _HealthCheckErrCount,
        LastError: _HealthCheckLastError, Logger: _TLOG_CaptureLoggerState()}
    PreviousCritical := Critical("Off")
    Primary := 0, Retired := false, Notices := [], CounterBefore := _LLM_Remote_AsyncCounter
    try {
        State.CounterBefore := CounterBefore
        State.Directory := A_Temp . "\ergopti_llm_retry_proposal_" . Nonce . "_" . Mode
        FSCreateDirectoryExclusiveStrict(State.Directory)
        State.Registry := _LATRT_RegistryKey(Nonce)
        STORAGE_REG_BASE := State.Registry
        _LLM_ThinkingRefused := Map()
        LLM_API_TEST_TIMEOUT_MS := 20000
        _ResetLogger()
        _LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
        LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
        LoggerSetTestSink(_LATRT_Sink.Bind(State))

        PeerScript := _DriverDir . "\tests\fixtures\llm_thinking_retry_peer.ps1"
        Services := _DriverDir . "\tests\fixtures\winhttp_test_services.ps1"
        AssertTrue(FSStrictExists(PeerScript) && FSStrictExists(Services), "reviewed native peer files must exist")
        State.Peer := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", PeerScript,
                "-Directory", State.Directory, "-ServicesPath", Services, "-Nonce", Nonce, "-Case", Mode],
            _LATRT_Done.Bind(State))
        AssertEqual(1, State.Peer.start(), "the exact peer Job must start")
        State.PeerPid := State.Peer.processId()
        AssertTrue(State.PeerPid is Integer && State.PeerPid > 0)
        AssertTrue(_LATRT_Wait(() => FSStrictExists(State.Directory . "\ready.json")
            || State.PeerCalls > 0, 30000), "the private listener must publish")
        AssertTrue(FSStrictExists(State.Directory . "\ready.json"), State.PeerOutput . State.PeerErrors)
        Ready := JsonParse(FSReadUtf8Exact(State.Directory . "\ready.json"))
        AssertEqual(Nonce, Ready["nonce"])
        AssertEqual(Mode, Ready["case"])
        AssertEqual(State.PeerPid, Ready["pid"])
        AssertTrue(Ready["port"] is Integer && Ready["port"] > 0 && Ready["port"] <= 65535)

        EntryId := "thinking_retry_" . Nonce
        Entry := Map("Id", EntryId, "Name", "Owned probe", "Provider", "deepseek",
            "BaseUrl", "http://127.0.0.1:" . Ready["port"] . "/v1",
            "Token", "owned-fixture-secret", "Model", "deepseek-chat")
        _LLM_Menu := Map("enabled", true, "backend", "api", "api_entry_id", EntryId, "api_entries", [Entry])
        _LLM_Menu_ApiTestProgress := Map()
        AssertTrue(_LLM_Menu_TestActiveApiEntry((Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip))),
            "the genuine Menu API Test must admit the original request")
        State.Progress := _LLM_Menu_ApiTestProgress
        AssertTrue(State.Progress.Has("gui"), "this native fixture requires its actual progress window")
        State.ProgressHwnd := State.Progress["gui"].Hwnd
        AssertTrue(WMHandleExists(State.ProgressHwnd), "snapshot the owned HWND before any retirement")
        AssertTrue(State.Progress.Has("entry") && State.Progress["entry"] == EntryId)
        State.Owner := State.Progress["owner"]
        State.OriginalId := State.Progress["req_id"]
        AssertEqual(CounterBefore + 1, State.OriginalId, "the actual handler must publish its initial id")
        AssertTrue(_LLM_Remote_Async.Has(State.OriginalId), "the original must be live before peer release")
        State.OriginalEntry := _LLM_Remote_Async[State.OriginalId]
        AssertTrue(LLM_AuxIsCurrent(State.Owner))
        AssertEqual(1, _LATRT_Control(State, "release"))
        AssertTrue(_LATRT_Wait(() => State.AfterCutpoint || IsObject(State.Failure), 30000),
            "the genuine HTTP 400 must reach the actual thinking-refusal logger")
        if IsObject(State.Failure)
            throw State.Failure
        AssertTrue(State.Cutpoint && State.OriginalGone && State.OwnerCurrentAtCutpoint)
        _LATRT_HoldRetry(State)
        if AliasMode != "" {
            AssertTrue(_LATRT_Wait(() => _LATRA_RetryHeld(State), 30000),
                "the alias must name an actual managed child while its owned peer withholds response two")
            Waiting := JsonParse(FSReadUtf8Exact(State.Directory . "\retry_waiting.json"))
            AssertEqual(Nonce, Waiting["nonce"])
            AssertEqual(Mode, Waiting["case"])
            AssertEqual(State.PeerPid, Waiting["pid"])
            AssertTrue(State.RetryId && _LLM_Remote_RetryOf.Get(State.OriginalId, 0) == State.RetryId)
            AssertTrue(_LLM_Remote_Async.Has(State.RetryId) && _LLM_Remote_Async[State.RetryId] == State.RetryEntry)
            AssertTrue(State.RetryEntry["http"] is CurlAsyncRequest && !State.RetryEntry["http"].Completed)
            if AliasMode == "alias-cancel" {
                State.Cancelled := _LLM_Menu_ApiTestProgressCancel(State.Progress)
                AssertTrue(State.Cancelled, "the actual public Cancel must reach the active original-to-retry link")
                AssertTrue(State.RetryEntry["cancelled"], "Cancel(original) must mark that exact active child")
            } else
                AssertEqual(1, _LATRT_Control(State, "finish-retry"))
        }
        AssertTrue(_LATRT_Wait(() => _LATRT_RequestsGone(State), 30000),
            "every published original/retry must deliver genuine managed completion")

        ; Before checking the repaired outcome, obtain independent HTTP evidence.
        AssertEqual(1, _LATRT_Control(State, "stop"))
        AssertTrue(_LATRT_Wait(() => State.PeerCalls > 0, 10000), "the peer must exit and publish its exact receipt")
        AssertEqual(1, State.PeerCalls)
        AssertEqual(0, State.PeerCode, State.PeerOutput . State.PeerErrors)
        AssertEqual("", State.PeerErrors)
        Receipt := JsonParse(FSReadUtf8Exact(State.Directory . "\receipt.json"))
        AssertEqual(Nonce, Receipt["nonce"])
        AssertEqual(State.PeerPid, Receipt["pid"])
        AssertTrue(Receipt["ok"] && Receipt["released"] && Receipt["stop_received"] && Receipt["listener_retired"])
        Delta := _LLM_Remote_AsyncCounter - CounterBefore
        _TestPrint("# THINKING_RETRY " . KL_JsonEncode(Map("case", Mode, "counter_delta", Delta,
            "http_requests", Receipt["http_requests"], "original_gone", State.OriginalGone,
            "cancelled", State.Cancelled, "owner_retired", !LLM_AuxIsCurrent(State.Owner),
            "peer_pid", State.PeerPid, "retry_id", State.RetryId,
            "alias_before", State.AliasBefore, "alias_after", _LLM_Remote_RetryOf.Count,
            "owned_alias_present", _LLM_Remote_RetryOf.Has(State.OriginalId))))

        if Cancel {
            AssertTrue(State.Cancelled && State.OwnerRetiredAtCutpoint && State.WindowRetiredAtCutpoint)
            AssertEqual(0, Notices.Length, "a cancelled owner must never publish a verdict")
            AssertEqual(1, Delta, "cancel at the exact retired-original gap must prevent retry reservation")
            AssertEqual(1, Receipt["http_requests"], "cancel must prevent the real second POST")
            AssertFalse(_LLM_Remote_RetryOf.Has(State.OriginalId), "cancelled work must not gain a retry link")
        } else if AliasMode == "alias-cancel" {
            AssertTrue(State.Cancelled && !LLM_AuxIsCurrent(State.Owner) && !WMHandleExists(State.ProgressHwnd))
            AssertEqual(0, Notices.Length, "an actually cancelled retry must publish no verdict")
            AssertEqual(2, Delta, "the cancellation control must have published a real retry")
            AssertEqual(2, Receipt["http_requests"], "the owned peer must independently receive that active child")
        } else {
            AssertEqual(2, Delta, "positive control must really reserve its thinking retry")
            AssertEqual(2, Receipt["http_requests"], "positive control must send both actual native HTTP POSTs")
            AssertEqual(1, Notices.Length, "positive control must publish exactly once")
            AssertTrue(Notices[1]["ok"], "second response must complete through the genuine Menu callback")
        }
        if AliasMode != "" {
            AssertTrue(_LATRT_Wait(() => _LATRA_ChildSettled(State), 10000),
                "native child completion/abort and its exact artifact custody must settle")
            AssertFalse(_LLM_Remote_RetryOf.Has(State.OriginalId),
                "a physically retired retry must retire its original cancellation alias")
            AssertEqual(State.AliasBefore, _LLM_Remote_RetryOf.Count,
                "the completed private exchange cannot retain a new alias or clear another exchange's alias")
        }
        AssertFalse(LLM_AuxIsCurrent(State.Owner))
        AssertFalse(_LLM_Menu_ApiTestProgress.Has("entry"))
    } catch Any as Failure {
        Primary := Failure
        try _LATRT_Diagnostic(State, Notices, "before-cleanup")
    } finally {
        try Retired := _LATRT_Retire(State)
        catch Any as CleanupFailure {
            if !IsObject(Primary)
                Primary := CleanupFailure
        }
        ; Only these new cases retire their own observed alias after the verdict.
        ; A fail-before receipt remains visible before this public cleanup call.
        if AliasMode != "" && State.OriginalId
            try LLM_RemoteCancelAsync(State.OriginalId)
        if IsObject(Primary) || !Retired
            try _LATRT_Diagnostic(State, Notices, "after-cleanup")
        if !Retired
            _LATRT_Debt[Nonce] := State
        ; Keep real request registry and monotonic counters untouched.
        _LLM_Menu := Saved.Menu
        _LLM_Menu_ApiTestProgress := Saved.Progress
        _LLM_ThinkingRefused := Saved.Thinking
        STORAGE_REG_BASE := Saved.Storage
        LLM_API_TEST_TIMEOUT_MS := Saved.Budget
        _LOGGER_TEST_SINK := Saved.Sink
        _LOGGER_REPEAT_ENABLED := Saved.Repeat
        _LOGGER_CLOCK_FN := Saved.Clock
        _LOGGER_STAMP_FN := Saved.Stamp
        _HealthCheckWarnCount := Saved.Warn
        _HealthCheckErrCount := Saved.Errors
        _HealthCheckLastError := Saved.LastError
        _TLOG_RestoreLoggerState(Saved.Logger)
        Critical(PreviousCritical)
        if Retired {
            try _LATRT_DeletePrivate(State)
            catch Any as CleanupFailure {
                _LATRT_Debt[Nonce] := State
                if !IsObject(Primary)
                    Primary := CleanupFailure
            }
        }
    }
    if !Retired && !IsObject(Primary)
        Primary := Error("Owned native retirement remains unacknowledged; exact handles/files retained.")
    if IsObject(Primary)
        throw Primary
}

_LATRT_Run(Cancel, AliasMode := "") {
    _ManagedRemoteFixtureWithLlmTimings(_LATHTTP_HostScope.Bind(_LTO_WithoutListingFetch.Bind(_LATRT_Case.Bind(Cancel, AliasMode))))
}

_LATRA_RetryHeld(State) {
    global _LLM_Remote_Async
    _LATRT_HoldRetry(State)
    return State.RetryId && _LLM_Remote_Async.Has(State.RetryId)
        && FSStrictExists(State.Directory . "\retry_waiting.json")
}

_LATRA_ChildSettled(State) {
    if !(State.RetryEntry is Map) || !State.RetryEntry.Has("http")
        return false
    Http := State.RetryEntry["http"]
    return Http is CurlAsyncRequest && Http.Completed && !IsObject(Http.Handle)
        && !Http.CleanupPending && !(Http.ManagedCapture is Map)
}

Test("llm API native thinking retry: completed alias retires (api-thinking-retry-alias-owner)",
    _LATRT_Run.Bind(false, "alias-complete"))
Test("llm API native thinking retry: original cancels active child (api-thinking-retry-alias-owner)",
    _LATRT_Run.Bind(false, "alias-cancel"))

Test("llm API native thinking retry: positive control (api-thinking-retry-owner)",
    _LATRT_Run.Bind(false))
Test("llm API native thinking retry: cancel at retired-original gap (api-thinking-retry-owner)",
    _LATRT_Run.Bind(true))


; Native managed-response classification through neutral production callbacks.
; Requires its existing owned peer / exact retirement helpers (_LATRT_*).
; No Menu callback or window presenter is invoked by the neutral subject cases.
global _LATHTTP_EnvironmentDebt := 0

_LATHTTP_NoEffects() {
    global _LLM_Remote_Async, _LATRT_Debt
    return _LLM_Remote_Async.Count == 0 && _LATRT_Debt.Count == 0
        && ManagedNetworkTerminalFailure.Owners.Count == 0
        && !IsObject(ManagedDownloadFailureWindow.Current)
}

_LATHTTP_Restore(Saved) {
    global _ManagedNetworkWindowsContract, _ManagedNetworkWindowsPorts, _ManagedNetworkWindowsInitializing
    _ManagedNetworkWindowsContract := Saved.Contract
    _ManagedNetworkWindowsPorts := Saved.Ports
    _ManagedNetworkWindowsInitializing := Saved.Initializing
}

_LATHTTP_HostScope(Body) {
    global _ManagedNetworkWindowsContract, _ManagedNetworkWindowsPorts, _ManagedNetworkWindowsInitializing
    global _LATHTTP_EnvironmentDebt
    if IsObject(_LATHTTP_EnvironmentDebt) {
        if !_LATRT_DrainDebt() || !_LATHTTP_NoEffects()
            throw Error("Previous managed HTTP scope still owns actual retirement debt.")
        _LATHTTP_Restore(_LATHTTP_EnvironmentDebt)
        _LATHTTP_EnvironmentDebt := 0
    }
    AssertFalse(_ManagedNetworkWindowsInitializing, "do not borrow a live host initialization")
    AssertTrue(_LATHTTP_NoEffects(), "private host scope requires no foreign request, window or broker owner")
    Saved := {Contract: _ManagedNetworkWindowsContract, Ports: _ManagedNetworkWindowsPorts,
        Initializing: _ManagedNetworkWindowsInitializing}
    _ManagedNetworkWindowsContract := 0, _ManagedNetworkWindowsPorts := 0
    _ManagedNetworkWindowsInitializing := false
    try {
        AssertTrue(ManagedNetworkFailureWindows_Init(), "use genuine canonical policy and production native ports")
        return Body.Call()
    } finally {
        if _LATHTTP_NoEffects()
            _LATHTTP_Restore(Saved)
        else {
            ; Keep the genuine environment alive while any captured callback/owner
            ; can still need it. Never close a window whose identity is unknown.
            _LATHTTP_EnvironmentDebt := Saved
            throw Error("Managed HTTP scope cannot restore host beneath live ownership; state retained.")
        }
    }
}

_LATHTTP_Case(Status) {
    global _DriverDir, _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LATRT_Debt
    AssertFalse(A_IsSuspended)
    Nonce := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount . "_" . Random(100000, 999999)
    Mode := Status == 400 ? "http400" : "http200"
    State := {Cancel: false, Nonce: Nonce, Mode: Mode, Directory: "", Registry: "",
        Peer: 0, PeerPid: 0, PeerCalls: 0, PeerCode: -1, PeerOutput: "", PeerErrors: "",
        Progress: 0, ProgressHwnd: 0, Logs: [], CleanupIssues: [], Owner: 0,
        OriginalId: 0, OriginalEntry: 0, RetryId: 0, RetryEntry: 0, Marker: 0}
    Heard := [], Primary := 0, Retired := false, CounterBefore := _LLM_Remote_AsyncCounter
    State.CounterBefore := CounterBefore
    PreviousCritical := Critical("Off")
    try {
        State.Directory := A_Temp . "\ergopti_llm_classify_" . Nonce . "_" . Mode
        FSCreateDirectoryExclusiveStrict(State.Directory)
        PeerScript := _DriverDir . "\tests\fixtures\llm_thinking_retry_peer.ps1"
        Services := _DriverDir . "\tests\fixtures\winhttp_test_services.ps1"
        State.Peer := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", PeerScript,
                "-Directory", State.Directory, "-ServicesPath", Services, "-Nonce", Nonce, "-Case", Mode],
            _LATRT_Done.Bind(State))
        AssertEqual(1, State.Peer.start())
        State.PeerPid := State.Peer.processId()
        AssertTrue(State.PeerPid is Integer && State.PeerPid > 0)
        AssertTrue(_LATRT_Wait(() => FSStrictExists(State.Directory . "\ready.json") || State.PeerCalls > 0, 30000))
        Ready := JsonParse(FSReadUtf8Exact(State.Directory . "\ready.json"))
        AssertEqual(Nonce, Ready["nonce"])
        AssertEqual(Mode, Ready["case"])
        AssertEqual(State.PeerPid, Ready["pid"])
        AssertTrue(Ready["port"] is Integer && Ready["port"] > 0 && Ready["port"] <= 65535)
        Entry := Map("Provider", "openai_compat", "Model", "fixture-model", "Token", "owned-fixture-secret",
            "BaseUrl", "http://127.0.0.1:" . Ready["port"] . "/v1")
        Id := LLM_RemoteGenerate_Async(Entry, "Fixture system.", "Fixture user.", 0.1,
            (Text, Usage := "") => Heard.Push(Map("ok", true, "text", Text)),
            (Info := "") => Heard.Push(Map("ok", false, "info", Info)),
            "", 8, "managed_classification_control", 20000)
        State.OriginalId := Id
        AssertEqual(CounterBefore + 1, Id)
        AssertTrue(_LLM_Remote_Async.Has(Id))
        State.OriginalEntry := _LLM_Remote_Async[Id]
        AssertEqual(1, _LATRT_Control(State, "release"))
        AssertTrue(_LATRT_Wait(() => Heard.Length > 0, 30000), "genuine terminal must invoke the neutral callback")
        AssertTrue(_LATRT_Wait(() => _LATRT_RequestsGone(State), 10000))
        AssertEqual(1, _LATRT_Control(State, "stop"))
        AssertTrue(_LATRT_Wait(() => State.PeerCalls > 0, 10000))
        AssertEqual(1, State.PeerCalls)
        AssertEqual(0, State.PeerCode, State.PeerOutput . State.PeerErrors)
        Receipt := JsonParse(FSReadUtf8Exact(State.Directory . "\receipt.json"))
        AssertEqual(Nonce, Receipt["nonce"])
        AssertEqual(Mode, Receipt["case"])
        AssertEqual(State.PeerPid, Receipt["pid"])
        AssertTrue(Receipt["ok"] && Receipt["released"] && Receipt["stop_received"] && Receipt["listener_retired"])
        AssertEqual(1, Receipt["http_requests"], "both controls require exactly one real HTTP POST")
        AssertEqual(1, _LLM_Remote_AsyncCounter - CounterBefore)
        AssertEqual(1, Heard.Length)
        Http := State.OriginalEntry["http"]
        AssertEqual(Status, Http.Status)
        AssertTrue(Http.Completed && Http.ResponseEncodingValid && Http.ManagedPayloadPublished)
        Expected := _LLMRemoteClassifyTerminal("openai", Map("exit", 0, "status", Http.Status,
            "body_read", true, "body", Http.ResponseText), "fixture-model")
        if Status == 400 {
            AssertFalse(Heard[1]["ok"])
            Info := Heard[1]["info"]
            AssertTrue(Info is Map)
            _TestPrint("# MANAGED_CLASSIFICATION " . KL_JsonEncode(Map("http_requests", Receipt["http_requests"],
                "status", Info["status"], "reason", Info["reason"], "message", Info["message"],
                "expected_reason", Expected["reason"], "expected_message", Expected["server_message"])))
            AssertEqual("provider_error", Expected["reason"])
            AssertEqual("owned-classification-refusal", Expected["server_message"])
            AssertEqual(Status, Info["status"])
            AssertEqual(Expected["reason"], Info["reason"], "managed failure must preserve production terminal classification")
            AssertEqual(Expected["server_message"], Info["message"], "provider error text cannot be discarded")
            ExpectedReport := ManagedNetworkFailureWindows_FromTransport(Http, () => true)
            if ExpectedReport is Map {
                AssertTrue(Info.Has("network_report") && Info["network_report"] is Map,
                    "an actual managed native report must remain attached")
                AssertEqual(ExpectedReport["cause"], Info["network_report"]["cause"])
                AssertEqual(ExpectedReport["evidence"], Info["network_report"]["evidence"])
            } else
                AssertFalse(Info.Has("network_report"), "absence of native evidence cannot manufacture a report")
        } else {
            AssertTrue(Heard[1]["ok"] && Expected["ok"])
            AssertEqual("owned-thinking-retry-ok", Heard[1]["text"])
        }
        AssertEqual(0, ManagedNetworkTerminalFailure.Owners.Count)
        AssertFalse(IsObject(ManagedDownloadFailureWindow.Current), "neutral callbacks cannot create failure windows")
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try Retired := _LATRT_Retire(State)
        catch Any as Failure {
            if !IsObject(Primary)
                Primary := Failure
        }
        if Retired {
            try _LATRT_DeletePrivate(State)
            catch Any as Failure {
                _LATRT_Debt[Nonce] := State
                if !IsObject(Primary)
                    Primary := Failure
            }
        } else
            _LATRT_Debt[Nonce] := State
        Critical(PreviousCritical)
    }
    if !Retired && !IsObject(Primary)
        Primary := Error("Exact managed HTTP retirement remains pending.")
    if IsObject(Primary)
        throw Primary
}

_LATHTTP_Run(Status) {
    _ManagedRemoteFixtureWithLlmTimings(_LATHTTP_HostScope.Bind(_LATHTTP_Case.Bind(Status)))
}
for _LATHTTP_Status in [200, 400]
    Test("LLM managed HTTP " . _LATHTTP_Status . " preserves canonical terminal details (managed-http-classification)",
        _LATHTTP_Run.Bind(_LATHTTP_Status))
