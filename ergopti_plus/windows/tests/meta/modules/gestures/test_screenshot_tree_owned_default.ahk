; tests/meta/modules/gestures/test_screenshot_tree_owned_default.ahk

; ==============================================================================
; MODULE: Screenshot In-process Capture Default
; DESCRIPTION:
; Structural link guard between screenshot production and its in-process
; capture. The injected spawn_fn seam remains available to deterministic unit
; tests, but the no-injection branch must select the native GDI capture task,
; and the screenshot module must never launch a script host again: v1.0.4 was
; flagged by a corporate antivirus for a hidden PowerShell clipboard stage.
; The shell_runner guards below keep the tree owner's own contract pinned.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Production fallback binding =======
; ==============================================
; ==============================================

_GSTOD_ScreenshotDefaultIsInProcess() {
	local body := _StripFullLineComments(
		_DriverFuncBody("_GestureScreenshotCreateWorker"))
	Assert(body != "",
		"_GestureScreenshotCreateWorker source must exist before its production fallback can be audited")

	local injected_selection := InStr(body,
		"IsObject(GestureScreenshotWorkerState.spawn_fn)")
	local injected_value := InStr(body,
		"? GestureScreenshotWorkerState.spawn_fn")
	Assert(injected_selection > 0 && injected_value > injected_selection,
		"the injected GestureScreenshotWorkerState.spawn_fn seam must remain reachable")

	Assert(RegExMatch(body,
		"s)\?\s*GestureScreenshotWorkerState\.spawn_fn\s*:\s*_GestureScreenshotSpawnNative\b"),
		"the no-injection screenshot branch must use the in-process capture task")
	Assert(!RegExMatch(body, "ShellRunner_Spawn"),
		"the production screenshot fallback must never regress to a child process")
}

Test("screenshot: production spawn fallback is the in-process capture",
	_GSTOD_ScreenshotDefaultIsInProcess)

; Scans the whole screenshot module (full-line comments removed, string
; literals kept) so a launcher hidden in any helper or literal still fails.
_GSTOD_ScreenshotModuleLaunchesNoScriptHost() {
	local path := _DriverProductionFileForSymbol("GestureCaptureRegion")
	local code := _StripFullLineComments(FileRead(path, "UTF-8"))
	Assert(InStr(code, "_GestureScreenshotSpawnNative(Capture, Done)") > 0,
		"the screenshot module scan must read the module that owns the capture")
	for needle in ["powershell", "pwsh", "-EncodedCommand", "-WindowStyle", "-ExecutionPolicy",
			"Add-Type", "DllImport", "TypeDefinition", "System.Drawing", "System.Windows.Forms",
			"ShellRunner_Spawn", "ShellRun", "WScript.Shell", "ComObject("]
		Assert(!InStr(code, needle),
			"the screenshot module must capture in process, never through a script host: found '" . needle . "'")
	Assert(!RegExMatch(code, "\bRun(Wait)?\s*\("),
		"the screenshot module must not launch any process")
}

Test("screenshot: the capture module never launches a hidden script host",
	_GSTOD_ScreenshotModuleLaunchesNoScriptHost)

_GSTOD_TreeOwnerPollsTheExactProcessHandle() {
	local body := _DriverFuncBody("_SR_TreePoll")
	local wait_helper := _DriverFuncBody("_SR_TreeProcessHasExited")
	Assert(body != "",
		"_SR_TreePoll source must exist before its process-identity contract can be audited")
	Assert(wait_helper != "",
		"_SR_TreeProcessHasExited source must exist before its contained OS call can be audited")
	Assert(InStr(body, "_SR_TreeProcessHasExited(process_handle") > 0
		&& InStr(wait_helper, 'DllCall("Kernel32\WaitForSingleObject"') > 0,
		"tree-owned completion must poll the retained process HANDLE through the catch-safe helper")
	Assert(InStr(body, "ProcessExist(") = 0,
		"tree-owned completion must never poll a reusable PID through ProcessExist")
	Assert(InStr(body, 'DllCall("Kernel32\WaitForSingleObject"') = 0
		&& InStr(body, 'DllCall("Kernel32\GetExitCodeProcess"') = 0,
		"the SetTimer callback must not contain raw Wait/GetExitCode DllCalls that can escape to global OnError")
}

Test("shell_runner: tree-owned poll uses an exact process HANDLE, never a PID",
	_GSTOD_TreeOwnerPollsTheExactProcessHandle)

_GSTOD_AccountingOwnsTreeCompletionWithoutJobWaits() {
	local poll := _DriverFuncBody("_SR_TreePoll")
	local accounting := _DriverFuncBody("_SR_TreeActiveProcessCount")
	local confirm := _DriverFuncBody("_SR_TreeConfirmJobEmpty")
	local quiesce := _DriverFuncBody("_SR_TreeQuiesceNative")
	local spawner := _DriverFuncBody("ShellRunner_SpawnTreeOwned")
	for Name, Body in Map(
		"tree poll", poll,
		"accounting query", accounting,
		"bounded confirmation", confirm,
		"native quiesce", quiesce,
		"tree spawner", spawner)
		Assert(Body != "", Name . " source must exist")

	local root_release := InStr(poll,
		'_SR_TreeCloseNativeHandle("process"')
	local accounting_query := InStr(poll, "_SR_TreeActiveProcessCount")
	local completion_claim := InStr(poll,
		"_SR_TreeClaimTaskLocked(state, true, true)")
	Assert(root_release > 0 && accounting_query > root_release
		&& completion_claim > accounting_query,
		"normal completion must close/zero the signaled root HANDLE, then observe ActiveProcesses=0, then claim OnDone")
	Assert(InStr(accounting, 'DllCall("Kernel32\QueryInformationJobObject"') > 0
		&& InStr(accounting, "SR_TREE_ACTIVE_PROCESSES_OFFSET") > 0,
		"JobObjectBasicAccountingInformation.ActiveProcesses must be the exact tree-completion predicate")
	Assert(InStr(confirm, "SR_TREE_TERMINATION_CONFIRM_BUDGET_MS") > 0
		&& InStr(confirm, "Sleep(SR_TREE_TERMINATION_CONFIRM_POLL_MS)") > 0
		&& InStr(confirm, "WaitForSingleObject") = 0
		&& InStr(quiesce, "WaitForSingleObject") = 0,
		"termination confirmation must be bounded/yielding and must never wait on a Job HANDLE")
	local terminate_release := InStr(quiesce,
		'_SR_TreeCloseNativeHandle("process"')
	local terminate_confirm := InStr(quiesce, "_SR_TreeConfirmJobEmpty")
	Assert(terminate_release > 0 && terminate_confirm > terminate_release,
		"forced termination must release its root process reference before ActiveProcesses can reach zero")
	Capture := _DriverFuncBody("_SR_AcquireCaptureDirectory")
	Start := _DriverFuncBody("_SR_TreeHandleStart")
	Create := _DriverFuncBody("_SR_TreeCreateSuspended")
	Assert(Capture != "" && Start != "" && Create != ""
		&& InStr(Start, '_SR_AcquireCaptureDirectory()') > 0
		&& InStr(Capture, "CreateDirectoryW") > 0
		&& InStr(Create, "CreateFileW") > 0
		&& InStr(Create, "PLC_CreateProcessWithInheritedHandles") > 0,
		"tree-owned capture must acquire a private directory and pass its exact output handle to direct CreateProcessW")
	Assert(InStr(poll, "wait_diagnostic !=") > 0
		&& InStr(poll, "force_terminate := true") > 0
		&& InStr(poll, "SR_TREE_ACCOUNTING_FAILURE_LIMIT") > 0
		&& InStr(poll, "_SR_TreeClaimTaskLocked(state, true, false)") > 0
		&& InStr(poll, "_SR_TreeQuiesceNative(claim, force_terminate)") > 0,
		"a failed process-HANDLE poll or repeated accounting failure must atomically claim and force fail-closed teardown instead of leaking the timer/task forever")
}

Test("shell_runner: Job accounting is two-phase, bounded, and process-unique",
	_GSTOD_AccountingOwnsTreeCompletionWithoutJobWaits)
