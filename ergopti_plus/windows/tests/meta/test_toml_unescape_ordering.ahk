; tests/meta/test_toml_unescape_ordering.ahk

; ==============================================================================
; MODULE: Wrap-Symbol TOML Decoder Ownership Guard
; DESCRIPTION:
; Ensures wrap symbols cannot reintroduce a local ordered-replacement decoder.
; The shared codec performs one left-to-right pass and covers the full TOML
; basic-string escape grammar.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTUO_UnescapeOrderingCheck() {
	Body := _DriverFuncBody("_WS_UnescapeToml")
	Assert(Body != "", "_WS_UnescapeToml must remain defined")
	Assert(InStr(Body, "TOML_UnescapeBasicStringContents(") > 0,
		"_WS_UnescapeToml must delegate to the shared left-to-right TOML decoder")
}
Test("wrap_symbols_config: _WS_UnescapeToml uses shared ordering",
	_TTUO_UnescapeOrderingCheck)
