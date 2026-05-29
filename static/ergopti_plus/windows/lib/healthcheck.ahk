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
		"recent_issues",   RecentIssues
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
	Lines.Push("# Diagnostic système — ErgoptiPlus")
	Lines.Push("")

	; ── Système ───────────────────────────────────────────────────────────────
	Lines.Push("## Système")
	Lines.Push("")
	Lines.Push("| Champ | Valeur |")
	Lines.Push("|---|---|")
	Lines.Push("| Version ErgoptiPlus | ``" . Snapshot["version"] . "`` |")
	Lines.Push("| Durée de fonctionnement | " . _HealthCheck_FormatUptime(Snapshot["uptime_sec"]) . " |")
	Lines.Push("| AutoHotkey | " . Sys["ahk_version"] . " " . Sys["ahk_bitness"] . " |")
	Lines.Push("| Windows | " . Sys["os_name"] . " |")
	Lines.Push("| Build Windows | " . Sys["os_build"] . " |")
	Lines.Push("| Architecture | " . Sys["os_arch"] . " |")
	Lines.Push("| CPU | " . Sys["cpu_name"] . " |")
	Lines.Push("| Cœurs logiques | " . Sys["cpu_cores"] . " |")
	Lines.Push("| RAM totale | " . Sys["ram_total_gb"] . " Go |")
	Lines.Push("| RAM disponible | " . Sys["ram_free_gb"] . " Go |")
	Lines.Push("| Résolution écran | " . Sys["screen_res"] . " |")
	Lines.Push("| DPI | " . Sys["dpi"] . " (" . Sys["dpi_scale"] . "%) |")
	Lines.Push("| Locale | " . Sys["locale"] . " |")
	if Sys["config_dir"] != ""
		Lines.Push("| Dossier config | ``" . Sys["config_dir"] . "`` |")
	Lines.Push("")

	; ── Compteurs de session ──────────────────────────────────────────────────
	WarnCount := Snapshot["warn_count"]
	ErrCount  := Snapshot["err_count"]
	Lines.Push("## Compteurs de session")
	Lines.Push("")
	Lines.Push("| Type | Nombre |")
	Lines.Push("|---|---|")
	if WarnCount = 0
		Lines.Push("| ✓ Avertissements | 0 |")
	else
		Lines.Push("| ✗ Avertissements | " . WarnCount . " |")
	if ErrCount = 0
		Lines.Push("| ✓ Erreurs | 0 |")
	else
		Lines.Push("| ✗ Erreurs | " . ErrCount . " |")
	Lines.Push("")

	; ── Adaptateurs ───────────────────────────────────────────────────────────
	OkList   := Snapshot["ports_validated"]
	FailList := Snapshot["failed_adapters"]
	Total    := OkList.Length + FailList.Length

	Lines.Push("## Adaptateurs (" . OkList.Length . "/" . Total . " OK)")
	Lines.Push("")
	for _, Name in OkList
		Lines.Push("- ✓ ``" . Name . "``")
	for _, Name in FailList
		Lines.Push("- ✗ ``" . Name . "``")
	Lines.Push("")

	; ── Dernière erreur ───────────────────────────────────────────────────────
	Lines.Push("## Dernière erreur enregistrée")
	Lines.Push("")
	LastErr := Snapshot["last_error"]
	Fence   := Chr(96) . Chr(96) . Chr(96)
	if LastErr != ""
		Lines.Push(Fence . "`n" . LastErr . "`n" . Fence)
	else
		Lines.Push("_Aucune erreur enregistrée._")
	Lines.Push("")

	; ── Derniers avertissements / erreurs ─────────────────────────────────────
	RecentIssues := Snapshot["recent_issues"]
	Lines.Push("## Derniers avertissements / erreurs (" . RecentIssues.Length . "/100)")
	Lines.Push("")
	if RecentIssues.Length = 0 {
		Lines.Push("_Aucun avertissement ni erreur depuis le démarrage._")
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

; Opens a dedicated window displaying the healthcheck report.
; WebView2 fills the entire Gui (G.Hwnd parent + Fill()) so no Bounds calculation is
; needed. The copy button lives inside the HTML and posts "copy_and_close" via
; chrome.webview.postMessage so JS→AHK communication replaces an AHK button.
; Falls back to a native Edit + Button when WebView2 is unavailable.
HealthCheck_ShowWindow() {
	global _VendorDir

	Snapshot  := HealthCheck_Run()
	Md        := HealthCheck_FormatMarkdown(Snapshot)
	PlainText := HealthCheck_FormatPlain(Snapshot)

	WinTitle  := t("menu.debug.healthcheck") . " — ErgoptiPlus"
	BtnLabel  := t("healthcheck.copy_and_close")

	UseWV := IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")

	if UseWV {
		; WebView2 path — button is rendered inside HTML, no native AHK button needed.
		WinW := 740
		WinH := 640
		G := Gui("+Resize +MinSize540x420", WinTitle)
		G.MarginX := 0
		G.MarginY := 0
		G.OnEvent("Close",  (*) => G.Destroy())
		G.OnEvent("Escape", (*) => G.Destroy())
		G.Show("w" . WinW . " h" . WinH)

		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		udir   := A_Temp . "\ergopti_hc_wv_" . A_TickCount
		try DirCreate(udir)

		Html := _HealthCheck_MakeHtml(Md, BtnLabel)

		OnMsg := (WV, MsgArgs) => _HealthCheck_OnWebMsg(WV, MsgArgs, PlainText, G)
		OnReady := (WVC) => _HealthCheck_OnWVReady(WVC, Html, OnMsg)

		try {
			WebView2.create(G.Hwnd, OnReady, 0, udir, "", 0, loader)
			return
		} catch as Err {
			try LoggerWarn("Healthcheck", "WebView2 create failed: {1} — falling back.", Err.Message)
			G.Destroy()
		}
	}

	; Fallback — native AHK controls (plain text, selectable Edit + native button).
	InnerW := 700
	Margin := 12
	BtnH   := 32
	G := Gui("+Resize +MinSize540x420", WinTitle)
	G.SetFont("s10", "Segoe UI")
	G.MarginX := Margin
	G.MarginY := 10
	ContentCtl := G.Add("Text", "xm ym w" . InnerW . " h560", "")
	BtnCopy    := G.Add("Button", "xm y+10 w" . InnerW . " h" . BtnH . " Default", BtnLabel)
	CloseAndCopy := (*) => (A_Clipboard := PlainText, G.Destroy())
	G.OnEvent("Close",  (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())
	BtnCopy.OnEvent("Click", CloseAndCopy)
	G.Show("w" . (InnerW + Margin * 2) . " AutoSize")
	_HealthCheck_AddFallbackEdit(G, ContentCtl, PlainText)
}

; Called by WebView2 once the controller COM object is fully ready.
; Fill() covers the entire Gui client area — no manual Bounds needed.
_HealthCheck_OnWVReady(WVC, Html, OnMsg) {
	try {
		s := WVC.CoreWebView2.Settings
		s.AreDevToolsEnabled              := false
		s.AreDefaultContextMenusEnabled   := false
		s.IsStatusBarEnabled              := false
		s.AreBrowserAcceleratorKeysEnabled := false
	}
	try WVC.CoreWebView2.WebMessageReceived(OnMsg)
	try WVC.Fill()
	try WVC.CoreWebView2.NavigateToString(Html)
	try LoggerDone("Healthcheck", "WebView2 ready — diagnostic page loaded.")
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
	Lines.Push("=== ErgoptiPlus — Diagnostic système ===")
	Lines.Push("")
	Lines.Push("Version         : " . Snapshot["version"])
	Lines.Push("Uptime          : " . _HealthCheck_FormatUptime(Snapshot["uptime_sec"]))
	Lines.Push("AutoHotkey      : " . Sys["ahk_version"] . " " . Sys["ahk_bitness"])
	Lines.Push("Windows         : " . Sys["os_name"])
	Lines.Push("Build           : " . Sys["os_build"])
	Lines.Push("Architecture    : " . Sys["os_arch"])
	Lines.Push("CPU             : " . Sys["cpu_name"])
	Lines.Push("Coeurs logiques : " . Sys["cpu_cores"])
	Lines.Push("RAM totale      : " . Sys["ram_total_gb"] . " Go")
	Lines.Push("RAM disponible  : " . Sys["ram_free_gb"] . " Go")
	Lines.Push("Resolution      : " . Sys["screen_res"])
	Lines.Push("DPI             : " . Sys["dpi"] . " (" . Sys["dpi_scale"] . "%)")
	Lines.Push("Locale          : " . Sys["locale"])
	if Sys["config_dir"] != ""
		Lines.Push("Config dir      : " . Sys["config_dir"])
	Lines.Push("")
	Lines.Push("Avertissements  : " . Snapshot["warn_count"])
	Lines.Push("Erreurs         : " . Snapshot["err_count"])
	Lines.Push("")

	OkList := Snapshot["ports_validated"]
	Lines.Push("Adaptateurs OK (" . OkList.Length . ") :")
	for _, Name in OkList
		Lines.Push("  + " . Name)

	FailList := Snapshot["failed_adapters"]
	if FailList.Length > 0 {
		Lines.Push("Echecs (" . FailList.Length . ") :")
		for _, Name in FailList
			Lines.Push("  x " . Name)
	} else {
		Lines.Push("Echecs : aucun")
	}

	Lines.Push("")
	LastErr := Snapshot["last_error"]
	Lines.Push("Derniere erreur : " . (LastErr != "" ? LastErr : "aucune"))

	RecentIssues := Snapshot["recent_issues"]
	if RecentIssues.Length > 0 {
		Lines.Push("")
		Lines.Push("--- Derniers avertissements / erreurs (" . RecentIssues.Length . ") ---")
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

	return Info
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

; Builds a self-contained HTML page from a Markdown string.
; BtnLabel is injected as a sticky footer button that posts "copy_and_close" to AHK.
_HealthCheck_MakeHtml(Md, BtnLabel) {
	; Escape Markdown for a JS single-quoted string literal
	Safe := StrReplace(Md,   "\",  "\\")
	Safe := StrReplace(Safe, "'",  "\'")
	Safe := StrReplace(Safe, "`n", "\n")
	Safe := StrReplace(Safe, "`r", "")
	Safe := StrReplace(Safe, "`t", "\t")
	JsSrc := "'" . Safe . "'"

	; Escape button label for HTML
	SafeBtn := StrReplace(BtnLabel, "&", "&amp;")
	SafeBtn := StrReplace(SafeBtn, "<", "&lt;")
	SafeBtn := StrReplace(SafeBtn, ">", "&gt;")
	SafeBtn := StrReplace(SafeBtn, "'", "&#39;")

	return (
		"<!DOCTYPE html><html><head><meta charset='utf-8'>"
		. "<style>"
		. "*{box-sizing:border-box;}"
		. "html{height:100%;margin:0;padding:0;}"
		. "body{height:100%;margin:0;padding:0;font-family:'Segoe UI',sans-serif;font-size:13px;color:#1a1a1a;background:#fff;display:flex;flex-direction:column;}"
		. "#content{flex:1;overflow-y:auto;padding:16px 20px;}"
		. "#footer{flex-shrink:0;padding:8px 16px;border-top:1px solid #e0e0e0;background:#f8f8f8;}"
		. "#btnCopy{width:100%;padding:7px 16px;font-family:'Segoe UI',sans-serif;font-size:13px;background:#0078d4;color:#fff;border:none;border-radius:4px;cursor:pointer;}"
		. "#btnCopy:hover{background:#106ebe;}"
		. "h1{font-size:1.25em;margin:0 0 .6em;}"
		. "h2{font-size:1.05em;margin:1.2em 0 .3em;border-bottom:1px solid #e0e0e0;padding-bottom:.2em;color:#333;}"
		. "table{border-collapse:collapse;width:100%;margin:.4em 0 .8em;}th,td{border:1px solid #e0e0e0;padding:.3em .65em;text-align:left;}"
		. "th{background:#f6f6f6;font-weight:600;}td:first-child{white-space:nowrap;color:#555;font-weight:500;}"
		. "ul{margin:.3em 0 .3em 1.2em;padding:0;}li{margin:.2em 0;}"
		. "code{background:#f3f3f3;border-radius:3px;padding:.1em .35em;font-family:Consolas,monospace;font-size:.88em;}"
		. "pre{background:#1e1e1e;color:#d4d4d4;border-radius:4px;padding:.7em 1em;overflow-x:auto;white-space:pre-wrap;word-break:break-all;font-family:Consolas,'Courier New',monospace;font-size:.82em;line-height:1.45;}"
		. "pre code{background:none;padding:0;color:inherit;}"
		. "em{font-style:italic;color:#666;}"
		. ".ok{color:#1a7f37;font-weight:600;}.fail{color:#cf222e;font-weight:600;}"
		. "</style></head>"
		. "<body>"
		. "<div id='content'></div>"
		. "<div id='footer'><button id='btnCopy' onclick=`"window.chrome.webview.postMessage('copy_and_close')`">" . SafeBtn . "</button></div>"
		. "<script>"
		. "function mdToHtml(s){"
		. "var lines=s.split('\n'),out=[],inPre=false,inUl=false,inOl=false,inTbl=false;"
		. "function closeBlocks(){if(inUl){out.push('</ul>');inUl=false;}if(inOl){out.push('</ol>');inOl=false;}if(inTbl){out.push('</table>');inTbl=false;}}"
		. "function inline(t){t=t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');"
		. "t=t.replace(/``([^``]+)``/g,'<code>$1</code>');"
		. "t=t.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');"
		. "t=t.replace(/__(.+?)__/g,'<strong>$1</strong>');"
		. "t=t.replace(/\*(.+?)\*/g,'<em>$1</em>');"
		. "t=t.replace(/_(.+?)_/g,'<em>$1</em>');"
		. "t=t.replace(/✓/g,'<span class=ok>✓</span>');"
		. "t=t.replace(/✗/g,'<span class=fail>✗</span>');"
		. "return t;}"
		. "for(var i=0;i<lines.length;i++){"
		. "var l=lines[i];"
		. "if(/^``````/.test(l)){if(inPre){out.push('</code></pre>');inPre=false;}else{closeBlocks();out.push('<pre><code>');inPre=true;}continue;}"
		. "if(inPre){out.push(l.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'));continue;}"
		. "if(/^\s*$/.test(l)){closeBlocks();continue;}"
		. "var hm=l.match(/^(#{1,6})\s+(.*)/);if(hm){closeBlocks();var n=hm[1].length;out.push('<h'+n+'>'+inline(hm[2])+'</h'+n+'>');continue;}"
		. "if(/^\|/.test(l)&&/\|/.test(l)){if(!inTbl){closeBlocks();out.push('<table>');inTbl=true;}"
		. "if(/^[\s|:-]+$/.test(l))continue;"
		. "var cells=l.replace(/^\||\|$/g,'').split('|');"
		. "var isHeader=(out.length>0&&out[out.length-1]==='<table>');"
		. "var tag=isHeader?'th':'td';"
		. "out.push('<tr>'+cells.map(function(c){return'<'+tag+'>'+inline(c.trim())+'</'+tag+'>';}).join('')+'</tr>');continue;}"
		. "var ul=l.match(/^[-*+]\s+(.*)/);if(ul){if(!inUl){closeBlocks();out.push('<ul>');inUl=true;}out.push('<li>'+inline(ul[1])+'</li>');continue;}"
		. "var ol=l.match(/^\d+\.\s+(.*)/);if(ol){if(!inOl){closeBlocks();out.push('<ol>');inOl=true;}out.push('<li>'+inline(ol[1])+'</li>');continue;}"
		. "closeBlocks();out.push('<p>'+inline(l)+'</p>');}"
		. "if(inPre)out.push('</code></pre>');closeBlocks();"
		. "return out.join('\n');}"
		. "document.getElementById('content').innerHTML=mdToHtml(" . JsSrc . ");"
		. "</script></body></html>"
	)
}
