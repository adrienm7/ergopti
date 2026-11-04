; tests/meta/infra/toml/test_toml_unescape_ordering.ahk

; ==============================================================================
; MODULE: Wrap-Symbol TOML Decoder Behaviour
; DESCRIPTION:
; A local ordered-replacement decoder turns an escaped backslash followed by n into
; a line feed. The wrap symbols decode in one left-to-right pass, as the shared
; codec does, and read the complete TOML basic-string escape grammar.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTUO_UnescapeOrderingCheck() {
	; The source text is backslash backslash n.
	AssertEqual(Chr(92) . "n", _WS_UnescapeToml(Chr(92) . Chr(92) . "n"),
		"an escaped backslash stays one backslash and never becomes the start of a line feed")
	AssertEqual("a" . Chr(10) . "b", _WS_UnescapeToml("a" . Chr(92) . "nb"), "a real escape decodes")
	AssertEqual(Chr(0xE9), _WS_UnescapeToml(Chr(92) . "u00e9"), "the Unicode escapes of the shared grammar decode")
}
Test("wrap_symbols_config: _WS_UnescapeToml decodes in one left-to-right pass",
	_TTUO_UnescapeOrderingCheck)
