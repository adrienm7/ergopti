; tests/unit/test_error_dialog.ahk

; ==============================================================================
; MODULE: Error Window (Windows)
; DESCRIPTION:
; Drives the error window's policy wiring and page actions:
; 1. a logged ERROR, through the real logger, reaches ErrorDialog_OnError with
;    its module and its UNFORMATTED template, and arms one timer; nothing is
;    logged from inside the logging call;
; 2. the shared policy holds: the same signature never arms twice, an error
;    logged while the window is pending or open is folded into it, nothing is
;    armed while the Debug menu setting is unticked or before initialisation;
; 3. the page's actions act on the report the host holds: copy, report and
;    open go through the diagnostics actions; a forged text or an unknown
;    action changes nothing;
; 4. the global error handler no longer raises its own tray toast, and logs an
;    uncaught error under a template that names its site, so two faults in two
;    places are two signatures.
; ==============================================================================

#Requires AutoHotkey v2.0

_TED_NativeWindowTitle() {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	SavedCache := _I18nCache, SavedLoaded := _I18nCacheLoaded
	try {
		Locales := JsonParse(FileRead(_SharedDir . "\data\locale_order.json", "UTF-8"))["order"]
		AssertEqual(21, Locales.Length)
		for Locale in Locales {
			Strings := JsonParse(FileRead(_SharedDir . "\data\locales\" . Locale . ".json", "UTF-8"))
			Label := Strings["common.error_title"]
			_I18nCache := Map("common.error_title", Label), _I18nCacheLoaded := true
			Window := _ErrorDialog_NewWindow()
			try AssertEqual("ErgoptiPlus — " . Label, Window.Title, Locale . " native error title")
			finally Window.Destroy()
		}
	} finally {
		_I18nCache := SavedCache, _I18nCacheLoaded := SavedLoaded
	}
}
Test("error window: the native title has one product prefix in every locale (error-window-title)",
	_TED_NativeWindowTitle)

; Captures the timers ErrorDialog_OnError arms instead of arming them.
global _TED_Timers := []

_TED_CaptureTimer(Fn, Period) {
	global _TED_Timers
	_TED_Timers.Push(Map("fn", Fn, "period", Period))
}

; Puts the error window back to a fresh, initialised session.
; @param Enabled {Boolean} The Debug menu setting.
_TED_Reset(Enabled := true) {
	global _ED_Policy, _ED_Decisions, _ED_Enabled, _ED_Busy, _ED_Folded, _ED_Session, _ED_TimerFn, _TED_Timers
	global _ED_ResetDone, _ED_WindowEpoch, _ED_PendingRecord
	_ED_Policy := 0
	_ED_PendingRecord := 0
	_ED_Busy := false
	_ED_Folded := 0
	_ED_Session := 0
	_ED_ResetDone := true
	_TED_Timers := []
	_ED_TimerFn := _TED_CaptureTimer
	Cache := Map("script", Map("show_error_dialog", Enabled ? 1 : 0))
	Assert(ErrorDialog_Init(Cache), "the error window must initialise from the shipped policy")
}

_TED_Restore() {
	global _ED_TimerFn, _ED_Policy
	_ED_TimerFn := SetTimer
	_ED_Policy := 0
}

_TED_LoggerReachesTheWindowWithTheTemplate() {
	global _ED_Decisions, _TED_Timers
	_TED_Reset()
	try {
		Lines := []
		LoggerSetTestSink((Line) => Lines.Push(Line))
		LoggerError("TedModule", "Flush failed: {1}", "disk full")
		LoggerClearTestSink()
		AssertEqual(1, Lines.Length, "the ERROR line itself is the only line: the hook must not log")
		Assert(_ED_Decisions["seen"].Has("TedModule|Flush failed: {1}"),
			"the signature is the module and the unformatted template")
		AssertEqual(1, _TED_Timers.Length, "one timer is armed")
		Assert(_TED_Timers[1]["period"] < 0, "the timer is one-shot")
	} finally _TED_Restore()
}
Test("error window: the logger hands ERRORs over with their template (error-dialog-windows)",
	_TED_LoggerReachesTheWindowWithTheTemplate)

_TED_PolicyHolds() {
	global _TED_Timers, _ED_Folded, _ED_Busy
	_TED_Reset()
	try {
		ErrorDialog_OnError("A", "one", "one", "t")
		ErrorDialog_OnError("A", "two", "two", "t")
		AssertEqual(1, _TED_Timers.Length, "an error logged while a window is pending arms nothing")
		AssertEqual(1, _ED_Folded, "it is folded into the pending window")
		_ErrorDialog_CloseWindow()
		AssertEqual(false, _ED_Busy, "closing frees the policy")
		ErrorDialog_OnError("A", "one", "again", "t")
		AssertEqual(1, _TED_Timers.Length, "a signature already shown this session never opens again")
		ErrorDialog_OnError("B", "three", "three", "t")
		AssertEqual(2, _TED_Timers.Length, "after close a new error opens a window again")
	} finally _TED_Restore()
}
Test("error window: one window per signature, folds while open (error-dialog-windows)", _TED_PolicyHolds)

_TED_UntickedKeepsQuiet() {
	global _TED_Timers
	_TED_Reset(false)
	try {
		AssertEqual(false, ErrorDialog_IsEnabled())
		ErrorDialog_OnError("A", "one", "one", "t")
		AssertEqual(0, _TED_Timers.Length, "an unticked setting keeps every error quiet")
	} finally _TED_Restore()
}
Test("error window: nothing opens while the setting is unticked (error-dialog-windows)", _TED_UntickedKeepsQuiet)

_TED_DisablingCancelsPending() {
	global _TED_Timers, _ED_Busy, _DriverBootPhase, _DriverStartupSmokeDir
	HadPhase := IsSet(_DriverBootPhase), SavedPhase := HadPhase ? _DriverBootPhase : ""
	HadSmoke := IsSet(_DriverStartupSmokeDir), SavedSmoke := HadSmoke ? _DriverStartupSmokeDir : ""
	_TED_Reset()
	try {
		_DriverBootPhase := "ready"
		_DriverStartupSmokeDir := "error-dialog-cancellation-test"
		ErrorDialog_OnError("old", "Old failure", "Old failure", "t")
		Stale := _TED_Timers[1]["fn"]
		Quiet := (*) => 0
		Writer := (Path, Updates) => true
		Assert(ErrorDialog_SetEnabled(false, Writer, Quiet, Quiet))
		AssertEqual(false, _ED_Busy, "disabling releases the pending slot")
		Assert(ErrorDialog_SetEnabled(true, Writer, Quiet, Quiet))
		ErrorDialog_OnError("new", "New failure", "New failure", "t")
		AssertEqual(2, _TED_Timers.Length, "a new error can queue after reactivation")
		Stale.Call()
		AssertEqual(true, _ED_Busy, "the stale callback cannot consume the new pending window")
		_TED_Timers[2]["fn"].Call()
		AssertEqual(false, _ED_Busy, "the current callback reaches the headless presentation guard")
	} finally {
		_DriverBootPhase := HadPhase ? SavedPhase : unset
		_DriverStartupSmokeDir := HadSmoke ? SavedSmoke : unset
		_TED_Restore()
	}
}
Test("error window: disabling invalidates queued windows across reactivation (error-dialog-cancel)",
	_TED_DisablingCancelsPending)

_TED_BeforeInitNothing() {
	global _ED_Policy, _ED_TimerFn, _TED_Timers
	_TED_Timers := []
	_ED_Policy := 0
	_ED_TimerFn := _TED_CaptureTimer
	try {
		ErrorDialog_OnError("A", "one", "one", "t")
		AssertEqual(0, _TED_Timers.Length, "an error logged before initialisation opens nothing")
	} finally _TED_Restore()
}
Test("error window: nothing before initialisation (error-dialog-windows)", _TED_BeforeInitNothing)

_TED_SettingPersists() {
	global _ED_Enabled, ConfigurationFile
	SavedPath := ConfigurationFile
	_TED_Reset()
	try {
		ConfigurationFile := A_Temp . "\ergopti_error_dialog_setting.toml"
		Seen := []
		Quiet := (*) => 0
		Refused := (Path, Updates) => false
		AssertEqual(false, ErrorDialog_SetEnabled(false, Refused, Quiet, Quiet), "a refused write is reported")
		AssertEqual(true, _ED_Enabled, "a refused write leaves the live flag unchanged")
		Writer := (Path, Updates) => (Seen.Push(Updates), true)
		Assert(ErrorDialog_SetEnabled(false, Writer, Quiet, Quiet), "the setting must be saved")
		AssertEqual(false, _ED_Enabled, "the live flag follows the saved one")
		AssertEqual(1, Seen.Length, "one write")
		AssertEqual("script", Seen[1][1].Section)
		AssertEqual("show_error_dialog", Seen[1][1].Key)
	} finally {
		ConfigurationFile := SavedPath
		_TED_Restore()
	}
}
Test("error window: the setting is saved to config.toml (error-dialog-windows)", _TED_SettingPersists)

_TED_ActionsUseTheHostsReport() {
	global _ED_Session, _ED_ResetDone, _ED_WindowEpoch
	_TED_Reset()
	try {
		Performed := []
		Perform := (Action, Paths, Config, Unused, Snapshot) => (Performed.Push(Map("action", Action, "paths", Paths, "snapshot", Snapshot)), Map("ok", true))
		Report := Map("text", "# ErgoptiPlus diagnostics`n", "fields", Map("title", "Mod: boom"))
		Snapshot := _TED_SharingSnapshot()
		Config := HealthCheck_Config()
		Shared := HealthCheck_ShareDocument(Snapshot, Config["schema"])
		_ED_Session := Map("epoch", _ED_WindowEpoch, "report", Report, "open_id", "errors_today",
			"paths", Map("errors_today", "C:\x\errors.log"), "config", Config, "snapshot", Snapshot)
		_ED_ResetDone := false
		_ErrorDialog_HandleMessage(_ED_WindowEpoch, '{"action":"copy","text":"forged"}', Perform)
		_ErrorDialog_HandleMessage(_ED_WindowEpoch, '{"action":"report"}', Perform)
		_ErrorDialog_HandleMessage(_ED_WindowEpoch, '{"action":"open_log"}', Perform)
		_ErrorDialog_HandleMessage(_ED_WindowEpoch, '{"action":"open_path","id":"config_dir"}', Perform)
		AssertEqual(3, Performed.Length, "copy, report and open run; the unknown action does not")
		AssertEqual("copy", Performed[1]["action"]["action"])
		AssertEqual(Shared["text"], Performed[1]["action"]["text"], "the page cannot choose what is copied")
		AssertEqual("report", Performed[2]["action"]["action"])
		AssertFalse(Performed[2]["action"]["fields"].Has("title"), "sharing omits the free error title")
		; The host prefills the report itself and saves no file (report-focus)
		AssertEqual(Shared["text"], Performed[2]["action"]["text"], "report sends the report copy sends")
		AssertFalse(Performed[2]["action"].Has("name"), "a report names no file to save")
		AssertEqual("open_path", Performed[3]["action"]["action"])
		AssertEqual("errors_today", Performed[3]["action"]["id"], "open_log opens today's errors file, by id")
		_ErrorDialog_HandleMessage(_ED_WindowEpoch + 1, '{"action":"copy"}', Perform)
		AssertEqual(3, Performed.Length, "a message of another window is inert")
	} finally {
		_ED_ResetDone := true
		_ED_Session := 0
		_TED_Restore()
	}
}
Test("error window: page actions act on the host's report (error-dialog-windows)", _TED_ActionsUseTheHostsReport)

_TED_GlobalHandlerSurfacesThroughTheWindow() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler must be readable")
	HandlerCode := _StripFullLineComments(Body)
	Assert(!InStr(HandlerCode, "error_caught"), "the global error handler must not raise its own tray toast")
	Assert(InStr(HandlerCode, "_ErrorNet_UncaughtTemplate(Exc)"),
		"an uncaught error is logged under a template that names its site")
	Exc := ValueError("the message varies", "Foo")
	SplitPath(Exc.File, &FileName)
	Template := _ErrorNet_UncaughtTemplate(Exc)
	AssertEqual("Uncaught ValueError in Foo (" . FileName . ":" . Exc.Line . "): {1}", Template,
		"the template names the type and the site, never the message")
	Braced := _ErrorNet_UncaughtTemplate(Error("m", "{x}"))
	Assert(InStr(Format(Braced, "boom"), "Uncaught Error in {x} (") == 1,
		"braces of the site are escaped so the template keeps its one placeholder: " . Braced)
	Assert(InStr(Format(Braced, "boom"), "): boom"), "the message fills the placeholder: " . Braced)
}
Test("error window: uncaught errors reach it by their site, without a toast (error-dialog-windows)",
	_TED_GlobalHandlerSurfacesThroughTheWindow)


; Supplies only synthetic host data; no collector, window or clipboard runs.
_TED_SharingSnapshot() {
	return Map("driver", "windows", "schema_version", 2, "detailed", false,
		"generated_at", "2026-09-24T08:15:02Z", "sections", Map(
			"versions", Map("ergopti_version", "2.1.0", "commit", "abcdef123456"),
			"system", Map("os", "Windows 11", "arch", "x64"),
			"issues", Map("warn_count", 1, "err_count", 2, "recent", ["CANARY-private.invalid/notes"]),
			"paths", Map("errors_today", "C:\synthetic-owner\errors.log")),
		"probes", Map("appleevent_transport", Map("state", "error", "native_status", -1744, "ms", 12, "cleanup", "settled")))
}

_TED_RealSharingSink() {
	global _ED_Session, _ED_ResetDone, _ED_WindowEpoch
	SavedSession := _ED_Session, SavedReset := _ED_ResetDone, SavedEpoch := _ED_WindowEpoch
	try {
		Snapshot := _TED_SharingSnapshot()
		Fields := _ErrorDialog_BuildReport(Map("kind", "error", "module", "synthetic",
			"message", "CANARY-private.invalid/notes", "time", "local"), (*) => Snapshot)
		Assert(Fields["snapshot"] == Snapshot, "the builder retains the exact captured host snapshot")
		AssertContains(Fields["report"]["text"], "CANARY", "local detailed report remains available")
		Copied := [], Opened := []
		Overrides := Map("identity", (*) => Map("home", "C:\synthetic-owner", "user", "synthetic"),
			"copy", (Text) => (Copied.Push(Text), true), "open_url", (Url) => (Opened.Push(Url), true))
		Perform := (Action, Paths, Config, Unused := 0, Retained := 0) => HealthCheck_PerformAction(Action, Paths, Config, Overrides, Retained)
		_ED_Session := Fields
		_ED_ResetDone := true ; The response port refuses before any WebView use.
		_ErrorDialog_Perform(_ED_WindowEpoch, "copy", Perform)
		_ErrorDialog_Perform(_ED_WindowEpoch, "report", Perform)
		AssertEqual(2, Copied.Length, "both callers reach the actual approved copy sink")
		AssertEqual(1, Opened.Length, "the actual issue builder opens after copying")
		AssertEqual(Copied[1], Copied[2], "both actions use the same retained projection")
		AssertFalse(InStr(Copied[1], "CANARY"), "private error details never leave")
		AssertContains(Copied[1], "-1744", "admitted technical status remains useful")
		AssertFalse(InStr(Opened[1], "CANARY"), "the issue URL cannot leak the error")
		Overrides["copy"] := (*) => false
		_ErrorDialog_Perform(_ED_WindowEpoch, "report", Perform)
		AssertEqual(1, Opened.Length, "copy refusal prevents another browser action")
	} finally {
		_ED_Session := SavedSession, _ED_ResetDone := SavedReset, _ED_WindowEpoch := SavedEpoch
	}
}
Test("error window: actual sharing caller retains snapshot and excludes private details", _TED_RealSharingSink)
