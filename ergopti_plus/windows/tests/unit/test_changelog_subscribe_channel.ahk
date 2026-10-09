; static/ergopti_plus/windows/tests/unit/test_changelog_subscribe_channel.ahk

; ==============================================================================
; MODULE: Changelog Subscription Bridge Tests
; DESCRIPTION:
; The Versions page's "Receive updates from <channel>" banner posts set_channel.
; The WebView host hands it to the one channel owner (Updater_SetChannel) and
; always answers the page with the subscription that holds afterwards, so a
; refused request surfaces as a failure instead of a banner stuck on "pending".
; The page used to switch the subscription implicitly with its tabs; now a tab
; only changes the view, and the host tells the page which channel it receives.
; ==============================================================================

_CSC_RecordSetChannel(State, Accept, Channel, Request) {
	State.Calls.Push(Channel)
	State.Requests.Push(Request)
	return Accept
}

_CSC_RecordEval(State, Script) {
	State.Scripts.Push(Script)
}

_CSC_Subscribe(Channel, Accept) {
	State := { Calls: [], Requests: [], Scripts: [] }
	Request := { Marker: "bridge request" }
	Result := _CLW_SubscribeChannel(Channel, Request,
		_CSC_RecordSetChannel.Bind(State, Accept), _CSC_RecordEval.Bind(State))
	State.Result := Result
	State.Request := Request
	return State
}

_CSC_OtherChannel() {
	global UPDATER_CHANNEL
	for Id in UpdateChannels_Ids()
		if (Id !== UPDATER_CHANNEL)
			return Id
	throw Error("the registry must declare a second channel")
}

_CSC_AcceptedChannelReachesTheOwner() {
	Channel := _CSC_OtherChannel()
	State := _CSC_Subscribe(Channel, true)
	AssertEqual(1, State.Calls.Length, "the channel owner must receive the request once")
	AssertEqual(Channel, State.Calls[1], "the owner must receive the requested channel")
	AssertTrue(State.Requests[1] == State.Request, "the bridge request context must reach the owner")
	AssertTrue(State.Result, "an accepted change must be reported as accepted")
	AssertEqual(1, State.Scripts.Length, "the page must be answered once")
	AssertEqual("setSubscribedChannel(" . JsonStringLiteral(Channel) . ",true)", State.Scripts[1],
		"the page must learn the new subscription")
}

_CSC_RefusedChannelsNeverReachTheOwner() {
	global UPDATER_CHANNEL
	Expected := "setSubscribedChannel(" . JsonStringLiteral(UPDATER_CHANNEL) . ",false)"
	for Raw in ["beta", "", StrUpper(_CSC_OtherChannel()), 42] {
		State := _CSC_Subscribe(Raw, true)
		Label := Raw is String ? "'" . Raw . "'" : Type(Raw)
		AssertEqual(0, State.Calls.Length, "channel " . Label . " must not reach the owner")
		AssertFalse(State.Result, "channel " . Label . " must be refused")
		AssertEqual(1, State.Scripts.Length, "the page must be answered for " . Label)
		AssertEqual(Expected, State.Scripts[1], "the page must keep the current subscription for " . Label)
	}
}

_CSC_OwnerRefusalIsReportedToThePage() {
	global UPDATER_CHANNEL
	State := _CSC_Subscribe(_CSC_OtherChannel(), false)
	AssertEqual(1, State.Calls.Length, "the owner must have been asked")
	AssertFalse(State.Result, "a refused change must be reported as refused")
	AssertEqual("setSubscribedChannel(" . JsonStringLiteral(UPDATER_CHANNEL) . ",false)", State.Scripts[1],
		"the page must show the failure and the unchanged subscription")
}

_CSC_BridgeRoutesAndSeedsTheSubscription() {
	Handler := _DriverFuncBody("_CLW_OnWebMessage")
	AssertTrue(RegExMatch(Handler, 's)Action == "set_channel"\).*?_CLW_SubscribeChannel\(') > 0,
		"the bridge must route set_channel to _CLW_SubscribeChannel")
	Build := _DriverFuncBody("_CLW_BuildWindow")
	AssertTrue(InStr(Build, "window.__subscribed_channel=") > 0,
		"the page must be seeded with the subscribed channel")
	AssertTrue(InStr(Build, "window.__channel_switch_restarts=true") > 0,
		"the page must know a channel change restarts the driver")
}

Test("Changelog subscription: an accepted channel reaches the one owner and the page", _CSC_AcceptedChannelReachesTheOwner)
Test("Changelog subscription: ids outside the registry are refused", _CSC_RefusedChannelsNeverReachTheOwner)
Test("Changelog subscription: an owner refusal is reported to the page", _CSC_OwnerRefusalIsReportedToThePage)
Test("Changelog subscription: the bridge routes set_channel and seeds the subscription", _CSC_BridgeRoutesAndSeedsTheSubscription)
