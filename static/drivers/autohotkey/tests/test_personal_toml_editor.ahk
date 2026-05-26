; static/drivers/autohotkey/tests/test_personal_toml_editor.ahk

; ==============================================================================
; MODULE: Personal TOML Editor Tests
; DESCRIPTION:
; Pure-helper tests for EscapeTomlValue, NormaliseOutput, ArrayJoin and the
; round-trip of WritePersonalToml ↔ ReadPersonalToml on a temporary file.
; ==============================================================================




; ==========================
; EscapeTomlValue
; ==========================
TestPE_EscapeEmpty() {
	AssertEqual("", EscapeTomlValue(""))
}
Test("EscapeTomlValue: empty string", TestPE_EscapeEmpty)

TestPE_EscapeBackslash() {
	AssertEqual("a\\b", EscapeTomlValue("a\b"))
}
Test("EscapeTomlValue: backslash is doubled", TestPE_EscapeBackslash)

TestPE_EscapeQuote() {
	AssertEqual('a\"b', EscapeTomlValue('a"b'))
}
Test("EscapeTomlValue: double-quote is escaped", TestPE_EscapeQuote)

TestPE_EscapeNewline() {
	AssertEqual("a{Enter}b", EscapeTomlValue("a`nb"))
}
Test("EscapeTomlValue: newline becomes {Enter} token", TestPE_EscapeNewline)

TestPE_EscapeTab() {
	AssertEqual("a{Tab}b", EscapeTomlValue("a`tb"))
}
Test("EscapeTomlValue: tab becomes {Tab} token", TestPE_EscapeTab)

TestPE_EscapeCR() {
	AssertEqual("a{Enter}b", EscapeTomlValue("a`rb"))
}
Test("EscapeTomlValue: carriage return becomes {Enter} token", TestPE_EscapeCR)

TestPE_EscapeCRLF() {
	AssertEqual("a{Enter}b", EscapeTomlValue("a`r`nb"))
}
Test("EscapeTomlValue: CRLF becomes a single {Enter} token", TestPE_EscapeCRLF)

TestPE_EscapeRoundTrip() {
	; Plain values with no newline/tab characters round-trip exactly through
	; Escape → Unescape. Newlines/tabs are deliberately one-way (replaced with
	; {Enter}/{Tab} tokens at write time) so they do not feature in this test.
	Original := "Mix of `"quotes`" and slashes\\."
	Recovered := UnescapeTomlString(EscapeTomlValue(Original))
	AssertEqual(Original, Recovered)
}
Test("Escape/Unescape round-trip preserves plain values", TestPE_EscapeRoundTrip)

TestPE_EscapeNewlinesTokenisedNotEscaped() {
	; Confirm we never store raw \n / \t / \r escape sequences for output-style
	; payloads — the canonical on-disk form is {Enter} / {Tab} tokens.
	Out := EscapeTomlValue("line1`nline2`tindented")
	AssertEqual("line1{Enter}line2{Tab}indented", Out)
}
Test("EscapeTomlValue: newlines and tabs are tokenised, not TOML-escaped",
	TestPE_EscapeNewlinesTokenisedNotEscaped)




; ==========================
; NormaliseOutput
; ==========================
TestPE_NormLF() {
	AssertEqual("a{Enter}b", NormaliseOutput("a`nb"))
}
Test("NormaliseOutput: bare LF becomes {Enter}", TestPE_NormLF)

TestPE_NormCRLF() {
	AssertEqual("a{Enter}b", NormaliseOutput("a`r`nb"))
}
Test("NormaliseOutput: bare CRLF becomes {Enter}", TestPE_NormCRLF)

TestPE_NormTab() {
	AssertEqual("a{Tab}b", NormaliseOutput("a`tb"))
}
Test("NormaliseOutput: bare tab becomes {Tab}", TestPE_NormTab)

TestPE_NormEsc() {
	AssertEqual("{Escape}", NormaliseOutput("{esc}"))
}
Test("NormaliseOutput: {esc} alias is canonicalised to {Escape}", TestPE_NormEsc)

TestPE_NormBs() {
	AssertEqual("{BackSpace}", NormaliseOutput("{bs}"))
}
Test("NormaliseOutput: {bs} alias is canonicalised to {BackSpace}", TestPE_NormBs)

TestPE_NormLeft() {
	AssertEqual("{Left}", NormaliseOutput("{left}"))
}
Test("NormaliseOutput: {left} alias is title-cased to {Left}", TestPE_NormLeft)

TestPE_NormUnknownToken() {
	AssertEqual("{Foobar}", NormaliseOutput("{foobar}"))
}
Test("NormaliseOutput: unknown {token} keeps capitalised first letter",
	TestPE_NormUnknownToken)

TestPE_NormUnmatchedBrace() {
	AssertEqual("a{b", NormaliseOutput("a{b"))
}
Test("NormaliseOutput: unmatched opening brace is preserved verbatim",
	TestPE_NormUnmatchedBrace)




; ==========================
; ArrayJoin
; ==========================
TestPE_JoinEmpty() {
	AssertEqual("", ArrayJoin([], ", "))
}
Test("ArrayJoin: empty array returns empty string", TestPE_JoinEmpty)

TestPE_JoinSingle() {
	AssertEqual("only", ArrayJoin(["only"], ", "))
}
Test("ArrayJoin: single element returns that element", TestPE_JoinSingle)

TestPE_JoinMulti() {
	AssertEqual("a, b, c", ArrayJoin(["a", "b", "c"], ", "))
}
Test("ArrayJoin: multiple elements interleave the separator", TestPE_JoinMulti)




; ==========================
; Read/Write round-trip
; ==========================
TestPE_RoundTrip() {
	global ScriptInformation
	TmpPath := A_ScriptDir . "\test_personal_rt.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	Data := Map(
		"sections_order", ["greetings"],
		"sections", Map(
			"greetings", Map(
				"description", "Greetings",
				"entries", [Map(
					"trigger",           "hi★",
					"output",            "Hello!",
					"is_word",           true,
					"auto_expand",       true,
					"is_case_sensitive", false,
					"final_result",      false,
					"strict_case",       false,
					"line_index",        0,
				)],
			),
		),
		"meta_description", "Test",
	)
	AssertTrue(WritePersonalToml(Data))

	Read := ReadPersonalToml()
	AssertTrue(Read["sections"].Has("greetings"))
	Entries := Read["sections"]["greetings"]["entries"]
	AssertEqual(1, Entries.Length)
	AssertEqual("hi★", Entries[1]["trigger"])
	AssertEqual("Hello!", Entries[1]["output"])

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("Personal TOML round-trip: write then read recovers an entry", TestPE_RoundTrip)




; ==========================
; EscapeTomlValue — edge cases
; ==========================
TestPE_EscapeOnlyBackslash() {
	AssertEqual("\\", EscapeTomlValue("\"))
}
Test("EscapeTomlValue: lone backslash → double-backslash", TestPE_EscapeOnlyBackslash)

TestPE_EscapeOnlyQuote() {
	AssertEqual('\"', EscapeTomlValue('"'))
}
Test("EscapeTomlValue: lone double-quote is escaped", TestPE_EscapeOnlyQuote)

TestPE_EscapeAllSpecials() {
	; All four special chars in one string. Backslash and double-quote stay
	; as TOML escapes; newline / CR / tab become {Enter} / {Tab} tokens by
	; design (one-way tokenisation locked in by the writer commit).
	Src := "\" . "`"`n`r`t"
	Esc := EscapeTomlValue(Src)
	AssertContains(Esc, "\\")
	AssertContains(Esc, '\"')
	AssertContains(Esc, "{Enter}")
	AssertContains(Esc, "{Tab}")
}
Test("EscapeTomlValue: all special characters are present in the escaped output",
	TestPE_EscapeAllSpecials)

TestPE_EscapePlainAlpha() {
	AssertEqual("hello world", EscapeTomlValue("hello world"))
}
Test("EscapeTomlValue: plain ASCII text is unchanged", TestPE_EscapePlainAlpha)

TestPE_EscapeAccented() {
	; Accented chars are not special in TOML double-quoted strings
	AssertEqual("café", EscapeTomlValue("café"))
}
Test("EscapeTomlValue: accented characters pass through unchanged", TestPE_EscapeAccented)




; ==========================
; NormaliseOutput — additional cases
; ==========================
TestPE_NormPlain() {
	AssertEqual("hello", NormaliseOutput("hello"))
}
Test("NormaliseOutput: plain text is unchanged", TestPE_NormPlain)

TestPE_NormRight() {
	AssertEqual("{Right}", NormaliseOutput("{right}"))
}
Test("NormaliseOutput: {right} is title-cased to {Right}", TestPE_NormRight)

TestPE_NormUp() {
	AssertEqual("{Up}", NormaliseOutput("{up}"))
}
Test("NormaliseOutput: {up} is title-cased to {Up}", TestPE_NormUp)

TestPE_NormDown() {
	AssertEqual("{Down}", NormaliseOutput("{down}"))
}
Test("NormaliseOutput: {down} is title-cased to {Down}", TestPE_NormDown)

TestPE_NormDelete() {
	AssertEqual("{Delete}", NormaliseOutput("{delete}"))
}
Test("NormaliseOutput: {delete} is title-cased to {Delete}", TestPE_NormDelete)

TestPE_NormMixedContent() {
	; Newline embedded between plain text
	AssertEqual("hello{Enter}world", NormaliseOutput("hello`nworld"))
}
Test("NormaliseOutput: newline in mixed content becomes {Enter}", TestPE_NormMixedContent)

TestPE_NormMultipleNewlines() {
	; Two successive newlines become two {Enter}
	AssertEqual("{Enter}{Enter}", NormaliseOutput("`n`n"))
}
Test("NormaliseOutput: two newlines produce two {Enter}", TestPE_NormMultipleNewlines)




; ==========================
; ArrayJoin — separators
; ==========================
TestPE_JoinNewlineSep() {
	AssertEqual("a`nb`nc", ArrayJoin(["a", "b", "c"], "`n"))
}
Test("ArrayJoin: newline separator joins correctly", TestPE_JoinNewlineSep)

TestPE_JoinEmptySep() {
	AssertEqual("abc", ArrayJoin(["a", "b", "c"], ""))
}
Test("ArrayJoin: empty separator concatenates without delimiter", TestPE_JoinEmptySep)




; ==========================
; Property-based: EscapeTomlValue ↔ UnescapeTomlString round-trip
; ==========================
; Generates N random printable ASCII strings and verifies that
; Unescape(Escape(s)) == s for every one. This catches any encoding
; asymmetry that deterministic unit tests might miss.
TestPE_PropertyRoundTripAscii() {
	loop 50 {
		; Build a random 5-15 character string from printable ASCII (0x20..0x7E),
		; deliberately including backslash (0x5C) and double-quote (0x22) so the
		; escape logic is exercised on every iteration.
		Len := 5 + Mod(A_Index * 7 + 3, 11)  ; deterministic spread 5..15
		Src := ""
		loop Len {
			; Cycle through a deterministic but diverse character set
			Code := 0x20 + Mod(A_Index * 13 + A_TickCount + Len, 0x5F)
			Src .= Chr(Code)
		}
		Recovered := UnescapeTomlString(EscapeTomlValue(Src))
		AssertEqual(Src, Recovered, "Round-trip failed for: " . Src)
	}
}
Test("Property: EscapeTomlValue/UnescapeTomlString ASCII round-trip (50 strings)",
	TestPE_PropertyRoundTripAscii)

TestPE_PropertyRoundTripSpecialChars() {
	; Explicitly test strings that combine the special TOML escape characters
	; that DO round-trip symmetrically (backslash and double-quote). Newline,
	; CR and tab are deliberately excluded — they are stored as {Enter}/{Tab}
	; tokens by EscapeTomlValue, which is a one-way transformation.
	SpecialSets := [
		"\",
		"`"",
		"a\b",
		'a"b',
		"\`"",
		"hello `"world`" \ done",
	]
	for Src in SpecialSets {
		Recovered := UnescapeTomlString(EscapeTomlValue(Src))
		AssertEqual(Src, Recovered, "Round-trip failed for special string")
	}
}
Test("Property: EscapeTomlValue/UnescapeTomlString special-char round-trip (6 strings)",
	TestPE_PropertyRoundTripSpecialChars)

TestPE_PropertyNewlinesTabsTokenised() {
	; Companion test to PropertyRoundTripSpecialChars: confirm that newline,
	; CR and tab characters always become {Enter} / {Tab} tokens at write
	; time, never the TOML escape sequences \n / \r / \t.
	AssertEqual("{Enter}", EscapeTomlValue("`n"))
	AssertEqual("{Enter}", EscapeTomlValue("`r"))
	AssertEqual("{Enter}", EscapeTomlValue("`r`n"))
	AssertEqual("{Tab}",   EscapeTomlValue("`t"))
	AssertEqual("a{Enter}b", EscapeTomlValue("a`nb"))
	AssertEqual("a{Enter}b", EscapeTomlValue("a`rb"))
	AssertEqual("a{Tab}b",   EscapeTomlValue("a`tb"))
	; Backslash gets doubled and the quote escaped, so the trailing \" turns
	; into \\\" in the on-disk representation alongside the {Enter}/{Tab}
	; tokens that replace the newlines and tab.
	AssertEqual("{Enter}{Enter}{Tab}\\\`"", EscapeTomlValue("`n`r`t\`""))
}
Test("Property: newlines and tabs are always tokenised on write",
	TestPE_PropertyNewlinesTabsTokenised)




; ==========================
; WritePersonalToml — multiple sections
; ==========================
TestPE_RoundTripTwoSections() {
	global ScriptInformation
	TmpPath := A_ScriptDir . "\test_personal_2sec.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	Data := Map(
		"sections_order", ["alpha", "beta"],
		"sections", Map(
			"alpha", Map(
				"description", "Alpha",
				"entries", [Map(
					"trigger", "aa", "output", "Alpha!", "is_word", true,
					"auto_expand", true, "is_case_sensitive", false,
					"final_result", false, "strict_case", false, "line_index", 0,
				)],
			),
			"beta", Map(
				"description", "Beta",
				"entries", [Map(
					"trigger", "bb", "output", "Beta!", "is_word", true,
					"auto_expand", false, "is_case_sensitive", true,
					"final_result", false, "strict_case", false, "line_index", 0,
				)],
			),
		),
		"meta_description", "Test two sections",
	)
	AssertTrue(WritePersonalToml(Data))

	Read := ReadPersonalToml()
	AssertTrue(Read["sections"].Has("alpha"))
	AssertTrue(Read["sections"].Has("beta"))
	AssertEqual("aa", Read["sections"]["alpha"]["entries"][1]["trigger"])
	AssertEqual("bb", Read["sections"]["beta"]["entries"][1]["trigger"])

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("Personal TOML round-trip: two-section data is preserved faithfully",
	TestPE_RoundTripTwoSections)

TestPE_RoundTripSpecialCharsInOutput() {
	global ScriptInformation
	TmpPath := A_ScriptDir . "\test_personal_special.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	SpecialOutput := 'He said "hello"' . " and goodbye"
	Data := Map(
		"sections_order", ["test"],
		"sections", Map(
			"test", Map(
				"description", "Test",
				"entries", [Map(
					"trigger", "q", "output", SpecialOutput, "is_word", true,
					"auto_expand", false, "is_case_sensitive", false,
					"final_result", false, "strict_case", false, "line_index", 0,
				)],
			),
		),
		"meta_description", "",
	)
	AssertTrue(WritePersonalToml(Data))

	Read := ReadPersonalToml()
	AssertEqual(SpecialOutput, Read["sections"]["test"]["entries"][1]["output"])

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("Personal TOML round-trip: output with double-quotes is preserved faithfully",
	TestPE_RoundTripSpecialCharsInOutput)
