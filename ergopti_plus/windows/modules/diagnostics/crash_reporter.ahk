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
; 1. Nothing is collected about the user: keystrokes, file contents, network
;    names and the account name are never included, not even hashed.
; 2. No confirmation: the old opt-in prompt added friction with zero privacy
;    benefit — the report is local-only. The user is told the path of the
;    saved file.
; 3. Full detail locally: the error, its stack, the log tail and the window
;    context are kept whole, since a report stripped of them cannot be
;    triaged. The file never leaves the machine by itself; whatever is copied,
;    saved for GitHub or sent is redacted at that boundary (Redact_Apply in the
;    error and diagnostics windows).
; 4. Logs-scoped directory: reports live in <logs>\crash_reports\
;    (LoggerCrashReportsDir), beside the daily log that explains them, and
;    follow a LogsDirPath override.
; 5. Structured output: reports are written as JSON for easy machine and human
;    readability, one file per incident.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

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
; Captures the error in full with the structured system, adapter and session
; state; nothing is redacted here, the report stays on this machine.
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
	; The version 2 snapshot's sections (_shared/modules/diagnostics/schema.json).
	; _HealthCheck_Collect substitutes an EMPTY Map when a collector throws, so
	; every read below goes through .Get.
	Sections := (HC is Map && HC.Has("sections")) ? HC["sections"] : Map()
	; ── Full system info ───────────────────────────────────────────────────────
	; The healthcheck already read the processor from the registry: reusing it
	; keeps the WMI query of _CrashReport_SysInfo off the crash handler's deferred
	; timer, which shares the keyboard hook's thread (crash-report-sysinfo-dedup).
	Sys := _CrashReport_SysInfo(Sections.Get("hardware", Map()))
	; Each field is enriched independently and read with .Get: a degraded
	; section must not take the next one with it.
	try {
		Input := Sections.Get("input", Map())
		if Input.Has("paused")
			Sys["pause_at_crash"] := Input["paused"] ? "paused" : "running"
	} catch as Err {
		try LoggerDebug("CrashReporter", "Crash report enrichment 'input' degraded: {1}.", Err.Message)
	}
	try {
		Sys["errors_log_path"] := Sections.Get("paths", Map()).Get("errors_today", "")
	} catch as Err {
		try LoggerDebug("CrashReporter", "Crash report enrichment 'paths' degraded: {1}.", Err.Message)
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
	try StuckMods := _CrashReport_StuckModifiers()
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
			Developer      := Sections.Get("developer", Map())
			Issues         := Sections.Get("issues", Map())
			AdaptersOk     := _CrashReport_JoinArr(Developer.Get("modules_ok", []))
			AdaptersFailed := _CrashReport_JoinArr(Developer.Get("modules_failed", []))
			WarnCount      := String(Issues.Get("warn_count", "unknown"))
			ErrCount       := String(Issues.Get("err_count", "unknown"))
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
	; Captured once, whole: the lines leading to a crash are what explains it.
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
		; ── The log tail, whole; redacted only where a report is shared ──
		"log_tail",             LogLines,
	)

	try LoggerDone("CrashReporter", "Crash report built (ts={1}, type={2}).", Ts, ErrorType)
	return Report
}

; The crash folder resolved by the logger, exposed to the diagnostics page.
; @return {String} Absolute path without a trailing separator.
CrashReport_Dir() {
	return RTrim(LoggerCrashReportsDir(), "\/")
}

; Writes a crash report Map beside the logger-owned daily log.
; Creates the directory on demand. Returns the file path on success, or "" on failure.
; @param Report {Map} The report Map returned by CrashReport_Build().
; @param WriterFn {Func|Integer} Optional durable-writer seam for regression coverage.
; @return {String} Absolute path to the written file, or "" on failure.
CrashReport_Save(Report, WriterFn := 0) {
	try LoggerStart("CrashReporter", "Saving crash report to disk…")

	; The logger is the one resolver of the crash-reports folder.
	ReportDir := LoggerCrashReportsDir()

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
	ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteDurable

	try {
		; A crash artifact is acknowledged only after its complete UTF-8 image has
		; crossed the stable-storage boundary. A short write must remove its partial
		; JSON rather than publishing a plausible path to an unreadable report.
		if ResolvedWriter.Call(FName, JsonStr) != true
			throw Error("durable crash report write was refused")
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
; @param Hardware {Map} The diagnostics snapshot's hardware section: its
;   processor is reused, and WMI is asked only when it has none.
_CrashReport_SysInfo(Hardware := 0) {
	Info := Map()

	; The boot snapshot's probe, so a crash on Windows 11 is not filed as Windows 10
	OsInfo := DiagSnapshot_OsInfo()
	Info["os_name"]  := OsInfo["os"]
	Info["os_build"] := OsInfo["os_version"]
	Info["os_arch"]  := A_Is64bitOS ? "64 bits" : "32 bits"

	CpuName  := "unknown"
	CpuCores := ""
	if (Hardware is Map) && Hardware.Has("cpu") {
		CpuName  := Hardware["cpu"]
		CpuCores := Hardware.Get("cpu_cores", "")
	} else {
		try {
			WMI  := ComObject("WbemScripting.SWbemLocator").ConnectServer()
			Qry  := WMI.ExecQuery("SELECT Name, NumberOfLogicalProcessors FROM Win32_Processor")
			Enum := Qry._NewEnum()
			if Enum.Next(&Item) {
				CpuName  := Trim(Item.Name)
				CpuCores := Item.NumberOfLogicalProcessors
			}
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

	; Same resolver as the healthcheck and the boot snapshot: the compiled
	; build's stamp, else the checkout's HEAD, without spawning git.
	Commit := DiagSnapshot_ResolveCommit(A_ScriptDir)
	Info["git_hash"] := Commit["commit"]
	Info["commit_source"] := Commit["source"]

	return Info
}

; Returns an ISO-8601 UTC timestamp string.
; @return {String} Timestamp in the form "YYYY-MM-DDTHH:MM:SSZ".
_CrashReport_IsoTimestamp() {
	; A_NowUTC gives UTC time; FormatTime with no first arg gives local time.
	; The trailing 'Z' must be a UTC value, not local time relabelled as UTC.
	return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ss") . "Z"
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
		"locale", "script_dir", "git_hash",
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
	return _CrashReport_EncodeFields(Report, _CrashReport_CanonicalFields())
}

; The isolated worker needs two raw paths to perform its local git probe and
; choose the destination directory. They live in pagefile-backed IPC only and
; are removed by both worker implementations before the canonical artifact is
; written; the report fields travel whole, as the local report keeps them.
_CrashReport_ToWorkerJson(Report) {
	Fields := _CrashReport_CanonicalFields()
	for Key in ["_transport_script_dir", "_transport_reports_dir"] {
		if Report.Has(Key)
			Fields.Push(Key)
	}
	return _CrashReport_EncodeFields(Report, Fields)
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

; Modifier keys physically held when the report is built. A Kana-style
; layout's AltGr is SC138, not RAlt, so the layout's AltGr key is inspected too.
; @return {Array} The held modifier key names.
_CrashReport_StuckModifiers() {
	global _CrashReporter_Modifiers
	Keys := _CrashReporter_Modifiers.Clone()
	if (KS_AltGrKeyName() != "RAlt")
		Keys.Push(KS_AltGrKeyName())
	Held := []
	for _, ModKey in Keys {
		if GetKeyState(ModKey, "P")
			Held.Push(ModKey)
	}
	return Held
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
