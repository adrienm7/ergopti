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
; 4. Without WebView2 the window shows the snapshot as plain text in a
;    read-only field: the report stays readable and copyable by hand.
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
_HealthCheck_PendingProbes(Schema) {
	Probes := Map()
	for Id, Probe in Schema["probes"]
		if _HealthCheck_Applies(Probe)
			Probes[Id] := Map("state", "pending")
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
HealthCheck_Run(Detailed := false) {
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
	Probes      := _HealthCheck_PendingProbes(Schema)

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
global HC_WIDTH  := 860
global HC_HEIGHT := 720

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

; Keep native title construction with the GUI owner, independent of diagnostics collection.
_HC_NewWindow() {
	return Gui_Create("+Resize +MinSize640x480", t("menu.debug.healthcheck"))
}

; Opens the diagnostics window, replacing any previous one.
; @param Mode {String} "report" opens it at the preview and the report button.
HealthCheck_ShowWindow(Mode := "") {
	global _VendorDir, _SharedDir, _I18nLocale, HC_WIDTH, HC_HEIGHT, HC_VHOST, HC_HOST_ACCESS_ALLOW
	global _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_ResetDone, _HC_Gui
	global _HC_WindowEpoch, _HC_Session

	LoggerStart("Healthcheck", "Opening the diagnostics window…")
	; Close any previous singleton before opening a new one.
	_HC_Close()
	Snapshot := HealthCheck_Run()

	G := _HC_NewWindow()
	G.MarginX := 0
	G.MarginY := 0
	ContentCtl := G.Add("Text", "x0 y0 w" . HC_WIDTH . " h" . HC_HEIGHT, "")
	G.WVC := 0
	G.OnEvent("Close",  (*) => _HealthCheck_CloseGui(G))
	G.OnEvent("Escape", (*) => _HealthCheck_CloseGui(G))
	G.OnEvent("Size",   _HC_OnSize.Bind(ContentCtl))
	G.Show("w" . HC_WIDTH . " h" . HC_HEIGHT)
	; Publish the host window so the next open can actually destroy this one.
	_HC_Gui := G

	UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !WebView_ShouldUseNativeFallback()
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		WVC := 0
		try {
			WVC := WebView2.create(ContentCtl.Hwnd, , WebView_SharedEnvironment(loader))
			G.WVC := WVC
		} catch as Err {
			LoggerWarn("Healthcheck", "WebView2 create failed: {1} — showing the plain-text report.", Err.Message)
		}

		if WVC {
			_HC_Controller := WVC
			_HC_WebView    := WVC.CoreWebView2
			_HC_ResetDone  := false
			_HC_WindowEpoch += 1
			WindowEpoch := _HC_WindowEpoch
			_HC_Session := Map("epoch", WindowEpoch, "snapshot", Snapshot, "detailed", false, "mode", Mode)

			try {
				s := _HC_WebView.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
			}

			; The locale base and code before the page scripts run: i18n.js fetches
			; the strings through the virtual host
			Locale := IsSet(_I18nLocale) ? _I18nLocale : "en"
			try _HC_WebView.AddScriptToExecuteOnDocumentCreated(
				"window.__i18n_base='https://" . HC_VHOST . "/data/locales/';window._i18n_locale='" . Locale . "';")

			; The subscription is bound to this window's epoch, so a late message of
			; a closed window cannot reach its replacement through the globals.
			_HC_MsgSub := _HC_WebView.WebMessageReceived(_HC_OnWebMessage.Bind(WindowEpoch))

			; Map the virtual host BEFORE navigating.
			try _HC_WebView.SetVirtualHostNameToFolderMapping(HC_VHOST, _SharedDir, HC_HOST_ACCESS_ALLOW)
			try _HC_WebView.Navigate("https://" . HC_VHOST . "/ui/healthcheck/index.html?cb=" . A_TickCount)
			try _HC_Controller.Fill()

			LoggerSuccess("Healthcheck", "Diagnostics window opened with the shared page.")
			return
		}
	}

	; Without WebView2: the snapshot as plain text in a read-only field
	ContentCtl.GetPos(&X, &Y, &W, &H)
	EditCtl := G.Add("Edit", "x" . X . " y" . Y . " w" . W . " h" . H . " ReadOnly Multi -Wrap +VScroll",
		HealthCheck_FormatPlain(Snapshot))
	EditCtl.SetFont("s9", "Consolas")
	LoggerSuccess("Healthcheck", "Diagnostics window opened as plain text (no WebView2).")
}

; Keeps the page filling the window when it is resized.
; @param ContentCtl {Gui.Text} The WebView2 host control.
_HC_OnSize(ContentCtl, GuiObj, MinMax, Width, Height) {
	global _HC_Controller, _HC_ResetDone
	if (MinMax == -1)
		return
	ContentCtl.Move(0, 0, Width, Height)
	if !_HC_ResetDone && IsSet(_HC_Controller)
		try _HC_Controller.Fill()
}

_HealthCheck_CloseGui(G) {
	global _HC_Gui
	_HC_Reset()
	if G.HasProp("WVC") && G.WVC
		try G.WVC.Close()
	try G.Destroy()
	; Drop the singleton handle so a later _HC_Close cannot Destroy() a window
	; that is already gone.
	_HC_Gui := unset
}

; ── WebView2 messages ───────────────────────────────────────────────────────

; Receives the page's messages. WebMessageReceived is a COM callback: the
; message is read here and handled on a fresh stack, bound to the window that
; received it. The callback bypasses native Suspend, and deliberately: the
; diagnostics page changes nothing ErgoptiPlus does, and the pause is often why
; the user opened it, so every action stays available while suspended.
_HC_OnWebMessage(WindowEpoch, Handler, Args) {
	global _HC_WindowEpoch, _HC_ResetDone
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch)
		return
	try Raw := Args.TryGetWebMessageAsString()
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
	global _HC_WindowEpoch, _HC_ResetDone, _HC_Session
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !(_HC_Session is Map)
		return
	if (Raw == "ready") {
		LoggerInfo("Healthcheck", "Diagnostics page ready.")
		try {
			_HC_Send(WindowEpoch, _HC_InitJson(_HC_Session))
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

; Performs one validated action of the page and answers it.
; @param WindowEpoch {Integer}
; @param Action {Map} From HealthCheck_ValidateAction.
; @param Config {Map} From HealthCheck_Config().
_HC_PerformPageAction(WindowEpoch, Action, Config) {
	global _HC_Session
	switch Action["action"] {
		case "close":
			_HC_Close()
		case "refresh":
			_HC_Session["detailed"] := Action["detailed"]
			_HC_Session["snapshot"] := HealthCheck_Run(Action["detailed"])
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
	global _HC_WebView, _HC_WindowEpoch, _HC_ResetDone
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !IsSet(_HC_WebView)
		return
	WebView_RunScriptAsync(_HC_WebView, "if(window.receiveDiagnostics)window.receiveDiagnostics(" . Json . ")",
		"HealthCheck")
}

; Restarts the probes of the window's snapshot; each answer is kept in the
; snapshot and pushed into the same window only.
; @param WindowEpoch {Integer}
_HC_RestartProbes(WindowEpoch) {
	global _HC_Session
	HealthCheck_StartProbes(WindowEpoch, HealthCheck_Config()["schema"], _HC_PublishProbe)
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
	Snapshot := _HC_Session["snapshot"]
	Snapshot["probes"][Id] := Result
	for SectionId, Values in Sections {
		for Key, Value in Values
			Snapshot["sections"][SectionId][Key] := Value
	}
	_HC_Send(WindowEpoch, '{"type":"probe","id":' . _HC_JsStr(Id) . ',"result":' . _HC_ValueToJson(Result)
		. ',"sections":' . _HC_ValueToJson(Sections) . '}')
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
	global _HC_Controller, _HC_WebView, _HC_MsgSub, _HC_ResetDone
	global _HC_WindowEpoch, _HC_Session

	if _HC_ResetDone
		return
	_HC_ResetDone := true
	_HC_WindowEpoch += 1
	_HC_Session := 0
	HealthCheck_CancelProbes()

	try {
		_HC_MsgSub := unset
		if IsSet(_HC_Controller)
			_HC_Controller.Close()
	}
	_HC_Controller := unset
	_HC_WebView    := unset
}
