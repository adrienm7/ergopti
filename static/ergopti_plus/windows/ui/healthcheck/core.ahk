; ui/healthcheck/core.ahk

; ==============================================================================
; MODULE: Healthcheck / Snapshot + Window
; DESCRIPTION:
; Session counters, the module contract check, the version 2 snapshot
; (_shared/modules/diagnostics/schema.json) and the diagnostics window. The
; window loads the shared page (_shared/ui/healthcheck/) through a virtual
; host; the page renders the snapshot, keeps the preview of what is shared and
; asks for every action by message.
;
; FEATURES & RATIONALE:
; 1. One WebMessageReceived subscription per window, bound to the window's
;    epoch. A message is read inside the COM callback and handled on a fresh
;    stack (SetTimer -1): handling it inside the callback re-enters the STA
;    apartment and can wedge WebView2's message delivery.
; 2. Every message is validated by HealthCheck_ValidateAction against the
;    schema's allowlist: the host opens only the paths it collected, by id.
; 3. The page asks for the first snapshot with "ready"; the probes start then
;    and push their answers into the same window only.
; 4. Diagnostics attempt the shared page even under memory pressure. When
;    WebView2 is unavailable, a native tree preserves translated sections and
;    separate values instead of dumping the plain-text export into an Edit.
;
; Split out of the former infra/healthcheck.ahk (the module split); see
; ui/healthcheck/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the healthcheck/*.ahk files is irrelevant.
; ==============================================================================



; Module-level state. _HealthCheckStartMs anchors the uptime origin at module
; load (parse time) — there is no separate init step; this is the single source
; of truth for the start tick, also read by crash_reporter.ahk.
global _HealthCheckStartMs   := A_TickCount
global _HealthCheckLastError := ""
global _HealthCheckWarnCount := 0
global _HealthCheckErrCount  := 0





; ========================================
; ========================================
; ======= 1/ Module Contract Check =======
; ========================================
; ========================================

; Each entry maps an adapter id to its required public function names.
; The id is the bare filename stem under adapters/ (no path, no extension).
; Functions are global AHK names expected to exist after the driver has
; finished its #Include phase.
_HealthCheck_AdapterSpecs() {
	Specs := Map()
	Specs["clipboard"]             := ["CB_Read", "CB_Write"]
	Specs["file_system"]           := ["FSRead", "FSWrite", "FSExists"]
	Specs["http_client"]           := ["HTTPPost", "HTTPCancel"]
	Specs["keyboard_hook"]         := ["KHStart", "KHStop"]
	Specs["mouse_control"]         := ["MCSetPos", "MCGetPos"]
	Specs["network_info"]          := ["NI_GetSsidHash"]
	Specs["notifier"]              := ["NotifierSend"]
	Specs["process_lifecycle"]     := ["PLC_Start", "PLC_Stop"]
	Specs["secure_field_detector"] := ["SFD_IsSecureField"]
	Specs["storage"]               := ["ST_Get", "ST_Set"]
	Specs["text_sender"]           := ["TextSend", "TextEraseChars"]
	Specs["timer_scheduler"]       := ["TimerAfter", "TimerEvery"]
	Specs["tooltip_renderer"]      := ["TooltipRShow", "TooltipRHide"]
	Specs["tray_menu"]             := ["TrayMenuSetIcon", "TrayMenuSetMenu", "TrayMenuSetTooltip", "TrayMenuDestroy"]
	Specs["window_info"]           := ["WIGetFocused", "WIGetAll"]
	Specs["window_manager"]        := ["WMActivate", "WMExists"]
	return Specs
}

; Checks every adapter's contract: each listed function is defined.
; @returns {Map} { ok: Array of ids, failed: Array of "id (reason)" }
_HealthCheck_ModuleCheck() {
	Ok := []
	Failed := []
	for AdapterId, RequiredFns in _HealthCheck_AdapterSpecs() {
		AllPresent := true
		for _, FnName in RequiredFns {
			if !IsSet(%FnName%) or !((%FnName%) is Func) {
				AllPresent := false
				LoggerWarn("Healthcheck", "Adapter '{1}' missing function '{2}'.", AdapterId, FnName)
			}
		}
		if AllPresent
			Ok.Push(AdapterId)
		else
			Failed.Push(AdapterId . " (contract incomplete)")
	}
	return Map("ok", Ok, "failed", Failed)
}





; ===================================
; ===================================
; ======= 2/ Session Counters =======
; ===================================
; ===================================

; Stores the last ERROR line for later retrieval by HealthCheck_Run(). The
; logger calls it on every emitted ERROR with the whole formatted line, which
; is what the macOS and Linux logger cores keep as their session last error.
; @param Msg {String} The formatted log line.
HealthCheck_RecordError(Msg) {
	global _HealthCheckLastError, _HealthCheckErrCount
	if !IsSet(_HealthCheckLastError)
		_HealthCheckLastError := ""
	_HealthCheckLastError := Msg
	_HealthCheckErrCount := (IsSet(_HealthCheckErrCount) ? _HealthCheckErrCount : 0) + 1
	; Do NOT log here: this runs synchronously from inside _LoggerEmit() (via the
	; ERROR/WARNING hook), so a recursive Logger* call re-enters _LoggerEmit mid-flight
	; and clobbers the outer call's dedup key + ring cursor with this line instead
	; (logger-reentrancy-corrupts-dedup-and-ring-cursor). The original error is
	; already logged by the caller — this is a silent counter update only.
}

; Increments the session warning counter (called by logger when it emits a WARNING).
HealthCheck_RecordWarn() {
	global _HealthCheckWarnCount
	_HealthCheckWarnCount := (IsSet(_HealthCheckWarnCount) ? _HealthCheckWarnCount : 0) + 1
}





; ===============================
; ===============================
; ======= 3/ The Snapshot =======
; ===============================
; ===============================

; The documents of the diagnostics window, parsed once: they are files of the
; shared tree, not settings.
global _HC_Config := 0

; The schema, the issue forms, the redaction rules and the repository, with
; the raw schema and rules the page receives as they are.
; @returns {Map} { schema, raw_schema, templates, redaction, raw_redaction, repository }
HealthCheck_Config() {
	global _HC_Config, _SharedDir
	if (_HC_Config is Map)
		return _HC_Config
	RawSchema := FileRead(_SharedDir . "\modules\diagnostics\schema.json", "UTF-8")
	RawRedaction := FileRead(_SharedDir . "\modules\diagnostics\redaction.json", "UTF-8")
	Schema := JsonParse(RawSchema)
	if !(Schema is Map) || (Schema.Get("schema_version", 0) != 2)
		throw ValueError("The diagnostics schema is not a version 2 schema.")
	_HC_Config := Map(
		"schema",        Schema,
		"raw_schema",    RawSchema,
		"redaction",     JsonParse(RawRedaction),
		"raw_redaction", RawRedaction,
		"templates",     JsonParse(FileRead(_SharedDir . "\modules\diagnostics\issue_templates.json", "UTF-8")),
		"repository",    JsonParse(FileRead(_SharedDir . "\modules\updater\defaults.json", "UTF-8"))["github"])
	return _HC_Config
}

; Run one collector defensively and return its value, or ``Fallback`` if it
; throws.
;
; A healthcheck is most valuable exactly when the driver is unhealthy, and
; several collectors read subsystem state that a crash has just left half-built.
; Called bare, any one of them aborted the whole run — which is how two crashed
; processes came to write an unpaired "Running healthcheck..." as their final
; line and produce no crash report at all.
;
; Failures are reported at WARNING rather than swallowed, so the culprit is
; named in the errors sink, and the trace/done pair brackets the call so a
; collector that HANGS (rather than throws) leaves the last unpaired TRACE
; pointing straight at it.
; @param Name {String} Collector name, used in the log lines.
; @param Collector {Func} Zero-argument collector to invoke.
; @param Fallback {Any} Value substituted when the collector fails.
; @return {Any} The collected value, or Fallback.
_HealthCheck_Collect(Name, Collector, Fallback) {
	try LoggerTrace("Healthcheck", "Collecting '{1}'…", Name)
	Value := Fallback
	try {
		Value := Collector()
	} catch as e {
		try LoggerWarn("Healthcheck", "Collector '{1}' failed, field degraded: {2}.", Name, e.Message)
	}
	try LoggerDone("Healthcheck", "Collected '{1}'.", Name)
	return Value
}

; The warnings and errors: the session counters, the last error and the
; newest entries of today's errors file (the ring before it exists).
; @returns {Map}
_HealthCheck_Issues() {
	global _HealthCheckLastError, _HealthCheckWarnCount, _HealthCheckErrCount
	Recent := _HealthCheck_Collect("recent_issues",
		() => _HealthCheck_RecentIssues(_HealthCheck_ErrorsLogPath()),
		Map("entries", [], "source", "unavailable"))
	Issues := Map(
		"warn_count",    _HealthCheckWarnCount,
		"err_count",     _HealthCheckErrCount,
		"recent_source", Recent["source"],
		"recent",        Recent["entries"])
	if (_HealthCheckLastError != "")
		Issues["last_error"] := _HealthCheckLastError
	return Issues
}

; The developer section: the module check, the log level and the ring.
; @returns {Map}
_HealthCheck_Developer() {
	global LOGGER_MIN_LEVEL
	Check := _HealthCheck_ModuleCheck()
	Developer := Map(
		"modules_ok",       Check["ok"],
		"modules_failed",   Check["failed"],
		"modules_disabled", [],
		"ring_lines",       LoggerRingBufferSnapshot().Length)
	if IsSet(LOGGER_MIN_LEVEL)
		Developer["log_level"] := String(LOGGER_MIN_LEVEL)
	return Developer
}

; The pending state of every probe this driver runs.
; @param Schema {Map}
; @returns {Map}
_HealthCheck_PendingProbes(Schema, Selected := true) {
	Probes := Map()
	for Id, Probe in Schema["probes"]
		if _HealthCheck_Applies(Probe)
			Probes[Id] := Selected ? Map("state", "pending") : Map("state", "not_run", "reason", "opt_in_required")
	return Probes
}

; A monotonic millisecond clock finer than A_TickCount, whose 15.6 ms steps
; cannot measure a 5 ms budget.
; @returns {Float}
_HealthCheck_NowMs() {
	static Frequency := 0
	if !Frequency
		DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	Counter := 0
	DllCall("QueryPerformanceCounter", "Int64*", &Counter)
	return Counter * 1000 / Frequency
}

; Collects the synchronous (phase A) snapshot of version 2 of the schema:
; in-process reads only, the probes fill the rest.
; @param Detailed {Boolean} Whether the user ticked "Include details".
; @returns {Map} { schema_version, driver, generated_at, detailed, sections, probes }
; @param Extensive {Boolean} Admits asynchronous checks independently of privacy.
HealthCheck_Run(Detailed := false, Extensive := false) {
	if !(Extensive is Integer) || (Extensive != 0 && Extensive != 1)
		throw TypeError("Extensive diagnostics require a Boolean selection.")
	global _HealthCheckStartMs
	try LoggerStart("Healthcheck", "Collecting the diagnostics…")
	; The budget is the collection's: the shared documents are parsed once per
	; session (about 30 ms on the first opening), before the clock starts
	Schema := HealthCheck_Config()["schema"]
	Started := _HealthCheck_NowMs()
	UptimeSec := (A_TickCount - (_HealthCheckStartMs) & 0xFFFFFFFF) // 1000
	ReportSubdir := Schema["report"]["subdir"]

	; Every collector is hoisted out of the Map(...) constructor and run through
	; _HealthCheck_Collect: inside the constructor a bare call could not be
	; guarded, and the first one to throw took the whole snapshot — and the
	; crash report it was run for — down with it.
	Paths       := _HealthCheck_Collect("paths", () => _HealthCheck_Paths(ReportSubdir), Map())
	Versions    := _HealthCheck_Collect("versions", _HealthCheck_Versions, Map())
	Hardware    := _HealthCheck_Collect("hardware", _HealthCheck_Hardware, Map())
	System      := _HealthCheck_Collect("system", () => _HealthCheck_System(Detailed, UptimeSec), Map())
	Input       := _HealthCheck_Collect("input", _HealthCheck_Input, Map())
	Features    := _HealthCheck_Collect("features", _HealthCheck_Features, Map("items", []))
	Ai          := _HealthCheck_Collect("ai", _HealthCheck_Ai, Map())
	Peripherals := _HealthCheck_Collect("peripherals", () => _HealthCheck_Peripherals(Detailed), Map("items", []))
	Issues      := _HealthCheck_Collect("issues", _HealthCheck_Issues, Map())
	Developer   := _HealthCheck_Collect("developer", _HealthCheck_Developer, Map())
	Probes      := _HealthCheck_PendingProbes(Schema, Extensive)

	Sections := Map(
		"paths",       Paths,
		"versions",    Versions,
		"hardware",    Hardware,
		"system",      System,
		"input",       Input,
		"features",    Features,
		"ai",          Ai,
		"network",     Map(),
		"peripherals", Peripherals,
		"issues",      Issues,
		"developer",   Developer)
	Snapshot := Map(
		"schema_version", Schema["schema_version"],
		"driver",         "windows",
		"generated_at",   FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
		"detailed",       Detailed ? true : false,
		"extensive",      Extensive ? true : false,
		"sections",       Sections,
		"probes",         Probes)

	; A Float: Round(x, 1) returns a String in AHK v2
	Elapsed := Round((_HealthCheck_NowMs() - Started) * 10) / 10
	Developer["phase_a_ms"] := Elapsed
	; Not a warning: the next snapshot would count it among the session's
	; problems. The report's developer section carries the duration.
	if (Elapsed > Schema["phase_a_budget_ms"])
		try LoggerInfo("Healthcheck", "The synchronous diagnostics took {1} ms, over the {2} ms budget.",
			Elapsed, Schema["phase_a_budget_ms"])
	Undeclared := HealthCheck_CheckFields(Snapshot, Schema)["undeclared"]
	if (Undeclared.Length > 0)
		try LoggerError("Healthcheck", "The diagnostics snapshot carries fields the schema does not declare: {1}.",
			_HC_Join(Undeclared, ", "))
	try LoggerSuccess("Healthcheck", "Diagnostics collected in {1} ms.", Elapsed)
	return Snapshot
}

; Formats a snapshot as plain text, one "section.field: value" line per value,
; for the read-only field shown when WebView2 is unavailable.
; @param Snapshot {Map} From HealthCheck_Run().
; @returns {String}
HealthCheck_FormatPlain(Snapshot) {
	Out := "ErgoptiPlus — " . Snapshot["driver"] . " — " . Snapshot["generated_at"]
	for SectionId, Section in Snapshot["sections"] {
		if !(Section is Map)
			continue
		for Key, Value in Section
			Out .= "`r`n" . SectionId . "." . Key . ": " . _HealthCheck_PlainValue(Value)
	}
	return Out
}

; One value of the plain-text report.
; @param Value {Any}
; @returns {String}
_HealthCheck_PlainValue(Value) {
	if (Value is Array) {
		Parts := ""
		for Index, Item in Value
			Parts .= (Index > 1 ? " | " : "") . _HealthCheck_PlainValue(Item)
		return Parts
	}
	if (Value is Map) {
		Parts := ""
		for Key, Item in Value
			Parts .= (Parts == "" ? "" : ", ") . Key . "=" . _HealthCheck_PlainValue(Item)
		return Parts
	}
	return StrReplace(StrReplace(String(Value), "`r", " "), "`n", " ")
}

; True when a schema entry (a section, a field or a probe) applies to a driver.
; @param Entry {Map}
; @param Driver {String}
; @returns {Boolean}
_HealthCheck_Applies(Entry, Driver := "windows") {
	if !Entry.Has("platforms")
		return true
	for Platform in Entry["platforms"]
		if (Platform == Driver)
			return true
	return false
}

; True when a probe fills the field on a driver.
; @param Field {Map}
; @param Driver {String}
; @returns {Boolean}
_HealthCheck_HasProbe(Field, Driver) {
	if !Field.Has("probe")
		return false
	Probe := Field["probe"]
	return (Probe is String) || ((Probe is Map) && Probe.Has(Driver))
}

; Compares a snapshot with the schema, as healthcheck.snapshot.check_fields
; does for the Lua drivers: the fields produced that the schema does not
; declare for its driver (drift: the page would never show them), and the declared
; synchronous fields that are absent (shown as unknown). The driver is the
; snapshot's own, so the shared vectors replay every driver's rules.
; @param Snapshot {Map}
; @param Schema {Map}
; @returns {Map} { undeclared: Array, missing: Array } of "section" or "section.field", sorted.
HealthCheck_CheckFields(Snapshot, Schema) {
	Driver := Snapshot["driver"]
	Declared := Map()
	for Section in Schema["sections"]
		if _HealthCheck_Applies(Section, Driver)
			Declared[Section["id"]] := Section
	Undeclared := ""
	Missing := ""
	Sections := Snapshot.Get("sections", Map())
	for Id, Data in Sections {
		if !Declared.Has(Id) {
			Undeclared .= Id . "`n"
			continue
		}
		Section := Declared[Id]
		if (Section.Get("kind", "fields") != "fields") || !(Data is Map)
			continue
		Fields := Map()
		for Field in Section.Get("fields", [])
			if _HealthCheck_Applies(Field, Driver)
				Fields[Field["id"]] := Field
		for FieldId in Data
			if !Fields.Has(FieldId)
				Undeclared .= Id . "." . FieldId . "`n"
		for FieldId, Field in Fields {
			Optional := Field.Get("opt_in", false) || _HealthCheck_HasProbe(Field, Driver)
			if !Data.Has(FieldId) && !Optional
				Missing .= Id . "." . FieldId . "`n"
		}
	}
	for Id, Section in Declared
		if (Section.Get("kind", "fields") != "summary") && !Sections.Has(Id)
			Missing .= Id . "`n"
	return Map("undeclared", _HealthCheck_SortedLines(Undeclared), "missing", _HealthCheck_SortedLines(Missing))
}

; The non-empty lines of a text, sorted, as an Array.
; @param Text {String}
; @returns {Array}
_HealthCheck_SortedLines(Text) {
	Text := Trim(Text, "`n")
	return (Text == "") ? [] : StrSplit(Sort(Text, "C"), "`n")
}





; =============================
; =============================
; ======= 4/ The Window =======
; =============================
; =============================

; The window's size: the manifest's healthcheck entry
; (_shared/ui/apps.manifest.json), pinned by test-webview-geometry-single-source.
; Wide enough for a path to stay on one line (test-healthcheck-page).
global HC_WIDTH  := 1060
global HC_HEIGHT := 720

; The fallback export row is reserved below the structured tree.
global HC_NATIVE_EXPORT_ROW := 38
global HC_NATIVE_EXPORT_MARGIN := 6

; Virtual host for the shared page — maps _SharedDir so relative assets
; (style.css, script.js, ../dom_utils.js) and the locale files resolve over https.
global HC_VHOST             := "ergopti.healthcheck"
global HC_HOST_ACCESS_ALLOW := 1

; WebView2 plumbing — subscription handles of the open window.
global _HC_Controller := unset
global _HC_WebView    := unset
global _HC_MsgSub     := unset
global _HC_WindowEpoch := 0

; The host window itself. Without it the singleton bookkeeping was split in half:
; the controller lived in a global, the Gui was a function-local, and _HC_Close
; could only reach the half it could see — so "close the previous singleton" left
; the previous window on screen with a dead blank pane.
global _HC_Gui := unset

; True once _HC_Reset() has torn the controller down — guards against
; double-close (same SEH access-violation pattern as action_picker_webview.ahk).
global _HC_ResetDone := false

; The page session of the open window: its epoch, its snapshot, whether
; details are included and the mode it opened in (0 when closed).
global _HC_Session := 0
; One retained controller; navigation renews the document and every session.
global _HC_ReuseKey := ""
global _HC_OpenStarted := 0
global _HC_Opening := false
global _HC_PendingMode := unset
global _HC_RequestSerial := 0
global _HC_PendingSerial := 0
global _HC_CloseDuringOpen := false
global _HC_Retiring := false

_HC_CanReuse(Key) {
	global _HC_Gui, _HC_Controller, _HC_WebView, _HC_ResetDone, _HC_ReuseKey
	if _HC_ResetDone || !IsSet(_HC_Gui) || !IsSet(_HC_Controller) || !IsSet(_HC_WebView)
		return false
	return _HC_ReuseKey == Key && WMHandleExists(_HC_Gui.Hwnd)
}

/** A newer open or close supersedes a request queued during native setup. */
_HC_ResumePending(Mode, Serial) {
	global _HC_RequestSerial
	if Serial != _HC_RequestSerial
		return
	HealthCheck_ShowWindow(Mode)
}

; Keep native title construction with the GUI owner, independent of diagnostics collection.
_HC_NewWindow() {
	return Gui_Create("+Resize +MinSize640x480", t("menu.debug.healthcheck"))
}

/** Attributes diagnostics opening without retaining snapshot or foreground contents. */
_HC_OpenTimingMark(Phase, Timing) {
	Wall := BootClockWallMs()
	Cpu := BootClockCpuMs()
	MenuWait := BootProfile_MenuWaitMs()
	Elapsed := Wall - Timing.Wall
	CpuText := (Cpu < 0 || Timing.Cpu < 0) ? "unknown" : Format("{:.3f}", Cpu - Timing.Cpu)
	HotPath_RecordLatency("Diagnostics." . Phase, Elapsed, 5)
	try LoggerInfo("Healthcheck", Format(
		"Diagnostics stage '{1}': wall={2:.3f} ms, process_cpu={3} ms, native_menu_wait={4:.3f} ms.",
		Phase, Elapsed, CpuText, Max(0, MenuWait - Timing.MenuWait)))
	Timing.Wall := Wall
	Timing.Cpu := Cpu
	Timing.MenuWait := MenuWait
}

; Opens the diagnostics window, replacing any previous one.
; @param Mode {String} "report" opens it at the preview and the report button.
HealthCheck_ShowWindow(Mode := "") {
	global _VendorDir, _SharedDir, _I18nLocale, HC_WIDTH, HC_HEIGHT, HC_VHOST, HC_HOST_ACCESS_ALLOW
	global _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_ResetDone, _HC_Gui
	global _HC_WindowEpoch, _HC_Session, _HC_ReuseKey, _HC_OpenStarted

	global _HC_Opening, _HC_PendingMode, _HC_CloseDuringOpen, _HC_Retiring
	global _HC_RequestSerial, _HC_PendingSerial
	_HC_RequestSerial += 1
	if _HC_Opening || _HC_Retiring {
		_HC_PendingMode := Mode
		_HC_PendingSerial := _HC_RequestSerial
		LoggerDebug("Healthcheck", "Diagnostics opening already in progress; latest request retained.")
		return
	}
	_HC_Opening := true
	_HC_CloseDuringOpen := false
	try {
		LoggerStart("Healthcheck", "Opening the diagnostics window…")
		_HC_OpenStarted := _HealthCheck_NowMs()
		Timing := { Wall: BootClockWallMs(), Cpu: BootClockCpuMs(), MenuWait: BootProfile_MenuWaitMs() }
		Locale := IsSet(_I18nLocale) ? _I18nLocale : "en"
		ReuseKey := _SharedDir . "`n" . Locale
		Reuse := _HC_CanReuse(ReuseKey)
		if Reuse
			_HealthCheck_CloseGui(_HC_Gui, false)
		else
			_HC_Close()
		Snapshot := HealthCheck_Run()
		_HC_OpenTimingMark("snapshot", Timing)

		if Reuse {
			G := _HC_Gui
			ContentCtl := G.ContentCtl
			G.Show()
		} else {
			G := _HC_NewWindow()
			G.MarginX := 0
			G.MarginY := 0
			ContentCtl := G.Add("Text", "x0 y0 w" . HC_WIDTH . " h" . HC_HEIGHT, "")
			G.ContentCtl := ContentCtl
			G.WVC := 0
			G.OnEvent("Close",  (*) => _HealthCheck_CloseGui(G))
			G.OnEvent("Escape", (*) => _HealthCheck_CloseGui(G))
			G.OnEvent("Size",   _HC_OnSize.Bind(ContentCtl))
			G.Show("w" . HC_WIDTH . " h" . HC_HEIGHT)
		}
		; Publish the host window so the next open can actually destroy this one.
		_HC_Gui := G
		LoggerInfo("Healthcheck", "Diagnostics host shown in {1} ms (reused={2}).",
			Round(_HealthCheck_NowMs() - _HC_OpenStarted, 2), Reuse ? 1 : 0)
		_HC_OpenTimingMark("host", Timing)

		UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
		if UseWV {
			loader := _VendorDir . "\64bit\WebView2Loader.dll"
			WVC := 0
			try {
				Environment := WebView_SharedEnvironment(loader)
				_HC_OpenTimingMark("environment", Timing)
				WVC := Reuse ? _HC_Controller : WebView2.create(ContentCtl.Hwnd, , Environment)
				_HC_OpenTimingMark("controller_create", Timing)
				WVC.IsVisible := false
				; Virtual-host subresources survive navigation, including same-size edits.
				WebView_ClearDocumentCache(WVC.CoreWebView2)
				_HC_OpenTimingMark("document_cache", Timing)
				G.WVC := WVC
			} catch as Err {
				if Reuse
					_HC_Reset()
				else if WVC
					WVC.Close()
				WVC := 0
				G.WVC := 0
				LoggerWarn("Healthcheck", "WebView2 create failed: {1} — showing structured native diagnostics.", Err.Message)
			}

			_HC_OpenTimingMark("controller", Timing)
			if WVC {
				_HC_Controller := WVC
				_HC_WebView    := WVC.CoreWebView2
				_HC_ResetDone  := false
				_HC_ReuseKey := ReuseKey
				_HC_WindowEpoch += 1
				WindowEpoch := _HC_WindowEpoch
				PageUrl := "https://" . HC_VHOST . "/ui/healthcheck/index.html?cb=" . A_TickCount . "&epoch=" . WindowEpoch
				_HC_Session := Map("epoch", WindowEpoch, "snapshot", Snapshot, "detailed", false, "extensive", false, "mode", Mode,
					"page_url", PageUrl)

				try {
					s := _HC_WebView.Settings
					s.AreDevToolsEnabled              := false
					s.AreDefaultContextMenusEnabled   := false
					s.IsStatusBarEnabled              := false
					s.AreBrowserAcceleratorKeysEnabled := false
				}

				; The locale base and code before the page scripts run: i18n.js fetches
				; the strings through the virtual host
				if !Reuse
					try _HC_WebView.AddScriptToExecuteOnDocumentCreated(
						"window.__i18n_base='https://" . HC_VHOST . "/data/locales/';window._i18n_locale='" . Locale . "';")

				; The subscription is bound to this window's epoch, so a late message of
				; a closed window cannot reach its replacement through the globals.
				_HC_MsgSub := _HC_WebView.WebMessageReceived(_HC_OnWebMessage.Bind(WindowEpoch))
				_HC_OpenTimingMark("bindings", Timing)

				; Map the virtual host BEFORE navigating.
				try _HC_WebView.SetVirtualHostNameToFolderMapping(HC_VHOST, _SharedDir, HC_HOST_ACCESS_ALLOW)
				try _HC_WebView.Navigate(PageUrl)
				try _HC_Controller.Fill()
				if _HC_CloseDuringOpen
					_HealthCheck_CloseGui(G, false)
				LoggerInfo("Healthcheck", "Diagnostics controller prepared in {1} ms (reused={2}).",
					Round(_HealthCheck_NowMs() - _HC_OpenStarted, 2), Reuse ? 1 : 0)
				_HC_OpenTimingMark("navigate", Timing)

				LoggerSuccess("Healthcheck", "Diagnostics window opened with the shared page.")
				return
			}
		}

		ContentCtl.Visible := false
		_HC_ShowNativeSnapshot(G, Snapshot)
		_HC_OpenTimingMark("native_controls", Timing)
		LoggerSuccess("Healthcheck", "Diagnostics window opened with structured native controls.")
	} finally {
		if IsSet(Timing)
			HotPath_RecordLatency("Diagnostics.total", _HealthCheck_NowMs() - _HC_OpenStarted, 5)
		_HC_Opening := false
		if IsSet(_HC_PendingMode) {
			PendingMode := _HC_PendingMode
			_HC_PendingMode := unset
			TimerArmOneShotMs(_HC_ResumePending.Bind(PendingMode, _HC_PendingSerial), 1)
		}
	}
}

; Builds a readable native view when the installed browser really cannot open.
; @param G {Gui} The diagnostics host window.
; @param Snapshot {Map} The same snapshot supplied to the shared page.
_HC_ShowNativeSnapshot(G, Snapshot) {
	global HC_WIDTH, HC_HEIGHT, HC_NATIVE_EXPORT_ROW, HC_NATIVE_EXPORT_MARGIN
	Tree := G.Add("TreeView", "x0 y0 w" . HC_WIDTH . " h" . (HC_HEIGHT - HC_NATIVE_EXPORT_ROW) . " +HScroll")
	G.NativeDiagnostics := Tree
	NativeSave := G.Add("Button", "x8 y" . (HC_HEIGHT - HC_NATIVE_EXPORT_ROW + HC_NATIVE_EXPORT_MARGIN)
		. " w160", t("healthcheck.toolbar.save"))
	NativeSave.OnEvent("Click", _HC_NativeSaveSnapshot.Bind(Snapshot))
	Summary := Tree.Add(t("healthcheck.section.summary"), 0, "Bold Expand")
	_HC_NativeAddValue(Tree, t("healthcheck.export.driver"), Snapshot["driver"], Summary)
	_HC_NativeAddValue(Tree, t("healthcheck.export.generated"), Snapshot["generated_at"], Summary)
	for Definition in HealthCheck_Config()["schema"]["sections"] {
		Id := Definition["id"]
		if !Snapshot["sections"].Has(Id) || !_HealthCheck_Applies(Definition)
			continue
		Section := Snapshot["sections"][Id]
		Parent := Tree.Add(t("healthcheck.section." . Id), 0, "Bold Expand")
		if Definition.Has("fields") {
			for Field in Definition["fields"] {
				Key := Field["id"]
				if Section.Has(Key) && _HealthCheck_Applies(Field)
					_HC_NativeAddValue(Tree, t("healthcheck.field." . Key), Section[Key], Parent)
			}
		} else {
			for Key, Value in Section
				_HC_NativeAddValue(Tree, Key, Value, Parent)
		}
	}
	return Tree
}

/** Formats the quick native report with an explicit unexecuted-test status. */
_HC_NativeSnapshotText(Snapshot) {
	Status := StrReplace(t("healthcheck.probe.not_run"), "%s", t("healthcheck.deep_tests.reason.not_embedded"))
	return HealthCheck_FormatPlain(Snapshot) . "`n" . t("healthcheck.deep_tests.title") . ": " . Status
}

/** Exports the captured quick fallback without browser-dependent checks. */
_HC_NativeSaveSnapshot(Snapshot, *) {
	Config := HealthCheck_Config()
	Name := Config["schema"]["report"]["name_prefix"] . "windows-" . FormatTime(A_NowUTC, "yyyyMMdd-HHmmss")
		. Config["schema"]["report"]["name_suffix"]
	Text := _HC_NativeSnapshotText(Snapshot)
	Validated := HealthCheck_ValidateAction(Map("action", "save", "text", Text, "name", Name),
		Map("schema", Config["schema"], "templates", Config["templates"], "driver", "windows"))
	if !Validated.Has("action")
		throw Error("The native diagnostic export was refused.")
	return HealthCheck_PerformAction(Validated["action"], Snapshot["sections"]["paths"], Config)
}

; Keeps arrays and records expandable, including each recent log entry.
; @param Tree {Gui.TreeView} The native diagnostics view.
; @param Label {String} The translated field name or record key.
; @param Value {Any} The snapshot value.
; @param Parent {Integer} The enclosing section or record.
_HC_NativeAddValue(Tree, Label, Value, Parent) {
	if Value is Array || Value is Map {
		Node := Tree.Add(Label, Parent, "Expand")
		for Key, Item in Value
			_HC_NativeAddValue(Tree, String(Key), Item, Node)
		return Node
	}
	return Tree.Add(Label . ": " . _HealthCheck_PlainValue(Value), Parent)
}

; Keeps the page filling the window when it is resized.
; @param ContentCtl {Gui.Text} The WebView2 host control.
_HC_OnSize(ContentCtl, GuiObj, MinMax, Width, Height) {
	global _HC_Controller, _HC_ResetDone
	if (MinMax == -1)
		return
	ContentCtl.Move(0, 0, Width, Height)
	if GuiObj.HasProp("NativeDiagnostics")
		GuiObj.NativeDiagnostics.Move(0, 0, Width, Height)
	if !_HC_ResetDone && IsSet(_HC_Controller)
		try _HC_Controller.Fill()
}

_HealthCheck_CloseGui(G, UserRequest := true) {
	global _HC_Gui, _HC_Controller, _HC_MsgSub, _HC_WindowEpoch, _HC_Session
	global _HC_Opening, _HC_CloseDuringOpen, _HC_Retiring, _HC_PendingMode
	global _HC_RequestSerial, _HC_PendingSerial
	if !IsSet(_HC_Gui) || !(G == _HC_Gui) || _HC_Retiring
		return 1
	if UserRequest {
		_HC_RequestSerial += 1
		_HC_PendingMode := unset
	}
	if _HC_Opening && UserRequest
		_HC_CloseDuringOpen := true
	_HC_Retiring := true
	try {
		_HC_WindowEpoch += 1
		_HC_Session := 0
		HealthCheck_CancelProbes()
		_HC_MsgSub := unset
		if IsSet(_HC_Controller)
			_HC_Controller.IsVisible := false
		G.Hide()
		LoggerDebug("Healthcheck", "Diagnostics session retired; native host retained.")
	} catch as Err {
		_HC_Close()
		LoggerError("Healthcheck", "Diagnostics host retention failed: {1}.", Err.Message)
		throw Err
	} finally {
		_HC_Retiring := false
		if !_HC_Opening && IsSet(_HC_PendingMode) {
			PendingMode := _HC_PendingMode
			_HC_PendingMode := unset
			TimerArmOneShotMs(_HC_ResumePending.Bind(PendingMode, _HC_PendingSerial), 1)
		}
	}
	return 1
}

; ── WebView2 messages ───────────────────────────────────────────────────────

; Receives the page's messages. WebMessageReceived is a COM callback: the
; message is read here and handled on a fresh stack, bound to the window that
; received it. The callback bypasses native Suspend, and deliberately: the
; diagnostics page changes nothing ErgoptiPlus does, and the pause is often why
; the user opened it, so every action stays available while suspended.
_HC_OnWebMessage(WindowEpoch, Handler, Args) {
	global _HC_WindowEpoch, _HC_ResetDone, _HC_Session
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !(_HC_Session is Map)
		return
	try {
		if !(Args.Source == _HC_Session["page_url"])
			return
		Raw := Args.TryGetWebMessageAsString()
	}
	catch as Err {
		LoggerWarn("Healthcheck", "A diagnostics page message could not be read: {1}.", Err.Message)
		return
	}
	if A_IsSuspended
		LoggerDebug("Healthcheck", "A diagnostics page message arrived while suspended; the page stays usable.")
	SetTimer(_HC_HandleMessage.Bind(WindowEpoch, Raw), -1)
}

; Handles one message of the page, on its own stack.
; @param WindowEpoch {Integer} The window that received it.
; @param Raw {String} The message as the page posted it.
_HC_HandleMessage(WindowEpoch, Raw) {
	global _HC_WindowEpoch, _HC_ResetDone, _HC_Session, _HC_Controller, _HC_OpenStarted
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !(_HC_Session is Map)
		return
	if (Raw == "ready") {
		LoggerInfo("Healthcheck", "Diagnostics page ready in {1} ms.",
			Round(_HealthCheck_NowMs() - _HC_OpenStarted, 2))
		try {
			_HC_Send(WindowEpoch, _HC_InitJson(_HC_Session))
			_HC_Controller.IsVisible := true
			_HC_RestartProbes(WindowEpoch)
		} catch as Err {
			LoggerError("Healthcheck", "The diagnostics page could not be initialised: {1}", Err.Message)
		}
		return
	}
	try Message := JsonParse(Raw)
	catch as Err {
		LoggerWarn("Healthcheck", "Refused a diagnostics page message that is not JSON: {1}.", Err.Message)
		return
	}
	Config := HealthCheck_Config()
	Result := HealthCheck_ValidateAction(Message, Map("schema", Config["schema"], "templates", Config["templates"],
		"driver", "windows"))
	if Result.Has("reason") {
		LoggerWarn("Healthcheck", "Refused a diagnostics page action ({1}).", Result["reason"])
		return
	}
	Action := Result["action"]
	LoggerInfo("Healthcheck", "Diagnostics page action: {1}.", Action["action"])
	; An exception on a timer thread would reach the global error handler as a
	; crash: it is logged here and the page is told its button did nothing
	try {
		_HC_PerformPageAction(WindowEpoch, Action, Config)
	} catch as Err {
		LoggerError("Healthcheck", "The diagnostics action '{1}' failed: {2}", Action["action"], Err.Message)
		_HC_Send(WindowEpoch, '{"type":"action","action":' . _HC_JsStr(Action["action"]) . ',"ok":false}')
	}
}

; Retains diagnostic metadata only; lower HTTP owners retain actual capabilities.
; @param Session {Map} The exact window session being refreshed.
_HC_ArchiveCleanupMetadata(Session) {
	Rows := Map()
	for Id, Result in Session["snapshot"]["probes"] {
		if Result.Get("state", "") == "pending" {
			Result := Result.Clone()
			Result["state"] := "cancelled"
			Result["cleanup"] := "pending"
		}
		if Result.Has("cleanup") && Result["cleanup"] != "settled"
			Rows[Id] := Result.Clone()
	}
	History := Session.Get("cleanup_history", [])
	if Rows.Count
		History.Push(Map("probes", Rows))
	Session["cleanup_history"] := History
}

; Performs one validated action of the page and answers it.
; @param WindowEpoch {Integer}
; @param Action {Map} From HealthCheck_ValidateAction.
; @param Config {Map} From HealthCheck_Config().
_HC_PerformPageAction(WindowEpoch, Action, Config) {
	global _HC_Session
	switch Action["action"] {
		case "close":
			global _HC_Gui
			_HealthCheck_CloseGui(_HC_Gui)
		case "export_snapshot":
			_HC_Send(WindowEpoch, _HC_ValueToJson(Map("type", "action", "action", "export_snapshot",
				"ok", true, "export_sequence", Action["export_sequence"], "snapshot", _HC_Session["snapshot"])))
		case "cancel":
			HealthCheck_CancelProbes()
			for CancelledProbe in _HC_Session["snapshot"]["probes"] {
				ProbeResult := _HC_Session["snapshot"]["probes"][CancelledProbe]
				if ProbeResult.Get("state", "") == "pending"
					_HC_Session["snapshot"]["probes"][CancelledProbe] := Map("state", "cancelled", "cleanup", "pending")
			}
			_HC_Send(WindowEpoch, '{"type":"action","action":"cancel","ok":true,"snapshot":' . _HC_ValueToJson(_HC_Session["snapshot"]) . '}')
		case "refresh":
			HealthCheck_CancelProbes()
			_HC_ArchiveCleanupMetadata(_HC_Session)
			_HC_Session["extensive"] := Action["extensive"]
			_HC_Session["detailed"] := Action["detailed"]
			_HC_Session["snapshot"] := HealthCheck_Run(Action["detailed"], Action["extensive"])
			_HC_Session["snapshot"]["retired_probes"] := _HC_Session.Get("cleanup_history", [])
			_HC_Send(WindowEpoch, '{"type":"snapshot","snapshot":' . _HC_ValueToJson(_HC_Session["snapshot"]) . '}')
			_HC_RestartProbes(WindowEpoch)
		default:
			Outcome := HealthCheck_PerformAction(Action, _HC_Session["snapshot"]["sections"]["paths"], Config)
			Json := '{"type":"action","action":' . _HC_JsStr(Action["action"])
				. ',"ok":' . (Outcome["ok"] ? "true" : "false")
			if Outcome.Has("path")
				Json .= ',"path":' . _HC_JsStr(Outcome["path"])
			if Outcome.Get("missing", false)
				Json .= ',"missing":true'
			_HC_Send(WindowEpoch, Json . '}')
	}
}

; The page's first message: its configuration and the first snapshot. The
; schema and the redaction rules go as their files are; the redaction context
; is written by hand so its flag is a JSON true, not the 1 AHK stores.
; @param Session {Map}
; @returns {String}
_HC_InitJson(Session) {
	Config := HealthCheck_Config()
	Context := HealthCheck_RedactionContext()
	return '{"type":"init","config":{"schema":' . Config["raw_schema"]
		. ',"redaction":' . Config["raw_redaction"]
		. ',"context":{"home":' . _HC_JsStr(Context["home"]) . ',"user":' . _HC_JsStr(Context["user"])
		. ',"case_insensitive":true},"mode":' . _HC_JsStr(Session["mode"])
		. '},"snapshot":' . _HC_ValueToJson(Session["snapshot"]) . '}'
}

; Sends one message into the window's page.
; @param WindowEpoch {Integer}
; @param Json {String} The message, as JSON.
_HC_Send(WindowEpoch, Json) {
	global _HC_WebView, _HC_WindowEpoch, _HC_ResetDone, _HC_Session
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !IsSet(_HC_WebView) || !(_HC_Session is Map)
		return
	WebView_RunScriptAsync(_HC_WebView,
		"if(location.href===" . JsonStringLiteral(_HC_Session["page_url"])
			. "&&window.receiveDiagnostics)window.receiveDiagnostics(" . Json . ")",
		"HealthCheck")
}

; Restarts the probes of the window's snapshot; each answer is kept in the
; snapshot and pushed into the same window only.
; @param WindowEpoch {Integer}
_HC_RestartProbes(WindowEpoch, StartFn := unset) {
	global _HC_Session
	HealthCheck_CancelProbes()
	Selected := _HC_Session.Get("extensive", false)
	if !(Selected is Integer) || (Selected != 0 && Selected != 1)
		throw TypeError("The diagnostics session has an invalid extensive selection.")
	if !Selected
		return false
	if IsSet(StartFn) {
		if !HasMethod(StartFn, "Call")
			throw TypeError("The diagnostics starter must be callable.")
		return StartFn.Call(WindowEpoch, HealthCheck_Config()["schema"], _HC_PublishProbe)
	}
	HealthCheck_StartProbes(WindowEpoch, HealthCheck_Config()["schema"], _HC_PublishProbe)
	return true
}

; Publishes one probe's answer into its window.
; @param WindowEpoch {Integer}
; @param Id {String}
; @param Result {Map} { state, ms, detail? }
; @param Sections {Map} Values the probe filled, by section.
_HC_PublishProbe(WindowEpoch, Id, Result, Sections) {
	global _HC_WindowEpoch, _HC_Session
	if (WindowEpoch != _HC_WindowEpoch) || !(_HC_Session is Map)
		return
	Report := Result.Get("network_report", 0)
	if Result.Has("network_report")
		Result.Delete("network_report")
	Snapshot := _HC_Session["snapshot"]
	Snapshot["probes"][Id] := Result
	for SectionId, Values in Sections {
		for Key, Value in Values
			Snapshot["sections"][SectionId][Key] := Value
	}
	_HC_Send(WindowEpoch, '{"type":"probe","id":' . _HC_JsStr(Id) . ',"result":' . _HC_ValueToJson(Result)
		. ',"sections":' . _HC_ValueToJson(Sections) . '}')
	if ManagedNetworkFailureWindows_CanonicalReport(Report)
		_HC_ShowManagedFailure(WindowEpoch, Id, Result, Report)
}

; Converts an AHK value to JSON: Maps become objects, Arrays arrays, numbers
; stay numbers (true and false are the 1 and 0 AHK stores).
_HC_ValueToJson(Val) {
	if !IsSet(Val)
		return "null"
	if (Val is String)
		return _HC_JsStr(Val)
	if (Val is Number)
		return String(Val)
	if (Val is Array) {
		Parts := []
		for _, Item in Val
			Parts.Push(_HC_ValueToJson(Item))
		return "[" . _HC_Join(Parts, ",") . "]"
	}
	if (Val is Map) {
		Parts := []
		for Key, Item in Val {
			Parts.Push(_HC_JsStr(Key) . ":" . _HC_ValueToJson(Item))
		}
		return "{" . _HC_Join(Parts, ",") . "}"
	}
	return _HC_JsStr(String(Val))
}

_HC_JsStr(s) {
	return JsonStringLiteral(s)
}

_HC_Join(Arr, Sep) {
	Out := ""
	for i, S in Arr
		Out .= (i > 1 ? Sep : "") . S
	return Out
}

; Closes the previous healthcheck singleton — controller AND window.
;
; This used to call _HC_Reset() alone, which only closes the CONTROLLER. The host
; Gui was a function-local that no global held, so nothing could destroy it: the
; previous window stayed on screen with a dead blank pane while a second one
; opened on top, once per menu click. Worse, closing one of those stale windows
; ran _HC_Reset again — and since every successful WebView2 create re-arms
; _HC_ResetDone, that second pass closed the LIVE controller of the window the
; user was actually reading.
_HC_Close() {
	global _HC_Gui
	; Save the reference BEFORE the reset, close the controller while its host
	; HWND is still alive, and only then destroy the window — the ordering the
	; WebView2 spec requires, and the one _CLW_OnClose / _LLM_MBW_OnClose use.
	saved_gui := IsSet(_HC_Gui) ? _HC_Gui : 0
	_HC_Reset()
	try {
		if saved_gui
			saved_gui.Destroy()
	}
	_HC_Gui := unset   ; Always clear the reference, even if Destroy threw
}

_HC_Reset() {
	ManagedNetworkTerminalFailure.Retire("diagnostics")
	global _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_ResetDone
	global _HC_WindowEpoch, _HC_Session, _HC_ReuseKey

	if _HC_ResetDone
		return
	_HC_ResetDone := true
	_HC_WindowEpoch += 1
	_HC_Session := 0
	_HC_ReuseKey := ""
	HealthCheck_CancelProbes()

	try {
		_HC_MsgSub := unset
		if IsSet(_HC_Controller)
			_HC_Controller.Close()
	}
	_HC_Controller := unset
	_HC_WebView    := unset
}

_HC_ManagedTerminalCurrent(Owner) {
	global _HC_WindowEpoch, _HC_ResetDone, _HC_Session, _HC_ProbeRun
	return !_HC_ResetDone && _HC_WindowEpoch == Owner.epoch && _HC_Session == Owner.session
		&& _HC_Session is Map && _HC_ProbeRun == Owner.run && IsObject(Owner.run) && !Owner.run.Cancelled
		&& _HC_Session["snapshot"]["probes"].Get(Owner.id, 0) == Owner.result && !A_IsSuspended
}

_HC_ShowManagedFailure(WindowEpoch, Id, Result, Report, PresentFn := 0) {
	global _HC_Session, _HC_ProbeRun
	Owner := {epoch: WindowEpoch, session: _HC_Session, run: _HC_ProbeRun, id: Id, result: Result}
	return ManagedNetworkTerminalFailure.Publish("diagnostics", Report,
		() => _HC_ManagedTerminalCurrent(Owner), "healthcheck.section.network", () => _HC_RetryManaged(Owner), PresentFn)
}

_HC_RetryManaged(Owner) {
	if !_HC_ManagedTerminalCurrent(Owner)
		return false
	global _HC_ProbeRun, _HC_WindowEpoch, _HC_ResetDone
	_HC_RestartProbes(Owner.epoch)
	return !_HC_ResetDone && _HC_WindowEpoch == Owner.epoch && IsObject(_HC_ProbeRun)
		&& _HC_ProbeRun != Owner.run && !_HC_ProbeRun.Cancelled
}
