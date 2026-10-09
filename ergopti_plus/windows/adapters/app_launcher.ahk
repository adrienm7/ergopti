; adapters/app_launcher.ahk

; ==============================================================================
; MODULE: AppLauncher Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the AppLauncher port contract. Wraps the AHK v2
; built-in Run() and ProcessExist() behind three stable functions so shortcut
; modules can launch programs and query process state without coupling to
; AHK-specific function syntax.
;
; NAMING CONVENTION:
; Port method             → AHK name mapping:
;   AL_Launch(appPath)           → AL_Launch(AppPath)
;   AL_LaunchWithArgs(path,args) → AL_LaunchWithArgs(AppPath, Args)
;   AL_IsRunning(processName)    → AL_IsRunning(ProcessName)
;
; FIRE-AND-FORGET:
; AL_Launch and AL_LaunchWithArgs call Run() without waiting for the process to
; finish. AHK's Run() is asynchronous by default, which matches the port
; contract's fire-and-forget semantics.
;
; FAIL-SAFE:
; All OS calls are wrapped in try/catch. A failed launch is logged with the
; program name (never its arguments); AL_IsRunning returns false on any error
; rather than propagating an exception to the caller.
; ==============================================================================



; ===========================================
; ===========================================
; ======= 1/ Adapter Functions ==============
; ===========================================
; ===========================================

; Launches an application by its executable path or shell URI.
; The call is fire-and-forget — it returns as soon as the OS has accepted the
; launch request.
; @param AppPath {String} Absolute/relative path to the executable or a URI.
AL_Launch(AppPath) {
	try {
		Pid := 0
		Run(AppPath, , , &Pid)
		try LoggerInfo("AppLauncher", "Launched '{1}' (pid {2}).", AL_ProgramName(AppPath), Pid)
	} catch as Err {
		; The launch used to fail in silence: a shortcut that "does nothing" had no
		; trace at all. Only the program name is logged, never a full target that
		; could be a user document.
		try LoggerError("AppLauncher", "Launch of '{1}' failed (Win32 error {2}).", AL_ProgramName(AppPath), A_LastError)
	}
}

; Names what is being launched without exposing its arguments or directory.
; @param AppPath {String}
; @returns {String} The base name of the executable or the URI scheme.
AL_ProgramName(AppPath) {
	Target := Trim(AppPath, ' "')
	; A URI (https:, ms-settings:) is named by its scheme: the rest can be a query.
	if !RegExMatch(Target, "^[A-Za-z]:[\\/]") && RegExMatch(Target, "^([A-Za-z][A-Za-z0-9+.-]+):", &Scheme)
		return Scheme[1] . ":"
	SplitPath(Target, &Name)
	return Name != "" ? Name : "unknown"
}

; Launches an application with command-line arguments.
; The call is fire-and-forget — it returns as soon as the OS has accepted the
; launch request.
; @param AppPath {String} Absolute/relative path to the executable.
; @param Args    {String} Command-line argument string to append.
AL_LaunchWithArgs(AppPath, Args) {
	try {
		Pid := 0
		Run(AppPath . " " . Args, , , &Pid)
		; Arguments can carry user text (a search, a path), so they are never logged.
		try LoggerInfo("AppLauncher", "Launched '{1}' with arguments (pid {2}).", AL_ProgramName(AppPath), Pid)
	} catch as Err {
		; Err.Message quotes the whole command line, arguments included, so only
		; the Win32 code is logged.
		try LoggerError("AppLauncher", "Launch of '{1}' with arguments failed (Win32 error {2}).",
			AL_ProgramName(AppPath), A_LastError)
	}
}

; Opens a file or a URI (mailto:, an .ics file) with its default handler.
; Unlike AL_Launch, a failure reaches the caller, which reports it to the user.
; @param Target {String} The file path or URI.
; @throws {Error} When Windows refuses to open it.
AL_OpenStrict(Target) {
	; Err.Message quotes the target, which can carry a mail body: only its
	; program name and the Win32 code go on
	try Run(Target)
	catch
		throw Error("Opening '" . AL_ProgramName(Target) . "' failed (Win32 error " . A_LastError . ").", -1)
	try LoggerInfo("AppLauncher", "Opened '{1}' with its default handler.", AL_ProgramName(Target))
}

; Starts a program with an argument vector. Each argument is quoted for the
; Windows command line (CommandLineToArgvW rules), so an argument arrives
; whole and verbatim, whatever it holds; no shell parses the line.
; @param Argv {Array} The program, then its arguments.
; @return {Integer} The process id.
; @throws {Error} When the program cannot be started.
AL_LaunchArgvStrict(Argv) {
	if !(Argv is Array) || Argv.Length == 0
		throw ValueError("AL_LaunchArgvStrict needs the program and its arguments.")
	CommandLine := ""
	for Arg in Argv
		CommandLine .= (A_Index == 1 ? "" : " ") . AL_QuoteArgument(Arg)
	Pid := 0
	; Arguments can carry user text, so only the program and their count go on
	try Run(CommandLine, , , &Pid)
	catch
		throw Error("Launching '" . AL_ProgramName(Argv[1]) . "' failed (Win32 error " . A_LastError . ").", -1)
	try LoggerInfo("AppLauncher", "Launched '{1}' with {2} argument(s) (pid {3}).",
		AL_ProgramName(Argv[1]), Argv.Length - 1, Pid)
	return Pid
}

; Quotes one argument for the Windows command line: backslashes are doubled
; only before a quote or the closing quote, and a quote is escaped.
; @param Arg {String}
; @return {String}
AL_QuoteArgument(Arg) {
	if !(Arg is String)
		throw TypeError("AL_QuoteArgument expects a string.")
	if (Arg != "" && !RegExMatch(Arg, '[ \t\n\x0B"]'))
		return Arg
	Out := '"'
	Slashes := 0
	Loop Parse Arg {
		if (A_LoopField == "\") {
			Slashes += 1
			continue
		}
		if (A_LoopField == '"') {
			Out .= _AL_Backslashes(Slashes * 2 + 1) . '"'
		} else {
			Out .= _AL_Backslashes(Slashes) . A_LoopField
		}
		Slashes := 0
	}
	return Out . _AL_Backslashes(Slashes * 2) . '"'
}

; @param Count {Integer}
; @return {String} Count backslashes.
_AL_Backslashes(Count) {
	Out := ""
	loop Count
		Out .= "\"
	return Out
}

; Returns the automation object of a COM server (Outlook.Application), or ""
; when it is not installed or refuses automation; the caller then takes its
; documented fallback path.
; @param ProgId {String}
; @return {Object|String}
AL_ComApplication(ProgId) {
	try return ComObject(ProgId)
	catch as Err {
		try LoggerInfo("AppLauncher", "Automation server '{1}' is not available: {2}", ProgId, Err.Message)
		return ""
	}
}

; Returns true when at least one process with the given name is currently running.
; @param ProcessName {String} Process name as shown in the OS task list (e.g. "notepad.exe").
; @return {Boolean} True on success, false on error.
AL_IsRunning(ProcessName) {
	try {
		return ProcessExist(ProcessName) ? true : false
	} catch {
		return false
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_APP_LAUNCHER := Map(
    "launch",         AL_Launch,
    "launchWithArgs", AL_LaunchWithArgs,
    "isRunning",      AL_IsRunning,
)
