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
	global LastSentCharacters
	LastSentCharacters := []
	AssertEqual("", GetLastSentCharacterAt(-1))
}
Test("GetLastSentCharacterAt: empty buffer returns empty string", TestHE_LastSentEmpty)

TestHE_LastSentOffsets() {
	global LastSentCharacters
	LastSentCharacters := ["a", "b", "c"]
	AssertEqual("c", GetLastSentCharacterAt(-1))
	AssertEqual("b", GetLastSentCharacterAt(-2))
}
Test("GetLastSentCharacterAt: returns offset value when available", TestHE_LastSentOffsets)

TestHE_LastSentOverflow() {
	global LastSentCharacters
	LastSentCharacters := ["x"]
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
