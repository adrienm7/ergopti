; static/ergopti_plus/windows/tests/unit/hotstrings/engine/preview/test_defers_to_engine.ahk

; ==============================================================================
; MODULE: Preview / Engine Word-Boundary Agreement (regression)
; DESCRIPTION:
; The tooltip advertised an expansion the engine then refused. Typing "at" and
; pressing the magic key produced "att" (the repeat key doubling the "t"), while
; the tooltip offered "tt -> télétravail" — a trigger the engine will not fire
; mid-word. Pressing the magic key again did nothing, because the engine was
; right and the tooltip was wrong.
;
; ROOT CAUSE ENCODED — TWO BUFFERS, TWO QUESTIONS:
; The preview inferred "am I at a word start?" from its OWN anchor: the suffix
; after the last boundary character in _PrefixBuffer. The engine asks
; _HSE_WordBoundaryAllows(HSE_Buffer, Spec). Those are different questions over
; different buffers, and they diverge after any expansion because _PrefixBuffer
; is rebuilt by the watcher's post-expansion sync while HSE_Buffer keeps the real
; typed context.
;
; Measured, from the driver's own DEBUG log (2026-07-21 18:10:30):
;     OnChar: char='★' prefixBuf='at' hseBuf='…télétravail ⚠️ at'
;     FIRE trig='t★' bs=2 burst='{BackSpace 2}{Text}tt'
;     _LookupAndRender: buf='tt'  ->  prefix MATCH for 'tt' (2 candidates)
; The watcher's buffer became "tt"; the engine's stayed "…att". "tt" looked
; word-initial to the preview and mid-word to the engine.
;
; WHY IT WAS SILENT:
; Nothing throws. The tooltip renders, the engine declines, and the two never
; compare notes — the only symptom is a suggestion that refuses to be validated,
; which reads as "the magic key didn't work" rather than as a preview defect.
;
; THE FIX:
; _PrefixCollectCandidates asks HSE_PreviewNextDecision directly. That oracle
; runs the real matcher, ordered personal/repeat fallbacks and dispatch gates,
; so no preview-local candidate exists to bypass a boundary or hide a different
; fallback winner.
; ==============================================================================





; ===================================================
; ===================================================
; ======= 1/ The Preview Defers To The Engine =======
; ===================================================
; ===================================================

; Registers a single star trigger with the real engine and points the engine
; buffer at `Buf`, so the collector sees a faithful registry.
; @param Trigger The trigger to register (e.g. "tt★").
; @param Buf     The engine buffer to simulate.
_PreviewAgree_Setup(Trigger, Buf) {
	global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_Buffer, HSE_StartIsWordBoundary
	global ScriptInformation
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "★"
	; Clear through the engine's own entry point rather than re-initialising the
	; globals by hand: they are not all Maps (HSE_StarSpecs is an Array), and a
	; hand-built registry would be testing a shape the engine never produces.
	HSE_RegistryClear()
	; "*" marks a star trigger, no "?" so the trigger is word-anchored — the
	; same flags a normal magic-key hotstring is registered with.
	Spec := HSE_Register("*", Trigger, 0,
		Map("Replacement", "expanded", "OnlyText", true,
			"Category", "test", "Section", "boundary"))
	HSE_Buffer := Buf
	; The buffer start is a real word boundary in every case below, so a refusal
	; can only come from the character preceding the trigger — never from an
	; unknown left edge.
	HSE_StartIsWordBoundary := true
	return Spec
}

; @return The canonical row for Trigger, or "" when that trigger is not the
; engine's complete next decision.
_PreviewAgree_RowFor(Trigger) {
	for _, Row in _PrefixCollectCandidates() {
		if Row.Trigger == Trigger
			return Row
	}
	return ""
}

TestPreviewAgree_RefusesMidWordStarTrigger() {
	; The measured case: engine buffer ends "att", so the "tt" body of "tt★" is
	; preceded by a letter and the engine will not fire it.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer att")
	Assert(!IsObject(_PreviewAgree_RowFor("tt" . "★")),
		"a star trigger whose body sits mid-word must NOT be offered — the engine refuses it, "
		. "so advertising it produces a tooltip the magic key cannot validate")
}
Test("preview: a mid-word star trigger is not offered",
	TestPreviewAgree_RefusesMidWordStarTrigger)

TestPreviewAgree_OffersStarTriggerAtWordStart() {
	; The mirror case — the fix must not silence legitimate suggestions.
	Spec := _PreviewAgree_Setup("tt" . "★", "je viens d’activer tt")
	Row := _PreviewAgree_RowFor("tt" . "★")
	Assert(IsObject(Row),
		"the same trigger at a genuine word start must still be offered, or the fix has "
		. "traded a false positive for a false negative")
	Assert(Row.HasOwnProp("FireDecision")
		and ObjPtr(Row.FireDecision.Spec) == ObjPtr(Spec),
		"the offered row must carry the exact live Spec selected by the canonical engine decision")
}
Test("preview: a word-initial star trigger is still offered",
	TestPreviewAgree_OffersStarTriggerAtWordStart)

TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix() {
	; The SearchKey scan can surface a candidate whose body is not actually at
	; the end of the engine buffer. Offering it would advertise an expansion for
	; text the user has not typed.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer atx")
	Assert(!IsObject(_PreviewAgree_RowFor("tt" . "★")),
		"a candidate whose body does not end the engine buffer must not be offered")
}
Test("preview: a candidate that does not match the buffer suffix is not offered",
	TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix)

TestPreviewAgree_FailsClosedForUnknownTrigger() {
	global _PrefixIndex, _TriggerSet
	SavedIndex := _PrefixIndex
	SavedSet := _TriggerSet
	try {
		_PreviewAgree_Setup("tt" . "★", "je viens d’activer zz")
		_PrefixIndex := Map()
		_TriggerSet := Map()
		_AddTriggerToIndex("zz" . "★", "stale", "test", "removed", 999)
		Assert(_PrefixIndex.Has("zz"),
			"sanity: the obsolete catalogue row must exist for this test to prove it has no authority")
		Assert(!IsObject(_PreviewAgree_RowFor("zz" . "★")),
			"an unregistered trigger must fail closed even when the auxiliary catalogue still contains it")
	} finally {
		_PrefixIndex := SavedIndex
		_TriggerSet := SavedSet
	}
}
Test("preview: an unknown trigger fails closed",
	TestPreviewAgree_FailsClosedForUnknownTrigger)


; During a live rebuild the engine refuses every registered match and both
; fallbacks, so every preview source must stay closed until the new generation
; is published.
TestPreviewAgree_RebuildFenceOverridesFailOpen() {
	global HSE_RebuildInProgress
	PreviousRebuild := HSE_RebuildInProgress
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer tt")
	try {
		HSE_RebuildInProgress := true
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a registered trigger must not be offered while the engine’s rebuild fence makes it unavailable")
	} finally {
		HSE_RebuildInProgress := PreviousRebuild
	}
}
Test("preview: the live-rebuild fence keeps every candidate closed",
	TestPreviewAgree_RebuildFenceOverridesFailOpen)

TestPreviewAgree_NoOpCandidateLosesToCanonicalFallback() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RepeatEnabled
	global ScriptInformation, LastSentCharacterKeyTime
	MK := ScriptInformation["MagicKey"]
	SavedRepeat := HSE_RepeatEnabled
	SavedStamps := LastSentCharacterKeyTime
	HSE_RegistryClear()
	try {
		HSE_RepeatEnabled := true
		HSE_Register("*", "ok" . MK, 0,
			Map("Replacement", "ok" . MK, "Category", "test", "Section", "noop"))
		HSE_Buffer := "ok"
		HSE_StartIsWordBoundary := true
		; The repeat answers within the magic key's window, measured from the
		; repeated letter (repeat-window): this buffer was set, not typed.
		LastSentCharacterKeyTime := Map("k", A_TickCount)

		Decision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		Assert(IsObject(Decision) and Decision.Spec.HasOwnProp("TransientKind")
			and Decision.Spec.TransientKind == "repeat",
			"the engine must reject the no-op mapping and hand the magic key to its repeat fallback")
		; The repeat winner is never offered (no-repeat-preview). Withholding it
		; must leave the bubble empty rather than promote the no-op it beat.
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"the tooltip must advertise neither the rejected no-op mapping nor the doubling that beats it")
	} finally {
		LastSentCharacterKeyTime := SavedStamps
		HSE_RepeatEnabled := SavedRepeat
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: a no-op candidate cannot stand in for the withheld repeat winner",
	TestPreviewAgree_NoOpCandidateLosesToCanonicalFallback)





; ===============================================
; ===============================================
; ======= 2/ An Output That Presses A Key =======
; ===============================================
; ===============================================

; The live incident: `gcm★` > `git commit -m "{Left}"` fired, and sent its Left
; arrow, yet the driver logged « No prefix match » for the three typed letters of
; every attempt while `gm★` next to it showed its bubble. Dropping the row hid the
; 0.75 s gate too: waiting for a bubble that could not come ran the gate out, and
; the magic key was then refused with no trace on screen.
; @param CaseSensitive {Boolean} The TOML is_case_sensitive flag.
; @param Trigger {String} The trigger, magic key included.
; @param Output {String} The output as the TOML holds it.
; @param Buf {String} The typed engine buffer.
; @return {Object} The row of the registered trigger, or "".
_PreviewAgree_KeyOutputRow(CaseSensitive, Trigger, Output, Buf) {
	global HSE_Buffer, HSE_StartIsWordBoundary
	HSE_RegistryClear()
	HSE_RegisterFromTomlFlags(CaseSensitive, "*", Trigger, Output,
		Map("Category", "test", "Section", "code", "FinalResult", true))
	HSE_Buffer := Buf
	HSE_StartIsWordBoundary := true
	Rows := _PrefixCollectCandidates()
	return Rows.Length > 0 ? Rows[Rows.Length] : ""
}

TestPreviewAgree_KeyOutputShowsItsText() {
	MK := ScriptInformation["MagicKey"]
	try {
		Row := _PreviewAgree_KeyOutputRow(true, "gcm" . MK, 'git commit -m "{Left}"', "gcm")
		Assert(IsObject(Row),
			"an output that presses a key must keep its bubble: it fires, so the preview must offer it")
		AssertEqual('git commit -m ""', Row.Output,
			"the bubble shows what the output types, never the key token")
		AssertEqual(false, Row.FireDecision.OnlyText,
			"the decision still sends the key: only the display text is plain")
		AssertEqual('git commit -m "{Left}"', Row.FireDecision.Replacement,
			"the frozen payload keeps its key")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: an output with a key shows its typed text (preview-key-output)",
	TestPreviewAgree_KeyOutputShowsItsText)

; The two case families reach the Spec through different factories, and the
; typed casing must reach the bubble as it reaches the output.
TestPreviewAgree_KeyOutputFollowsTheTypedCase() {
	MK := ScriptInformation["MagicKey"]
	try {
		Row := _PreviewAgree_KeyOutputRow(false, "ab" . MK, "xy(){Left}", "AB")
		Assert(IsObject(Row), "the conform family must keep its bubble")
		AssertEqual("XY()", Row.Output, "a capitalised typing capitalises the bubble")
		Row := _PreviewAgree_KeyOutputRow(false, "ab" . MK, "xy(){Left}", "Ab")
		AssertEqual("Xy()", Row.Output, "a title-cased typing title-cases the bubble")
		Row := _PreviewAgree_KeyOutputRow(false, "ab," . MK, "xy(){Left}", "ab,")
		Assert(IsObject(Row), "the explicit-variant family must keep its bubble")
		AssertEqual("xy()", Row.Output, "the explicit-variant family carries the text too")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: a key output's bubble follows the typed case (preview-key-output)",
	TestPreviewAgree_KeyOutputFollowsTheTypedCase)

; Nothing to show: a row with an empty text would be a blank bubble.
TestPreviewAgree_KeyOnlyOutputHasNoRow() {
	MK := ScriptInformation["MagicKey"]
	try {
		AssertEqual("", _PreviewAgree_KeyOutputRow(true, "zz" . MK, "{Left 2}", "zz"),
			"an output that only presses keys types no text to preview")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: an output of keys alone has no row (preview-key-output)",
	TestPreviewAgree_KeyOnlyOutputHasNoRow)

; The other half of the incident: past the delay the bubble retires and the magic
; key changes nothing. That refusal left no trace of which gate took it.
TestPreviewAgree_ExpiredGateIsCountedAtDispatch() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_LastEndChar, LastSentCharacterKeyTime
	MK := ScriptInformation["MagicKey"]
	Saved := IsSet(LastSentCharacterKeyTime) ? LastSentCharacterKeyTime : Map()
	Series := _HotPathStatisticsOwner().Stats.Series
	if Series.Has("HSE.Refused.preflight")
		Series.Delete("HSE.Refused.preflight")
	try {
		HSE_RegistryClear()
		HSE_RegisterFromTomlFlags(true, "*", "gcm" . MK, 'git commit -m "{Left}"',
			Map("Category", "test", "Section", "code", "FinalResult", true, "TimeActivationSeconds", 0.75))
		HSE_Buffer := "gcm"
		HSE_StartIsWordBoundary := true
		LastSentCharacterKeyTime := Map("m", A_TickCount)
		AssertEqual(1, _PrefixCollectCandidates().Length, "inside the delay the bubble offers the entry")

		LastSentCharacterKeyTime := Map("m", A_TickCount - 5000)
		AssertEqual(0, _PrefixCollectCandidates().Length, "past the delay the bubble is gone")
		Match := HSE_FeedChar(MK, true)
		Assert(IsObject(Match), "the matcher still finds the entry: only the gate refuses it")
		Effect := 0
		AssertFalse(HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect), "the gate refuses the fire")
		Assert(Series.Has("HSE.Refused.preflight"), "the refusal names its gate in the statistics")
	} finally {
		LastSentCharacterKeyTime := Saved
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: a key output past its delay is refused and counted (preview-key-output)",
	TestPreviewAgree_ExpiredGateIsCountedAtDispatch)





; =======================================
; =======================================
; ======= 3/ Enter And Tab Expand =======
; =======================================
; =======================================

; The live incident: `ko` + Space gave `KO`, `ko` + Enter and `ko` + Tab stayed
; `ko`. OnKeyDown wiped both buffers for those two keys before OnChar brought
; their character, so the end character found an empty buffer. They are held back
; instead: nothing can be erased after Enter submitted a line, so the burst erases
; the trigger alone and its tail types the key.
; @param Char {String} The end character of the key.
; @param Typed {String} The typed engine buffer.
; @return {Object} Fired, Burst (the recorded send) and Buffer.
_EndKey_Complete(Char, Typed) {
	global HSE_Buffer, HSE_StartIsWordBoundary, _Stub_RecordedSends
	global _PrefixFocusedControlToken, _SendHook
	HSE_RegistryClear()
	HSE_RegisterFromTomlFlags(true, "", "ko", "KO",
		Map("Category", "test", "Section", "endkey"))
	HSE_Buffer := Typed
	HSE_StartIsWordBoundary := true
	_PrefixFocusedControlToken := WIGetFocusedControlToken()
	_Stub_RecordedSends := []
	SavedSendHook := _SendHook
	_SendHook := _HOOK_RecordSend
	; The foreground window of the run must not choose the delivery route.
	OutputHostResolverPrimeForTest("endkey-test.exe")
	try {
		Fired := HotstringCompleteEndKey(Char)
		Burst := _Stub_RecordedSends.Length > 0 ? _Stub_RecordedSends[1].args[1] : ""
		return { Fired: Fired, Burst: Burst, Buffer: HSE_Buffer }
	} finally {
		_SendHook := SavedSendHook
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

TestEndKey_EnterAndTabExpand() {
	for _, Char in ["`n", "`t"] {
		Result := _EndKey_Complete(Char, "ko")
		AssertTrue(Result.Fired, "the end key completes the entry")
		AssertEqual("{BackSpace 2}{Text}KO" . Char, Result.Burst,
			"only the trigger is on screen, and the tail types the key held back")
	}
}
Test("end key: Enter and Tab expand and land after the text (hotstring-end-keys)",
	TestEndKey_EnterAndTabExpand)

TestEndKey_NoEntryKeepsTheNativeKey() {
	AssertFalse(_EndKey_Complete("`n", "kx").Fired, "no entry: the caller sends the key")
	AssertEqual("", _EndKey_Complete("`n", "kx").Burst, "and nothing was typed")
	AssertFalse(_EndKey_Complete("`n", "KO").Fired,
		"a case-sensitive entry leaves an already capitalised KO to the native key")
	AssertFalse(_EndKey_Complete("`t", "").Fired, "an empty word has nothing to complete")
}
Test("end key: a key that completes nothing stays native (hotstring-end-keys)",
	TestEndKey_NoEntryKeepsTheNativeKey)

; The press that the hotkey took must not be wiped by the watcher that sees it.
TestEndKey_ClaimShieldsTheWord() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixEndKeyClaim, _PrefixEndKeyProbe
	try {
		AssertFalse(HotstringEndKeyClaim(0x0D, "`n"),
			"before the watcher publishes its probe, a #HotIf of the boot pump stays out")
		_PrefixEndKeyProbe := _PrefixClaimEndKey
		HSE_RegistryClear()
		HSE_RegisterFromTomlFlags(true, "", "ko", "KO",
			Map("Category", "test", "Section", "endkey"))
		HSE_Buffer := "ko"
		HSE_StartIsWordBoundary := true
		AssertTrue(HotstringEndKeyClaim(0x0D, "`n"), "the hotkey takes the press")
		_OnPrefixKeyDown(0, 0x0D, 0x1C)
		AssertEqual("ko", HSE_Buffer, "the claimed press leaves the word to the expansion")
		AssertEqual(0, _PrefixEndKeyClaim, "the claim covers one press")
		_OnPrefixKeyDown(0, 0x0D, 0x1C)
		AssertEqual("", HSE_Buffer, "any other Enter still ends the word")
	} finally {
		_PrefixEndKeyClaim := 0
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("end key: a claimed press keeps the word and only that press (hotstring-end-keys)",
	TestEndKey_ClaimShieldsTheWord)

; On the maintainer's setup Tab is AltGr's tap and Enter CapsLock's: both go out
; through the driver's send, so the watcher never meets them.
TestEndKey_TapResolvesItsEndChar() {
	global TapHold
	Saved := TapHold
	try {
		TapHold := Map("keys", Map(
			"alt_gr", Map("tap_action", "tab"), "caps_lock", Map("tap_action", "enter"),
			"left_alt", Map("tap_action", "backspace"), "enter", Map()))
		AssertEqual("`t", HotstringEndCharOfTap("alt_gr"), "AltGr's Tab tap is an end key")
		AssertEqual("`n", HotstringEndCharOfTap("caps_lock"), "CapsLock's Enter tap is an end key")
		AssertEqual("", HotstringEndCharOfTap("left_alt"), "a Backspace tap is not")
		AssertEqual("`n", HotstringEndCharOfTap("enter"), "the native tap of the Enter key is")
	} finally {
		TapHold := Saved
	}
}
Test("end key: a tap that types Enter or Tab is an end key (hotstring-end-keys)",
	TestEndKey_TapResolvesItsEndChar)
