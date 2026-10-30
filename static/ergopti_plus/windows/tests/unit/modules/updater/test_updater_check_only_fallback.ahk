; tests/unit/modules/updater/test_updater_check_only_fallback.ahk

; ==============================================================================
; MODULE: Updater Check-Only Fallback Tests
; DESCRIPTION:
; Replays the shared corpus of the public Atom feed answer and of the stored list
; copy, then drives the manual check: when the API gives no list the feed answers,
; a release it names is announced without an Update path, and nothing reaches the
; tray's cached release.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TUCO_CorpusDir := A_LineFile . "\..\..\..\..\..\..\_shared\tests\corpus\updater\"

_TUCO_Read(Name) {
	global _TUCO_CorpusDir
	return FileRead(_TUCO_CorpusDir . Name, "UTF-8")
}

_TUCO_FeedVectors() {
	Corpus := JsonParse(_TUCO_Read("check_only_vectors.json"))
	Feed := _TUCO_Read(Corpus["feed"])
	List := _Updater_ParseReleaseFeed(Feed, Corpus["owner"], Corpus["repo"], &Reason)
	Assert(List != "", "the corpus feed gives a list: " . Reason)
	AssertEqual(0, InStr(List, "foreign"), "the foreign entry never counts")
	Assert(Corpus["cases"].Length >= 4, "the corpus holds its cases")
	for Vector in Corpus["cases"] {
		Index := _Updater_ReleaseListIndex(List)
		Selected := _Updater_SelectChannelRelease(List, Vector["channel"], Index)
		AssertEqual(Vector["latest"], Updater_ParseTagName(Selected), Vector["id"])
		Offered := UpdateChannels_ShouldOffer(Vector["latest"], Vector["current"], Vector["channel"], Vector["installed"])
		AssertEqual(Vector["state"], Offered ? "available" : "up_to_date", Vector["id"])
		AssertEqual(Vector["check_only"] ? 1 : 0, Offered ? 1 : 0, Vector["id"] . ": only an available release is check-only")
	}
}
Test("updater check-only: the feed answers the shared vectors (PAR-14)", _TUCO_FeedVectors)

_TUCO_FeedRefusals() {
	AssertEqual("", _Updater_ParseReleaseFeed("<html>blocked</html>", "o", "r", &Reason))
	AssertEqual("not an Atom feed", Reason)
	Foreign := '<feed><entry><link rel="alternate" href="https://github.com/other/r/releases/tag/v1"/></entry></feed>'
	AssertEqual("", _Updater_ParseReleaseFeed(Foreign, "o", "r", &Reason))
	AssertEqual("an Atom feed without a release of o/r", Reason)
	Unsafe := '<feed><entry><link href="https://github.com/o/r/releases/tag/v1%22x"/></entry></feed>'
	AssertEqual("", _Updater_ParseReleaseFeed(Unsafe, "o", "r", &Reason), "a tag outside the rule is dropped")
	Good := "<feed><entry><link rel='self' href='https://x/y'/><link rel='alternate' href='https://github.com/o/r/releases/tag/v1.0%2Bb'/>"
		. "<updated>2026-01-02T03:04:05Z</updated></entry><entry><link href='https://github.com/o/r/releases/tag/v2'/>"
		. "<updated>not a date</updated></entry></feed>"
	AssertEqual('[{"tag_name":"v1.0+b","published_at":"2026-01-02T03:04:05Z"},{"tag_name":"v2","published_at":""}]',
		_Updater_ParseReleaseFeed(Good, "o", "r", &Reason))
}
Test("updater check-only: the feed parser refuses what is not a release of this repository (PAR-14)",
	_TUCO_FeedRefusals)

; The Windows copy is a text file, so each stored value is written as that file
; would hold it. Its bound is the closing bracket a cut body lacks: the Windows
; list is a whole list, larger than one Linux page (max_body_bytes).
_TUCO_ListCacheVectors() {
	global UPDATER_LIST_CACHE_MAGIC
	Corpus := JsonParse(_TUCO_Read("list_cache_vectors.json"))
	Assert(Corpus["cases"].Length >= 12, "the corpus holds its cases")
	for Vector in Corpus["cases"] {
		Stored := Vector["stored"]
		Text := Stored
		ExpectedUrl := Vector.Get("expected_url", "")
		if (Stored is Map) {
			Url := Stored.Get("url", "")
			if (ExpectedUrl == "")
				ExpectedUrl := Url
			Body := Stored.Get("body", "")
			if Stored.Has("body_repeat") {
				Repeat := Stored["body_repeat"]
				Body := Repeat["prefix"] . StrReplace(Format("{:" . Repeat["count"] . "}", ""), " ", Repeat["unit"])
			}
			Text := UPDATER_LIST_CACHE_MAGIC . "`n" . Url . "`n" . Stored.Get("etag", "") . "`n" . Body
		}
		Parsed := _Updater_ParseListCache(Text, ExpectedUrl)
		AssertEqual(Vector["valid"] ? 1 : 0, IsObject(Parsed) ? 1 : 0, Vector["id"])
	}
}
Test("updater check-only: the stored list copy follows the shared vectors (PAR-14)", _TUCO_ListCacheVectors)

; Drives the manual check's completion with the window captured.
_TUCO_ManualCase(Scenario) {
	global _UC_PresentFn, _UC_RequestId, _UC_State, _UC_Release, UPDATER_LATEST_RELEASE, _UpdaterCheckInProgress
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	SavedPresent := _UC_PresentFn
	SavedLatest := IsSet(UPDATER_LATEST_RELEASE) ? UPDATER_LATEST_RELEASE : ""
	SavedProgress := IsSet(_UpdaterCheckInProgress) ? _UpdaterCheckInProgress : false
	Shown := []
	_UC_PresentFn := (State) => (Shown.Push(State), true)
	try {
		_UpdaterTest_ResetRequestState()
		UPDATER_LATEST_RELEASE := ""
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "main")
		UpdateCheck_Begin(Request, "1.0.0")
		Scenario.Call(Request, Shown)
	} finally {
		_UC_PresentFn := SavedPresent
		_UC_RequestId := 0, _UC_State := 0, _UC_Release := 0
		UPDATER_LATEST_RELEASE := SavedLatest
		_UpdaterCheckInProgress := SavedProgress
		_UpdaterTest_RestoreRequestState(Saved)
	}
}

_TUCO_ApiFailureAsksTheFeed(Request, Shown) {
	global UPDATER_LATEST_RELEASE, _UpdaterCheckInProgress
	Feed := []
	_Updater_OneClickUpdateCallback("", "1.0.0", Request, 0, false,
		(Channel, FeedRequest, OnJson) => Feed.Push(Map("channel", Channel, "on_json", OnJson)))
	AssertEqual(1, Feed.Length, "an API failure reads the feed")
	AssertEqual("main", Feed[1]["channel"])
	AssertEqual(1, Shown.Length, "the window still shows checking")
	AssertEqual("checking", Shown[1]["state"])
	AssertTrue(_UpdaterCheckInProgress, "the row stays checking during the feed")

	Feed[1]["on_json"].Call('{"tag_name":"v2.0.0","published_at":""}', Request)
	Answer := Shown[Shown.Length]
	AssertEqual("available", Answer["state"])
	AssertEqual("v2.0.0", Answer["latest"])
	AssertTrue(Answer.Get("check_only", false), "the answer is check-only")
	AssertTrue(JsonParse(_UpdateCheck_StateJson(Answer)).Get("check_only", false), "the page is told")
	AssertFalse(IsObject(UPDATER_LATEST_RELEASE), "the tray row never offers it")
	AssertFalse(_UpdaterCheckInProgress)

	Installs := []
	Outcome := UpdateCheck_Perform("update", "", Map("install", (Release) => (Installs.Push(Release), true)))
	AssertFalse(Outcome["ok"], "Update is refused for a check-only release")
	AssertEqual(0, Installs.Length, "nothing installs")
}
Test("updater check-only: an API failure reads the feed and announces without an install (PAR-14)",
	() => _TUCO_ManualCase(_TUCO_ApiFailureAsksTheFeed))

_TUCO_FeedFailureIsTheFailure(Request, Shown) {
	Feed := []
	_Updater_OneClickUpdateCallback("", "1.0.0", Request, 0, false,
		(Channel, FeedRequest, OnJson) => Feed.Push(OnJson))
	Feed[1].Call("", Request)
	Answer := Shown[Shown.Length]
	AssertEqual("error", Answer["state"], "both sources failed: the check failed")
	AssertEqual("updater.no_connection", Answer["reason_key"])
	AssertEqual(1, Feed.Length, "the feed is asked once")
}
Test("updater check-only: a failed feed answers the connection failure once (PAR-14)",
	() => _TUCO_ManualCase(_TUCO_FeedFailureIsTheFailure))

_TUCO_ApiListNeverAsksTheFeed(Request, Shown) {
	Feed := []
	_Updater_OneClickUpdateCallback('{"tag_name":"v1.0.0"}', "1.0.0", Request, 0, false,
		(Channel, FeedRequest, OnJson) => Feed.Push(OnJson))
	AssertEqual(0, Feed.Length, "an API answer ends the check")
	AssertEqual(0, InStr(_UpdateCheck_StateJson(Shown[Shown.Length]), "check_only"), "the API's answer is installable")
}
Test("updater check-only: an API answer never reads the feed (PAR-14)",
	() => _TUCO_ManualCase(_TUCO_ApiListNeverAsksTheFeed))

_TUCO_FeedResponse() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "main")
		AssertEqual("", _Updater_InterpretFeedResponse(403, "", "main", Request))
		AssertEqual("", _Updater_InterpretFeedResponse(200, "<html>proxy page</html>", "main", Request))
		Feed := '<feed><entry><link href="https://github.com/' . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
			. '/releases/tag/v2.0.0"/></entry></feed>'
		AssertEqual("v2.0.0", Updater_ParseTagName(_Updater_InterpretFeedResponse(200, Feed, "main", Request)))
	} finally
		_UpdaterTest_RestoreRequestState(Saved)
	AssertEqual("https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases.atom",
		Updater_ReleaseFeedUrl())
	Prepare := _DriverFuncBody("_Updater_PrepareFeedAsyncTransport")
	Assert(InStr(Prepare, "application/atom+xml") > 0, "the feed asks for Atom")
	Assert(InStr(Prepare, "_Updater_PrepareReleasesListAsyncTransport(") > 0,
		"the feed uses the validator-free list transport: an API ETag never reaches it")
}
Test("updater check-only: the feed response gives the channel's release or a failure (PAR-14)", _TUCO_FeedResponse)

_TUCO_BackgroundFeed() {
	Body(Store, Clock) {
		global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_LATEST_RELEASE, UPDATER_LAST_NOTIFIED_TAG
		SavedLatest := IsSet(UPDATER_LATEST_RELEASE) ? UPDATER_LATEST_RELEASE : ""
		SavedTag := UPDATER_LAST_NOTIFIED_TAG
		try {
			UPDATER_LATEST_RELEASE := "", UPDATER_LAST_NOTIFIED_TAG := ""
			Feed := [], Shown := []
			Show := (Text) => Shown.Push(Text)
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			_Updater_HandleBackgroundResult("", "1.0.0", Request, 0, false,
				(Channel, FeedRequest, OnJson) => Feed.Push(OnJson), Show)
			AssertEqual(1, Feed.Length, "an API failure reads the public feed")
			AssertFalse(_UCSch_Record(Store).Has("last_check_at"), "nothing is recorded before the feed answers")
			Feed[1].Call('{"tag_name":"v2.0.0","published_at":""}', Request)
			AssertEqual(1, Shown.Length, "a newer release is announced")
			AssertContains(Shown[1], t("update_check.check_only"), "and says it cannot be installed yet")
			AssertFalse(IsObject(UPDATER_LATEST_RELEASE), "the tray's install row never offers it")
			AssertEqual(0, _UCSch_Record(Store)["failures"], "the feed answered: no failure backoff")
			; The same release is announced once.
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
			_Updater_HandleBackgroundResult('{"tag_name":"v2.0.0"}', "1.0.0", Request, 0, true, 0, Show)
			AssertEqual(1, Shown.Length, "already notified")
		} finally {
			UPDATER_LATEST_RELEASE := SavedLatest, UPDATER_LAST_NOTIFIED_TAG := SavedTag
		}
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68"), 1700000000, 1699990000, 86400, Body)
}
Test("updater check-only: a background check reads the feed and announces once, without an install (PAR-14)",
	_TUCO_BackgroundFeed)
