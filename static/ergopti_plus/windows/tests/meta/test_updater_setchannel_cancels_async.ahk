; tests/meta/test_updater_setchannel_cancels_async.ahk

; ==============================================================================
; MODULE: Updater_SetChannel Async-Cancel Meta Test
; DESCRIPTION:
; Static source guard for the "async-requests-not-cancelled-on-channel-reload"
; finding.
;
; Updater_SetChannel persists the new channel then calls Reload to restart the
; script. Reload is NOT instantaneous: the old instance may still hold an
; in-flight WinHTTP request and a queued poll timer that could fire a callback
; against a half-torn-down state during the transition. The explicit cleanup
; path Updater_StopBackgroundChecks() (which calls _Updater_CancelAsyncChecks
; and stops the background/focus timers) already exists precisely for this, and
; Updater_SetCheckInterval already uses it on its in-process restart path.
;
; The fix calls Updater_StopBackgroundChecks() in Updater_SetChannel BEFORE
; Reload. This is a meta-static test (scans source text) because calling
; Updater_SetChannel would execute Reload and restart the headless runner.
; If the explicit cancel is removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_USCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body — from its declaration to the first closing
; brace at column 0 (AHK functions close with `}` flush-left). Returns "" when
; the declaration is absent.
_USCA_FuncBody(Src, FuncDef) {
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
; ======= 2/ Cancel-before-Reload assertion ========
; ==================================================
; ==================================================

_USCA_SetChannelCancelsAsyncBeforeReload() {
	Src := _USCA_ReadSource("lib/updater.ahk")
	Seg := _DriverFuncBody("Updater_SetChannel")
	Assert(Seg != "", "Updater_SetChannel(Channel) declaration must exist in lib/updater.ahk")

	StopIdx := InStr(Seg, "Updater_StopBackgroundChecks()")
	Assert(StopIdx > 0,
		"Updater_SetChannel must call Updater_StopBackgroundChecks() so in-flight async checks and poll timers are cancelled deterministically before Reload (async-requests-not-cancelled-on-channel-reload)")

	ReloadIdx := InStr(Seg, "Reload")
	Assert(ReloadIdx > 0, "Updater_SetChannel must still Reload after the cancel")
	Assert(StopIdx < ReloadIdx,
		"Updater_StopBackgroundChecks() must run BEFORE Reload — cancelling after the restart begins would be too late (async-requests-not-cancelled-on-channel-reload)")
}
Test("updater: Updater_SetChannel cancels async checks before Reload (async-requests-not-cancelled-on-channel-reload)", _USCA_SetChannelCancelsAsyncBeforeReload)
