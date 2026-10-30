; tests/meta/infra/toml/test_parse_overrides_seen_sections.ahk

; ==============================================================================
; MODULE: _ParseOverrides Duplicate Section Behaviour
; DESCRIPTION:
; A file repeating a [ext.name.section] header silently clobbered the earlier
; values, which made an accidental duplicate impossible to diagnose. A duplicate
; header is invalid TOML, as on the other drivers: the parser raises.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPOSS_Parse(Tag, Body) {
	Path := A_Temp . "\ergopti_test_overrides_" . DllCall("GetCurrentProcessId", "UInt") . "_" . Tag . ".toml"
	FileAppend(Body, Path, "UTF-8-RAW")
	try return _ParseOverrides(Path)
	finally FileDelete(Path)
}

_TPOSS_DuplicateHeaderRaises() {
	Header := "[ext.pack.section]`n"
	_TPOSS_Parse("single", Header . 'delay = 1`n')
	Raised := ""
	try _TPOSS_Parse("twice", Header . 'delay = 1`n' . Header . 'delay = 2`n')
	catch ValueError as Err
		Raised := Err.Message
	AssertContains(Raised, "Duplicate table", "a repeated header must raise rather than clobber the earlier values")
}
Test("hotstrings_config: _ParseOverrides raises on a duplicate section header", _TPOSS_DuplicateHeaderRaises)
