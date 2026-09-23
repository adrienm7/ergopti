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

	; Windows display name + build from the boot snapshot's probe: a raw
	; ProductName read here reported every Windows 11 machine as Windows 10
	OsInfo := DiagSnapshot_OsInfo()
	Info["os_name"]  := OsInfo["os"]
	Info["os_build"] := OsInfo["os_version"]
	Info["os_arch"]  := A_Is64bitOS ? "64 bits" : "32 bits"

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
	; Where the scripts run from, under its own label: in a compiled build it is
	; the extracted bundle, never the configuration folder.
	Info["script_dir"] := A_ScriptDir

	; Commit: the compiled build's BUNDLE_COMMIT stamp, else the source
	; checkout's HEAD read from .git. `git rev-parse` answered nothing for every
	; compiled release (no checkout) and, being a subprocess, had to be polled
	; with a bounded Sleep on the crash-handler path; file reads need neither.
	Commit := DiagSnapshot_ResolveCommit(A_ScriptDir)
	Info["git_hash"] := Commit["commit"]
	Info["commit_source"] := Commit["source"]

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
	; Paths from the logger's resolver, named at call time.
	Sum["today_log"] := LoggerTodayLogPath()
	Sum["errors_log"] := LoggerTodayErrorsPath()
	Sum["notes"] := "High-severity (WARNING/ERROR) lines are also written to today's errors file (Debug > Open today's errors file)"
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
		; RAlt is a plain Alt on a Kana-style layout, whose AltGr is SC138.
		St["altgr"] := GetKeyState(KS_AltGrKeyName(), "P") ? "active" : "off"
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
	Info := Map("logs_dir", "", "unified_today", "", "errors_today", "", "crash_reports_dir", "",
		"errors_sink_active", false, "ring_lines", 0, "note", "Use the dedicated errors log for WARNING/ERROR only — keeps main logs clean.")
	; The logger is the one resolver of the logs folder and of today's files.
	Info["logs_dir"] := LoggerLogsDir()
	Info["unified_today"] := LoggerTodayLogPath()
	Info["errors_today"] := LoggerTodayErrorsPath()
	Info["crash_reports_dir"] := LoggerCrashReportsDir()
	try {
		global LOGGER_ERRORS_LOG_PATH, LOGGER_RING_BUFFER
		; Active once LoggerInit resolved the dated files and the flush owns them.
		Info["errors_sink_active"] := IsSet(LOGGER_ERRORS_LOG_PATH) && LOGGER_ERRORS_LOG_PATH != ""
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

; Extracts the last N WARNING and ERROR lines from the in-memory ring buffer:
; the fallback of _HealthCheck_RecentIssues when today's errors file does not
; exist yet.
_HealthCheck_RingIssues(MaxLines) {
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

; Loads the recent-issue bounds shared by the three drivers.
; @returns {Map} { tail_max_bytes, max_entries }
; @throws {ValueError} When the shared file is missing a positive integer bound.
_HealthCheck_RecentIssueLimits() {
	global _SharedDir
	Path := _SharedDir . "\modules\diagnostics\recent_issues.json"
	Data := JsonParse(FileRead(Path, "UTF-8"))
	Limits := Map(
		"tail_max_bytes", Data.Get("errors_tail_max_bytes", 0),
		"max_entries",    Data.Get("max_entries", 0))
	for Name, Value in Limits {
		if !(Value is Integer) || Value < 1
			throw ValueError("Recent issue limit '" . Name . "' must be a positive integer in " . Path . ".")
	}
	return Limits
}

; Reads at most MaxBytes from the end of a file, as raw bytes decoded as UTF-8.
; @param Path {String}
; @param MaxBytes {Integer}
; @returns {Map|Integer} { chunk, at_file_start }, or 0 when the file does not exist.
_HealthCheck_ReadTail(Path, MaxBytes) {
	if !FileExist(Path)
		return 0
	; UTF-8-RAW: positions are bytes and no byte order mark is skipped, so the
	; offset below is exact and the parser sees the file as written
	File := FileOpen(Path, "r", "UTF-8-RAW")
	try {
		Size := File.Length
		Start := Max(0, Size - MaxBytes)
		File.Pos := Start
		Bytes := Buffer(Max(1, Size - Start))
		Read := File.RawRead(Bytes, Size - Start)
	} finally {
		File.Close()
	}
	return Map("chunk", _HealthCheck_DecodeTail(Bytes, Read), "at_file_start", Start == 0)
}

; Decodes tail bytes as UTF-8. A read that began inside a sequence decodes its
; first bytes to U+FFFD, on the first line the parser always drops.
; @param Bytes {Buffer}
; @param Length {Integer} Byte count.
; @returns {String}
_HealthCheck_DecodeTail(Bytes, Length) {
	return (Length > 0) ? StrGet(Bytes, Length, "UTF-8") : ""
}

; Turns the tail of an errors file into its WARNING and ERROR entries: the AHK
; copy of the shared parse_errors_tail (_shared/lua/healthcheck/snapshot.lua),
; pinned by _shared/tests/corpus/healthcheck/errors_tail_vectors.json.
; @param Chunk {String} Text read from the end of the file.
; @param AtFileStart {Boolean} True when the read began at byte 0.
; @param MaxEntries {Integer} How many of the newest entries to keep.
; @returns {Array} Entries, oldest first.
_HealthCheck_ParseErrorsTail(Chunk, AtFileStart, MaxEntries) {
	Text := Chunk
	if (AtFileStart && SubStr(Text, 1, 1) == Chr(0xFEFF))
		Text := SubStr(Text, 2)
	Text := StrReplace(StrReplace(Text, "`r`n", "`n"), "`r", "`n")
	Entries := []
	; Index of the entry continuation lines join; -1 inside an entry of another
	; level, 0 before the first entry
	Current := 0
	for Index, Line in StrSplit(Text, "`n") {
		; A read that did not start at byte 0 began inside a line
		if ((Index == 1 && !AtFileStart) || Line == "")
			continue
		if RegExMatch(Line, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3} \[([A-Z]+)\] ", &Match) {
			if (Match[1] == "WARNING" || Match[1] == "ERROR") {
				Entries.Push(Line)
				Current := Entries.Length
			} else {
				Current := -1
			}
		} else if (Current > 0) {
			Entries[Current] := Entries[Current] . "`n" . Line
		}
	}
	if (Entries.Length <= MaxEntries)
		return Entries
	Newest := []
	Loop MaxEntries
		Newest.Push(Entries[Entries.Length - MaxEntries + A_Index])
	return Newest
}

; Today's errors file, as the logger names it: the one accessor the healthcheck
; reads it through, so the logs-folder owner can move it.
; @returns {String} "" before the logger has resolved its paths.
_HealthCheck_ErrorsLogPath() {
	global LOGGER_ERRORS_LOG_PATH
	return IsSet(LOGGER_ERRORS_LOG_PATH) ? LOGGER_ERRORS_LOG_PATH : ""
}

; The window's recent warnings and errors: the tail of today's errors file, or
; the ring when that file does not exist yet. The ring holds every level, so at
; DEBUG a few minutes of routine lines evicted the problems the window is
; opened to show; the errors file keeps WARNING and ERROR only.
; @param ErrorsPath {String} Today's errors file ("" when the logger has none).
; @returns {Map} { entries: Array oldest first, source: "errors_file" | "ring" }
_HealthCheck_RecentIssues(ErrorsPath) {
	Limits := _HealthCheck_RecentIssueLimits()
	Tail := (ErrorsPath != "") ? _HealthCheck_ReadTail(ErrorsPath, Limits["tail_max_bytes"]) : 0
	if (Tail is Map) {
		return Map(
			"entries", _HealthCheck_ParseErrorsTail(Tail["chunk"], Tail["at_file_start"], Limits["max_entries"]),
			"source",  "errors_file")
	}
	return Map("entries", _HealthCheck_RingIssues(Limits["max_entries"]), "source", "ring")
}
