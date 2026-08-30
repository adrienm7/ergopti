; adapters/process_lifecycle.ahk

; ==============================================================================
; MODULE: ProcessLifecycle Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the ProcessLifecycle port contract. Provides
; callbacks for foreground-window (focus) changes via a SetTimer polling loop
; since AHK v2 exposes no native app-launch/quit notification mechanism short
; of WMI subscriptions. Launch and quit callbacks are accepted but never fired.
;
; NAMING CONVENTION:
; Port method        -> AHK name mapping:
;   onFocusChange(cb)  -> PLC_OnFocusChange(Callback)
;   onAppLaunch(cb)    -> PLC_OnAppLaunch(Callback)
;   onAppQuit(cb)      -> PLC_OnAppQuit(Callback)
;   getForegroundApp() -> PLC_GetForegroundApp()
;   start()            -> PLC_Start()
;   stop()             -> PLC_Stop()
;
; POLLING NOTES:
; PLC_Poll() is called every PLC_POLL_MS milliseconds by a SetTimer. It reads
; WinGetProcessName("A") and WinGetTitle("A") and fires all registered focus
; callbacks when either value changes. Errors inside Poll (e.g., window closed
; between calls) are silently swallowed to prevent timer disruption.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Global State =======
; ===============================
; ===============================

; Array of callbacks invoked when the foreground window changes
global PLC_FocusCallbacks  := []

; Array of app-launch callbacks - accepted but never triggered on AHK (no WMI)
global PLC_LaunchCallbacks := []

; Array of app-quit callbacks - accepted but never triggered on AHK (no WMI)
global PLC_QuitCallbacks   := []

; Whether the polling timer is currently running
global PLC_Running         := false

; Process name of the last known foreground application
global PLC_LastAppId       := ""

; Window title of the last known foreground window
global PLC_LastWindowTitle := ""

; Polling interval fed to SetTimer - 250 ms balances responsiveness and CPU use
global PLC_POLL_MS         := 250

; Injectable native seam used only by ownership regression tests.
global PLC_TIMER_DRIVER    := 0





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

_PLC_SetPollTimer(Enable) {
	global PLC_TIMER_DRIVER, PLC_POLL_MS
	Period := Enable ? PLC_POLL_MS : 0
	if HasMethod(PLC_TIMER_DRIVER, "Call")
		return PLC_TIMER_DRIVER.Call(PLC_Poll, Period)
	if Enable
		SetTimer(PLC_Poll, PLC_POLL_MS)
	else
		SetTimer(PLC_Poll, 0)
	return true
}

; Registers a callback invoked whenever the foreground window changes.
; The callback signature is: Callback(AppId, WindowTitle).
; Non-callable values are rejected with a WARNING (never silently dropped).
; @param Callback {Func} A callable object to append to PLC_FocusCallbacks.
PLC_OnFocusChange(Callback) {
	try {
		; Guard: accept any callable (Func, Closure, BoundFunc, or any object
		; exposing Call). Type(Callback)="Func" was too narrow - it rejected
		; closures and bound methods (the idiomatic way to register instance
		; handlers), silently dropping them. HasMethod covers every callable.
		if HasMethod(Callback, "Call")
			PLC_FocusCallbacks.Push(Callback)
		else
			LoggerWarn("ProcessLifecycle", "onFocusChange rejected a non-callable callback (type {1}).", Type(Callback))
	} catch {
		return
	}
}

; Registers a callback for application-launch events (stub - never fired).
; AHK v2 has no built-in launch notification without WMI; this is accepted
; to satisfy the port contract but will never be triggered.
; @param Callback {Func} A callable object to append to PLC_LaunchCallbacks.
PLC_OnAppLaunch(Callback) {
	try {
		if HasMethod(Callback, "Call")
			PLC_LaunchCallbacks.Push(Callback)
		else
			LoggerWarn("ProcessLifecycle", "onAppLaunch rejected a non-callable callback (type {1}).", Type(Callback))
	} catch {
		return
	}
}

; Registers a callback for application-quit events (stub - never fired).
; Same constraint as PLC_OnAppLaunch: no WMI means no quit signal.
; @param Callback {Func} A callable object to append to PLC_QuitCallbacks.
PLC_OnAppQuit(Callback) {
	try {
		if HasMethod(Callback, "Call")
			PLC_QuitCallbacks.Push(Callback)
		else
			LoggerWarn("ProcessLifecycle", "onAppQuit rejected a non-callable callback (type {1}).", Type(Callback))
	} catch {
		return
	}
}

; Returns a Map describing the current foreground application.
; @return {Map} Map with keys "appId" (process name) and "windowTitle".
;               Both values are empty strings on error.
PLC_GetForegroundApp() {
	try {
		local AppId    := WinGetProcessName("A")
		local WinTitle := WinGetTitle("A")
		return Map("appId", AppId, "windowTitle", WinTitle)
	} catch {
		return Map("appId", "", "windowTitle", "")
	}
}

; Starts the focus-change polling timer. Idempotent - safe to call repeatedly.
; @return {Boolean} True only when the polling timer is owned.
PLC_Start() {
	global PLC_Running
	Succeeded := false
	FailureMessage := ""
	PreviousCritical := Critical("On")
	try {
		if PLC_Running {
			Succeeded := true
		} else {
			; Native admission precedes the logical latch. Otherwise a rejected
			; period leaves every later idempotent Start believing a poller exists.
			if _PLC_SetPollTimer(true) != true
				throw Error("focus poller timer admission was refused")
			PLC_Running := true
			Succeeded := true
		}
	} catch as Err {
		PLC_Running := false
		FailureMessage := Err.Message
	} finally Critical(PreviousCritical)
	if FailureMessage != ""
		LoggerError("ProcessLifecycle",
			"Could not start the focus poller: {1}.", FailureMessage)
	return Succeeded
}

; Stops the focus-change polling timer. Idempotent - safe to call repeatedly.
; @return {Boolean} True only after every native and logical owner is retired.
PLC_Stop() {
	global PLC_Running, PLC_FocusCallbacks, PLC_LaunchCallbacks, PLC_QuitCallbacks
	FailureMessage := ""
	PreviousCritical := Critical("On")
	try {
		if PLC_Running {
			if _PLC_SetPollTimer(false) != true
				throw Error("focus poller timer cancellation was refused")
			PLC_Running := false
		}
		; Subscribers may retire only after the native timer owner has accepted
		; cancellation. Otherwise the live poller and its logical callback set
		; describe different resources and a later Stop cannot retry atomically.
		PLC_FocusCallbacks  := []
		PLC_LaunchCallbacks := []
		PLC_QuitCallbacks   := []
	} catch as Err {
		FailureMessage := Err.Message
	} finally Critical(PreviousCritical)
	if FailureMessage != "" {
		try LoggerError("ProcessLifecycle",
			"Could not stop the focus poller: {1}.", FailureMessage)
		return false
	}
	return true
}

; Signals an existing manual-reset event by its exact kernel-object name.
; The caller validates any untrusted name before crossing this adapter seam.
; @param Name {String} Exact event name.
; @return {Boolean} True only when OpenEvent and SetEvent both succeed.
PLC_SignalNamedEvent(Name) {
	if !(Name is String) or Name = ""
		return false
	Handle := 0
	try {
		static EVENT_MODIFY_STATE := 0x0002
		Handle := DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
			"Str", Name, "Ptr")
		return Handle and DllCall("SetEvent", "Ptr", Handle, "Int") != 0
	} catch {
		return false
	} finally {
		if Handle
			try DllCall("CloseHandle", "Ptr", Handle)
	}
}

; Creates a manual-reset, initially non-signaled event and rejects an existing
; object with the same name. The collision check makes names capabilities rather
; than attachable labels.
PLC_CreateNamedManualResetEvent(Name) {
	if !(Name is String) or Name = ""
		throw TypeError("Named event requires a non-empty String")
	Handle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
		"Int", false, "Str", Name, "Ptr")
	ErrorCode := A_LastError
	if !Handle
		throw Error("CreateEventW failed for '" . Name . "' (Win32 "
			. ErrorCode . ")")
	static ERROR_ALREADY_EXISTS := 183
	if (ErrorCode == ERROR_ALREADY_EXISTS) {
		PLC_CloseNativeHandle(Handle)
		throw Error("CreateEventW collided with existing event '" . Name . "'")
	}
	return Handle
}

PLC_CloseNativeHandle(Handle) {
	if !Handle
		return true
	try return DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
	catch
		return false
}

PLC_CurrentProcessId() {
	try return DllCall("Kernel32\GetCurrentProcessId", "UInt")
	catch
		return 0
}

; Opens an inheritable handle to this exact process. The updater passes that
; capability to its child instead of relying on a reusable PID.
PLC_OpenCurrentProcessHandle(DesiredAccess) {
	ProcessId := PLC_CurrentProcessId()
	if (!ProcessId or !IsNumber(DesiredAccess))
		return 0
	try return DllCall("Kernel32\OpenProcess", "UInt", DesiredAccess,
		"Int", true, "UInt", ProcessId, "Ptr")
	catch
		return 0
}

PLC_TerminateProcessHandle(Handle, ExitCode := 1) {
	if !Handle
		return true
	try return DllCall("Kernel32\TerminateProcess", "Ptr", Handle,
		"UInt", ExitCode, "Int") != 0
	catch
		return false
}

; Creates a child with inherited handles into caller-owned native buffers. The
; PROCESS_INFORMATION buffer remains caller-owned so an OnExit thread can claim
; its handles atomically if creation and shutdown race.
PLC_CreateProcessWithInheritedHandles(ApplicationPath, CommandBuffer, CreationFlags, StartupInfo, ProcessInfo) {
	if !(ApplicationPath is String) or ApplicationPath = ""
		throw TypeError("CreateProcessW requires an application path")
	if !(CommandBuffer is Buffer) or !(StartupInfo is Buffer)
		or !(ProcessInfo is Buffer)
		throw TypeError("CreateProcessW requires native buffers")
	Created := DllCall("Kernel32\CreateProcessW",
		"Str", ApplicationPath,
		"Ptr", CommandBuffer.Ptr,
		"Ptr", 0,
		"Ptr", 0,
		"Int", true,
		"UInt", CreationFlags,
		"Ptr", 0,
		"Ptr", 0,
		"Ptr", StartupInfo.Ptr,
		"Ptr", ProcessInfo.Ptr,
		"Int")
	if !Created
		throw Error("CreateProcessW failed (Win32 " . A_LastError . ")")
	return true
}

; Returns the native result, captured Win32 error and any thrown message without
; losing diagnostics to cleanup calls that follow ResumeThread.
PLC_ResumeThreadHandle(Handle) {
	Result := Map("Value", 0xFFFFFFFF, "Error", 0, "Exception", "")
	try {
		Result["Value"] := DllCall("Kernel32\ResumeThread", "Ptr", Handle, "UInt")
		Result["Error"] := A_LastError
	} catch as Err {
		Result["Error"] := A_LastError
		Result["Exception"] := Err.Message
	}
	return Result
}

PLC_WaitHandle(Handle, TimeoutMs := 0) {
	if !Handle
		return -1
	try return DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle,
		"UInt", TimeoutMs, "UInt")
	catch
		return -1
}

PLC_SetEventHandle(Handle) {
	if !Handle
		return false
	try return DllCall("Kernel32\SetEvent", "Ptr", Handle, "Int") != 0
	catch
		return false
}





; ======================================
; ======================================
; ======= 3/ Internal Poll Logic =======
; ======================================
; ======================================

; Timer callback - compares current foreground window to last known state
; and fires all PLC_FocusCallbacks when either the process name or window
; title has changed. Errors are swallowed so a transient API failure (e.g.,
; the window closed between the SetTimer tick and the WinGet call) cannot
; permanently disrupt subsequent poll cycles.
PLC_Poll() {
	global PLC_LastAppId, PLC_LastWindowTitle
	; Pause invariant: a suspended driver must be fully silent. This SetTimer
	; callback is not gated by native Suspend, so early-return while suspended -
	; otherwise focus changes keep being observed and fanned out to the
	; registered callbacks (which downstream feed keylogger app-switch events)
	; while the user expects every feature paused. The timer is periodic, so
	; polling resumes automatically on unpause; no re-arm is needed.
	if A_IsSuspended
		return
	try {
		local NewApp   := WinGetProcessName("A")
		local NewTitle := WinGetTitle("A")
		if NewApp != PLC_LastAppId or NewTitle != PLC_LastWindowTitle {
			PLC_LastAppId       := NewApp
			PLC_LastWindowTitle := NewTitle
			; Iterate a snapshot so a callback registering a new subscriber
			; during the loop does not corrupt the array enumerator.
			for Cb in PLC_FocusCallbacks.Clone() {
				try Cb(NewApp, NewTitle)
			}
		}
	} catch {
		; Silently ignore errors (window may have closed between poll calls)
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_PROCESS_LIFECYCLE := Map(
    "onFocusChange",    PLC_OnFocusChange,
    "onAppLaunch",      PLC_OnAppLaunch,
    "onAppQuit",        PLC_OnAppQuit,
    "getForegroundApp", PLC_GetForegroundApp,
    "start",            PLC_Start,
    "stop",             PLC_Stop,
)
