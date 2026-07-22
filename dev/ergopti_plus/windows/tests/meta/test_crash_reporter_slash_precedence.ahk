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
; SCOPE: source introspection of lib/crash_reporter.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_CRSP_CheckNoBadPrecedence() {
	; Move-resilient: scan the lib module tree via the framework helper instead of
	; a pinned crash_reporter path. The BaseDir precedence forms are unique to
	; crash_reporter within lib/, so the scope stays meaningful.
	Src := _DriverDirConcat("lib")

	; The wrong form: (!BaseDir ~= "[/\\]$") — NOT binds to BaseDir, not the regex result
	Assert(!InStr(Src, "if (!BaseDir ~="),
		'crash_reporter must not use if (!BaseDir ~= ...) — wrong precedence; use if !(BaseDir ~= ...) instead')
}

_CRSP_CheckCorrectPrecedence() {
	Src := _DriverDirConcat("lib")

	; The correct form: !(BaseDir ~= "[/\\]$")
	Assert(InStr(Src, "if !(BaseDir ~="),
		'crash_reporter must use if !(BaseDir ~= ...) to apply NOT to the full regex match result')
}


Test("meta crash-reporter: trailing-slash check does not use wrong !expr precedence",
	_CRSP_CheckNoBadPrecedence)

Test("meta crash-reporter: trailing-slash check uses !(BaseDir ~= ...) with correct precedence",
	_CRSP_CheckCorrectPrecedence)