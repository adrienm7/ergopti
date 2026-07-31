; static/ergopti_plus/windows/tests/unit/test_hotstrings_full.ahk

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

; Delay per-section regression (from hotstrings_config).
;
; This replaces an AssertTrue(true) placeholder that stated the precedence rule
; in prose and verified none of it. The rule is section > category > TOML >
; global, and the section leg is the one users hit: a per-section delay set from
; the config window must beat the category default, and clearing it must fall
; back rather than leave the section pinned.
TestHotstringsFull_SectionDelayBeatsCategory() {
	Cat := "_hsfull_precedence_probe"
	Sec := "probe_section"
	try {
		HotstringsSetOverride(Cat, "", "delay", 111)
		AssertEqual(111, HotstringsResolve(Cat).Delay,
			"a category-level delay must resolve for the category itself")
		AssertEqual(111, HotstringsResolve(Cat, Sec).Delay,
			"a section with no delay of its own must inherit the category's")

		HotstringsSetOverride(Cat, Sec, "delay", 222)
		AssertEqual(222, HotstringsResolve(Cat, Sec).Delay,
			"a per-section delay must override the category — this is the leg the config window writes")
		AssertEqual(111, HotstringsResolve(Cat).Delay,
			"setting a section delay must not leak upward into the category")

		HotstringsClearOverride(Cat, Sec, "delay")
		AssertEqual(111, HotstringsResolve(Cat, Sec).Delay,
			"clearing the section delay must fall back to the category, not stay pinned to the cleared value")
	} finally {
		HotstringsClearOverride(Cat, Sec)
		HotstringsClearOverride(Cat, "")
	}
}
Test("Hotstrings full: a per-section delay overrides the category and falls back when cleared",
	TestHotstringsFull_SectionDelayBeatsCategory)
; HotstringHandler invocations with the same Abbr/Repl pair: if HotstringHandler
; correctly issues "BackSpace N + Repl + EndChar" for the right N, then a
; runtime fire of the same hotstring under AHK will, by construction, replace
; the abbreviation in place. That contract IS asserted here.
; ==============================================================================

; Hooks are installed by run_all.ahk for the whole test process; this file
; only needs to call ResetHotstringRecorders() at the start of each test.

_TestCallHotstring(Abbreviation, Replacement, EndChar, OnlyText := True, FinalResult := False, TimeActivationSeconds :=
    0) {
    BackSpaceSeq := "{BackSpace " . StrLen(Abbreviation) . "}"
    PrevCharKey := SubStr(Abbreviation, -2, 1)
    _HotstringDispatch(Replacement, EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult, TimeActivationSeconds)
}





; ==================================================
; ==================================================
; ======= 1/ CreateHotstring — flag assembly =======
; ==================================================
; ==================================================

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





; ========================================================
; ========================================================
; ======= 2/ CreateHotstring — options propagation =======
; ========================================================
; ========================================================

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





; =================================================================
; =================================================================
; ======= 3/ CreateCaseSensitiveHotstrings — variant counts =======
; =================================================================
; =================================================================

; Helper: extract every recorded trigger spec into a flat Array.
_CollectSpecs() {
    Specs := []
    for R in _Stub_HotstringRegistrations {
        Specs.Push(R.spec)
    }
    return Specs
}

TestCS_SingleCharLetter() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "a", "b")
    ; Conform path: ONE case-insensitive spec (no "C" flag) — HSE_DispatchMatch
    ; conforms the output casing at fire time. (Was 2 explicit variants.)
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    AssertEqual(":*?B0O:a", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: single-char letter registers one conform spec",
    TestCS_SingleCharLetter)

TestCS_SingleCharDigit() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "1", "2")
    ; A digit has no case, but the conform path still collapses to one spec.
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: single-char digit registers one conform spec",
    TestCS_SingleCharDigit)

TestCS_SingleCharStarSuffix() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "a★", "x")
    ; RTrim("a★","★")="a" → 1-char abbr; conform still registers one CI spec.
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: trailing magic-key 1-char abbr registers one conform spec",
    TestCS_SingleCharStarSuffix)

TestCS_TwoCharAllLetters() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; Conform path: one CI spec keyed on the lowercase trigger. (Was lower/UPPER/Title.)
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    AssertEqual(":*?B0O:ab", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: 2-char letter abbr registers one conform spec",
    TestCS_TwoCharAllLetters)

TestCS_TwoCharDigitFirst() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "1b", "x")
    ; No shift-symbol char → conform path → one CI spec.
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char digit-first abbr registers one conform spec",
    TestCS_TwoCharDigitFirst)

TestCS_TwoCharCommaFirst() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", ",b", "x")
    ; lowercase ",b" — 1
    ; uppercase variants of ",B": [",B", nnbsp;B, nnbsp:B, nbsp;B, nbsp:B]
    ;   (comma → 4 upper symbols {nnbsp,nbsp}×{";",":"}) — 5
    ; titlecase: first char "," IS in UppercasedSymbols → for each of the 4 upper
    ;   symbols register UpperSymbol + lowercase rest → 4
    ; Total: 1 + 5 + 4 = 10
    AssertEqual(10, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char comma-first abbr explodes to 10 variants",
    TestCS_TwoCharCommaFirst)

TestCS_TwoCharCommaInside() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "a,", "x")
    ; lowercase "a," — 1
    ; uppercase variants of "A,": ["A,", "A"+nnbsp;, "A"+nnbsp:, "A"+nbsp;, "A"+nbsp:] — 5
    ; titlecase: first char "a" letter, register "A," — 1
    ; Total: 7
    AssertEqual(7, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 2-char comma-inside abbr produces 7 variants",
    TestCS_TwoCharCommaInside)

TestCS_ThreeCharAllLetters() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "abc", "xyz")
    ; Conform path → one CI spec (was lowercase + UPPER + Title = 3).
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 3-char letter abbr registers one conform spec",
    TestCS_ThreeCharAllLetters)

TestCS_ThreeCharCommaInside() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "a,b", "x")
    ; lowercase 1 + uppercase variants of "A,B" = 5 (orig + 4 comma variants) + titlecase 1 = 7
    AssertEqual(7, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: 3-char with comma inside produces 7 variants",
    TestCS_ThreeCharCommaInside)

TestCS_ConformSpecIsCaseInsensitive() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; The conform spec DROPS the "C" flag (it now matches any case) but keeps B0
    ; (no auto-backspace by the builtin) and O (omit end char). Exact spec string
    ; proves the absence of "C".
    AssertEqual(":*?B0O:ab", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: conform spec is case-insensitive (B0O, no C)",
    TestCS_ConformSpecIsCaseInsensitive)

TestCS_RegistersLowercaseConformSpec() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; The single conform spec is keyed on the lowercase trigger; HSE matches it
    ; case-insensitively and conforms the output to the typed case at fire time.
    AssertEqual(":*?B0O:ab", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: registers the lowercase conform spec",
    TestCS_RegistersLowercaseConformSpec)

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
    ; Conform lowercases the trigger to one CI spec "z"; typing Z still matches it
    ; (case-insensitive) and conforms the output at fire time.
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    AssertEqual(":*?B0O:z", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: already-uppercase 1-char registers one lowercase conform spec",
    TestCS_AlreadyUppercaseLetter)

TestCS_TwoCharStartingDigit() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", "1A", "X")
    ; No shift-symbol char → conform path → one CI spec keyed on lowercase "1a".
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    AssertEqual(":*?B0O:1a", _Stub_HotstringRegistrations[1].spec)
}
Test("CreateCaseSensitiveHotstrings: 2-char digit-first abbr registers one conform spec",
    TestCS_TwoCharStartingDigit)

TestCS_TwoCharApostropheFirst() {
    ResetHotstringRecorders()
    CreateCaseSensitiveHotstrings("*?", Chr(0x27) . "b", "x")
    ; Apostrophe (Chr(0x27)) is in UppercasedSymbols with two upper variants
    ; (nnbsp+"?" and nbsp+"?").
    ; lowercase "'b" + uppercase variants of "'B": ["'B", nnbsp?B, nbsp?B] = 3
    ; + titlecase from symbol upgrade nnbsp?b, nbsp?b = 2 → total 6.
    AssertEqual(6, _Stub_HotstringRegistrations.Length)
}
Test("CreateCaseSensitiveHotstrings: apostrophe-first 2-char abbr produces 6 variants",
    TestCS_TwoCharApostropheFirst)

; Six AssertTrue(true) placeholders stood here. Three of them stated the SAME
; pause invariant three times, and it is already asserted for real — with the
; guard-before-mutation ordering that actually matters — by
; tests/unit/test_domain_expander.ahk. Restating it here would be a fourth copy
; of a claim, not a fourth check, so those three are gone rather than rewritten.
;
; The other three named real, checkable invariants and are written out below.

; Synthetic re-trigger loop. The driver's own SendInput output must never be fed
; back into the watcher, or an expansion whose replacement contains a trigger
; expands again, forever. The mechanism is the InputHook's I1 input level, which
; filters by PROVENANCE — the previous 60 ms time window also discarded real
; typing that arrived just after an expansion.
TestHSFull_SyntheticIsFilteredByProvenance() {
	Body := _DriverFuncBody("_StartInputHook")
	Assert(RegExMatch(Body, 'InputHook\("[^"]*I1[^"]*"\)') > 0,
		"the prefix watcher's InputHook must be created with I1 — that input level is what excludes the driver's own synthetic output, and without it every expansion containing a trigger re-triggers itself")
}
Test("Hotstrings full: synthetic input is filtered by provenance, not by a time window",
	TestHSFull_SyntheticIsFilteredByProvenance)


; A delay the user could not have meant must not reach the engine. The resolver
; is the single place this can be enforced, and the fallback has to be the
; global default rather than the bad value or zero.
TestHSFull_BadDelayFallsBackToTheGlobalDefault() {
	global GLOBAL_DEFAULT_DELAY
	Cat := "_hsfull_baddelay_probe"
	try {
		; An override cleared back to "" is exactly what the config window writes
		; when the user empties the field.
		HotstringsSetOverride(Cat, "", "delay", 250)
		AssertEqual(250, HotstringsResolve(Cat).Delay, "the probe override must take effect first")
		HotstringsSetOverride(Cat, "", "delay", "")
		AssertEqual(GLOBAL_DEFAULT_DELAY, HotstringsResolve(Cat).Delay,
			"an empty delay must fall back to the global default, not resolve to 0 or to the previous value")
	} finally {
		HotstringsClearOverride(Cat, "")
	}
}
Test("Hotstrings full: an empty delay falls back to the global default",
	TestHSFull_BadDelayFallsBackToTheGlobalDefault)


; The preview tooltip must not survive the expansion it was previewing. It is
; hidden from _ResetPrefixBuffer, which every fire path goes through, and the
; hide must be FORCED — the queued form would leave it on screen for the
; dequeue interval, which is the bug this covers.
TestHSFull_TooltipHiddenOnFire() {
	Body := _DriverFuncBody("_ResetPrefixBuffer")
	Assert(RegExMatch(Body, 'TooltipHide\("ResetBuf",\s*true\)') > 0,
		"_ResetPrefixBuffer must force-hide the tooltip (second argument true) — a queued hide leaves the preview on screen after the hotstring has already fired")
}
Test("Hotstrings full: the preview tooltip is force-hidden when a hotstring fires",
	TestHSFull_TooltipHiddenOnFire)





; =======================================================
; =======================================================
; ======= 4bis/ HotstringHandler — boundary cases =======
; =======================================================
; =======================================================

TestHH_PriorKeyMissingFailsClosed() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Map is empty — the prior char's timestamp may have been pruned after a
    ; long pause, so IsTimeActivationExpired must fail CLOSED (expired) and the
    ; time-gated expansion must be suppressed (0 sends), not fire as if typed now.
    LastSentCharacterKeyTime := Map()
    _TestCallHotstring("ab", "x", "", true, false, 1)
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: prior key absent from timing Map fails closed (suppressed)",
    TestHH_PriorKeyMissingFailsClosed)

TestHH_PriorKeyDifferentCharFailsClosed() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; The handler asks IsTimeActivationExpired for SubStr("xy", -2, 1) == "x".
    ; Only "y" is tracked, so the gate char "x" has no timestamp — we cannot
    ; prove "x" was typed recently, so the gate fails CLOSED (suppressed).
    LastSentCharacterKeyTime := Map("y", A_TickCount - 60000)
    _TestCallHotstring("xy", "z", "", true, false, 1)
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: absent gate-char timing fails closed (suppressed)",
    TestHH_PriorKeyDifferentCharFailsClosed)

TestHH_NotepadFinalResultStillNotepad() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    ; Even with FinalResult=true, the Notepad branch wins (it returns before
    ; the FinalResult check is reached).
    _TestCallHotstring("ab", "x", "!", true, true, 0)
    AssertEqual(1, _Stub_RecordedSends.Length)
    AssertEqual("SendInstant", _Stub_RecordedSends[1].fn)
}
Test("HotstringHandler: Notepad branch overrides FinalResult and uses SendInstant",
    TestHH_NotepadFinalResultStillNotepad)

TestHH_ReplacementWithControlChars() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; The replacement may contain any text; the handler must pass it verbatim
    ; without escaping or stripping.
    _TestCallHotstring("ab", "{Enter}", "", false, false, 0)
    AssertEqual("{Enter}", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement passes control sequences verbatim",
    TestHH_ReplacementWithControlChars)

TestHH_ReplacementWithLeadingSpace() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", " leading", "", true, false, 0)
    AssertEqual(" leading", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement preserves leading whitespace",
    TestHH_ReplacementWithLeadingSpace)





; =========================================================
; =========================================================
; ======= 5bis/ End-to-end — case-sensitive cascade =======
; =========================================================
; =========================================================

TestE2E_CaseSensSingleCharLowercase() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Single-char "a → b" registers ONE conform spec. Firing its callback (the
    ; lowercase form) yields the lowercase replacement "b".
    CreateCaseSensitiveHotstrings("*?", "a", "b")
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual("b", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: case-sensitive 1-char lowercase 'a → b' fires correctly",
    TestE2E_CaseSensSingleCharLowercase)

TestE2E_CaseSensSingleCharUppercase() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "a", "b")
    ; Type the trigger as a capital. A 1-char abbr has no distinct UPPER form, so a
    ; typed capital maps to the Title-cased replacement "B" (== upper for one char).
    ; Case-sensitive check — AssertEqual uses != which is case-INSENSITIVE in v2.
    HSE_FeedReset(true)
    Match := HSE_FeedChar("A")
    Assert(Match != "", "uppercase 'A' must match the case-insensitive conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "{Text}B", true) > 0,
        "typed 'A' must produce the conformed replacement 'B'")
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





; ==============================================
; ==============================================
; ======= 4/ HotstringHandler — branches =======
; ==============================================
; ==============================================

TestHH_BackspaceCountSingleChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("a", "b", "", true, false, 0)
    AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 1-char abbr → BackSpace 1", TestHH_BackspaceCountSingleChar)

TestHH_BackspaceCountTwoChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "abc", "", true, false, 0)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 2-char abbr → BackSpace 2", TestHH_BackspaceCountTwoChar)

TestHH_BackspaceCountFiveChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("hello", "world", "", true, false, 0)
    AssertEqual("{BackSpace 5}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 5-char abbr → BackSpace 5", TestHH_BackspaceCountFiveChar)

TestHH_BackspaceCountUnicodeAbbr() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; ★ is one Unicode code point; StrLen counts it as 1. The actual on-screen
    ; character takes one BackSpace press, so the count must remain 1.
    _TestCallHotstring("★", "x", "", true, false, 0)
    AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: Unicode abbr counts as one BackSpace", TestHH_BackspaceCountUnicodeAbbr)

TestHH_BackspaceFlagOnlyTextFalse() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "", true, false, 0)
    ; The BackSpace control sequence must be sent with OnlyText=false so it
    ; is interpreted as a real key press, not as literal text {BackSpace 2}.
    AssertEqual(false, _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: BackSpace send uses OnlyText=false",
    TestHH_BackspaceFlagOnlyTextFalse)

TestHH_ReplacementIsSecondSend() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "REPLACE", "", true, false, 0)
    AssertEqual("REPLACE", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement payload is the second send", TestHH_ReplacementIsSecondSend)

TestHH_EndCharIsThirdSend() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", " ", true, false, 0)
    AssertEqual(" ", _Stub_RecordedSends[3].args[1])
}
Test("HotstringHandler: end character is the third send", TestHH_EndCharIsThirdSend)

TestHH_EndCharFlagOnlyTextFalse() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    ; EndChar must be sent with OnlyText=false (third positional arg).
    AssertEqual(false, _Stub_RecordedSends[3].args[2])
}
Test("HotstringHandler: end character send uses OnlyText=false",
    TestHH_EndCharFlagOnlyTextFalse)

TestHH_DefaultPathSendCount() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: default path issues exactly 3 sends", TestHH_DefaultPathSendCount)

TestHH_DefaultPathUsesSendNewResult() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
    AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
    AssertEqual("SendNewResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: default path uses SendNewResult for every send",
    TestHH_DefaultPathUsesSendNewResult)

TestHH_FinalResultUsesSendFinalResult() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[2].fn)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: FinalResult=true switches all three sends to SendFinalResult",
    TestHH_FinalResultUsesSendFinalResult)

TestHH_NotepadPathSendCount() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    ; Notepad path: erase prefix + clipboard paste are one SendInstant transaction.
    AssertEqual(1, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: Notepad branch issues one atomic send", TestHH_NotepadPathSendCount)

TestHH_NotepadPathUsesSendInstant() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual(1, _Stub_RecordedSends.Length)
    AssertEqual("SendInstant", _Stub_RecordedSends[1].fn)
}
Test("HotstringHandler: Notepad branch uses SendInstant for replacement+endchar",
    TestHH_NotepadPathUsesSendInstant)

TestHH_NotepadPathCombinesReplacementAndEndChar() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "REPL", "!", true, false, 0)
    ; Notepad path concatenates Replacement . EndChar into one paste payload while
    ; passing the erase sequence as SendInstant's atomic prefix.
    AssertEqual("REPL!", _Stub_RecordedSends[1].args[1])
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: Notepad branch concatenates Replacement and EndChar",
    TestHH_NotepadPathCombinesReplacementAndEndChar)

TestHH_TimeActivationExpiredSkipsAll() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
    _TestCallHotstring("ab", "x", "", true, false, 1)
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
    _TestCallHotstring("ab", "x", "", true, false, 1)
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
    _TestCallHotstring("ab", "x", "", true, false, 0)
    AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: TimeActivationSeconds=0 disables the guard entirely",
    TestHH_TimeActivationZeroDisablesGuard)

TestHH_OnlyTextFlagPropagation() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "", false, false, 0)
    ; OnlyText=false → second send uses OnlyText=false (so SendEvent treats x as keys).
    AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("HotstringHandler: OnlyText=false flows to the replacement send",
    TestHH_OnlyTextFlagPropagation)

TestHH_EmptyAbbrYieldsZeroBackspace() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("", "x", "", true, false, 0)
    AssertEqual("{BackSpace 0}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: empty abbreviation produces BackSpace 0",
    TestHH_EmptyAbbrYieldsZeroBackspace)

TestHH_EmptyReplacementStillThreeSends() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "", "", true, false, 0)
    ; Empty replacement is still emitted as the second send.
    AssertEqual(3, _Stub_RecordedSends.Length)
    AssertEqual("", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: empty replacement is still emitted as the second send",
    TestHH_EmptyReplacementStillThreeSends)





; ==================================================================
; ==================================================================
; ======= 5/ End-to-end CreateHotstring → callback → Handler =======
; ==================================================================
; ==================================================================

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
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; Type "AB" through the engine; the conform spec must emit the UPPER-cased
    ; replacement "XY" (case-sensitive — AssertEqual is case-insensitive in v2).
    HSE_FeedReset(true)
    HSE_FeedChar("A")
    Match := HSE_FeedChar("B")
    Assert(Match != "", "uppercase 'AB' must match the conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "XY", true) > 0, "typed 'AB' must produce UPPER 'XY'")
    Assert(!InStr(Burst, "xy", true), "must NOT emit lowercase 'xy' for UPPER input")
}
Test("End-to-end: CreateCaseSensitive conform emits UPPER replacement for UPPER input",
    TestE2E_CaseSensitiveUppercaseFires)

TestE2E_CaseSensitiveTitlecaseFires() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; Type "Ab" (Title); the conform spec must emit the Title-cased "Xy".
    HSE_FeedReset(true)
    HSE_FeedChar("A")
    Match := HSE_FeedChar("b")
    Assert(Match != "", "title-case 'Ab' must match the conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "Xy", true) > 0, "typed 'Ab' must produce Title 'Xy'")
    Assert(!InStr(Burst, "XY", true), "must NOT emit UPPER 'XY' for Title input")
}
Test("End-to-end: CreateCaseSensitive conform emits Title replacement for Title input",
    TestE2E_CaseSensitiveTitlecaseFires)





; =====================================
; =====================================
; ======= 6/ ActivateHotstrings =======
; =====================================
; =====================================

TestAH_SendsTwoCalls() {
    global HSE_Buffer
    ResetHotstringRecorders()
    ; Seed a pending abbreviation so the flush dance runs — the gate skips it
    ; on an empty buffer (activate-hotstrings-sleep-on-keyboard-thread).
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual(2, _Stub_RecordedSends.Length)
}
Test("ActivateHotstrings: produces exactly 2 send calls (Space + BackSpace)",
    TestAH_SendsTwoCalls)

TestAH_FirstSendIsSpace() {
    global HSE_Buffer
    ResetHotstringRecorders()
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
    AssertEqual(" ", _Stub_RecordedSends[1].args[1])
}
Test("ActivateHotstrings: first send is a literal space", TestAH_FirstSendIsSpace)

TestAH_SecondSendIsBackspace() {
    global HSE_Buffer
    ResetHotstringRecorders()
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
    AssertEqual("{BackSpace}", _Stub_RecordedSends[2].args[1])
    AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("ActivateHotstrings: second send is {BackSpace} with OnlyText=false",
    TestAH_SecondSendIsBackspace)





; ===========================================
; ===========================================
; ======= 7/ Microsoft Office tagging =======
; ===========================================
; ===========================================

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





; =========================================================
; =========================================================
; ======= 8/ HotstringHandler — more boundary cases =======
; =========================================================
; =========================================================

TestHH_StarMagicKeyAbbr() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Abbreviation ending with MagicKey "★" — StrLen("ab★") = 3
    _TestCallHotstring("ab★", "x", "", true, false, 0)
    AssertEqual("{BackSpace 3}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: MagicKey in abbreviation is counted by StrLen",
    TestHH_StarMagicKeyAbbr)

TestHH_OnlyTextTruePropagation() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; OnlyText=true must flow to the replacement send (second send).
    _TestCallHotstring("ab", "x", "", true, false, 0)
    AssertEqual(true, _Stub_RecordedSends[2].args[2])
}
Test("HotstringHandler: OnlyText=true flows to the replacement send",
    TestHH_OnlyTextTruePropagation)

TestHH_FinalResultBackspaceIsFinal() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; FinalResult=true path — all three sends must use SendFinalResult.
    _TestCallHotstring("xy", "hello", ".", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
    AssertEqual(false, _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: FinalResult backspace uses SendFinalResult with OnlyText=false",
    TestHH_FinalResultBackspaceIsFinal)

TestHH_FinalResultEndCharIsFinal() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("xy", "hello", ".", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
    AssertEqual(".", _Stub_RecordedSends[3].args[1])
}
Test("HotstringHandler: FinalResult end character uses SendFinalResult",
    TestHH_FinalResultEndCharIsFinal)

TestHH_UnicodeReplacementPreserved() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("->", "→", "", true, false, 0)
    AssertEqual("→", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: Unicode arrow replacement is preserved verbatim",
    TestHH_UnicodeReplacementPreserved)

TestHH_EmojisInReplacement() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ok", "👍", "", true, false, 0)
    AssertEqual("👍", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: emoji replacement is preserved verbatim",
    TestHH_EmojisInReplacement)

TestHH_MultiLineReplacement() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    Multi := "line1" . "`n" . "line2"
    _TestCallHotstring("ml", Multi, "", true, false, 0)
    AssertEqual(Multi, _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: multi-line replacement is passed through unchanged",
    TestHH_MultiLineReplacement)

TestHH_NotepadAbbrWithUnicode() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    ; With Notepad + Unicode in abbr, BackSpace count must match StrLen("ab")
    _TestCallHotstring("ab", "★", "!", true, false, 0)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[2])
    AssertContains(_Stub_RecordedSends[1].args[1], "★")
}
Test("HotstringHandler: Notepad path with Unicode replacement preserves character",
    TestHH_NotepadAbbrWithUnicode)





; ============================================
; ============================================
; ======= 9/ CreateHotstring — options =======
; ============================================
; ============================================

TestCH_OptionTimeActivationPropagates() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; With a very short timeout and a very stale prior key, expansion must be blocked.
    global LastSentCharacterKeyTime
    LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
    CreateHotstring("*?", "ab", "x", Map("TimeActivationSeconds", 1))
    Cb := _Stub_HotstringRegistrations[1].callback
    ; Reset sends so we only count those from the callback
    ResetHotstringRecorders()
    Cb()
    ; Stale "a" → expired → no sends
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("CreateHotstring: TimeActivationSeconds option blocks expansion when prior key is stale",
    TestCH_OptionTimeActivationPropagates)

TestCH_OptionFinalResultPropagates() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    CreateHotstring("", "btw2", "by the way", Map("FinalResult", true))
    Cb := _Stub_HotstringRegistrations[1].callback
    ResetHotstringRecorders()
    Cb()
    ; All sends must be SendFinalResult
    for S in _Stub_RecordedSends {
        AssertEqual("SendFinalResult", S.fn)
    }
}
Test("CreateHotstring: FinalResult=true option propagates to every send in the callback",
    TestCH_OptionFinalResultPropagates)

TestCH_OptionOnlyTextFalse() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    CreateHotstring("*", "xk", "y", Map("OnlyText", false))
    Cb := _Stub_HotstringRegistrations[1].callback
    ResetHotstringRecorders()
    Cb()
    ; OnlyText=false must flow to the replacement send (second send, index 2).
    AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("CreateHotstring: OnlyText=false option propagates to the replacement send",
    TestCH_OptionOnlyTextFalse)

; Hooks are torn down by run_all.ahk's own teardown if needed.
