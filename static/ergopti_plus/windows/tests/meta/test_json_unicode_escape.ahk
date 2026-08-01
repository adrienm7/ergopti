; tests/meta/test_json_unicode_escape.ahk

; ==============================================================================
; MODULE: JSON Unicode Escape Meta Test
; DESCRIPTION:
; Static source guard for the "json-unicode-escape-raw-throw" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TJU_Check() {
	Src := _DriverDirConcat("infra")
	Assert(InStr(Src, "^[0-9A-Fa-f]{4}$") > 0, "json.ahk must validate \\u hex escapes")
	Assert(InStr(Src, "JSON: invalid \u escape") > 0, "json.ahk must throw descriptive error on invalid \\u escape")
}

Test("JSON parser: validate \\u escapes", _TJU_Check)
