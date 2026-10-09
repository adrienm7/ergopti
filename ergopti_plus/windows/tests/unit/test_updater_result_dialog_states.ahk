; tests/unit/test_updater_result_dialog_states.ahk

; ==============================================================================
; MODULE: Update Check Window (Windows)
; DESCRIPTION:
; Drives the update-check window's host without opening a window
; (_UC_PresentFn captures what it would show):
; 1. "checking" names the checked channel; an answer of another check is
;    ignored; a failure names its reason's locale key and today's log;
; 2. the page's state message carries every field the shared page reads, and
;    the page's messages act only for the open window, as actions; a cancelled
;    check closes only the window that still shows it;
; 3. the actions act on the answer the window holds: Update installs only an
;    offered release and closes, a switch goes only to a listed channel, Report
;    names the updater and the cause, the log opens only for a failure; a
;    click while the driver is paused drives no updater action;
; 4. the native window composes the page's sentences, placeholders filled, and
;    replaces a WebView2 that could not be created without losing the check;
; 5. a manual check keeps the other channels with a newer release on its
;    request; a background check does not.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TUCD_Presented := []

_TUCD_Capture(State) {
	global _TUCD_Presented
	_TUCD_Presented.Push(State)
	return true
}

; Runs one case with the window replaced by the capture, restoring the host.
_TUCD_Run(Scenario) {
	global _UC_PresentFn, _UC_RequestId, _UC_State, _UC_Release, _TUCD_Presented
	SavedPresent := _UC_PresentFn
	_TUCD_Presented := []
	_UC_PresentFn := _TUCD_Capture
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		Scenario.Call()
	} finally {
		_UC_PresentFn := SavedPresent
		_UC_RequestId := 0
		_UC_State := 0
		_UC_Release := 0
		_UpdaterTest_RestoreRequestState(Saved)
	}
}

_TUCD_Request() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	return _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "dev")
}

_TUCD_Last() {
	global _TUCD_Presented
	return _TUCD_Presented[_TUCD_Presented.Length]
}

_TUCD_CheckingThenAnswer() {
	_TUCD_Run(_TUCD_CheckingThenAnswerCase)
}
_TUCD_CheckingThenAnswerCase() {
	global _TUCD_Presented
	Request := _TUCD_Request()
	AssertTrue(UpdateCheck_Begin(Request, "v0.0.0-dev.144"))
	AssertEqual("checking", _TUCD_Last()["state"])
	AssertEqual("dev", _TUCD_Last()["channel"], "checking names the checked channel")
	Other := _TUCD_Request()
	AssertFalse(UpdateCheck_ShowResult(Other, Map("state", "up_to_date", "current", "v0.0.0-dev.144")),
		"the answer of another check is ignored")
	AssertEqual(1, _TUCD_Presented.Length)
	AssertTrue(UpdateCheck_ShowResult(Request, Map("state", "error", "current", "v0.0.0-dev.144",
		"reason", "no_connection", "detail", "GitHub could not be reached")))
	Shown := _TUCD_Last()
	AssertEqual("error", Shown["state"])
	AssertEqual("updater.no_connection", Shown["reason_key"])
	AssertEqual(LoggerTodayLogPath(), Shown["log_path"], "a failure names today's log")
	AssertThrows(() => UpdateCheck_ShowResult(Request, Map("state", "error", "reason", "boom")),
		"an unknown reason is refused, not shown blank")
	AssertThrows(() => UpdateCheck_ShowResult(Request, Map("state", "installing")),
		"an unknown phase is refused")
}
Test("update check: checking names the channel, then the answer of that check only (update-check-window)",
	_TUCD_CheckingThenAnswer)

_TUCD_StateJson() {
	State := Map("state", "available", "channel", "dev", "current", "v0.0.0-dev.144",
		"latest", "v0.0.0-dev.150", "others", [Map("channel", "main", "tag", "v1.0.0")])
	Parsed := JsonParse(_UpdateCheck_StateJson(State))
	AssertEqual("state", Parsed["type"])
	AssertEqual("available", Parsed["state"])
	AssertEqual("dev", Parsed["channel"])
	AssertEqual("v0.0.0-dev.144", Parsed["current"])
	AssertEqual("v0.0.0-dev.150", Parsed["latest"])
	AssertEqual(1, Parsed["others"].Length)
	AssertEqual("main", Parsed["others"][1]["channel"])
	AssertEqual("v1.0.0", Parsed["others"][1]["tag"])
	Failure := JsonParse(_UpdateCheck_StateJson(Map("state", "error", "channel", "main", "current", "1.0.0",
		"reason_key", "updater.parse_failed", "log_path", "C:\Users\me\logs\ErgoptiPlus_2026-09-29.log")))
	AssertEqual("updater.parse_failed", Failure["reason_key"])
	AssertEqual("C:\Users\me\logs\ErgoptiPlus_2026-09-29.log", Failure["log_path"], "the path survives JSON")
	AssertEqual(0, Failure["others"].Length)
}
Test("update check: the page's state message carries every field it reads (update-check-window)",
	_TUCD_StateJson)

global _TUCD_Effects := 0

_TUCD_NewEffects() {
	global _TUCD_Effects
	Seen := { Installs: [], Changelogs: [], Switches: [], Reports: [], Logs: 0, Closes: 0 }
	_TUCD_Effects := Seen
	Install(Release) {
		Seen.Installs.Push(Release.Tag)
		return true
	}
	Changelog(Channel) {
		Seen.Changelogs.Push(Channel)
		return true
	}
	SetChannel(Channel) {
		Seen.Switches.Push(Channel)
		return true
	}
	Report(Record) {
		Seen.Reports.Push(Record)
		return true
	}
	OpenLog() {
		Seen.Logs += 1
		return true
	}
	Close() {
		Seen.Closes += 1
	}
	return Map("install", Install, "changelog", Changelog, "set_channel", SetChannel,
		"report", Report, "open_log", OpenLog, "close", Close)
}

_TUCD_Actions() {
	_TUCD_Run(_TUCD_ActionsCase)
}
_TUCD_ActionsCase() {
	global _TUCD_Effects
	Request := _TUCD_Request()
	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	Effects := _TUCD_NewEffects()
	AssertFalse(UpdateCheck_Perform("update", "", Effects)["ok"], "nothing installs while checking")
	AssertEqual(0, _TUCD_Effects.Installs.Length)

	UpdateCheck_ShowResult(Request, Map("state", "up_to_date", "current", "v0.0.0-dev.144",
		"latest", "v0.0.0-dev.144", "others", [Map("channel", "main", "tag", "v1.0.0")]))
	AssertFalse(UpdateCheck_Perform("update", "", Effects)["ok"], "an up-to-date answer installs nothing")
	AssertFalse(UpdateCheck_Perform("report", "", Effects)["ok"], "only a failure is reported")
	AssertFalse(UpdateCheck_Perform("switch_channel", "beta", Effects)["ok"], "an unlisted channel is refused")
	AssertEqual(0, _TUCD_Effects.Switches.Length)
	Switched := UpdateCheck_Perform("switch_channel", "main", Effects)
	AssertTrue(Switched["ok"] and Switched["closed"], "a listed channel is switched to, and the window closes")
	AssertEqual("main", _TUCD_Effects.Switches[1])

	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	Release := { Tag: "v0.0.0-dev.150", RawJson: "{}" }
	UpdateCheck_ShowResult(Request, Map("state", "available", "current", "v0.0.0-dev.144",
		"latest", Release.Tag, "others", [], "release", Release))
	AssertTrue(UpdateCheck_Perform("whats_new", "", Effects)["ok"])
	AssertEqual("dev", _TUCD_Effects.Changelogs[1], "What's new opens the Versions window on the channel")
	Installed := UpdateCheck_Perform("update", "", Effects)
	AssertTrue(Installed["ok"] and Installed["closed"], "Update installs the offered release and closes")
	AssertEqual("v0.0.0-dev.150", _TUCD_Effects.Installs[1])

	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	UpdateCheck_ShowResult(Request, Map("state", "error", "current", "v0.0.0-dev.144",
		"reason", "no_connection", "detail", "GitHub could not be reached"))
	AssertTrue(UpdateCheck_Perform("report", "", Effects)["ok"])
	Record := _TUCD_Effects.Reports[1]
	AssertEqual("Updater", Record["module"])
	AssertContains(Record["message"], "GitHub could not be reached", "the report carries the cause")
	AssertContains(Record["message"], "dev", "the report names the checked channel")
	AssertTrue(UpdateCheck_Perform("open_log", "", Effects)["ok"])
	AssertEqual(1, _TUCD_Effects.Logs)
	AssertFalse(UpdateCheck_Perform("run", "", Effects)["ok"], "an unknown action does nothing")
}
Test("update check: the actions act only on the answer the window holds (update-check-window)",
	_TUCD_Actions)

; A page message and a native click bypass native Suspend: a click that arrives
; while the driver is paused drives no updater action, and says so.
_TUCD_PausedClicks() {
	_TUCD_Run(_TUCD_PausedClicksCase)
}
_TUCD_PausedClicksCase() {
	global _TUCD_Effects
	Request := _TUCD_Request()
	Refusals := []
	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	Release := { Tag: "v0.0.0-dev.150", RawJson: "{}" }
	UpdateCheck_ShowResult(Request, Map("state", "available", "current", "v0.0.0-dev.144",
		"latest", Release.Tag, "others", [Map("channel", "main", "tag", "v1.0.0")], "release", Release))
	Effects := _TUCD_NewEffects()
	Effects["refuse_paused"] := () => Refusals.Push(true)
	for Name, Channel in Map("update", "", "whats_new", "", "switch_channel", "main")
		AssertFalse(UpdateCheck_Perform(Name, Channel, Effects, true)["ok"], Name . " is refused while paused")
	AssertEqual(3, Refusals.Length, "each refusal tells the user the driver is paused")
	AssertEqual(0, _TUCD_Effects.Installs.Length, "nothing installs while paused")
	AssertEqual(0, _TUCD_Effects.Changelogs.Length, "the Versions window stays closed while paused")
	AssertEqual(0, _TUCD_Effects.Switches.Length, "the channel stays while paused")
	AssertTrue(UpdateCheck_Perform("close", "", Effects, true)["closed"], "the window still closes while paused")

	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	UpdateCheck_ShowResult(Request, Map("state", "error", "current", "v0.0.0-dev.144",
		"reason", "no_connection", "detail", "GitHub could not be reached"))
	AssertTrue(UpdateCheck_Perform("report", "", Effects, true)["ok"], "a failure is still reported while paused")
	AssertTrue(UpdateCheck_Perform("open_log", "", Effects, true)["ok"], "the log still opens while paused")
	AssertEqual(3, Refusals.Length, "the error window's actions are not refused")
}
Test("update check: a click while paused drives no updater action (update-check-window)",
	_TUCD_PausedClicks)

; WebView2 can fail to start (no Evergreen runtime, a boot timeout, another
; window booting the shared environment): the window falls back to its native
; form, and the check's answer still reaches it.
_TUCD_WebViewFailure() {
	_TUCD_Run(_TUCD_WebViewFailureCase)
}
_TUCD_WebViewFailureCase() {
	global _UC_ResetDone, _UC_WindowEpoch, _UC_Native, _UC_Gui
	Request := _TUCD_Request()
	Built := []
	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	_UC_WindowEpoch += 1
	Epoch := _UC_WindowEpoch
	_UC_ResetDone := false
	Host := _UpdateCheck_NewWindow()
	_UC_Gui := Host
	try {
		AssertTrue(_UpdateCheck_FallBackToNative(Epoch, Host, () => Built.Push(true)),
			"a WebView2 failure opens the native window")
		AssertEqual(1, Built.Length, "the native window is built once")
		AssertTrue(_UC_Native, "the window is native from then on")
		AssertFalse(IsSet(_UC_Gui), "the WebView2 host is gone")
		AssertTrue(UpdateCheck_ShowResult(Request, Map("state", "up_to_date", "current", "v0.0.0-dev.144",
			"latest", "v0.0.0-dev.144", "others", [])), "the check's answer still reaches the window")
		AssertEqual("up_to_date", _TUCD_Last()["state"])

		_UC_WindowEpoch += 1
		Stale := _UC_WindowEpoch
		_UC_ResetDone := true
		Closed := _UpdateCheck_NewWindow()
		AssertFalse(_UpdateCheck_FallBackToNative(Stale, Closed, () => Built.Push(true)),
			"a window closed while WebView2 was starting stays closed")
		AssertEqual(1, Built.Length, "no native window replaces a closed one")
	} finally {
		_UC_Native := false
		_UC_ResetDone := true
		_UC_Gui := unset
	}
}
Test("update check: a WebView2 failure falls back to the native window (update-check-window)",
	_TUCD_WebViewFailure)

; The page's messages reach the actions only for the open window, as actions,
; and a paused click is refused there too; a cancelled check closes only the
; window that still shows it.
_TUCD_PageMessages() {
	_TUCD_Run(_TUCD_PageMessagesCase)
}
_TUCD_PageMessagesCase() {
	global _UC_ResetDone, _UC_WindowEpoch, _TUCD_Effects
	Request := _TUCD_Request()
	UpdateCheck_Begin(Request, "v0.0.0-dev.144")
	UpdateCheck_ShowResult(Request, Map("state", "up_to_date", "current", "v0.0.0-dev.144",
		"latest", "v0.0.0-dev.144", "others", [Map("channel", "main", "tag", "v1.0.0")]))
	Effects := _TUCD_NewEffects()
	Refusals := []
	Effects["refuse_paused"] := () => Refusals.Push(true)
	SwitchMessage := '{"action":"switch_channel","channel":"main"}'
	_UC_WindowEpoch += 1
	Epoch := _UC_WindowEpoch
	_UC_ResetDone := false
	try {
		_UpdateCheck_HandleMessage(Epoch - 1, SwitchMessage, false, Effects)
		AssertEqual(0, _TUCD_Effects.Switches.Length, "a message of a closed window does nothing")
		_UpdateCheck_HandleMessage(Epoch, "not json", false, Effects)
		_UpdateCheck_HandleMessage(Epoch, '{"action":"run"}', false, Effects)
		_UpdateCheck_HandleMessage(Epoch, '{"action":"switch_channel","channel":1}', false, Effects)
		AssertEqual(0, _TUCD_Effects.Switches.Length, "a message that is not an action does nothing")
		_UpdateCheck_HandleMessage(Epoch, SwitchMessage, true, Effects)
		AssertEqual(0, _TUCD_Effects.Switches.Length, "a message that arrived while paused switches nothing")
		AssertEqual(1, Refusals.Length, "the paused switch is refused visibly")
		_UpdateCheck_HandleMessage(Epoch, SwitchMessage, false, Effects)
		AssertEqual(1, _TUCD_Effects.Switches.Length, "the page's switch reaches the channel owner")
		AssertEqual("main", _TUCD_Effects.Switches[1])

		UpdateCheck_Abandon(_TUCD_Request())
		AssertFalse(_UC_ResetDone, "another check's cancellation leaves the window open")
		UpdateCheck_Abandon(Request)
		AssertTrue(_UC_ResetDone, "the check's cancellation closes its window")
		_UpdateCheck_HandleMessage(Epoch, SwitchMessage, false, Effects)
		AssertEqual(1, _TUCD_Effects.Switches.Length, "a closed window's message does nothing")
	} finally {
		_UC_ResetDone := true
	}
}
Test("update check: the page's messages act only for the open window (update-check-window)",
	_TUCD_PageMessages)

_TUCD_NativeTexts() {
	Label := _Updater_ChannelLabel("dev")
	Texts := _UpdateCheck_NativeTexts(Map("state", "up_to_date", "channel", "dev",
		"current", "v0.0.0-dev.144", "latest", "v0.0.0-dev.144", "others", [Map("channel", "main", "tag", "v1.0.0")]))
	AssertEqual("v0.0.0-dev.144", Texts["line1"], "up to date leads with the version")
	AssertEqual(StrReplace(t("update_check.is_latest"), "{channel}", Label), Texts["line2"])
	AssertEqual(1, Texts["others"].Length)
	AssertEqual("main", Texts["others"][1].channel)
	AssertContains(Texts["others"][1].text, "v1.0.0")
	AssertEqual(0, InStr(Texts["others"][1].text, "{"), "no placeholder is left in a line")
	Checking := _UpdateCheck_NativeTexts(Map("state", "checking", "channel", "dev", "current", "", "others", []))
	AssertEqual(StrReplace(t("update_check.checking"), "{channel}", Label), Checking["line1"])
	Failure := _UpdateCheck_NativeTexts(Map("state", "error", "channel", "dev", "current", "v0.0.0-dev.144",
		"latest", "", "others", [], "reason_key", "updater.no_connection", "log_path", "C:\logs\today.log"))
	AssertEqual(t("update_check.error_heading"), Failure["line1"])
	AssertEqual(t("updater.no_connection"), Failure["line2"])
	AssertContains(Failure["logged"], "C:\logs\today.log")
	AssertEqual(0, Failure["others"].Length, "a failure lists no other channel")
	Window := _UpdateCheck_NewWindow()
	try AssertEqual("ErgoptiPlus — " . t("update_check.window_title"), Window.Title, "one product prefix")
	finally Window.Destroy()
}
Test("update check: the native window reads like the page (update-check-window)", _TUCD_NativeTexts)

_TUCD_OtherChannelsOnManualChecks() {
	_TUCD_Run(_TUCD_OtherChannelsCase)
}
_TUCD_OtherChannelsCase() {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND
	List := '[{"tag_name":"v1.0.0","published_at":"2026-09-03T00:00:00Z","prerelease":false},'
		. '{"tag_name":"v0.0.0-dev.150","published_at":"2026-09-02T00:00:00Z","prerelease":true}]'
	Manual := _TUCD_Request()
	Json := _Updater_InterpretResponse(200, List, "", "dev", "https://example.invalid/releases", Manual)
	AssertEqual("v0.0.0-dev.150", Updater_ParseTagName(Json), "the checked channel's release is selected")
	Others := _Updater_RequestOtherChannels(Manual)
	AssertEqual(1, Others.Length, "the newer stable release is kept for the window")
	AssertEqual("main", Others[1]["channel"])
	AssertEqual("v1.0.0", Others[1]["tag"])
	Background := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false, "dev")
	_Updater_InterpretResponse(200, List, "", "dev", "https://example.invalid/releases", Background)
	AssertFalse(Background.HasProp("OtherChannels"), "a background check keeps nothing for a window")
	AssertEqual(0, _Updater_RequestOtherChannels(Background).Length)
}
Test("update check: a manual check keeps the other channels with a newer release (update-check-window)",
	_TUCD_OtherChannelsOnManualChecks)
