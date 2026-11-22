; tests/unit/core/timing/test_timings_reader.ahk

; ==============================================================================
; MODULE: Timings Reader Value Types (Windows)
; DESCRIPTION:
; The Lua reader (_shared/core/timing/engine/timings_core.lua) refuses a
; registry value that is not a number. TimingsGet passed the value through
; Integer(), so a quoted "500" read as 500 on Windows and stopped macOS and
; Linux at boot, and a 1.5 ms read as 1; TimingsGetNumber's IsNumber accepted
; a quoted "1.5" (timings-reader-types, timing parity campaign, November 22,
; 2026). A registry loaded with each shape pins the refusal.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body() with a registry of every value shape; the real one is put back.
_TRT_WithRegistry(Body) {
	global _TimingsCache
	Saved := _TimingsCache
	try {
		_TimingsCache := Map("t", Map("int_ms", 500, "quoted_ms", "500", "float_ms", 1.5,
			"float_mm", 1.5, "int_mm", 3, "quoted_mm", "1.5"))
		Body.Call()
	} finally
		_TimingsCache := Saved
}

; The message of the error Callback throws, "" when it does not throw.
_TRT_Thrown(Callback) {
	try Callback.Call()
	catch as Err
		return Err.Message
	return ""
}

_TRT_IntegerOnly() {
	AssertEqual(500, TimingsGet("t", "int_ms"))
	AssertEqual(0.5, TimingsGetSec("t", "int_ms"))
	AssertContains(_TRT_Thrown(() => TimingsGet("t", "quoted_ms")), "missing or non-integer key [t] quoted_ms",
		"a quoted value is refused, as the Lua reader refuses it")
	AssertContains(_TRT_Thrown(() => TimingsGet("t", "float_ms")), "missing or non-integer key [t] float_ms",
		"a fractional millisecond count is refused instead of truncated")
	AssertContains(_TRT_Thrown(() => TimingsGet("t", "absent_ms")), "missing or non-integer key [t] absent_ms",
		"a missing key names itself in English")
}
Test("Timings: TimingsGet admits only an integer value (timings-reader-types)",
	() => _TRT_WithRegistry(_TRT_IntegerOnly))

_TRT_NumberOnly() {
	AssertEqual(1.5, TimingsGetNumber("t", "float_mm"))
	AssertEqual(3, TimingsGetNumber("t", "int_mm"))
	AssertContains(_TRT_Thrown(() => TimingsGetNumber("t", "quoted_mm")), "missing or non-numeric key [t] quoted_mm",
		"a quoted number is refused, as the Lua reader refuses it")
	AssertContains(_TRT_Thrown(() => TimingsGetNumber("t", "absent_mm")), "missing or non-numeric key [t] absent_mm")
}
Test("Timings: TimingsGetNumber admits only a TOML number (timings-reader-types)",
	() => _TRT_WithRegistry(_TRT_NumberOnly))

_TRT_LoadNamesTheFile() {
	Missing := A_Temp . "\ergopti_timings_reader_absent_" . A_TickCount
	AssertContains(_TRT_Thrown(() => TimingsLoadShared(Missing)), "constants.toml is missing or empty: ",
		"an unreadable registry names its path in English, as the Lua reader does")
}
Test("Timings: an unreadable registry is named in English (timings-reader-types)", _TRT_LoadNamesTheFile)
