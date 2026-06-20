; ui/healthcheck/helpers.ahk

; ==============================================================================
; MODULE: Healthcheck / State-gathering Helpers
; DESCRIPTION:
; Internal probes that gather the runtime snapshot: system info, pause state, keylogger / LLM / layout / hotstrings state, log info, config summary, uptime formatting, recent-issue extraction, HTML escaping and the snapshot-to-HTML renderer.
;
; Split out of the former lib/healthcheck.ahk (P5 refactor); see
; ui/healthcheck/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the healthcheck/*.ahk files is irrelevant.
; ==============================================================================





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

	; Short git commit hash of the running source tree.
	; Use non-blocking Run + bounded poll so a stalled git (unavailable, network
	; drive, credential prompt) cannot freeze the main pseudo-thread — this path
	; also runs on the crash handler where the keyboard is already degraded.
	GitHash := ""
	try {
		TmpFile := A_Temp . "\ergopti_githash_" . A_TickCount . "_" . A_PtrSize . ".txt"
		Run(A_ComSpec . " /c git -C " . Chr(34) . A_ScriptDir . Chr(34)
			. " rev-parse --short HEAD > " . Chr(34) . TmpFile . Chr(34), , "Hide")
		StartTick := A_TickCount
		while (!FileExist(TmpFile) and ((A_TickCount - StartTick) & 0xFFFFFFFF) < 500)
			Sleep(50)
		if FileExist(TmpFile) {
			GitHash := Trim(FileRead(TmpFile, "UTF-8"))
			try FileDelete(TmpFile)
		}
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

	; ── Enriched runtime sections ─────────────────────────────────────────────
	EnrichedHtml := ""

	if Snapshot.Has("pause_state") {
		ps := Snapshot["pause_state"]
		PauseVal := ps["is_paused"] ? "<span class=fail>PAUSED</span> (" . _HealthCheck_HE(ps["source"]) . ")" : "<span class=ok>running</span>"
		EnrichedHtml .= "<h2>Runtime state</h2><table><tr><th>Field</th><th>Value</th></tr>"
		EnrichedHtml .= "<tr><td>Pause / Suspend</td><td>" . PauseVal . "</td></tr>"
		if Snapshot.Has("layout") {
			ly := Snapshot["layout"]
			EnrichedHtml .= "<tr><td>Layout base</td><td>" . _HealthCheck_HE(ly["ergopti_base"]) . "</td></tr>"
			EnrichedHtml .= "<tr><td>AltGr</td><td>"       . _HealthCheck_HE(ly["altgr"])        . "</td></tr>"
			EnrichedHtml .= "<tr><td>Shift</td><td>"        . _HealthCheck_HE(ly["shift"])        . "</td></tr>"
			EnrichedHtml .= "<tr><td>Caps</td><td>"         . _HealthCheck_HE(ly["caps"])         . "</td></tr>"
			EnrichedHtml .= "<tr><td>Prefix latch</td><td>" . _HealthCheck_HE(ly["prefix_latch"]) . "</td></tr>"
		}
		if Snapshot.Has("llm") {
			ll := Snapshot["llm"]
			EnrichedHtml .= "<tr><td>LLM enabled</td><td>"     . _HealthCheck_HE(ll["enabled"])        . "</td></tr>"
			EnrichedHtml .= "<tr><td>LLM backend</td><td>"     . _HealthCheck_HE(ll["backend"])        . "</td></tr>"
			EnrichedHtml .= "<tr><td>LLM profile</td><td>"     . _HealthCheck_HE(ll["active_profile"]) . "</td></tr>"
			EnrichedHtml .= "<tr><td>LLM model</td><td>"       . _HealthCheck_HE(ll["model"])          . "</td></tr>"
			EnrichedHtml .= "<tr><td>LLM predictions</td><td>" . _HealthCheck_HE(ll["n_predictions"])  . "</td></tr>"
		}
		if Snapshot.Has("keylogger") {
			kl := Snapshot["keylogger"]
			EnrichedHtml .= "<tr><td>Keylogger events</td><td>"  . _HealthCheck_HE(String(kl["events_session"])) . "</td></tr>"
			EnrichedHtml .= "<tr><td>WPM</td><td>"               . _HealthCheck_HE(String(kl["wpm"]))            . "</td></tr>"
			EnrichedHtml .= "<tr><td>Privacy hits</td><td>"      . _HealthCheck_HE(String(kl["privacy_hits"]))   . "</td></tr>"
		}
		if Snapshot.Has("hotstrings") {
			hs := Snapshot["hotstrings"]
			EnrichedHtml .= "<tr><td>Terminators</td><td>"    . _HealthCheck_HE(String(hs["terminators"]))    . "</td></tr>"
			EnrichedHtml .= "<tr><td>Personal hotstrings</td><td>" . _HealthCheck_HE(String(hs["personal_count"])) . "</td></tr>"
			EnrichedHtml .= "<tr><td>Dynamic hotstrings</td><td>"  . _HealthCheck_HE(String(hs["dynamic_count"]))  . "</td></tr>"
			EnrichedHtml .= "<tr><td>Default delay</td><td>"  . _HealthCheck_HE(String(hs["default_delay"])) . "</td></tr>"
			EnrichedHtml .= "<tr><td>Magic key</td><td>"      . _HealthCheck_HE(hs["magic_key"])             . "</td></tr>"
		}
		if Snapshot.Has("logs") {
			lg := Snapshot["logs"]
			LogVal := lg["unified_today"] != "" ? _HealthCheck_Code(lg["unified_today"]) : "<em>n/a</em>"
			ErrVal := lg["errors_today"]  != "" ? _HealthCheck_Code(lg["errors_today"])  : "<em>n/a</em>"
			EnrichedHtml .= "<tr><td>Log (unified)</td><td>"  . LogVal . "</td></tr>"
			EnrichedHtml .= "<tr><td>Log (errors)</td><td>"   . ErrVal . "</td></tr>"
			EnrichedHtml .= "<tr><td>Ring buffer lines</td><td>" . _HealthCheck_HE(String(lg["ring_lines"])) . "</td></tr>"
		}
		EnrichedHtml .= "</table>"
	}

	; ── Assemble full page ────────────────────────────────────────────────────
	return (
		"<!DOCTYPE html><html><head><meta charset='utf-8'>"
		. "<style>" . Css . "</style>"
		. "</head><body>"
		. "<h1>System diagnostic</h1>"
		. "<h2>System</h2>" . SysTbl
		. "<h2>Session counters</h2>" . CtrTbl
		. EnrichedHtml
		. "<h2>Adapters (" . OkList.Length . "/" . Total . " OK)</h2>" . AdapHtml
		. "<h2>Last recorded error</h2>" . LastErrHtml
		. "<h2>Recent warnings / errors (" . Issues.Length . "/100)</h2>" . IssuesHtml
		. "</body></html>"
	)
}
