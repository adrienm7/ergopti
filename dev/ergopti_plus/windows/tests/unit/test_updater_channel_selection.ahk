; static/ergopti_plus/windows/tests/unit/test_updater_channel_selection.ahk

; ==============================================================================
; MODULE: Updater Channel Selection Tests
; DESCRIPTION:
; The Windows updater reads its channels from the shared registry
; (modules/updater/channels.ahk over the generated data) instead of "main"/"dev"
; literals.
;
; ROOT CAUSE ENCODED:
; The stable channel asked GitHub's /releases/latest, which ignores prereleases
; and answers 404 while no stable release exists; the 404 became an empty
; payload that every caller reported as "could not reach GitHub". Every channel
; now reads the same release list and keeps its latest release through the
; registry's tag rule, and "no release on this channel" is its own outcome.
; The persisted channel, the build stamp and the live request provenance are
; validated against the registry, so an alias ("stable") or an unknown id can
; neither become a live channel nor be refused silently.
; ==============================================================================

_UpdChanSel_List() {
	; GitHub lists by publish date: the newest dev build comes first, the only
	; stable release is older, and a foreign family must be ignored.
	return '['
		. '{"tag_name":"v0.0.0-dev.134","prerelease":true,"body":"dev 134"},'
		. '{"tag_name":"v1.2.0","prerelease":false,"body":"stable 1.2.0"},'
		. '{"tag_name":"v1.3.0-beta.1","prerelease":true,"body":"beta"},'
		. '{"tag_name":"v0.0.0-dev.133","prerelease":true,"body":"dev 133"},'
		. '{"tag_name":"v1.1.0","prerelease":false,"body":"stable 1.1.0"}'
		. ']'
}

_UpdChanSel_SelectsTheChannelsLatest() {
	Select := _UpdaterTest_ResolveFunction("_Updater_SelectChannelRelease")
	NoRelease := _UpdaterTest_ResolveFunction("_Updater_JsonIsNoChannelRelease")
	AssertEqual("v1.2.0", Updater_ParseTagName(Select.Call(_UpdChanSel_List(), "main")),
		"the stable channel must keep its latest stable release, not the newest publication")
	AssertEqual("v0.0.0-dev.134", Updater_ParseTagName(Select.Call(_UpdChanSel_List(), "dev")),
		"the dev channel must keep its latest dev build")
	OnlyDev := '[{"tag_name":"v0.0.0-dev.134","prerelease":true},{"tag_name":"v0.0.0-dev.133","prerelease":true}]'
	Empty := Select.Call(OnlyDev, "main")
	AssertTrue(NoRelease.Call(Empty),
		"a list without a stable release must report that the channel has none")
	AssertFalse(_Updater_JsonPayloadIsFailure(Empty),
		"no release on a channel is not a network failure")
	AssertFalse(NoRelease.Call(""), "a failed fetch is not an empty channel")
}
Test("Updater channels: a channel keeps its latest release from the shared list", _UpdChanSel_SelectsTheChannelsLatest)

_UpdChanSel_InterpretsListResponses() {
	global _UpdaterFetchCache
	SavedCache := _UpdaterFetchCache
	try {
		_UpdaterFetchCache := Map()
		Json := _Updater_InterpretResponse(200, _UpdChanSel_List(), '"list-etag"', "main", "test://list")
		AssertEqual("v1.2.0", Updater_ParseTagName(Json),
			"a fresh list must be narrowed to the channel's latest release")
		Again := _Updater_InterpretResponse(304, "", "", "main", "test://list")
		AssertEqual("v1.2.0", Updater_ParseTagName(Again),
			"a 304 must reuse the cached list and select the same release again")
	} finally {
		_UpdaterFetchCache := SavedCache
	}
}
Test("Updater channels: conditional list responses keep the channel's release", _UpdChanSel_InterpretsListResponses)

_UpdChanSel_EveryChannelReadsTheList() {
	UrlFn := _UpdaterTest_ResolveFunction("Updater_ReleaseApiUrl")
	Url := UrlFn.Call()
	AssertEqual(0, InStr(Url, "/releases/latest"),
		"no channel may depend on /releases/latest, which answers 404 without a stable release")
	AssertTrue(InStr(Url, "/releases?per_page=") > 0, "the update check must read the release list")
}
Test("Updater channels: every channel reads the release list endpoint", _UpdChanSel_EveryChannelReadsTheList)

_UpdChanSel_LoadChannelResolvesThroughTheRegistry() {
	global _IniCache, UPDATER_CHANNEL, UPDATER_INI_SECTION, UPDATER_INI_KEY
	SavedCache := IsSet(_IniCache) ? _IniCache : unset
	SavedChannel := UPDATER_CHANNEL
	try {
		Installed := _Updater_InstalledChannel()
		AssertTrue(UpdateChannels_IsKnown(Installed), "the installed channel must be a registry channel")
		for _, Scenario in [
			{ Raw: "dev", Expected: "dev", Why: "a channel id is followed" },
			{ Raw: "main", Expected: "main", Why: "a channel id is followed" },
			{ Raw: "stable", Expected: "main", Why: "an alias reads as its channel" },
			{ Raw: "beta", Expected: Installed, Why: "an unknown value follows the installed channel" }
		] {
			_IniCache := Map(UPDATER_INI_SECTION, Map(UPDATER_INI_KEY, Scenario.Raw))
			Updater_LoadChannel()
			AssertEqual(Scenario.Expected, UPDATER_CHANNEL, Scenario.Why . " (" . Scenario.Raw . ")")
		}
		_IniCache := Map()
		Updater_LoadChannel()
		AssertEqual(Installed, UPDATER_CHANNEL, "without a persisted value the installed channel is followed")
	} finally {
		if IsSet(SavedCache)
			_IniCache := SavedCache
		else
			_IniCache := unset
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("Updater channels: the persisted channel resolves through the registry", _UpdChanSel_LoadChannelResolvesThroughTheRegistry)

_UpdChanSel_RequestsCarryRegistryChannels() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "dev")
	AssertTrue(_Updater_RequestContextValid(Request), "a registry channel is a valid request channel")
	Alias := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "stable")
	AssertFalse(_Updater_RequestContextValid(Alias),
		"an alias is resolved at the persistence boundary, never carried as a live channel")
}
Test("Updater channels: request provenance only carries registry channel ids", _UpdChanSel_RequestsCarryRegistryChannels)

_UpdChanSel_RecordWrite(State, *) {
	State.Writes += 1
	return true
}

; Stands in for Reload and its timer: a regression that accepted the id must
; not restart the test runner.
_UpdChanSel_RecordReload(State, *) {
	State.Reloads += 1
	return true
}

_UpdChanSel_SetChannelRefusesUnknownIds() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CHANNEL
	Saved := _UpdaterTest_SaveRequestState()
	SavedChannel := UPDATER_CHANNEL
	try {
		_UpdaterTest_ResetRequestState()
		State := { Writes: 0, Reloads: 0 }
		for _, Unknown in ["beta", "stable", "Main"] {
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
			AssertFalse(Updater_SetChannel(Unknown, Request, false, 0,
				_UpdChanSel_RecordWrite.Bind(State), _UpdChanSel_RecordReload.Bind(State),
				_UpdChanSel_RecordReload.Bind(State), _UpdChanSel_RecordReload.Bind(State),
				_UpdChanSel_RecordReload.Bind(State)),
				"Updater_SetChannel must refuse '" . Unknown . "', which is no registry channel id")
		}
		AssertEqual(0, State.Writes, "a refused channel must never reach config.toml")
		AssertEqual(0, State.Reloads, "a refused channel must never schedule a Reload")
		AssertEqual(SavedChannel, UPDATER_CHANNEL, "a refused channel must not become the live channel")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("Updater channels: Updater_SetChannel refuses ids outside the registry", _UpdChanSel_SetChannelRefusesUnknownIds)

_UpdChanSel_NoReleaseMessageNamesTheChannel() {
	Message := _UpdaterTest_ResolveFunction("_Updater_NoChannelReleaseMessage")
	Text := Message.Call("main")
	AssertTrue(InStr(Text, t("updater.channel.main")) > 0,
		"the message must name the channel through its registry label")
	AssertEqual(0, InStr(Text, "{channel}"), "the placeholder must be filled")
}
Test("Updater channels: the empty-channel message names the channel", _UpdChanSel_NoReleaseMessageNamesTheChannel)

_UpdChanSel_CountClose(State, *) {
	State.Closed += 1
	return true
}

_UpdChanSel_RecordOpen(State, Channel, *) {
	State.Opened.Push(Channel)
	return true
}

_UpdChanSel_Answer(State, Answer, Question) {
	State.Questions.Push(Question)
	return Answer
}

_UpdChanSel_RecordSubscribe(State, Channel, Request) {
	State.Subscribed.Push(Channel)
	return true
}

_UpdChanSel_NativeViewNeverSubscribes() {
	State := { Closed: 0, Opened: [] }
	AssertTrue(_Updater_ViewChangelogChannel("window", "dev", false, 0,
		_UpdChanSel_CountClose.Bind(State), _UpdChanSel_RecordOpen.Bind(State)),
		"viewing a registry channel must reopen the window on it")
	AssertEqual(1, State.Closed, "the window showing the previous channel is closed")
	AssertEqual("dev", State.Opened[1], "the window reopens on the chosen channel")
	AssertFalse(_Updater_ViewChangelogChannel("window", "stable", false, 0,
		_UpdChanSel_CountClose.Bind(State), _UpdChanSel_RecordOpen.Bind(State)),
		"an alias or unknown id is refused before any window change")
	AssertEqual(1, State.Opened.Length, "a refused view opens nothing")
}
Test("Updater channels: the native Versions picker only changes the view", _UpdChanSel_NativeViewNeverSubscribes)

_UpdChanSel_NativeSubscribeAsksFirst() {
	State := { Closed: 0, Questions: [], Subscribed: [] }
	AssertFalse(_Updater_SubscribeChangelogChannel("window", "dev", false, 0,
		_UpdChanSel_CountClose.Bind(State), _UpdChanSel_Answer.Bind(State, "No"),
		_UpdChanSel_RecordSubscribe.Bind(State)),
		"declining the restart must keep the subscription")
	AssertEqual(0, State.Subscribed.Length, "no channel may change without the confirmation")
	AssertEqual(0, State.Closed, "the window stays open when the user declines")
	AssertTrue(InStr(State.Questions[1], t("updater.channel.dev")) > 0,
		"the confirmation names the channel through its registry label")

	AssertTrue(_Updater_SubscribeChangelogChannel("window", "dev", false, 0,
		_UpdChanSel_CountClose.Bind(State), _UpdChanSel_Answer.Bind(State, "Yes"),
		_UpdChanSel_RecordSubscribe.Bind(State)),
		"a confirmed subscription goes to the channel owner")
	AssertEqual("dev", State.Subscribed[1], "the shown channel becomes the subscribed one")

	Asked := State.Questions.Length
	AssertFalse(_Updater_SubscribeChangelogChannel("window", "beta", false, 0,
		_UpdChanSel_CountClose.Bind(State), _UpdChanSel_Answer.Bind(State, "Yes"),
		_UpdChanSel_RecordSubscribe.Bind(State)),
		"an unknown channel is refused")
	AssertEqual(Asked, State.Questions.Length, "an unknown channel is refused before asking")
	AssertEqual(1, State.Subscribed.Length, "a refused channel never reaches the owner")
}
Test("Updater channels: the native Versions window subscribes only after confirmation", _UpdChanSel_NativeSubscribeAsksFirst)
