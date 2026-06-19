; tests/meta/test_logger_flush_on_warning.ahk

; ==============================================================================
; MODULE: Logger Flush on Warning Meta Test
; DESCRIPTION:
; Regression guard ensuring _LoggerEmit forces a synchronous flush for WARNING
; level messages, not only for ERROR. A WARNING immediately before a hard crash
; would otherwise be swallowed by the 500 ms buffered path.
;
; SCOPE: source introspection of lib/logger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_LFOW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_LFOW_CheckWarnThreshold() {
	Src := _LFOW_ReadSource("lib/logger.ahk")
	Assert(Src != "", "lib/logger.ahk must be readable")

	; The force-flush guard must use "WARNING" as the threshold, not "ERROR"
	Assert(!InStr(Src, 'LOGGER_SEVERITY["ERROR"]') || InStr(Src, 'LOGGER_SEVERITY["WARNING"]'),
		'_LoggerEmit force-flush must trigger at >= LOGGER_SEVERITY["WARNING"], not only ERROR')

	Assert(InStr(Src, '>= LOGGER_SEVERITY["WARNING"]'),
		'_LoggerEmit must call _LoggerFlush(true) when LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"]')
}


Test("meta logger: force-flush triggered for WARNING level, not only ERROR",
	_LFOW_CheckWarnThreshold)