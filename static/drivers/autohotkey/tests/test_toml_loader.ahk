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




; ==========================
; UnescapeTomlString — additional cases
; ==========================
TestTL_UnescapeMultipleEscapes() {
	; \n\t in sequence
	AssertEqual("`n`t", UnescapeTomlString("\n\t"))
}
Test("UnescapeTomlString: multiple escapes in sequence", TestTL_UnescapeMultipleEscapes)

TestTL_UnescapeDoubleBackslash() {
	; \\\\ → two backslashes in the result
	AssertEqual("a\\b\\c", UnescapeTomlString("a\\\\b\\\\c"))
}
Test("UnescapeTomlString: double-backslash pairs decode correctly",
	TestTL_UnescapeDoubleBackslash)

TestTL_UnescapeQuoteInside() {
	; a\"b\"c → a"b"c
	AssertEqual('a"b"c', UnescapeTomlString('a\"b\"c'))
}
Test("UnescapeTomlString: multiple escaped quotes in one string",
	TestTL_UnescapeQuoteInside)

TestTL_UnescapeMixed() {
	; a\nb\tc → a<newline>b<tab>c
	AssertEqual("a`nb`tc", UnescapeTomlString("a\nb\tc"))
}
Test("UnescapeTomlString: mixed newline and tab escapes", TestTL_UnescapeMixed)




; ==========================
; FoldAsciiLower — extra accents
; ==========================
TestTL_FoldCircumflexA() {
	AssertEqual("a", FoldAsciiLower("â"))
}
Test("FoldAsciiLower: â folds to a", TestTL_FoldCircumflexA)

TestTL_FoldUmlautA() {
	AssertEqual("a", FoldAsciiLower("ä"))
}
Test("FoldAsciiLower: ä folds to a", TestTL_FoldUmlautA)

TestTL_FoldUmlautE() {
	AssertEqual("e", FoldAsciiLower("ë"))
}
Test("FoldAsciiLower: ë folds to e", TestTL_FoldUmlautE)

TestTL_FoldCircumflexI() {
	AssertEqual("i", FoldAsciiLower("î"))
}
Test("FoldAsciiLower: î folds to i", TestTL_FoldCircumflexI)

TestTL_FoldUmlautI() {
	AssertEqual("i", FoldAsciiLower("ï"))
}
Test("FoldAsciiLower: ï folds to i", TestTL_FoldUmlautI)

TestTL_FoldCircumflexO() {
	AssertEqual("o", FoldAsciiLower("ô"))
}
Test("FoldAsciiLower: ô folds to o", TestTL_FoldCircumflexO)

TestTL_FoldUmlautO() {
	AssertEqual("o", FoldAsciiLower("ö"))
}
Test("FoldAsciiLower: ö folds to o", TestTL_FoldUmlautO)

TestTL_FoldGraveU() {
	AssertEqual("u", FoldAsciiLower("ù"))
}
Test("FoldAsciiLower: ù folds to u", TestTL_FoldGraveU)

TestTL_FoldCircumflexU() {
	AssertEqual("u", FoldAsciiLower("û"))
}
Test("FoldAsciiLower: û folds to u", TestTL_FoldCircumflexU)

TestTL_FoldUmlautU() {
	AssertEqual("u", FoldAsciiLower("ü"))
}
Test("FoldAsciiLower: ü folds to u", TestTL_FoldUmlautU)

TestTL_FoldEmpty() {
	AssertEqual("", FoldAsciiLower(""))
}
Test("FoldAsciiLower: empty string stays empty", TestTL_FoldEmpty)

TestTL_FoldMixed() {
	AssertEqual("cafe", FoldAsciiLower("Café"))
}
Test("FoldAsciiLower: mixed accented + ASCII string", TestTL_FoldMixed)

TestTL_FoldNoAccents() {
	AssertEqual("hello", FoldAsciiLower("HELLO"))
}
Test("FoldAsciiLower: pure ASCII input is just lowercased", TestTL_FoldNoAccents)




; ==========================
; ReadTomlFile — multiple files don't cross-contaminate
; ==========================
TestTL_ReadTomlTwoDifferentFiles() {
	TmpA := A_ScriptDir . "\test_toml_a.toml"
	TmpB := A_ScriptDir . "\test_toml_b.toml"
	for _, P in [TmpA, TmpB] {
		if FileExist(P) {
			FileDelete(P)
		}
	}
	FileAppend("key_a = 1`r`n", TmpA, "UTF-8")
	FileAppend("key_b = 2`r`n", TmpB, "UTF-8")
	ContentA := ReadTomlFile(TmpA)
	ContentB := ReadTomlFile(TmpB)
	AssertContains(ContentA, "key_a")
	AssertFalse(InStr(ContentA, "key_b") > 0)
	AssertContains(ContentB, "key_b")
	AssertFalse(InStr(ContentB, "key_a") > 0)
	FileDelete(TmpA)
	FileDelete(TmpB)
}
Test("ReadTomlFile: two different files are cached independently",
	TestTL_ReadTomlTwoDifferentFiles)




; ==========================
; LoadHotstringsSection — with a synthetic TOML file
; ==========================
TestTL_LoadHotstringsBasic() {
	; Build a minimal TOML file with one hotstring entry
	TmpPath := A_ScriptDir . "\test_hstr_load.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	; Use is_case_sensitive=true so CreateHotstring (non-variant) is called
	Content := "[[greetings]]`r`n"
	         . '"hi" = { output = "hello", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n'
	FileAppend(Content, TmpPath, "UTF-8")

	; Redirect to our temp file via ScriptInformation["PersonalTomlPath"]
	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	LoadHotstringsSection("personal", "greetings", { TimeActivationSeconds: 0 })

	; Exactly one hotstring must have been registered
	AssertEqual(1, _Stub_HotstringRegistrations.Length)
	AssertContains(_Stub_HotstringRegistrations[1].spec, "hi")

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: registers one hotstring from a synthetic TOML file",
	TestTL_LoadHotstringsBasic)

TestTL_LoadHotstringsMissingSection() {
	TmpPath := A_ScriptDir . "\test_hstr_nosec.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[[other]]`r`n" . '"x" = { output = "y", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n',
		TmpPath, "UTF-8")

	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	; Request a section that does not exist in the file
	LoadHotstringsSection("personal", "greetings", { TimeActivationSeconds: 0 })

	; Nothing should have been registered
	AssertEqual(0, _Stub_HotstringRegistrations.Length)

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: registers nothing when section is absent",
	TestTL_LoadHotstringsMissingSection)

TestTL_LoadHotstringsAutoExpand() {
	TmpPath := A_ScriptDir . "\test_hstr_auto.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	; auto_expand=true → Flags should contain "*"
	FileAppend("[[greet]]`r`n" . '"yo" = { output = "yo!", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n',
		TmpPath, "UTF-8")

	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	LoadHotstringsSection("personal", "greet", { TimeActivationSeconds: 0 })

	AssertEqual(1, _Stub_HotstringRegistrations.Length)
	AssertContains(_Stub_HotstringRegistrations[1].spec, "*")

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: auto_expand=true produces a * flag in the trigger spec",
	TestTL_LoadHotstringsAutoExpand)

TestTL_LoadHotstringsCommentedLines() {
	TmpPath := A_ScriptDir . "\test_hstr_comment.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	Content := "[[sect]]`r`n"
	         . "# this line is a comment and should be skipped`r`n"
	         . '"real" = { output = "kept", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n'
	FileAppend(Content, TmpPath, "UTF-8")

	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	LoadHotstringsSection("personal", "sect", { TimeActivationSeconds: 0 })

	AssertEqual(1, _Stub_HotstringRegistrations.Length)

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: commented-out lines are skipped",
	TestTL_LoadHotstringsCommentedLines)

TestTL_LoadHotstringsMultipleEntries() {
	TmpPath := A_ScriptDir . "\test_hstr_multi.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	Content := "[[words]]`r`n"
	         . '"aa" = { output = "alpha", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n'
	         . '"bb" = { output = "beta",  is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n'
	         . '"cc" = { output = "gamma", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n'
	FileAppend(Content, TmpPath, "UTF-8")

	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	LoadHotstringsSection("personal", "words", { TimeActivationSeconds: 0 })

	AssertEqual(3, _Stub_HotstringRegistrations.Length)

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: registers all three entries from a three-entry section",
	TestTL_LoadHotstringsMultipleEntries)
