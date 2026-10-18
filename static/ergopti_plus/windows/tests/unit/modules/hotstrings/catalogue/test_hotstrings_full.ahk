; static/ergopti_plus/windows/tests/unit/modules/hotstrings/catalogue/test_hotstrings_full.ahk

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
;   * BackSpace count = number of Unicode scalars — the most fragile invariant
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
	global _HotstringsOverrides, _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	Path := A_Temp . "\hotstrings_full_precedence_overrides.toml"
	try FileDelete(Path)
	_HotstringsOverrides := Map()
	_HotstringsOverridesPath := Path
	HotstringsResolveBumpGen()
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
		_HotstringsOverrides := SavedOverrides
		_HotstringsOverridesPath := SavedPath
		HotstringsResolveBumpGen()
		try FileDelete(Path)
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
    BackSpaceSeq := "{BackSpace " . _TextCodepointLength(Abbreviation) . "}"
    PrevCharKey := _MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds).PrevCharKey
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
    ; One lowercase CI spec retains B0/O while dropping C; dispatch owns casing.
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
Test("CreateCaseSensitiveHotstrings: uppercase digit-first abbr registers one lowercase conform spec",
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
; tests/unit/modules/hotstrings/engine/test_domain_expander.ahk. Restating it here would be a fourth copy
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
	global GLOBAL_DEFAULT_DELAY, _HotstringsOverrides, _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	Path := A_Temp . "\hotstrings_full_bad_delay_overrides.toml"
	try FileDelete(Path)
	_HotstringsOverrides := Map()
	_HotstringsOverridesPath := Path
	HotstringsResolveBumpGen()
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
		_HotstringsOverrides := SavedOverrides
		_HotstringsOverridesPath := SavedPath
		HotstringsResolveBumpGen()
		try FileDelete(Path)
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


TestHH_UnicodeCallbackReplay() {
	global _Stub_RecordedSends
	SimulateRegularApp()
	ResetHotstringRecorders()
	_TestCallHotstring(Chr(0x1F600) . "x", "R", "", true, true)
	AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1],
		"the callback fixture must preserve the real registration's native key count")
}
Test("Hotstrings full: Unicode callback replay uses native Backspace counts (unicode-erase)",
	TestHH_UnicodeCallbackReplay)

/** A real registration callback must look up the complete prior character. */
_TestHH_UnicodeTimingCallback(Trigger, PriorChar) {
	global LastSentCharacterKeyTime, _Stub_RecordedSends, _Stub_HotstringRegistrations
	SavedTimes := LastSentCharacterKeyTime
	try {
		SimulateRegularApp()
		ResetHotstringRecorders()
		LastSentCharacterKeyTime := Map(PriorChar, A_TickCount)
		CreateHotstring("*?C", Trigger, "BAR", Map("TimeActivationSeconds", 1))
		AssertEqual(1, _Stub_HotstringRegistrations.Length)
		Callback := _Stub_HotstringRegistrations[1].callback
		Callback()
		AssertEqual(3, _Stub_RecordedSends.Length, "the actual callback passes its recent character gate")
		AssertEqual("BAR", _Stub_RecordedSends[2].args[1], "the guarded callback emits its own replacement")
	} finally {
		LastSentCharacterKeyTime := SavedTimes
		ResetHotstringRecorders()
	}
}
Test("callback unicode-time-gate: supplementary preceding character has one timestamp identity", (*) =>
	_TestHH_UnicodeTimingCallback("a" . Chr(0x1F601) . "★", Chr(0x1F601)))
Test("callback unicode-time-gate: supplementary final key keeps the actual preceding identity", (*) =>
	_TestHH_UnicodeTimingCallback("ab" . Chr(0x1F601), "b"))


/** Verify scalar identity independently from the exact activation deadline. */
_UTG_ActivationMatrix() {
	global LastSentCharacterKeyTime
	Saved := LastSentCharacterKeyTime
	Prior := Chr(0x1F601)
	Decoy := Chr(0x1FA01)
	try {
		for Origin in [1000, 0xFFFFFFF0] {
			for Elapsed in [999, 1000, 1001] {
				Now := (Origin + Elapsed) & 0xFFFFFFFF
				LastSentCharacterKeyTime := Map(Prior, Origin, Decoy, Now)
				Spec := _MakeHotstringMeta("bar", "a" . Prior . "★", true, true, 1)
				AssertEqual(Prior, Spec.PrevCharKey, "metadata carries the complete prior scalar")
				AssertEqual(Elapsed > 1000, IsTimeActivationExpired(Spec.PrevCharKey, 1, Now),
					"the native callback gate preserves strict expiry across wrap")
				for Conform in [false, true] {
					Spec.CaseConform := Conform
					Decision := _HSE_PrepareDispatchDecision(Spec, Spec.Trigger, "", false, "bar", Now)
					if Elapsed > 1000 {
						AssertEqual("", Decision, "expired real dispatch is refused despite a fresh decoy")
					} else {
						AssertTrue(IsObject(Decision), "before and exact expiry remain dispatchable")
						AssertEqual(Origin, Decision.GateOriginTick, "dispatch uses the actual scalar timestamp")
						AssertEqual(1000 - Elapsed, Decision.RemainingMs,
							"equality is fireable but has no remaining renderer interaction window")
					}
				}
			}
		}
		LastSentCharacterKeyTime := Map(Decoy, 5000)
		Spec := _MakeHotstringMeta("bar", "a" . Prior . "★", true, true, 1)
		AssertTrue(IsTimeActivationExpired(Spec.PrevCharKey, 1, 5000), "a decoy cannot supply a missing timestamp")
		AssertEqual("", _HSE_PrepareDispatchDecision(Spec, Spec.Trigger, "", false, "bar", 5000))
		LastSentCharacterKeyTime := Map("b", 1000)
		Bmp := _MakeHotstringMeta("bar", "ab★", true, true, 1)
		AssertFalse(IsTimeActivationExpired(Bmp.PrevCharKey, 1, 2000), "ordinary scalar remains live at equality")
		AssertTrue(IsTimeActivationExpired(Bmp.PrevCharKey, 1, 2001), "ordinary scalar expires strictly afterward")
		AssertFalse(IsTimeActivationExpired(Prior, 0, 2001), "zero disables the activation gate")
		for InvalidDuration in ["1", 4294968] {
			AssertTrue(IsTimeActivationExpired("b", InvalidDuration, 1000),
				"invalid positive duration retains the canonical clock refusal")
			Bmp.TimeActivationSeconds := InvalidDuration
			AssertEqual("", _HSE_PrepareDispatchDecision(Bmp, Bmp.Trigger, "", false, "bar", 1000))
		}
		Bmp.TimeActivationSeconds := 1.25
		AssertFalse(IsTimeActivationExpired("b", 1.25, 2250), "a valid fractional-second duration keeps its exact boundary")
		AssertTrue(IsTimeActivationExpired("b", 1.25, 2251), "a valid fractional-second duration expires one millisecond later")
	} finally {
		LastSentCharacterKeyTime := Saved
	}
}
Test("hotstrings unicode-time-gate: scalar timestamps retain exact and wrapped deadlines", _UTG_ActivationMatrix)

_UTG_TypedCompletionIdentity() {
	global LastSentCharacterKeyTime
	Saved := LastSentCharacterKeyTime
	try {
		Completion := Chr(0x1F601)
		Spec := _MakeHotstringMeta("bar", "ab" . Completion, true, true, 1)
		Spec.CaseConform := true
		LastSentCharacterKeyTime := Map("B", 1000, "b", 1)
		Decision := _HSE_PrepareDispatchDecision(Spec, "AB" . Completion, "", false, "bar", 1500)
		AssertTrue(IsObject(Decision), "supplementary completion preserves the preceding typed case")
		AssertEqual(1000, Decision.GateOriginTick, "typed B owns the timestamp rather than canonical b")
		AssertEqual("BAR", Decision.Replacement, "the actual conform owner receives the complete trigger")
	} finally {
		LastSentCharacterKeyTime := Saved
	}
}
Test("hotstrings unicode-time-gate: supplementary completion uses the actual typed timestamp", _UTG_TypedCompletionIdentity)

_UTG_RawMetadataIdentity() {
	global _HotstringRegistrar, HSE_RegistryByGroup
	Saved := _HotstringRegistrar
	try {
		_HotstringRegistrar := 0
		HSE_RegistryClear()
		Trigger := "a" . Chr(0x1F601) . "★"
		CreateRawCallbackHotstring("*?C", Trigger, (*) => 0,
			Map("Group", "unicode-time-fixture", "Priority", 77, "TimeActivationSeconds", 1))
		AssertTrue(HSE_RegistryByGroup.Has("unicode-time-fixture"), "real raw registration preserves its owner")
		Specs := HSE_RegistryByGroup["unicode-time-fixture"]
		AssertEqual(1, Specs.Length)
		AssertEqual(Chr(0x1F601), Specs[1].PrevCharKey, "raw metadata uses the same complete scalar identity")
		AssertEqual(77, Specs[1].Priority, "the transplant retains the priority/provenance contract")
	} finally {
		HSE_RegistryClear()
		_HotstringRegistrar := Saved
	}
}
Test("hotstrings unicode-time-gate: raw registration transports the complete prior key", _UTG_RawMetadataIdentity)

_UTG_RecentDecoyDoesNotRepairCallback() {
	global LastSentCharacterKeyTime, _Stub_RecordedSends, _Stub_HotstringRegistrations
	Saved := LastSentCharacterKeyTime
	try {
		SimulateRegularApp()
		ResetHotstringRecorders()
		Prior := Chr(0x1F601)
		LastSentCharacterKeyTime := Map(Prior, (A_TickCount - 5000) & 0xFFFFFFFF,
			Chr(0x1FA01), A_TickCount)
		CreateHotstring("*?C", "a" . Prior . "★", "BAR", Map("TimeActivationSeconds", 1))
		AssertEqual(1, _Stub_HotstringRegistrations.Length)
		_Stub_HotstringRegistrations[1].callback()
		AssertEqual(0, _Stub_RecordedSends.Length, "a fresh distinct scalar cannot repair the expired actual callback key")
	} finally {
		LastSentCharacterKeyTime := Saved
		ResetHotstringRecorders()
	}
}
Test("callback unicode-time-gate: a recent decoy cannot repair an expired scalar", _UTG_RecentDecoyDoesNotRepairCallback)
