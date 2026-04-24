; static/drivers/autohotkey/tests/test_hotstring_engine.ahk

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
	M := _BuildUppercasedSymbols()
	AssertTrue(M.Has(","))
	AssertEqual(2, M[","].Length)
}
Test("_BuildUppercasedSymbols: contains the comma key with two variants",
	TestHE_UppercasedComma)

TestHE_UppercasedApostrophe() {
	M := _BuildUppercasedSymbols()
	AssertTrue(M.Has(Chr(0x27)))
	AssertEqual(1, M[Chr(0x27)].Length)
}
Test("_BuildUppercasedSymbols: apostrophe key uses Chr(0x27)", TestHE_UppercasedApostrophe)




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
	; Key not in map; implementation falls back to Now, so never expired
	AssertFalse(IsTimeActivationExpired("x", 1))
}
Test("IsTimeActivationExpired: missing key in map never triggers expiry",
	TestHE_TimeoutMissingKey)

TestHE_TimeoutExactBoundary() {
	global LastSentCharacterKeyTime
	; Set timestamp to exactly TimeActivationSeconds * 1000 ms ago
	LastSentCharacterKeyTime := Map("b", A_TickCount - 1000)
	; Timeout = 1 s and key is exactly 1 s old: (Now - CharTime) == 1000
	; The condition is strictly >, so exactly at boundary is NOT expired
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

TestHE_VariantsNoSymbols() {
	V := GenerateUppercaseVariants("ABC", Map())
	AssertEqual(1, V.Length)
	AssertEqual("ABC", V[1])
}
Test("GenerateUppercaseVariants: no matching symbols returns only original",
	TestHE_VariantsNoSymbols)

TestHE_VariantsApostropheOneAlternative() {
	Sym := _BuildUppercasedSymbols()
	V := GenerateUppercaseVariants(Chr(0x27) . "HELLO", Sym)
	; apostrophe has 1 alternative (" ?") so total = 2 variants
	AssertEqual(2, V.Length)
}
Test("GenerateUppercaseVariants: apostrophe generates 1 extra variant",
	TestHE_VariantsApostropheOneAlternative)

TestHE_VariantsSingleChar() {
	V := GenerateUppercaseVariants("A", Map())
	AssertEqual(1, V.Length)
	AssertEqual("A", V[1])
}
Test("GenerateUppercaseVariants: single character with no symbol match",
	TestHE_VariantsSingleChar)




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
	ResetHotstringRecorders()
	ActivateHotstrings()
	; Expect exactly 2 sends: SendNewResult(" ") then SendNewResult("{BackSpace}", False)
	AssertEqual(2, _Stub_RecordedSends.Length)
	AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
	AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
}
Test("ActivateHotstrings: emits space then backspace via SendNewResult",
	TestHE_ActivateHotstringsEmitsSpaceThenBackspace)
