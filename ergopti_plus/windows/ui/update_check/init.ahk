; ui/update_check/init.ahk

; ==============================================================================
; MODULE: Update Check Window
; DESCRIPTION:
; Hosts the shared update-check page (_shared/ui/update_check/) for the tray's
; "Check for updates" row: "checking" for the subscribed channel, then the
; answer (up to date, a release to install, no release on the channel yet, or
; why the check failed), with one line for every other channel whose latest
; release was published after the installed build.
;
; FEATURES & RATIONALE:
; 1. The manual check used to answer with tray balloons, and to start the
;    install prompt on a newer release; the window now carries every answer,
;    centered, and nothing downloads before its Update button.
; 2. Update runs the existing install of the offered release
;    (_Updater_ActivateCachedRelease, then Updater_DownloadAndInstall); a
;    switch goes through the channel owner (Updater_SetChannel), What's new
;    opens the Versions window, and a failure's Report reuses the error
;    window's GitHub report.
; 3. One window, bound to the manual check it shows and to an epoch: a late
;    answer of another check, or a message of a closed window, is inert.
; 4. Without WebView2, or when its WebView cannot be created, the same answer
;    is a native, centered window with the same texts and buttons.
; ==============================================================================

#Requires AutoHotkey v2.0

; The window's size: the manifest's update_check entry
; (_shared/ui/apps.manifest.json), pinned by test-webview-geometry-single-source.
global UC_WIDTH  := 480
global UC_HEIGHT := 320

; Virtual host for the shared page, mapped to _SharedDir like the error window's
global UC_VHOST             := "ergopti.updatecheck"
global UC_HOST_ACCESS_ALLOW := 1

; The page's actions, each with the phase it needs ("" = any phase)
global UC_PAGE_ACTIONS := Map("close", "", "update", "available", "whats_new", "available",
	"switch_channel", "", "report", "error", "open_log", "error")

; The actions that drive the updater, refused while the driver is paused; the
; others (close, report, open the log) change nothing ErgoptiPlus does, as in
; the error window
global UC_UPDATER_ACTIONS := Map("update", true, "whats_new", true, "switch_channel", true)

; The phases an answer may carry, as the page knows them
global UC_ANSWER_STATES := Map("up_to_date", true, "available", true, "no_release", true, "error", true)

; The reasons a failed check may give, as locale keys the page translates
global UC_REASONS := Map(
	"no_connection", "updater.no_connection",
	"parse_failed",  "updater.parse_failed",
	"unexpected",    "update_check.error_unexpected")

; Replaces the window for the tests: called with the state instead of showing it
global _UC_PresentFn := 0

; The manual check the window shows (its request id), its state (the page's
; state message as a Map) and the release an "available" answer offers
global _UC_RequestId := 0
global _UC_State     := 0
global _UC_Release   := 0

; The open window: host Gui, WebView2 or the native fallback
global _UC_Gui         := unset
global _UC_Controller  := unset
global _UC_WebView     := unset
global _UC_MsgSub      := unset
global _UC_Native      := false
global _UC_WindowEpoch := 0
global _UC_ResetDone   := true





; =============================
; =============================
; ======= 1/ Public API =======
; =============================
; =============================

; Opens the window, or reuses the open one, showing "checking" for the channel
; of one manual check.
; @param Request {Object} The manual check's request context.
; @param Current {String} The installed version.
; @returns {Boolean} shown
UpdateCheck_Begin(Request, Current) {
	ManagedNetworkTerminalFailure.Retire("updater_check")
	global _UC_RequestId, _UC_Release
	_UC_RequestId := Request.RequestId
	_UC_Release := 0
	return _UpdateCheck_Present(Map("state", "checking", "channel", Request.Channel,
		"current", Current, "latest", "", "others", []), true)
}

; Shows the answer of one manual check. The answer of another check (superseded
; by a later click, or of a window closed meanwhile) is ignored.
; @param Request {Object} The manual check's request context.
; @param Answer {Map} { state, current, latest?, others?, reason?, detail?, release? }:
;   reason names a UC_REASONS entry for an error; release is the offered release
;   object for "available".
; @returns {Boolean} shown
UpdateCheck_ShowResult(Request, Answer) {
	global _UC_RequestId, _UC_Release, UC_ANSWER_STATES, UC_REASONS
	if (Request.RequestId != _UC_RequestId) {
		LoggerDebug("UpdateCheck", "Discarded the answer of a superseded update check.")
		return false
	}
	Phase := Answer.Get("state", "")
	if !UC_ANSWER_STATES.Has(Phase)
		throw ValueError("Unknown update-check answer: " . Phase)
	State := Map("state", Phase, "channel", Request.Channel,
		"current", Answer.Get("current", ""), "latest", Answer.Get("latest", ""),
		"others", Answer.Get("others", []))
	if (Phase == "error") {
		Reason := Answer.Get("reason", "")
		if !UC_REASONS.Has(Reason)
			throw ValueError("Unknown update-check failure reason: " . Reason)
		NetworkKey := ManagedNetworkFailureWindows_MessageKey(Answer.Get("network_report", 0))
		State["reason_key"] := NetworkKey != "" ? NetworkKey : UC_REASONS[Reason]
		State["detail"] := NetworkKey != "" ? "" : Answer.Get("detail", "")
		State["log_path"] := LoggerTodayLogPath()
	}
	_UC_Release := (Phase == "available") ? Answer["release"] : 0
	LoggerInfo("UpdateCheck", "Update check window: {1} (channel {2}).", Phase, Request.Channel)
	Accepted := _UpdateCheck_Present(State)
	if Accepted && Phase == "error" && ManagedNetworkFailureWindows_CanonicalReport(Answer.Get("network_report", 0))
		_UpdateCheck_ShowManagedFailure(Request, State, Answer["network_report"])
	else
		ManagedNetworkTerminalFailure.Retire("updater_check")
	return Accepted
}

; Offers a release a manual check found: the window shows it with its Update
; button, the only consent that downloads it.
; @param Release {Object} The published release (Tag, RawJson…).
; @param Request {Object} The manual check's request context.
; @returns {Boolean} shown
UpdateCheck_ShowAvailable(Release, Request) {
	return UpdateCheck_ShowResult(Request, Map("state", "available",
		"current", Updater_CurrentVersion(), "latest", Release.Tag,
		"others", _Updater_RequestOtherChannels(Request), "release", Release))
}

; Closes the window when it still shows a check that ended without an answer
; (cancelled at a suspend boundary or by a channel switch).
; @param Request {Object}
UpdateCheck_Abandon(Request) {
	global _UC_RequestId, _UC_ResetDone
	if (Request.RequestId != _UC_RequestId) || _UC_ResetDone
		return
	LoggerInfo("UpdateCheck", "The update check was cancelled; its window closes.")
	_UpdateCheck_CloseWindow()
}





; ==================================
; ==================================
; ======= 2/ The Page's Data =======
; ==================================
; ==================================

; The page's state message.
; @param State {Map} The window's state.
; @returns {String} JSON
_UpdateCheck_StateJson(State) {
	Others := ""
	for Entry in State.Get("others", []) {
		Others .= (Others == "" ? "" : ",") . '{"channel":' . JsonStringLiteral(Entry["channel"])
			. ',"tag":' . JsonStringLiteral(Entry["tag"]) . '}'
	}
	Json := '{"type":"state","state":' . JsonStringLiteral(State["state"])
		. ',"channel":' . JsonStringLiteral(State["channel"])
		. ',"current":' . JsonStringLiteral(State.Get("current", ""))
		. ',"latest":' . JsonStringLiteral(State.Get("latest", ""))
		. ',"others":[' . Others . ']'
	if (State["state"] == "error") {
		Json .= ',"reason_key":' . JsonStringLiteral(State["reason_key"])
			. ',"log_path":' . JsonStringLiteral(State["log_path"])
	}
	return Json . '}'
}

; A translation with its named placeholders filled, as the page composes it.
; @param Key {String}
; @param Values {Map} placeholder name -> value
; @returns {String}
_UpdateCheck_Text(Key, Values := 0) {
	Text := t(Key)
	if (Values is Map) {
		for Name, Value in Values
			Text := StrReplace(Text, "{" . Name . "}", Value)
	}
	return Text
}

; The texts of the native window, composed like the page's: two lines, today's
; log for a failure, one line per other channel.
; @param State {Map}
; @returns {Map} { line1, line2, logged, others: Array of { text, channel } }
_UpdateCheck_NativeTexts(State) {
	Phase := State["state"]
	Channel := _Updater_ChannelLabel(State["channel"])
	Line1 := "", Line2 := "", Logged := ""
	switch Phase {
		case "checking":
			Line1 := _UpdateCheck_Text("update_check.checking", Map("channel", Channel))
		case "up_to_date":
			Line1 := State["current"]
			Line2 := _UpdateCheck_Text("update_check.is_latest", Map("channel", Channel))
		case "available":
			Line1 := State["latest"]
			Line2 := _UpdateCheck_Text("update_check.available",
				Map("current", State["current"], "channel", Channel))
		case "no_release":
			Line1 := State["current"]
			Line2 := _UpdateCheck_Text("updater.no_release_on_channel", Map("channel", Channel))
		case "error":
			Line1 := t("update_check.error_heading")
			Line2 := _UpdateCheck_Text(State["reason_key"], Map("channel", Channel,
				"tag", State.Get("latest", ""), "current", State.Get("current", "")))
			Logged := _UpdateCheck_Text("update_check.logged_in", Map("path", State["log_path"]))
	}
	Others := []
	if (Phase == "up_to_date" or Phase == "available" or Phase == "no_release") {
		for Entry in State.Get("others", []) {
			Others.Push({ text: _UpdateCheck_Text("update_check.also_available",
				Map("channel", _Updater_ChannelLabel(Entry["channel"]), "tag", Entry["tag"])),
				channel: Entry["channel"] })
		}
	}
	return Map("line1", Line1, "line2", Line2, "logged", Logged, "others", Others)
}





; ==============================
; ==============================
; ======= 3/ The Actions =======
; ==============================
; ==============================

; Performs one action of the window, on the answer it holds.
; @param Name {String} One of UC_PAGE_ACTIONS.
; @param Channel {String} The channel of a switch line.
; @param Effects {Map|Integer} Replacements of the effects (tests only): install,
;   changelog, set_channel, report, open_log, close, refuse_paused.
; @param BornSuspended {Boolean} Whether the driver was paused when the click
;   arrived: an updater action is then refused visibly.
; @returns {Map} { ok, missing, closed }
UpdateCheck_Perform(Name, Channel := "", Effects := 0, BornSuspended := false) {
	global _UC_State, _UC_Release, UC_PAGE_ACTIONS, UC_UPDATER_ACTIONS
	Outcome := Map("ok", false, "missing", false, "closed", false)
	if !UC_PAGE_ACTIONS.Has(Name) || !(_UC_State is Map)
		return Outcome
	Needs := UC_PAGE_ACTIONS[Name]
	if (Needs != "" and _UC_State["state"] != Needs) {
		LoggerWarn("UpdateCheck", "Refused the update-check action '{1}' outside the '{2}' phase.", Name, Needs)
		return Outcome
	}
	Effect(Key, Default) => (Effects is Map && Effects.Has(Key)) ? Effects[Key] : Default
	if (BornSuspended && UC_UPDATER_ACTIONS.Has(Name)) {
		Effect("refuse_paused", _Updater_RefuseManualWhileSuspended).Call()
		return Outcome
	}
	switch Name {
		case "close":
			Effect("close", _UpdateCheck_CloseWindow).Call()
			Outcome["ok"] := true, Outcome["closed"] := true
		case "update":
			if Effect("install", _UpdateCheck_Install).Call(_UC_Release) {
				Effect("close", _UpdateCheck_CloseWindow).Call()
				Outcome["ok"] := true, Outcome["closed"] := true
			}
		case "whats_new":
			Effect("changelog", Changelog_Open).Call(_UC_State["channel"])
			Outcome["ok"] := true
		case "switch_channel":
			if !_UpdateCheck_Lists(Channel) {
				LoggerWarn("UpdateCheck", "Refused a switch to '{1}': the answer did not list it.", Channel)
			} else if Effect("set_channel", Updater_SetChannel).Call(Channel) {
				; The channel owner reloads the application on the new channel
				Effect("close", _UpdateCheck_CloseWindow).Call()
				Outcome["ok"] := true, Outcome["closed"] := true
			}
		case "report":
			Outcome["ok"] := Effect("report", ErrorDialog_Report).Call(Map("kind", "error",
				"module", "Updater",
				"message", "Update check failed on channel " . _UC_State["channel"] . ": " . _UC_State["detail"],
				"time", FormatTime(, "yyyy-MM-dd HH:mm:ss"))) ? true : false
		case "open_log":
			Outcome["ok"] := Effect("open_log", LogOpeners_OpenTodayLog).Call() ? true : false
	}
	return Outcome
}

; Whether the answer lists a channel as having a newer release.
; @param Channel {String}
; @returns {Boolean}
_UpdateCheck_Lists(Channel) {
	global _UC_State
	for Entry in _UC_State.Get("others", []) {
		if (Entry["channel"] == Channel)
			return true
	}
	return false
}

; Installs the offered release: the user's click is the consent the tray's
; "Update to vX" row also gives.
; @param Release {Object}
; @returns {Boolean} started
_UpdateCheck_Install(Release) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if (Type(Release) != "Object") {
		LoggerError("UpdateCheck", "Update refused: the window holds no offered release.")
		return false
	}
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	return _Updater_ActivateCachedRelease(Release, Request) == true
}





; ==============================
; ==============================
; ======= 4/ The Window ========
; ==============================
; ==============================

; Keeps native title construction independently testable. An ordinary window:
; it is raised and focused when it opens or a new check re-opens it, never kept
; above other applications.
_UpdateCheck_NewWindow() {
	return Gui_Create("", t("update_check.window_title"))
}

; Shows a state in the open window, or opens the window.
; @param State {Map}
; @param Reopen {Boolean} A new manual check: an open window is presented again.
; @returns {Boolean} shown
_UpdateCheck_Present(State, Reopen := false) {
	global _UC_State, _UC_ResetDone, _UC_Native, _UC_WindowEpoch, _UC_PresentFn, _UC_Gui
	_UC_State := State
	if HasMethod(_UC_PresentFn, "Call")
		return _UC_PresentFn.Call(State) ? true : false
	if !_UC_ResetDone {
		if _UC_Native
			_UpdateCheck_BuildNative()
		else
			_UpdateCheck_Send(_UC_WindowEpoch, _UpdateCheck_StateJson(State))
		; A result updates the window where it is; only the user's new click
		; brings a covered window back.
		if Reopen && IsSet(_UC_Gui) && IsObject(_UC_Gui)
			WMPresentWindow(_UC_Gui)
		return true
	}
	return _UpdateCheck_Open()
}

; Opens the window: the shared page in WebView2, or its native counterpart.
; @returns {Boolean} opened
_UpdateCheck_Open() {
	global _VendorDir, _SharedDir, _I18nLocale, UC_WIDTH, UC_HEIGHT, UC_VHOST, UC_HOST_ACCESS_ALLOW
	global _UC_Gui, _UC_Controller, _UC_WebView, _UC_MsgSub, _UC_ResetDone, _UC_WindowEpoch, _UC_Native
	LoggerStart("UpdateCheck", "Opening the update-check window…")
	_UC_WindowEpoch += 1
	Epoch := _UC_WindowEpoch
	UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
		&& !WebView_ShouldUseNativeFallback()
	if !UseWV {
		_UC_Native := true
		_UC_ResetDone := false
		_UpdateCheck_BuildNative()
		LoggerSuccess("UpdateCheck", "Update-check window opened (native, without WebView2).")
		return true
	}
	_UC_Native := false
	G := _UpdateCheck_NewWindow()
	G.MarginX := 0
	G.MarginY := 0
	ContentCtl := G.Add("Text", "x0 y0 w" . UC_WIDTH . " h" . UC_HEIGHT, "")
	G.WVC := 0
	G.OnEvent("Close",  (*) => _UpdateCheck_CloseWindow())
	G.OnEvent("Escape", (*) => _UpdateCheck_CloseWindow())
	; No position: Gui.Show centers the window on the screen
	G.Show("w" . UC_WIDTH . " h" . UC_HEIGHT)
	_UC_Gui := G
	_UC_ResetDone := false
	try {
		WVC := WebView2.create(ContentCtl.Hwnd, , WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll"))
		G.WVC := WVC
	} catch as Err {
		LoggerError("UpdateCheck", "WebView2 could not be created for the update-check window: {1}", Err.Message)
		return _UpdateCheck_FallBackToNative(Epoch, G)
	}
	_UC_Controller := WVC
	_UC_WebView := WVC.CoreWebView2
	try {
		s := _UC_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
	}
	Locale := IsSet(_I18nLocale) ? _I18nLocale : "en"
	try _UC_WebView.AddScriptToExecuteOnDocumentCreated(
		"window.__i18n_base='https://" . UC_VHOST . "/data/locales/';window._i18n_locale='" . Locale . "';")
	_UC_MsgSub := _UC_WebView.WebMessageReceived(_UpdateCheck_OnWebMessage.Bind(Epoch))
	try _UC_WebView.SetVirtualHostNameToFolderMapping(UC_VHOST, _SharedDir, UC_HOST_ACCESS_ALLOW)
	try _UC_WebView.Navigate("https://" . UC_VHOST . "/ui/update_check/index.html?cb=" . A_TickCount)
	try _UC_Controller.Fill()
	LoggerSuccess("UpdateCheck", "Update-check window opened.")
	return true
}

; Replaces a WebView2 host whose WebView could not be created (no Evergreen
; runtime, a boot timeout, another window still booting the shared environment)
; with the native window. The check and its state stay: the check's answer
; arrives later, and only a window still showing that check receives it.
; @param Epoch {Integer} The epoch of the window being opened.
; @param HostGui {Gui} The WebView2 host, which holds no WebView.
; @param BuildFn {Func|Integer} Replacement of _UpdateCheck_BuildNative (tests only).
; @returns {Boolean} opened
_UpdateCheck_FallBackToNative(Epoch, HostGui, BuildFn := 0) {
	global _UC_Gui, _UC_ResetDone, _UC_WindowEpoch, _UC_Native
	try HostGui.Destroy()
	; The environment's boot pumps messages: a window the user closed meanwhile
	; stays closed, and a window opened since then is not replaced
	if _UC_ResetDone || (Epoch != _UC_WindowEpoch) {
		LoggerDone("UpdateCheck", "The update-check window was closed while WebView2 was starting.")
		return false
	}
	_UC_Gui := unset
	_UC_Native := true
	Build := HasMethod(BuildFn, "Call") ? BuildFn : _UpdateCheck_BuildNative
	Build.Call()
	LoggerSuccess("UpdateCheck", "Update-check window opened (native, WebView2 could not be created).")
	return true
}

; Builds (or rebuilds) the native window for the current state: every text and
; button centered, like the page.
_UpdateCheck_BuildNative() {
	global _UC_Gui, _UC_State, UC_WIDTH
	Previous := IsSet(_UC_Gui) ? _UC_Gui : 0
	Texts := _UpdateCheck_NativeTexts(_UC_State)
	Phase := _UC_State["state"]
	Width := UC_WIDTH - 40
	G := _UpdateCheck_NewWindow()
	G.MarginX := 20
	G.MarginY := 16
	G.SetFont("s12 bold", "Segoe UI")
	G.Add("Text", "xm w" . Width . " Center", Texts["line1"])
	G.SetFont("s10 norm", "Segoe UI")
	if (Texts["line2"] != "")
		G.Add("Text", "xm y+6 w" . Width . " Center", Texts["line2"])
	if (Texts["logged"] != "")
		G.Add("Text", "xm y+8 w" . Width . " Center cGray", Texts["logged"])
	for Other in Texts["others"] {
		G.Add("Text", "xm y+10 w" . Width . " Center", Other.text)
		SwitchButton := G.Add("Button", "xm y+4", t("update_check.switch_channel"))
		SwitchButton.OnEvent("Click", _UpdateCheck_NativeClick.Bind("switch_channel", Other.channel))
		_UpdateCheck_CenterRow([SwitchButton])
	}
	G.Add("Text", "xm y+10 w" . Width . " Center vStatus", "")
	Row := []
	if (Phase == "available") {
		WhatsNew := G.Add("Button", "xm y+8", t("update_check.whats_new"))
		WhatsNew.OnEvent("Click", _UpdateCheck_NativeClick.Bind("whats_new", ""))
		_UpdateCheck_CenterRow([WhatsNew])
	}
	if (Phase == "error") {
		Row.Push(G.Add("Button", "xm y+12", t("healthcheck.toolbar.report")))
		Row[Row.Length].OnEvent("Click", _UpdateCheck_NativeClick.Bind("report", ""))
		Row.Push(G.Add("Button", "x+8 yp", t("update_check.open_log")))
		Row[Row.Length].OnEvent("Click", _UpdateCheck_NativeClick.Bind("open_log", ""))
	}
	Row.Push(G.Add("Button", (Row.Length ? "x+8 yp" : "xm y+12"), t("common.close")))
	Row[Row.Length].OnEvent("Click", _UpdateCheck_NativeClick.Bind("close", ""))
	if (Phase == "available") {
		Row.Push(G.Add("Button", "x+8 yp Default", t("update_check.update")))
		Row[Row.Length].OnEvent("Click", _UpdateCheck_NativeClick.Bind("update", ""))
	}
	_UpdateCheck_CenterRow(Row)
	G.OnEvent("Close",  (*) => _UpdateCheck_CloseWindow())
	G.OnEvent("Escape", (*) => _UpdateCheck_CloseWindow())
	; No position: Gui.Show centers the window on the screen; the texts span
	; UC_WIDTH with the margins, so the window keeps the manifest's width
	G.Show("AutoSize")
	_UC_Gui := G
	if Previous {
		try Previous.Destroy()
	}
}

; Gives a row of buttons one width and centers it in the window.
; @param Buttons {Array}
_UpdateCheck_CenterRow(Buttons) {
	global UC_WIDTH
	if (Buttons.Length == 0)
		return
	Shared := Gui_HarmoniseButtonWidths(Buttons)
	Gap := 8
	Total := Buttons.Length * Shared + (Buttons.Length - 1) * Gap
	X := Max(0, (UC_WIDTH - Total) // 2)
	for Button in Buttons {
		Button.Move(X)
		X += Shared + Gap
	}
}

; A click in the native window, on its own stack like a page message. A Gui
; event bypasses native Suspend: whether the driver was paused is read here.
_UpdateCheck_NativeClick(Name, Channel, *) {
	global _UC_WindowEpoch
	SetTimer(_UpdateCheck_Act.Bind(_UC_WindowEpoch, Name, Channel, A_IsSuspended), -1)
}

; Closes the window: the controller first, while its host window lives, then
; the window.
_UpdateCheck_CloseWindow() {
	ManagedNetworkTerminalFailure.Retire("updater_check")
	global _UC_Gui, _UC_Controller, _UC_WebView, _UC_MsgSub, _UC_ResetDone, _UC_WindowEpoch, _UC_State
	global _UC_Release, _UC_RequestId, _UC_Native
	SavedGui := IsSet(_UC_Gui) ? _UC_Gui : 0
	if !_UC_Native && IsSet(_UC_Controller) {
		_UC_MsgSub := unset
		try _UC_Controller.Close()
	}
	_UC_Controller := unset
	_UC_WebView := unset
	_UC_ResetDone := true
	_UC_Native := false
	_UC_WindowEpoch += 1
	_UC_State := 0
	_UC_Release := 0
	_UC_RequestId := 0
	try {
		if SavedGui
			SavedGui.Destroy()
	}
	_UC_Gui := unset
	LoggerInfo("UpdateCheck", "Update-check window closed.")
}

; Sends one message into the window's page.
; @param Epoch {Integer}
; @param Json {String}
_UpdateCheck_Send(Epoch, Json) {
	global _UC_WebView, _UC_WindowEpoch, _UC_ResetDone, _UC_Native
	if _UC_ResetDone || _UC_Native || (Epoch != _UC_WindowEpoch) || !IsSet(_UC_WebView)
		return
	WebView_RunScriptAsync(_UC_WebView, "if(window.receiveUpdateCheck)window.receiveUpdateCheck(" . Json . ")",
		"UpdateCheck")
}

; Receives the page's messages. WebMessageReceived is a COM callback: the
; message is read here and handled on a fresh stack, bound to its window.
_UpdateCheck_OnWebMessage(Epoch, Handler, Args) {
	global _UC_WindowEpoch, _UC_ResetDone
	if _UC_ResetDone || (Epoch != _UC_WindowEpoch)
		return
	; The callback bypasses native Suspend: whether the driver was paused is read
	; before the COM read can pump messages. The page still loads and closes
	; while paused; its updater actions are refused (UpdateCheck_Perform)
	BornSuspended := A_IsSuspended
	try Raw := Args.TryGetWebMessageAsString()
	catch as Err {
		LoggerWarn("UpdateCheck", "An update-check message could not be read: {1}.", Err.Message)
		return
	}
	SetTimer(_UpdateCheck_HandleMessage.Bind(Epoch, Raw, BornSuspended), -1)
}

; Handles one message of the page, on its own stack.
; @param Epoch {Integer}
; @param Raw {String}
; @param BornSuspended {Boolean} Whether the driver was paused when it arrived.
; @param Effects {Map|Integer} Replacements of the effects (tests only).
_UpdateCheck_HandleMessage(Epoch, Raw, BornSuspended := false, Effects := 0) {
	global _UC_WindowEpoch, _UC_ResetDone, _UC_State, UC_PAGE_ACTIONS
	if _UC_ResetDone || (Epoch != _UC_WindowEpoch) || !(_UC_State is Map)
		return
	if (Raw == "ready") {
		_UpdateCheck_Send(Epoch, _UpdateCheck_StateJson(_UC_State))
		return
	}
	Name := "", Channel := ""
	try {
		Message := JsonParse(Raw)
		if (Message is Map) {
			Name := Message.Get("action", "")
			Channel := Message.Get("channel", "")
		}
	}
	if !(Name is String) || !UC_PAGE_ACTIONS.Has(Name) || !(Channel is String) {
		LoggerWarn("UpdateCheck", "Refused an update-check message that is not one of its actions.")
		return
	}
	_UpdateCheck_Act(Epoch, Name, Channel, BornSuspended, Effects)
}

; Performs one action and answers it, in the page or the native window.
; @param Epoch {Integer}
; @param Name {String}
; @param Channel {String}
; @param BornSuspended {Boolean} Whether the driver was paused at the click.
; @param Effects {Map|Integer} Replacements of the effects (tests only).
_UpdateCheck_Act(Epoch, Name, Channel, BornSuspended := false, Effects := 0) {
	global _UC_WindowEpoch, _UC_ResetDone, _UC_Native, _UC_Gui
	if _UC_ResetDone || (Epoch != _UC_WindowEpoch)
		return
	LoggerInfo("UpdateCheck", "Update-check window action: {1}.", Name)
	try Outcome := UpdateCheck_Perform(Name, Channel, Effects, BornSuspended)
	catch as Err {
		LoggerError("UpdateCheck", "The update-check action '{1}' failed: {2}", Name, Err.Message)
		Outcome := Map("ok", false, "missing", false, "closed", false)
	}
	if Outcome["closed"] || _UC_ResetDone || (Epoch != _UC_WindowEpoch)
		return
	if _UC_Native {
		Status := ""
		if !Outcome["ok"]
			Status := t("healthcheck.status.failed")
		else if (Name == "report")
			Status := t("notify.report_bug_body")
		try _UC_Gui["Status"].Text := Status
		return
	}
	_UpdateCheck_Send(Epoch, '{"type":"action","action":' . JsonStringLiteral(Name)
		. ',"ok":' . (Outcome["ok"] ? "true" : "false")
		. ',"missing":' . (Outcome["missing"] ? "true" : "false") . '}')
}

_UpdateCheck_ManagedCurrent(Owner) {
	global _UC_ResetDone, _UC_WindowEpoch, _UC_RequestId, _UC_State, UPDATER_REQUEST_POLICY_ALLOW
	return !_UC_ResetDone && _UC_WindowEpoch == Owner.epoch && _UC_RequestId == Owner.request.RequestId
		&& _UC_State == Owner.state && _UC_State is Map && _UC_State.Get("state", "") == "error"
		&& _Updater_RequestPolicy(Owner.request) == UPDATER_REQUEST_POLICY_ALLOW
}

_UpdateCheck_ShowManagedFailure(Request, State, Report, PresentFn := 0) {
	global _UC_WindowEpoch
	Owner := {request: Request, state: State, epoch: _UC_WindowEpoch}
	return ManagedNetworkTerminalFailure.Publish("updater_check", Report, () => _UpdateCheck_ManagedCurrent(Owner),
		"update_check.window_title", () => _UpdateCheck_RetryManaged(Owner), PresentFn)
}

_UpdateCheck_RetryManaged(Owner) {
	if !_UpdateCheck_ManagedCurrent(Owner)
		return false
	global _UC_RequestId, _UC_ResetDone
	BeforeRequest := _UC_RequestId
	Updater_OneClickUpdate()
	return !_UC_ResetDone && _UC_RequestId != BeforeRequest
}
