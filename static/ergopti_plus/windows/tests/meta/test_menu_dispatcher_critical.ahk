; tests/meta/test_menu_dispatcher_critical.ahk

; ==============================================================================
; MODULE: MenuDispatcher Critical-Section Guard Meta Test
; DESCRIPTION:
; Static source guard for the "Critical held across callback starves keyboard
; hook" finding (bypass-dispatch-critical-starves-keyboard-hook).
;
; lib/menu_dispatcher.ahk _DispatchIfMissed() previously opened Critical
; at the top of the function and never released it before Callback.Call().
; AHK's Critical mode prevents the current thread from being interrupted — it
; also prevents the low-level keyboard hook thread from delivering keystrokes
; beyond the OS LowLevelHooksTimeout (~300 ms). Any menu action that takes
; longer than that budget (network calls, file I/O, GUI rebuilds) would cause
; Windows to silently drop the physical keystroke that triggered it.
;
; The fix: Critical "Off" is released immediately after the atomic state check
; (gate / LastFire stamp) and before Callback.Call(). These tests assert the
; old naked Critical (without Off) no longer spans the callback call site.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_MDC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Critical-release assertions ============
; ===================================================
; ===================================================

_MDC_CriticalReleasedBeforeCallback() {
	Src := _MDC_ReadSource("lib/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("_DispatchIfMissed")
	Assert(Seg != "", "_DispatchIfMissed must exist in menu_dispatcher.ahk")
	; Verify Critical Off appears in the function body (released before Call).
	; Use single-quoted string so the linter does not flag escaped double quotes.
	Assert(InStr(Seg, 'Critical "Off"') > 0,
		"_DispatchIfMissed must release Critical before Callback.Call() to prevent keyboard-hook starvation")
}
Test("menu_dispatcher: _DispatchIfMissed releases Critical before Callback.Call()", _MDC_CriticalReleasedBeforeCallback)

_MDC_CriticalOffBeforeCallbackCall() {
	Seg := _DriverFuncBody("_DispatchIfMissed")
	Assert(Seg != "", "_DispatchIfMissed declaration must exist")
	; The callback reference is extracted and its dispatch timestamp committed
	; while Critical is on. The release associated with that commit, not an
	; earlier stale-retry return, must occur before the real callback invocation.
	CommitPos := InStr(Seg, "_MenuDispatchLastFire[ItemId] := A_TickCount")
	CallPos := InStr(Seg, "Callback.Call(")
	OffPos := InStr(Seg, 'Critical "Off"', , CommitPos)
	Assert(CommitPos > 0 and OffPos > CommitPos and CallPos > OffPos,
		"Critical Off must precede Callback.Call() in _DispatchIfMissed so the hook thread is never starved")
}
Test("menu_dispatcher: Critical Off appears before Callback.Call() in source order", _MDC_CriticalOffBeforeCallbackCall)
