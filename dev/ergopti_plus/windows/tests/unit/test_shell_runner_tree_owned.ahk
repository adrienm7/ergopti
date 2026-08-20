; tests/unit/test_shell_runner_tree_owned.ahk

; ==============================================================================
; MODULE: ShellRunner Native Tree Ownership
; DESCRIPTION:
; Behavioural regression for the process-tree escape in the cmd.exe redirection
; transport. Killing only the wrapper PID can leave its PowerShell descendant
; alive long enough to publish a canceled screenshot stage.
;
; ROOT CAUSE ENCODED: the real child writes its own PID before sleeping. The test
; proves that terminate() returns only after that exact descendant is gone, then
; waits past the child's delayed side effect to prove it did not merely outlive
; the wrapper invisibly. No fake process handle or source inspection is used.
; ==============================================================================

#Requires AutoHotkey v2.0

global SRTOW_CHILD_SLEEP_MS := 1600
global SRTOW_PID_WAIT_MS := 5000
global SRTOW_PID_POLL_MS := 10
global SRTOW_LATE_EFFECT_WAIT_MS := 1800
global SRTOW_TERMINATE_RETURN_MAX_MS := 1500
global SRTOW_EXIT_SIGNAL_SETTLE_MS := 500
global SRTOW_NATURAL_CHILD_DELAY_MS := 800
global SRTOW_NATURAL_WAIT_MS := 5000
global SRTOW_ONDONE_SETTLE_MS := 250
global SRTOW_POLLER_RACE_YIELD_MS := 25
global SRTOW_POLLER_RACE_WAIT_MS := 1000
global SRTOW_NATURAL_EXIT_CODE := 7
global SRTOW_SYNCHRONIZE := 0x00100000
global SRTOW_WAIT_OBJECT_0 := 0
global SRTOW_WAIT_TIMEOUT := 0x102
global SRTOW_DUPLICATE_SAME_ACCESS := 0x2





; =====================================
; =====================================
; ======= 1/ Disposable fixture =======
; =====================================
; =====================================

_SRTOW_DeleteIfPresent(Path) {
	try {
		if FileExist(Path)
			FileDelete(Path)
	}
}

_SRTOW_WaitForChildPid(PidPath) {
	local started_tick := A_TickCount
	while TickElapsed(started_tick) < SRTOW_PID_WAIT_MS {
		try {
			if FileExist(PidPath) {
				local raw_pid := Trim(FileRead(PidPath))
				if RegExMatch(raw_pid, "^\d+$") {
					local child_pid := Integer(raw_pid)
					if child_pid > 0
						return child_pid
				}
			}
		}
		Sleep(SRTOW_PID_POLL_MS)
	}
	return 0
}

_SRTOW_OpenExactProcess(Pid) {
	return DllCall("Kernel32\OpenProcess", "UInt", SRTOW_SYNCHRONIZE,
		"Int", false, "UInt", Pid, "Ptr")
}

_SRTOW_ExactProcessWait(ProcessHandle) {
	return DllCall("Kernel32\WaitForSingleObject", "Ptr", ProcessHandle,
		"UInt", 0, "UInt")
}

_SRTOW_WaitForExactProcessExit(ProcessHandle) {
	local started_tick := A_TickCount
	while TickElapsed(started_tick) < SRTOW_EXIT_SIGNAL_SETTLE_MS {
		if _SRTOW_ExactProcessWait(ProcessHandle) == SRTOW_WAIT_OBJECT_0
			return true
		Sleep(SRTOW_PID_POLL_MS)
	}
	return _SRTOW_ExactProcessWait(ProcessHandle) == SRTOW_WAIT_OBJECT_0
}

_SRTOW_DuplicateNativeHandle(NativeHandle) {
	local current_process := DllCall("Kernel32\GetCurrentProcess", "Ptr")
	local duplicate := 0
	if !DllCall("Kernel32\DuplicateHandle",
			"Ptr", current_process,
			"Ptr", NativeHandle,
			"Ptr", current_process,
			"Ptr*", &duplicate,
			"UInt", 0,
			"Int", false,
			"UInt", SRTOW_DUPLICATE_SAME_ACCESS,
			"Int")
		return 0
	return duplicate
}

_SRTOW_ExactJobActiveProcessCount(JobHandle) {
	local accounting := Buffer(SR_TREE_BASIC_ACCOUNTING_BYTES, 0)
	if !DllCall("Kernel32\QueryInformationJobObject",
			"Ptr", JobHandle,
			"Int", SR_TREE_JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
			"Ptr", accounting.Ptr,
			"UInt", accounting.Size,
			"Ptr", 0,
			"Int")
		return -1
	return NumGet(accounting, SR_TREE_ACTIVE_PROCESSES_OFFSET, "UInt")
}





; =====================================================
; =====================================================
; ======= 2/ terminate() drains the native tree =======
; =====================================================
; =====================================================

_SRTOW_TerminateReapsDescendantBeforeReturn() {
	local nonce := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount
	local script_path := A_Temp . "\ergopti_sr_tree_child_" . nonce . ".ps1"
	local pid_path := A_Temp . "\ergopti_sr_tree_child_" . nonce . ".pid"
	local late_path := A_Temp . "\ergopti_sr_tree_child_" . nonce . ".late"
	local handle := 0
	local child_pid := 0
	local child_handle := 0
	local script := "param([string]$PidPath, [string]$LatePath)" . "`n"
		. "[System.IO.File]::WriteAllText($PidPath, [string]$PID)" . "`n"
		. "Start-Sleep -Milliseconds " . SRTOW_CHILD_SLEEP_MS . "`n"
		. "[System.IO.File]::WriteAllText($LatePath, 'late')" . "`n"

	try {
		_SRTOW_DeleteIfPresent(script_path)
		_SRTOW_DeleteIfPresent(pid_path)
		_SRTOW_DeleteIfPresent(late_path)
		FileAppend(script, script_path, "UTF-8")
		handle := ShellRunner_SpawnTreeOwned("powershell.exe", [
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", script_path,
			pid_path,
			late_path
		], (*) => 0)
		Assert(IsObject(handle),
			"ShellRunner_SpawnTreeOwned must return a lifecycle handle")
		Assert(handle.start() == true,
			"the disposable tree-owned PowerShell child must start")

		child_pid := _SRTOW_WaitForChildPid(pid_path)
		Assert(child_pid > 0,
			"the real PowerShell descendant must publish its native PID")
		Assert(ProcessExist(child_pid) == child_pid,
			"positive control: the published descendant PID must be alive before terminate()")
		child_handle := _SRTOW_OpenExactProcess(child_pid)
		Assert(child_handle != 0,
			"the regression must retain an exact descendant HANDLE before cancellation")
		Assert(_SRTOW_ExactProcessWait(child_handle) == SRTOW_WAIT_TIMEOUT,
			"positive control: the exact descendant HANDLE must be unsignaled before terminate()")

		local terminate_started := A_TickCount
		local terminate_result := handle.terminate()
		local terminate_elapsed := TickElapsed(terminate_started)
		Assert(terminate_elapsed <= SRTOW_TERMINATE_RETURN_MAX_MS,
			"terminate() must obey its bounded accounting budget instead of hanging on a Job HANDLE")
		Assert(terminate_result == true,
			"terminate() must report that its Job Object reached zero active processes")
		; Job accounting reaches zero when the process can no longer execute, a
		; few scheduler ticks before Windows finishes signaling/reaping every
		; external process HANDLE. Require that exact HANDLE to converge within
		; a second bounded window, then wait past the would-be late side effect.
		Assert(_SRTOW_WaitForExactProcessExit(child_handle),
			"the exact real-descendant HANDLE must become signaled after Job accounting reaches zero")
		Sleep(SRTOW_LATE_EFFECT_WAIT_MS)
		Assert(!FileExist(late_path),
			"a descendant killed with its Job Object must never publish its delayed side effect")
	} finally {
		if child_handle
			try DllCall("Kernel32\CloseHandle", "Ptr", child_handle, "Int")
		if IsObject(handle)
			try handle.terminate()
		_SRTOW_DeleteIfPresent(script_path)
		_SRTOW_DeleteIfPresent(pid_path)
		_SRTOW_DeleteIfPresent(late_path)
	}
}

Test("shell_runner: tree-owned terminate reaps a real descendant before returning",
	_SRTOW_TerminateReapsDescendantBeforeReturn)





; ===========================================================
; ===========================================================
; ======= 3/ Natural completion waits for descendants =======
; ===========================================================
; ===========================================================

_SRTOW_WaitForFile(Path, TimeoutMs) {
	local started_tick := A_TickCount
	while TickElapsed(started_tick) < TimeoutMs {
		if FileExist(Path)
			return true
		Sleep(SRTOW_PID_POLL_MS)
	}
	return false
}

_SRTOW_NaturalCompletionWaitsForDescendant() {
	local nonce := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_natural_" . A_TickCount
	local parent_path := A_Temp . "\ergopti_sr_tree_parent_" . nonce . ".ps1"
	local child_path := A_Temp . "\ergopti_sr_tree_grandchild_" . nonce . ".ps1"
	local marker_path := A_Temp . "\ergopti_sr_tree_marker_" . nonce . ".txt"
	local handle := 0
	local done_count := 0
	local done_exit_code := 0
	local done_stdout := ""
	local marker_existed_at_done := false
	local child_script := "param([string]$MarkerPath)" . "`n"
		. "Start-Sleep -Milliseconds " . SRTOW_NATURAL_CHILD_DELAY_MS . "`n"
		. "[System.IO.File]::WriteAllText($MarkerPath, 'descendant-done')" . "`n"
	local parent_script := "param([string]$ChildScript, [string]$MarkerPath)" . "`n"
		. "$q = [char]34" . "`n"
		. "$childArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $q + $ChildScript + $q + ' ' + $q + $MarkerPath + $q" . "`n"
		. "Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $childArgs | Out-Null" . "`n"
		. "Write-Output 'ROOT_DONE'" . "`n"
		. "exit " . SRTOW_NATURAL_EXIT_CODE . "`n"

	_SRTOW_OnDone(ExitCode, Stdout, Stderr) {
		done_count += 1
		done_exit_code := ExitCode
		done_stdout := Stdout
		marker_existed_at_done := FileExist(marker_path) ? true : false
	}

	try {
		_SRTOW_DeleteIfPresent(parent_path)
		_SRTOW_DeleteIfPresent(child_path)
		_SRTOW_DeleteIfPresent(marker_path)
		FileAppend(parent_script, parent_path, "UTF-8")
		FileAppend(child_script, child_path, "UTF-8")
		handle := ShellRunner_SpawnTreeOwned("powershell.exe", [
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", parent_path,
			child_path,
			marker_path
		], _SRTOW_OnDone)
		Assert(handle.start() == true,
			"the natural-completion fixture must start its root PowerShell")

		local root_wait_started := A_TickCount
		while handle.processId() != 0
				&& TickElapsed(root_wait_started) < SRTOW_NATURAL_WAIT_MS
			Sleep(SRTOW_PID_POLL_MS)
		Assert(handle.processId() == 0,
			"the poller must reap and close the exited cmd.exe root within the test deadline")
		Assert(done_count = 0,
			"OnDone must remain fenced after root exit while its delayed descendant is active")

		Assert(_SRTOW_WaitForFile(marker_path, SRTOW_NATURAL_WAIT_MS),
			"the surviving descendant must publish its delayed marker")
		local done_wait_started := A_TickCount
		while done_count = 0
				&& TickElapsed(done_wait_started) < SRTOW_NATURAL_WAIT_MS
			Sleep(SRTOW_PID_POLL_MS)
		Assert(done_count = 1 && marker_existed_at_done,
			"OnDone must fire exactly once only after the descendant marker exists and the full Job tree is empty")
		Assert(done_exit_code = SRTOW_NATURAL_EXIT_CODE,
			"natural completion must preserve the reaped root wrapper's exit code")
		Assert(InStr(done_stdout, "ROOT_DONE") > 0,
			"natural completion must preserve the root wrapper's captured stdout")
		Sleep(SRTOW_ONDONE_SETTLE_MS)
		Assert(done_count = 1,
			"the two-phase root/accounting polls must never dispatch OnDone twice")
	} finally {
		if IsObject(handle)
			try handle.terminate()
		_SRTOW_DeleteIfPresent(parent_path)
		_SRTOW_DeleteIfPresent(child_path)
		_SRTOW_DeleteIfPresent(marker_path)
	}
}

Test("shell_runner: natural completion waits for the full descendant tree",
	_SRTOW_NaturalCompletionWaitsForDescendant)





; =========================================================
; =========================================================
; ======= 4/ Poller timer/flag linearization ==============
; =========================================================
; =========================================================

_SRTOW_PollerTimerAndFlagTransitionTogether() {
	global _SR_TreeOwnedTasks, _SR_TreePollRunning, _SR_POLL_INTERVAL_MS
	local saved_tasks := _SR_TreeOwnedTasks
	local saved_running := _SR_TreePollRunning
	local scheduler := Map(
		"Armed", true,
		"RaceScheduled", false,
		"Calls", [])
	local publish_count := 0

	_SRTOW_PublishAndRearm() {
		SetTimer(_SRTOW_PublishAndRearm, 0)
		publish_count += 1
		_SR_TreeOwnedTasks[1] := Map("Fixture", true)
		_SR_TreeEnsurePoller(_SRTOW_ApplyTimer)
	}

	_SRTOW_ApplyTimer(Period) {
		; The old implementation reached this disarm only after leaving Critical.
		; Its Sleep therefore admitted the one-shot start, whose arm was then
		; overwritten when this stale callback resumed and recorded period zero.
		if Period = 0 && !scheduler["RaceScheduled"] {
			scheduler["RaceScheduled"] := true
			SetTimer(_SRTOW_PublishAndRearm, -1)
			if A_IsCritical
				Sleep(SRTOW_POLLER_RACE_YIELD_MS)
			else {
				local handshake_started := A_TickCount
				while publish_count = 0
					&& TickElapsed(handshake_started) < SRTOW_POLLER_RACE_WAIT_MS
					Sleep(1)
				Assert(publish_count = 1,
					"positive control: an unfenced stale disarm must admit the racing publisher")
			}
		}
		scheduler["Calls"].Push(Map(
			"Period", Period,
			"Critical", A_IsCritical != 0,
			"OldFlag", _SR_TreePollRunning))
		scheduler["Armed"] := Period > 0
	}

	try {
		Assert(saved_tasks.Count = 0 && !saved_running,
			"the poller transaction fixture requires the shared tree registry to be idle")
		_SR_TreeOwnedTasks := Map()
		_SR_TreePollRunning := true

		; Drive the real empty-poll path. The scheduled publisher can interrupt
		; the fake only if production has already released its Critical fence.
		_SR_TreePoll(_SRTOW_ApplyTimer)
		local wait_started := A_TickCount
		while publish_count = 0
			&& TickElapsed(wait_started) < SRTOW_POLLER_RACE_WAIT_MS
			Sleep(1)

		Assert(publish_count = 1 && scheduler["Calls"].Length = 2,
			"the injected start must publish once and exercise both timer transitions")
		local disarm := scheduler["Calls"][1]
		local arm := scheduler["Calls"][2]
		Assert(disarm["Period"] = 0 && arm["Period"] = _SR_POLL_INTERVAL_MS,
			"Critical must linearize the stale tick before the racing arm, never arm then disarm")
		Assert(disarm["Critical"] && arm["Critical"],
			"both real timer operations must remain inside their Critical transactions")
		Assert(disarm["OldFlag"] && !arm["OldFlag"],
			"each timer operation must see the prior flag before committing its new value")
		Assert(_SR_TreeOwnedTasks.Count = 1
			&& _SR_TreePollRunning && scheduler["Armed"],
			"a task published by the racing start must retain a live poller")
	} finally {
		try SetTimer(_SRTOW_PublishAndRearm, 0)
		_SR_TreeOwnedTasks := saved_tasks
		_SR_TreePollRunning := saved_running
	}
}
Test("shell_runner: tree poller timer and flag transition together (shellrunner-tree-poller-linearization)",
	_SRTOW_PollerTimerAndFlagTransitionTogether)

_SRTOW_PollerTimerFailureDoesNotCommitFlag() {
	global _SR_TreeOwnedTasks, _SR_TreePollRunning
	local saved_tasks := _SR_TreeOwnedTasks
	local saved_running := _SR_TreePollRunning
	local throw_count := 0

	_SRTOW_ThrowingTimer(Period) {
		Assert(A_IsCritical != 0,
			"even a failing timer backend must run inside the poller transaction")
		throw_count += 1
		throw Error("synthetic tree-poller timer failure")
	}

	try {
		Assert(saved_tasks.Count = 0 && !saved_running,
			"the poller failure fixture requires the shared tree registry to be idle")
		_SR_TreeOwnedTasks := Map()
		_SR_TreePollRunning := true
		local disarm_threw := false
		try _SR_TreePoll(_SRTOW_ThrowingTimer)
		catch as Err {
			disarm_threw := InStr(Err.Message, "synthetic tree-poller timer failure") > 0
		}
		Assert(disarm_threw && _SR_TreePollRunning,
			"a failed disarm must preserve the prior true flag")

		_SR_TreePollRunning := false
		local arm_threw := false
		try _SR_TreeEnsurePoller(_SRTOW_ThrowingTimer)
		catch as Err {
			arm_threw := InStr(Err.Message, "synthetic tree-poller timer failure") > 0
		}
		Assert(arm_threw && !_SR_TreePollRunning,
			"a failed arm must preserve the prior false flag")
		Assert(throw_count = 2,
			"both real poller transition paths must reach the injected timer backend")
	} finally {
		_SR_TreeOwnedTasks := saved_tasks
		_SR_TreePollRunning := saved_running
	}
}
Test("shell_runner: failed tree timer operation cannot commit its flag (shellrunner-tree-poller-failure)",
	_SRTOW_PollerTimerFailureDoesNotCommitFlag)





; =========================================================
; =========================================================
; ======= 5/ Termination while native handles are private =
; =========================================================
; =========================================================

_SRTOW_StartingTerminationDefersUntilNativeAdoption(TerminationSequence,
		ScenarioName, ExpectCallback, DetachAfter := false,
		UseAsyncTerminate := false) {
	global _SR_TreeOwnedTasks
	local nonce := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_starting_" . ScenarioName
		. "_" . A_TickCount
	local marker_path := A_Temp . "\ergopti_sr_starting_" . nonce . ".late"
	local escaped_marker := StrReplace(marker_path, "'", "''")
	local script := "Start-Sleep -Milliseconds 400;"
		. "[System.IO.File]::WriteAllText('" . escaped_marker . "','late')"
	local handle := 0
	local observation_handle := 0
	local job_observation_handle := 0
	local observed_state := 0
	local observed_native := 0
	local hook_active := false
	local hook_results := Array()
	local hook_native_complete := false
	local hook_state_private := false
	local hook_terminal_claimed := false
	local hook_tree_quiesced := false
	local hook_finalization_pending := false
	local hook_pending_callback := false
	local hook_detach_result := false
	local hook_process_wait := SRTOW_WAIT_OBJECT_0
	local callback_count := 0
	local callback_during_hook := false
	local callback_saw_quiesced := false
	local callback_active_processes := -1
	local callback_exit_code := -1
	local callback_stdout := "sentinel"
	local callback_stderr := "sentinel"

	_SRTOW_OnStartingDone(ExitCode, Stdout, Stderr) {
		callback_count += 1
		callback_during_hook := hook_active
		callback_saw_quiesced := IsObject(observed_state)
			&& observed_state["TreeQuiesced"]
		callback_active_processes := job_observation_handle
			? _SRTOW_ExactJobActiveProcessCount(job_observation_handle) : -1
		callback_exit_code := ExitCode
		callback_stdout := Stdout
		callback_stderr := Stderr
	}

	_SRTOW_BeforeNativeAdopt(State, Native) {
		observed_state := State
		observed_native := Native
		hook_native_complete := Native["ProcessHandle"] != 0
			&& Native["ThreadHandle"] != 0 && Native["JobHandle"] != 0
			&& Native["Assigned"]
		hook_state_private := State["Starting"]
			&& !State["Started"] && State["ProcessHandle"] = 0
			&& State["ThreadHandle"] = 0 && State["JobHandle"] = 0
			&& !_SR_TreeOwnedTasks.Has(State["TaskId"])
		observation_handle := _SRTOW_OpenExactProcess(Native["Pid"])
		job_observation_handle := _SRTOW_DuplicateNativeHandle(
			Native["JobHandle"])
		hook_active := true
		for fire_done in TerminationSequence {
			if fire_done
				hook_results.Push(handle.requestTerminate())
			else if UseAsyncTerminate
				hook_results.Push(handle.terminateAsync())
			else
				hook_results.Push(handle.terminate())
		}
		if DetachAfter
			hook_detach_result := handle.detach()
		hook_active := false
		hook_terminal_claimed := State["TerminalClaimed"]
		hook_tree_quiesced := State["TreeQuiesced"]
		hook_finalization_pending := State["FinalizationPending"]
		hook_pending_callback := IsObject(
			State.Get("PendingTerminationCallback", 0))
		hook_process_wait := observation_handle
			? _SRTOW_ExactProcessWait(observation_handle) : SRTOW_WAIT_OBJECT_0
	}

	try {
		_SRTOW_DeleteIfPresent(marker_path)
		Assert(_SR_TreeOwnedTasks.Count = 0,
			"the STARTING race fixture requires an idle tree-owned registry")
		handle := ShellRunner_SpawnTreeOwned("powershell.exe", [
			"-NoProfile", "-NonInteractive", "-Command", script
		], _SRTOW_OnStartingDone, 0, _SRTOW_BeforeNativeAdopt)
		local started := handle.start()

		Assert(hook_native_complete && hook_state_private
			&& observation_handle != 0 && job_observation_handle != 0,
			"positive control: cancellation must land after complete native creation but before State adoption")
		local every_call_pending := hook_results.Length = TerminationSequence.Length
		for result in hook_results
			every_call_pending := every_call_pending && result == false
		Assert(every_call_pending,
			"no STARTING termination call can report success before private handles are quiesced")
		Assert(!hook_terminal_claimed && !hook_tree_quiesced,
			"STARTING termination must not manufacture a terminal empty-handle claim")
		Assert(hook_finalization_pending,
			"STARTING termination must reserve the later native finalization")
		Assert(!DetachAfter || hook_detach_result,
			"detach during STARTING must synchronously retire callback ownership")
		Assert(hook_pending_callback = ExpectCallback,
			"STARTING callback ownership must follow request/terminate/detach semantics until terminal claim")
		Assert(hook_process_wait = SRTOW_WAIT_TIMEOUT,
			"the exact suspended process must still be live when the pending request returns false")
		Assert(!started,
			"a start canceled before ResumeThread must report false")
		Assert(_SRTOW_WaitForExactProcessExit(observation_handle),
			"the resumed start stack must quiesce the exact private process before returning")
		Assert(observed_state["TerminalClaimed"]
			&& observed_state["TreeQuiesced"]
			&& !observed_state["FinalizationPending"],
			"native adoption must finish one real terminal claim and record quiescence")
		Assert(observed_state["ProcessHandle"] = 0
			&& observed_state["ThreadHandle"] = 0
			&& observed_state["JobHandle"] = 0
			&& observed_state["Pid"] = 0,
			"the completed STARTING cancellation must retain no native handle or PID")
		Assert(observed_native["ProcessHandle"] = 0
			&& observed_native["ThreadHandle"] = 0
			&& observed_native["JobHandle"] = 0,
			"private native ownership must be transferred and consumed exactly once")
		Assert(_SR_TreeOwnedTasks.Count = 0,
			"a canceled suspended process must never enter the completion registry")
		Assert(!FileExist(marker_path),
			"the canceled suspended process must never run its delayed side effect")

		if ExpectCallback {
			Assert(callback_count = 1 && !callback_during_hook
				&& callback_saw_quiesced
				&& callback_active_processes = 0,
				"requestTerminate callback must fire once only after real native quiescence")
			Assert(callback_exit_code = SR_TREE_TERMINATE_EXIT_CODE
				&& callback_stdout = "" && callback_stderr = "",
				"deferred STARTING completion must preserve the termination callback contract")
		} else {
			Assert(!hook_pending_callback && callback_count = 0,
				"terminate must suppress completion ownership while STARTING")
		}
		Assert(handle.terminate(),
			"termination after completed STARTING cleanup must be an idempotent confirmed success")
		Assert(callback_count = (ExpectCallback ? 1 : 0),
			"repeated terminal calls must never duplicate the reserved callback")
	} finally {
		if job_observation_handle
			try DllCall("Kernel32\CloseHandle", "Ptr", job_observation_handle, "Int")
		if observation_handle
			try DllCall("Kernel32\CloseHandle", "Ptr", observation_handle, "Int")
		if IsObject(handle)
			try handle.terminate()
		_SRTOW_DeleteIfPresent(marker_path)
	}
}

Test("shell_runner: terminate while STARTING waits for private native cleanup (shellrunner-tree-starting-terminate)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[false], "terminate", false))

Test("shell_runner: requestTerminate while STARTING defers callback until cleanup (shellrunner-tree-starting-request)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[true], "request", true))

Test("shell_runner: later STARTING terminate suppresses pending callback (shellrunner-tree-starting-request-then-terminate)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[true, false], "request_then_terminate", false))

Test("shell_runner: STARTING request cannot reacquire a suppressed callback (shellrunner-tree-starting-terminate-then-request)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[false, true], "terminate_then_request", false))

Test("shell_runner: STARTING detach retires a pending callback (shellrunner-tree-starting-request-then-detach)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[true], "request_then_detach", false, true))

Test("shell_runner: terminateAsync shares the honest STARTING fence (shellrunner-tree-starting-terminate-async)",
	_SRTOW_StartingTerminationDefersUntilNativeAdoption.Bind(
		[false], "terminate_async", false, false, true))

_SRTOW_ThrowingBeforeAdoptHookCannotLeakNative(ThrowErrorObject) {
	global _SR_TreeOwnedTasks
	local nonce := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_starting_hook_" . (ThrowErrorObject ? "error" : "value")
		. "_" . A_TickCount
	local marker_path := A_Temp . "\ergopti_sr_starting_" . nonce . ".late"
	local escaped_marker := StrReplace(marker_path, "'", "''")
	local script := "Start-Sleep -Milliseconds 400;"
		. "[System.IO.File]::WriteAllText('" . escaped_marker . "','late')"
	local handle := 0
	local observation_handle := 0
	local observed_state := 0
	local observed_native := 0
	local callback_count := 0

	_SRTOW_UnexpectedDone(*) {
		callback_count += 1
	}

	_SRTOW_ThrowAfterNativeCreation(State, Native) {
		observed_state := State
		observed_native := Native
		observation_handle := _SRTOW_OpenExactProcess(Native["Pid"])
		if ThrowErrorObject
			throw Error("")
		throw "intentional before-adopt non-Error test failure"
	}

	try {
		_SRTOW_DeleteIfPresent(marker_path)
		Assert(_SR_TreeOwnedTasks.Count = 0,
			"the throwing-hook fixture requires an idle tree-owned registry")
		handle := ShellRunner_SpawnTreeOwned("powershell.exe", [
			"-NoProfile", "-NonInteractive", "-Command", script
		], _SRTOW_UnexpectedDone, 0, _SRTOW_ThrowAfterNativeCreation)
		local started := handle.start()

		Assert(!started && observation_handle != 0,
			"a throwing before-adopt hook must fail start after creating an observable exact process")
		Assert(_SRTOW_WaitForExactProcessExit(observation_handle),
			"hook failure must quiesce the exact private process before start returns")
		Assert(observed_state["TerminalClaimed"]
			&& observed_state["TreeQuiesced"]
			&& !observed_state["FinalizationPending"],
			"hook failure must record one completed terminal native claim")
		Assert(observed_native["ProcessHandle"] = 0
			&& observed_native["ThreadHandle"] = 0
			&& observed_native["JobHandle"] = 0,
			"hook failure must consume every private native handle exactly once")
		Assert(_SR_TreeOwnedTasks.Count = 0 && callback_count = 0,
			"failed pre-adoption work must neither publish nor report successful completion")
		Assert(!FileExist(marker_path),
			"the suspended process from a throwing hook must never execute")
		Assert(handle.terminate(),
			"post-cleanup termination after a throwing hook must be idempotently confirmed")
	} finally {
		if observation_handle
			try DllCall("Kernel32\CloseHandle", "Ptr", observation_handle, "Int")
		if IsObject(handle)
			try handle.terminate()
		_SRTOW_DeleteIfPresent(marker_path)
	}
}
Test("shell_runner: empty Error STARTING throw quiesces private native ownership (shellrunner-tree-starting-hook-error-object)",
	_SRTOW_ThrowingBeforeAdoptHookCannotLeakNative.Bind(true))
Test("shell_runner: non-Error STARTING throw quiesces private native ownership (shellrunner-tree-starting-hook-error-value)",
	_SRTOW_ThrowingBeforeAdoptHookCannotLeakNative.Bind(false))
