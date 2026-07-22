; tests/meta/test_deps_installer_pid_captured.ahk

; ==============================================================================
; MODULE: Ollama Deps Installer PID Capture Meta Test
; DESCRIPTION:
; Regression guard ensuring LLM_Deps_RunInstaller captures the winget PID into
; _LLM_Deps_InstallerPid so LLM_Deps_Cancel can terminate a running install.
;
; The bug: the Run() call for the installer omitted the &pid out-parameter and
; never wrote _LLM_Deps_InstallerPid. _LLM_Deps_InstallerPid was declared and
; read by LLM_Deps_Cancel but always held 0 (falsy), so the taskkill block in
; Cancel was dead code. A user clicking Cancel would stop the 3s polling timer
; but leave winget downloading Ollama in the background indefinitely.
;
; The fix: launch winget directly (without cmd /c start so it does not detach)
; and capture the real PID via Run's &pid out-parameter.  taskkill /F /T then
; reaches the entire winget process tree from a Cancel.
;
; SCOPE: source introspection of modules/llm/ollama_deps_checker.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_DIPC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_DIPC_CheckPidAssignedInRunInstaller() {
	Src := _DIPC_ReadSource("modules/llm/ollama_deps_checker.ahk")
	Assert(Src != "", "modules/llm/ollama_deps_checker.ahk must be readable")

	Body := _DriverFuncBody("LLM_Deps_RunInstaller")
	Assert(Body != "", "LLM_Deps_RunInstaller must be present in ollama_deps_checker.ahk")

	; The PID must be assigned inside RunInstaller, not only inside Cancel
	Assert(InStr(Body, "_LLM_Deps_InstallerPid"),
		"LLM_Deps_RunInstaller must assign _LLM_Deps_InstallerPid (captured from Run &pid)")
}

_DIPC_CheckRunUsesAmpersandPid() {
	Src := _DIPC_ReadSource("modules/llm/ollama_deps_checker.ahk")
	Assert(Src != "", "modules/llm/ollama_deps_checker.ahk must be readable")

	Body := _DriverFuncBody("LLM_Deps_RunInstaller")
	Assert(Body != "", "LLM_Deps_RunInstaller must be present in ollama_deps_checker.ahk")

	; The Run call must pass &_LLM_Deps_InstallerPid as the 4th argument
	Assert(InStr(Body, "&_LLM_Deps_InstallerPid"),
		"Run() inside LLM_Deps_RunInstaller must capture the PID via &_LLM_Deps_InstallerPid")
}

_DIPC_CheckCancelCanKillPid() {
	Src := _DIPC_ReadSource("modules/llm/ollama_deps_checker.ahk")
	Assert(Src != "", "modules/llm/ollama_deps_checker.ahk must be readable")

	Body := _DriverFuncBody("LLM_Deps_Cancel")
	Assert(Body != "", "LLM_Deps_Cancel must be present in ollama_deps_checker.ahk")

	; Cancel must still have the taskkill block to use the captured PID
	Assert(InStr(Body, "taskkill") && InStr(Body, "_LLM_Deps_InstallerPid"),
		"LLM_Deps_Cancel must use _LLM_Deps_InstallerPid with taskkill to terminate the install")
}


Test("meta deps-installer-pid: LLM_Deps_RunInstaller assigns _LLM_Deps_InstallerPid from Run()",
	_DIPC_CheckPidAssignedInRunInstaller)

Test("meta deps-installer-pid: Run() inside LLM_Deps_RunInstaller uses &_LLM_Deps_InstallerPid",
	_DIPC_CheckRunUsesAmpersandPid)

Test("meta deps-installer-pid: LLM_Deps_Cancel can kill the process via _LLM_Deps_InstallerPid",
	_DIPC_CheckCancelCanKillPid)
