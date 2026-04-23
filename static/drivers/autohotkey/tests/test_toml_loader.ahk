; static/drivers/autohotkey/tests/test_toml_loader.ahk

; ==============================================================================
; MODULE: TOML Loader Tests
; DESCRIPTION:
; Covers UnescapeTomlString, FoldAsciiLower and the file caching behaviour
; of ReadTomlFile.
; ==============================================================================




; ==========================
; UnescapeTomlString
; ==========================
TestTL_UnescapeEmpty() {
	AssertEqual("", UnescapeTomlString(""))
}
Test("UnescapeTomlString: empty string round-trips", TestTL_UnescapeEmpty)

TestTL_UnescapePlain() {
	AssertEqual("hello", UnescapeTomlString("hello"))
}
Test("UnescapeTomlString: plain string round-trips", TestTL_UnescapePlain)

TestTL_UnescapeBackslash() {
	AssertEqual("a\b", UnescapeTomlString("a\\b"))
}
Test("UnescapeTomlString: backslash-backslash decodes to one backslash",
	TestTL_UnescapeBackslash)

TestTL_UnescapeQuote() {
	AssertEqual('a"b', UnescapeTomlString('a\"b'))
}
Test("UnescapeTomlString: backslash-quote decodes to bare quote", TestTL_UnescapeQuote)

TestTL_UnescapeNewline() {
	AssertEqual("a`nb", UnescapeTomlString("a\nb"))
}
Test("UnescapeTomlString: backslash-n decodes to newline", TestTL_UnescapeNewline)

TestTL_UnescapeTab() {
	AssertEqual("a`tb", UnescapeTomlString("a\tb"))
}
Test("UnescapeTomlString: backslash-t decodes to tab", TestTL_UnescapeTab)

TestTL_UnescapeCR() {
	AssertEqual("a`rb", UnescapeTomlString("a\rb"))
}
Test("UnescapeTomlString: backslash-r decodes to carriage return", TestTL_UnescapeCR)

TestTL_UnescapeUnknown() {
	AssertEqual("axb", UnescapeTomlString("a\xb"))
}
Test("UnescapeTomlString: unknown escape passes through next character",
	TestTL_UnescapeUnknown)

TestTL_UnescapeTrailing() {
	AssertEqual("a\", UnescapeTomlString("a\"))
}
Test("UnescapeTomlString: trailing backslash is preserved", TestTL_UnescapeTrailing)




; ==========================
; FoldAsciiLower
; ==========================
TestTL_FoldAscii() {
	AssertEqual("hello", FoldAsciiLower("HELLO"))
}
Test("FoldAsciiLower: ASCII string is just lowercased", TestTL_FoldAscii)

TestTL_FoldFrenchE() {
	AssertEqual("aeee", FoldAsciiLower("àéèê"))
}
Test("FoldAsciiLower: à é è ê fold to a e e e", TestTL_FoldFrenchE)

TestTL_FoldCedilla() {
	AssertEqual("c", FoldAsciiLower("ç"))
}
Test("FoldAsciiLower: ç folds to c", TestTL_FoldCedilla)

TestTL_FoldCapitalIE() {
	AssertEqual("ie", FoldAsciiLower("IÉ"))
}
Test("FoldAsciiLower: capitalised IÉ becomes ie", TestTL_FoldCapitalIE)

TestTL_FoldAllAccents() {
	AssertEqual("a", FoldAsciiLower("â"))
	AssertEqual("a", FoldAsciiLower("ä"))
	AssertEqual("e", FoldAsciiLower("ë"))
	AssertEqual("i", FoldAsciiLower("î"))
	AssertEqual("i", FoldAsciiLower("ï"))
	AssertEqual("o", FoldAsciiLower("ô"))
	AssertEqual("o", FoldAsciiLower("ö"))
	AssertEqual("u", FoldAsciiLower("ù"))
	AssertEqual("u", FoldAsciiLower("û"))
	AssertEqual("u", FoldAsciiLower("ü"))
}
Test("FoldAsciiLower: covers all 11 documented accents", TestTL_FoldAllAccents)




; ==========================
; ReadTomlFile cache
; ==========================
TestTL_ReadTomlCaches() {
	TmpPath := A_ScriptDir . "\test_toml_cache.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("first = 1`r`n", TmpPath, "UTF-8")
	First := ReadTomlFile(TmpPath)
	AssertContains(First, "first = 1")

	; Mutate the file on disk; cached read must still return the original.
	FileAppend("second = 2`r`n", TmpPath, "UTF-8")
	Second := ReadTomlFile(TmpPath)
	AssertEqual(First, Second)

	FileDelete(TmpPath)
}
Test("ReadTomlFile: caches content per absolute path", TestTL_ReadTomlCaches)
