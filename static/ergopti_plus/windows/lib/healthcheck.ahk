; static/ergopti_plus/windows/lib/healthcheck.ahk

; ==============================================================================
; MODULE: Healthcheck
; DESCRIPTION:
; Diagnostic probe that snapshots the runtime state of the AutoHotkey driver
; and returns it in both structured (Map) and human-readable (string) form.
; Designed to be triggered from the tray Debug submenu or via a command-line
; flag so operators can verify the driver is properly wired without log files.
;
; FEATURES & RATIONALE:
; 1. Adapter probing: checks each adapter module file is present on disk and
;    that the expected public function names are defined in the global scope,
;    without calling or altering any of them.
; 2. Port validation: records which adapters expose their full contract surface
;    (load + all required functions present) vs which are partially broken.
; 3. Last error capture: reads the module-level _HealthCheckLastError variable
;    set by HealthCheck_RecordError() so callers can surface the most recent
;    failure without parsing log files.
; 4. Uptime: computes milliseconds elapsed since HealthCheck_Init() was first
;    called (stored in _HealthCheckStartMs) and converts to whole seconds.
; 5. System info: captures OS version (including build number), CPU, RAM, AHK
;    runtime, screen resolution, locale, and config directory for a complete
;    at-a-glance snapshot.
; 6. Recent log entries: pulls the last 50 WARNING/ERROR lines from the in-memory
;    ring buffer so diagnosis is possible without opening log files.
; 7. Selectable window: displays the report in a WebView2 window (text is
;    selectable and copyable) with a fallback read-only Edit control.
; ==============================================================================

#Requires AutoHotkey v2.0

; Module-level state — populated by HealthCheck_Init().
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
;   "uptime_sec"      -> Integer seconds since HealthCheck_Init()
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

	UptimeSec := (A_TickCount - _HealthCheckStartMs) // 1000

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

	CloseAndCopy := (*) => (A_Clipboard := PlainText, G.Destroy())
	G.OnEvent("Close",  (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())
	BtnCopy.OnEvent("Click", CloseAndCopy)

	G.Show("w" . _HC_WIN_W . " AutoSize")

	UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		udir   := A_Temp . "\ergopti_hc_wv_" . A_TickCount
		try DirCreate(udir)

		WVC := 0
		try {
			; Parent to ContentCtl.Hwnd — identical to updater's RightPane.Hwnd pattern.
			WVC := WebView2.create(ContentCtl.Hwnd, , 0, udir, "", 0, loader)
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
			G.Destroy()
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




; ===================================================
; ===================================================
; ======= 3/ Internal Helpers =======================
; ===================================================
; ===================================================

; Returns a Map with OS, CPU, RAM, and screen fields for inclusion in the snapshot.
_HealthCheck_SysInfo() {
	Info := Map()

	; Windows display name + build number from registry (more accurate than A_OSVersion)
	OsName  := A_OSVersion
	OsBuild := ""
	OsArch  := A_Is64bitOS ? "64 bits" : "32 bits"
	try {
		OsName  := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "ProductName")
		OsBuild := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuildNumber")
		UBR     := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR")
		OsBuild := OsBuild . "." . UBR
	}
	Info["os_name"]  := OsName
	Info["os_build"] := OsBuild
	Info["os_arch"]  := OsArch

	; CPU name + logical core count via WMI (first processor record)
	CpuName  := "inconnu"
	CpuCores := A_ComSpec ? "" : ""   ; placeholder — filled below
	try {
		WMI  := ComObject("WbemScripting.SWbemLocator").ConnectServer()
		Qry  := WMI.ExecQuery("SELECT Name, NumberOfLogicalProcessors FROM Win32_Processor")
		Enum := Qry._NewEnum()
		if Enum.Next(&Item) {
			CpuName  := Trim(Item.Name)
			CpuCores := Item.NumberOfLogicalProcessors
		}
	}
	Info["cpu_name"]  := CpuName
	Info["cpu_cores"] := CpuCores

	; Physical + available RAM via GlobalMemoryStatusEx DllCall
	RamTotalGb := "?"
	RamFreeGb  := "?"
	try {
		MemStatus := Buffer(64, 0)
		NumPut("UInt", 64, MemStatus, 0)   ; dwLength
		if DllCall("GlobalMemoryStatusEx", "Ptr", MemStatus) {
			TotalBytes    := NumGet(MemStatus, 8,  "UInt64")
			AvailBytes    := NumGet(MemStatus, 16, "UInt64")
			RamTotalGb    := Format("{:.1f}", TotalBytes / 1073741824)
			RamFreeGb     := Format("{:.1f}", AvailBytes / 1073741824)
		}
	}
	Info["ram_total_gb"] := RamTotalGb
	Info["ram_free_gb"]  := RamFreeGb

	; Screen + DPI
	Info["screen_res"] := A_ScreenWidth . "x" . A_ScreenHeight
	Info["dpi"]        := A_ScreenDPI
	Info["dpi_scale"]  := Round(A_ScreenDPI / 96 * 100)

	; AHK runtime
	Info["ahk_version"] := A_AhkVersion
	Info["ahk_bitness"] := (A_PtrSize = 8) ? "64-bit" : "32-bit"

	; Locale
	Info["locale"] := A_Language

	; Config directory (optional — only set if the global exists)
	ConfigDir := ""
	try {
		global _ConfigDir
		ConfigDir := _ConfigDir
	}
	Info["config_dir"] := ConfigDir

	; Short git commit hash of the running source tree
	GitHash := ""
	try {
		TmpFile := A_Temp . "\ergopti_githash_" . A_TickCount . ".txt"
		RunWait(A_ComSpec . " /c git -C " . Chr(34) . A_ScriptDir . Chr(34) . " rev-parse --short HEAD > " . Chr(34) . TmpFile . Chr(34), , "Hide")
		GitHash := Trim(FileRead(TmpFile, "UTF-8"))
		FileDelete(TmpFile)
	}
	Info["git_hash"] := GitHash

	return Info
}

; === Enriched collectors for "le plus complet possible" diagnostic ===
; All protected (pcall) so the healthcheck itself cannot crash the driver.
; Privacy: counts, states, paths only — never raw user text / expansions / prompts.

_HealthCheck_PauseState() {
	St := Map("is_paused", false, "source", "unknown")
	try {
		; AHK: A_IsSuspended is the primary gate; script_control may expose more.
		St["is_paused"] := (A_IsSuspended ? true : false)
		St["source"] := "A_IsSuspended"
		try {
			; If script_control is loaded, prefer its view (more precise for non-hotkey paths).
			global script_control
			if IsSet(script_control) && script_control.HasProp("is_paused") {
				St["is_paused"] := !!script_control.is_paused
				St["source"] := "script_control"
			}
		}
	}
	return St
}

_HealthCheck_KeyloggerSummary() {
	Sum := Map("enabled", "unknown", "wpm", "n/a", "events_session", 0, "privacy_hits", 0, "today_log", "", "errors_log", "", "notes", "see separate errors sink for high-severity")
	try {
		; Paths — unified + the dedicated errors sink (new feature)
		global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
		if IsSet(LOGGER_LOG_PATH) && LOGGER_LOG_PATH != ""
			Sum["today_log"] := LOGGER_LOG_PATH
		if IsSet(LOGGER_ERRORS_LOG_PATH) && LOGGER_ERRORS_LOG_PATH != ""
			Sum["errors_log"] := LOGGER_ERRORS_LOG_PATH
		; Note the separation
		Sum["notes"] := "High-severity (WARNING/ERROR) are also written to the dedicated ErgoptiPlus_errors_*.log (use Debug > Open Error Log)"
	}
	; Try to get safe stats from keylogger modules if they expose them (reader/walker/aggregator)
	try {
		; Best-effort: many keylogger stats live in keylogger_*.ahk globals or functions after include.
		; We only read; never start/stop.
		global _Keylogger_EventsToday, _Keylogger_WPM, _Keylogger_PrivacyCount
		if IsSet(_Keylogger_EventsToday)
			Sum["events_session"] := _Keylogger_EventsToday
		if IsSet(_Keylogger_WPM)
			Sum["wpm"] := _Keylogger_WPM
		if IsSet(_Keylogger_PrivacyCount)
			Sum["privacy_hits"] := _Keylogger_PrivacyCount
	} catch {
		; silent — diagnostic must stay robust
	}
	return Sum
}

_HealthCheck_LLMState() {
	St := Map("enabled", "unknown", "backend", "unknown", "active_profile", "unknown", "model", "n/a", "n_predictions", "n/a", "streaming", "n/a")
	try {
		; LLM tray / core state is often in _LLM_Tray or llm/init globals.
		global _LLM_Tray, llm_enabled, llm_backend, llm_active_profile
		if IsSet(llm_enabled)
			St["enabled"] := llm_enabled ? "true" : "false"
		if IsSet(llm_backend)
			St["backend"] := llm_backend
		if IsSet(llm_active_profile)
			St["active_profile"] := llm_active_profile
		if IsSet(_LLM_Tray) && _LLM_Tray is Map {
			if _LLM_Tray.Has("model")
				St["model"] := _LLM_Tray["model"]
			if _LLM_Tray.Has("n_predictions")
				St["n_predictions"] := _LLM_Tray["n_predictions"]
			if _LLM_Tray.Has("streaming")
				St["streaming"] := _LLM_Tray["streaming"]
		}
	} catch {
	}
	return St
}

_HealthCheck_LayoutState() {
	St := Map("ergopti_base", "unknown", "altgr", "unknown", "shift", "unknown", "caps", "unknown", "prefix_latch", "clean")
	try {
		; Layout modules expose state via functions or globals after init.
		global ErgoptiBaseEnabled, AltGrActive, ShiftActive, CapsActive
		if IsSet(ErgoptiBaseEnabled)
			St["ergopti_base"] := ErgoptiBaseEnabled ? "on" : "off"
		if IsSet(AltGrActive)
			St["altgr"] := AltGrActive ? "active" : "off"
		if IsSet(ShiftActive)
			St["shift"] := ShiftActive ? "active" : "off"
		if IsSet(CapsActive)
			St["caps"] := CapsActive ? "active" : "off"
		; Prefix latch status (the known gotcha) — best effort from layout_altgr if exposed.
		try {
			global _AltGrPrefixLatched
			if IsSet(_AltGrPrefixLatched) && _AltGrPrefixLatched
				St["prefix_latch"] := "latched (check after suspend)"
		}
	} catch {
	}
	return St
}

_HealthCheck_HotstringsState() {
	St := Map("terminators", 0, "magic_key", "", "personal_count", 0, "dynamic_count", 0, "default_delay", "n/a")
	try {
		global TERMINATORS, DYN_HOTSTRINGS_DEFAULT_DELAY
		if IsSet(TERMINATORS) && TERMINATORS is Array
			St["terminators"] := TERMINATORS.Length
		if IsSet(DYN_HOTSTRINGS_DEFAULT_DELAY)
			St["default_delay"] := DYN_HOTSTRINGS_DEFAULT_DELAY
		; Magic key from keymap or terminators
		try {
			global MAGIC_KEY
			if IsSet(MAGIC_KEY)
				St["magic_key"] := MAGIC_KEY
		}
		; Personal / dynamic counts (safe — just lengths)
		try {
			global PERSONAL_HOTSTRINGS, DYNAMIC_HOTSTRINGS
			if IsSet(PERSONAL_HOTSTRINGS) && PERSONAL_HOTSTRINGS is Map
				St["personal_count"] := PERSONAL_HOTSTRINGS.Count
			if IsSet(DYNAMIC_HOTSTRINGS) && DYNAMIC_HOTSTRINGS is Map
				St["dynamic_count"] := DYNAMIC_HOTSTRINGS.Count
		}
	} catch {
	}
	return St
}

_HealthCheck_LogsInfo() {
	Info := Map("unified_today", "", "errors_today", "", "errors_sink_active", false, "ring_lines", 0, "note", "Use the dedicated errors log for WARNING/ERROR only — keeps main logs clean.")
	try {
		global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, LOGGER_RING_BUFFER
		if IsSet(LOGGER_LOG_PATH) && LOGGER_LOG_PATH != ""
			Info["unified_today"] := LOGGER_LOG_PATH
		if IsSet(LOGGER_ERRORS_LOG_PATH) && LOGGER_ERRORS_LOG_PATH != "" {
			Info["errors_today"] := LOGGER_ERRORS_LOG_PATH
			Info["errors_sink_active"] := true
		}
		if IsSet(LOGGER_RING_BUFFER) && LOGGER_RING_BUFFER is Array
			Info["ring_lines"] := LOGGER_RING_BUFFER.Length
	} catch {
	}
	return Info
}

_HealthCheck_ConfigSummary() {
	Sum := Map("overrides", 0, "enabled_hotstrings", "n/a", "enabled_gestures", "n/a", "enabled_llm", "n/a", "config_files", [])
	try {
		; Best effort from known loader globals / _IniCache counts.
		global _IniCache, _ConfigDir
		if IsSet(_IniCache) && _IniCache is Map {
			; Rough count of sections that look like overrides
			c := 0
			for k in _IniCache
				c += 1
			Sum["overrides"] := c
		}
		; High-level enabled from Features if present (v1 shape or v2)
		try {
			global Features, FeaturesV2
			if IsSet(FeaturesV2) && FeaturesV2 is Map {
				if FeaturesV2.Has("hotstrings")
					Sum["enabled_hotstrings"] := "see v2 manifest"
				; etc. — keep light
			}
		}
		if IsSet(_ConfigDir) && _ConfigDir != ""
			Sum["config_files"].Push(_ConfigDir . "\config.toml")
	} catch {
	}
	return Sum
}

; Converts a raw second count to a human-readable uptime string (e.g. "2h 04m 37s").
_HealthCheck_FormatUptime(Sec) {
	h := Sec // 3600
	m := (Sec - h * 3600) // 60
	s := Sec - h * 3600 - m * 60
	if h > 0
		return h . "h " . Format("{:02d}", m) . "m " . Format("{:02d}", s) . "s"
	if m > 0
		return m . "m " . Format("{:02d}", s) . "s"
	return s . "s"
}

; Extracts the last N WARNING and ERROR lines from the in-memory ring buffer.
_HealthCheck_RecentIssues(MaxLines) {
	All    := LoggerRingBufferSnapshot()
	Issues := []
	for _, Line in All {
		if InStr(Line, "[WARNING]") or InStr(Line, "[ERROR]")
			Issues.Push(Line)
	}
	; Return only the last MaxLines entries
	if Issues.Length <= MaxLines
		return Issues
	Result := []
	Start  := Issues.Length - MaxLines + 1
	loop MaxLines {
		Result.Push(Issues[Start + A_Index - 1])
	}
	return Result
}

; Escapes a string for safe inclusion as HTML text content.
_HealthCheck_HE(s) {
	s := StrReplace(s, "&",  "&amp;")
	s := StrReplace(s, "<",  "&lt;")
	s := StrReplace(s, ">",  "&gt;")
	s := StrReplace(s, '"', "&quot;")
	return s
}

; Wraps a value in a <code> element with HTML-escaped content.
_HealthCheck_Code(s) => "<code>" . _HealthCheck_HE(s) . "</code>"

; Builds a self-contained HTML page directly from the snapshot Map.
; No runtime JS conversion — the HTML is fully rendered before NavigateToString.
; NOTE: All labels and section titles in this function are intentionally in English
; and must NOT go through the i18n system. Diagnostic output targets developers,
; not end users — a consistent language makes cross-platform log comparison possible.
_HealthCheck_SnapshotToHtml(Snapshot, BtnLabel) {
	Sys       := Snapshot["sys"]
	OkList    := Snapshot["ports_validated"]
	FailList  := Snapshot["failed_adapters"]
	Total     := OkList.Length + FailList.Length
	WarnCount := Snapshot["warn_count"]
	ErrCount  := Snapshot["err_count"]
	LastErr   := Snapshot["last_error"]
	Issues    := Snapshot["recent_issues"]
	SafeBtn   := _HealthCheck_HE(BtnLabel)

	; ── CSS ───────────────────────────────────────────────────────────────────
	Css := (
		"html,body{margin:0;padding:0;font-family:'Segoe UI',sans-serif;font-size:13px;color:#1a1a1a;background:#fff;}"
		. "body{padding:16px 20px;overflow-x:hidden;overflow-y:auto;word-break:break-word;}"
		. "h1{font-size:1.25em;margin:0 0 .6em;}"
		. "h2{font-size:1.05em;margin:1.2em 0 .3em;border-bottom:1px solid #e0e0e0;"
			. "padding-bottom:.2em;color:#333;}"
		. "table{border-collapse:collapse;width:100%;margin:.4em 0 .8em;}"
		. "th,td{border:1px solid #e0e0e0;padding:.3em .65em;text-align:left;}"
		. "th{background:#f6f6f6;font-weight:600;}"
		. "td:first-child{white-space:nowrap;color:#555;font-weight:500;}"
		. "ul{margin:.3em 0 .3em 1.2em;padding:0;}li{margin:.2em 0;}"
		. "code{background:#f3f3f3;border-radius:3px;padding:.1em .35em;"
			. "font-family:Consolas,monospace;font-size:.88em;}"
		. "pre{background:#1e1e1e;color:#d4d4d4;border-radius:4px;padding:.7em 1em;"
			. "overflow-x:hidden;white-space:pre-wrap;word-break:break-all;"
			. "font-family:Consolas,'Courier New',monospace;font-size:.82em;line-height:1.45;}"
		. "em{font-style:italic;color:#666;}"
		. ".ok{color:#1a7f37;font-weight:600;}.fail{color:#cf222e;font-weight:600;}"
	)

	; ── System table ──────────────────────────────────────────────────────────
	SysTbl := (
		"<table>"
		. "<tr><th>Field</th><th>Value</th></tr>"
		. "<tr><td>ErgoptiPlus version</td><td>" . _HealthCheck_Code(Snapshot["version"])           . "</td></tr>"
		. "<tr><td>Last git commit</td><td>"    . _HealthCheck_Code(Sys["git_hash"] != "" ? Sys["git_hash"] : "unknown") . "</td></tr>"
		. "<tr><td>Uptime</td><td>"              . _HealthCheck_HE(_HealthCheck_FormatUptime(Snapshot["uptime_sec"])) . "</td></tr>"
		. "<tr><td>AutoHotkey</td><td>"          . _HealthCheck_HE(Sys["ahk_version"] . " " . Sys["ahk_bitness"])    . "</td></tr>"
		. "<tr><td>Windows</td><td>"             . _HealthCheck_HE(Sys["os_name"])                  . "</td></tr>"
		. "<tr><td>Windows build</td><td>"       . _HealthCheck_HE(Sys["os_build"])                 . "</td></tr>"
		. "<tr><td>Architecture</td><td>"        . _HealthCheck_HE(Sys["os_arch"])                  . "</td></tr>"
		. "<tr><td>CPU</td><td>"                 . _HealthCheck_HE(Sys["cpu_name"])                 . "</td></tr>"
		. "<tr><td>Logical cores</td><td>"       . _HealthCheck_HE(String(Sys["cpu_cores"]))        . "</td></tr>"
		. "<tr><td>Total RAM</td><td>"           . _HealthCheck_HE(Sys["ram_total_gb"] . " GB")     . "</td></tr>"
		. "<tr><td>Available RAM</td><td>"       . _HealthCheck_HE(Sys["ram_free_gb"]  . " GB")     . "</td></tr>"
		. "<tr><td>Screen resolution</td><td>"   . _HealthCheck_HE(Sys["screen_res"])               . "</td></tr>"
		. "<tr><td>DPI</td><td>"                 . _HealthCheck_HE(Sys["dpi"] . " (" . Sys["dpi_scale"] . "%)") . "</td></tr>"
		. "<tr><td>Locale</td><td>"              . _HealthCheck_HE(Sys["locale"])                   . "</td></tr>"
	)
	if Sys["config_dir"] != ""
		SysTbl .= "<tr><td>Config dir</td><td>" . _HealthCheck_Code(Sys["config_dir"]) . "</td></tr>"
	SysTbl .= "</table>"

	; ── Session counters table ────────────────────────────────────────────────
	WarnOk  := WarnCount = 0 ? "<span class=ok>✅ " . WarnCount . "</span>" : "<span class=fail>❌ " . WarnCount . "</span>"
	ErrOk   := ErrCount  = 0 ? "<span class=ok>✅ " . ErrCount  . "</span>" : "<span class=fail>❌ " . ErrCount  . "</span>"
	CtrTbl  := (
		"<table>"
		. "<tr><th>Type</th><th>Count</th></tr>"
		. "<tr><td>⚠️ Warnings</td><td>" . WarnOk . "</td></tr>"
		. "<tr><td>🔴 Errors</td><td>"   . ErrOk  . "</td></tr>"
		. "</table>"
	)

	; ── Adapters list ─────────────────────────────────────────────────────────
	AdapHtml := "<ul>"
	for _, Name in OkList
		AdapHtml .= "<li><span class=ok>✓</span> " . _HealthCheck_Code(Name) . "</li>"
	for _, Name in FailList
		AdapHtml .= "<li><span class=fail>✗</span> " . _HealthCheck_Code(Name) . "</li>"
	AdapHtml .= "</ul>"

	; ── Last error ────────────────────────────────────────────────────────────
	if LastErr != ""
		LastErrHtml := "<pre>" . _HealthCheck_HE(LastErr) . "</pre>"
	else
		LastErrHtml := "<em>No error recorded.</em>"

	; ── Recent issues ─────────────────────────────────────────────────────────
	if Issues.Length = 0 {
		IssuesHtml := "<em>No warnings or errors since startup.</em>"
	} else {
		IssuesLines := ""
		for _, L in Issues
			IssuesLines .= _HealthCheck_HE(L) . "`n"
		IssuesHtml := "<pre>" . IssuesLines . "</pre>"
	}

	; ── Assemble full page ────────────────────────────────────────────────────
	return (
		"<!DOCTYPE html><html><head><meta charset='utf-8'>"
		. "<style>" . Css . "</style>"
		. "</head><body>"
		. "<h1>System diagnostic</h1>"
		. "<h2>System</h2>" . SysTbl
		. "<h2>Session counters</h2>" . CtrTbl
		. "<h2>Adapters (" . OkList.Length . "/" . Total . " OK)</h2>" . AdapHtml
		. "<h2>Last recorded error</h2>" . LastErrHtml
		. "<h2>Recent warnings / errors (" . Issues.Length . "/100)</h2>" . IssuesHtml
		. "</body></html>"
	)
}
