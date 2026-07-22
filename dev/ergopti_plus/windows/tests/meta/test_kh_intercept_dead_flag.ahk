; tests/meta/test_kh_intercept_dead_flag.ahk

; ==============================================================================
; MODULE: KeyboardHook Intercept Dead-Flag Meta Test
; DESCRIPTION:
; Static source guard for the kh-intercept-dead-flag finding.
;
; The KeyboardHook adapter stores opts["intercept"] in _KH_INTERCEPT but the
; shared visible InputHook cannot suppress events per-subscriber, so the flag
; was inert — a behavioral option that silently did nothing, violating the
; "no silent behavioral fallback" rule (CLAUDE.md 5.4).
;
; The fix keeps "intercept" in the port contract but makes the unsupported
; path loud: KHStart emits a LoggerWarn when intercept=true is requested. This
; test scans keyboard_hook.ahk and asserts the KHStart body warns on the
; intercept branch, so the dead flag can never silently return.
;
; This is a meta-static test (scans source text) because KHStart calls
; KHRefreshContext (WinGetTitle / WinGetProcessName) and HookDispatcher.Register,
; which have OS / shared-hook side effects unsafe for the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_KHIDF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Intercept-warning assertions ==========
; ==================================================
; ==================================================

_KHIDF_KHStartWarnsOnIntercept() {
	Src := _KHIDF_ReadSource("adapters/keyboard_hook.ahk")
	Seg := _DriverFuncBody("KHStart")
	Assert(Seg != "", "KHStart(Opts) declaration must exist in keyboard_hook.ahk")
	Assert(InStr(Seg, "intercept") > 0,
		"KHStart must still read the intercept option — it remains part of the port contract")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"KHStart must emit a LoggerWarn when intercept=true is requested — the shared visible InputHook cannot suppress per-subscriber, so an inert flag must be loud, not silent (CLAUDE.md 5.4)")
}
Test("KeyboardHook: KHStart warns on unsupported intercept=true (kh-intercept-dead-flag)", _KHIDF_KHStartWarnsOnIntercept)
