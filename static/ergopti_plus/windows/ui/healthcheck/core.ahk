; ui/healthcheck/core.ahk

; ==============================================================================
; MODULE: Healthcheck / Probe + Public API + Window
; DESCRIPTION:
; Module-level counters, the adapter/port registry probe, the public API
; (HealthCheck_Run / RecordError / RecordWarn / FormatMarkdown / FormatPlain /
; Format) and the WebView2 report window. The report HTML is rendered by the
; shared frontend _shared/ui/healthcheck/ (loaded via virtual host); the
; snapshot is injected as JSON after navigation completes.
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




; ===================================================
; ===================================================
; ======= 1/ Adapter & Port Registry ================
; ===================================================
; ===================================================

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




; ===================================================
; ===================================================
; ======= 2/ Public API =============================
; ===================================================
; ===================================================

; Stores an error message for later retrieval by HealthCheck_Run().
; Call from any error handler that wants healthcheck visibility.
; @param Msg {String} Human-readable error description.
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

; Probes all registered adapters and returns a Map snapshot with:
;   "version"         -> String  driver version (from Updater_CurrentVersion or "local")
;   "loaded_adapters" -> Array   adapter ids that loaded cleanly
;   "ports_validated" -> Array   adapter ids whose full contract was satisfied
;   "failed_adapters" -> Array   adapter ids that failed load or contract check
;   "last_error"      -> String  most recent error (empty string if none)
;   "uptime_sec"      -> Integer seconds since module load (_HealthCheckStartMs)
;   "warn_count"      -> Integer number of WARNING-level lines emitted this session
;   "err_count"       -> Integer number of errors recorded via HealthCheck_RecordError
;   "sys"             -> Map     OS/runtime/hardware snapshot (see _HealthCheck_SysInfo)
;   "recent_issues"   -> Array   last 50 WARNING/ERROR lines from the ring buffer
;   "pause_state"     -> Map     {is_paused, source} — project_suspend_pause_invariant friendly (read-only)
;   "keylogger"       -> Map     safe summary (events, wpm, privacy counts, log paths incl. errors sink)
;   "llm"             -> Map     backend, profile, model, basic settings (no prompts)
;   "layout"          -> Map     base/AltGr/Shift/Caps + prefix latch status (sanitized)
;   "hotstrings"      -> Map     terminators, personal/dyn counts, delays (no secrets)
;   "logs"            -> Map     unified + errors sink paths, ring info
;   "config"          -> Map     overrides count, high-level enabled counts, key paths
; @return {Map}
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

HealthCheck_Run() {
	global _HealthCheckStartMs, _HealthCheckLastError, _HealthCheckWarnCount, _HealthCheckErrCount

	try LoggerStart("Healthcheck", "Running healthcheck...")

	; Resolve driver version
	Version := "local"
	try Version := Updater_CurrentVersion()

	Specs          := _HealthCheck_Collect("adapter_specs", _HealthCheck_AdapterSpecs, Map())
	LoadedAdapters := []
	PortsValidated := []
	FailedAdapters := []

	for AdapterId, RequiredFns in Specs {
		AllPresent := true
		for _, FnName in RequiredFns {
			if !IsSet(%FnName%) or !((%FnName%) is Func) {
				AllPresent := false
				try LoggerWarn("Healthcheck", "Adapter '{1}' missing function '{2}'.", AdapterId, FnName)
			}
		}
		if AllPresent {
			LoadedAdapters.Push(AdapterId)
			PortsValidated.Push(AdapterId)
		} else {
			FailedAdapters.Push(AdapterId . " (contract incomplete)")
		}
	}

	UptimeSec := (A_TickCount - (_HealthCheckStartMs) & 0xFFFFFFFF) // 1000

	; Every collector below is hoisted out of the Map(...) constructor and run
	; through _HealthCheck_Collect. Inside the constructor they were bare calls,
	; so the first one to throw took the entire healthcheck — and with it the
	; crash report it was being run to produce — down with it. _HealthCheck_SysInfo
	; is the most exposed: it does a WMI ConnectServer, three RegRead calls and a
	; git subprocess poll.
	RecentIssues := _HealthCheck_Collect("recent_issues", () => _HealthCheck_RecentIssues(100), [])
	Sys          := _HealthCheck_Collect("sys", _HealthCheck_SysInfo, Map())
	PauseState   := _HealthCheck_Collect("pause_state", _HealthCheck_PauseState, Map())
	KeyloggerSum := _HealthCheck_Collect("keylogger", _HealthCheck_KeyloggerSummary, Map())
	LLMState     := _HealthCheck_Collect("llm", _HealthCheck_LLMState, Map())
	LayoutState  := _HealthCheck_Collect("layout", _HealthCheck_LayoutState, Map())
	HotstrState  := _HealthCheck_Collect("hotstrings", _HealthCheck_HotstringsState, Map())
	LogsInfo     := _HealthCheck_Collect("logs", _HealthCheck_LogsInfo, Map())
	ConfigSum    := _HealthCheck_Collect("config", _HealthCheck_ConfigSummary, Map())

	Result := Map(
		"version",         Version,
		"loaded_adapters", LoadedAdapters,
		"ports_validated", PortsValidated,
		"failed_adapters", FailedAdapters,
		"last_error",      _HealthCheckLastError,
		"uptime_sec",      UptimeSec,
		"warn_count",      _HealthCheckWarnCount,
		"err_count",       _HealthCheckErrCount,
		"sys",             Sys,
		"recent_issues",   RecentIssues,
		; Enriched (maximum completeness)
		"pause_state",     PauseState,
		"keylogger",       KeyloggerSum,
		"llm",             LLMState,
		"layout",          LayoutState,
		"hotstrings",      HotstrState,
		"logs",            LogsInfo,
		"config",          ConfigSum
	)

	try LoggerSuccess("Healthcheck", "Healthcheck complete — {1} adapter(s) OK, {2} failed, uptime {3}s.",
		PortsValidated.Length, FailedAdapters.Length, UptimeSec)

	return Result
}

; Formats a healthcheck snapshot as a Markdown string suitable for WebView2 rendering.
; @param Snapshot {Map|0} Result from HealthCheck_Run(), or 0 to run fresh.
; @return {String}
HealthCheck_FormatMarkdown(Snapshot := 0) {
	if !(Snapshot is Map)
		Snapshot := HealthCheck_Run()

	Sys := Snapshot["sys"]

	Lines := []
	Lines.Push("# System diagnostic")
	Lines.Push("")

	; ── System info ───────────────────────────────────────────────────────────
	Lines.Push("## System")
	Lines.Push("")
	Lines.Push("| Field | Value |")
	Lines.Push("|---|---|")
	Lines.Push("| ErgoptiPlus version | " . '``' . Snapshot["version"] . '``' . " |")
	Lines.Push("| Uptime | " . _HealthCheck_FormatUptime(Snapshot["uptime_sec"]) . " |")
	Lines.Push("| AutoHotkey | " . Sys["ahk_version"] . " " . Sys["ahk_bitness"] . " |")
	Lines.Push("| Windows | " . Sys["os_name"] . " |")
	Lines.Push("| Windows build | " . Sys["os_build"] . " |")
	Lines.Push("| Architecture | " . Sys["os_arch"] . " |")
	Lines.Push("| CPU | " . Sys["cpu_name"] . " |")
	Lines.Push("| Logical cores | " . Sys["cpu_cores"] . " |")
	Lines.Push("| Total RAM | " . Sys["ram_total_gb"] . " GB |")
	Lines.Push("| Available RAM | " . Sys["ram_free_gb"] . " GB |")
	Lines.Push("| Screen resolution | " . Sys["screen_res"] . " |")
	Lines.Push("| DPI | " . Sys["dpi"] . " (" . Sys["dpi_scale"] . "%) |")
	Lines.Push("| Locale | " . Sys["locale"] . " |")
	if Sys["config_dir"] != ""
		Lines.Push("| Config dir | " . '``' . Sys["config_dir"] . '``' . " |")
	Lines.Push("")

	; ── Session counters ──────────────────────────────────────────────────────
	WarnCount := Snapshot["warn_count"]
	ErrCount  := Snapshot["err_count"]
	Lines.Push("## Session counters")
	Lines.Push("")
	Lines.Push("| Type | Count |")
	Lines.Push("|---|---|")
	Lines.Push("| ⚠️ Warnings | " . (WarnCount = 0 ? "✅ " : "❌ ") . WarnCount . " |")
	Lines.Push("| 🔴 Errors   | " . (ErrCount  = 0 ? "✅ " : "❌ ") . ErrCount  . " |")
	Lines.Push("")

	; ── Adapters ──────────────────────────────────────────────────────────────
	OkList   := Snapshot["ports_validated"]
	FailList := Snapshot["failed_adapters"]
	Total    := OkList.Length + FailList.Length

	Lines.Push("## Adapters (" . OkList.Length . "/" . Total . " OK)")
	Lines.Push("")
	for _, Name in OkList
		Lines.Push("- ✓ " . '``' . Name . '``')
	for _, Name in FailList
		Lines.Push("- ✗ " . '``' . Name . '``')
	Lines.Push("")

	; ── Last recorded error ───────────────────────────────────────────────────
	Lines.Push("## Last recorded error")
	Lines.Push("")
	LastErr := Snapshot["last_error"]
	Fence   := Chr(96) . Chr(96) . Chr(96)
	if LastErr != ""
		Lines.Push(Fence . "`n" . LastErr . "`n" . Fence)
	else
		Lines.Push("_No error recorded._")
	Lines.Push("")

	; ── Recent warnings / errors ──────────────────────────────────────────────
	RecentIssues := Snapshot["recent_issues"]
	Lines.Push("## Recent warnings / errors (" . RecentIssues.Length . "/100)")
	Lines.Push("")
	if RecentIssues.Length = 0 {
		Lines.Push("_No warnings or errors since startup._")
	} else {
		Lines.Push(Fence)
		for _, L in RecentIssues
			Lines.Push(L)
		Lines.Push(Fence)
	}

	Out := ""
	for i, L in Lines
		Out .= (i > 1 ? "`n" : "") . L
	return Out
}

; Exact dimensions for the diagnostic window — mirrors the updater layout approach.
global _HC_WIN_W    := 740
global _HC_MARGIN   := 12
global _HC_BTN_H    := 32
global _HC_BTN_PAD  := 8    ; vertical gap above and below the button row

; Virtual host for the shared healthcheck frontend — maps _SharedDir so
; relative assets (style.css, script.js, ../dom_utils.js) resolve over https.
global HC_VHOST             := "ergopti.healthcheck"
global HC_HOST_ACCESS_ALLOW := 1

; WebView2 plumbing — subscription handles + snapshot JSON captured at open time.
global _HC_Controller := unset
global _HC_WebView    := unset
global _HC_NavSub     := unset
global _HC_SnapshotJs := ""
global _HC_WindowEpoch := 0

; The host window itself. Without it the singleton bookkeeping was split in half:
; the controller lived in a global, the Gui was a function-local, and _HC_Close
; could only reach the half it could see — so "close the previous singleton" left
; the previous window on screen with a dead blank pane.
global _HC_Gui := unset

; True once _HC_Reset() has torn the controller down — guards against
; double-close (same SEH access-violation pattern as action_picker_webview.ahk).
global _HC_ResetDone := false

; Opens a dedicated window displaying the healthcheck report.
; Loads the shared _shared/ui/healthcheck/ frontend via virtual host, injects
; the snapshot as JSON after navigation, and renders client-side. The button
; is a native AHK control placed below the WebView pane.
; Falls back to a selectable Edit + native button when WebView2 is unavailable.
HealthCheck_ShowWindow() {
	global _VendorDir, _SharedDir, _HC_WIN_W, _HC_MARGIN, _HC_BTN_H, _HC_BTN_PAD
	global HC_VHOST, HC_HOST_ACCESS_ALLOW
	global _HC_Controller, _HC_WebView, _HC_NavSub, _HC_SnapshotJs, _HC_ResetDone, _HC_Gui
	global _HC_WindowEpoch

	Snapshot  := HealthCheck_Run()
	PlainText := HealthCheck_FormatPlain(Snapshot)

	; Close any previous singleton before opening a new one.
	_HC_Close()

	WinTitle := "ErgoptiPlus — " . t("menu.debug.healthcheck")
	BtnLabel := t("healthcheck.copy_and_close")

	InnerW   := _HC_WIN_W - _HC_MARGIN * 2
	ContentH := 560

	G := Gui_Create("+Resize +MinSize540x420", WinTitle)
	G.SetFont("s10", "Segoe UI")
	G.MarginX := _HC_MARGIN
	G.MarginY := _HC_MARGIN

	; Content pane — same Text control pattern as updater's RightPane.
	ContentCtl := G.Add("Text", "xm ym w" . InnerW . " h" . ContentH, "")

	BtnCopy := G.Add("Button",
		"xm y+" . _HC_BTN_PAD . " w" . InnerW . " h" . _HC_BTN_H . " Default",
		BtnLabel)

	G.WVC := 0
	CloseAndCopy := (*) => (CB_Write(PlainText), _HealthCheck_CloseGui(G))
	G.OnEvent("Close",  (*) => _HealthCheck_CloseGui(G))
	G.OnEvent("Escape", (*) => _HealthCheck_CloseGui(G))
	BtnCopy.OnEvent("Click", CloseAndCopy)

	G.Show("w" . _HC_WIN_W . " AutoSize")
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
			try LoggerWarn("Healthcheck", "WebView2 create failed: {1} — falling back.", Err.Message)
		}

		if WVC {
			global _HC_Controller := WVC
			global _HC_WebView    := WVC.CoreWebView2
			global _HC_ResetDone  := false
			_HC_WindowEpoch += 1
			WindowEpoch := _HC_WindowEpoch

			try {
				s := _HC_WebView.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
			}

			; Build the renderHealthcheck(snapshot) call for injection after navigation.
			_HC_SnapshotJs := "if(window.renderHealthcheck)window.renderHealthcheck(" . _HC_SnapshotToJson(Snapshot) . ")"

			; Store the navigation subscription handle.
			global _HC_NavSub := _HC_WebView.NavigationCompleted(
				_HC_OnNavigationCompleted.Bind(WindowEpoch))

			; Map the virtual host BEFORE navigating.
			try _HC_WebView.SetVirtualHostNameToFolderMapping(HC_VHOST, _SharedDir, HC_HOST_ACCESS_ALLOW)
			try _HC_WebView.Navigate("https://" . HC_VHOST . "/ui/healthcheck/index.html?cb=" . A_TickCount)
			try _HC_Controller.Fill()

			try LoggerDone("Healthcheck", "Shared healthcheck frontend loaded via vhost.")
			return
		}
		try LoggerWarn("Healthcheck", "WVC is falsy after create — falling back to Edit.")
	}

	; Fallback — overlay a selectable Edit over the Text placeholder.
	_HealthCheck_AddFallbackEdit(G, ContentCtl, PlainText)
}

; Overlays a selectable read-only Edit on the same slot as the given placeholder control.
_HealthCheck_AddFallbackEdit(G, HostCtl, Text) {
	HostCtl.GetPos(&X, &Y, &W, &H)
	EditCtl := G.Add("Edit", "x" . X . " y" . Y . " w" . W . " h" . H
		. " ReadOnly Multi -Wrap +VScroll", Text)
	EditCtl.SetFont("s9", "Consolas")
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

; ── WebView2 navigation + teardown helpers ──────────────────────────────────

; Injects the snapshot JSON once the shared frontend has finished loading.
; NavigationCompleted can arrive after the singleton was closed and reopened.
; Bind the session so a late event cannot schedule work against the replacement
; controller through the mutable module globals.
_HC_OnNavigationCompleted(WindowEpoch, Handler, Args) {
	global _HC_WindowEpoch, _HC_ResetDone
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch)
		return
	SetTimer(_HC_PushSnapshot.Bind(WindowEpoch), -1)
}

_HC_PushSnapshot(WindowEpoch) {
	global _HC_WebView, _HC_SnapshotJs, _HC_WindowEpoch, _HC_ResetDone
	if _HC_ResetDone || (WindowEpoch != _HC_WindowEpoch) || !IsSet(_HC_WebView)
		return
	try _HC_WebView.ExecuteScriptAsync(_HC_SnapshotJs)
}

; Converts the AHK snapshot Map to a safe JSON string for JS injection.
; Uses the same escaping as action_picker_webview.ahk's _ActPickWeb_JsStr.
_HC_SnapshotToJson(Snapshot) {
	; Walk the Map recursively and build a JSON string.
	; We build manually to avoid depending on a JSON library.
	return _HC_ValueToJson(Snapshot)
}

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
	global _HC_Controller, _HC_WebView, _HC_NavSub, _HC_SnapshotJs, _HC_ResetDone
	global _HC_WindowEpoch

	if _HC_ResetDone
		return
	_HC_ResetDone := true
	_HC_WindowEpoch += 1

	try {
		_HC_NavSub := unset
		if IsSet(_HC_Controller)
			_HC_Controller.Close()
	}
	_HC_Controller := unset
	_HC_WebView    := unset
	_HC_SnapshotJs := ""
}

; Formats the snapshot as a plain-text string (fallback when WebView2 is absent).
; @param Snapshot {Map} Result from HealthCheck_Run().
; @return {String}
HealthCheck_FormatPlain(Snapshot) {
	Sys   := Snapshot["sys"]
	Lines := []
	Lines.Push("=== System diagnostic ===")
	Lines.Push("")
	Lines.Push("Version         : " . Snapshot["version"])
	Lines.Push("Uptime          : " . _HealthCheck_FormatUptime(Snapshot["uptime_sec"]))
	Lines.Push("AutoHotkey      : " . Sys["ahk_version"] . " " . Sys["ahk_bitness"])
	Lines.Push("Windows         : " . Sys["os_name"])
	Lines.Push("Build           : " . Sys["os_build"])
	Lines.Push("Architecture    : " . Sys["os_arch"])
	Lines.Push("CPU             : " . Sys["cpu_name"])
	Lines.Push("Logical cores   : " . Sys["cpu_cores"])
	Lines.Push("Total RAM       : " . Sys["ram_total_gb"] . " GB")
	Lines.Push("Available RAM   : " . Sys["ram_free_gb"] . " GB")
	Lines.Push("Resolution      : " . Sys["screen_res"])
	Lines.Push("DPI             : " . Sys["dpi"] . " (" . Sys["dpi_scale"] . "%)")
	Lines.Push("Locale          : " . Sys["locale"])
	if Sys["config_dir"] != ""
		Lines.Push("Config dir      : " . Sys["config_dir"])
	Lines.Push("")
	Lines.Push("Warnings        : " . Snapshot["warn_count"])
	Lines.Push("Errors          : " . Snapshot["err_count"])
	Lines.Push("")

	; --- Enriched sections ---
	if Snapshot.Has("pause_state") {
		ps := Snapshot["pause_state"]
		Lines.Push("Pause / Suspend : " . (ps["is_paused"] ? "PAUSED (" . ps["source"] . ")" : "running"))
	}

	if Snapshot.Has("logs") {
		lg := Snapshot["logs"]
		Lines.Push("Logs (unified)  : " . (lg["unified_today"] != "" ? lg["unified_today"] : "n/a"))
		Lines.Push("Errors sink     : " . (lg["errors_today"] != "" ? lg["errors_today"] : "n/a") . "  (WARNING/ERROR only — keeps main log clean)")
	}

	if Snapshot.Has("keylogger") {
		kl := Snapshot["keylogger"]
		Lines.Push("Keylogger       : events=" . kl["events_session"] . " wpm=" . kl["wpm"] . " privacy_hits=" . kl["privacy_hits"])
	}

	if Snapshot.Has("llm") {
		ll := Snapshot["llm"]
		Lines.Push("LLM             : enabled=" . ll["enabled"] . " backend=" . ll["backend"] . " profile=" . ll["active_profile"])
	}

	if Snapshot.Has("layout") {
		ly := Snapshot["layout"]
		Lines.Push("Layout          : base=" . ly["ergopti_base"] . " altgr=" . ly["altgr"] . " shift=" . ly["shift"] . " caps=" . ly["caps"] . " prefix_latch=" . ly["prefix_latch"])
	}

	if Snapshot.Has("hotstrings") {
		hs := Snapshot["hotstrings"]
		Lines.Push("Hotstrings      : terminators=" . hs["terminators"] . " personal=" . hs["personal_count"] . " dyn=" . hs["dynamic_count"] . " magic=" . hs["magic_key"])
	}

	OkList := Snapshot["ports_validated"]
	Lines.Push("Adapters OK (" . OkList.Length . ") :")
	for _, Name in OkList
		Lines.Push("  + " . Name)

	FailList := Snapshot["failed_adapters"]
	if FailList.Length > 0 {
		Lines.Push("Failed (" . FailList.Length . ") :")
		for _, Name in FailList
			Lines.Push("  x " . Name)
	} else {
		Lines.Push("Failed : none")
	}

	Lines.Push("")
	LastErr := Snapshot["last_error"]
	Lines.Push("Last error      : " . (LastErr != "" ? LastErr : "none"))

	RecentIssues := Snapshot["recent_issues"]
	if RecentIssues.Length > 0 {
		Lines.Push("")
		Lines.Push("--- Recent warnings / errors (" . RecentIssues.Length . ") ---")
		for _, L in RecentIssues
			Lines.Push(L)
	}

	Out := ""
	for i, L in Lines
		Out .= (i > 1 ? "`r`n" : "") . L
	return Out
}
