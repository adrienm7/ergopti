; tests/unit/modules/hotstrings/engine/test_hotstring_scalar_continuation.ahk

; ==============================================================================
; MODULE: Hotstring Scalar Continuation Arbitration
; DESCRIPTION:
; A complete consumed scalar may continue a longer STAR trigger. Shorter END
; rules yield only to that exact continuation, not an unrelated shared half.
; ==============================================================================

#Requires AutoHotkey v2.0

_HSUC_Case(Mode) {
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, HSE_MAX_BUFFER_LEN
	global HSE_Buffer, HSE_LastEndChar, HSE_Suppressed, _PrefixWatcherSuppressed, _PrefixLastKeyTick
	Saved := { Words: HSE_WORD_TERMINATORS, Consumed: HSE_CONSUMED_DELIMITERS,
		Capacity: HSE_MAX_BUFFER_LEN, Suppressed: HSE_Suppressed,
		PrefixSuppressed: _PrefixWatcherSuppressed, Tick: _PrefixLastKeyTick }
	try {
		HSE_TestReset()
		Face := Chr(0x1F600), Other := Chr(0x1F601)
		HSE_WORD_TERMINATORS := " " . Face . Other
		HSE_CONSUMED_DELIMITERS := Face . Other
		HSE_MAX_BUFFER_LEN := 32
		HSE_Register("C", "qr", (*) => 0, { Replacement: "END", OnlyText: true })
		Trigger := (Mode == "ci-continuation" ? "QR" : "qr") . Face . "x"
		HSE_Register(Mode == "ci-continuation" ? "*" : "*C", Trigger, (*) => 0,
			{ Replacement: "LONG", OnlyText: true })
		HSE_FeedChar("q", true), HSE_FeedChar("r", true)
		Typed := Mode == "shared-high-negative" ? Other : Face
		Match := HSE_FeedChar(Typed, true)
		if Mode == "shared-high-negative" {
			AssertTrue(IsObject(Match), "an unrelated full scalar must not borrow another continuation's high half")
			AssertEqual("qr", Match.Trigger, "the ordinary END rule remains eligible for the different delimiter")
			AssertFalse(Match.Star)
			AssertEqual(Other, HSE_LastEndChar)
			HSE_ApplyExpansion(Match, "END", HSE_LastEndChar)
			AssertEqual("END", HSE_Buffer, "the independent consumed delimiter is removed by the real buffer publisher")
		} else {
			AssertFalse(IsObject(Match), "a complete scalar continuation must defer the shorter END expansion")
			AssertEqual("qr" . Face, HSE_Buffer, "arbitration must preserve the exact observed prefix")
			AssertEqual("", HSE_LastEndChar)
			Match := HSE_FeedChar("x", true)
			AssertTrue(IsObject(Match), "the unmodified prefix must still complete the longer STAR rule")
			AssertEqual(Trigger, Match.Trigger)
			AssertTrue(Match.Star)
			AssertEqual("", HSE_LastEndChar)
			HSE_ApplyExpansion(Match, "LONG")
			AssertEqual("LONG", HSE_Buffer, "the completed STAR rule publishes its own replacement once")
		}
	} finally {
		HSE_WORD_TERMINATORS := Saved.Words
		HSE_CONSUMED_DELIMITERS := Saved.Consumed
		HSE_MAX_BUFFER_LEN := Saved.Capacity
		HSE_TestReset()
		HSE_Suppressed := Saved.Suppressed
		_PrefixWatcherSuppressed := Saved.PrefixSuppressed
		_PrefixLastKeyTick := Saved.Tick
	}
}

for _HSUC_Mode in ["ci-continuation", "cs-continuation", "shared-high-negative"]
	Test("HSE scalar continuation: " . _HSUC_Mode . " arbitrates complete prefixes (hse-scalar-continuation)", _HSUC_Case.Bind(_HSUC_Mode))
