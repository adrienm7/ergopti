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




; ==========================================
; BootstrapPersonalFeatures
; ==========================================

; Helper that writes a synthetic personal_hotstrings.toml, runs
; BootstrapPersonalFeatures(), and returns the resulting Features["Personal"]
; for assertions. Restores ScriptInformation and Features afterwards.
TestTL_RunBootstrap(TomlContent) {
	global Features, ScriptInformation
	TmpPath := A_Temp . "\test_personal_bootstrap_" . A_Now . "_" . A_TickCount . ".toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend(TomlContent, TmpPath, "UTF-8")

	OldPath := ScriptInformation.Has("PersonalTomlPath") ? ScriptInformation["PersonalTomlPath"] : ""
	OldPersonal := Features.Has("Personal") ? Features["Personal"] : ""
	ScriptInformation["PersonalTomlPath"] := TmpPath
	if Features.Has("Personal") {
		Features.Delete("Personal")
	}
	; Clear the file cache so the synthetic file is actually re-read each run
	global _TomlFileCache
	if _TomlFileCache.Has(TmpPath) {
		_TomlFileCache.Delete(TmpPath)
	}

	BootstrapPersonalFeatures()
	Result := Features.Has("Personal") ? Features["Personal"] : Map()

	; Cleanup
	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
	if OldPersonal != "" {
		Features["Personal"] := OldPersonal
	} else if Features.Has("Personal") {
		Features.Delete("Personal")
	}
	return Result
}

TestTL_BootstrapRegistersAllSections() {
	Toml := "[_meta]`r`nsections_order = [`"greetings`", `"code`"]`r`n`r`n"
	Toml .= "[_meta.sections]`r`ngreetings = `"Greetings shortcuts`"`r`ncode = `"Code shortcuts`"`r`n`r`n"
	Toml .= "[[greetings]]`r`n`r`n[[code]]`r`n"
	Personal := TestTL_RunBootstrap(Toml)
	AssertTrue(Personal.Count > 0, "Personal map should be non-empty after bootstrap")
	AssertTrue(Personal.Has("Greetings"), "Greetings section should be registered")
	AssertTrue(Personal.Has("Code"), "Code section should be registered")
}
Test("BootstrapPersonalFeatures: every [_meta.sections] entry creates a feature",
	TestTL_BootstrapRegistersAllSections)

TestTL_BootstrapEnabledByDefault() {
	Toml := "[_meta.sections]`r`ngreetings = `"G`"`r`n`r`n[[greetings]]`r`n"
	Personal := TestTL_RunBootstrap(Toml)
	AssertTrue(Personal.Has("Greetings"), "Greetings must exist before checking Enabled")
	AssertTrue(Personal["Greetings"].Enabled, "section should be enabled by default")
}
Test("BootstrapPersonalFeatures: sections are enabled by default",
	TestTL_BootstrapEnabledByDefault)

TestTL_BootstrapPreservesTomlSection() {
	; The lowercase TOML key is stored on TomlSection so the loader can find
	; the [[section]] block even when the Feature key was PascalCased.
	Toml := "[_meta.sections]`r`nmySection = `"Test`"`r`n`r`n[[mySection]]`r`n"
	Personal := TestTL_RunBootstrap(Toml)
	AssertTrue(Personal.Has("MySection"), "PascalCase feature key expected — bootstrap may have failed silently")
	if !Personal.Has("MySection") {
		return
	}
	AssertEqual("mysection", Personal["MySection"].TomlSection,
		"TomlSection should retain the original lowercase key")
}
Test("BootstrapPersonalFeatures: TomlSection stores the original lowercase key",
	TestTL_BootstrapPreservesTomlSection)

TestTL_BootstrapMissingFile() {
	global Features, ScriptInformation
	OldPath := ScriptInformation.Has("PersonalTomlPath") ? ScriptInformation["PersonalTomlPath"] : ""
	ScriptInformation["PersonalTomlPath"] := A_Temp . "\definitely_does_not_exist_" . A_Now . ".toml"
	if Features.Has("Personal") {
		Features.Delete("Personal")
	}

	BootstrapPersonalFeatures()
	; Should not have created the Personal map for a missing file
	AssertFalse(Features.Has("Personal") and Features["Personal"].Count > 0,
		"missing file should not populate Features.Personal")

	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("BootstrapPersonalFeatures: missing TOML file is silently ignored",
	TestTL_BootstrapMissingFile)




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


; ==========================================
; ApplyConfigTomlOverrides
; ==========================================

TestTL_OverridesScriptSection() {
	global ScriptInformation
	OldLog := ScriptInformation.Has("LogLevel") ? ScriptInformation["LogLevel"] : ""
	ScriptInformation["LogLevel"] := "INFO"

	TmpPath := A_Temp . "\test_config_override_" . A_Now . "_" . A_TickCount . ".toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[script]`r`nLogLevel = `"DEBUG`"`r`n", TmpPath, "UTF-8")
	global _TomlFileCache
	if _TomlFileCache.Has(TmpPath) {
		_TomlFileCache.Delete(TmpPath)
	}

	Applied := ApplyConfigTomlOverrides(TmpPath)
	AssertTrue(Applied >= 1, "should apply at least one override")
	AssertEqual("DEBUG", ScriptInformation["LogLevel"], "LogLevel must be overridden to DEBUG")

	FileDelete(TmpPath)
	ScriptInformation["LogLevel"] := OldLog
}
Test("ApplyConfigTomlOverrides: [script] section overrides ScriptInformation",
	TestTL_OverridesScriptSection)

TestTL_OverridesMissingFileNoOp() {
	NoFile := A_Temp . "\definitely_missing_" . A_Now . ".toml"
	Applied := ApplyConfigTomlOverrides(NoFile)
	AssertEqual(0, Applied, "missing file should apply 0 overrides without throwing")
}
Test("ApplyConfigTomlOverrides: missing file applies zero overrides",
	TestTL_OverridesMissingFileNoOp)

TestTL_OverridesUnknownPathSkipped() {
	; A dotted path that doesn't resolve in Features should be skipped silently
	; (logged as a warning), not throw.
	TmpPath := A_Temp . "\test_unknown_path_" . A_Now . "_" . A_TickCount . ".toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[features]`r`n`"NoSuchCategory.NoSuchFeature.Enabled`" = false`r`n", TmpPath, "UTF-8")
	global _TomlFileCache
	if _TomlFileCache.Has(TmpPath) {
		_TomlFileCache.Delete(TmpPath)
	}

	; Should not throw; returns 0 because nothing applied
	Applied := ApplyConfigTomlOverrides(TmpPath)
	AssertEqual(0, Applied)

	FileDelete(TmpPath)
}
Test("ApplyConfigTomlOverrides: unknown feature path is skipped silently",
	TestTL_OverridesUnknownPathSkipped)
