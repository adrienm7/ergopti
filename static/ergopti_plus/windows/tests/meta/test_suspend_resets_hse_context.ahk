; tests/meta/test_suspend_resets_hse_context.ahk

; ==============================================================================
; MODULE: Suspend resets the hotstring engine context
; DESCRIPTION:
; Suspend is a focus-destroying, context-unknown boundary just like a mouse
; click, Ctrl+V or Win+L: the on-screen text the hotstring buffer mirrors can
; change completely while the driver is paused (the user clicks into another
; document). Ergopti_OnSuspendEnter tore down every other async producer but
; never wiped HSE_Buffer, so the first terminator after resume could fire a
; stale trigger and BackSpace into unrelated text. This guards that the
; suspend-enter reactor hard-resets the engine buffer, and that the resume
; reactor still resets the prefix (preview) buffer so the two stay paired --
; exactly as RebuildHotstringsLive / _LockWorkstationEmit do. (F07, audit
; 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_SRHC_SuspendHardResetsEngineBuffer() {
	EnterBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	ResumeBody := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(EnterBody != "", "Ergopti_OnSuspendEnter must exist in infra/lifecycle.ahk")
	Assert(ResumeBody != "", "Ergopti_OnSuspendResume must exist in infra/lifecycle.ahk")
	Assert(InStr(EnterBody, "HSE_HardReset") > 0,
		"Ergopti_OnSuspendEnter must hard-reset the hotstring engine buffer (suspend is a context-unknown boundary)")
	Assert(InStr(ResumeBody, "_ResetPrefixBuffer") > 0,
		"Ergopti_OnSuspendResume must reset the prefix/preview buffer so it stays paired with the engine buffer")
}
Test("suspend: hotstring engine buffer is hard-reset so no stale trigger fires after resume",
	_SRHC_SuspendHardResetsEngineBuffer)
