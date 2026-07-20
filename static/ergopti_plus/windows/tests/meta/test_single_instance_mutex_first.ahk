; tests/meta/test_single_instance_mutex_first.ahk

; ==============================================================================
; MODULE: Single-owner mutex established before hook/message-pump ownership
; DESCRIPTION:
; #SingleInstance Force replaces the previous instance only at the END of the new
; instance's load, and killing a hung/dialog-blocked old instance is best-effort,
; so a rapid double-launch could leave two processes briefly co-owning the keyboard
; hook and the log (field-observed: interleaved duplicate log lines for minutes, a
; boot killed mid-registration with hotkeys armed). The fix acquires a named
; session-local mutex as the first auto-execute statement and waits (bounded) for a
; previous owner to exit before registering anything. This guards that the mutex is
; acquired BEFORE Bundle_Init() (whose RunWait pumps the first message loop) and
; BEFORE HookDispatcher.Start() — exclusivity must precede any message pump or hook
; registration, not the parse-time replacement #SingleInstance Force performs.
; (F02, audit 2026-07-20.) NOTE: the runtime mutex acquisition needs a live
; double-launch test on real hardware; this meta test only pins the source ordering.
; ==============================================================================

#Requires AutoHotkey v2.0

_SIMF_MutexEstablishedBeforeHookAndPump() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	EntryFile := WindowsDir . "\ErgoptiPlus.ahk"
	Src := ""
	try Src := FileRead(EntryFile)
	Assert(Src != "", "ErgoptiPlus.ahk must be readable for the single-instance mutex meta-test")

	; Strip full-line comments so the several comment mentions of Bundle_Init() do
	; not shadow the actual call site when we compare source positions.
	Code := _StripFullLineComments(Src)
	MutexPos := InStr(Code, "CreateMutexW")
	BundlePos := InStr(Code, "Bundle_Init()")
	HookPos := InStr(Code, "HookDispatcher.Start()")

	Assert(MutexPos > 0, "ErgoptiPlus.ahk must acquire a named single-owner mutex (CreateMutexW) at boot")
	Assert(BundlePos > 0, "ErgoptiPlus.ahk must call Bundle_Init()")
	Assert(HookPos > 0, "ErgoptiPlus.ahk must start the hook dispatcher (HookDispatcher.Start())")
	Assert(MutexPos < BundlePos,
		"the single-owner mutex must be acquired BEFORE Bundle_Init() (its RunWait pumps the first message loop), so exclusivity precedes the first message pump")
	Assert(MutexPos < HookPos,
		"the single-owner mutex must be acquired BEFORE HookDispatcher.Start(), so two instances never co-own the keyboard hook")
}
Test("boot: single-owner mutex is acquired before the message pump and hook registration",
	_SIMF_MutexEstablishedBeforeHookAndPump)
