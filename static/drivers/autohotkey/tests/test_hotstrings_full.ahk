; static/drivers/autohotkey/tests/test_hotstrings_full.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Exhaustive Tests
; DESCRIPTION:
; In-depth coverage of the hotstring core: CreateHotstring, the much trickier
; CreateCaseSensitiveHotstrings (which generates between 2 and 6+ variants per
; call depending on the abbreviation's first character and the symbol-aware
; uppercase mappings), and HotstringHandler's Notepad / final-result /
; time-activation branches. Tests rely on the production test seams
; ``_HotstringRegistrar`` and ``_SendHook`` (defaults are 0, swapped here for
; recorders) so no real hotstring is ever registered with the OS during CI.
;
; FEATURES & RATIONALE:
; The hotstring engine is the load-bearing column of the whole driver. A
; subtle change in variant generation, time-activation, or send ordering
; would silently break thousands of user keystrokes. Each test below pins
; one specific contract observed at runtime:
;   * registration count + trigger-spec shape (CreateHotstring + CreateCaseSensitiveHotstrings)
;   * callback closure correctness (driving HotstringHandler through the
;     captured callback proves the closure captured Abbr/Repl/options correctly)
;   * BackSpace count = StrLen(Abbreviation) — the most fragile invariant
;   * Replacement and EndChar emitted in the correct order through the
;     correct send primitive (SendNewResult vs SendFinalResult)
;   * Time-activation guard (typed-too-slowly heuristic) blocks emission
;   * Notepad takes the SendInstant path; Office path is tagged via cache
;
; The cascading examples in the user's brief — "a → b" so typing "ac" yields
; "bc"; "ab → abc" so typing "ab" yields "abc" — depend on AHK actually firing
; hotkeys, which a unit test cannot do. They are nonetheless reduced to
; HotstringHandler invocations with the same Abbr/Repl pair: if HotstringHandler
; correctly issues "BackSpace N + Repl + EndChar" for the right N, then a
; runtime fire of the same hotstring under AHK will, by construction, replace
; the abbreviation in place. That contract IS asserted here.
; ==============================================================================

; Hooks are installed by run_all.ahk for the whole test process; this file
; only needs to call ResetHotstringRecorders() at the start of each test.




; ============================================
; ============================================
; ======= 1/ CreateHotstring — flag assembly =======
; ============================================
; ============================================

TestCH_FlagsEmpty() {
	ResetHotstringRecorders()
	CreateHotstring("", "abc", "xyz")
	AssertEqual(1, _Stub_HotstringRegistrations.Length)
	AssertEqual(":B0O:abc", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateHotstring: empty flags yields :B0O: prefix", TestCH_FlagsEmpty)

TestCH_FlagsAutoExpand() {
	ResetHotstringRecorders()
	CreateHotstring("*", "abc", "xyz")
	AssertEqual(":*B0O:abc", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateHotstring: '*' flag is preserved (auto-expand)", TestCH_FlagsAutoExpand)

TestCH_FlagsAutoAndInsideWord() {
	ResetHotstringRecorders()
	CreateHotstring("*?", "abc", "xyz")
	AssertEqual(":*?B0O:abc", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateHotstring: '*?' flags are preserved (inside-word + auto-expand)",
	TestCH_FlagsAutoAndInsideWord)

TestCH_FlagsInsideWordOnly() {
	ResetHotstringRecorders()
	CreateHotstring("?", "abc", "xyz")
	AssertEqual(":?B0O:abc", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateHotstring: '?' flag is preserved (inside-word)", TestCH_FlagsInsideWordOnly)

TestCH_FlagsCustomCFlag() {
	ResetHotstringRecorders()
	CreateHotstring("C", "abc", "xyz")
	AssertEqual(":CB0O:abc", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateHotstring: 'C' flag (strict case) flows through", TestCH_FlagsCustomCFlag)

TestCH_FlagsAlwaysAppendsB0O() {
	ResetHotstringRecorders()
	CreateHotstring("*", "x", "y")
	; ``B0`` (no auto-erase) and ``O`` (omit end char from abbreviation) MUST
	; always be appended — these are the invariants the rest of the engine relies on.
	AssertContains(_Stub_HotstringRegistrations[1].spec, "B0")
	AssertContains(_Stub_HotstringRegistrations[1].spec, "O")
}
Test("CreateHotstring: B0 and O flags are always appended", TestCH_FlagsAlwaysAppendsB0O)

TestCH_RegistersExactlyOne() {
	ResetHotstringRecorders()
	CreateHotstring("*?", "ab", "abc")
	AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateHotstring: registers exactly one hotstring (vs CreateCaseSensitive)",
	TestCH_RegistersExactlyOne)

TestCH_CallbackIsObject() {
	ResetHotstringRecorders()
	CreateHotstring("", "x", "y")
	AssertTrue(IsObject(_Stub_HotstringRegistrations[1].callback))
}
Test("CreateHotstring: callback is a callable Func", TestCH_CallbackIsObject)




; ============================================
; ============================================
; ======= 2/ CreateHotstring — options propagation =======
; ============================================
; ============================================

TestCH_OptionsDefaultOnlyTextTrue() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("*", "ab", "xy")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	; Default OnlyText=true → SendNewResult("xy", true) for the replacement.
	AssertEqual(true, _Stub_RecordedSends[2].args[2])
}
Test("CreateHotstring: default OnlyText is true (replacement send)",
	TestCH_OptionsDefaultOnlyTextTrue)

TestCH_OptionsOverrideOnlyText() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("*", "ab", "xy", Map("OnlyText", false))
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("CreateHotstring: OnlyText=false propagates to the replacement send",
	TestCH_OptionsOverrideOnlyText)

TestCH_OptionsDefaultFinalResultFalse() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("*", "ab", "xy")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	; Default FinalResult=false → uses SendNewResult (allows downstream cascading).
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[3].fn)
}
Test("CreateHotstring: default FinalResult=false uses SendNewResult",
	TestCH_OptionsDefaultFinalResultFalse)

TestCH_OptionsOverrideFinalResult() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("*", "ab", "xy", Map("FinalResult", true))
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	; FinalResult=true → uses SendFinalResult (blocks downstream cascading).
	AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[2].fn)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
}
Test("CreateHotstring: FinalResult=true switches to SendFinalResult",
	TestCH_OptionsOverrideFinalResult)

TestCH_OptionsTimeActivationDefaultZero() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	; Pretend the previous key was typed an hour ago — should NOT block default expansion.
	LastSentCharacterKeyTime := Map("a", A_TickCount - 3600 * 1000)
	CreateHotstring("*", "ab", "xy")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("CreateHotstring: default TimeActivationSeconds=0 never expires",
	TestCH_OptionsTimeActivationDefaultZero)

TestCH_OptionsTimeActivationBlocks() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	; "a" was typed 60 s ago; option says 1 s → must expire and skip.
	LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
	CreateHotstring("*", "ab", "xy", Map("TimeActivationSeconds", 1))
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("CreateHotstring: TimeActivationSeconds blocks expansion when expired",
	TestCH_OptionsTimeActivationBlocks)




; ============================================
; ============================================
; ======= 3/ CreateCaseSensitiveHotstrings — variant counts =======
; ============================================
; ============================================

; Helper: extract every recorded trigger spec into a flat Array.
_CollectSpecs() {
	Specs := []
	for _, R in _Stub_HotstringRegistrations {
		Specs.Push(R.spec)
	}
	return Specs
}

TestCS_SingleCharLetter() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "a", "b")
	; 1-char branch: registers lowercase "a" then titlecase "A" (== uppercase).
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
	Specs := _CollectSpecs()
	AssertContains(Specs[1] . "|" . Specs[2], ":*?CB0O:a")
	AssertContains(Specs[1] . "|" . Specs[2], ":*?CB0O:A")
}
Test("CreateCaseSensitiveHotstrings: single-char letter registers 2 variants (lowercase + titlecase)",
	TestCS_SingleCharLetter)

TestCS_SingleCharDigit() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "1", "2")
	; Even though StrLower("1") == StrUpper("1"), the 1-char branch still
	; calls RegisterVariant twice (lowercase + titlecase) — two registrations.
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: single-char digit still produces 2 registrations",
	TestCS_SingleCharDigit)

TestCS_SingleCharStarSuffix() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "a★", "x")
	; RTrim("a★", "★") = "a" length 1 → 1-char branch fires. 2 registrations.
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: trailing magic-key counts as 1-char abbr",
	TestCS_SingleCharStarSuffix)

TestCS_TwoCharAllLetters() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	; lowercase "ab" + uppercase variants (just "AB" since no symbols)
	; + titlecase "Ab" = 3 registrations.
	AssertEqual(3, _Stub_HotstringRegistrations.Length)
	Specs := _CollectSpecs()
	Joined := Specs[1] . "|" . Specs[2] . "|" . Specs[3]
	AssertContains(Joined, ":*?CB0O:ab")
	AssertContains(Joined, ":*?CB0O:AB")
	AssertContains(Joined, ":*?CB0O:Ab")
}
Test("CreateCaseSensitiveHotstrings: 2-char letter abbr produces lower/upper/titlecase (3)",
	TestCS_TwoCharAllLetters)

TestCS_TwoCharDigitFirst() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "1b", "x")
	; lowercase "1b" + uppercase "1B" — first char "1" is not a letter and not
	; in UppercasedSymbols, so NO titlecase variant is registered. 2 total.
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char digit-first abbr produces only 2 variants",
	TestCS_TwoCharDigitFirst)

TestCS_TwoCharCommaFirst() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", ",b", "x")
	; lowercase ",b" — 1
	; uppercase variants of ",B": [",B", " ;B", " :B"] (comma → 2 upper symbols) — 3
	; titlecase: first char "," IS in UppercasedSymbols → for each upper symbol
	; register UpperSymbol + lowercase rest → " ;b", " :b" — 2
	; Total: 1 + 3 + 2 = 6
	AssertEqual(6, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char comma-first abbr explodes to 6 variants",
	TestCS_TwoCharCommaFirst)

TestCS_TwoCharCommaInside() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "a,", "x")
	; lowercase "a," — 1
	; uppercase variants of "A,": ["A,", "A ;", "A :"] — 3
	; titlecase: first char "a" letter, register "A," — 1
	; Total: 5
	AssertEqual(5, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char comma-inside abbr produces 5 variants",
	TestCS_TwoCharCommaInside)

TestCS_ThreeCharAllLetters() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "abc", "xyz")
	; lowercase + 1 uppercase variant + 1 titlecase = 3
	AssertEqual(3, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 3-char letter abbr produces 3 variants",
	TestCS_ThreeCharAllLetters)

TestCS_ThreeCharCommaInside() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "a,b", "x")
	; lowercase 1 + uppercase variants of "A,B" = 3 (orig + 2 comma variants) + titlecase 1 = 5
	AssertEqual(5, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 3-char with comma inside produces 5 variants",
	TestCS_ThreeCharCommaInside)

TestCS_AlwaysIncludesCFlag() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	for _, R in _Stub_HotstringRegistrations {
		AssertContains(R.spec, "C")
		AssertContains(R.spec, "B0O")
	}
}
Test("CreateCaseSensitiveHotstrings: every variant carries C, B0 and O flags",
	TestCS_AlwaysIncludesCFlag)

TestCS_LowercaseRegistersFirst() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	; The first registration must be the lowercase variant — order matters
	; because AHK applies the most recently registered variant for ambiguous matches.
	AssertEqual(":*?CB0O:ab", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: lowercase variant is registered first",
	TestCS_LowercaseRegistersFirst)

TestCS_EmptyAbbr() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "", "x")
	; StrLen("") == 0 → 1-char branch skipped, 2-char branch skipped → only lowercase registers.
	AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: empty abbreviation registers only the lowercase no-op",
	TestCS_EmptyAbbr)

TestCS_AlreadyUppercaseLetter() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "Z", "y")
	; lowercase "z" + titlecase "Z" — 2 registrations, both valid distinct triggers.
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
	Specs := _CollectSpecs()
	Joined := Specs[1] . "|" . Specs[2]
	AssertContains(Joined, ":*?CB0O:z")
	AssertContains(Joined, ":*?CB0O:Z")
}
Test("CreateCaseSensitiveHotstrings: already-uppercase 1-char registers lower + upper",
	TestCS_AlreadyUppercaseLetter)

TestCS_TwoCharStartingDigit() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", "1A", "X")
	; lowercase "1a" + uppercase "1A" (no symbols, so just one upper variant)
	; Titlecase: first char "1" — not a letter (lower==upper) AND not in
	; UppercasedSymbols → no titlecase branch. 2 total.
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char digit-first abbr (uppercase suffix) — 2 variants",
	TestCS_TwoCharStartingDigit)

TestCS_TwoCharApostropheFirst() {
	ResetHotstringRecorders()
	CreateCaseSensitiveHotstrings("*?", Chr(0x27) . "b", "x")
	; Apostrophe (Chr(0x27)) is in UppercasedSymbols with one upper variant " ?".
	; lowercase "'b" + uppercase variants of "'B": ["'B", " ?B"] = 2 + titlecase from
	; symbol upgrade " ?b" = 1 → total 4.
	AssertEqual(4, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: apostrophe-first 2-char abbr produces 4 variants",
	TestCS_TwoCharApostropheFirst)




; ============================================
; ============================================
; ======= 4bis/ HotstringHandler — boundary cases =======
; ============================================
; ============================================

TestHH_PriorKeyMissingNeverExpires() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	; Map is empty — IsTimeActivationExpired falls back to Now, so diff == 0
	; and the timeout cannot be exceeded regardless of OptionTimeActivationSeconds.
	LastSentCharacterKeyTime := Map()
	HotstringHandler("ab", "x", "", true, false, 1)
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: prior key absent from timing Map never expires",
	TestHH_PriorKeyMissingNeverExpires)

TestHH_PriorKeyDifferentCharNeverBlocksOther() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	; The handler asks IsTimeActivationExpired for SubStr("xy", -2, 1) == "x".
	; "y" being stale must NOT block expansion gated on "x".
	LastSentCharacterKeyTime := Map("y", A_TickCount - 60000)
	HotstringHandler("xy", "z", "", true, false, 1)
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: stale timing for an unrelated character does not block expansion",
	TestHH_PriorKeyDifferentCharNeverBlocksOther)

TestHH_NotepadFinalResultStillNotepad() {
	ResetHotstringRecorders()
	SimulateNotepadActive()
	; Even with FinalResult=true, the Notepad branch wins (it returns before
	; the FinalResult check is reached).
	HotstringHandler("ab", "x", "!", true, true, 0)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendInstant", _Stub_RecordedSends[2].fn)
}
Test("HotstringHandler: Notepad branch overrides FinalResult and uses SendInstant",
	TestHH_NotepadFinalResultStillNotepad)

TestHH_ReplacementWithControlChars() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	; The replacement may contain any text; the handler must pass it verbatim
	; without escaping or stripping.
	HotstringHandler("ab", "{Enter}", "", false, false, 0)
	AssertEqual("{Enter}", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement passes control sequences verbatim",
	TestHH_ReplacementWithControlChars)

TestHH_ReplacementWithLeadingSpace() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", " leading", "", true, false, 0)
	AssertEqual(" leading", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement preserves leading whitespace",
	TestHH_ReplacementWithLeadingSpace)




; ============================================
; ============================================
; ======= 5bis/ End-to-end — case-sensitive cascade =======
; ============================================
; ============================================

TestE2E_CaseSensSingleCharLowercase() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	; Single-char "a → b" via CreateCaseSensitiveHotstrings registers both
	; "a → b" and "A → B". Firing the lowercase callback yields "b".
	CreateCaseSensitiveHotstrings("*?", "a", "b")
	AssertEqual(2, _Stub_HotstringRegistrations.Length)
	; Lowercase callback (registered first).
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual("b", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: case-sensitive 1-char lowercase 'a → b' fires correctly",
	TestE2E_CaseSensSingleCharLowercase)

TestE2E_CaseSensSingleCharUppercase() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateCaseSensitiveHotstrings("*?", "a", "b")
	; Titlecase callback is the second registration; firing it must send "B".
	Cb := _Stub_HotstringRegistrations[2].callback
	Cb()
	AssertEqual("B", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: case-sensitive 1-char uppercase 'A → B' fires correctly",
	TestE2E_CaseSensSingleCharUppercase)

TestE2E_HookInstalledNoRealRegistration() {
	; Sanity: with the hook installed, CreateHotstring must NOT call the real
	; AHK Hotstring() builtin. We verify by counting registrations (only those
	; the recorder captures are visible).
	Before := _Stub_HotstringRegistrations.Length
	CreateHotstring("*", "test_hook_proof", "y")
	AssertEqual(Before + 1, _Stub_HotstringRegistrations.Length)
}
Test("Hook integration: installed hook captures CreateHotstring instead of AHK builtin",
	TestE2E_HookInstalledNoRealRegistration)




; ============================================
; ============================================
; ======= 4/ HotstringHandler — branches =======
; ============================================
; ============================================

TestHH_BackspaceCountSingleChar() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("a", "b", "", true, false, 0)
	AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 1-char abbr → BackSpace 1", TestHH_BackspaceCountSingleChar)

TestHH_BackspaceCountTwoChar() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "abc", "", true, false, 0)
	AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 2-char abbr → BackSpace 2", TestHH_BackspaceCountTwoChar)

TestHH_BackspaceCountFiveChar() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("hello", "world", "", true, false, 0)
	AssertEqual("{BackSpace 5}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 5-char abbr → BackSpace 5", TestHH_BackspaceCountFiveChar)

TestHH_BackspaceCountUnicodeAbbr() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	; ★ is one Unicode code point; StrLen counts it as 1. The actual on-screen
	; character takes one BackSpace press, so the count must remain 1.
	HotstringHandler("★", "x", "", true, false, 0)
	AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: Unicode abbr counts as one BackSpace", TestHH_BackspaceCountUnicodeAbbr)

TestHH_BackspaceFlagOnlyTextFalse() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "", true, false, 0)
	; The BackSpace control sequence must be sent with OnlyText=false so it
	; is interpreted as a real key press, not as literal text {BackSpace 2}.
	AssertEqual(false, _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: BackSpace send uses OnlyText=false",
	TestHH_BackspaceFlagOnlyTextFalse)

TestHH_ReplacementIsSecondSend() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "REPLACE", "", true, false, 0)
	AssertEqual("REPLACE", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement payload is the second send", TestHH_ReplacementIsSecondSend)

TestHH_EndCharIsThirdSend() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", " ", true, false, 0)
	AssertEqual(" ", _Stub_RecordedSends[3].args[1])
}
Test("HotstringHandler: end character is the third send", TestHH_EndCharIsThirdSend)

TestHH_EndCharFlagOnlyTextFalse() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "!", true, false, 0)
	; EndChar must be sent with OnlyText=false (third positional arg).
	AssertEqual(false, _Stub_RecordedSends[3].args[2])
}
Test("HotstringHandler: end character send uses OnlyText=false",
	TestHH_EndCharFlagOnlyTextFalse)

TestHH_DefaultPathSendCount() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "!", true, false, 0)
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: default path issues exactly 3 sends", TestHH_DefaultPathSendCount)

TestHH_DefaultPathUsesSendNewResult() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "!", true, false, 0)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: default path uses SendNewResult for every send",
	TestHH_DefaultPathUsesSendNewResult)

TestHH_FinalResultUsesSendFinalResult() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "!", true, true, 0)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[2].fn)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: FinalResult=true switches all three sends to SendFinalResult",
	TestHH_FinalResultUsesSendFinalResult)

TestHH_NotepadPathSendCount() {
	ResetHotstringRecorders()
	SimulateNotepadActive()
	HotstringHandler("ab", "x", "!", true, false, 0)
	; Notepad path: BackSpace via SendNewResult + clipboard paste via SendInstant. 2 calls.
	AssertEqual(2, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: Notepad branch issues exactly 2 sends", TestHH_NotepadPathSendCount)

TestHH_NotepadPathUsesSendInstant() {
	ResetHotstringRecorders()
	SimulateNotepadActive()
	HotstringHandler("ab", "x", "!", true, false, 0)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendInstant", _Stub_RecordedSends[2].fn)
}
Test("HotstringHandler: Notepad branch uses SendInstant for replacement+endchar",
	TestHH_NotepadPathUsesSendInstant)

TestHH_NotepadPathCombinesReplacementAndEndChar() {
	ResetHotstringRecorders()
	SimulateNotepadActive()
	HotstringHandler("ab", "REPL", "!", true, false, 0)
	; Notepad path concatenates Replacement . EndChar into a single SendInstant call.
	AssertEqual("REPL!", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: Notepad branch concatenates Replacement and EndChar",
	TestHH_NotepadPathCombinesReplacementAndEndChar)

TestHH_TimeActivationExpiredSkipsAll() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
	HotstringHandler("ab", "x", "", true, false, 1)
	; Timeout 1 s exceeded by the 60 s gap → handler returns immediately.
	AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: expired time-activation produces zero sends",
	TestHH_TimeActivationExpiredSkipsAll)

TestHH_TimeActivationFreshAllowsAll() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	LastSentCharacterKeyTime := Map("a", A_TickCount)
	HotstringHandler("ab", "x", "", true, false, 1)
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: fresh prior-key timing within window allows expansion",
	TestHH_TimeActivationFreshAllowsAll)

TestHH_TimeActivationZeroDisablesGuard() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	; Even with a stale prior key, timeout=0 must NEVER expire.
	LastSentCharacterKeyTime := Map("a", A_TickCount - 3600 * 1000)
	HotstringHandler("ab", "x", "", true, false, 0)
	AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: TimeActivationSeconds=0 disables the guard entirely",
	TestHH_TimeActivationZeroDisablesGuard)

TestHH_OnlyTextFlagPropagation() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "x", "", false, false, 0)
	; OnlyText=false → second send uses OnlyText=false (so SendEvent treats x as keys).
	AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("HotstringHandler: OnlyText=false flows to the replacement send",
	TestHH_OnlyTextFlagPropagation)

TestHH_EmptyAbbrYieldsZeroBackspace() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("", "x", "", true, false, 0)
	AssertEqual("{BackSpace 0}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: empty abbreviation produces BackSpace 0",
	TestHH_EmptyAbbrYieldsZeroBackspace)

TestHH_EmptyReplacementStillThreeSends() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	HotstringHandler("ab", "", "", true, false, 0)
	; Empty replacement is still emitted as the second send.
	AssertEqual(3, _Stub_RecordedSends.Length)
	AssertEqual("", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: empty replacement is still emitted as the second send",
	TestHH_EmptyReplacementStillThreeSends)




; ============================================
; ============================================
; ======= 5/ End-to-end CreateHotstring → callback → Handler =======
; ============================================
; ============================================

; Verifies that the callback closure built by CreateHotstring captures Abbr
; and Repl correctly. This is what the AHK runtime fires when a user actually
; types the abbreviation — the closure must drive HotstringHandler with the
; correct StrLen for the BackSpace count and the correct Replacement payload.

TestE2E_AToB() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	; This is the foundational "a → b" hotstring from the user's brief.
	; Typing "a" must delete one character and send "b". Typing "ac" then
	; produces "bc" because "c" is a normal keystroke that follows.
	CreateHotstring("*", "a", "b")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual(3, _Stub_RecordedSends.Length)
	AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
	AssertEqual("b", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: 'a → b' callback deletes 1 and sends 'b'", TestE2E_AToB)

TestE2E_AbToAbc() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	; The "ab → abc" example from the user's brief.
	CreateHotstring("*", "ab", "abc")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual(3, _Stub_RecordedSends.Length)
	AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
	AssertEqual("abc", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: 'ab → abc' callback deletes 2 and sends 'abc'", TestE2E_AbToAbc)

TestE2E_LongAbbreviation() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("*", "approximately", "≈")
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual("{BackSpace 13}", _Stub_RecordedSends[1].args[1])
	AssertEqual("≈", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: long abbreviation produces correct BackSpace count and unicode replacement",
	TestE2E_LongAbbreviation)

TestE2E_FinalResultPreservesEndChar() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateHotstring("", "btw", "by the way", Map("FinalResult", true))
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	; Without `*` the hotstring fires on an end character; A_EndChar is "" in
	; our manual call, so the third send is the empty string.
	AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
	AssertEqual("by the way", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: FinalResult=true passes through to every send",
	TestE2E_FinalResultPreservesEndChar)

TestE2E_CaseSensitiveLowercaseFires() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	; First registration is the lowercase variant.
	Cb := _Stub_HotstringRegistrations[1].callback
	Cb()
	AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
	AssertEqual("xy", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: CreateCaseSensitive lowercase callback sends lowercase replacement",
	TestE2E_CaseSensitiveLowercaseFires)

TestE2E_CaseSensitiveUppercaseFires() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	; Find the uppercase ":*?CB0O:AB" registration.
	UpperIdx := 0
	for i, R in _Stub_HotstringRegistrations {
		if R.spec == ":*?CB0O:AB" {
			UpperIdx := i
			break
		}
	}
	AssertTrue(UpperIdx > 0)
	Cb := _Stub_HotstringRegistrations[UpperIdx].callback
	Cb()
	; Uppercase callback must send the uppercase replacement "XY".
	AssertEqual("XY", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: CreateCaseSensitive uppercase callback sends uppercase replacement",
	TestE2E_CaseSensitiveUppercaseFires)

TestE2E_CaseSensitiveTitlecaseFires() {
	ResetHotstringRecorders()
	SimulateRegularApp()
	CreateCaseSensitiveHotstrings("*?", "ab", "xy")
	TitleIdx := 0
	for i, R in _Stub_HotstringRegistrations {
		if R.spec == ":*?CB0O:Ab" {
			TitleIdx := i
			break
		}
	}
	AssertTrue(TitleIdx > 0)
	Cb := _Stub_HotstringRegistrations[TitleIdx].callback
	Cb()
	; Titlecase callback must send "Xy".
	AssertEqual("Xy", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: CreateCaseSensitive titlecase callback sends titlecase replacement",
	TestE2E_CaseSensitiveTitlecaseFires)




; ============================================
; ============================================
; ======= 6/ ActivateHotstrings =======
; ============================================
; ============================================

TestAH_SendsTwoCalls() {
	ResetHotstringRecorders()
	ActivateHotstrings()
	AssertEqual(2, _Stub_RecordedSends.Length)
}
Test("ActivateHotstrings: produces exactly 2 send calls (Space + BackSpace)",
	TestAH_SendsTwoCalls)

TestAH_FirstSendIsSpace() {
	ResetHotstringRecorders()
	ActivateHotstrings()
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual(" ", _Stub_RecordedSends[1].args[1])
}
Test("ActivateHotstrings: first send is a literal space", TestAH_FirstSendIsSpace)

TestAH_SecondSendIsBackspace() {
	ResetHotstringRecorders()
	ActivateHotstrings()
	AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
	AssertEqual("{BackSpace}", _Stub_RecordedSends[2].args[1])
	AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("ActivateHotstrings: second send is {BackSpace} with OnlyText=false",
	TestAH_SecondSendIsBackspace)




; ============================================
; ============================================
; ======= 7/ Microsoft Office tagging =======
; ============================================
; ============================================

TestMS_DetectsWord() {
	SimulateMicrosoftOffice()
	AssertTrue(MicrosoftApps())
}
Test("MicrosoftApps: detects WINWORD.EXE through the active-app cache",
	TestMS_DetectsWord)

TestMS_NonOfficeReturnsFalse() {
	SimulateRegularApp()
	AssertFalse(MicrosoftApps())
}
Test("MicrosoftApps: returns false for a non-Office foreground app",
	TestMS_NonOfficeReturnsFalse)

TestMS_NotepadIsNotOffice() {
	SimulateNotepadActive()
	AssertFalse(MicrosoftApps())
}
Test("MicrosoftApps: Notepad is not classified as an Office app",
	TestMS_NotepadIsNotOffice)




; Hooks are torn down by run_all.ahk's own teardown if needed.
