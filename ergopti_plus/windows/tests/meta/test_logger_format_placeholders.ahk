; tests/meta/test_logger_format_placeholders.ahk

; ==============================================================================
; MODULE: Logger Format-Placeholder Test
; DESCRIPTION:
; Guards against printf-style placeholders in logger format strings.
;
; WHY THIS MATTERS (the bug class this encodes):
;   The central logger (LoggerDebug/Info/Warn/Error/Start/Success/Trace/Done)
;   formats with AHK v2 Format-style positional placeholders — {1}, {2}, {3} …
;   It never interprets printf-style conversions (%s, %d, %u, …). A call that
;   writes "loaded (%d items)" therefore logs the literal text "(%d items)" and
;   silently drops the value — the diagnostic is useless precisely when needed.
;   A whole-codebase sweep fixed ~35 such calls across 12 files; this test keeps
;   them fixed and fails the build the moment a new one is introduced.
;
; SCOPE: scans every PRODUCTION .ahk under windows\ (the tests\ tree is skipped:
;   i18n fixtures and StrReplace-on-translated-string calls legitimately use
;   printf-style placeholders, and this file itself carries the patterns as data).
;   Detection is per-line, matching the project convention of writing the format
;   string on the same line as the Logger… call.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckLoggerFormatPlaceholders() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	LoggerCallRe  := "Logger(Debug|Info|Warn|Error|Start|Success|Trace|Done)\("
	; printf conversions the {N}-style logger never substitutes
	PlaceholderRe := "%[sdiuxXfgc]"

	Offenders := []
	Loop Files, WindowsDir . "\*.ahk", "FR" {
		; Skip the test tree — fixtures and this scanner carry the patterns as data.
		if InStr(A_LoopFileFullPath, "\tests\")
			continue
		Body := ""
		try Body := FileRead(A_LoopFileFullPath, "UTF-8")
		if (Body == "")
			continue
		LineNo := 0
		Loop Parse, Body, "`n", "`r" {
			LineNo += 1
			Line := A_LoopField
			if (RegExMatch(Line, LoggerCallRe) && RegExMatch(Line, PlaceholderRe))
				Offenders.Push(A_LoopFileName . ":" . LineNo . "  " . Trim(Line))
		}
	}

	Msg := "Logger calls must use {1}/{2} Format placeholders, not printf-style "
		. "percent conversions (the logger never substitutes them). Offender(s):`n"
	for _, O in Offenders
		Msg .= "  " . O . "`n"

	Assert(Offenders.Length == 0, Msg)
}

Test("meta logger: no printf placeholders in logger format strings",
	_MetaCheckLoggerFormatPlaceholders)
