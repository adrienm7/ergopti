; tests/meta/modules/llm/servers/test_deps_installer_pid_captured.ahk

; ==============================================================================
; MODULE: Ollama Installer Single Owner
; DESCRIPTION:
; Ergopti installs and runs only its own pinned Ollama (decision DELETE of
; _shared/core/network/data/owned_runtimes.json): the user-level winget and browser fallback
; is gone. Shutdown still joins the managed installer before it turns terminal,
; and the real checker stays enrolled.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_DIPC_NoUserLevelInstaller() {
	Source := _DriverSourceNoComments()
	Assert(Source != "", "the driver source must be readable")
	for Name in ["LLM_Deps_RunInstaller", "_LLM_Deps_CancelInstallerOwner", "LLM_Deps_PollServerReady"]
		AssertEqual("", _DriverFuncBodyOrEmpty(Name), Name . " must stay deleted")
	AssertFalse(RegExMatch(Source, "\bwinget(\.exe)?\b"), "no production path may reach winget")
	AssertFalse(InStr(Source, "Ollama.Ollama"), "no production path may name the winget package")
	Body := _DriverFuncBody("LLM_Deps_Cancel")
	AssertContains(Body, "LLM_ManagedBootstrapCancel()", "cancel goes through the managed owner")
}

_DIPC_ShutdownRequiresManagedQuiescence() {
	PrepareBody := _DriverFuncBody("LLM_Deps_PrepareShutdown")
	Assert(PrepareBody != "", "the installer shutdown preflight must exist")
	Assert(InStr(PrepareBody, "return LLM_ManagedBootstrapCancel()", true) > 0,
		"shutdown must return the managed owner's termination receipt")

	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "", "Ergopti_OnShutdown must remain source-visible")
	PreparePos := InStr(ShutdownBody, "LLM_Deps_PrepareShutdown()", true)
	TerminalPos := InStr(ShutdownBody, "ShutdownTerminal := true", true)
	FailurePos := InStr(ShutdownBody, "if !InstallerStopped", true, PreparePos)
	RefusalPos := InStr(ShutdownBody, _SHUTDOWN_REFUSAL_MARKER, true, FailurePos)
	Assert(PreparePos > 0 && FailurePos > PreparePos
		&& RefusalPos > FailurePos && TerminalPos > RefusalPos,
		"an unconfirmed installer must refuse exit before terminal teardown")
}

; Canonical enrollment: the real getter, not a permissive stub.
_DIPC_CanonicalCheckerEnrollment() {
	global _LLM_Deps_State
	Runner := FileRead(A_ScriptDir . "\run_all.ahk", "UTF-8")
	ActiveRunner := _DriverMaskNonCode(&Runner)
	Assert(RegExMatch(ActiveRunner, "m)^#Include \.\./modules/llm/ollama_deps_checker\.ahk$") > 0,
		"The canonical runner must include the production dependency checker.")
	Stubs := FileRead(A_ScriptDir . "\test_stubs.ahk", "UTF-8")
	Assert(!_DriverFindFunctionDefinition(&Stubs, "LLM_Deps_IsReady"),
		"A permissive dependency readiness stub cannot replace the production subject.")
	Saved := _LLM_Deps_State
	try {
		_LLM_Deps_State := "ready"
		AssertTrue(LLM_Deps_IsReady(), "The real state getter accepts the ready state.")
		_LLM_Deps_State := "pending"
		AssertFalse(LLM_Deps_IsReady(), "The real state getter refuses a pending state.")
	} finally _LLM_Deps_State := Saved
}


Test("Ollama deps: only the managed owner installs, winget stays deleted (owned-runtimes-winget)",
	_DIPC_NoUserLevelInstaller)

Test("Ollama deps: shutdown joins the managed installer (AHK-092)",
	_DIPC_ShutdownRequiresManagedQuiescence)

Test("Ollama deps: canonical checker is enrolled without a permissive subject stub (installer-debt-enrollment)",
	_DIPC_CanonicalCheckerEnrollment)
