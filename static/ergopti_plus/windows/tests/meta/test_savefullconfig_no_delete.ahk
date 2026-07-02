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
	Raw := _DriverSourceConcat()
	Src := _SFND_StripComments(Raw)

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
}
Test("ErgoptiPlus: BuildTrayMenuDeferred restores _DriverReady in finally block (buildtraymenu-driverready-lost-on-error)", _SFND_BuildTrayMenuDeferredTryFinally)




; ====================================================
; ====================================================
; ======= 3/ PrevCanonState is function-local ========
; ====================================================
; ====================================================

_SFND_PrevCanonStateIsLocal() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig() must exist in the driver source")

	Assert(RegExMatch(Body, "global\s+([^\r\n]+)", &m) > 0,
		"SaveFullConfig must declare its global dependencies")
	GlobalLine := m[1]

	Assert(!InStr(GlobalLine, "PrevCanonState"),
		"SaveFullConfig must NOT declare PrevCanonState as global -- a shared global "
		. "canonicalization-guard snapshot lets a re-entrant call (e.g. the boot retry "
		. "timer landing mid-execution of another SaveFullConfig caller) clobber the "
		. "outer call's captured value, permanently wedging _TOML_STRICT_CANON_IN_PROGRESS "
		. "to true and silently disabling future TOML re-normalization (savefullconfig-prevcanonstate-shared-global)")

	Assert(InStr(Body, "PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS") > 0,
		"SaveFullConfig must still snapshot the previous canonicalization-guard state")
	Assert(InStr(Body, "_TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState") > 0,
		"SaveFullConfig must still restore the previous canonicalization-guard state")
}
Test("ErgoptiPlus: SaveFullConfig's PrevCanonState is function-local, not a shared global (savefullconfig-prevcanonstate-shared-global)", _SFND_PrevCanonStateIsLocal)

