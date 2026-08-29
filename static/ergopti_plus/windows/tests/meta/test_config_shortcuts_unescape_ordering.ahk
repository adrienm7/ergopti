; tests/meta/test_config_shortcuts_unescape_ordering.ahk

; ==============================================================================
; MODULE: Config Shortcuts TOML Decoder Ownership Meta Test
; DESCRIPTION:
; Keeps CS_Unescape on the shared complete left-to-right TOML decoder so local
; replacement ordering and escape coverage cannot drift again.
; ==============================================================================

#Requires AutoHotkey v2.0

_TCSUO_CheckUnescapeOrdering() {
	Body := _DriverFuncBody("CS_Unescape")
	Assert(Body != "", "CS_Unescape must remain defined")
	Assert(InStr(Body, "TOML_UnescapeBasicStringContents(") > 0,
		"CS_Unescape must delegate to the shared complete TOML decoder")
}
Test("meta ahk-22: CS_Unescape uses the shared left-to-right TOML decoder",
	_TCSUO_CheckUnescapeOrdering)
