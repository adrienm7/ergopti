; tests/meta/test_updater_setcheckinterval_coerces.ahk

; ==============================================================================
; MODULE: Updater_SetCheckInterval Coercion Meta Test
; DESCRIPTION:
; Static source guard for the "updater-setcheckinterval-type-guard-rejects-non-
; integer" finding.
;
; The old guard `if (Type(Seconds) != "Integer" or Seconds < 0) return` was an
; exact-type test: a valid cadence arriving as a String ("300") or Float (300.0)
; — entirely plausible from a config migration, since Updater_LoadCheckInterval
; reads strings from TOML — would silently fail it. The early return was also
; silent (no LoggerWarn), so a mis-typed value disappeared without a trace,
; violating the fail-loud / setter-logging conventions.
;
; The fix coerces with Integer() inside a try, rejects only genuinely invalid
; (non-numeric or negative) input, and LoggerWarn's on rejection. This is a
; meta-static test (scans source text) because calling Updater_SetCheckInterval
; has real side effects (TOML_Write to the global config file, timer restart,
; initMenu rebuild) that are unsafe in the headless runner.
;
; If the exact-type rejection regresses, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_USCI_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Coercion-guard assertions =============
; ==================================================
; ==================================================

_USCI_CoercesInsteadOfExactTypeReject() {
	Src := _USCI_ReadSource("modules/updater.ahk")
	Seg := _DriverFuncBody("Updater_SetCheckInterval")
	Assert(Seg != "", "Updater_SetCheckInterval(Seconds) declaration must exist in modules/updater.ahk")

	; The exact-type rejection must be gone — it silently dropped valid String
	; and Float cadences.
	Assert(!InStr(Seg, 'Type(Seconds) != "Integer"'),
		"Updater_SetCheckInterval must not reject on Type(Seconds) != Integer — that silently drops valid String/Float cadences (updater-setcheckinterval-type-guard-rejects-non-integer)")

	; It must coerce defensively instead.
	Assert(InStr(Seg, "Integer(Seconds)") > 0,
		"Updater_SetCheckInterval must coerce with Integer(Seconds) so a String/Float cadence is accepted (updater-setcheckinterval-type-guard-rejects-non-integer)")
}
Test("updater: Updater_SetCheckInterval coerces instead of exact-type reject (updater-setcheckinterval-type-guard-rejects-non-integer)", _USCI_CoercesInsteadOfExactTypeReject)

_USCI_LogsOnRejection() {
	Src := _USCI_ReadSource("modules/updater.ahk")
	Seg := _DriverFuncBody("Updater_SetCheckInterval")
	; A rejected value must be visible in the log rather than silently dropped.
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"Updater_SetCheckInterval must LoggerWarn on a rejected value — fail loud, do not silently no-op (updater-setcheckinterval-type-guard-rejects-non-integer)")
}
Test("updater: Updater_SetCheckInterval logs a warning on rejection (updater-setcheckinterval-type-guard-rejects-non-integer)", _USCI_LogsOnRejection)

_USCI_PersistsBeforePublishingTimerState() {
	Seg := _DriverFuncBody("Updater_SetCheckInterval")
	PersistAt := InStr(Seg, "if !TOML_Write(Seconds")
	PublishAt := InStr(Seg, "UPDATER_CHECK_INTERVAL := Seconds")
	StopAt := InStr(Seg, "Updater_StopBackgroundChecks()")
	Assert(PersistAt > 0 && PublishAt > PersistAt && StopAt > PersistAt,
		"Updater_SetCheckInterval must persist before publishing cadence or restarting timers")
	Assert(InStr(Seg, "LoggerError") > PersistAt,
		"a failed cadence write must fail loud and leave the current timer untouched")
}
Test("updater: interval persistence commits before state/timer publication", _USCI_PersistsBeforePublishingTimerState)
