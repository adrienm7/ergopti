; ui/healthcheck/core.ahk

; ==============================================================================
; MODULE: Healthcheck / Probe + Public API + Window
; DESCRIPTION:
; Module-level counters, the adapter/port registry probe, the public API (HealthCheck_Run / RecordError / RecordWarn / FormatMarkdown / FormatPlain / Format) and the WebView2 report window.
;
; Split out of the former lib/healthcheck.ahk (P5 refactor); see
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
	_HealthCheckLastError := Msg
	_HealthCheckErrCount  += 1
	try LoggerDebug("Healthcheck", "Last error recorded: {1}", Msg)
}

; Increments the session warning counter (called by logger when it emits a WARNING).
HealthCheck_RecordWarn() {
	global _HealthCheckWarnCount
	_HealthCheckWarnCount += 1
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
HealthCheck_Run() {
	global _HealthCheckStartMs, _HealthCheckLastError, _HealthCheckWarnCount, _HealthCheckErrCount

	try LoggerStart("Healthcheck", "Running healthcheck...")

	; Resolve driver version
	Version := "local"
	try Version := Updater_CurrentVersion()

	Specs          := _HealthCheck_AdapterSpecs()
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

	; Collect the last 100 WARNING / ERROR lines from the ring buffer
	RecentIssues := _HealthCheck_RecentIssues(100)

	Result := Map(
		"version",         Version,
		"loaded_adapters", LoadedAdapters,
		"ports_validated", PortsValidated,
		"failed_adapters", FailedAdapters,
		"last_error",      _HealthCheckLastError,
		"uptime_sec",      UptimeSec,
		"warn_count",      _HealthCheckWarnCount,
		"err_count",       _HealthCheckErrCount,
		"sys",             _HealthCheck_SysInfo(),
		"recent_issues",   RecentIssues,
		; Enriched (maximum completeness)
		"pause_state",     _HealthCheck_PauseState(),
		"keylogger",       _HealthCheck_KeyloggerSummary(),
		"llm",             _HealthCheck_LLMState(),
		"layout",          _HealthCheck_LayoutState(),
		"hotstrings",      _HealthCheck_HotstringsState(),
		"logs",            _HealthCheck_LogsInfo(),
		"config",          _HealthCheck_ConfigSummary()
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

; Opens a dedicated window displaying the healthcheck report.
; Mirrors the updater changelog pane pattern exactly: synchronous WebView2.create,
; Text control as host (same as RightPane in updater), Fill(), NavigateToString.
; The button is a native AHK control placed below the WebView pane.
; Falls back to a selectable Edit + native button when WebView2 is unavailable.
HealthCheck_ShowWindow() {
	global _VendorDir, _HC_WIN_W, _HC_MARGIN, _HC_BTN_H, _HC_BTN_PAD

	Snapshot  := HealthCheck_Run()
	PlainText := HealthCheck_FormatPlain(Snapshot)

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
	CloseAndCopy := (*) => (A_Clipboard := PlainText, _HealthCheck_CloseGui(G))
	G.OnEvent("Close",  (*) => _HealthCheck_CloseGui(G))
	G.OnEvent("Escape", (*) => _HealthCheck_CloseGui(G))
	BtnCopy.OnEvent("Click", CloseAndCopy)

	G.Show("w" . _HC_WIN_W . " AutoSize")

	UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !WebView_ShouldUseNativeFallback()
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"

		WVC := 0
		try {
			; Parent to ContentCtl.Hwnd — identical to updater's RightPane.Hwnd pattern.
			; Reuse the shared session environment (lib/webview_utils.ahk) so no
			; second Chromium process boots and reopens are near-instant.
			WVC := WebView2.create(ContentCtl.Hwnd, , WebView_SharedEnvironment(loader))
			G.WVC := WVC
		} catch as Err {
			try LoggerWarn("Healthcheck", "WebView2 create failed: {1} — falling back.", Err.Message)
		}

		if WVC {
			WV := WVC.CoreWebView2
			try {
				s := WV.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
			}
			; Defer Fill+NavigateToString so the message loop has painted the
			; window and GetClientRect returns a valid non-zero rect.
			Html := _HealthCheck_SnapshotToHtml(Snapshot, BtnLabel)
			SetTimer(() => (WVC.Fill(), WV.NavigateToString(Html)), -50)
			try LoggerDone("Healthcheck", "NavigateToString scheduled.")
			; Button still copies plain-text even with WebView2 active.
			return
		}
		try LoggerWarn("Healthcheck", "WVC is falsy after create — falling back to Edit.")
	}

	; Fallback — overlay a selectable Edit over the Text placeholder.
	_HealthCheck_AddFallbackEdit(G, ContentCtl, PlainText)
}

; Handles messages posted from the HTML page via chrome.webview.postMessage.
; "copy_and_close" copies the plain-text report to the clipboard then destroys the window.
_HealthCheck_OnWebMsg(WV, MsgArgs, PlainText, G) {
	try {
		Msg := MsgArgs.TryGetWebMessageAsString()
		if Msg = "copy_and_close" {
			A_Clipboard := PlainText
			_HealthCheck_CloseGui(G)
		}
	}
}

; Overlays a selectable read-only Edit on the same slot as the given placeholder control.
_HealthCheck_AddFallbackEdit(G, HostCtl, Text) {
	HostCtl.GetPos(&X, &Y, &W, &H)
	EditCtl := G.Add("Edit", "x" . X . " y" . Y . " w" . W . " h" . H
		. " ReadOnly Multi -Wrap +VScroll", Text)
	EditCtl.SetFont("s9", "Consolas")
}

_HealthCheck_CloseGui(G) {
	if G.HasProp("WVC") && G.WVC
		try G.WVC.Close()
	try G.Destroy()
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

; Kept for backwards compatibility — delegates to HealthCheck_FormatPlain.
; @param Snapshot {Map|0} Result from HealthCheck_Run(), or 0 to run fresh.
; @return {String}
HealthCheck_Format(Snapshot := 0) {
	if !(Snapshot is Map)
		Snapshot := HealthCheck_Run()
	return HealthCheck_FormatPlain(Snapshot)
}




