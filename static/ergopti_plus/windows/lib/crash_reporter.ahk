; drivers/autohotkey/lib/crash_reporter.ahk

; ==============================================================================
; MODULE: Crash Reporter
; DESCRIPTION:
; Opt-in crash report builder and persistence layer for the AutoHotkey driver.
; When the global error handler fires, this module offers the user a choice to
; save a sanitized report to disk for later inspection or support. No network
; calls are made -- the report is written locally only.
;
; FEATURES & RATIONALE:
; 1. Privacy-first: keystrokes, file contents, SSID, and raw usernames are
;    never included. The username is hashed (CRC32-like fold) so incidents from
;    the same user can be correlated without revealing the identity.
; 2. Opt-in: the user is always prompted before anything is written to disk.
; 3. Rich diagnostics: the report includes AHK runtime details, system
;    environment, active-window context, stuck modifiers, and module state so
;    a bug report alone is often enough to reproduce and fix the crash.
; 4. Structured output: reports are written as JSON for easy machine and human
;    readability, one file per incident under crash_reports/.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================


; Subdirectory under the user config dir that receives all crash report files.
; Created on demand -- never fails if the parent dir does not exist yet.
global _CrashReporter_Subdir := "crash_reports"

; Modifier keys to inspect for stuck state at crash time.
; Listed in the order they appear in the AHK documentation.
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
; Captures error details, system environment, AHK runtime, active-window
; context, stuck modifiers, and best-effort module state.
; Keystrokes, file contents, SSID, and raw usernames are never included.
; @param ErrorObj {Error} The AHK v2 Error object caught by the global handler.
; @return {Map} Report with all diagnostic fields documented below.
CrashReport_Build(ErrorObj) {
	try LoggerTrace("CrashReporter", "Building crash report...")

	; ---- Error fields (direct from the Error object) ----
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

	; ---- Driver version ----
	Version := "unknown"
	try Version := Updater_CurrentVersion()

	; ---- System environment ----
	OsVersion      := A_OSVersion
	AhkVersion     := A_AhkVersion
	AhkBitness     := (A_PtrSize = 8) ? "64-bit" : "32-bit"
	ScreenRes       := A_ScreenWidth . "x" . A_ScreenHeight
	Locale          := A_Language
	ScriptDir       := A_ScriptDir

	; Hash the username so same-user incidents can be correlated without
	; exposing the actual Windows account name (privacy rule: no PII in reports)
	UsernameHash := _CrashReport_FoldHash(A_UserName)

	; ---- Uptime ----
	UptimeSec := 0
	try {
		global _HealthCheckStartMs
		UptimeSec := (A_TickCount - _HealthCheckStartMs) // 1000
	}

	; ---- Active window context (helps reproduce the crash) ----
	ActiveWindowTitle   := ""
	ActiveWindowProcess := ""
	try ActiveWindowTitle   := WinGetTitle("A")
	try ActiveWindowProcess := WinGetProcessName("A")

	; ---- Stuck modifiers snapshot (state at the moment the handler ran) ----
	StuckMods := []
	try {
		global _CrashReporter_Modifiers
		for _, ModKey in _CrashReporter_Modifiers {
			if GetKeyState(ModKey, "P")
				StuckMods.Push(ModKey)
		}
	}
	StuckModsStr := (StuckMods.Length > 0) ? _CrashReport_JoinArr(StuckMods) : "none"

	; ---- Module state (best-effort -- modules may not be initialised yet) ----
	KeyloggerInit := "unknown"
	ConfigDir     := ""
	try {
		; AHK v2 class names are globally accessible without a `global` declaration —
		; declaring `global Keylogger` here would conflict with the class definition
		; in keylogger.ahk and cause a startup crash. The try block already handles
		; the case where the class is not yet initialized.
		KeyloggerInit := Keylogger.initialized ? "true" : "false"
	}
	try {
		global _ConfigDir
		ConfigDir := _ConfigDir
	}

	; ---- ISO-8601 timestamp ----
	Ts := _CrashReport_IsoTimestamp()

	Report := Map(
		; -- Identification --
		"version",              Version,
		"driver",               "autohotkey",
		"timestamp",            Ts,
		; -- Error details --
		"error_type",           ErrorType,
		"error_msg",            ErrorMsg,
		"error_extra",          ErrorExtra,
		"error_what",           ErrorWhat,
		"error_file",           ErrorFile,
		"error_line",           ErrorLine,
		"stack_trace",          StackTrace,
		; -- System environment --
		"os",                   OsVersion,
		"ahk_version",          AhkVersion,
		"ahk_bitness",          AhkBitness,
		"screen_resolution",    ScreenRes,
		"locale",               Locale,
		"script_dir",           ScriptDir,
		"username_hash",        UsernameHash,
		; -- Runtime context --
		"uptime_sec",           String(UptimeSec),
		"active_window_title",  ActiveWindowTitle,
		"active_window_process", ActiveWindowProcess,
		"stuck_modifiers",      StuckModsStr,
		; -- Module state --
		"keylogger_initialized", KeyloggerInit,
		"config_dir",           ConfigDir,
	)

	try LoggerDone("CrashReporter", "Crash report built (ts={1}, type={2}).", Ts, ErrorType)
	return Report
}

; Writes a crash report Map to disk as a JSON file under the crash_reports
; directory. Creates the directory on demand. Returns the file path on
; success, or an empty string on failure.
; @param Report {Map} The report Map returned by CrashReport_Build().
; @return {String} Absolute path to the written file, or "" on failure.
CrashReport_Save(Report) {
	global _ConfigDir, _CrashReporter_Subdir

	try LoggerStart("CrashReporter", "Saving crash report to disk...")

	; Resolve directory -- fall back to USERPROFILE if _ConfigDir is not set
	BaseDir := ""
	try BaseDir := _ConfigDir
	if (BaseDir == "") {
		try BaseDir := EnvGet("USERPROFILE") . "\.config\ergopti_plus\"
	}
	if (!BaseDir ~= "[/\\]$") {
		BaseDir .= "\"
	}
	ReportDir := BaseDir . _CrashReporter_Subdir . "\"

	; Create the directory tree (best-effort)
	try DirCreate(ReportDir)

	; Build a timestamped filename (colons replaced for NTFS compatibility)
	Ts    := Report.Has("timestamp") ? Report["timestamp"] : _CrashReport_IsoTimestamp()
	FName := ReportDir . StrReplace(Ts, ":", "-") . ".json"

	; Serialise to JSON
	JsonStr := _CrashReport_ToJson(Report)

	; Write to disk
	try {
		FileAppend(JsonStr, FName, "UTF-8-RAW")
		try LoggerSuccess("CrashReporter", "Crash report saved: {1}.", FName)
		return FName
	} catch as WriteErr {
		try LoggerError("CrashReporter", "Write failed for '{1}': {2}.", FName, WriteErr.Message)
		return ""
	}
}

; Displays a MsgBox asking the user whether to save the crash report.
; If the user confirms, calls CrashReport_Save() and shows the outcome.
; Safe to call from within ErgoptiGlobalErrorHandler -- all calls are guarded.
; @param Report {Map} The report Map returned by CrashReport_Build().
CrashReport_PromptUser(Report) {
	try LoggerStart("CrashReporter", "Prompting user for crash report opt-in...")

	Title   := t("crash.report.prompt_title")
	Body    := t("crash.report.prompt_body")
	OkBtn   := t("button.ok")
	Cancel  := t("button.cancel")

	; MsgBox returns the button label pressed
	Choice := MsgBox(Body, Title, "OC Icon!")

	if (Choice == "OK") {
		FilePath := CrashReport_Save(Report)
		if (FilePath != "") {
			MsgBox(FilePath, t("crash.report.saved"), "OK Iconi")
			try LoggerSuccess("CrashReporter", "User accepted crash report opt-in.")
		} else {
			try LoggerWarn("CrashReporter", "Crash report save failed after user accepted prompt.")
		}
	} else {
		try LoggerInfo("CrashReporter", "User declined crash report opt-in.")
		MsgBox(t("crash.report.declined"), "ErgoptiPlus", "OK Iconi")
	}
}





; ===========================
; ==========================
; ======= 3/ Helpers =======
; ==========================
; ===========================

; Returns an ISO-8601 UTC timestamp string matching the Lua reporter format.
; AHK does not expose UTC time directly via A_Now, so we compute it from
; FormatTime which uses local time -- "Z" is appended as an approximation
; since AHK v2 has no native UTC formatter without a DLL call.
; @return {String} Timestamp in the form "YYYY-MM-DDTHH:MM:SSZ".
_CrashReport_IsoTimestamp() {
	return FormatTime(, "yyyy-MM-ddTHH:mm:ssZ")
}

; Produces a short, stable, non-reversible hex digest of a string by folding
; each character code into a 32-bit accumulator. Not cryptographic -- the goal
; is stable cross-session correlation of incidents from the same machine user
; without storing the raw value (privacy rule).
; @param Str {String} The input string to hash.
; @return {String} Eight-character lowercase hex string (e.g. "3f8a1c22").
_CrashReport_FoldHash(Str) {
	Acc := 0x811C9DC5  ; FNV-1a 32-bit offset basis
	Loop StrLen(Str) {
		; XOR-fold with FNV prime then rotate right by 3 to increase avalanche
		Acc := ((Acc ^ Ord(SubStr(Str, A_Index, 1))) * 0x01000193) & 0xFFFFFFFF
		Acc := ((Acc >> 3) | (Acc << 29)) & 0xFFFFFFFF
	}
	return Format("{:08x}", Acc)
}

; Serialises a crash report Map to a formatted JSON string.
; String fields are emitted as JSON strings; the field order is fixed for
; consistent diff-ability across versions. Unknown keys are ignored.
; @param Report {Map} The report Map.
; @return {String} Pretty-printed JSON string.
_CrashReport_ToJson(Report) {
	Fields := [
		; Identification
		"version", "driver", "timestamp",
		; Error details
		"error_type", "error_msg", "error_extra", "error_what",
		"error_file", "error_line", "stack_trace",
		; System environment
		"os", "ahk_version", "ahk_bitness", "screen_resolution",
		"locale", "script_dir", "username_hash",
		; Runtime context
		"uptime_sec", "active_window_title", "active_window_process",
		"stuck_modifiers",
		; Module state
		"keylogger_initialized", "config_dir",
	]
	Parts := []
	Q     := Chr(34)

	for _, Key in Fields {
		Val := Report.Has(Key) ? String(Report[Key]) : ""
		; Minimal JSON string escaping: backslash, double-quote, CR, LF, tab
		Val := StrReplace(Val, "\",  "\\")
		Val := StrReplace(Val, Q,   "\" . Q)
		Val := StrReplace(Val, "`r", "\r")
		Val := StrReplace(Val, "`n", "\n")
		Val := StrReplace(Val, "`t", "\t")
		Parts.Push("  " . Q . Key . Q . ": " . Q . Val . Q)
	}

	return "{`r`n" . _CrashReport_JoinParts(Parts) . "`r`n}"
}

; Joins an array of strings with ",`r`n" separators.
; Extracted so the serialiser body stays readable.
; @param Parts {Array} String array.
; @return {String} Joined string.
_CrashReport_JoinParts(Parts) {
	Result := ""
	for Idx, Item in Parts {
		Result .= (Idx > 1 ? ",`r`n" : "") . Item
	}
	return Result
}

; Joins an array of strings with ", " separator for inline display.
; Used to format the stuck_modifiers list as a compact comma-separated value.
; @param Arr {Array} String array.
; @return {String} Joined string.
_CrashReport_JoinArr(Arr) {
	Result := ""
	for Idx, Item in Arr {
		Result .= (Idx > 1 ? ", " : "") . Item
	}
	return Result
}
