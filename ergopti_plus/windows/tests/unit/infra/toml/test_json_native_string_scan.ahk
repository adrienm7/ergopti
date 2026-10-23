; tests/unit/infra/toml/test_json_native_string_scan.ahk

; ==============================================================================
; MODULE: JSON Native String Scan Tests
; DESCRIPTION:
; JsonParse finds the end of each plain string run with one native code-unit
; scan (NativeTextSpanExcluding), and JsonArrayElementSpans validates, decodes
; and records spans in one pass.
; Both are performance changes: they must decode exactly what the former
; per-character scan decoded, including raw lone surrogates (which PCRE refuses
; to scan from) and every refused control character. Native before/after
; probes own the timing evidence; these tests own the semantics.
; ==============================================================================

#Requires AutoHotkey v2.0

_JNSS_UnitsOf(Text) {
	Units := ""
	loop StrLen(Text)
		Units .= Format("{:04X} ", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Units
}

; Every raw UTF-16 code unit at the start, middle and end of a plain run.
_JNSS_EveryRawCodeUnitDecodesIdentically() {
	Failures := 0, First := ""
	loop 65535 {
		Code := A_Index
		if Code == 0x22 || Code == 0x5C
			continue
		Char := Chr(Code)
		for Source in ['"' . Char . 'run"', '"run' . Char . 'run"', '"run' . Char . '"'] {
			Expected := SubStr(Source, 2, StrLen(Source) - 2)
			try {
				Decoded := JsonParse(Source)
				Accepted := true
			} catch {
				Accepted := false
			}
			Ok := Code < 0x20 ? !Accepted : (Accepted && _JNSS_UnitsOf(Decoded) == _JNSS_UnitsOf(Expected))
			if !Ok {
				Failures += 1
				if First == ""
					First := Format("U+{1:04X} in {2}", Code, _JNSS_UnitsOf(Source))
			}
		}
	}
	AssertEqual(0, Failures, "raw string text must decode exactly, controls refused; first divergence: " . First)
}
Test("JSON: every raw code unit decodes exactly through the native run scan (json-native-string-scan)",
	_JNSS_EveryRawCodeUnitDecodesIdentically)

; Long runs, escapes between runs and raw surrogates around them.
_JNSS_MixedRunsDecodeIdentically() {
	Plain := ""
	loop 5000
		Plain .= "abcé"
	Cases := [
		['"' . Plain . '\n' . Plain . '"', Plain . "`n" . Plain],
		['"xé' . Chr(0xDC00) . 'y\"z"', "x" . Chr(0xE9) . Chr(0xDC00) . 'y"z'],
		['"a' . Chr(0xD800) . '\\b' . Chr(0xD83D) . Chr(0xDE00) . '"', "a" . Chr(0xD800) . "\b" . Chr(0x1F600)],
		['"' . Chr(0x60) . 'tick' . Chr(0x60) . '"', Chr(0x60) . "tick" . Chr(0x60)]]
	for Pair in Cases
		AssertEqual(_JNSS_UnitsOf(Pair[2]), _JNSS_UnitsOf(JsonParse(Pair[1])), "mixed runs must decode exactly")
}
Test("JSON: long runs, escapes and raw surrogates decode exactly (json-native-string-scan)",
	_JNSS_MixedRunsDecodeIdentically)

; One pass yields the same decoded element the canonical parser produces.
_JNSS_SpansCarryDecodedValues() {
	Source := ' [ 1 , "sé" , {"k":[true,null]} , [ {"x":"y"} ] ] '
	Spans := JsonArrayElementSpans(Source)
	Whole := JsonParse(Source)
	AssertEqual(Whole.Length, Spans.Length, "one span per root element")
	AssertEqual(1, Spans[1]["value"])
	AssertEqual("s" . Chr(0xE9), Spans[2]["value"])
	AssertTrue(Spans[3]["value"] is Map && Spans[3]["value"]["k"][2] == JSON_NULL, "objects decode with their nested values")
	AssertEqual("y", Spans[4]["value"][1]["x"], "nested arrays decode with their nested objects")
	for Index, Span in Spans
		AssertEqual(Type(JsonParse(Span["text"])), Type(Span["value"]), "the span value matches its own source text")
}
Test("JSON: array spans carry the decoded value of every element (json-native-string-scan)",
	_JNSS_SpansCarryDecodedValues)
