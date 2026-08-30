; modules/keymap/uia_selection_worker.ahk

; ==============================================================================
; MODULE: UIA Probe Worker
; DESCRIPTION:
; Owns the killable, out-of-process UIA selection, password and bounds probes. The
; resident driver only posts an integer request and receives one bounded
; WM_COPYDATA result; every cross-process COM call stays inside the disposable
; worker process, away from the thread that dispatches keyboard hooks.
;
; FEATURES & RATIONALE:
; 1. Persistent worker: process creation happens once, not on every selection
;    gesture. The hot-path request is one non-blocking PostMessage.
; 2. Enforceable deadline: a one-shot timer retires request ownership and kills
;    the worker after 60 ms. A COM call cannot overrun that budget in the driver.
; 3. Context fence: request, worker observation and live publication must agree
;    on top-level HWND, focused-control HWND and physical-input generation.
; 4. Exact-once terminal: timeout, stop, worker exit and WM_COPYDATA all compete
;    for one registry entry; the winner deletes it before any callback or kill.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ====================================
; ====================================
; ======= 1/ Constants & state =======
; ====================================
; ====================================

global UIASW_DEADLINE_MS := 60
; Compiled workers reuse the main executable and may cross a cold bundle check
; before reaching their early exit. This is a startup watchdog, not the 60 ms
; per-request provider deadline, so allow that bounded one-time cost.
global UIASW_START_DEADLINE_MS := 5000
global UIASW_START_BACKOFF_MS := 30000
global UIASW_MAX_RESULT_BYTES := 40000
global UIASW_READY_MAX_BYTES := 64
global UIASW_TERMINATION_RETRY_MS := 250

class UIASWState {
	static worker_generation := 0
	static request_generation := 0
	static handle := 0
	static worker_hwnd := 0
	; Kernel HANDLE opened from the worker's ready HWND. Retaining it prevents a
	; recycled numeric PID from ever becoming the target of a deadline teardown.
	static worker_process_handle := 0
	static pending := 0
	static start_deadline_fn := 0
	static start_failure_tick := 0
	; Human-readable startup phase retained for the bounded timeout diagnostic.
	; No provider text or foreground-window metadata is ever stored here.
	static start_diagnostic := "never started"
	static handlers_registered := false
	; A refused async tree-kill request remains reachable here until a later retry
	; is accepted. Clearing the primary worker slot before that receipt exists can
	; admit a replacement while the old provider process is still alive forever.
	static cleanup_debt := []
	; Native process handles whose CloseHandle receipt was refused. Keep these
	; exact capabilities reachable and block replacement admission until retry
	; proves that the kernel ownership was released.
	static process_cleanup_debt := []
	static process_cleanup_draining := false
	static cleanup_retry_armed := false
	; Test seams. Production leaves all at 0.
	static spawn_fn := 0
	static post_fn := 0
	static open_process_fn := 0
	static terminate_process_fn := 0
	static close_process_fn := 0
	static cleanup_timer_fn := 0
}





; ======================================
; ======================================
; ======= 2/ Resident controller =======
; ======================================
; ======================================

UIASW_EnsureHandlers() {
	if UIASWState.handlers_registered
		return
	OnMessage(0x004A, UIASW_OnCopyData)
	UIASWState.handlers_registered := true
}

UIASW_IsReady() {
	return IsObject(UIASWState.handle) && UIASWState.worker_hwnd != 0
}

UIASW_TerminateHandle(Handle) {
	if !IsObject(Handle)
		return true
	if HasMethod(Handle, "terminateAsync") {
		Succeeded := false
		try Succeeded := Handle.terminateAsync() == true
		catch as Err
			try LoggerError("Layout",
				"UIA worker termination request threw: {1}.", Err.Message)
		return Succeeded
	}
	; Test/dummy handles may only implement the original interface.
	if !HasMethod(Handle, "terminate")
		return false
	try {
		Handle.terminate()
		return true
	} catch as Err {
		try LoggerError("Layout", "UIA worker termination threw: {1}.", Err.Message)
		return false
	}
}

UIASW_ArmTerminationRetry() {
	global UIASW_TERMINATION_RETRY_MS
	PreviousCritical := Critical("On")
	try {
		if (UIASWState.cleanup_debt.Length = 0
				&& UIASWState.process_cleanup_debt.Length = 0)
			return true
		if UIASWState.cleanup_retry_armed
			return true
		UIASWState.cleanup_retry_armed := true
	} finally Critical(PreviousCritical)
	try {
		if HasMethod(UIASWState.cleanup_timer_fn, "Call")
			UIASWState.cleanup_timer_fn.Call(UIASW_RetryTerminationDebt,
				-UIASW_TERMINATION_RETRY_MS)
		else
			SetTimer(UIASW_RetryTerminationDebt, -UIASW_TERMINATION_RETRY_MS)
		return true
	} catch as Err {
		PreviousCritical := Critical("On")
		try UIASWState.cleanup_retry_armed := false
		finally Critical(PreviousCritical)
		try LoggerError("Layout",
			"Could not arm UIA worker termination retry: {1}.", Err.Message)
		return false
	}
}

UIASW_QueueTerminationDebt(Handle, ArmRetry := true) {
	if !IsObject(Handle)
		return false
	PreviousCritical := Critical("On")
	try {
		for Existing in UIASWState.cleanup_debt {
			if ObjPtr(Existing) = ObjPtr(Handle)
				return false
		}
		UIASWState.cleanup_debt.Push(Handle)
	} finally Critical(PreviousCritical)
	if ArmRetry
		UIASW_ArmTerminationRetry()
	return true
}

UIASW_DrainTerminationDebt() {
	PreviousCritical := Critical("On")
	try {
		Pending := UIASWState.cleanup_debt
		UIASWState.cleanup_debt := []
		UIASWState.cleanup_retry_armed := false
	} finally Critical(PreviousCritical)
	for Handle in Pending {
		if !UIASW_TerminateHandle(Handle)
			UIASW_QueueTerminationDebt(Handle, false)
	}
	PreviousCritical := Critical("On")
	try Complete := UIASWState.cleanup_debt.Length = 0
	finally Critical(PreviousCritical)
	if !Complete
		UIASW_ArmTerminationRetry()
	return Complete
}

UIASW_QueueProcessCleanupDebt(ProcessHandle, ArmRetry := true) {
	if !ProcessHandle
		return false
	PreviousCritical := Critical("On")
	try {
		for ExistingHandle in UIASWState.process_cleanup_debt {
			if ExistingHandle = ProcessHandle
				return false
		}
		UIASWState.process_cleanup_debt.Push(ProcessHandle)
	} finally Critical(PreviousCritical)
	if ArmRetry
		UIASW_ArmTerminationRetry()
	return true
}

UIASW_RemoveProcessCleanupDebt(ProcessHandle) {
	PreviousCritical := Critical("On")
	try {
		for Index, ExistingHandle in UIASWState.process_cleanup_debt {
			if ExistingHandle = ProcessHandle {
				UIASWState.process_cleanup_debt.RemoveAt(Index)
				return true
			}
		}
		return false
	} finally Critical(PreviousCritical)
}

UIASW_DrainProcessCleanupDebt() {
	PreviousCritical := Critical("On")
	try {
		if UIASWState.process_cleanup_debt.Length = 0
			return true
		if UIASWState.process_cleanup_draining
			return false
		UIASWState.process_cleanup_draining := true
		Pending := UIASWState.process_cleanup_debt.Clone()
	} finally Critical(PreviousCritical)
	try {
		for ProcessHandle in Pending {
			if UIASW_CloseProcessHandle(ProcessHandle)
				UIASW_RemoveProcessCleanupDebt(ProcessHandle)
		}
	} finally {
		PreviousCritical := Critical("On")
		try UIASWState.process_cleanup_draining := false
		finally Critical(PreviousCritical)
	}
	PreviousCritical := Critical("On")
	try Complete := UIASWState.process_cleanup_debt.Length = 0
	finally Critical(PreviousCritical)
	if !Complete
		UIASW_ArmTerminationRetry()
	return Complete
}

UIASW_ReleaseProcessHandle(ProcessHandle) {
	if !ProcessHandle
		return true
	UIASW_QueueProcessCleanupDebt(ProcessHandle, false)
	return UIASW_DrainProcessCleanupDebt()
}

UIASW_RetryTerminationDebt() {
	TerminationReleased := UIASW_DrainTerminationDebt()
	ProcessHandlesReleased := UIASW_DrainProcessCleanupDebt()
	return TerminationReleased && ProcessHandlesReleased
}

UIASW_CloseProcessHandle(ProcessHandle) {
	if !ProcessHandle
		return true
	if IsObject(UIASWState.close_process_fn) {
		try return UIASWState.close_process_fn.Call(ProcessHandle) == true
		catch as Err {
			try LoggerError("Layout",
				"UIA worker process-handle close threw: {1}.", Err.Message)
			return false
		}
	}
	try return UIAW_CloseProcessHandle(ProcessHandle) == true
	catch as Err {
		try LoggerError("Layout",
			"UIA worker process-handle close threw: {1}.", Err.Message)
		return false
	}
}

UIASW_OpenWorkerProcess(WorkerHwnd, ExpectedParentPid) {
	if IsObject(UIASWState.open_process_fn)
		return UIASWState.open_process_fn.Call(WorkerHwnd, ExpectedParentPid)
	return UIAW_OpenVerifiedWorkerProcess(WorkerHwnd, ExpectedParentPid)
}

UIASW_TerminateProcessHandle(ProcessHandle) {
	if IsObject(UIASWState.terminate_process_fn)
		return UIASWState.terminate_process_fn.Call(ProcessHandle)
	return UIAW_TerminateProcessHandle(ProcessHandle)
}

UIASW_TerminateWorker(Handle, ProcessHandle := 0) {
	if ProcessHandle {
		; Windows specifies TerminateProcess against another process as asynchronous:
		; it initiates termination and returns immediately. The retained kernel HANDLE
		; identifies the exact child even if its numeric PID has already been recycled.
		Terminated := false
		try Terminated := UIASW_TerminateProcessHandle(ProcessHandle)
		ProcessHandleReleased := UIASW_ReleaseProcessHandle(ProcessHandle)
		if Terminated {
			if IsObject(Handle) && HasMethod(Handle, "detach")
				try Handle.detach()
			return ProcessHandleReleased
		}
	}
	; Before the ready HWND exists, or if native termination is denied, retain the
	; tree-kill fallback. Its handle owns the cmd.exe wrapper plus the child worker.
	if UIASW_TerminateHandle(Handle)
		return !ProcessHandle || ProcessHandleReleased
	UIASW_QueueTerminationDebt(Handle)
	return false
}

UIASW_WorkerEntryPath() {
	SplitPath(A_LineFile, , &ModuleDir)
	return ModuleDir . "\uia_selection_worker_entry.ahk"
}

UIASW_Start() {
	global UIASW_START_DEADLINE_MS, UIASW_START_BACKOFF_MS
	if A_IsSuspended
		return false
	UIASW_EnsureHandlers()
	; A replacement must not coexist with a worker whose termination request was
	; refused. Retry the exact retained handle before considering new admission.
	if (!UIASW_DrainTerminationDebt()
			|| !UIASW_DrainProcessCleanupDebt())
		return false
	if IsObject(UIASWState.handle)
		return true
	if UIASWState.start_failure_tick {
		if !TickExpired(UIASWState.start_failure_tick, UIASW_START_BACKOFF_MS)
			return false
		UIASWState.start_failure_tick := 0
	}

	WorkerGeneration := ++UIASWState.worker_generation
	UIASWState.start_diagnostic := "ready message not received"
	Executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
	Args := A_IsCompiled
		? ["/force", "--uia-selection-worker", A_ScriptHwnd, WorkerGeneration]
		: ["/force", "/ErrorStdOut", UIASW_WorkerEntryPath(), "--uia-selection-worker", A_ScriptHwnd, WorkerGeneration]
	Done := UIASW_OnWorkerExit.Bind(WorkerGeneration)
	Spawn := IsObject(UIASWState.spawn_fn) ? UIASWState.spawn_fn : ShellRunner_Spawn

	try Handle := Spawn.Call(Executable, Args, Done)
	catch as Err {
		UIASWState.start_failure_tick := A_TickCount
		try LoggerError("Layout", "Could not create the UIA probe worker: {1}", Err.Message)
		return false
	}
	if !IsObject(Handle) {
		UIASWState.start_failure_tick := A_TickCount
		try LoggerError("Layout", "Could not create the UIA probe worker handle.")
		return false
	}

	; Publish before start(): a fake or failed handle may complete synchronously.
	UIASWState.handle := Handle
	UIASWState.worker_hwnd := 0
	UIASWState.worker_process_handle := 0
	StartDeadlineFn := UIASW_OnStartDeadline.Bind(WorkerGeneration)
	UIASWState.start_deadline_fn := StartDeadlineFn
	try SetTimer(StartDeadlineFn, -UIASW_START_DEADLINE_MS)
	catch as Err {
		UIASWState.start_deadline_fn := 0
		UIASWState.handle := 0
		UIASWState.start_failure_tick := A_TickCount
		UIASWState.worker_generation += 1
		UIASW_TerminateHandle(Handle)
		try LoggerError("Layout", "Could not arm the UIA probe worker startup deadline: {1}", Err.Message)
		return false
	}
	try Started := Handle.start()
	catch as Err {
		try LoggerError("Layout", "Could not start the UIA probe worker: {1}", Err.Message)
		UIASW_OnWorkerExit(WorkerGeneration, 1, "", "")
		return false
	}
	; A synchronous completion already retired this generation.
	if (UIASWState.worker_generation != WorkerGeneration || !IsObject(UIASWState.handle))
		return false
	if !Started {
		UIASW_OnWorkerExit(WorkerGeneration, 1, "", "")
		return false
	}
	return true
}

UIASW_OnWorkerReady(WorkerHwnd, WorkerGeneration, Msg, ReceiverHwnd) {
	PreviousCritical := A_IsCritical
	Critical("On")
	if (ReceiverHwnd != A_ScriptHwnd || WorkerGeneration != UIASWState.worker_generation
		|| !IsObject(UIASWState.handle) || !WorkerHwnd) {
		if (WorkerGeneration = UIASWState.worker_generation)
			UIASWState.start_diagnostic := "ready message rejected by receiver/generation/owner validation"
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return 0
	}
	; A duplicate ready handshake is harmless, but must not replace/leak the
	; retained kernel handle. A different HWND in the same generation is rejected.
	if UIASWState.worker_hwnd {
		Accepted := UIASWState.worker_hwnd = WorkerHwnd
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return Accepted ? 1 : 0
	}
	WrapperPid := 0
	if IsObject(UIASWState.handle) && HasMethod(UIASWState.handle, "processId")
		try WrapperPid := UIASWState.handle.processId()
	ProcessHandle := UIASW_OpenWorkerProcess(WorkerHwnd, WrapperPid)
	if !ProcessHandle {
		UIASWState.start_diagnostic := "ready message received but the child process handle could not be opened"
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return 0
	}
	UIASWState.worker_hwnd := WorkerHwnd
	UIASWState.worker_process_handle := ProcessHandle
	StartDeadlineFn := UIASWState.start_deadline_fn
	UIASWState.start_deadline_fn := 0
	UIASWState.start_failure_tick := 0
	UIASWState.start_diagnostic := "ready accepted"
	Critical(PreviousCritical ? PreviousCritical : "Off")
	if IsObject(StartDeadlineFn)
		try SetTimer(StartDeadlineFn, 0)
	return 1
}

UIASW_OnStartDeadline(WorkerGeneration) {
	global UIASW_START_DEADLINE_MS
	PreviousCritical := A_IsCritical
	Critical("On")
	if (WorkerGeneration != UIASWState.worker_generation
		|| !IsObject(UIASWState.handle) || UIASWState.worker_hwnd) {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return false
	}
	Handle := UIASWState.handle
	ProcessHandle := UIASWState.worker_process_handle
	UIASWState.handle := 0
	UIASWState.worker_hwnd := 0
	UIASWState.worker_process_handle := 0
	UIASWState.start_deadline_fn := 0
	UIASWState.start_failure_tick := A_TickCount
	UIASWState.worker_generation += 1
	Critical(PreviousCritical ? PreviousCritical : "Off")
	UIASW_TerminateWorker(Handle, ProcessHandle)
	try LoggerWarn("Layout", "UIA probe worker did not become ready within {1} ms; startup is backed off ({2}).", UIASW_START_DEADLINE_MS, UIASWState.start_diagnostic)
	return true
}

_UIASW_Request(Context, OnTerminal, RequestCode) {
	global UIASW_DEADLINE_MS
	if A_IsSuspended || !(Context is Map) || !IsObject(OnTerminal)
		return false
	if !(RequestCode is Integer) || RequestCode <= 0
		return false
	for Field in ["Hwnd", "Control", "InputEpoch", "ProcName"] {
		if !Context.Has(Field)
			return false
	}
	PreviousCritical := A_IsCritical
	Critical("On")
	if !UIASW_IsReady() || IsObject(UIASWState.pending) {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return false
	}
	RequestGeneration := ++UIASWState.request_generation
	WorkerGeneration := UIASWState.worker_generation
	DeadlineFn := UIASW_OnDeadline.Bind(RequestGeneration, WorkerGeneration)
	UIASWState.pending := Map(
		"request_generation", RequestGeneration,
		"worker_generation", WorkerGeneration,
		"context", Context,
		"on_terminal", OnTerminal,
		"deadline_fn", DeadlineFn
	)
	try SetTimer(DeadlineFn, -UIASW_DEADLINE_MS)
	catch as Err {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		UIASW_Complete(RequestGeneration, WorkerGeneration, "failed",
			Map("Error", Err.Message), true)
		return false
	}
	Post := IsObject(UIASWState.post_fn) ? UIASWState.post_fn : UIASW_PostRequest
	try Posted := Post.Call(UIASWState.worker_hwnd, RequestGeneration, RequestCode)
	catch as Err {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		UIASW_Complete(RequestGeneration, WorkerGeneration, "failed",
			Map("Error", Err.Message), true)
		return false
	}
	Critical(PreviousCritical ? PreviousCritical : "Off")
	if !Posted {
		UIASW_Complete(RequestGeneration, WorkerGeneration, "failed",
			Map("Error", "PostMessage rejected the worker request."), true)
		return false
	}
	return true
}

UIASW_Request(Context, OnTerminal) {
	global UIASW_MAX_TEXT_CHARS
	return _UIASW_Request(Context, OnTerminal, UIASW_MAX_TEXT_CHARS)
}

UIASW_RequestPassword(Context, OnTerminal) {
	global UIASW_PASSWORD_REQUEST_CODE
	return _UIASW_Request(Context, OnTerminal, UIASW_PASSWORD_REQUEST_CODE)
}

UIASW_RequestBounds(Context, OnTerminal) {
	global UIASW_BOUNDS_REQUEST_CODE
	return _UIASW_Request(Context, OnTerminal, UIASW_BOUNDS_REQUEST_CODE)
}

UIASW_PostRequest(WorkerHwnd, RequestGeneration, MaxTextChars) {
	return UIAW_PostRequest(WorkerHwnd, RequestGeneration, MaxTextChars)
}

UIASW_OnDeadline(RequestGeneration, WorkerGeneration) {
	UIASW_Complete(RequestGeneration, WorkerGeneration, "timeout", Map(), true)
}

UIASW_Complete(RequestGeneration, WorkerGeneration, Status, Result, StopWorker := false) {
	PreviousCritical := A_IsCritical
	Critical("On")
	if !IsObject(UIASWState.pending)
		|| UIASWState.pending["request_generation"] != RequestGeneration
		|| UIASWState.pending["worker_generation"] != WorkerGeneration {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return false
	}
	Pending := UIASWState.pending
	UIASWState.pending := 0
	Handle := 0
	ProcessHandle := 0
	if StopWorker && UIASWState.worker_generation = WorkerGeneration {
		Handle := UIASWState.handle
		ProcessHandle := UIASWState.worker_process_handle
		UIASWState.handle := 0
		UIASWState.worker_hwnd := 0
		UIASWState.worker_process_handle := 0
		; Invalidate a late ready/exit/result from the retired process.
		UIASWState.worker_generation += 1
	}
	Critical(PreviousCritical ? PreviousCritical : "Off")

	try SetTimer(Pending["deadline_fn"], 0)
	if IsObject(Handle)
		UIASW_TerminateWorker(Handle, ProcessHandle)
	try Pending["on_terminal"].Call(Status, Pending["context"], Result)
	catch as Err
		try LoggerError("Layout", "UIA probe terminal callback failed ({1}): {2}", Status, Err.Message)
	return true
}

UIASW_Stop(Status := "canceled") {
	PreviousCritical := A_IsCritical
	Critical("On")
	Pending := UIASWState.pending
	Handle := UIASWState.handle
	ProcessHandle := UIASWState.worker_process_handle
	StartDeadlineFn := UIASWState.start_deadline_fn
	HadBackoff := UIASWState.start_failure_tick != 0
	HadDebt := UIASWState.cleanup_debt.Length != 0
		|| UIASWState.process_cleanup_debt.Length != 0
	if !IsObject(Pending) && !IsObject(Handle) && !IsObject(StartDeadlineFn)
			&& !HadBackoff && !HadDebt {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return false
	}
	UIASWState.pending := 0
	UIASWState.handle := 0
	UIASWState.worker_hwnd := 0
	UIASWState.worker_process_handle := 0
	UIASWState.start_deadline_fn := 0
	UIASWState.start_failure_tick := 0
	UIASWState.worker_generation += 1
	Critical(PreviousCritical ? PreviousCritical : "Off")

	if IsObject(StartDeadlineFn)
		try SetTimer(StartDeadlineFn, 0)
	TerminationAccepted := true
	if IsObject(Handle)
		TerminationAccepted := UIASW_TerminateWorker(Handle, ProcessHandle)
	if IsObject(Pending) {
		try SetTimer(Pending["deadline_fn"], 0)
		try Pending["on_terminal"].Call(Status, Pending["context"], Map())
		catch as Err
			try LoggerError("Layout", "UIA probe stop callback failed ({1}): {2}", Status, Err.Message)
	}
	TerminationDebtReleased := UIASW_DrainTerminationDebt()
	ProcessDebtReleased := UIASW_DrainProcessCleanupDebt()
	HadOwnership := IsObject(Pending) || IsObject(Handle)
		|| IsObject(StartDeadlineFn) || HadBackoff || HadDebt
	return HadOwnership && TerminationAccepted
		&& TerminationDebtReleased && ProcessDebtReleased
}

UIASW_OnWorkerExit(WorkerGeneration, ExitCode, Stdout, Stderr) {
	PreviousCritical := A_IsCritical
	Critical("On")
	if (WorkerGeneration != UIASWState.worker_generation) {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return
	}
	RequestGeneration := IsObject(UIASWState.pending)
		? UIASWState.pending["request_generation"] : 0
	StartDeadlineFn := UIASWState.start_deadline_fn
	UIASWState.start_deadline_fn := 0
	Critical(PreviousCritical ? PreviousCritical : "Off")
	if IsObject(StartDeadlineFn)
		try SetTimer(StartDeadlineFn, 0)
	if RequestGeneration {
		UIASW_Complete(RequestGeneration, WorkerGeneration, "failed",
			Map("Error", "Worker exited before publishing a result."), false)
	}
	PreviousCritical := A_IsCritical
	Critical("On")
	if (WorkerGeneration = UIASWState.worker_generation) {
		ProcessHandle := UIASWState.worker_process_handle
		UIASWState.handle := 0
		UIASWState.worker_hwnd := 0
		UIASWState.worker_process_handle := 0
		UIASWState.start_failure_tick := A_TickCount
		WorkerDetail := Trim(Stdout . " " . Stderr)
		UIASWState.start_diagnostic := WorkerDetail != ""
			? "worker exited: " . SubStr(WorkerDetail, 1, 400)
			: "worker exited without a diagnostic"
		UIASWState.worker_generation += 1
	} else {
		ProcessHandle := 0
	}
	Critical(PreviousCritical ? PreviousCritical : "Off")
	UIASW_ReleaseProcessHandle(ProcessHandle)
	try LoggerWarn("Layout", "UIA probe worker exited unexpectedly (exit={1}).", ExitCode)
}

UIASW_OnCopyData(WorkerHwnd, CopyDataPtr, Msg, ReceiverHwnd) {
	global UIASW_MAX_RESULT_BYTES, UIASW_READY_MAX_BYTES
	if (ReceiverHwnd != A_ScriptHwnd || !CopyDataPtr)
		return 0
	CopyTag := NumGet(CopyDataPtr, 0, "UPtr")
	ByteCount := NumGet(CopyDataPtr, A_PtrSize, "UInt")
	DataOffset := (A_PtrSize = 8) ? 16 : 8
	DataPtr := NumGet(CopyDataPtr, DataOffset, "Ptr")
	if (ByteCount < 2 || !DataPtr)
		return 0
	if !CopyTag {
		if ByteCount > UIASW_READY_MAX_BYTES
			return 0
		try WorkerGeneration := Integer(
			StrGet(DataPtr, (ByteCount // 2) - 1, "UTF-16"))
		catch
			return 0
		return UIASW_OnWorkerReady(WorkerHwnd, WorkerGeneration,
			Msg, ReceiverHwnd)
	}
	if ByteCount > UIASW_MAX_RESULT_BYTES
		return 0
	PreviousCritical := A_IsCritical
	Critical("On")
	if !IsObject(UIASWState.pending) || WorkerHwnd != UIASWState.worker_hwnd {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		return 0
	}
	WorkerGeneration := UIASWState.pending["worker_generation"]
	Critical(PreviousCritical ? PreviousCritical : "Off")
	try Payload := StrGet(DataPtr, (ByteCount // 2) - 1, "UTF-16")
	catch
		return 0
	Result := UIASW_ParsePayload(Payload)
	if !(Result is Map)
		return 0
	return UIASW_Complete(CopyTag, WorkerGeneration,
		Result["Status"], Result, false) ? 1 : 0
}

UIASW_ParsePayload(Payload) {
	static Allowed := Map("ok", 1, "empty", 1, "no_text_pattern", 1,
		"stale", 1, "failed", 1)
	First := InStr(Payload, "`n")
	Second := First ? InStr(Payload, "`n", , First + 1) : 0
	Third := Second ? InStr(Payload, "`n", , Second + 1) : 0
	if !First || !Second || !Third
		return 0
	try {
		Status := SubStr(Payload, 1, First - 1)
		Hwnd := Integer(SubStr(Payload, First + 1, Second - First - 1))
		Control := Integer(SubStr(Payload, Second + 1, Third - Second - 1))
	} catch {
		return 0
	}
	if !Allowed.Has(Status)
		return 0
	return Map(
		"Status", Status,
		"Hwnd", Hwnd,
		"Control", Control,
		"Text", SubStr(Payload, Third + 1)
	)
}

UIASW_ContextMatches(Expected, Observed, Live) {
	if !(Expected is Map) || !(Observed is Map) || !(Live is Map)
		return false
	for Field in ["Hwnd", "Control"] {
		if !Expected.Has(Field) || !Observed.Has(Field) || !Live.Has(Field)
			return false
		if !Expected[Field] || Expected[Field] != Observed[Field]
			|| Expected[Field] != Live[Field]
			return false
	}
	return Expected.Has("InputEpoch") && Live.Has("InputEpoch")
		&& Expected["InputEpoch"] = Live["InputEpoch"]
}

; Consumes a short-lived selection capability only when its window, control,
; physical-input generation, and age still match the live caret context.
UIASW_ConsumeSelectionSnapshot(Snapshot, LiveHwnd, LiveControl, LiveInputEpoch,
		ElapsedMs, MaxAgeMs) {
	if !IsObject(Snapshot)
		return ""
	if !(Snapshot.HasOwnProp("Text") and Snapshot.HasOwnProp("Hwnd")
			and Snapshot.HasOwnProp("Control")
			and Snapshot.HasOwnProp("InputEpoch")
			and Snapshot.HasOwnProp("CapturedAt")
			and Snapshot.HasOwnProp("Consumed"))
		return ""
	if !(Snapshot.Text is String) || Snapshot.Text == ""
		return ""
	if Snapshot.Consumed || Snapshot.Hwnd != LiveHwnd
			|| Snapshot.Control != LiveControl
			|| Snapshot.InputEpoch != LiveInputEpoch
			|| ElapsedMs > MaxAgeMs
		return ""
	Snapshot.Consumed := true
	return Snapshot.Text
}
