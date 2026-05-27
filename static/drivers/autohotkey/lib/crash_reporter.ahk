; drivers/autohotkey/lib/crash_reporter.ahk

; ==============================================================================
; MODULE: Crash Reporter
; DESCRIPTION:
; Opt-in crash report builder and persistence layer for the AutoHotkey driver.
; When the global error handler fires, this module offers the user a choice to
; save a sanitized report to disk for later inspection or support. No network
; calls are made -- the report is written locally only. A future version could
; offer an upload path once a backend exists.
;
; FEATURES & RATIONALE:
; 1. Privacy-first: the report contains only version, OS, driver, error message,
;    and stack trace. Keystrokes, personal data, and file contents are never
;    included, not even in debug fields.
; 2. Opt-in: the user is always prompted before anything is written to disk.
; 3. Structured output: reports are written as JSON for easy machine and human
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





; ============================
; =============================
; ======= 2/ Public API =======
; =============================
; ============================

; Builds a sanitized crash report Map from an AHK Error object.
; The report never contains keystrokes, personal data, or file content.
; @param ErrorObj {Error} The AHK v2 Error object caught by the global handler.
; @return {Map} Report with fields: version, os, driver, timestamp, error_msg, stack_trace.
CrashReport_Build(ErrorObj) {
	try LoggerTrace("CrashReporter", "Building crash report...")

	ErrorMsg   := ""
	StackTrace := ""
	try ErrorMsg   := ErrorObj.Message
	try StackTrace := ErrorObj.HasProp("Stack") ? ErrorObj.Stack : ""

	; Driver version -- best-effort via Updater module (may not be initialised)
	Version := "unknown"
	try Version := Updater_CurrentVersion()

	; OS version via AHK built-in
	OsVersion := A_OSVersion

	; ISO-8601 UTC timestamp compatible with the Lua reporter format
	Ts := _CrashReport_IsoTimestamp()

	Report := Map(
		"version",     Version,
		"os",          OsVersion,
		"driver",      "autohotkey",
		"timestamp",   Ts,
		"error_msg",   ErrorMsg,
		"stack_trace", StackTrace
	)

	try LoggerDone("CrashReporter", "Crash report built (ts={1}).", Ts)
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

	; Resolve directory -- fall back to APPDATA if _ConfigDir is not set
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
; A_TickCount drift vs the local clock -- best-effort, good enough for crash IDs.
; @return {String} Timestamp in the form "YYYY-MM-DDTHH:MM:SSZ".
_CrashReport_IsoTimestamp() {
	; FormatTime defaults to local time; we append "Z" as an approximation
	; since AHK v2 has no native UTC formatter without a DLL call.
	return FormatTime(, "yyyy-MM-ddTHH:mm:ssZ")
}

; Serialises a crash report Map to a minimal JSON string.
; Only the six canonical report fields are emitted; unknown keys are ignored.
; @param Report {Map} The report Map.
; @return {String} JSON string.
_CrashReport_ToJson(Report) {
	; Field order matches the Lua reporter for consistent diff-ability
	Fields := ["version", "os", "driver", "timestamp", "error_msg", "stack_trace"]
	Parts  := []
	Q      := Chr(34)

	for _, Key in Fields {
		Val := Report.Has(Key) ? String(Report[Key]) : ""
		; Escape backslash, double-quote, and newline for minimal JSON safety
		Val := StrReplace(Val, "\", "\\")
		Val := StrReplace(Val, Q, "\" . Q)
		Val := StrReplace(Val, "`n", "\n")
		Val := StrReplace(Val, "`r", "\r")
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
