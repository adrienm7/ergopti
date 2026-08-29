; static/ergopti_plus/windows/tests/unit/test_toml_loader.ahk

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

; More edges for toml unescape + caching (regression for config load)
TestTL_UnescapeUnicodeEscape() {
	AssertEqual("a\u00E9b", UnescapeTomlString("a\\u00E9b"))  ; basic, may be handled by TOML lib
}
Test("UnescapeTomlString: unicode escape round-trips (basic)", TestTL_UnescapeUnicodeEscape)

TestTL_ReadTomlFileCaching() {
	; Caching behaviour: repeated reads of same path should hit cache (no reparse)
	; (implementation detail tested via no side effects in unit harness)
	Path := A_Temp . "\toml_cache_test.toml"
	try FileDelete(Path)
	FileAppend('key = "value"', Path, "UTF-8")
	Content1 := ReadTomlFile(Path)
	Content2 := ReadTomlFile(Path)
	try FileDelete(Path)
	AssertEqual(Content1, Content2)
}
Test("ReadTomlFile: repeated calls return consistent (cache or re-read safe)", TestTL_ReadTomlFileCaching)

TestTL_UnescapeMultipleEscapes() {
	AssertEqual("a`tb`nc", UnescapeTomlString("a\tb\nc"))
}
Test("UnescapeTomlString: multiple escapes handled", TestTL_UnescapeMultipleEscapes)

; --- Fast-path regression guards (no-backslash input must return verbatim) ---
; The InStr fast-path returns the input untouched whenever it carries no "\".
; These pin that the shortcut is byte-for-byte identical to the full scan for
; the inputs that actually exercise it — plain ASCII, unicode, and strings
; containing characters the escape handler would otherwise inspect (", n, t).
TestTL_UnescapeFastPathUnicode() {
	AssertEqual("café münchen — ★", UnescapeTomlString("café münchen — ★"))
}
Test("UnescapeTomlString: no-backslash unicode returns verbatim (fast-path)",
	TestTL_UnescapeFastPathUnicode)

TestTL_UnescapeFastPathLooksLikeEscapes() {
	; No backslash present, so 'n'/'t'/'"' must stay literal, not decode
	AssertEqual('ntr"quoted"', UnescapeTomlString('ntr"quoted"'))
}
Test("UnescapeTomlString: no-backslash escape-looking chars stay literal (fast-path)",
	TestTL_UnescapeFastPathLooksLikeEscapes)

TestTL_UnescapeTrailingBackslash() {
	; A lone trailing backslash (i == n) hits the slow path's else branch and
	; is preserved verbatim — guards the boundary the fast-path skips over
	AssertEqual("abc\", UnescapeTomlString("abc\"))
}
Test("UnescapeTomlString: trailing lone backslash preserved", TestTL_UnescapeTrailingBackslash)

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
TestTL_UnescapeEscapesSequence() {
	; \n\t in sequence
	AssertEqual("`n`t", UnescapeTomlString("\n\t"))
}
Test("UnescapeTomlString: multiple escapes in sequence", TestTL_UnescapeEscapesSequence)

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
	for P in [TmpA, TmpB] {
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
	; is_case_sensitive = true routes to CreateHotstring, which registers the
	; literal trigger ONLY — hence exactly one spec. (The flag's name is
	; inverted relative to the registrar it selects; the mapping is documented
	; once, at hotstring_builder.ahk's HotstringRegistrarFor.) The false branch
	; registers the whole cased family instead, which
	; TestTL_CaseSensitiveFlagSelectsRegistrar below pins directly.
	Content := "[[greetings]]`r`n"
	         . '"hi" = { output = "hello", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
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

; Behavioural counterpart to the source-scan guard on the is_case_sensitive
; mapping. The flip changed real registration behaviour for personal and
; extension entries, yet every test covering those loaders passed either way —
; the only guard was a meta test asserting the branch's SHAPE, and an existing
; unit test's comment documented the OLD meaning. This pins the observable
; difference: which registrar runs, and how many specs it produces.
TestTL_CaseSensitiveFlagSelectsRegistrar() {
	TmpPath := A_ScriptDir . "\test_hstr_case.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	; is_case_sensitive = FALSE -> CreateCaseSensitiveHotstrings -> the whole
	; cased family (lower / UPPER / Title). auto_expand = false keeps the
	; explicit-variant path, so the family is registered as three specs.
	Content := "[[greetings]]`r`n"
	         . '"hi" = { output = "hello", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`r`n'
	FileAppend(Content, TmpPath, "UTF-8")

	global ScriptInformation
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	ResetHotstringRecorders()
	LoadHotstringsSection("personal", "greetings", { TimeActivationSeconds: 0 })

	AssertEqual(3, _Stub_HotstringRegistrations.Length,
		"is_case_sensitive = false must route to CreateCaseSensitiveHotstrings and register the whole cased family — one spec here means the flag is selecting the literal-only registrar, i.e. the mapping has flipped back")

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("LoadHotstringsSection: is_case_sensitive = false registers the cased family",
	TestTL_CaseSensitiveFlagSelectsRegistrar)

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
	         . '"real" = { output = "kept", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
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
	         . '"aa" = { output = "alpha", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
	         . '"bb" = { output = "beta",  is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
	         . '"cc" = { output = "gamma", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
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

TestTL_LoadExtTomlFileUsesCurrentSection() {
	TmpPath := A_ScriptDir . "\test_ext_loader.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	Content := "[[custom]]`r`n"
	         . '"aa" = { output = "alpha", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
	FileAppend(Content, TmpPath, "UTF-8")

	ResetHotstringRecorders()
	LoadExtTomlFile(TmpPath, "Custom")

	AssertEqual(1, _Stub_HotstringRegistrations.Length)

	FileDelete(TmpPath)
}
Test("LoadExtTomlFile: registers entries without undefined category/section locals",
	TestTL_LoadExtTomlFileUsesCurrentSection)

TestTL_LoadExtSimpleEntriesUnescapeTomlStrings() {
	global _Stub_HotstringRegistrations, _Stub_RecordedSends
	TmpPath := A_ScriptDir . "\test_ext_simple_escapes.toml"
	try {
		try FileDelete(TmpPath)
		FileAppend(
			'[[custom]]`n'
			. 'escapedoutput = "say \"hi\""`n'
			. '"escaped\"trigger" = "value"`n',
			TmpPath, "UTF-8")
		ResetHotstringRecorders()
		LoadExtTomlFile(TmpPath, "Custom")
		AssertTrue(_Stub_HotstringRegistrations.Length >= 2,
			"both escape-aware simple entries must register their variants")
		OutputBinding := 0
		FoundEscapedTrigger := false
		for Binding in _Stub_HotstringRegistrations {
			if InStr(Binding.spec, "escapedoutput") and !IsObject(OutputBinding)
				OutputBinding := Binding
			if InStr(Binding.spec, 'escaped"trigger')
				FoundEscapedTrigger := true
		}
		AssertTrue(IsObject(OutputBinding),
			"the bare simple trigger must register")
		OutputBinding.callback.Call()
		AssertEqual('say "hi"', _Stub_RecordedSends[2].args[1],
			"the engine callback must receive the unescaped output")
		AssertTrue(FoundEscapedTrigger,
			"the engine must receive the unescaped quoted trigger")
	} finally {
		try FileDelete(TmpPath)
		ResetHotstringRecorders()
	}
}
Test("LoadExtTomlFile: simple entries unescape quoted triggers and outputs",
	TestTL_LoadExtSimpleEntriesUnescapeTomlStrings)




; ``BootstrapPersonalFeatures`` was removed in slice 9. Its four tests
; went with it.


; ==========================================
; TomlCoerceValue
; ==========================================

TestTL_CoerceTrueFalse() {
	AssertEqual(1, TomlCoerceValue("true"))
	AssertEqual(0, TomlCoerceValue("false"))
	AssertEqual(1, TomlCoerceValue("  TRUE "))
}
Test("TomlCoerceValue: true/false coerce to 1/0", TestTL_CoerceTrueFalse)

TestTL_CoerceNumber() {
	AssertEqual(42, TomlCoerceValue("42"))
	AssertEqual(-7, TomlCoerceValue("-7"))
	AssertEqual(3.14, TomlCoerceValue("3.14"))
}
Test("TomlCoerceValue: integers and floats are parsed", TestTL_CoerceNumber)

TestTL_CoerceQuotedString() {
	AssertEqual("hello", TomlCoerceValue('"hello"'))
	AssertEqual("a`nb", TomlCoerceValue('"a\nb"'))
}
Test("TomlCoerceValue: quoted strings are unquoted and unescaped",
	TestTL_CoerceQuotedString)




; ==========================
; _ParseEntryPriority — individual per-hotstring priority (top of the cascade)
; ==========================
TestTL_EntryPriorityExplicit() {
	Line := '"abc" = { output = "x", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false, priority = 80 }'
	AssertEqual(80, _ParseEntryPriority(Line, 10),
		"an explicit priority key in the inline table must override the fallback")
}
Test("ParseEntryPriority: explicit priority key overrides the fallback",
	TestTL_EntryPriorityExplicit)

TestTL_EntryPriorityFallback() {
	Line := '"abc" = { output = "x", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }'
	AssertEqual(10, _ParseEntryPriority(Line, 10),
		"no priority key keeps the resolved section/source fallback")
}
Test("ParseEntryPriority: missing priority key keeps the fallback",
	TestTL_EntryPriorityFallback)

TestTL_EntryPriorityIgnoresOutputText() {
	; "priority = 5" sits INSIDE the output string, not as a key (not preceded by
	; { or ,), so it must be ignored and the fallback kept.
	Line := '"abc" = { output = "set priority = 5 now", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }'
	AssertEqual(30, _ParseEntryPriority(Line, 30),
		"a priority-looking substring inside the output value must NOT be parsed as a key")
}
Test("ParseEntryPriority: ignores a priority substring inside the output value",
	TestTL_EntryPriorityIgnoresOutputText)




; ==========================
; _HOTSTRING_ENTRY_PATTERN — must tolerate the optional individual priority key
; ==========================
; Regression: _ParseEntryPriority can only fire on a line that first MATCHES the
; entry pattern. Before the optional priority group was added, an entry carrying
; `priority = N` failed the pattern and was silently dropped at boot — making the
; per-hotstring priority feature a dead no-op. These pin that the pattern accepts
; the key (with and without the optional strict flag) and still captures the rest.
TestTL_EntryPatternAcceptsPriority() {
	global _HOTSTRING_ENTRY_PATTERN
	Line := '"abc" = { output = "x", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false, priority = 80 }'
	AssertTrue(RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &M) > 0,
		"an entry carrying a trailing priority key must still match the boot pattern")
	AssertEqual("80", M[8], "the priority value must be captured by the pattern")
}
Test("HotstringEntryPattern: accepts a trailing priority key",
	TestTL_EntryPatternAcceptsPriority)

TestTL_EntryPatternAcceptsStrictAndPriority() {
	global _HOTSTRING_ENTRY_PATTERN
	Line := '"abc" = { output = "x", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false, is_case_sensitive_strict = true, priority = 90 }'
	AssertTrue(RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &M) > 0,
		"strict + priority together must match the boot pattern")
	AssertEqual("true", M[7], "the strict flag must still be captured")
	AssertEqual("90", M[8], "the priority value must still be captured after the strict flag")
}
Test("HotstringEntryPattern: accepts strict flag followed by priority",
	TestTL_EntryPatternAcceptsStrictAndPriority)

TestTL_EntryPatternPriorityOptional() {
	global _HOTSTRING_ENTRY_PATTERN
	Line := '"abc" = { output = "x", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }'
	AssertTrue(RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &M) > 0,
		"an entry without a priority key must still match (no regression)")
	AssertEqual("", M[8], "the priority capture is empty when the key is absent")
}
Test("HotstringEntryPattern: priority key stays optional",
	TestTL_EntryPatternPriorityOptional)

; ParseTomlGroupConfig must read a file-level [_meta] priority and a per-section
; [_meta.sections.<sec>] priority into the Config struct — these are the
; package-shipped defaults the resolve cascade reads beneath the user override.
TestTL_ParseGroupConfigPriority() {
	global HotstringGroupConfig
	Path := A_Temp . "\toml_group_prio_test.toml"
	try FileDelete(Path)
	FileAppend(
		"[_meta]`npriority = 35`n`n"
		. "[_meta.sections.foo]`npriority = 65`n`n"
		. "[[foo]]`n",
		Path, "UTF-8")
	; Bypass the cache so the fresh file is actually parsed.
	if HotstringGroupConfig.Has(Path)
		HotstringGroupConfig.Delete(Path)
	Cfg := ParseTomlGroupConfig("", Path)
	AssertEqual(35, Cfg.Priority, "file-level [_meta] priority must be parsed")
	AssertTrue(Cfg.Sections.Has("foo"), "the [_meta.sections.foo] block must materialise a section")
	AssertEqual(65, Cfg.Sections["foo"].Priority, "per-section [_meta.sections.foo] priority must be parsed")
	if HotstringGroupConfig.Has(Path)
		HotstringGroupConfig.Delete(Path)
	try FileDelete(Path)
}
Test("ParseTomlGroupConfig: reads [_meta] and per-section priority",
	TestTL_ParseGroupConfigPriority)

TestTL_ParseGroupConfigRejectsNumericOverflow() {
	global HotstringGroupConfig
	Path := A_Temp . "\toml_group_numeric_overflow_test.toml"
	FloatOverflow := "1"
	Loop 309
		FloatOverflow .= "0"
	FloatOverflow .= ".0"
	try {
		try FileDelete(Path)
		FileAppend(
			"[_meta]`ndelay = 18446744073709552116`n"
			. "priority = 18446744073709552116`n`n"
			. "[_meta.sections.foo]`ndelay = " . FloatOverflow . "`n"
			. "priority = 18446744073709552116`n`n"
			. "[_meta.sections.too_long]`ndelay = 4294968`n`n"
			. "[[foo]]`n",
			Path, "UTF-8")
		_ParseTomlGroupConfig_InvalidatePath(Path)
		Cfg := ParseTomlGroupConfig("", Path)
		AssertEqual("", Cfg.Delay,
			"overflowing group delay must not alias a finite duration")
		AssertEqual("", Cfg.Priority,
			"overflowing group priority must not alias a valid rank")
		AssertEqual("", Cfg.Sections["foo"].Delay,
			"non-finite section delay must not be published")
		AssertEqual("", Cfg.Sections["foo"].Priority,
			"overflowing section priority must not be published")
		AssertEqual("", Cfg.Sections["too_long"].Delay,
			"a finite delay beyond TickElapsed must not be published")
	} finally {
		_ParseTomlGroupConfig_InvalidatePath(Path)
		try FileDelete(Path)
	}
}
Test("ParseTomlGroupConfig: numeric overflow cannot alias hotstring metadata",
	TestTL_ParseGroupConfigRejectsNumericOverflow)

TestTL_MetadataHeadersAcceptInlineComments() {
	global HotstringGroupConfig
	Path := A_Temp . "\toml_group_commented_headers_test.toml"
	try {
		try FileDelete(Path)
		FileAppend(
			"[_meta] # package defaults`n"
			. "delay = 0.35`n"
			. 'sections_order = ["foo", "bar"] # display order`n`n'
			. "[_meta.sections.foo] # first section`n"
			. "priority = 65`n`n"
			. "[_meta.section_delays] # compact overrides`n"
			. "bar = 0.75`n`n"
			. "[[foo]]`n",
			Path, "UTF-8")
		if HotstringGroupConfig.Has(Path)
			HotstringGroupConfig.Delete(Path)
		Cfg := ParseTomlGroupConfig("", Path)
		AssertEqual(0.35, Cfg.Delay,
			"commented [_meta] must retain file-level metadata")
		AssertEqual(65, Cfg.Sections["foo"].Priority,
			"commented per-section metadata headers must parse")
		AssertEqual(0.75, Cfg.Sections["bar"].Delay,
			"commented section-delay headers must parse")
		Order := ReadTomlSectionsOrder("", Path)
		AssertEqual(2, Order.Length,
			"commented [_meta] must expose sections_order")
		AssertEqual("foo", Order[1])
		AssertEqual("bar", Order[2])
	} finally {
		if HotstringGroupConfig.Has(Path)
			HotstringGroupConfig.Delete(Path)
		try FileDelete(Path)
	}
}
Test("toml metadata: inline-commented headers parse in both readers",
	TestTL_MetadataHeadersAcceptInlineComments)
