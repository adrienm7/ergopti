; tests/meta/test_updater_self_update_bak_rollback.ahk

; ==============================================================================
; MODULE: Updater Self-Update Bak Rollback Meta Test
; DESCRIPTION:
; Regression guard ensuring the self-update swap script uses a .bak rename
; instead of a hard delete so a failed move can be rolled back.
;
; The bug: the swap batch script did:
;   del /q "%CUR_EXE%"
;   move /y "%NEW_EXE%" "%CUR_EXE%"
; If the move failed (different drive, AV lock, permission error), the current
; exe was already gone and the install was bricked — no exe, no rollback.
;
; The fix: rename the current exe to .bak before moving the new one in. If the
; move fails (new exe absent after move), rename .bak back. Only delete the
; .bak after a confirmed successful move. The relaunch only fires on success.
;
; SCOPE: source introspection of modules/updater.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_USBR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_USBR_CheckNoBareDelete() {
	Src := _USBR_ReadSource("modules/updater.ahk")
	Assert(Src != "", "modules/updater.ahk must be readable")

	; Use the full parameter list to anchor on the definition, not the call site
	Body := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(Body != "", "_Updater_BuildStagingWorkerScript must be present in updater.ahk")

	; Old risky delete-then-move must not be the swap pattern
	Assert(!InStr(Body, 'del /q "%CUR_EXE%"'),
		"swap script must not delete CUR_EXE before moving — use .bak rename for rollback safety")
}

_USBR_CheckBakRenamePresent() {
	Src := _USBR_ReadSource("modules/updater.ahk")
	Assert(Src != "", "modules/updater.ahk must be readable")

	; Use the full parameter list to anchor on the definition, not the call site
	Body := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(Body != "", "_Updater_BuildStagingWorkerScript must be present in updater.ahk")

	; Swap script must rename to .bak before the move
	Assert(InStr(Body, ".bak"),
		"swap script must rename current exe to .bak before moving new exe in")

	; Must have rollback rename when move fails
	Assert(InStr(Body, "BAK_EXE"),
		"swap script must reference BAK_EXE for rollback on failed move")
}

_USBR_CheckBakDeletedOnSuccess() {
	Src := _USBR_ReadSource("modules/updater.ahk")
	Assert(Src != "", "modules/updater.ahk must be readable")

	; Use the full parameter list to anchor on the definition, not the call site
	Body := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(Body != "", "_Updater_BuildStagingWorkerScript must be present in updater.ahk")

	; The .bak must be deleted after a confirmed successful move
	Assert(InStr(Body, "del /q %BAK_EXE%"),
		"swap script must delete the .bak file after a confirmed successful move")
}


Test("meta self-update-bak: swap script does not use bare del on CUR_EXE before move",
	_USBR_CheckNoBareDelete)

Test("meta self-update-bak: swap script renames CUR_EXE to .bak for rollback safety",
	_USBR_CheckBakRenamePresent)

Test("meta self-update-bak: swap script deletes .bak only after confirmed successful move",
	_USBR_CheckBakDeletedOnSuccess)
