; tests/meta/test_menu_dispatch_error_propagation.ahk

; ==============================================================================
; MODULE: Menu Dispatcher Error Propagation Meta Test
; DESCRIPTION:
; Regression guard to ensure the menu dispatcher bypass propagates errors properly.
;
; In _DispatchIfMissed, the callback invocation was wrapped in a try/catch block
; that suppressed the error. If a natively-dispatched click errored, it triggered
; the global OnError handler and the crash reporter. If the bypass dispatched
; the click, the error was swallowed silently with only a log line.
;
; This test verifies that _DispatchIfMissed uses `throw Err` after logging, or
; doesn't suppress the error entirely, so it propagates to the global OnError handler.
;
; SCOPE: source introspection of infra/menu_dispatcher.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_MDEP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_MDEP_CheckErrorPropagation() {
	Src := _MDEP_ReadSource("infra/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_DispatchIfMissed")
	Assert(Body != "", "_DispatchIfMissed must exist in menu_dispatcher.ahk")

	HasThrow := InStr(Body, "throw Err") > 0
	HasCatch := InStr(Body, "catch") > 0
	Assert(!HasCatch || HasThrow, "_DispatchIfMissed must not silently swallow callback exceptions (must throw)")
}
Test("meta menu-dispatcher: _DispatchIfMissed propagates exceptions", _MDEP_CheckErrorPropagation)
