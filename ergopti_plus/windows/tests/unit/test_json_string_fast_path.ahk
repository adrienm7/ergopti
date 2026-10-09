; tests/unit/test_json_string_fast_path.ahk

; ==============================================================================
; MODULE: JSON String Fast-Path Tests
; DESCRIPTION:
; Pins escaping across every non-NUL UTF-16 code unit without timing assertions
; dependent on desktop load. Native before/after probes own performance evidence.
; ==============================================================================

_JsonFastPath_AllCodeUnits(Html) {
	Escapes := Map(8, "\b", 9, "\t", 10, "\n", 12, "\f", 13, "\r",
		34, '\"', 92, "\\")
	Loop 65535 {
		Code := A_Index
		Char := Chr(Code)
		Expected := Char
		if Escapes.Has(Code)
			Expected := Escapes[Code]
		else if Code < 32 || Code = 0x2028 || Code = 0x2029
				|| (Html && (Code = 38 || Code = 60 || Code = 62))
			Expected := Format("\u{:04x}", Code)
		AssertEqual('"prefix' . Expected . 'suffix"',
			JsonStringLiteral("prefix" . Char . "suffix", Html),
			"JSON escaping differs at UTF-16 unit " . Code)
	}
	AssertEqual('""', JsonStringLiteral("", Html))
	AssertEqual('"123"', JsonStringLiteral(123, Html))
	AssertEqual('"' . Chr(0x1F642) . '"', JsonStringLiteral(Chr(0x1F642), Html))
}
for Html in [false, true]
	Test("JSON strings: exhaustive code units HTML=" . Html . " (json-safe-string-fast-path)",
		_JsonFastPath_AllCodeUnits.Bind(Html))
