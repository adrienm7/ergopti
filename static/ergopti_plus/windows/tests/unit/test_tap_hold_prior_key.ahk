; tests/unit/test_tap_hold_prior_key.ahk

; ==============================================================================
; MODULE: Tap-hold prior-key guard
; DESCRIPTION:
; A tap-hold release may fire its tap action only when the last key pressed
; before it was the key itself. The guards compared A_PriorKey with hand-written
; names, but A_PriorKey is the name AHK derives from the recorded virtual key and
; scan code through the active layout: never an "SCxxx" string, "Backspace"
; rather than "BackSpace", and "^" for the Kana AltGr of the Ergopti layout.
; "SC138" and "BackSpace" could therefore never match, so the AltGr tap on Kana
; layouts and every Backspace tap with a hold never fired
; (tap-hold-prior-key-2026-09-25). TapHoldPriorKeyIsSelf derives the expected
; name from the key's own scan code at call time instead.
; ==============================================================================

#Requires AutoHotkey v2.0

_THPK_BackspaceUsesAhkSpelling() {
	AssertTrue(TapHoldPriorKeyIsSelf("backspace", GetKeyName("vk08sc00E")),
		"a Backspace press recorded by the hook must count as the Backspace tap-hold key itself")
	AssertFalse(TapHoldPriorKeyIsSelf("backspace", "BackSpace"),
		"AHK spells the key 'Backspace'; the old literal 'BackSpace' never matched under case-sensitive ==")
}
Test("tap-hold prior key: Backspace matches the name AHK records (tap-hold-prior-key-2026-09-25)",
	_THPK_BackspaceUsesAhkSpelling)

_THPK_KanaAltGrUsesTheLayoutName() {
	KanaNames := (Name) => (Name == "SC138" ? "^" : GetKeyName(Name))
	AssertTrue(TapHoldPriorKeyIsSelf("alt_gr", "^", KanaNames),
		"on the Ergopti Kana layout the hook records AltGr (vkDF, sc138) as '^'")
	AssertFalse(TapHoldPriorKeyIsSelf("alt_gr", "SC138", KanaNames),
		"A_PriorKey is never an 'SCxxx' string")
	AssertFalse(TapHoldPriorKeyIsSelf("alt_gr", "RAlt", KanaNames),
		"RAlt is not the Kana layout's AltGr")
	StandardNames := (Name) => (Name == "SC138" ? "RAlt" : GetKeyName(Name))
	AssertTrue(TapHoldPriorKeyIsSelf("alt_gr", "RAlt", StandardNames),
		"on a standard AltGr layout the same key is recorded as 'RAlt'")
	AssertFalse(TapHoldPriorKeyIsSelf("alt_gr", "^", StandardNames),
		"a layout-specific literal must not leak into the standard layout's guard")
}
Test("tap-hold prior key: the AltGr guard follows the layout (tap-hold-prior-key-2026-09-25)",
	_THPK_KanaAltGrUsesTheLayoutName)

_THPK_EveryKeyMatchesWhatTheHookRecords() {
	global _TH_TapHoldScToKeyId
	Checked := 0
	for Sc, KeyId in _TH_TapHoldScToKeyId {
		ScName := Format("SC{:03X}", Sc)
		Recorded := GetKeyName(Format("vk{:X}sc{:X}", GetKeyVK(ScName), Sc))
		AssertTrue(TapHoldPriorKeyIsSelf(KeyId, Recorded),
			"tap-hold key '" . KeyId . "' must match the name the hook records for " . ScName
			. " on the current layout ('" . Recorded . "')")
		Checked++
	}
	Assert(Checked >= 14, "every tap-hold scan code must be checked, got " . Checked)
}
Test("tap-hold prior key: every tap-hold key matches its own recorded name (tap-hold-prior-key-2026-09-25)",
	_THPK_EveryKeyMatchesWhatTheHookRecords)

_THPK_NamesTheKeysOwnScanCode() {
	Asked := []
	Spy(Name) {
		Asked.Push(Name)
		return GetKeyName(Name)
	}
	TapHoldPriorKeyIsSelf("alt_gr", "x", Spy)
	TapHoldPriorKeyIsSelf("backspace", "x", Spy)
	AssertEqual(2, Asked.Length, "the helper must derive exactly one expected name per call")
	AssertEqual("SC138", Asked[1], "alt_gr must be named from its physical scan code")
	AssertEqual("SC00E", Asked[2], "backspace must be named from its physical scan code")
}
Test("tap-hold prior key: the expected name comes from the key's scan code (tap-hold-prior-key-2026-09-25)",
	_THPK_NamesTheKeysOwnScanCode)

_THPK_EmptyHistoryAndUnknownKeys() {
	AssertFalse(TapHoldPriorKeyIsSelf("left_shift", ""),
		"an empty key history must never pass as the key itself")
	AssertFalse(TapHoldPriorKeyIsSelf("left_shift", "a"),
		"another key pressed last must block the tap")
	AssertThrows(() => TapHoldPriorKeyIsSelf("not_a_tap_hold_key", "a"),
		"an unknown tap-hold id is a programming error, not a silent false")
}
Test("tap-hold prior key: empty history and unknown ids (tap-hold-prior-key-2026-09-25)",
	_THPK_EmptyHistoryAndUnknownKeys)

; A layout can put a tap-hold key on a virtual key that has no name at all
; (VK_KANA-style AltGr remaps). AHK then reports an undocumented placeholder
; for A_PriorKey while GetKeyName answers "". The name cannot decide, so the
; scan-code activity tracker that every dispatch also consults stays the guard,
; and the situation is logged instead of silently losing every tap.
_THPK_UnnamedKeyDefersToTheActivityTracker() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Unnamed := (Name) => ""
		AssertTrue(TapHoldPriorKeyIsSelf("alt_gr", "not found", Unnamed),
			"an unnamed key must defer to the activity tracker instead of losing every tap")
		TapHoldPriorKeyIsSelf("alt_gr", "not found", Unnamed)
	} finally {
		LoggerClearTestSink()
	}
	Warnings := 0
	for Line in Captured {
		if InStr(Line, "[WARNING]") && InStr(Line, "alt_gr")
			Warnings++
	}
	AssertEqual(1, Warnings, "an unnamed tap-hold key must be reported once, not on every press")
}
Test("tap-hold prior key: an unnamed key defers to the activity tracker (tap-hold-prior-key-2026-09-25)",
	_THPK_UnnamedKeyDefersToTheActivityTracker)
