; tests/meta/test_crash_reporter_slash_precedence.ahk

; ==============================================================================
; MODULE: Crash Reporter Slash Precedence Meta Test
; DESCRIPTION:
; Regression guard ensuring the trailing-slash normalisation in the crash reporter
; uses correct operator precedence. The bug:
;   if (!BaseDir ~= "[/\\]$")
; is parsed as (!BaseDir) ~= "[/\\]$" — the logical NOT binds tighter than ~=,
; so it negates BaseDir first (non-empty string → false/0) and then compares
; 0 against the regex, which always succeeds, so the guard never adds the trailing
; backslash.
;
; The fix: !(BaseDir ~= "[/\\]$") — NOT applied to the full match expression.
;
; The crash reporter no longer builds its folder: LoggerCrashReportsDir() in
; infra/logger.ahk resolves it inside the logs folder. The invariant moved with
; it and is now checked behaviourally: whatever separator the logs folder was
; stored with, the crash-reports folder ends in exactly one backslash.
;
; SCOPE: source introspection of modules/diagnostics/ plus the logger resolver.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_CRSP_CheckNoBadPrecedence() {
	; Move-resilient: scan the module tree via the framework helper instead of
	; a pinned crash_reporter path. The BaseDir precedence forms are unique to
	; crash_reporter within modules/diagnostics/, so the scope stays meaningful.
	Src := _DriverDirConcat("modules/diagnostics")

	; The wrong form: (!BaseDir ~= "[/\\]$") — NOT binds to BaseDir, not the regex result
	Assert(!InStr(Src, "if (!BaseDir ~="),
		'crash_reporter must not use if (!BaseDir ~= ...) — wrong precedence; use if !(BaseDir ~= ...) instead')
}

_CRSP_CrashFolderEndsInOneSeparator() {
	global _LogsDir
	Saved := _LogsDir
	try {
		for Stored in ["C:\Logs\ergopti_plus", "C:\Logs\ergopti_plus\", "C:\Logs\ergopti_plus/"] {
			_LogsDir := Stored
			AssertEqual("C:\Logs\ergopti_plus\", LoggerLogsDir(),
				"the logs folder must end in exactly one backslash whatever it was stored with")
			AssertEqual("C:\Logs\ergopti_plus\crash_reports\", LoggerCrashReportsDir(),
				"crash reports must land in <logs>\crash_reports\, never beside it")
		}
	} finally {
		_LogsDir := Saved
	}
}


Test("meta crash-reporter: trailing-slash check does not use wrong !expr precedence",
	_CRSP_CheckNoBadPrecedence)

Test("meta crash-reporter: the crash-reports folder always ends in one separator",
	_CRSP_CrashFolderEndsInOneSeparator)