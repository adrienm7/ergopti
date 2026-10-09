; static/ergopti_plus/windows/tests/unit/test_updater_balloon_click_ownership.ahk

; ==============================================================================
; MODULE: Updater Balloon Ownership Tests
; DESCRIPTION:
; Every tray balloon of the driver is a TrayTip on the same icon, and Windows
; reports a click on any of them as NIN_BALLOONUSERCLICK with no identity.
; _Updater_OnTrayMsg treated every such click as a click on the update offer:
; a saved screenshot, a copied colour or the manual check's "up to date"
; balloon opened the update prompt, and with no cached release the fallback
; fetched and showed "Update available" for the version already installed.
;
; Ownership is last-shown-wins: the updater claims the next NIN_BALLOONSHOW
; right before its own TrayTip, and releases it before any other balloon it
; shows; a click routes only while it owns the balloon. The fallback path also
; offers only a candidate the shared offer rule accepts.
; ==============================================================================

_UBCO_Reset() {
	_Updater_ReleaseBalloon()
}

_UBCO_ClickAfterUpdaterBalloonOpensThePrompt() {
	global UPDATER_NIN_BALLOONSHOW, UPDATER_NIN_BALLOONUSERCLICK
	State := { Shows: 0 }
	ShowFn := () => (State.Shows += 1)
	try {
		_UBCO_Reset()
		_Updater_ClaimBalloon()
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONSHOW, 0x404, 0, ShowFn)
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONUSERCLICK, 0x404, 0, ShowFn)
		AssertEqual(1, State.Shows, "a click on the updater's own balloon opens the update prompt")
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONUSERCLICK, 0x404, 0, ShowFn)
		AssertEqual(1, State.Shows, "the claim is spent by the click it answered")
	} finally {
		_UBCO_Reset()
	}
}
Test("Updater balloon: a click on the updater's balloon opens the update prompt",
	_UBCO_ClickAfterUpdaterBalloonOpensThePrompt)

_UBCO_ForeignBalloonClickIsIgnored() {
	global UPDATER_NIN_BALLOONSHOW, UPDATER_NIN_BALLOONUSERCLICK
	State := { Shows: 0 }
	ShowFn := () => (State.Shows += 1)
	try {
		_UBCO_Reset()
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONUSERCLICK, 0x404, 0, ShowFn)
		AssertEqual(0, State.Shows, "a click on a balloon the updater never showed is not an update click")

		; The updater's balloon, then a screenshot balloon replacing it.
		_Updater_ClaimBalloon()
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONSHOW, 0x404, 0, ShowFn)
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONSHOW, 0x404, 0, ShowFn)
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONUSERCLICK, 0x404, 0, ShowFn)
		AssertEqual(0, State.Shows, "a balloon shown after the updater's own takes the click")

		; The updater's own non-offer balloon (the manual check's "up to date").
		_Updater_ClaimBalloon()
		_Updater_ReleaseBalloon()
		_Updater_OnTrayMsg(0, UPDATER_NIN_BALLOONUSERCLICK, 0x404, 0, ShowFn)
		AssertEqual(0, State.Shows, "a click on the updater's up-to-date balloon is not an update click")
	} finally {
		_UBCO_Reset()
	}
}
Test("Updater balloon: a click on any other balloon does not open the update prompt",
	_UBCO_ForeignBalloonClickIsIgnored)

; The manual check shows no balloon at all: every answer is in the update-check
; window (ui/update_check), so no balloon of its can be read as an offer.
_UBCO_UpdaterNonOfferBalloonsReleaseTheClaim() {
	Body := _DriverFuncBody("_Updater_OneClickUpdateCallback")
	Assert(Body != "", "_Updater_OneClickUpdateCallback must exist")
	AssertEqual(0, InStr(Body, "TrayTip("), "the manual check answers in its window, never in a balloon")
	AssertTrue(InStr(Body, "UpdateCheck_ShowResult(") > 0, "the manual check shows its answer in the window")
	Offer := _DriverFuncBody("_Updater_HandleBackgroundResult")
	ClaimAt := InStr(Offer, "_Updater_ClaimBalloon()")
	TipAt := InStr(Offer, "TrayTip(", , ClaimAt)
	Assert(ClaimAt > 0 and TipAt > ClaimAt, "the update offer claims the balloon right before its TrayTip")
}
Test("Updater balloon: the manual check shows no balloon, the offer claims its own", _UBCO_UpdaterNonOfferBalloonsReleaseTheClaim)

_UBCO_RecordPrompt(State, Release, Request) {
	State.Prompts.Push(Release.Tag)
}

_UBCO_RecordNotice(State, Message, Title, Options) {
	State.Notices.Push(Message)
}

; With no cached release, the notification fallback fetches the channel's latest
; release: it must offer only a candidate the offer rule accepts.
_UBCO_FallbackOffersOnlyANewerRelease() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CHANNEL
	SavedChannel := UPDATER_CHANNEL
	try {
		UPDATER_CHANNEL := UpdateChannels_UnreleasedBuildChannel()
		for _, Pair in [["v0.0.0-dev.200", 0], ["v0.0.0-dev.201", 1]] {
			State := { Prompts: [], Notices: [] }
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Json := '{"tag_name":"' . Pair[1] . '","body":"","html_url":"https://github.com/adrienm7/ergopti/releases/tag/'
				. Pair[1] . '","published_at":"2026-09-01T00:00:00Z","prerelease":true}'
			_Updater_ShowAvailableUpdateCallback(Json, Request, 0,
				_UBCO_RecordNotice.Bind(State), _UBCO_RecordPrompt.Bind(State), "0.0.0-dev.200")
			AssertEqual(Pair[2], State.Prompts.Length, "the update prompt for " . Pair[1] . " against 0.0.0-dev.200")
			if (Pair[2] == 0) {
				AssertEqual(1, State.Notices.Length, "the installed version is reported as up to date")
				AssertEqual(Format(t("updater.up_to_date"), "0.0.0-dev.200"), State.Notices[1])
			}
		}
	} finally {
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("Updater balloon: the fetch fallback offers only a newer release", _UBCO_FallbackOffersOnlyANewerRelease)
