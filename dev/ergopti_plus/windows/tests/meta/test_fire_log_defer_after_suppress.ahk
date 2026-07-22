; tests/meta/test_fire_log_defer_after_suppress.ahk

; ==============================================================================
; MODULE: Fire-Log Defer vs Suppress Release Ordering Guard
; DESCRIPTION:
; Guards the strict ordering invariant between HSE_FIRE_LOG_DEFER_MS (90 ms)
; and HSE_SUPPRESS_RELEASE_DELAY_MS (60 ms). The fired-hotstring log drain
; MUST fire AFTER the suppress release, otherwise it stretches the OnChar
; critical path inside the suppress window and re-introduces the key-swallow
; bug that produced "abcd"->"acd". The two constants live in two separate
; files and the ordering exists only as a code comment. No test locked it
; before this guard.
;
; If a future edit raises HSE_SUPPRESS_RELEASE_DELAY_MS (e.g. to 100 ms to
; widen the OS-drain margin) or lowers HSE_FIRE_LOG_DEFER_MS, the ordering
; silently inverts and the bug returns with zero test failure.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaCheckFireLogDeferAfterSuppress() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	InputFile := WindowsDir . "\lib\hotstrings\hotstring_inputhook.ahk"
	InputSrc := ""
	try InputSrc := FileRead(InputFile)
	Assert(InputSrc != "", "hotstring_inputhook.ahk must be readable")

	DispatchFile := WindowsDir . "\lib\hotstrings\hotstring_dispatch.ahk"
	DispatchSrc := ""
	try DispatchSrc := FileRead(DispatchFile)
	Assert(DispatchSrc != "", "hotstring_dispatch.ahk must be readable")

	; Extract the two integer literals via RegExMatch.
	; HSE_FIRE_LOG_DEFER_MS lives in hotstring_inputhook.ahk.
	fireDefer := 0
	RegExMatch(InputSrc, "HSE_FIRE_LOG_DEFER_MS\s*:=\s*(\d+)", &fireMatch)
	Assert(fireMatch.Count >= 1, "HSE_FIRE_LOG_DEFER_MS := <ms> must exist in hotstring_inputhook.ahk")
	fireDefer := Integer(fireMatch[1])

	; HSE_SUPPRESS_RELEASE_DELAY_MS lives in hotstring_dispatch.ahk.
	suppressRelease := 0
	RegExMatch(DispatchSrc, "HSE_SUPPRESS_RELEASE_DELAY_MS\s*:=\s*(\d+)", &suppressMatch)
	Assert(suppressMatch.Count >= 1, "HSE_SUPPRESS_RELEASE_DELAY_MS := <ms> must exist in hotstring_dispatch.ahk")
	suppressRelease := Integer(suppressMatch[1])

	; The fire-log drain (90 ms by default) MUST fire AFTER the suppress
	; release (60 ms by default). If this invariant is inverted, the log drain
	; runs inside the suppress window, stretches OnChar, and re-swallows keys
	; typed right after a trigger - the exact "abcd"->"acd" bug.
	Assert(fireDefer > suppressRelease,
		"HSE_FIRE_LOG_DEFER_MS (" . fireDefer . " ms) must be greater than "
		. "HSE_SUPPRESS_RELEASE_DELAY_MS (" . suppressRelease . " ms) - "
		. "the fire-log drain must fire AFTER the suppress release or the "
		. '"abcd"->"acd" key-swallow bug returns')
}

Test("meta fire-log defer: HSE_FIRE_LOG_DEFER_MS > HSE_SUPPRESS_RELEASE_DELAY_MS (abcd->acd key-swallow guard)",
	_MetaCheckFireLogDeferAfterSuppress)
