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
	AssertEqual("a\nb", EscapeTomlValue("a`nb"))
}
Test("EscapeTomlValue: newline becomes \\n", TestPE_EscapeNewline)

TestPE_EscapeTab() {
	AssertEqual("a\tb", EscapeTomlValue("a`tb"))
}
Test("EscapeTomlValue: tab becomes \\t", TestPE_EscapeTab)

TestPE_EscapeCR() {
	AssertEqual("a\rb", EscapeTomlValue("a`rb"))
}
Test("EscapeTomlValue: carriage return becomes \\r", TestPE_EscapeCR)

TestPE_EscapeRoundTrip() {
	Original := "Mix `nof\things\rand `"quotes`" and tabs`t and slashes\\."
	Recovered := UnescapeTomlString(EscapeTomlValue(Original))
	AssertEqual(Original, Recovered)
}
Test("Escape/Unescape round-trip preserves the value", TestPE_EscapeRoundTrip)




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
