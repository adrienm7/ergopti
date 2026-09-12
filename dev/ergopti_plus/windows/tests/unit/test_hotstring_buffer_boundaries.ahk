; tests/unit/test_hotstring_buffer_boundaries.ahk

; ==============================================================================
; MODULE: Hotstring Buffer Boundary Tests
; DESCRIPTION:
; Replays maximum-length triggers through character input, preview and dispatch.
; Termination framing must not consume trigger capacity or invent word boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

_HBB_Trigger(Length) {
	Trigger := "z"
	loop Length - 1
		Trigger .= "a"
	return Trigger
}

_HBB_Feed(Text) {
	Match := ""
	for Char in StrSplit(Text)
		Match := HSE_FeedChar(Char)
	return Match
}

_HBB_MaximumTerminatedTrigger(Framing, Conform := false) {
	global HSE_Buffer, HSE_MAX_BUFFER_LEN, HSE_LastEndChar, HSE_TypoNbspStripped
	global HSE_CONSUMED_DELIMITERS
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	HSE_TestReset()
	ResetHotstringRecorders()
	SimulateRegularApp()
	try {
		HSE_CONSUMED_DELIMITERS := ""
		Trigger := _HBB_Trigger(HSE_MAX_BUFFER_LEN)
		HSE_Register("?", Trigger, (*) => 0,
			{Replacement: "done", OnlyText: true, CaseConform: Conform})
		_HBB_Feed(Conform ? StrUpper(Trigger) : Trigger)
		if StrLen(Framing) > 1
			_HBB_Feed(SubStr(Framing, 1, -1))
		EndChar := SubStr(Framing, -1)
		BeforePreview := HSE_Buffer
		Preview := HSE_PreviewNextDecision(HSE_Buffer, EndChar)
		AssertTrue(IsObject(Preview), "maximum-length completion must remain available to preview")
		AssertEqual(BeforePreview, HSE_Buffer, "preview must not consume live framing")
		Match := HSE_FeedChar(EndChar)
		AssertTrue(IsObject(Match), "termination framing must not evict the first trigger character")
		AssertEqual(EndChar, HSE_LastEndChar, "the actual terminator must reach dispatch")
		AssertEqual(StrLen(Framing) > 1, HSE_TypoNbspStripped, "typography framing belongs to the selected match")
		ExpectedReplacement := Conform ? "DONE" : "done"
		AssertEqual(ExpectedReplacement, Preview.Replacement, "preview must retain complete typed case context")
		AssertTrue(HSE_DispatchMatch(Match, HSE_LastEndChar), "the maximum-length match must emit")
		AssertEqual("{BackSpace " . (HSE_MAX_BUFFER_LEN + StrLen(Framing)) . "}{Text}"
			. ExpectedReplacement . EndChar, _ConformDF_LastBurst(), "dispatch must replace the exact framed trigger")
		AssertEqual(ExpectedReplacement . EndChar, HSE_Buffer, "the model must match emitted text")
	} finally {
		HSE_CONSUMED_DELIMITERS := SavedConsumed
		HSE_TestReset()
	}
}
Test("HSE buffer: full-length trigger retains its delimiter (hse-buffer-boundaries)",
	_HBB_MaximumTerminatedTrigger.Bind(" "))
Test("HSE buffer: full-length trigger retains NBSP colon framing (hse-buffer-boundaries)",
	_HBB_MaximumTerminatedTrigger.Bind(Chr(0xA0) . ":"))
Test("HSE buffer: full-length trigger retains NNBSP semicolon framing (hse-buffer-boundaries)",
	_HBB_MaximumTerminatedTrigger.Bind(Chr(0x202F) . ";"))
Test("HSE buffer: maximum-length preview and dispatch preserve typed case (hse-buffer-boundaries)",
	_HBB_MaximumTerminatedTrigger.Bind(" ", true))

_HBB_TrimKeepsObservedBoundary() {
	global HSE_MAX_BUFFER_LEN
	try {
		for Prefix in [" ", "x"] {
			HSE_TestReset()
			Trigger := _HBB_Trigger(HSE_MAX_BUFFER_LEN)
			HSE_Register("*", Trigger, (*) => 0, {Replacement: "done", OnlyText: true})
			_HBB_Feed(Prefix)
			Match := _HBB_Feed(Trigger)
			AssertEqual(Prefix == " ", IsObject(Match),
				"truncation must preserve the actual character preceding a word trigger")
		}
	} finally HSE_TestReset()
}
Test("HSE buffer: truncation retains known word boundaries (hse-buffer-boundaries)",
	_HBB_TrimKeepsObservedBoundary)

_HBB_FramingDoesNotExtendTriggerCapacity() {
	global HSE_MAX_BUFFER_LEN, HSE_Buffer
	try {
		HSE_TestReset()
		Trigger := _HBB_Trigger(HSE_MAX_BUFFER_LEN) . " "
		HSE_Register("*?", Trigger, (*) => 0, {Replacement: "oversized", OnlyText: true})
		AssertEqual("", _HBB_Feed(Trigger), "framing reserve must not admit an oversized star trigger")
		HSE_FeedChar("x")
		AssertEqual(HSE_MAX_BUFFER_LEN, StrLen(HSE_Buffer), "ordinary input must release unused framing capacity")
	} finally HSE_TestReset()
}
Test("HSE buffer: framing reserve does not extend trigger capacity (hse-buffer-boundaries)",
	_HBB_FramingDoesNotExtendTriggerCapacity)

_HBB_OversizedStarCannotMaskValidCompletion() {
	global HSE_MAX_BUFFER_LEN
	try {
		HSE_TestReset()
		Trigger := _HBB_Trigger(HSE_MAX_BUFFER_LEN)
		HSE_Register("?", Trigger, (*) => 0, {Replacement: "done", OnlyText: true})
		HSE_Register("*?", Trigger . " ", (*) => 0, {Replacement: "oversized", OnlyText: true})
		_HBB_Feed(Trigger)
		Match := HSE_FeedChar(" ")
		AssertTrue(IsObject(Match), "an unmatchable star continuation must not mask a valid completion")
		AssertEqual(Trigger, Match.Trigger, "the valid nonstar trigger must own the completion")
	} finally HSE_TestReset()
}
Test("HSE buffer: impossible star continuation cannot mask a valid trigger (hse-buffer-boundaries)",
	_HBB_OversizedStarCannotMaskValidCompletion)
