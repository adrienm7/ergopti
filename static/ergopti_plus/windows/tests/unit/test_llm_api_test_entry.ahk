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

; No active entry, or an entry id pointing nowhere: refuse before any owner,
; request or notification. The dispatch itself is never reached, so this also
; proves the refusal path needs no network.
_LAT_RefusesWithNoActiveEntry() {
	SavedMenu := _LAT_FixtureMenu()
	try {
		_LLM_Menu["api_entries"] := []
		_LLM_Menu["api_entry_id"] := ""
		AssertFalse(_LLM_Menu_TestActiveApiEntry(),
			"an empty entry list must refuse the probe")
		_LLM_Menu["api_entries"] := [_LAT_FixtureEntry()]
		_LLM_Menu["api_entry_id"] := "ghost"
		AssertFalse(_LLM_Menu_TestActiveApiEntry(),
			"an entry id pointing nowhere must refuse the probe")
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
	try {
		LLM_REMOTE_TEST_REQUEST := Map()
		AssertFalse(_LLM_Menu_TestActiveApiEntry(),
			"a missing shared probe spec must refuse the probe")
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
