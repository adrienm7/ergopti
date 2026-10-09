; static/ergopti_plus/windows/tests/unit/test_wrap_symbols_unreadable_blocks_save.ahk

; ==============================================================================
; MODULE: Regression — an unreadable wrap_symbols.toml must not be overwritten
;         with an empty one (wrap-symbols-unreadable-blocks-save)
; DESCRIPTION:
; Boot with wrap_symbols.toml briefly held by a sync client, an AV scan or a
; backup job. The `loop read` throws a sharing violation, the catch logs and
; returns, and _WS_Disabled / _WS_Custom stay EMPTY. Then the user toggles any
; wrap symbol from the menu: _WS_Save serializes those empty maps over the real
; file. Every disabled built-in is silently re-enabled and every custom pair is
; permanently gone.
;
; ROOT CAUSE ENCODED: empty is exactly what "the user has disabled nothing and
; defined no custom pair" looks like, so the failed read produced a state that
; is indistinguishable from a legitimate one — and the writer had no way to ask.
; Same class as the config.toml boot read, and the same cure: the distinction
; has to be latched at READ time, because by save time the lock has usually
; cleared and the write looks perfectly safe.
;
; The latch is deliberately never cleared. Nothing re-reads the file in-process,
; so the maps stay untrustworthy for the rest of the session; a self-healing
; flag would just restore the data loss on the next successful unrelated read.
;
; SCOPE: behavioural, provoked with a real exclusive file lock — the same
; mechanism the field failure used.
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny every sharing mode, producing OS error 32 for a concurrent reader.
global _WSU_EXCLUSIVE_LOCK_FLAGS := "r-rwd"




; ==================================================================
; ==================================================================
; ======= 1/ An unreadable file latches, a missing one does not ====
; ==================================================================
; ==================================================================

; Read and write the latch defensively. Without this, a build in which the latch
; does not exist at all fails every assertion below with "global has not been
; assigned a value" instead of naming the data loss — and a regression test whose
; message does not describe the bug is one nobody can act on.
_WSU_Latch() {
	global _WS_LoadFailed
	return IsSet(_WS_LoadFailed) ? _WS_LoadFailed : false
}

_WSU_SetLatch(Value) {
	global _WS_LoadFailed
	_WS_LoadFailed := Value
}


; Run _WS_Load against a path and report the resulting state, restoring every
; global it borrows.
_WSU_LoadFrom(Path, Locked) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom
	PrevPath := _WS_Config_Path
	PrevDis  := _WS_Disabled
	PrevCus  := _WS_Custom
	PrevFail := _WSU_Latch()

	_WS_Config_Path := Path
	_WS_Disabled    := Map()
	_WS_Custom      := []
	_WSU_SetLatch(false)

	Lock := ""
	if Locked
		Lock := FileOpen(Path, _WSU_EXCLUSIVE_LOCK_FLAGS)
	_WS_Load()
	Failed   := _WSU_Latch()
	Disabled := _WS_Disabled.Count
	if IsObject(Lock)
		Lock.Close()

	_WS_Config_Path := PrevPath
	_WS_Disabled    := PrevDis
	_WS_Custom      := PrevCus
	_WSU_SetLatch(PrevFail)
	return { Failed: Failed, Disabled: Disabled, Locked: IsObject(Lock) }
}

_WSU_UnreadableFileLatches() {
	Path := A_Temp . "\ergopti_test_ws_locked_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend('[[disabled]]`nchar = "("`n', Path, "UTF-8")

	R := _WSU_LoadFrom(Path, true)
	try FileDelete(Path)

	Assert(R.Locked, "the test could not take an exclusive lock — it would otherwise assert nothing")
	Assert(R.Failed,
		"a wrap_symbols.toml that exists but cannot be read must latch the failure. Without it the empty maps left behind are indistinguishable from a user who disabled nothing, and the next toggle persists that emptiness over the real file")
	Assert(R.Disabled == 0, "nothing can be loaded from a file that could not be read")
}

; A fresh install has no file at all, and must still be able to save.
_WSU_MissingFileDoesNotLatch() {
	Path := A_Temp . "\ergopti_test_ws_absent_" . A_TickCount . ".toml"
	try FileDelete(Path)
	R := _WSU_LoadFrom(Path, false)
	Assert(!R.Failed,
		"a MISSING file is not a failure — latching it would block the very first save on a fresh install, which is the common case")
}

; And a readable file must still load, or the guard would be a regression.
_WSU_ReadableFileStillLoads() {
	Path := A_Temp . "\ergopti_test_ws_ok_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend('[[disabled]]`nchar = "("`n', Path, "UTF-8")
	R := _WSU_LoadFrom(Path, false)
	try FileDelete(Path)
	Assert(!R.Failed, "a readable file must not latch")
	Assert(R.Disabled == 1, "a readable file must still populate the disabled set")
}




; ==================================================================
; ==================================================================
; ======= 2/ The save refuses while the latch is raised ============
; ==================================================================
; ==================================================================

; The destructive half. The file is readable again by now — that is the whole
; point — so only the latch can stop the write.
_WSU_SaveRefusesWhileLatched() {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom
	Path := A_Temp . "\ergopti_test_ws_save_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend('[[disabled]]`nchar = "("`n', Path, "UTF-8")
	Before := FileRead(Path, "UTF-8")

	PrevPath := _WS_Config_Path
	PrevDis  := _WS_Disabled
	PrevCus  := _WS_Custom
	PrevFail := _WSU_Latch()

	; Exactly the post-failure state: empty maps, latch raised.
	_WS_Config_Path := Path
	_WS_Disabled    := Map()
	_WS_Custom      := []
	_WSU_SetLatch(true)
	_WS_Save()
	AfterBlocked := FileRead(Path, "UTF-8")

	; Control: with the latch clear, the same call MUST rewrite the file. Without
	; this the assertion above would also pass if _WS_Save were broken outright.
	_WSU_SetLatch(false)
	_WS_Save()
	AfterAllowed := FileRead(Path, "UTF-8")

	_WS_Config_Path := PrevPath
	_WS_Disabled    := PrevDis
	_WS_Custom      := PrevCus
	_WSU_SetLatch(PrevFail)
	try FileDelete(Path)

	Assert(AfterBlocked == Before,
		"_WS_Save must not rewrite wrap_symbols.toml while the load-failed latch is set — what it would write is the empty state the failed read left behind, and that erases every disabled built-in and every custom pair")
	Assert(AfterAllowed != Before,
		"control: with the latch clear the same call must actually rewrite the file. If it does not, the assertion above proves nothing about the latch")
	Assert(InStr(AfterAllowed, "disabled") == 0,
		"control: the rewrite really did serialize the empty state — which is exactly the data loss the latch exists to prevent")
}


Test("wrap-symbols-unreadable-blocks-save: an unreadable file latches the failure",
	_WSU_UnreadableFileLatches)
Test("wrap-symbols-unreadable-blocks-save: a missing file does not latch",
	_WSU_MissingFileDoesNotLatch)
Test("wrap-symbols-unreadable-blocks-save: a readable file still loads",
	_WSU_ReadableFileStillLoads)
Test("wrap-symbols-unreadable-blocks-save: the save refuses while latched",
	_WSU_SaveRefusesWhileLatched)
