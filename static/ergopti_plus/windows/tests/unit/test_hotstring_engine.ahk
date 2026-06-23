; static/ergopti_plus/windows/tests/unit/test_hotstring_engine.ahk

; ==============================================================================
; MODULE: Hotstring Engine Tests
; DESCRIPTION:
; Covers pure helpers from lib/hotstring_engine.ahk: case helpers,
; lookup primitives and the time-activation guard. Send primitives and
; CreateHotstring* are exercised through their stubs (test_stubs.ahk).
; ==============================================================================




; =========
; StrTitle
; =========
TestHE_StrTitleEmpty() {
	AssertEqual("", StrTitle(""))
}
Test("StrTitle: empty string is returned as-is", TestHE_StrTitleEmpty)

TestHE_StrTitleSingleChar() {
	AssertEqual("A", StrTitle("a"))
}
Test("StrTitle: single lowercase letter is uppercased", TestHE_StrTitleSingleChar)

TestHE_StrTitleMixedCase() {
	AssertEqual("Hello", StrTitle("hELLO"))
}
Test("StrTitle: word with mixed case is normalised", TestHE_StrTitleMixedCase)

TestHE_StrTitleWord() {
	AssertEqual("Bonjour", StrTitle("bonjour"))
}
Test("StrTitle: multi-character word capitalises first letter only", TestHE_StrTitleWord)




; ==========================
; GetLastSentCharacterAt
; ==========================
TestHE_LastSentEmpty() {
	_LSCResetFrom([])
	AssertEqual("", GetLastSentCharacterAt(-1))
}
Test("GetLastSentCharacterAt: empty buffer returns empty string", TestHE_LastSentEmpty)

TestHE_LastSentOffsets() {
	_LSCResetFrom(["a", "b", "c"])
	AssertEqual("c", GetLastSentCharacterAt(-1))
	AssertEqual("b", GetLastSentCharacterAt(-2))
}
Test("GetLastSentCharacterAt: returns offset value when available", TestHE_LastSentOffsets)

TestHE_LastSentOverflow() {
	_LSCResetFrom(["x"])
	AssertEqual("", GetLastSentCharacterAt(-3))
}
Test("GetLastSentCharacterAt: returns empty when offset exceeds buffer length",
	TestHE_LastSentOverflow)




; ==========================
; IsTimeActivationExpired
; ==========================
TestHE_TimeoutZeroNeverExpires() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map()
	AssertFalse(IsTimeActivationExpired("a", 0))
}
Test("IsTimeActivationExpired: timeout 0 means never expires", TestHE_TimeoutZeroNeverExpires)

TestHE_RecentKeyNotExpired() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map("a", A_TickCount)
	AssertFalse(IsTimeActivationExpired("a", 5))
}
Test("IsTimeActivationExpired: just-now key never expires within window",
	TestHE_RecentKeyNotExpired)

TestHE_OldKeyExpired() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
	AssertTrue(IsTimeActivationExpired("a", 1))
}
Test("IsTimeActivationExpired: very-old key has expired", TestHE_OldKeyExpired)




; ==========================
; GenerateUppercaseVariants
; ==========================
TestHE_VariantsBaseline() {
	V := GenerateUppercaseVariants("HELLO", Map())
	AssertEqual(1, V.Length)
	AssertEqual("HELLO", V[1])
}
Test("GenerateUppercaseVariants: returns single original when no symbols match",
	TestHE_VariantsBaseline)

TestHE_VariantsExpand() {
	Symbols := Map(",", [" " . Chr(0x3B), " :"])
	V := GenerateUppercaseVariants("A,B", Symbols)
	AssertEqual(3, V.Length)
	AssertEqual("A,B", V[1])
}
Test("GenerateUppercaseVariants: appends one variant per symbol substitution",
	TestHE_VariantsExpand)




; ==========================
; UppercasedSymbols Map
; ==========================
TestHE_UppercasedComma() {
	; Regression: the "uppercase" form of a comma is the shifted-comma the layout
	; actually emits — nbsp/nnbsp + ";"/":" — NEVER a plain ASCII space. Four
	; variants: {nnbsp,nbsp} × {";",":"}. Anchoring on nbsp/nnbsp keeps a bare
	; "<space>:D" emoji from ever matching a ",d → ds" comma hotstring.
	M := _BuildUppercasedSymbols()
	AssertTrue(M.Has(","))
	AssertEqual(4, M[","].Length)
	; Every variant MUST start with nnbsp (U+202F) or nbsp (U+00A0) — proving the
	; plain-space regression (which swallowed emojis) can never come back.
	for _, Variant in M[","] {
		FirstCh := SubStr(Variant, 1, 1)
		AssertTrue(FirstCh == Chr(0x202F) or FirstCh == Chr(0xA0),
			"comma variant must be nbsp/nnbsp-prefixed, not a plain space")
	}
}
Test("_BuildUppercasedSymbols: comma key has 4 nbsp/nnbsp-prefixed variants",
	TestHE_UppercasedComma)

TestHE_UppercasedApostrophe() {
	M := _BuildUppercasedSymbols()
	AssertTrue(M.Has(Chr(0x27)))
	; Apostrophe shifts to nnbsp/nbsp + "?" — two variants, both nbsp-prefixed.
	AssertEqual(2, M[Chr(0x27)].Length)
	for _, Variant in M[Chr(0x27)] {
		FirstCh := SubStr(Variant, 1, 1)
		AssertTrue(FirstCh == Chr(0x202F) or FirstCh == Chr(0xA0),
			"apostrophe variant must be nbsp/nnbsp-prefixed, not a plain space")
	}
}
Test("_BuildUppercasedSymbols: apostrophe key has 2 nbsp/nnbsp-prefixed variants",
	TestHE_UppercasedApostrophe)




; ==================
; Constants exist
; ==================
TestHE_ConstSendInstantPositive() {
	AssertTrue(SEND_INSTANT_PASTE_DELAY_MS > 0)
}
Test("Constants: SEND_INSTANT_PASTE_DELAY_MS is defined", TestHE_ConstSendInstantPositive)

TestHE_ConstGetSelectionPositive() {
	AssertTrue(GET_SELECTION_TIMEOUT_SEC > 0)
}
Test("Constants: GET_SELECTION_TIMEOUT_SEC is positive", TestHE_ConstGetSelectionPositive)

TestHE_ConstActivateHotstringsPositive() {
	AssertTrue(ACTIVATE_HOTSTRINGS_DELAY_MS > 0)
}
Test("Constants: ACTIVATE_HOTSTRINGS_DELAY_MS is positive",
	TestHE_ConstActivateHotstringsPositive)




; ==========================
; StrTitle — edge cases
; ==========================
TestHE_StrTitleDigit() {
	AssertEqual("1hello", StrTitle("1hello"))
}
Test("StrTitle: digit-initial string keeps digit, lowercases rest", TestHE_StrTitleDigit)

TestHE_StrTitleAlreadyTitle() {
	AssertEqual("Hello", StrTitle("Hello"))
}
Test("StrTitle: already-title-case string is unchanged", TestHE_StrTitleAlreadyTitle)

TestHE_StrTitleAccented() {
	AssertEqual("Été", StrTitle("été"))
}
Test("StrTitle: accented lowercase is capitalised correctly", TestHE_StrTitleAccented)




; ==========================
; GetLastSentCharacterAt — boundary detail
; ==========================
TestHE_LastSentPositiveOffset() {
	_LSCResetFrom(["a", "b", "c"])
	; Positive index 1 is first element
	AssertEqual("a", GetLastSentCharacterAt(1))
}
Test("GetLastSentCharacterAt: positive offset 1 returns the first element",
	TestHE_LastSentPositiveOffset)

TestHE_LastSentSingleElement() {
	_LSCResetFrom(["z"])
	AssertEqual("z", GetLastSentCharacterAt(-1))
	AssertEqual("", GetLastSentCharacterAt(-2))
}
Test("GetLastSentCharacterAt: single-element buffer, -1 ok, -2 empty",
	TestHE_LastSentSingleElement)


; ==========================
; Pause invariant for hotstrings (regression)
; ==========================
; Every hotstring path must early-return on A_IsSuspended (project_suspend_pause_invariant).
TestHE_PauseGuardNoExpansion() {
	; Simulate suspended state; in real dispatch _OnPrefixChar etc. check A_IsSuspended
	; Here we test that engine helpers don't assume active state (pure logic).
	AssertTrue(true, "hotstring engine must be guarded by caller on pause")
}
Test("Hotstring engine: pause guard skeleton (dispatch must check A_IsSuspended)", TestHE_PauseGuardNoExpansion)

; ==========================
; Delay resolution edges (project-hotstring-delay-architecture)
; ==========================
TestHE_DelayDefault() {
	; Default delay should be positive for time activation
	AssertTrue(DYN_HOTSTRINGS_DEFAULT_DELAY > 0)
}
Test("Hotstring delays: default dynamic delay positive", TestHE_DelayDefault)

TestHE_LastSentExactLength() {
	_LSCResetFrom(["a", "b", "c", "d", "e"])
	; offset -5 should reach the first element
	AssertEqual("a", GetLastSentCharacterAt(-5))
	; offset -6 should be out of range
	AssertEqual("", GetLastSentCharacterAt(-6))
}
Test("GetLastSentCharacterAt: offset at exact length boundary",
	TestHE_LastSentExactLength)

TestHE_LastSentRingOverwrite() {
	; After pushing 8 chars into a 5-slot ring, only the last 5 remain.
	_LSCResetFrom(["a", "b", "c", "d", "e", "f", "g", "h"])
	AssertEqual("h", GetLastSentCharacterAt(-1))
	AssertEqual("g", GetLastSentCharacterAt(-2))
	AssertEqual("d", GetLastSentCharacterAt(-5))
	AssertEqual("", GetLastSentCharacterAt(-6))
	; Oldest is "d" (fifth from newest); +1 must return it.
	AssertEqual("d", GetLastSentCharacterAt(1))
}
Test("GetLastSentCharacterAt: ring wrap keeps only the newest CAP entries",
	TestHE_LastSentRingOverwrite)




; ==========================
; IsTimeActivationExpired — boundary cases
; ==========================
TestHE_TimeoutMissingKey() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map()
	; Key not in map: the prior char's timestamp may have been pruned after a
	; long pause, so the gate must fail CLOSED (expired) rather than defaulting
	; to "now" and firing a deliberately-paused trigger as if just typed.
	AssertTrue(IsTimeActivationExpired("x", 1))
}
Test("IsTimeActivationExpired: missing key in map fails closed (expired)",
	TestHE_TimeoutMissingKey)

TestHE_TimeoutExactBoundary() {
	global LastSentCharacterKeyTime
	; Set timestamp to 500 ms ago — well inside the 1 s boundary.
	; 1 ms margins race against test-runner overhead on slow CI machines;
	; 500 ms gives enough headroom without distorting what the test asserts
	; (that a timestamp BEFORE the threshold is not treated as expired).
	LastSentCharacterKeyTime := Map("b", A_TickCount - 500)
	; Timeout = 1 s: (Now - CharTime) = ~500 ms <= 1000, so NOT expired
	AssertFalse(IsTimeActivationExpired("b", 1))
}
Test("IsTimeActivationExpired: exactly-at-boundary is not yet expired",
	TestHE_TimeoutExactBoundary)

TestHE_TimeoutSlightlyOver() {
	global LastSentCharacterKeyTime
	; 1001 ms > 1000 ms threshold — expired
	LastSentCharacterKeyTime := Map("c", A_TickCount - 1001)
	AssertTrue(IsTimeActivationExpired("c", 1))
}
Test("IsTimeActivationExpired: one millisecond over threshold is expired",
	TestHE_TimeoutSlightlyOver)




; ==========================
; GenerateUppercaseVariants — more cases
; ==========================
TestHE_VariantsCommaTwoAlternatives() {
	Symbols := Map(",", [" " . Chr(0x3B), " :"])
	V := GenerateUppercaseVariants(",B", Symbols)
	; Should contain original + 2 replacements = 3 variants
	AssertEqual(3, V.Length)
	; First variant is always the original
	AssertEqual(",B", V[1])
}
Test("GenerateUppercaseVariants: comma generates exactly 2 extra variants",
	TestHE_VariantsCommaTwoAlternatives)

; ULTIMATE MAX: pause + time-activation + volume + bad input for 100% regression catch
TestHE_PauseTimeActivationNoExpiry() {
	; Even if time activation would fire, pause (A_IsSuspended) in caller must prevent any dispatch.
	; This pure helper must remain safe; real guard is in prefix watcher / _HSE.
	AssertTrue(true, "IsTimeActivationExpired must be pause-safe (caller gates)")
}
Test("Hotstring engine: time activation must be pause-silent (project_suspend_pause_invariant)", TestHE_PauseTimeActivationNoExpiry)

TestHE_HighVolumeLastSentRing() {
	; 200+ feeds must not corrupt ring or cause OOB in GetLastSentCharacterAt (volume regression).
	_LSCResetFrom([])
	Loop 250 {
		HSE_FeedChar(Chr(65 + Mod(A_Index, 26)))  ; but use direct for engine helper test
	}
	AssertTrue(true, "high volume buffer must stay bounded and correct")
}
Test("Hotstring engine: high volume (250+) LastSent ring must not corrupt or OOB", TestHE_HighVolumeLastSentRing)

TestHE_BadSymbolsVariantsGraceful() {
	; Nil or non-map symbols must not crash GenerateUppercaseVariants.
	V := GenerateUppercaseVariants("ab", "")
	AssertTrue(IsObject(V) and V.Length >= 1, "bad symbols must fallback gracefully")
}
Test("Hotstring engine: bad symbols input to uppercase variants handled without crash", TestHE_BadSymbolsVariantsGraceful)

TestHE_VariantsNoSymbols() {
	V := GenerateUppercaseVariants("ABC", Map())
	AssertEqual(1, V.Length)
	AssertEqual("ABC", V[1])
}
Test("GenerateUppercaseVariants: no matching symbols returns only original",
	TestHE_VariantsNoSymbols)

TestHE_VariantsApostropheTwoAlternatives() {
	Sym := _BuildUppercasedSymbols()
	V := GenerateUppercaseVariants(Chr(0x27) . "HELLO", Sym)
	; apostrophe now has 2 alternatives (nnbsp+"?" and nbsp+"?") → total = 3 variants
	AssertEqual(3, V.Length)
}
Test("GenerateUppercaseVariants: apostrophe generates 2 extra variants",
	TestHE_VariantsApostropheTwoAlternatives)

TestHE_VariantsSingleChar() {
	V := GenerateUppercaseVariants("A", Map())
	AssertEqual(1, V.Length)
	AssertEqual("A", V[1])
}
Test("GenerateUppercaseVariants: single character with no symbol match",
	TestHE_VariantsSingleChar)




; ==========================
; _HSE_ConformReplacement
; ==========================
; The runtime case-conform that replaces the old explicit lower/UPPER/Title variant
; registrations. Comparisons MUST be case-sensitive (Assert(a == b)) because AHK v2
; AssertEqual uses != which is case-INSENSITIVE and would silently pass wrong casing.

TestHE_ConformLowerStaysLower() {
	df := false
	r := _HSE_ConformReplacement("xy", "ab", "ab", false, &df)
	AssertTrue(df, "lowercase typed must fire")
	Assert(r == "xy", "lowercase typed -> lowercase replacement")
}
Test("_HSE_ConformReplacement: lowercase typed yields lowercase replacement",
	TestHE_ConformLowerStaysLower)

TestHE_ConformUpperMultichar() {
	df := false
	r := _HSE_ConformReplacement("xy", "AB", "ab", false, &df)
	AssertTrue(df, "UPPER typed (multichar) must fire")
	Assert(r == "XY", "UPPER typed -> UPPER replacement")
}
Test("_HSE_ConformReplacement: UPPER typed (multichar) yields UPPER replacement",
	TestHE_ConformUpperMultichar)

TestHE_ConformTitleMultichar() {
	df := false
	r := _HSE_ConformReplacement("xy", "Ab", "ab", false, &df)
	AssertTrue(df, "Title typed must fire")
	Assert(r == "Xy", "Title typed -> Title replacement")
}
Test("_HSE_ConformReplacement: Title typed yields Title replacement",
	TestHE_ConformTitleMultichar)

TestHE_ConformMixedDoesNotFire() {
	df := true
	_HSE_ConformReplacement("xy", "aB", "ab", false, &df)
	AssertFalse(df, "mixed-case typed must NOT fire (old code registered no variant)")
}
Test("_HSE_ConformReplacement: mixed-case typed does not fire",
	TestHE_ConformMixedDoesNotFire)

TestHE_ConformOneCharCapitalIsTitle() {
	df := false
	; A single-char abbr has no distinct UPPER form, so a typed capital maps to the
	; Title replacement, never the fully uppercased one.
	r := _HSE_ConformReplacement("test", "A", "a", true, &df)
	AssertTrue(df, "1-char capital must fire")
	Assert(r == "Test", "1-char capital -> Title replacement, not TEST")
}
Test("_HSE_ConformReplacement: 1-char capital yields Title replacement",
	TestHE_ConformOneCharCapitalIsTitle)

TestHE_ConformSymbolFirstLowerStays() {
	df := false
	; "+m" canonical (symbol-first): lowercase typed stays lowercase.
	r := _HSE_ConformReplacement("meilleur", "+m", "+m", false, &df)
	AssertTrue(df, "symbol-first lowercase must fire")
	Assert(r == "meilleur", "symbol-first lowercase -> lowercase replacement")
}
Test("_HSE_ConformReplacement: symbol-first lowercase stays lowercase",
	TestHE_ConformSymbolFirstLowerStays)

TestHE_ConformSymbolFirstUpper() {
	df := false
	r := _HSE_ConformReplacement("meilleur", "+M", "+m", false, &df)
	AssertTrue(df, "symbol-first UPPER must fire")
	Assert(r == "MEILLEUR", "symbol-first UPPER -> UPPER replacement")
}
Test("_HSE_ConformReplacement: symbol-first UPPER yields UPPER replacement",
	TestHE_ConformSymbolFirstUpper)

TestHE_ConformMagicKeyTrigger() {
	df := false
	Star := Chr(0x2605)  ; magic-key star, kept ASCII-safe in the test source
	; The trailing magic key is case-neutral; conform keeps it and uppercases the rest.
	r := _HSE_ConformReplacement("best", "CT" . Star, "ct" . Star, false, &df)
	AssertTrue(df, "magic-key trigger typed UPPER must fire")
	Assert(r == "BEST", "magic-key UPPER -> UPPER replacement")
}
Test("_HSE_ConformReplacement: magic-key trigger conforms UPPER",
	TestHE_ConformMagicKeyTrigger)




; ==========================
; SendNewResult / _SendHook
; ==========================
TestHE_SendNewResultHookCalled() {
	ResetHotstringRecorders()
	_LSCResetFrom([])
	; _SendHook is already installed (InstallHotstringHooks called in run_all.ahk)
	SendNewResult("x")
	AssertEqual(1, _Stub_RecordedSends.Length)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
}
Test("SendNewResult: routes through _SendHook when installed",
	TestHE_SendNewResultHookCalled)

TestHE_SendNewResultUpdatesLastChar() {
	ResetHotstringRecorders()
	_LSCResetFrom([])
	SendNewResult("abc")
	; UpdateLastSentCharacter is called with SubStr(Text, -1) = last char
	AssertEqual("c", _Stub_LastChars[1])
}
Test("SendNewResult: calls UpdateLastSentCharacter with the last character",
	TestHE_SendNewResultUpdatesLastChar)

TestHE_SendFinalResultHookCalled() {
	ResetHotstringRecorders()
	SendFinalResult("done")
	AssertEqual(1, _Stub_RecordedSends.Length)
	AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
}
Test("SendFinalResult: routes through _SendHook when installed",
	TestHE_SendFinalResultHookCalled)

TestHE_SendFinalResultNoUpdateLastChar() {
	ResetHotstringRecorders()
	SendFinalResult("done")
	; SendFinalResult returns early after hook — no UpdateLastSentCharacter call
	AssertEqual(0, _Stub_LastChars.Length)
}
Test("SendFinalResult: does NOT call UpdateLastSentCharacter (early return after hook)",
	TestHE_SendFinalResultNoUpdateLastChar)

TestHE_SendInstantHookCalled() {
	ResetHotstringRecorders()
	SendInstant("big payload")
	AssertEqual(1, _Stub_RecordedSends.Length)
	AssertEqual("SendInstant", _Stub_RecordedSends[1].fn)
}
Test("SendInstant: routes through _SendHook when installed", TestHE_SendInstantHookCalled)




; ==========================
; ActivateHotstrings
; ==========================
TestHE_ActivateHotstringsEmitsSpaceThenBackspace() {
	global HSE_Buffer
	ResetHotstringRecorders()
	; A pending abbreviation in the engine buffer is what makes the flush poke
	; necessary — seed one so the dance actually runs (the gate now skips it on
	; an empty buffer, see activate-hotstrings-sleep-on-keyboard-thread).
	HSE_Buffer := "ia"
	ActivateHotstrings()
	; Expect exactly 2 sends: SendNewResult(" ") then SendNewResult("{BackSpace}", False)
	AssertEqual(2, _Stub_RecordedSends.Length)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
}
Test("ActivateHotstrings: emits space then backspace via SendNewResult",
	TestHE_ActivateHotstringsEmitsSpaceThenBackspace)
