; ui/healthcheck/helpers.ahk

; ==============================================================================
; MODULE: Healthcheck / State-gathering Helpers
; DESCRIPTION:
; Internal probes that gather the runtime snapshot: system info, pause state, keylogger / LLM / layout / hotstrings state, log info, config summary, uptime formatting, and recent-issue extraction.
;
; The HTML rendering is now in the shared frontend _shared/ui/healthcheck/;
; core.ahk injects the snapshot as JSON and the client-side script.js renders
; the report.
;
; Split out of the former infra/healthcheck.ahk (the module split); see
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

_HealthCheck_KeyloggerSummary(SnapshotFn := 0) {
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
	if !HasMethod(SnapshotFn, "Call") && IsSet(KL_HealthSnapshot)
		SnapshotFn := KL_HealthSnapshot
	if HasMethod(SnapshotFn, "Call") {
		Owner := SnapshotFn.Call()
		if !(Owner is Map)
			throw TypeError("Keylogger health owner returned a non-Map snapshot.")
		for Key in ["enabled", "wpm", "events_session", "privacy_hits", "today_log"] {
			if !Owner.Has(Key)
				throw Error("Keylogger health snapshot is missing '" . Key . "'.")
		}
		Sum["enabled"] := Owner["enabled"] ? "true" : "false"
		Sum["wpm"] := Owner["wpm"]
		Sum["events_session"] := Owner["events_session"]
		Sum["privacy_hits"] := Owner["privacy_hits"]
		Sum["today_log"] := Owner["today_log"]
	}
	return Sum
}

_HealthCheck_LLMState(SnapshotFn := 0) {
	St := Map("enabled", "unknown", "backend", "unknown", "active_profile", "unknown", "model", "n/a", "n_predictions", "n/a", "streaming", "n/a")
	if !HasMethod(SnapshotFn, "Call") && IsSet(LLM_Menu_HealthSnapshot)
		SnapshotFn := LLM_Menu_HealthSnapshot
	if !HasMethod(SnapshotFn, "Call")
		return St
	Owner := SnapshotFn.Call()
	if !(Owner is Map) || !Owner.Get("available", false)
		return St
	for Key in ["enabled", "backend", "profile_id", "model", "n_predictions", "streaming"] {
		if !Owner.Has(Key)
			throw Error("LLM health snapshot is missing '" . Key . "'.")
	}
	St["enabled"] := Owner["enabled"] ? "true" : "false"
	St["backend"] := Owner["backend"]
	St["active_profile"] := Owner["profile_id"]
	St["model"] := Owner["model"]
	St["n_predictions"] := Owner["n_predictions"]
	St["streaming"] := Owner["streaming"]
	return St
}

_HealthCheck_LayoutState() {
	St := Map("ergopti_base", "unknown", "altgr", "unknown", "shift", "unknown", "caps", "unknown", "prefix_latch", "clean")
	try {
		global Features
		if IsSet(Features) && Features is Map
			St["ergopti_base"] := Features["layout"]["ergopti_base"] ? "on" : "off"
		St["altgr"] := GetKeyState("RAlt", "P") ? "active" : "off"
		St["shift"] := GetKeyState("Shift", "P") ? "active" : "off"
		St["caps"] := GetKeyState("CapsLock", "T") ? "active" : "off"
		if GetKeyState("SC138") && !GetKeyState("SC138", "P")
			St["prefix_latch"] := "latched (check after suspend)"
	} catch {
	}
	return St
}

_HealthCheck_HotstringsState() {
	St := Map("terminators", 0, "magic_key", "", "personal_count", 0, "dynamic_count", 0, "default_delay", "n/a")
	try {
		global TERMINATORS, DYN_HOTSTRINGS_DEFAULT_DELAY, ScriptInformation, Features
		if IsSet(TERMINATORS) && TERMINATORS is Array
			St["terminators"] := TERMINATORS.Length
		if IsSet(DYN_HOTSTRINGS_DEFAULT_DELAY)
			St["default_delay"] := DYN_HOTSTRINGS_DEFAULT_DELAY
		if IsSet(ScriptInformation) && ScriptInformation is Map
			St["magic_key"] := ScriptInformation.Get("MagicKey", "")
		if IsSet(Features) && Features is Map && Features.Has("hotstrings") {
			Hotstrings := Features["hotstrings"]
			if Hotstrings.Has("personal") && Hotstrings["personal"] is Map
				St["personal_count"] := Hotstrings["personal"].Count
			if Hotstrings.Has("dynamic") && Hotstrings["dynamic"] is Map
				St["dynamic_count"] := Hotstrings["dynamic"].Count
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
		global Features
		if IsSet(Features) && Features is Map {
			Sum["enabled_hotstrings"] := IsCategoryGated("Hotstrings") ? "true" : "false"
			if Features.Has("gestures") && Features["gestures"] is Map
				Sum["enabled_gestures"] := Features["gestures"].Get("enabled", false) ? "true" : "false"
			if Features.Has("llm") && Features["llm"] is Map
				Sum["enabled_llm"] := Features["llm"].Get("enabled", false) ? "true" : "false"
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

