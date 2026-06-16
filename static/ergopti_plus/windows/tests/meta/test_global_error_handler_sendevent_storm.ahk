; tests/meta/test_global_error_handler_sendevent_storm.ahk

; ==============================================================================
; MODULE: Global Error-Handler SendEvent-Storm Guard Meta Test
; DESCRIPTION:
; Static source guard for the "global-error-handler-sendevent-storm" finding.
;
; The global error handler used to (a) force-release all 8 modifiers whenever
; they were PHYSICALLY down — yanking a Shift the user was legitimately holding
; mid-chord and desyncing the modifier state — and (b) surface the error through a
; blocking MsgBox that starves the keyboard hook (keys pressed while the dialog is
; up are dropped or queued).
;
; The fix: the release decision is factored into _ShouldReleaseModifier(ModKey),
; which releases ONLY modifiers that are logically down but NOT physically held
; (genuinely stuck), and the user-facing surface routes through the non-blocking
; NotifierSend tray notification instead of MsgBox. This test encodes both halves:
; the handler must call _ShouldReleaseModifier (no bare GetKeyState(...,"P")
; release loop), and it must NOT surface the error via MsgBox. Meta-static because
; ErgoptiPlus.ahk registers every hotkey at load and cannot be #Included headless.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_GEHSS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_GEHSS_FuncBody(Src, FuncDef) {
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
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_GEHSS_HandlerUsesReleaseGuard() {
	Src := _GEHSS_ReadSource("ErgoptiPlus.ahk")
	Seg := _GEHSS_FuncBody(Src, "ErgoptiGlobalErrorHandler(Exc, Mode) {")
	Assert(Seg != "", "ErgoptiGlobalErrorHandler(Exc, Mode) must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "_ShouldReleaseModifier(") > 0,
		"ErgoptiGlobalErrorHandler must route the modifier-release decision through _ShouldReleaseModifier — releasing a modifier the user is physically holding desyncs the modifier state and breaks capitalisation")
}
Test("ErgoptiPlus: error handler gates modifier release via _ShouldReleaseModifier (global-error-handler-sendevent-storm)", _GEHSS_HandlerUsesReleaseGuard)

_GEHSS_ReleaseGuardChecksPhysicalState() {
	Src := _GEHSS_ReadSource("ErgoptiPlus.ahk")
	Seg := _GEHSS_FuncBody(Src, "_ShouldReleaseModifier(ModKey) {")
	Assert(Seg != "", "_ShouldReleaseModifier(ModKey) must exist in ErgoptiPlus.ahk")
	; Q is the ASCII double-quote (the linter bans the backtick-quote escape).
	Q := Chr(34)
	Assert(InStr(Seg, "!GetKeyState(ModKey, " . Q . "P" . Q . ")") > 0,
		"_ShouldReleaseModifier must NOT release a modifier the user is physically holding (must require !GetKeyState(ModKey, P))")
}
Test("ErgoptiPlus: _ShouldReleaseModifier spares physically-held keys (global-error-handler-sendevent-storm)", _GEHSS_ReleaseGuardChecksPhysicalState)

_GEHSS_HandlerSurfaceIsNonBlocking() {
	Src := _GEHSS_ReadSource("ErgoptiPlus.ahk")
	Seg := _GEHSS_FuncBody(Src, "ErgoptiGlobalErrorHandler(Exc, Mode) {")
	Assert(InStr(Seg, "NotifierSend(") > 0,
		"ErgoptiGlobalErrorHandler must surface the error via the non-blocking NotifierSend tray notification")
	Assert(InStr(Seg, "MsgBox(") = 0,
		"ErgoptiGlobalErrorHandler must NOT use a blocking MsgBox — a modal dialog on the input thread starves the keyboard hook and drops the next keystrokes")
}
Test("ErgoptiPlus: error handler surfaces via NotifierSend not MsgBox (global-error-handler-sendevent-storm)", _GEHSS_HandlerSurfaceIsNonBlocking)
