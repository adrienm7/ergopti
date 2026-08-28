; tests/meta/test_deps_installer_pid_captured.ahk

; ==============================================================================
; MODULE: Ollama Installer Exact-Owner Regression
; DESCRIPTION:
; A numeric PID can be reused after winget exits while the daemon readiness poll
; remains active. Cancellation must therefore retain the exact ShellRunner task,
; not reopen a long-lived PID with taskkill. These tests cover both the source
; wiring and the ABA case where an old completion arrives after a replacement
; owner was published.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_DIPC_InstallerUsesExactTreeOwner() {
	RunBody := _DriverFuncBody("LLM_Deps_RunInstaller")
	CancelBody := _DriverFuncBody("LLM_Deps_Cancel")
	Assert(RunBody != "", "LLM_Deps_RunInstaller must remain reachable")
	Assert(CancelBody != "", "LLM_Deps_Cancel must remain reachable")
	AssertContains(RunBody, "ShellRunner_SpawnTreeOwned",
		"winget must launch inside an exact process-tree owner")
	AssertContains(RunBody, "_LLM_Deps_InstallerOwner",
		"the exact owner must be published before start")
	Assert(RegExMatch(RunBody,
		"s)ShellRunner_SpawnTreeOwned\(.*?,\s*,\s*,\s*0,\s*false\s*\)") > 0,
		"the long-running installer must discard unused output instead of growing a staging file (AHK-086)")
	Assert(!InStr(RunBody . CancelBody, "_LLM_Deps_InstallerPid"),
		"no long-lived numeric PID owner may survive")
	Assert(!InStr(CancelBody, "taskkill") && !InStr(CancelBody, "ProcessClose("),
		"cancellation must never reopen a recyclable PID")
}

_DIPC_CancelRetainsFailedOwner() {
	Body := _DriverFuncBody("_LLM_Deps_CancelInstallerOwner")
	Assert(Body != "", "the exact installer cancellation helper must exist")
	TerminatePos := InStr(Body, '.terminate()')
	ExpectedPos := InStr(Body, "Owner != ExpectedOwner")
	ReceiptPos := InStr(Body, "if Terminated")
	ClearPos := InStr(Body, "_LLM_Deps_InstallerOwner := 0", true, ReceiptPos)
	RetainPos := InStr(Body, 'Owner["state"] := "running"', true, ReceiptPos)
	Assert(ExpectedPos > 0 && TerminatePos > ExpectedPos && ReceiptPos > TerminatePos,
		"a stale launch failure must not terminate a replacement owner")
	Assert(ReceiptPos > TerminatePos,
		"cancellation must consume the exact task's terminal receipt")
	Assert(ClearPos > ReceiptPos && RetainPos > ReceiptPos,
		"only a true receipt may clear ownership; failure must retain it")
}

_DIPC_StaleTerminalCannotRetireReplacement() {
	Body := _DriverFuncBody("_LLM_Deps_RetireInstallerOwner")
	Assert(Body != "", "the exact installer retirement helper must exist")
	IdentityPos := InStr(Body, "_LLM_Deps_InstallerOwner != ExpectedOwner")
	ClearPos := InStr(Body, "_LLM_Deps_InstallerOwner := 0")
	Assert(IdentityPos > 0 && ClearPos > IdentityPos,
		"an old completion must compare exact owner identity before clearing")
}


Test("Ollama deps: installer launch and cancellation retain an exact tree owner (AHK-082)",
	_DIPC_InstallerUsesExactTreeOwner)

Test("Ollama deps: failed exact termination retains its owner (AHK-082)",
	_DIPC_CancelRetainsFailedOwner)

Test("Ollama deps: stale terminal cannot retire a replacement owner (AHK-082)",
	_DIPC_StaleTerminalCannotRetireReplacement)
