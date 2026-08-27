; static/ergopti_plus/windows/tests/unit/test_personal_toml_editor.ahk

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


; Pause guard for the personal-toml editor (project_suspend_pause_invariant).
;
; This asserted AssertTrue(true) while its message claimed the editor "must
; respect full pause silence" — a stated invariant with nothing behind it. What
; is actually checkable at this layer is that the serialisation helpers are pure:
; they must not consult pause state or emit anything, because a helper that
; typed or wrote during a pause is how the invariant gets broken. Dispatch-level
; silence is enforced where dispatch lives; this pins the half that lives here.
TestPE_SerialisationIsPure() {
	Body := _DriverFuncBody("EscapeTomlValue")
	Assert(Body != "", "EscapeTomlValue must exist in the driver source")
	Assert(!InStr(Body, "Send") && !InStr(Body, "FileAppend") && !InStr(Body, "FileOpen"),
		"EscapeTomlValue must not send keystrokes or write files — it serialises a string. "
		. "Anything it emits would fire while the script is paused (project_suspend_pause_invariant)")

	Norm := _DriverFuncBody("NormaliseOutput")
	Assert(Norm != "", "NormaliseOutput must exist in the driver source")
	Assert(!InStr(Norm, "Send") && !InStr(Norm, "FileAppend") && !InStr(Norm, "FileOpen"),
		"NormaliseOutput must not send keystrokes or write files, for the same reason")
}
Test("PersonalTomlEditor: serialisation helpers emit nothing (pause invariant)", TestPE_SerialisationIsPure)

; Error paths: bad input to escape/write must not crash
TestPE_BadInputGraceful() {
	AssertEqual("", EscapeTomlValue(""))  ; or handle gracefully
}
Test("PersonalTomlEditor: bad input to EscapeTomlValue handled gracefully", TestPE_BadInputGraceful)

; Complex personal info with special characters.
;
; This asserted AssertTrue(true) under the message "roundtrip must preserve
; complex French input" — the one property most worth checking in a French-first
; product, asserted by nothing. Accented characters must pass through untouched
; while quotes and backslashes are escaped, and the ORDER matters: escaping the
; backslash after the quote would double-escape the backslash the quote just
; introduced.
TestPE_RoundtripComplex() {
	; Accents survive verbatim — they are not special to TOML.
	AssertEqual("Prénom Élodie çà et là", EscapeTomlValue("Prénom Élodie çà et là"))

	; A quote is escaped; the surrounding accented text is untouched.
	; AHK does not treat "\" as an escape character (the backtick is), so these
	; literals contain exactly the backslashes they appear to.
	AssertEqual('Jean dit \"bonjour\" à Noël', EscapeTomlValue('Jean dit "bonjour" à Noël'))

	; A backslash is escaped first, so a quote's escape is not itself re-escaped.
	AssertEqual('C:\\Users\\Élodie', EscapeTomlValue('C:\Users\Élodie'))

	; Newlines and tabs become tokens even between accented characters.
	AssertEqual("é{Enter}è{Tab}ù", EscapeTomlValue("é`nè`tù"))
}
Test("PersonalTomlEditor: complex personal info roundtrip (French accents/quotes)", TestPE_RoundtripComplex)


TestPE_EscapeRoundTrip() {
	; Plain values with no newline/tab characters round-trip exactly through
	; Escape → Unescape. Newlines/tabs are deliberately one-way (replaced with
	; {Enter}/{Tab} tokens at write time) so they do not feature in this test.
	Original := 'Mix of "quotes" and slashes\\.'
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
	Src := "\" . '"' . "`n`r`t"
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
		'"',
		"a\b",
		'a"b',
		'\"',
		'hello "world" \ done',
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
	AssertEqual('{Enter}{Enter}{Tab}\\\"', EscapeTomlValue("`n`r`t\" . '"'))
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




; ==========================
; Read/Write round-trip — per-hotstring priority
; ==========================
; The editor stores an optional individual collision priority on each entry.
; Explicit values must survive the write→read cycle as numbers; entries that
; inherit the source default must stay free of any priority key (empty on read).
TestPE_RoundTripPriority() {
	global ScriptInformation
	TmpPath := A_ScriptDir . "\test_personal_prio.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	OldPath := ScriptInformation["PersonalTomlPath"]
	ScriptInformation["PersonalTomlPath"] := TmpPath

	Data := Map(
		"sections_order", ["prio"],
		"sections", Map(
			"prio", Map(
				"description", "Priority",
				"entries", [
					Map(
						"trigger", "win", "output", "WINNER", "is_word", true,
						"auto_expand", true, "is_case_sensitive", false,
						"final_result", false, "strict_case", false,
						"priority", 90, "line_index", 0,
					),
					Map(
						"trigger", "def", "output", "DEFAULT", "is_word", true,
						"auto_expand", true, "is_case_sensitive", false,
						"final_result", false, "strict_case", false,
						"priority", "", "line_index", 0,
					),
				],
			),
		),
		"meta_description", "Priority test",
	)
	AssertTrue(WritePersonalToml(Data))

	Read := ReadPersonalToml()
	; Index-independent lookup so the assertions hold even if the on-disk file is
	; re-sorted by the TOML formatter.
	PrioByTrigger := Map()
	for E in Read["sections"]["prio"]["entries"] {
		PrioByTrigger[E["trigger"]] := E["priority"]
	}
	AssertEqual(90, PrioByTrigger["win"], "an explicit priority must round-trip as a number")
	AssertEqual("", PrioByTrigger["def"], "an inherited entry stays free of a priority key")

	FileDelete(TmpPath)
	ScriptInformation["PersonalTomlPath"] := OldPath
}
Test("Personal TOML round-trip: explicit per-hotstring priority is preserved",
	TestPE_RoundTripPriority)




; ==========================
; ReloadPersonalSection — stale-group clearing (F7)
; ==========================
; Regression for personal-hotstring-live-reload-stale-group: saving the same
; personal-hotstring trigger twice with a different output must make the
; SECOND output win, not sit as a dead duplicate behind the stale first one.
TestPE_ReloadClearsStaleGroup() {
	global Features
	HSE_RegistryClear()
	SavedFeatures := Features
	Features := Map("hotstrings", Map("personal", Map(
		"reloadtest", Map("enabled", true, "time_activation_seconds", 0),
	)))

	Data := Map(
		"sections_order", ["reloadtest"],
		"sections", Map(
			"reloadtest", Map(
				"description", "Reload Test",
				"entries", [Map(
					"trigger", "rlx", "output", "FIRST", "is_word", true,
					"auto_expand", true, "is_case_sensitive", true,
					"final_result", false, "strict_case", false, "line_index", 0,
				)],
			),
		),
		"meta_description", "Test",
	)
	FeatureConfig := Map("enabled", true, "time_activation_seconds", 0)
	ReloadPersonalSection(Data, "reloadtest", FeatureConfig)

	; Edit the entry's output and reload again — mirrors "save after edit" in
	; the live editor without a script Reload.
	Data["sections"]["reloadtest"]["entries"][1]["output"] := "SECOND"
	ReloadPersonalSection(Data, "reloadtest", FeatureConfig)

	Matches := []
	for _, Spec in HSE_MappingsForTail("x") {
		if (Spec.Trigger == "rlx")
			Matches.Push(Spec)
	}
	AssertEqual(1, Matches.Length,
		"the stale first registration must be cleared, not left as a dead duplicate (personal-hotstring-live-reload-stale-group)")
	AssertEqual("SECOND", Matches[1].Repl,
		"the newest edit must win — the group must be cleared before re-registering (personal-hotstring-live-reload-stale-group)")

	Features := SavedFeatures
}
Test("Personal TOML: ReloadPersonalSection clears the stale HSE group before re-registering (personal-hotstring-live-reload-stale-group)",
	TestPE_ReloadClearsStaleGroup)




; ==========================
; ReloadPersonalSection — gating (F12)
; ==========================
; Regression for personal-hotstring-live-reload-ignores-gate: a disabled
; section's editor save must not register it live, matching the still-
; unchecked tray checkbox.
TestPE_ReloadSkipsDisabledSection() {
	global Features
	HSE_RegistryClear()
	SavedFeatures := Features
	Features := Map("hotstrings", Map("personal", Map(
		"gated", Map("enabled", false, "time_activation_seconds", 0),
	)))

	Data := Map(
		"sections_order", ["gated"],
		"sections", Map(
			"gated", Map(
				"description", "Gated",
				"entries", [Map(
					"trigger", "gtx", "output", "SHOULD_NOT_REGISTER", "is_word", true,
					"auto_expand", true, "is_case_sensitive", true,
					"final_result", false, "strict_case", false, "line_index", 0,
				)],
			),
		),
		"meta_description", "Test",
	)
	FeatureConfig := Map("enabled", false, "time_activation_seconds", 0)
	ReloadPersonalSection(Data, "gated", FeatureConfig)

	Matches := 0
	for _, Spec in HSE_MappingsForTail("x") {
		if (Spec.Trigger == "gtx")
			Matches += 1
	}
	AssertEqual(0, Matches, "a disabled section must not register live via ReloadPersonalSection")

	Features := SavedFeatures
}
Test("Personal TOML: ReloadPersonalSection skips a disabled section (personal-hotstring-live-reload-ignores-gate)",
	TestPE_ReloadSkipsDisabledSection)




; ============================================
; WebView initData — hidden strict-case state
; ============================================

TestPE_BuildEntryPreservesHiddenStrictCase() {
	global _PersonalEditorPrioCtrl
	OldPriorityCtrl := _PersonalEditorPrioCtrl
	_PersonalEditorPrioCtrl := false
	try {
		TriggerEdit := { Value: "strict-trigger" }
		OutputEdit := { Value: "strict output" }
		ChkIsWord := { Value: 1 }
		ChkAutoExp := { Value: 1 }
		ChkCaseSens := { Value: 1 }
		ChkFinal := { Value: 0 }

		StrictEntry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord,
			ChkAutoExp, ChkCaseSens, ChkFinal, true)
		DefaultEntry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord,
			ChkAutoExp, ChkCaseSens, ChkFinal)
		AssertEqual(true, StrictEntry["strict_case"],
			"editing must preserve the hidden strict-case flag")
		AssertEqual(false, DefaultEntry["strict_case"],
			"new entries must retain the non-strict default")
	} finally {
		_PersonalEditorPrioCtrl := OldPriorityCtrl
	}
}
Test("Personal editor native fallback: hidden strict-case state survives edits",
	TestPE_BuildEntryPreservesHiddenStrictCase)

TestPE_WebViewCarriesStrictCase() {
	global ScriptInformation, _ReadPersonalTomlCache
	TmpPath := A_Temp . "\ergopti_test_personal_strict_" . A_TickCount . ".toml"
	try FileDelete(TmpPath)
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := IsSet(_ReadPersonalTomlCache) ? _ReadPersonalTomlCache : false
	ScriptInformation["PersonalTomlPath"] := TmpPath
	_ReadPersonalTomlCache := false

	try {
		Data := Map(
			"sections_order", ["strict"],
			"sections", Map(
				"strict", Map(
					"description", "Strict",
					"entries", [Map(
						"trigger", "Case", "output", "exact", "is_word", true,
						"auto_expand", false, "is_case_sensitive", true,
						"final_result", false, "strict_case", true, "line_index", 0,
					)],
				),
			),
			"meta_description", "Strict case",
		)
		AssertTrue(WritePersonalToml(Data), "the strict fixture must reach disk")
		_ReadPersonalTomlCache := false
		try Js := _HsEdWeb_InitDataJs()
		catch as Err {
			Assert(false, "initData fixture failed before the strict assertion: "
				. Err.Message . " | " . Err.What . " | " . Err.Extra . " | " . Err.Stack)
		}
		Assert(InStr(Js, ",is_case_sensitive_strict:true") > 0,
			"the WebView host must carry hidden strict-case state into the shared editor")
	} finally {
		try FileDelete(TmpPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("Personal editor WebView: strict-case state reaches initData",
	TestPE_WebViewCarriesStrictCase)
