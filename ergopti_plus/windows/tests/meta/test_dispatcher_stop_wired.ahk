; tests/meta/test_dispatcher_stop_wired.ahk

; ==============================================================================
; MODULE: HookDispatcher Stop-Wiring Meta Test
; DESCRIPTION:
; Static source guard for the finding dispatcher-stop-not-wired-and-leaks.
;
; The module docstring of infra/hook_dispatcher.ahk claimed Stop() was "Called by
; the script's OnExit handler", but no such handler was ever wired. On a plain
; ExitApp (non-Reload, e.g. the tray Quit item) the InputHook was only reclaimed
; by the OS, never explicitly Stopped. Additionally Stop() never cleared the
; subscriber registry, so a Stop()/Start() cycle inherited the previous (and,
; given the historical Unregister bug, un-removable) subscribers and double-fired
; every event.
;
; The fix (a) registers OnExit((*) => HookDispatcher.Stop()) in ErgoptiPlus.ahk
; right after HookDispatcher.Start(), and (b) makes Stop() reset
; _subscribers := Map(). This is a meta-static test because Start()/Stop() create
; a real InputHook and register real OS Hotkeys, which is unsafe in the headless
; runner; the source-text assertions cannot have those side effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_DSW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the function body from its declaration to the first flush-left closing
; brace. Returns "" when the declaration is absent.
_DSW_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ OnExit wiring assertion ===============
; ==================================================
; ==================================================

_DSW_OnExitWiresStop() {
	Src := _DriverSourceConcat()
	; The startup section must register Stop() as the process OnExit handler so a
	; plain ExitApp releases the InputHook explicitly, not just via OS teardown.
	Assert(InStr(Src, "OnExit") > 0 && InStr(Src, "HookDispatcher.Stop") > 0,
		"ErgoptiPlus.ahk must register an OnExit handler referencing HookDispatcher.Stop - the docstring promises Stop() runs on exit; without the wiring the InputHook leaks across a non-Reload exit")
}
Test("ErgoptiPlus: OnExit wires HookDispatcher.Stop (dispatcher-stop-not-wired-and-leaks)", _DSW_OnExitWiresStop)

_DSW_StopClearsSubscribers() {
	Src := _DSW_ReadSource("infra/hook_dispatcher.ahk")
	Seg := _DSW_FuncBody(Src, "static Stop() {")
	Assert(Seg != "", "HookDispatcher.Stop() must exist in hook_dispatcher.ahk")
	Assert(InStr(Seg, "_subscribers := Map()") > 0,
		"HookDispatcher.Stop() must reset _subscribers := Map() - otherwise a Stop()/Start() cycle inherits stale subscribers and double-fires every event")
}
Test("HookDispatcher: Stop() clears the subscriber registry (dispatcher-stop-not-wired-and-leaks)", _DSW_StopClearsSubscribers)
