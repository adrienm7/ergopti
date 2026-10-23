; adapters/process_lifecycle.ahk

; ==============================================================================
; MODULE: ProcessLifecycle Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the ProcessLifecycle port contract. Provides
; callbacks for foreground-window (focus) changes via a SetTimer polling loop
; since AHK v2 exposes no native app-launch/quit notification mechanism short
; of WMI subscriptions. The same loop diffs a Toolhelp process snapshot for
; launch and quit callbacks while any of them is registered.
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

; Array of callbacks invoked with an executable name when its first process starts
global PLC_LaunchCallbacks := []

; Array of callbacks invoked with an executable name when its last process exits
global PLC_QuitCallbacks   := []

; Executable names of the last successful process snapshot (0 = no baseline).
; Without a baseline the first snapshot would report every process as launched.
global PLC_LastProcesses   := 0

; Tick of the last process snapshot attempt (0 = none yet)
global PLC_LastProcessTick := 0

; Process snapshots are coarser than focus polls: the Linux adapter diffs its
; process list every 2 s for the same launch/quit contract.
global PLC_PROCESS_POLL_MS := 2000

; Injectable snapshot seam used only by snapshot-failure regression tests.
global PLC_PROCESS_SNAPSHOT_DRIVER := 0

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

; Win32 process rights and wait results for callers that own a child process.
global PLC_PROCESS_TERMINATE := 0x0001
global PLC_SYNCHRONIZE       := 0x00100000
global PLC_WAIT_OBJECT_0     := 0x00000000
global PLC_WAIT_TIMEOUT      := 0x00000102





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

; Registers a callback for application-launch events. While any launch or quit
; subscriber exists, PLC_Poll diffs a process snapshot every PLC_PROCESS_POLL_MS
; and calls Callback(AppId) when an executable name appears.
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

; Registers a callback for application-quit events, called with the executable
; name once its last process has exited (same snapshot diff as launches).
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
	global PLC_LastProcesses, PLC_LastProcessTick
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
		; A later start diffs against a fresh baseline, never a stale one.
		PLC_LastProcesses   := 0
		PLC_LastProcessTick := 0
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

; Returns the native current process identity without a failure sentinel.
; @return {Integer} This process's positive DWORD identifier.
; @throws {Error} The native call fails or returns an invalid identifier.
PLC_CurrentProcessIdStrict() {
	ProcessId := DllCall("kernel32\GetCurrentProcessId", "UInt")
	if ProcessId <= 0
		throw Error("The current process identifier is invalid.")
	return ProcessId
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

; Opens a non-inheritable handle to one process by id. A caller that has just
; created that process owns it through the handle, so a later probe or
; termination can never reach an unrelated process that reused the id.
PLC_OpenProcessHandle(ProcessId, DesiredAccess) {
	if !(ProcessId is Integer) or ProcessId <= 0 or !IsNumber(DesiredAccess)
		return 0
	try return DllCall("Kernel32\OpenProcess", "UInt", DesiredAccess,
		"Int", false, "UInt", ProcessId, "Ptr")
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
PLC_CreateProcessWithInheritedHandles(ApplicationPath, CommandBuffer, CreationFlags, StartupInfo, ProcessInfo,
		Environment := 0, WorkingDir := "") {
	if !(ApplicationPath is String) or ApplicationPath = ""
		throw TypeError("CreateProcessW requires an application path")
	if !(CommandBuffer is Buffer) or !(StartupInfo is Buffer)
		or !(ProcessInfo is Buffer)
		throw TypeError("CreateProcessW requires native buffers")
	if (!(Environment is Integer) || Environment != 0) && !(Environment is Buffer)
		throw TypeError("CreateProcessW requires an inherited or private environment")
	if !(WorkingDir is String)
		throw TypeError("CreateProcessW requires a working directory string")
	if Environment is Buffer
		CreationFlags |= 0x00000400
	Created := DllCall("Kernel32\CreateProcessW",
		"Str", ApplicationPath,
		"Ptr", CommandBuffer.Ptr,
		"Ptr", 0,
		"Ptr", 0,
		"Int", true,
		"UInt", CreationFlags,
		"Ptr", Environment is Buffer ? Environment.Ptr : 0,
		"Ptr", WorkingDir == "" ? 0 : StrPtr(WorkingDir),
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
	global PLC_LastAppId, PLC_LastWindowTitle, PLC_LastProcesses
	; Pause invariant: a suspended driver must be fully silent. This SetTimer
	; callback is not gated by native Suspend, so early-return while suspended -
	; otherwise focus changes keep being observed and fanned out to the
	; registered callbacks (which downstream feed keystats app-switch events)
	; while the user expects every feature paused. The timer is periodic, so
	; polling resumes automatically on unpause; no re-arm is needed.
	if A_IsSuspended {
		; Launches and quits during the pause are not replayed as one burst.
		PLC_LastProcesses := 0
		return
	}
	_PLC_PollProcesses()
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

; Diffs the running executable names against the last successful snapshot and
; fires launch/quit callbacks, at most once per PLC_PROCESS_POLL_MS and only
; while a launch or quit subscriber exists. A failed snapshot keeps the last
; set: reading it as an empty machine would report every process as quit, then
; as launched again once snapshots recover.
_PLC_PollProcesses() {
	global PLC_LaunchCallbacks, PLC_QuitCallbacks, PLC_LastProcesses, PLC_LastProcessTick
	global PLC_PROCESS_POLL_MS
	if PLC_LaunchCallbacks.Length == 0 && PLC_QuitCallbacks.Length == 0
		return
	if PLC_LastProcessTick && TickElapsed(PLC_LastProcessTick) < PLC_PROCESS_POLL_MS
		return
	PLC_LastProcessTick := A_TickCount
	Current := _PLC_ProcessSnapshot()
	if !(Current is Map)
		return
	Previous := PLC_LastProcesses
	PLC_LastProcesses := Current
	if !(Previous is Map)
		return
	; Iterate snapshots so a callback registering a subscriber cannot corrupt them.
	for Name in Current
		if !Previous.Has(Name)
			for Cb in PLC_LaunchCallbacks.Clone()
				try Cb(Name)
	for Name in Previous
		if !Current.Has(Name)
			for Cb in PLC_QuitCallbacks.Clone()
				try Cb(Name)
}

; Returns the running executable names as a case-insensitive set, or 0 when
; Windows refused the snapshot or its enumeration.
_PLC_ProcessSnapshot() {
	global PLC_PROCESS_SNAPSHOT_DRIVER
	if HasMethod(PLC_PROCESS_SNAPSHOT_DRIVER, "Call")
		return PLC_PROCESS_SNAPSHOT_DRIVER.Call()
	static TH32CS_SNAPPROCESS := 0x2, ERROR_NO_MORE_FILES := 18
	Snapshot := DllCall("Kernel32\CreateToolhelp32Snapshot", "UInt", TH32CS_SNAPPROCESS, "UInt", 0, "Ptr")
	if Snapshot == -1 || !Snapshot
		return 0
	try {
		; PROCESSENTRY32W: dwSize first, szExeFile[MAX_PATH] after the fixed fields.
		Entry := Buffer(A_PtrSize == 8 ? 568 : 556, 0)
		NumPut("UInt", Entry.Size, Entry)
		Names := Map()
		Names.CaseSense := "Off"
		Next := DllCall("Kernel32\Process32FirstW", "Ptr", Snapshot, "Ptr", Entry, "Int")
		while Next {
			Names[StrGet(Entry.Ptr + (A_PtrSize == 8 ? 44 : 36), 260, "UTF-16")] := true
			Next := DllCall("Kernel32\Process32NextW", "Ptr", Snapshot, "Ptr", Entry, "Int")
		}
		return A_LastError == ERROR_NO_MORE_FILES && Names.Count ? Names : 0
	} finally DllCall("Kernel32\CloseHandle", "Ptr", Snapshot)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_PROCESS_LIFECYCLE := Map(
    "onFocusChange",    PLC_OnFocusChange,
    "onAppLaunch",      PLC_OnAppLaunch,
    "onAppQuit",        PLC_OnAppQuit,
    "getForegroundApp", PLC_GetForegroundApp,
    "start",            PLC_Start,
    "stop",             PLC_Stop,
)


/** Reads the current process identity without acquiring a new process handle. */
PLC_CurrentProcessIdentity() {
	Times := Buffer(32, 0)
	if !DllCall("GetProcessTimes", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Ptr", Times,
		"Ptr", Times.Ptr + 8, "Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24, "Int")
		throw OSError(A_LastError, "GetProcessTimes", "Diagnostic host identity could not be observed.")
	return Map("pid", DllCall("GetCurrentProcessId", "UInt"),
		"created_filetime", NumGet(Times, 0, "Int64"))
}

/** Observes the native wall clock without changing collection timing policy. */
PLC_CurrentFiletime() {
	Time := Buffer(8, 0)
	DllCall("GetSystemTimeAsFileTime", "Ptr", Time)
	return NumGet(Time, 0, "Int64")
}

/** Returns the original GUID status; callers retain their own refusal policy. */
PLC_CreateGuid(Guid, ResultType := "Int") {
	return DllCall("Ole32\CoCreateGuid", "Ptr", Guid, ResultType)
}

/** Queries only an already-loaded, started native module; never lazy-loads it. */
_DiagSnapshot_ResidentNativeReads(Rows) {
	global _VendorDir, _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerModule, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerQuarantined
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputUnknown, _HSE_TerminalOwner, _HSE_TerminalReplayPending
	global _LLM_NavEventOwnerStopPending, _LLM_NavEventOwnerStartRollbackPending, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerLifecycleQuiesced, _LLM_NavEventOwnerShutdownFenced, _LLM_NavEventOwnerDrainActive
	if !_LLM_NavEventOwnerStarted || !_LLM_NavEventOwnerModule || _LLM_NavEventOwnerStarting
			|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerQuarantined || _LLM_NavEventOwnerPort is Map
			|| _LLM_NavEventOwnerStopPending || _LLM_NavEventOwnerStartRollbackPending || _LLM_NavEventOwnerStartCancelled
			|| _LLM_NavEventOwnerLifecycleQuiesced || _LLM_NavEventOwnerShutdownFenced || _LLM_NavEventOwnerDrainActive
		return
	Module := _LLM_NavEventOwnerModule
	Path := Buffer(65536, 0)
	Length := DllCall("GetModuleFileNameW", "Ptr", Module, "Ptr", Path, "UInt", 32768, "UInt")
	if !Length || Length >= 32768 || StrGet(Path, Length, "UTF-16") != StrReplace(_VendorDir . "\ergopti_nav_owner.dll", "/", "\")
		return
	CanStopFn := DllCall("GetProcAddress", "Ptr", Module, "AStr", "ErgoptiNav_CanStop", "Ptr")
	CaptureFn := DllCall("GetProcAddress", "Ptr", Module, "AStr", "ErgoptiNav_GetTerminalCapture", "Ptr")
	if !CanStopFn || !CaptureFn
		return
	Row := Rows[4], Started := A_TickCount, CanStop := 0
	Status := DllCall(CanStopFn, "UChar*", &CanStop, "Int")
	Row["status"] := Status == 0 ? "PASS" : "FAIL", Row["scope"] := "native_readonly"
	Row["reason"] := Status == 0 ? "native_aggregate_drain_observed" : "native_query_refused"
	Row["duration_ms"] := TickElapsed(Started), Row["values"]["native_status"] := Status
	Row["values"]["can_stop"] := Status == 0 ? CanStop : -1
	if Status != 0
		Row["errors"] := [Map("native_status", Status)]
	Row["values"]["record_count"] := _LLM_TerminalOutputRecords.Count
	Row["values"]["pending_count"] := 0, Row["values"]["unknown_count"] := IsObject(_LLM_TerminalOutputUnknown) ? 1 : 0
	for _, Record in _LLM_TerminalOutputRecords {
		Row["values"]["pending_count"] += Record["pending"] ? 1 : 0
		Row["values"]["unknown_count"] += Record["unknown"] ? 1 : 0
	}
	Token := 0
	if _HSE_TerminalOwner is Map && !(_HSE_TerminalOwner.Get("Port", 0) is Map)
		Token := _HSE_TerminalOwner.Get("Id", 0)
	else if _HSE_TerminalReplayPending is Map && !(_HSE_TerminalReplayPending.Get("Port", 0) is Map)
		Token := _HSE_TerminalReplayPending.Get("Token", 0)
	if !(Token is Integer) || Token <= 0
		return
	Row := Rows[3], Started := A_TickCount, Snapshot := Buffer(28, 0)
	Status := DllCall(CaptureFn, "UInt64", Token, "Ptr", Snapshot, "Int")
	Row["values"]["native_status"] := Status
	Row["duration_ms"] := TickElapsed(Started), Row["scope"] := "native_readonly"
	Row["reason"] := Status == 0 ? "native_capture_state_observed" : "native_capture_not_present"
	Row["status"] := Status == 0 ? "PASS" : (Status == 8 ? "UNRUN" : "FAIL")
	if Status != 0 && Status != 8
		Row["errors"] := [Map("native_status", Status)]
	if Status == 0 {
		if NumGet(Snapshot, 0, "UInt64") != Token
			throw Error("Native capture identity changed during its diagnostic read.")
		Row["values"]["token"] := Token
		for Index, Field in ["phase", "queued", "replayed", "last_os_error", "release_kind"]
			Row["values"][Field] := NumGet(Snapshot, 8 + (Index - 1) * 4, "UInt")
	}
}
