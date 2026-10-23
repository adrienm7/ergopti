; ui/error_dialog/init.ahk

; ==============================================================================
; MODULE: Error Window
; DESCRIPTION:
; Opens the shared error window (_shared/ui/error_dialog/) when a logged ERROR
; passes the shared policy (_shared/modules/diagnostics/error_policy.json):
; what went wrong, where it is logged, and the buttons to report it on GitHub,
; copy the report, open the errors file or close the window. Uncaught errors
; reach it too, through the ERROR the global error handler logs.
;
; FEATURES & RATIONALE:
; 1. The logger calls ErrorDialog_OnError synchronously for every emitted
;    ERROR, often from inside the keyboard hook. It only decides and arms a
;    one-shot timer: no logging (the logger is mid-line), no window, no I/O.
;    The window opens present_delay_ms later, once the driver is ready.
; 2. ErrorPolicy_Decide rules: one window per error signature per session, at
;    most max_dialogs per window_sec, errors logged while a window is open are
;    counted in it, nothing while the Debug menu's "Show a window for every
;    error" is unticked. It replaces the tray toast of the global error handler.
; 3. The window never takes the keyboard (Show NoActivate): it can appear while
;    the user is typing, and a stolen focus would swallow the next keys.
; 4. The report is ErrorReport_Compose's, built from the diagnostics snapshot
;    and redacted before the page sees it; copy, report and open go through the
;    diagnostics window's own actions (HealthCheck_PerformAction), which redact
;    again before anything leaves the machine.
; 5. One window at a time, bound to an epoch: a late message of a closed window
;    is inert. Without WebView2 the error is announced by a notification.
; ==============================================================================

#Requires AutoHotkey v2.0

; The window's size: the manifest's error_dialog entry
; (_shared/ui/apps.manifest.json), pinned by test-webview-geometry-single-source.
global ED_WIDTH  := 560
global ED_HEIGHT := 460

; Virtual host for the shared page, mapped to _SharedDir like the diagnostics one
global ED_VHOST             := "ergopti.errordialog"
global ED_HOST_ACCESS_ALLOW := 1

; The Debug menu setting, as the features manifest declares it
global ED_SETTING_SECTION := "script"
global ED_SETTING_KEY     := "show_error_dialog"

; How often a window decided during boot checks again whether the driver is ready
global ED_BOOT_RETRY_MS := 500

; Arms the one-shot timers of ErrorDialog_OnError; a test captures them instead
global _ED_TimerFn := SetTimer

; The page's actions
global ED_PAGE_ACTIONS := Map("report", true, "copy", true, "open_log", true, "close", true)

; The validated policy and the session's decisions; 0 until ErrorDialog_Init
global _ED_Policy    := 0
global _ED_Decisions := 0

; Whether the window may open, as the Debug menu shows it
global _ED_Enabled := false

; True from the moment a window is decided until it closes (or fails to open):
; the policy folds every error logged in between into it
global _ED_Busy := false

; Identity of the deferred request; disabling invalidates it before native work.
global _ED_PendingRecord := 0

; Errors folded into the pending or open window
global _ED_Folded := 0

; The open window: its session (error, report, paths), host Gui and WebView2
global _ED_Session     := 0
global _ED_Gui         := unset
global _ED_Controller  := unset
global _ED_WebView     := unset
global _ED_MsgSub      := unset
global _ED_WindowEpoch := 0
global _ED_ResetDone   := true





; =================================
; =================================
; ======= 1/ Initialisation =======
; =================================
; =================================

; Loads the policy and the Debug menu setting. Called once at boot, right
; after the logger, so the errors of the rest of the boot are surfaced too.
; @param Cache {Map} The parsed config.toml.
; @returns {Boolean} False when the window cannot work (logged).
ErrorDialog_Init(Cache) {
	global _ED_Policy, _ED_Decisions, _ED_Enabled, _SharedDir
	if (_ED_Policy is Map) {
		LoggerError("ErrorDialog", "The error window was initialised twice; the second call is refused.")
		return false
	}
	LoggerStart("ErrorDialog", "Initialising the error window…")
	try {
		Policy := ErrorPolicy_Validate(JsonParse(FileRead(_SharedDir . "\modules\diagnostics\error_policy.json", "UTF-8")))
		Enabled := _ErrorDialog_ReadSetting(Cache)
	} catch as Err {
		LoggerError("ErrorDialog", "The error window cannot start: {1}", Err.Message)
		return false
	}
	_ED_Policy := Policy
	_ED_Decisions := ErrorPolicy_NewState()
	_ED_Enabled := Enabled
	LoggerSuccess("ErrorDialog", "Error window ready ({1}).", Enabled ? "enabled" : "disabled")
	return true
}

; The setting in config.toml, or its manifest default.
; @param Cache {Map}
; @returns {Boolean}
; @throws {ValueError} When config.toml holds something else than a boolean,
;   or the manifest declares no boolean default.
_ErrorDialog_ReadSetting(Cache) {
	global ED_SETTING_SECTION, ED_SETTING_KEY
	Path := ED_SETTING_SECTION . "." . ED_SETTING_KEY
	Raw := IniCacheGet(Cache, ED_SETTING_SECTION, ED_SETTING_KEY)
	if (Raw == "_") {
		Entry := ManifestFindEntryByPath(Path)
		if !(Entry is Map) || !Entry.Has("default")
			throw ValueError("The features manifest declares no default for " . Path . ".")
		Raw := Entry["default"]
	}
	if !(Raw is Integer) || (Raw != 0 && Raw != 1)
		throw ValueError(Path . " must be a boolean.")
	return Raw == 1
}

; Whether the Debug menu's "Show a window for every error" is ticked.
; @returns {Boolean}
ErrorDialog_IsEnabled() {
	global _ED_Enabled
	return _ED_Enabled
}

; Ticks or unticks "Show a window for every error": config.toml first, then
; the live flag, then the menu.
; @param Enabled {Boolean}
; @returns {Boolean} False when config.toml refused it (the flag is unchanged).
ErrorDialog_SetEnabled(Enabled, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	global ConfigurationFile, ED_SETTING_SECTION, ED_SETTING_KEY
	Enabled := Enabled ? true : false
	Updates := [{ Section: ED_SETTING_SECTION, Key: ED_SETTING_KEY, Value: Enabled }]
	if !ConfigCommitUpdates(ConfigurationFile, Updates, "the error window setting", WriterFn, NotifyFn,
			_ErrorDialog_PublishEnabled.Bind(Enabled)) {
		LoggerError("ErrorDialog", "The error window setting could not be saved; it is unchanged.")
		return false
	}
	LoggerDebug("ErrorDialog", "Error window {1}.", Enabled ? "enabled" : "disabled")
	if HasMethod(RebuildFn, "Call")
		RebuildFn.Call()
	else
		RebuildTrayMenu()
	return true
}

_ErrorDialog_PublishEnabled(Enabled) {
	global _ED_Enabled, _ED_PendingRecord, _ED_Busy, _ED_Folded
	_ED_Enabled := Enabled
	if !Enabled && (_ED_PendingRecord is Map) {
		_ED_PendingRecord := 0
		_ED_Busy := false
		_ED_Folded := 0
	}
}





; ================================
; ================================
; ======= 2/ Logged Errors =======
; ================================
; ================================

; Decides what a logged ERROR does. Called by _LoggerEmit on every emitted
; ERROR, synchronously and possibly from the keyboard hook: it must not log
; (the logger is mid-line, and a nested line would corrupt its dedup state)
; and must not block.
; @param Tag {String} The module.
; @param Template {String} The message before its arguments.
; @param Body {String} The formatted message.
; @param Stamp {String} The line's timestamp.
ErrorDialog_OnError(Tag, Template, Body, Stamp) {
	global _ED_Policy, _ED_Decisions, _ED_Busy, _ED_Folded, _ED_Enabled, _ED_Session, _ED_TimerFn
	global _ED_PendingRecord
	if !(_ED_Policy is Map)
		return
	Decision := ErrorPolicy_Decide(_ED_Decisions, _ED_Policy, Map(
		"module", Tag, "template", Template, "at", _HealthCheck_NowMs() / 1000,
		"enabled", _ED_Enabled, "open", _ED_Busy))
	switch Decision["verdict"] {
		case "folded":
			_ED_Folded += 1
			if (_ED_Session is Map)
				_ED_TimerFn.Call(_ErrorDialog_PushFolded.Bind(_ED_Session["epoch"]), -1)
		case "show":
			_ED_Busy := true
			Record := Map("kind", "error", "module", String(Tag), "message", String(Body), "time", String(Stamp))
			_ED_PendingRecord := Record
			_ED_TimerFn.Call(_ErrorDialog_Present.Bind(Record), -Max(1, _ED_Policy["present_delay_ms"]))
	}
}

; Tells the open window how many errors were folded into it.
; @param Epoch {Integer} The window the fold was counted for.
_ErrorDialog_PushFolded(Epoch) {
	global _ED_Folded
	_ErrorDialog_Send(Epoch, '{"type":"more","count":' . _ED_Folded . '}')
}





; ===============================
; ===============================
; ======= 3/ The Report =========
; ===============================
; ===============================

; The report of one error, from the diagnostics snapshot.
; @param Record {Map} { kind, module, message, time, log_path?, open_id? }
; @param SnapshotFn {Func} Snapshot collector; tests supply an inert producer.
; @returns {Map} { report, snapshot, paths, config, log_path, open_id }
_ErrorDialog_BuildReport(Record, SnapshotFn := HealthCheck_Run) {
	Config := HealthCheck_Config()
	Snapshot := SnapshotFn.Call(false)
	Sections := Snapshot["sections"]
	Versions := Sections.Get("versions", Map())
	System := Sections.Get("system", Map())
	Issues := Sections.Get("issues", Map())
	Generated := String(Snapshot["generated_at"])
	Identity := Map(
		"version",       String(Versions.Get("ergopti_version", "unknown")),
		"commit",        String(Versions.Get("commit", "")),
		"os",            String(System.Get("os", "unknown")),
		"driver",        "windows",
		"generated_utc", Generated,
		"warn_count",    Issues.Get("warn_count", 0),
		"err_count",     Issues.Get("err_count", 0))
	; The recent warnings and errors of today's errors file, as many as the
	; diagnostics window shows (_shared/modules/diagnostics/recent_issues.json)
	Recent := []
	for Entry in Issues.Get("recent", [])
		Recent.Push(String(Entry))
	Report := ErrorReport_Compose(Map("kind", Record["kind"], "module", Record["module"],
		"message", Record["message"], "time", Record["time"], "recent", Recent), Identity)
	Paths := Sections.Get("paths", Map()).Clone()
	OpenId := "errors_today"
	if (Record["kind"] == "crash") {
		OpenId := "crash_report"
		Paths["crash_report"] := Record["log_path"]
	}
	if !Paths.Has(OpenId) || (Paths[OpenId] == "")
		throw Error("The file this error is logged in is unknown.")
	return Map("report", Report, "snapshot", Snapshot, "paths", Paths, "config", Config, "log_path", Paths[OpenId], "open_id", OpenId)
}


; Reports one failure on GitHub exactly as this window's Report button does,
; for a window that shows a failure of its own (the update-check window): the
; same diagnostics report, redacted, the same prefilled issue form.
; @param Record {Map} { kind: "error", module, message, time }
; @param PerformFn {Func|Integer} Replacement of HealthCheck_PerformAction (tests only).
; @returns {Boolean} reported
ErrorDialog_Report(Record, PerformFn := 0) {
	try Fields := _ErrorDialog_BuildReport(Record)
	catch as Err {
		LoggerError("ErrorDialog", "The report of '{1}' could not be built: {2}", Record["module"], Err.Message)
		return false
	}
	Report := HealthCheck_ShareDocument(Fields["snapshot"], Fields["config"]["schema"])
	Perform := HasMethod(PerformFn, "Call") ? PerformFn : HealthCheck_PerformAction
	Outcome := Perform.Call(Map("action", "report", "text", Report["text"], "fields", Report["fields"]),
		Fields["paths"], Fields["config"], 0, Fields["snapshot"])
	return Outcome["ok"] ? true : false
}



; ==============================
; ==============================
; ======= 4/ The Window ========
; ==============================
; ==============================

; Opens the window for a decided error, once the driver is ready. Runs on a
; timer thread, never on the logging call's.
; @param Record {Map} { kind, module, message, time }
_ErrorDialog_Present(Record) {
	global _DriverBootPhase, _DriverStartupSmokeDir, ED_BOOT_RETRY_MS, _ED_Busy, _ED_Folded
	global _ED_PendingRecord, _ED_TimerFn
	if _ED_PendingRecord != Record
		return
	if (!IsSet(_DriverBootPhase) || _DriverBootPhase != "ready") {
		_ED_TimerFn.Call(_ErrorDialog_Present.Bind(Record), -ED_BOOT_RETRY_MS)
		return
	}
	; Release this exact request before logging: a nested error may admit its successor.
	if IsSet(_DriverStartupSmokeDir) && (_DriverStartupSmokeDir != "") {
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if _ED_PendingRecord != Record
				return
			_ED_PendingRecord := 0
			_ED_Busy := false
			_ED_Folded := 0
		} finally Critical(PreviousCritical)
		LoggerInfo("ErrorDialog", "Startup smoke run: the error window for '{1}' is not opened.", Record["module"])
		return
	}
	; Opening owns its failure cleanup; this frame must never free a successor.
	_ErrorDialog_Open(Record)
}
; Keep native title construction independently testable without reporting a real error.
_ErrorDialog_NewWindow() {
	return Gui_Create("+Resize +MinSize440x320", t("common.error_title"))
}

; Opens the window for one error, without taking the keyboard.
; @param Record {Map}
; @returns {Boolean} opened
_ErrorDialog_Open(Record) {
	global _VendorDir, _SharedDir, _I18nLocale, ED_WIDTH, ED_HEIGHT, ED_VHOST, ED_HOST_ACCESS_ALLOW
	global _ED_Gui, _ED_Controller, _ED_WebView, _ED_MsgSub, _ED_ResetDone, _ED_WindowEpoch, _ED_Session
	global _ED_PendingRecord
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if _ED_PendingRecord != Record || !_ED_ResetDone
			return false
		_ED_PendingRecord := 0
		_ED_ResetDone := false
		_ED_WindowEpoch += 1
		Epoch := _ED_WindowEpoch
	} finally Critical(PreviousCritical)
	G := 0, WVC := 0, WV := 0, Subscription := 0, Committed := false, Primary := 0
	try {
		LoggerStart("ErrorDialog", "Opening the error window…")
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		try Fields := _ErrorDialog_BuildReport(Record)
		catch as Err {
			Primary := Err
			LoggerError("ErrorDialog", "The error report could not be built: {1}", Err.Message)
			return false
		}
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
			&& !WebView_ShouldUseNativeFallback()
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		if !UseWV {
			Heading := t("error_dialog.heading")
			if !_ErrorDialog_IsCurrent(Epoch)
				return false
			NotifierSend(Heading . "`n`n" . Record["message"], Map("title", "ErgoptiPlus", "level", "error"))
			if _ErrorDialog_IsCurrent(Epoch)
				LoggerWarn("ErrorDialog", "WebView2 is unavailable; the error was announced by a notification.")
			return false
		}
		G := _ErrorDialog_NewWindow()
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		G.MarginX := 0
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		G.MarginY := 0
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		ContentCtl := G.Add("Text", "vErrorDialogContent x0 y0 w" . ED_WIDTH . " h" . ED_HEIGHT, "")
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		G.WVC := 0
		; Bind only the epoch. The native event supplies its exact Gui, without a Gui cycle.
		G.OnEvent("Close", _ErrorDialog_OnClose.Bind(Epoch))
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		G.OnEvent("Escape", _ErrorDialog_OnClose.Bind(Epoch))
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		G.OnEvent("Size", _ErrorDialog_OnSize.Bind(Epoch))
		if !_ErrorDialog_IsCurrent(Epoch)
			return false
		Fields["epoch"] := Epoch
		Fields["record"] := Record
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if !_ErrorDialog_IsCurrent(Epoch)
				return false
			_ED_Gui := G
			_ED_Session := Fields
		} finally Critical(PreviousCritical)
		; Publish the host before Show can dispatch Close or Size.
		G.Show("NoActivate w" . ED_WIDTH . " h" . ED_HEIGHT)
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		Environment := WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll")
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		HostHwnd := ContentCtl.Hwnd
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		try WVC := WebView2.create(HostHwnd, , Environment)
		catch as Err {
			Primary := Err
			LoggerError("ErrorDialog", "WebView2 could not be created for the error window: {1}", Err.Message)
			return false
		}
		; Until publication, this stack alone owns the returned controller, even if stale.
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		WV := WVC.CoreWebView2
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		try {
			s := WV.Settings
			if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
				return false
			s.AreDevToolsEnabled := false
			if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
				return false
			s.AreDefaultContextMenusEnabled := false
			if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
				return false
			s.IsStatusBarEnabled := false
			if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
				return false
			s.AreBrowserAcceleratorKeysEnabled := false
		}
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		Locale := IsSet(_I18nLocale) ? _I18nLocale : "en"
		try WV.AddScriptToExecuteOnDocumentCreated(
			"window.__i18n_base='https://" . ED_VHOST . "/data/locales/';window._i18n_locale='" . Locale . "';")
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		Subscription := WV.WebMessageReceived(_ErrorDialog_OnWebMessage.Bind(Epoch))
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		try WV.SetVirtualHostNameToFolderMapping(ED_VHOST, _SharedDir, ED_HOST_ACCESS_ALLOW)
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
				return false
			G.WVC := WVC
			_ED_Controller := WVC
			_ED_WebView := WV
			_ED_MsgSub := Subscription
			Subscription := 0
			Committed := true
		} finally Critical(PreviousCritical)
		try WV.Navigate("https://" . ED_VHOST . "/ui/error_dialog/index.html?cb=" . A_TickCount)
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		try WVC.Fill()
		if !_ErrorDialog_IsCurrent(Epoch, G, Fields)
			return false
		LoggerSuccess("ErrorDialog", "Error window opened.")
		return _ErrorDialog_IsCurrent(Epoch, G, Fields)
	} catch as Err {
		Primary := Err
		throw Err
	} finally {
		if !Committed {
			; Revoke only this owner, then release private COM outside the RAM transaction.
			Retired := _ErrorDialog_ResetWindow(Epoch)
			Subscription := 0
			WV := 0
			CleanupFailure := 0
			if WVC {
				try WVC.Close()
				catch as Err {
					CleanupFailure := Err
					try LoggerError("ErrorDialog", "Retired browser cleanup failed: {1}.", Err.Message)
				}
			}
			; Native Close may already have destroyed this exact private host.
			if G
				try G.Destroy()
			if IsObject(CleanupFailure) && !IsObject(Primary)
				throw CleanupFailure
		}
	}
}

; Pure owner checks also support the existing headless action tests.
_ErrorDialog_IsCurrent(Epoch, Window := 0, Session := 0) {
	global _ED_WindowEpoch, _ED_ResetDone, _ED_Gui, _ED_Session
	return !_ED_ResetDone && Epoch == _ED_WindowEpoch
		&& (!Window || (IsSet(_ED_Gui) && _ED_Gui == Window))
		&& (!Session || _ED_Session == Session)
}


; Direct report actions also run headless, with their response port disabled.
; Reset atomically revokes both this epoch and session before any teardown callout.
_ErrorDialog_SessionCurrent(Epoch, Session) {
	global _ED_WindowEpoch, _ED_Session
	return Session is Map && Epoch == _ED_WindowEpoch && _ED_Session == Session
}

_ErrorDialog_OnClose(Epoch, GuiObj, *) {
	if _ErrorDialog_IsCurrent(Epoch, GuiObj)
		_ErrorDialog_CloseWindow(Epoch, GuiObj)
	return true
}
; Keeps the page filling the window when it is resized.
_ErrorDialog_OnSize(Epoch, GuiObj, MinMax, Width, Height) {
	global _ED_Controller
	if MinMax == -1 || !_ErrorDialog_IsCurrent(Epoch, GuiObj)
		return
	ContentCtl := GuiObj["ErrorDialogContent"]
	if !_ErrorDialog_IsCurrent(Epoch, GuiObj)
		return
	ContentCtl.Move(0, 0, Width, Height)
	Controller := IsSet(_ED_Controller) ? _ED_Controller : 0
	if !_ErrorDialog_IsCurrent(Epoch, GuiObj)
		return
	if Controller
		try Controller.Fill()
}
; Closes the window: the controller first, while its host window lives, then
; the window; and frees the policy for the next error.
_ErrorDialog_CloseWindow(Epoch := unset, Window := 0) {
	Retired := IsSet(Epoch) ? _ErrorDialog_ResetWindow(Epoch, Window) : _ErrorDialog_ResetWindow()
	if !Retired
		return
	; Strong local references keep releases and native teardown outside Critical.
	Retired.Subscription := 0
	if Retired.Window
		Retired.Window.WVC := 0
	if Retired.Controller
		try Retired.Controller.Close()
	Retired.WebView := 0
	Retired.Controller := 0
	if Retired.Window
		try Retired.Window.Destroy()
	LoggerInfo("ErrorDialog", "Error window closed.")
}

; Detach every old reference before any destructor, Close, Destroy or logger can pump.
_ErrorDialog_ResetWindow(Epoch := unset, Window := 0) {
	global _ED_Gui, _ED_Controller, _ED_WebView, _ED_MsgSub, _ED_ResetDone, _ED_WindowEpoch, _ED_Session
	global _ED_Busy, _ED_Folded, _ED_PendingRecord
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if IsSet(Epoch) && !_ErrorDialog_IsCurrent(Epoch, Window)
			return 0
		Retired := {Window: IsSet(_ED_Gui) ? _ED_Gui : 0,
			Controller: IsSet(_ED_Controller) ? _ED_Controller : 0,
			WebView: IsSet(_ED_WebView) ? _ED_WebView : 0,
			Subscription: IsSet(_ED_MsgSub) ? _ED_MsgSub : 0, Session: _ED_Session,
			Pending: _ED_PendingRecord}
		_ED_ResetDone := true
		_ED_WindowEpoch += 1
		_ED_PendingRecord := 0
		_ED_Session := 0
		_ED_Busy := false
		_ED_Folded := 0
		_ED_Gui := unset
		_ED_Controller := unset
		_ED_WebView := unset
		_ED_MsgSub := unset
		return Retired
	} finally Critical(PreviousCritical)
}
; Sends one message into the window's page.
; @param Epoch {Integer}
; @param Json {String}
_ErrorDialog_Send(Epoch, Json) {
	global _ED_WebView, _ED_WindowEpoch, _ED_ResetDone
	WebView := IsSet(_ED_WebView) ? _ED_WebView : 0
	if _ED_ResetDone || (Epoch != _ED_WindowEpoch) || !WebView
		return
	WebView_RunScriptAsync(WebView, "if(window.receiveErrorDialog)window.receiveErrorDialog(" . Json . ")",
		"ErrorDialog")
}

; The page's first message: the error and its report, already redacted.
; @param Session {Map}
; @returns {String}
_ErrorDialog_InitJson(Session) {
	global _ED_Folded
	Config := Session["config"]
	Context := HealthCheck_RedactionContext()
	Rules := Config["redaction"]
	Record := Session["record"]
	return '{"type":"init","kind":' . JsonStringLiteral(Record["kind"])
		. ',"module":' . JsonStringLiteral(Redact_Apply(Record["module"], Rules, Context))
		. ',"message":' . JsonStringLiteral(Redact_Apply(Record["message"], Rules, Context))
		. ',"log_path":' . JsonStringLiteral(Redact_Apply(Session["log_path"], Rules, Context))
		. ',"text":' . JsonStringLiteral(Redact_Apply(Session["report"]["text"], Rules, Context))
		. ',"more":' . _ED_Folded . '}'
}

; Receives the page's messages. WebMessageReceived is a COM callback: the
; message is read here and handled on a fresh stack, bound to its window.
_ErrorDialog_OnWebMessage(Epoch, Handler, Args) {
	global _ED_WindowEpoch, _ED_ResetDone
	if _ED_ResetDone || (Epoch != _ED_WindowEpoch)
		return
	try Raw := Args.TryGetWebMessageAsString()
	catch as Err {
		LoggerWarn("ErrorDialog", "An error window message could not be read: {1}.", Err.Message)
		return
	}
	if !_ErrorDialog_IsCurrent(Epoch)
		return
	; The callback bypasses native Suspend, and deliberately: the window changes
	; nothing ErgoptiPlus does (it copies, opens a file or GitHub), and an error
	; is worth reporting whether or not the driver is paused
	if A_IsSuspended
		LoggerDebug("ErrorDialog", "An error window message arrived while suspended; the window stays usable.")
	if !_ErrorDialog_IsCurrent(Epoch)
		return
	SetTimer(_ErrorDialog_HandleMessage.Bind(Epoch, Raw), -1)
}

; Handles one message of the page, on its own stack.
; @param Epoch {Integer}
; @param Raw {String}
; @param PerformFn {Func|Integer} Replacement of HealthCheck_PerformAction (tests only).
_ErrorDialog_HandleMessage(Epoch, Raw, PerformFn := 0) {
	global _ED_WindowEpoch, _ED_ResetDone, _ED_Session, ED_PAGE_ACTIONS
	Session := _ED_Session
	if !_ErrorDialog_IsCurrent(Epoch, 0, Session) || !(Session is Map)
		return
	if (Raw == "ready") {
		try _ErrorDialog_Send(Epoch, _ErrorDialog_InitJson(Session))
		catch as Err
			LoggerError("ErrorDialog", "The error window could not be initialised: {1}", Err.Message)
		return
	}
	ActionName := ""
	try {
		Message := JsonParse(Raw)
		if (Message is Map)
			ActionName := Message.Get("action", "")
	}
	if !(ActionName is String) || !ED_PAGE_ACTIONS.Has(ActionName) {
		LoggerWarn("ErrorDialog", "Refused an error window message that is not one of its actions.")
		return
	}
	LoggerInfo("ErrorDialog", "Error window action: {1}.", ActionName)
	try {
		_ErrorDialog_Perform(Epoch, ActionName, PerformFn)
	} catch as Err {
		LoggerError("ErrorDialog", "The error window action '{1}' failed: {2}", ActionName, Err.Message)
		_ErrorDialog_Send(Epoch, '{"type":"action","action":' . JsonStringLiteral(ActionName) . ',"ok":false}')
	}
}

; Performs one action of the page and answers it: the host acts on the
; report it holds, never on a text, a path or a URL from the page.
; @param Epoch {Integer}
; @param Name {String}
; @param PerformFn {Func|Integer} Replacement of HealthCheck_PerformAction (tests only).
_ErrorDialog_Perform(Epoch, ActionName, PerformFn := 0) {
	global _ED_Session
	Session := _ED_Session
	if !_ErrorDialog_SessionCurrent(Epoch, Session)
		return
	if (ActionName == "close") {
		_ErrorDialog_CloseWindow(Epoch)
		return
	}
	Report := Session["report"]
	if ActionName == "copy" || ActionName == "report"
		Report := HealthCheck_ShareDocument(Session["snapshot"], Session["config"]["schema"])
	if !_ErrorDialog_SessionCurrent(Epoch, Session)
		return
	switch ActionName {
		case "copy":
			PageAction := Map("action", "copy", "text", Report["text"])
		case "report":
			PageAction := Map("action", "report", "text", Report["text"], "fields", Report["fields"])
		default:
			PageAction := Map("action", "open_path", "id", Session["open_id"])
	}
	Perform := HasMethod(PerformFn, "Call") ? PerformFn : HealthCheck_PerformAction
	ActionOutcome := Perform.Call(PageAction, Session["paths"], Session["config"], 0, Session["snapshot"])
	Json := '{"type":"action","action":' . JsonStringLiteral(ActionName) . ',"ok":' . (ActionOutcome["ok"] ? "true" : "false")
	if ActionOutcome.Get("missing", false)
		Json .= ',"missing":true'
	_ErrorDialog_Send(Epoch, Json . '}')
}
