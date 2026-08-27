; modules/diagnostics/crash_reporter.ahk

; ==============================================================================
; MODULE: Crash Reporter
; DESCRIPTION:
; Automatic crash report builder and persistence layer for the AutoHotkey driver.
; When the global error handler fires, this module saves a full diagnostic report
; to disk immediately — no confirmation step — and shows the user the file path.
; No network calls are ever made.
;
; FEATURES & RATIONALE:
; 1. Privacy-first: keystrokes, file contents, SSID, and raw usernames are
;    never included. The username is hashed (FNV-1a fold) so incidents from
;    the same user can be correlated without revealing the identity.
; 2. No confirmation: the old opt-in prompt added friction with zero privacy
;    benefit — the report is local-only and contains no PII. The user sees a
;    single dialog showing the path of the saved file.
; 3. Privacy-bounded diagnostics: the report keeps structured system, adapter,
;    and session state while replacing free-form error text, paths, window
;    context, and log bodies with explicit redaction markers.
; 4. Driver-scoped directory: reports live under <config_dir>/autohotkey/crash_reports/
;    so they are co-located with the AHK logs and config under the autohotkey/
;    subfolder, separate from any Hammerspoon reports.
; 5. Structured output: reports are written as JSON for easy machine and human
;    readability, one file per incident.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Subdirectory under the config dir that receives all AHK crash report files.
; Nested under autohotkey/ to mirror the driver folder layout and stay separate
; from any Hammerspoon reports under hammerspoon/.
global _CrashReporter_Subdir := "autohotkey\crash_reports"

; Modifier keys to inspect for stuck state at crash time.
global _CrashReporter_Modifiers := [
	"LControl", "RControl",
	"LShift",   "RShift",
	"LAlt",     "RAlt",
	"LWin",     "RWin",
]





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

; Builds a rich crash report Map from an AHK Error object.
; Captures structured system, adapter, and session state, then replaces every
; free-form privacy source with an explicit marker before returning.
; @param ErrorObj {Error} The AHK v2 Error object caught by the global handler.
; @return {Map} Report with all diagnostic fields documented below.
CrashReport_Build(ErrorObj) {
	try LoggerTrace("CrashReporter", "Building crash report…")

	; ── Error fields ─────────────────────────────────────────────────────────
	ErrorMsg   := ""
	StackTrace := ""
	ErrorType  := ""
	ErrorExtra := ""
	ErrorWhat  := ""
	ErrorLine  := ""
	ErrorFile  := ""

	try ErrorMsg   := ErrorObj.Message
	try StackTrace := ErrorObj.HasProp("Stack") ? ErrorObj.Stack : ""
	try ErrorType  := Type(ErrorObj)
	try ErrorExtra := ErrorObj.HasProp("Extra") ? String(ErrorObj.Extra) : ""
	try ErrorWhat  := ErrorObj.HasProp("What")  ? String(ErrorObj.What)  : ""
	try ErrorLine  := ErrorObj.HasProp("Line")  ? String(ErrorObj.Line)  : ""
	try ErrorFile  := ErrorObj.HasProp("File")  ? String(ErrorObj.File)  : ""

	; ── Driver version ────────────────────────────────────────────────────────
	Version := "unknown"
	try Version := Updater_CurrentVersion()

	; ── Timestamp ────────────────────────────────────────────────────────────
	Ts := _CrashReport_IsoTimestamp()

	; Run the healthcheck EXACTLY ONCE per crash and reuse its result for both the
	; enriched system fields and the adapter / session block below. HealthCheck_Run
	; re-validates every port adapter and is non-trivial work; the error handler
	; fires at an arbitrary point (potentially mid-keystroke) with the keyboard
	; already degraded, so a second redundant run only widens the input-dead window.
	HC := ""
	try HC := HealthCheck_Run()
	; ── Full system info (mirrors healthcheck _HealthCheck_SysInfo + enriched fields) ──────────
	; HC["sys"] already ran the exact same WMI ConnectServer / RegRead / git-subprocess
	; probes above via HealthCheck_Run — recomputing them here would double that
	; blocking work on the crash handler's deferred timer (crash-report-sysinfo-dedup).
	; Only fall back to a fresh probe if the healthcheck itself failed to produce one.
	; .Count > 0, not just .Has(). _HealthCheck_Collect substitutes an EMPTY Map
	; when a collector throws, and the healthcheck result always carries the "sys"
	; key — so testing presence alone made this fallback unreachable dead code,
	; and every Sys[...] read below would then throw on the missing key. That
	; would abort CrashReport_Build inside the error net's catch: logged, never
	; reported. Which is precisely the failure the healthcheck's own degradation
	; was added to prevent.
	Sys := (HC != "" and HC.Has("sys") and HC["sys"].Count > 0) ? HC["sys"] : _CrashReport_SysInfo()
	; Pull a few safe enriched fields from the live healthcheck for even richer crash reports (pause state, key logs paths, etc.)
	; Each field is enriched independently and read with .Get. The outer keys
	; were guarded but the INNER ones were not, and both lived in one try — so a
	; degraded pause_state Map threw and silently took errors_log_path with it,
	; into a bare catch that recorded nothing.
	if (HC != "") {
		try {
			if (HC.Has("pause_state") and HC["pause_state"].Count > 0)
				Sys["pause_at_crash"] := HC["pause_state"].Get("is_paused", false) ? "paused" : "running"
		} catch as Err {
			try LoggerDebug("CrashReporter", "Crash report enrichment 'pause_state' degraded: {1}.", Err.Message)
		}
		try {
			if (HC.Has("logs") and HC["logs"].Count > 0)
				Sys["errors_log_path"] := HC["logs"].Get("errors_today", "")
		} catch as Err {
			try LoggerDebug("CrashReporter", "Crash report enrichment 'logs' degraded: {1}.", Err.Message)
		}
	}

	; ── Uptime ────────────────────────────────────────────────────────────────
	; -1, not 0: a genuine cold start reports 0, so an unset _HealthCheckStartMs
	; reporting 0 too would hide the difference on the one artifact meant to
	; explain what state the driver was in.
	UptimeSec := -1
	try {
		global _HealthCheckStartMs
		if IsSet(_HealthCheckStartMs)
			UptimeSec := (A_TickCount - (_HealthCheckStartMs) & 0xFFFFFFFF) // 1000
	}

	; ── Active window context ─────────────────────────────────────────────────
	ActiveWindowTitle   := ""
	ActiveWindowProcess := ""
	try ActiveWindowTitle   := WinGetTitle("A")
	try ActiveWindowProcess := WinGetProcessName("A")

	; ── Stuck modifiers ───────────────────────────────────────────────────────
	StuckMods := []
	try {
		global _CrashReporter_Modifiers
		for _, ModKey in _CrashReporter_Modifiers {
			if GetKeyState(ModKey, "P")
				StuckMods.Push(ModKey)
		}
	}
	StuckModsStr := (StuckMods.Length > 0) ? _CrashReport_JoinArr(StuckMods) : "none"

	; ── Adapter / port status (mirrors the healthcheck adapter validation) ──────────
	; Reuse the single healthcheck result captured above — never re-run it.
	AdaptersOk     := ""
	AdaptersFailed := ""
	WarnCount      := "0"
	ErrCount       := "0"
	try {
		if (HC != "") {
			; .Get throughout: these come from the healthcheck, which degrades a
			; failed collector to an empty Map. A raw read threw into a catch-less
			; try, leaving ErrCount at "0" — indistinguishable from a genuine
			; clean session, on a report written because something crashed.
			AdaptersOk     := _CrashReport_JoinArr(HC.Get("ports_validated", []))
			AdaptersFailed := _CrashReport_JoinArr(HC.Get("failed_adapters", []))
			WarnCount      := String(HC.Get("warn_count", "unknown"))
			ErrCount       := String(HC.Get("err_count", "unknown"))
		}
	}

	; ── Module state ──────────────────────────────────────────────────────────
	KeyloggerInit := "unknown"
	ConfigDir     := ""
	try KeyloggerInit := Keylogger.initialized ? "true" : "false"
	try {
		global _ConfigDir
		ConfigDir := _ConfigDir
	}

	; ── In-memory log ring buffer (all 200 lines, most recent last) ───────────
	; Capture once so the redaction boundary can retain the line count. The raw
	; bodies never leave CrashReport_Build or reach the artifact.
	LogLines := ""
	try {
		Snapshot := LoggerRingBufferSnapshot()
		Parts    := []
		for _, Line in Snapshot
			Parts.Push(Line)
		LogLines := _CrashReport_JoinNewlines(Parts)
	}

	Report := Map(
		; ── Identification ──
		"version",              Version,
		"driver",               "autohotkey",
		"timestamp",            Ts,
		; ── Error details ──
		"error_type",           ErrorType,
		"error_msg",            ErrorMsg,
		"error_extra",          ErrorExtra,
		"error_what",           ErrorWhat,
		"error_file",           ErrorFile,
		"error_line",           ErrorLine,
		"stack_trace",          StackTrace,
		; ── System environment (full, mirrors healthcheck) ──
		"os_name",              Sys.Get("os_name", ""),
		"os_build",             Sys.Get("os_build", ""),
		"os_arch",              Sys.Get("os_arch", ""),
		"ahk_version",          Sys.Get("ahk_version", ""),
		"ahk_bitness",          Sys.Get("ahk_bitness", ""),
		"cpu_name",             Sys.Get("cpu_name", ""),
		"cpu_cores",            String(Sys.Get("cpu_cores", "")),
		"ram_total_gb",         String(Sys.Get("ram_total_gb", "")),
		"ram_free_gb",          String(Sys.Get("ram_free_gb", "")),
		"screen_resolution",    Sys.Get("screen_res", ""),
		"dpi",                  String(Sys.Get("dpi", "")),
		"dpi_scale",            String(Sys.Get("dpi_scale", "")),
		"locale",               Sys.Get("locale", ""),
		"script_dir",           A_ScriptDir,
		"git_hash",             Sys.Get("git_hash", ""),
		"username_hash",        _CrashReport_FoldHash(A_UserName),
		; ── Runtime context ──
		"uptime_sec",           String(UptimeSec),
		"active_window_title",  ActiveWindowTitle,
		"active_window_process", ActiveWindowProcess,
		"stuck_modifiers",      StuckModsStr,
		; ── Adapter / session health ──
		"adapters_ok",          AdaptersOk,
		"adapters_failed",      AdaptersFailed,
		"session_warnings",     WarnCount,
		"session_errors",       ErrCount,
		; ── Module state ──
		"keylogger_initialized", KeyloggerInit,
		"config_dir",           ConfigDir,
		; ── Log line-count source; bodies are redacted before publication ──
		"log_tail",             LogLines,
	)

	try LoggerDone("CrashReporter", "Crash report built (ts={1}, type={2}).", Ts, ErrorType)
	return _CrashReport_RedactCanonical(Report)
}

; Writes a crash report Map to disk as a JSON file under autohotkey/crash_reports/.
; Creates the directory on demand. Returns the file path on success, or "" on failure.
; @param Report {Map} The report Map returned by CrashReport_Build().
; @return {String} Absolute path to the written file, or "" on failure.
CrashReport_Save(Report) {
	global _ConfigDir, _CrashReporter_Subdir

	try LoggerStart("CrashReporter", "Saving crash report to disk…")

	BaseDir := ""
	try BaseDir := _ConfigDir
	if (BaseDir == "")
		try BaseDir := EnvGet("USERPROFILE") . "\.config\ergopti_plus\"
	if !(BaseDir ~= "[/\\]$")
		BaseDir .= "\"
	ReportDir := BaseDir . _CrashReporter_Subdir . "\"

	try DirCreate(ReportDir)

	Ts   := Report.Has("timestamp") ? Report["timestamp"] : _CrashReport_IsoTimestamp()
	Base := ReportDir . StrReplace(Ts, ":", "-")
	FName := Base . ".json"
	n := 1
	while FileExist(FName) {
		FName := Base . "_" . n . ".json"
		n += 1
	}

	JsonStr := _CrashReport_ToJson(Report)

	try {
		; Truncating write (mode "w") — unique suffix loop above prevents a same-second incident
		; from appending into the first report and producing invalid JSON
		f := FileOpen(FName, "w", "UTF-8-RAW")
		f.Write(JsonStr)
		f.Close()
		try LoggerSuccess("CrashReporter", "Crash report saved: {1}.", FName)
		return FName
	} catch as WriteErr {
		try LoggerError("CrashReporter", "Write failed for '{1}': {2}.", FName, WriteErr.Message)
		return ""
	}
}

; Saves the crash report immediately (no confirmation) then shows the user a
; single dialog with the path of the saved file. If saving fails, shows an error.
; Safe to call from within ErgoptiGlobalErrorHandler — all calls are guarded.
; @param Report {Map} The report Map returned by CrashReport_Build().
; @returns {Boolean} True when a report file was actually written. The caller
;          needs this: the error net throttles by fault signature, and a
;          throttle recorded for a report that was never saved silences every
;          recurrence for the whole TTL.
CrashReport_PromptUser(Report) {
	try LoggerStart("CrashReporter", "Saving crash report…")

	FilePath := CrashReport_Save(Report)

	if (FilePath != "") {
		try LoggerSuccess("CrashReporter", "Crash report saved at '{1}'.", FilePath)
		; Surface non-blocking — a modal MsgBox on the input thread starves the keyboard hook
		try NotifierSend(FilePath, Map("title", t("crash.report.saved_title"), "level", "info"))
		return true
	}
	try LoggerWarn("CrashReporter", "Crash report could not be saved.")
	try NotifierSend(t("crash.report.save_failed"), Map("title", t("crash.report.saved_title"), "level", "warning"))
	return false
}





; ==========================
; ==========================
; ======= 3/ Helpers =======
; ==========================
; ==========================

; Returns a Map with full OS, CPU, RAM, screen, AHK, and git fields.
; Mirrors _HealthCheck_SysInfo() so the crash report is a superset of the
; healthcheck diagnostic without duplicating the collection logic.
_CrashReport_SysInfo() {
	Info := Map()

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

	CpuName  := "unknown"
	CpuCores := ""
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

	RamTotalGb := "?"
	RamFreeGb  := "?"
	try {
		MemStatus := Buffer(64, 0)
		NumPut("UInt", 64, MemStatus, 0)
		if DllCall("GlobalMemoryStatusEx", "Ptr", MemStatus) {
			TotalBytes := NumGet(MemStatus, 8,  "UInt64")
			AvailBytes := NumGet(MemStatus, 16, "UInt64")
			RamTotalGb := Format("{:.1f}", TotalBytes / 1073741824)
			RamFreeGb  := Format("{:.1f}", AvailBytes / 1073741824)
		}
	}
	Info["ram_total_gb"] := RamTotalGb
	Info["ram_free_gb"]  := RamFreeGb

	Info["screen_res"] := A_ScreenWidth . "x" . A_ScreenHeight
	Info["dpi"]        := A_ScreenDPI
	Info["dpi_scale"]  := Round(A_ScreenDPI / 96 * 100)
	Info["ahk_version"] := A_AhkVersion
	Info["ahk_bitness"] := (A_PtrSize = 8) ? "64-bit" : "32-bit"
	Info["locale"]      := A_Language

	GitHash := ""
	try {
		TmpFile := A_Temp . "\ergopti_cr_hash_" . A_TickCount . "_" . A_PtrSize . ".txt"
		; Use Run (non-blocking) instead of RunWait to avoid a 30-second hang when
		; git is unavailable or the repo is on a disconnected network drive.
		Run(A_ComSpec . " /c git -C " . Chr(34) . A_ScriptDir . Chr(34)
			. " rev-parse --short HEAD > " . Chr(34) . TmpFile . Chr(34), , "Hide")
		StartedTick := A_TickCount
		while (!FileExist(TmpFile) and !TickExpired(StartedTick, 500))
			Sleep(50)
		if FileExist(TmpFile) {
			GitHash := Trim(FileRead(TmpFile, "UTF-8"))
			try FileDelete(TmpFile)
		}
	}
	Info["git_hash"] := GitHash

	return Info
}

; Returns an ISO-8601 UTC timestamp string.
; @return {String} Timestamp in the form "YYYY-MM-DDTHH:MM:SSZ".
_CrashReport_IsoTimestamp() {
	; A_NowUTC gives UTC time; FormatTime with no first arg gives local time.
	; The trailing 'Z' must be a UTC value, not local time relabelled as UTC.
	return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ss") . "Z"
}

; FNV-1a 32-bit fold: stable, non-reversible hex digest of a string.
; @param Str {String}
; @return {String} Eight-character lowercase hex string.
_CrashReport_FoldHash(Str) {
	Acc := 0x811C9DC5
	Loop StrLen(Str) {
		Acc := ((Acc ^ Ord(SubStr(Str, A_Index, 1))) * 0x01000193) & 0xFFFFFFFF
		Acc := ((Acc >> 3) | (Acc << 29)) & 0xFFFFFFFF
	}
	return Format("{:08x}", Acc)
}

; Replaces every free-form source that can carry user data while preserving the
; canonical schema. The function clones its input so a caller retaining the
; diagnostic Map never observes a half-redacted mutation.
_CrashReport_RedactCanonical(Report) {
	if !(Report is Map)
		return Map()
	Redacted := Report.Clone()
	Fixed := Map(
		"error_msg", "[redacted error message]",
		"error_extra", "[redacted error context]",
		"error_what", "[redacted error context]",
		"error_file", "[redacted source path]",
		"script_dir", "[redacted path]",
		"active_window_title", "[redacted window title]",
		"active_window_process", "[redacted process]",
		"config_dir", "[redacted path]")
	for Key, Marker in Fixed {
		if Redacted.Has(Key) && String(Redacted[Key]) != ""
			Redacted[Key] := Marker
	}
	for Key, Label in Map("stack_trace", "stack", "log_tail", "log") {
		if !Redacted.Has(Key)
			continue
		Value := String(Redacted[Key])
		if (Value == "")
			continue
		if RegExMatch(Value, "^\[redacted \d+ " . Label . " lines?\]$")
			continue
		LineCount := StrLen(Value) - StrLen(StrReplace(Value, "`n")) + 1
		Redacted[Key] := "[redacted " . LineCount . " " . Label
			. (LineCount == 1 ? " line]" : " lines]")
	}
	return Redacted
}

_CrashReport_CanonicalFields() {
	return [
		"version", "driver", "timestamp",
		"error_type", "error_msg", "error_extra", "error_what",
		"error_file", "error_line", "stack_trace",
		"os_name", "os_build", "os_arch",
		"ahk_version", "ahk_bitness",
		"cpu_name", "cpu_cores",
		"ram_total_gb", "ram_free_gb",
		"screen_resolution", "dpi", "dpi_scale",
		"locale", "script_dir", "git_hash", "username_hash",
		"uptime_sec", "active_window_title", "active_window_process",
		"stuck_modifiers",
		"adapters_ok", "adapters_failed",
		"session_warnings", "session_errors",
		"keylogger_initialized", "config_dir",
		"log_tail"
	]
}

; Serialises a crash report Map to a formatted JSON string.
; @param Report {Map}
; @return {String} Pretty-printed JSON string.
_CrashReport_ToJson(Report) {
	return _CrashReport_EncodeFields(
		_CrashReport_RedactCanonical(Report), _CrashReport_CanonicalFields())
}

; The isolated worker needs two raw paths to perform its local git probe and
; choose the destination directory. They live in pagefile-backed IPC only and
; are removed by both worker implementations before the canonical artifact is
; written. Every report field in the same envelope is already redacted.
_CrashReport_ToWorkerJson(Report) {
	SafeReport := _CrashReport_RedactCanonical(Report)
	Fields := _CrashReport_CanonicalFields()
	for Key in ["_transport_script_dir", "_transport_config_dir"] {
		if SafeReport.Has(Key)
			Fields.Push(Key)
	}
	return _CrashReport_EncodeFields(SafeReport, Fields)
}

_CrashReport_EncodeFields(Report, Fields) {
	Parts := []
	Q     := Chr(34)

	for _, Key in Fields {
		Val := Report.Has(Key) ? String(Report[Key]) : ""
		Val := StrReplace(Val, "\",  "\\")
		Val := StrReplace(Val, Q,   "\" . Q)
		Val := StrReplace(Val, "`r", "\r")
		Val := StrReplace(Val, "`n", "\n")
		Val := StrReplace(Val, "`t", "\t")
		; Every OTHER C0 control character must be escaped too, or the report is
		; a file no JSON parser will read — and this is the one artifact that
		; exists to be read after a crash. error_msg, stack_trace and log_tail
		; all carry text the driver did not author, so a stray 0x00-0x1F is not
		; hypothetical enough to leave unhandled.
		Loop 32 {
			Code := A_Index - 1
			if (Code = 9 or Code = 10 or Code = 13)
				continue  ; already handled above
			Val := StrReplace(Val, Chr(Code), Format("\u{:04x}", Code))
		}
		Parts.Push("  " . Q . Key . Q . ": " . Q . Val . Q)
	}

	return "{`r`n" . _CrashReport_JoinParts(Parts) . "`r`n}"
}

; Joins an array of strings with ",`r`n" separators.
; @param Parts {Array}
; @return {String}
_CrashReport_JoinParts(Parts) {
	Result := ""
	for Idx, Item in Parts
		Result .= (Idx > 1 ? ",`r`n" : "") . Item
	return Result
}

; Joins an array of strings with ", " separator for inline display.
; @param Arr {Array}
; @return {String}
_CrashReport_JoinArr(Arr) {
	Result := ""
	for Idx, Item in Arr
		Result .= (Idx > 1 ? ", " : "") . Item
	return Result
}

; Joins an array of strings with newline separators for the log_tail field.
; @param Lines {Array}
; @return {String}
_CrashReport_JoinNewlines(Lines) {
	Result := ""
	for Idx, Item in Lines
		Result .= (Idx > 1 ? "`n" : "") . Item
	return Result
}
