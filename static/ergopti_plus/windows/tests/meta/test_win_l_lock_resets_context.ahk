; tests/meta/test_win_l_lock_resets_context.ahk

; ==============================================================================
; MODULE: Win+L Lock Context-Reset Meta Test
; DESCRIPTION:
; Static source guard for finding "win-l-lock-no-watcher-reset".
;
; Locking the workstation is a focus-destroying, context-unknown event (like a
; mouse click or Ctrl+V) that should reset the hotstring feed and prefix buffer.
; The original Win+L handler instead recorded a phantom 'l' into the last-sent
; ring and left HSE_Buffer / the prefix buffer intact, so after unlock the
; engine still believed the pre-lock word context abutted the cursor and could
; mis-/non-fire the first word typed afterwards.
;
; The fix routes Win+L through _LockWorkstationEmit, which calls HSE_FeedReset
; and _ResetPrefixBuffer and intentionally drops the UpdateLastSentCharacter('l')
; push (no 'l' was emitted). This is a meta-static test because layout.ahk
; registers top-level hotkeys and cannot be #Included by the headless runner;
; it scans source text so a regression fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_WLLR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Context-reset assertions ==============
; ==================================================
; ==================================================

_WLLR_AssertLockResetsContext() {
	Src := _WLLR_ReadSource("modules/keymap/layout.ahk")
	Body := _DriverFuncBody("_LockWorkstationEmit")
	Assert(Body != "", "_LockWorkstationEmit helper must exist in layout.ahk (win-l-lock-no-watcher-reset)")
	Assert(InStr(Body, "HSE_FeedReset") > 0,
		"_LockWorkstationEmit must call HSE_FeedReset - a lock is a context-unknown boundary (win-l-lock-no-watcher-reset)")
	Assert(InStr(Body, "_ResetPrefixBuffer") > 0,
		"_LockWorkstationEmit must call _ResetPrefixBuffer so stale word context does not survive the lock/unlock boundary (win-l-lock-no-watcher-reset)")
}
Test("layout: Win+L lock resets HSE feed and prefix buffer (win-l-lock-no-watcher-reset)", _WLLR_AssertLockResetsContext)

_WLLR_AssertNoPhantomLPush() {
	Src := _WLLR_ReadSource("modules/keymap/layout.ahk")
	Body := _DriverFuncBody("_LockWorkstationEmit")
	Assert(!InStr(Body, "UpdateLastSentCharacter"),
		"_LockWorkstationEmit must NOT push a phantom 'l' into the last-sent ring - no character is emitted by the OS lock (win-l-lock-no-watcher-reset)")
}
Test("layout: Win+L lock does not record a phantom last-sent char (win-l-lock-no-watcher-reset)", _WLLR_AssertNoPhantomLPush)
