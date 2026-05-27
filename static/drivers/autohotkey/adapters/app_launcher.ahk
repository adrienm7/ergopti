; static/drivers/autohotkey/adapters/app_launcher.ahk

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
; All OS calls are wrapped in try/catch. AL_IsRunning returns 0 on any error
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
		Run(AppPath)
	} catch {
		; OS-level failure — caller can check AL_IsRunning if confirmation is needed
	}
}

; Launches an application with command-line arguments.
; The call is fire-and-forget — it returns as soon as the OS has accepted the
; launch request.
; @param AppPath {String} Absolute/relative path to the executable.
; @param Args    {String} Command-line argument string to append.
AL_LaunchWithArgs(AppPath, Args) {
	try {
		Run(AppPath . " " . Args)
	} catch {
		; OS-level failure — caller can check AL_IsRunning if confirmation is needed
	}
}

; Returns 1 when at least one process with the given name is currently running.
; @param ProcessName {String} Process name as shown in the OS task list (e.g. "notepad.exe").
; @return {Integer} 1 if the process exists, 0 otherwise.
AL_IsRunning(ProcessName) {
	try {
		return ProcessExist(ProcessName) ? 1 : 0
	} catch {
		return 0
	}
}
