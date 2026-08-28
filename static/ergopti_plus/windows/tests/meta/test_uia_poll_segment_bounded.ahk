; tests/meta/test_uia_poll_segment_bounded.ahk

; ==============================================================================
; MODULE: UIA Selection-Poll Bounding Meta Test
; DESCRIPTION:
; Regression guard for AHK-02 / uia-poll-segment-unbounded.
;
; AHK SetTimer callbacks and keyboard hooks share one thread. Checking a budget
; between synchronous COM calls cannot interrupt the call already in progress;
; retained UIA.SelectionPoll samples reached 681.79 ms. The enforceable boundary
; is therefore architectural: the resident tick contains no UIA call, a detached
; worker owns every COM hop, and a <=60 ms timer retires ownership before killing
; that process. The unchanged-input gate remains because avoiding needless IPC is
; still cheaper than starting a correctly isolated probe.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ======================================
; ======================================
; ======= 1/ Killable deadline =========
; ======================================
; ======================================

_UPB_Body() {
	Body := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(Body != "", "_UIA_SelectionPollTick() must exist in the driver source")
	return Body
}

_UPB_ProbeIsOutsideResidentThread() {
	Body := _UPB_Body()
	Assert(InStr(Body, "UIASW_Request(") > 0,
		"the resident poll must dispatch through the detached UIA worker")
	for Forbidden in ["UIA.GetFocusedElement", ".GetPattern(", ".GetSelection(", ".GetText("] {
		Assert(InStr(Body, Forbidden) = 0,
			"a synchronous UIA hop remains on the keyboard thread: " . Forbidden)
	}
	Worker := _DriverFuncBody("UIASW_WorkerHandleRequest")
	Assert(Worker != "" && InStr(Worker, "UIA.GetFocusedElement()") > 0
		&& InStr(Worker, '.GetPattern("Text")') > 0
		&& InStr(Worker, ".GetSelection()") > 0,
		"the UIA hops must still exist, but only in the detached worker handler")
}

_UPB_WorkerDeadlineCanInterruptCurrentHop() {
	Src := _DriverSourceConcat()
	Assert(RegExMatch(Src, "global\s+UIASW_DEADLINE_MS\s*:=\s*([0-9]+)", &BudgetM) > 0,
		"the detached selection worker must have a named owner deadline")
	Budget := BudgetM[1] + 0
	Assert(Budget > 0 && Budget <= 60,
		"the UIA worker deadline must be at most 60 ms (found " . Budget . " ms)")

	Request := _DriverFuncBody("_UIASW_Request")
	Deadline := _DriverFuncBody("UIASW_OnDeadline")
	Complete := _DriverFuncBody("UIASW_Complete")
	Assert(Request != "" && Deadline != "" && Complete != "",
		"the UIA worker request/deadline/completion owner functions must exist")
	TimerPos := InStr(Request, "SetTimer(DeadlineFn, -UIASW_DEADLINE_MS)")
	PostPos := InStr(Request, "Post.Call(")
	Assert(TimerPos > 0 && PostPos > 0 && TimerPos < PostPos,
		"the kill deadline must be armed before posting work; arming afterward loses a synchronous completion/stall race")
	Assert(InStr(Deadline, '"timeout"') > 0 && InStr(Deadline, "true") > 0,
		"deadline expiry must complete the live request as timeout with worker teardown")
	Assert(InStr(Complete, "UIASW_TerminateWorker(Handle, ProcessHandle)") > 0,
		"the deadline owner must terminate the process containing the currently blocked COM call")
	Terminate := _DriverFuncBody("UIASW_TerminateWorker")
	NativeTerminate := _DriverFuncBody("UIAW_TerminateProcessHandle")
	Assert(Terminate != "" && InStr(Terminate, "UIASW_TerminateProcessHandle") > 0
		&& InStr(Terminate, ".detach()") > 0
		&& NativeTerminate != "" && InStr(NativeTerminate, "TerminateProcess") > 0
		&& InStr(Terminate, "ProcessClose(") = 0,
		"the deadline must initiate asynchronous TerminateProcess against its retained child handle and detach shell completion; synchronous ProcessClose cannot sit on the keyboard thread")
	OpenWorker := _DriverFuncBody("UIASW_OpenWorkerProcess")
	NativeOpen := _DriverFuncBody("UIAW_OpenVerifiedWorkerProcess")
	ParentPid := _DriverFuncBody("UIAW_WorkerParentPid")
	Ready := _DriverFuncBody("UIASW_OnWorkerReady")
	Assert(OpenWorker != "" && InStr(OpenWorker, "UIAW_OpenVerifiedWorkerProcess") > 0
		&& NativeOpen != "" && InStr(NativeOpen, "OpenProcess") > 0
		&& InStr(NativeOpen, "ExpectedParentPid") > 0
		&& ParentPid != "" && InStr(ParentPid, "NtQueryInformationProcess") > 0
		&& Ready != "" && InStr(Ready, "UIASW_OpenWorkerProcess(WorkerHwnd, WrapperPid)") > 0
		&& InStr(Ready, ".processId()") > 0,
		"the ready handshake must retain a kernel process HANDLE and prove the HWND process is ShellRunner's child; a spoofed sender or recycled numeric PID must never become the deadline target")
	AsyncTerminate := _DriverFuncBody("_SR_HandleTerminateAsync")
	AsyncClaim := _DriverFuncBody("_SR_LegacyClaimAsyncTerminate")
	Publish := _DriverFuncBody("_SR_LegacyPublishStart")
	Start := _DriverFuncBody("_SR_HandleStart")
	TreeKill := _DriverFuncBody("_SR_LegacyRequestTreeKill")
	Assert(InStr(AsyncTerminate, "_SR_LegacyClaimAsyncTerminate(state)") > 0
		&& InStr(AsyncTerminate, '_SR_LegacyRequestTreeKill(outcome["Pid"])') > 0
		&& InStr(TreeKill, 'Run("taskkill.exe') > 0
		&& InStr(AsyncTerminate . AsyncClaim . TreeKill, "ProcessClose(") = 0
		&& InStr(AsyncTerminate . AsyncClaim . TreeKill, "FileDelete(") = 0,
		"ShellRunner's async termination must only launch the tree kill and detach completion; it must never wait in ProcessClose or filesystem cleanup")
	Assert(InStr(AsyncClaim, 'State["AsyncTerminationRequested"] := true') > 0
		&& InStr(AsyncClaim, 'State["CancelLaunch"] := true') = 0,
		"terminateAsync during Run must use its own publication token, never the synchronous private-cleanup token")
	PublishOwnerPos := InStr(Publish, "_SR_ActiveTasks[task_id] := State")
	PublishAsyncPos := InStr(Publish,
		'start_cancelled := State["AsyncTerminationRequested"]')
	Assert(PublishOwnerPos > 0 && PublishAsyncPos > PublishOwnerPos
		&& InStr(Publish, '"StartCanceled", start_cancelled', true, PublishAsyncPos) > 0,
		"async Run-pump cancellation must publish detached poller ownership before start reports cancellation")
	Assert(InStr(Start, 'return !publication["StartCanceled"]') > 0,
		"the resumed start stack must return false after launching only the deferred tree kill")
}

_UPB_TimeoutFallsToNoSelection() {
	Terminal := _DriverFuncBody("_UIA_OnSelectionWorkerTerminal")
	Assert(Terminal != "", "_UIA_OnSelectionWorkerTerminal() must exist")
	TimeoutPos := InStr(Terminal, 'Status = "timeout"')
	ClearPos := InStr(Terminal, "_UIA_SelectionCache := 0", , TimeoutPos)
	Assert(TimeoutPos > 0 && ClearPos > TimeoutPos,
		"worker timeout must clear the old selection snapshot before returning")
}





; =======================================
; =======================================
; ======= 2/ Unchanged input gate =======
; =======================================
; =======================================

_UPB_UnchangedInputsAreNotReprobed() {
	Body := _UPB_Body()
	Assert(InStr(Body, "_UIA_LastProbeHwnd") > 0,
		"the poll must remember the window it last probed")
	Assert(InStr(Body, "_UIA_LastProbeIdleEpoch") > 0,
		"the poll must remember the physical-input generation it last probed")
	Assert(InStr(Body, "A_TimeIdlePhysical") > 0 || InStr(Body, "_UIA_CurrentInputEpoch()") > 0,
		"the release signal must derive from physical input")
	SkipPos := InStr(Body, "_UIA_LastProbeHwnd ==")
	DispatchPos := InStr(Body, "UIASW_Request(")
	Assert(SkipPos > 0 && DispatchPos > SkipPos,
		"the unchanged-context skip must precede worker dispatch")
	Chunk := SubStr(Body, SkipPos, 400)
	Assert(InStr(Chunk, "_UIA_LastProbeIdleEpoch ==") > 0 && InStr(Chunk, " and ") > 0,
		"the skip must require both the same HWND and the same physical-input generation")
}


Test("meta uia-poll: every COM hop runs outside the resident keyboard thread (uia-worker-deadline)",
	_UPB_ProbeIsOutsideResidentThread)
Test("meta uia-poll: the 60 ms owner deadline kills the current COM hop (uia-worker-deadline)",
	_UPB_WorkerDeadlineCanInterruptCurrentHop)
Test("meta uia-poll: timeout retires the old selection snapshot (uia-worker-deadline)",
	_UPB_TimeoutFallsToNoSelection)
Test("meta uia-poll: unchanged focus/input context is not re-probed",
	_UPB_UnchangedInputsAreNotReprobed)
