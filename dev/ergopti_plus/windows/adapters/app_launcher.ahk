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
