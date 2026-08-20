; tests/meta/test_savefullconfig_no_delete.ahk

; ==============================================================================
; MODULE: SaveFullConfig No-FileDelete Guard Meta Test
; DESCRIPTION:
; Static source guards for two audit findings in ErgoptiPlus.ahk.
;
; ROOT CAUSES ENCODED:
;
; 1. DATA-LOSS WINDOW IN SaveFullConfig (savefullconfig-filedelete-data-loss):
;    The original SaveFullConfig called FileDelete(ConfigurationFile) before
;    TOML_BatchWrite. TOML_BatchWrite already performs an atomic
;    write-to-temp + FileMove(tmp, dest, overwrite=true) — the pre-delete was
;    redundant AND dangerous: a crash between FileDelete and FileMove leaves the
;    user with zero config files. The companion test test_toml_batchwrite_atomic
;    guards the TOML_BatchWrite internals; this test guards the call-site in
;    SaveFullConfig.
;
; 2. _DriverReady PERMANENT LOCKOUT (buildtraymenu-driverready-lost-on-error):
;    BuildTrayMenuDeferred saved _DriverReady into _SavedReady and cleared it
;    before calling initMenu() — but it only restored it on the SUCCESS path.
;    An exception from initMenu() (e.g. a malformed personal-hotstring TOML)
;    left _DriverReady permanently false, making SaveFullConfig a no-op for the
;    remainder of the session. The fix wraps initMenu() in try/finally so
;    _DriverReady is restored unconditionally regardless of exceptions.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ SaveFullConfig has no FileDelete ========
; ===================================================
; ===================================================

_SFND_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_SFND_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_SFND_SaveFullConfigNoDelete() {
	Raw := _DriverSourceConcat()
	Src := _SFND_StripComments(Raw)
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist in ErgoptiPlus.ahk")

	Assert(InStr(Body, "FileDelete(") = 0,
		"SaveFullConfig must not call FileDelete before TOML_BatchWrite — TOML_BatchWrite already uses atomic FileMove(overwrite=true); pre-deleting creates a data-loss window on crash (savefullconfig-filedelete-data-loss)")

	; Confirm TOML_BatchWrite is still called (the write must still happen)
	Assert(InStr(Body, "TOML_BatchWrite") > 0,
		"SaveFullConfig must still call TOML_BatchWrite to persist the configuration")
}
Test("ErgoptiPlus: SaveFullConfig has no FileDelete before TOML_BatchWrite (savefullconfig-filedelete-data-loss)", _SFND_SaveFullConfigNoDelete)




; ====================================================
; ====================================================
; ======= 2/ BuildTrayMenuDeferred try/finally ========
; ====================================================
; ====================================================

_SFND_BuildTrayMenuDeferredTryFinally() {
	Src := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(Src != "",
		"the deferred boot tray request must carry its _DriverReady scope in its root worker")

	; _DriverReady must be restored via a finally block, not conditionally
	Assert(InStr(Src, "_DriverReady := _SavedReady") > 0,
		"BuildTrayMenuDeferred must restore _DriverReady from _SavedReady (buildtraymenu-driverready-lost-on-error)")

	Assert(InStr(Src, "finally {") > 0 or InStr(Src, "finally{") > 0,
		"BuildTrayMenuDeferred must use try/finally so _DriverReady is restored even on initMenu() exceptions (buildtraymenu-driverready-lost-on-error)")

	; The restoration must come after a finally keyword, not only on the success path
	PosFin    := InStr(Src, "finally {")
	PosFinAlt := InStr(Src, "finally{")
	ActualFin := (PosFin > 0) ? PosFin : PosFinAlt
	PosRestore := InStr(Src, "_DriverReady := _SavedReady")
	Assert(ActualFin > 0 and PosRestore > ActualFin,
		"_DriverReady := _SavedReady must appear AFTER the finally keyword, not only on the success path (buildtraymenu-driverready-lost-on-error)")
	BootRequest := _DriverFuncBody("BuildTrayMenuDeferred")
	Assert(BootRequest != "" and InStr(BootRequest,
		"RebuildTrayMenu(0, _TrayRootBuildBoot, false)") > 0,
		"the deferred boot root must use the same generation owner as every live tray rebuild")
	Assert(InStr(BootRequest, "initMenu(") = 0,
		"the boot timer must not bypass the shared tray-root generation owner")
	Worker := _DriverFuncBody("_TrayRootBuildBoot")
	PublishPos := InStr(Worker, "Published := initMenu(PublishAuthorizeFn)")
	MarkPos := InStr(Worker, 'BootProfile_Mark("Tray menu built', false,
		PublishPos)
	Assert(PublishPos > 0 and MarkPos > PublishPos
		and InStr(BootRequest, 'BootProfile_Mark("Tray menu built') = 0,
		"the boot profiler may report the root only after its actual terminal publication")
}
Test("ErgoptiPlus: BuildTrayMenuDeferred restores _DriverReady in finally block (buildtraymenu-driverready-lost-on-error)", _SFND_BuildTrayMenuDeferredTryFinally)





; ====================================================
; ====================================================
; ======= 3/ Save has one non-reentrant writer =======
; ====================================================
; ====================================================

_SFND_SaveFullConfigOwnsOneCausalBatchWrite() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist in the driver source")
	Assert(InStr(Body, "PrevCanonState") = 0
		and InStr(Body, "_TOML_STRICT_CANON_IN_PROGRESS") = 0,
		"SaveFullConfig must not carry the obsolete guard for a nested full save that the batch writer no longer performs")
	WriteNeedle := "TOML_BatchWrite(BoundPath, Updates,"
	WritePos := InStr(Body, WriteNeedle)
	Assert(WritePos > 0,
		"SaveFullConfig must write through the path selected by its exact lease owner")
	StrictPos := InStr(Body, "Written is Integer", true, WritePos)
	ResultPos := InStr(Body, "Result := CONFIG_SAVE_OK", true, StrictPos)
	AckPos := InStr(Body, "_ConfigFullSaveAcknowledge(TargetGeneration)")
	ReturnPos := InStr(Body, "return Result", true, AckPos)
	StrReplace(Body, WriteNeedle, "", true, &WriteCount)
	Assert(WriteCount = 1,
		"SaveFullConfig must own exactly one atomic batch write")
	Assert(StrictPos > WritePos and ResultPos > StrictPos
		and AckPos > ResultPos and ReturnPos > AckPos,
		"SaveFullConfig must acknowledge a generation only after durable success and return its named status")
}
Test("ErgoptiPlus: SaveFullConfig owns one non-reentrant batch write",
	_SFND_SaveFullConfigOwnsOneCausalBatchWrite)
