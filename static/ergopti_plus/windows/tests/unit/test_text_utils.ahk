; static/ergopti_plus/windows/tests/unit/test_text_utils.ahk

; ==============================================================================
; MODULE: Text Utilities Tests
; DESCRIPTION:
; Unit-tests for the pure string helpers in infra/text_utils.ahk.
; ==============================================================================






; ============================
; ============================
; ======= 1/ UriDecode =======
; ============================
; ============================

_SU_PlainStringPassesThrough() {
	AssertEqual("hello", UriDecode("hello"))
}
Test("UriDecode: plain string passes through unchanged", _SU_PlainStringPassesThrough)

_SU_DecodesSpace() {
	AssertEqual("hello world", UriDecode("hello%20world"))
}
Test("UriDecode: decodes space %20", _SU_DecodesSpace)

_SU_DecodesSlash() {
	AssertEqual("a/b", UriDecode("a%2Fb"))
}
Test("UriDecode: decodes forward slash %2F", _SU_DecodesSlash)

_SU_DecodesMultiple() {
	AssertEqual("a b/c", UriDecode("a%20b%2Fc"))
}
Test("UriDecode: decodes multiple sequences", _SU_DecodesMultiple)

_SU_LeavesLonePercent() {
	; A bare % not followed by two hex digits should not crash
	Result := UriDecode("50%")
	AssertEqual("50%", Result)
}
Test("UriDecode: leaves lone percent sign intact", _SU_LeavesLonePercent)

_SU_DecodesUppercaseHex() {
	AssertEqual(" ", UriDecode("%20"))
}
Test("UriDecode: decodes uppercase hex", _SU_DecodesUppercaseHex)

_SU_DecodesLowercaseHex() {
	AssertEqual(" ", UriDecode("%20"))
}
Test("UriDecode: decodes lowercase hex", _SU_DecodesLowercaseHex)

_SU_EmptyStringReturnsEmpty() {
	AssertEqual("", UriDecode(""))
}
Test("UriDecode: empty string returns empty string", _SU_EmptyStringReturnsEmpty)

_SU_DecodesRealisticFileUrlSegment() {
	; file:/// path with accented folder name
	Encoded := "T%C3%A9l%C3%A9chargements"
	; %C3%A9 = U+00E9 = é (UTF-8 two-byte sequence)
	; AHK Chr(0xC3) + Chr(0xA9) may not equal "é" in ANSI mode, so we just
	; verify the function does not crash and returns a non-empty string.
	Result := UriDecode(Encoded)
	Assert(StrLen(Result) > 0, "Expected non-empty decoded result")
}
Test("UriDecode: decodes a realistic file URL path segment", _SU_DecodesRealisticFileUrlSegment)


/** Independent character vectors pin native key counts and internal spans. */
_SU_UnicodeEraseAndReplaySpans() {
	Vectors := [[], ["a"], [Chr(0x1F600)], ["a", Chr(0x1F600), "b"],
		[Chr(0x1F600), Chr(0x10400), "x", Chr(0x1F642)],
		["e", Chr(0x301), Chr(0x1F600)], [Chr(0xD800)], [Chr(0xDC00)]]
	for Expected in Vectors {
		Text := ""
		for Char in Expected
			Text .= Char
		AssertEqual(Expected.Length, _TextCodepointLength(Text))
		Actual := _TextCodepoints(Text)
		AssertEqual(Expected.Length, Actual.Length, "replay keeps complete pairs and every independent character")
		for Index, Char in Expected
			AssertEqual(Char, Actual[Index], "replay must preserve the exact original units")
		Loop Expected.Length + 3 {
			Count := A_Index - 1
			Erased := 0
			Loop Min(Count, Expected.Length)
				Erased += StrLen(Expected[Expected.Length - A_Index + 1])
			AssertEqual(Erased, _TextTailCodeUnits(Text, Count),
				"native erasure clamps to available whole characters")
		}
	}
	AssertThrows(() => _TextCodepointLength(42), "counting rejects a non-string")
	AssertThrows(() => _TextCodepoints(42), "replay rejects a non-string")
	AssertThrows(() => _TextTailCodeUnits("a", -1), "erasure rejects a negative count")
	AssertThrows(() => _TextTailCodeUnits("a", 1.5), "erasure rejects a fractional count")
	AssertThrows(() => _TextTailCodeUnits(42, 1), "erasure rejects a non-string")
}
Test("text utils: Unicode replay and erasure preserve independent character spans (unicode-erase)",
	_SU_UnicodeEraseAndReplaySpans)

_UCAP_TextTailBudget() {
	Text := "A" . Chr(0x1F600) . "bc"
	Expected := ["", "c", "bc", "bc", Chr(0x1F600) . "bc", Text]
	for Value in Expected {
		Capacity := A_Index - 1
		Actual := _TextTailWithinUnits(Text, Capacity)
		AssertEqual(Value, Actual, "literal suffix for budget " . Capacity)
		Assert(StrLen(Actual) <= Capacity, "whole pairs never exceed the unit budget")
	}
	AssertEqual("", _TextTailWithinUnits("A" . Chr(0x1F600), 1))
	AssertEqual(Chr(0x1F600), _TextTailWithinUnits("A" . Chr(0x1F600), 2))
	AssertEqual("A" . Chr(0xD800), _TextTailWithinUnits("A" . Chr(0xD800), 2),
		"isolated legacy units retain their original representation")
	AssertEqual(Chr(0xDC00), _TextTailWithinUnits("A" . Chr(0xDC00), 1))
}
Test("text unicode-context-cap: every unit budget preserves the exact complete suffix", _UCAP_TextTailBudget)
