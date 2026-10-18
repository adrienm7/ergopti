; static/ergopti_plus/windows/tests/unit/modules/hotstrings/engine/test_hotstring_engine_main.ahk

; ==============================================================================
; MODULE: Hotstring Engine Main Tests
; DESCRIPTION:
; Pure-helper tests for the new hotstring engine. Covers buffer semantics
; (FeedChar / FeedBackspace / FeedReset / ApplyExpansion), the registry's
; last-char bucketing, and HSE_FindMatchAtEnd's word-boundary + end-char +
; case-sensitivity gates.
;
; All tests reset module globals through HSE_RegistryClear / HSE_FeedReset
; in their own setup so they can run in any order without leakage.
; ==============================================================================





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

HSE_TestReset() {
    global HSE_Suppressed, _PrefixWatcherSuppressed, _PrefixLastKeyTick
    HSE_RegistryClear()
    HSE_Suppressed := 0
    ; Cancel any pending deferred PrefixWatcherSuppress(false) or HSE_Suppress(false)
    ; timers left over from a prior test dispatch so they cannot fire mid-test and
    ; corrupt the suppression depth counter. SetTimer with period 0 deletes the
    ; registration; the closures are one-shot lambdas, so we cancel by function
    ; object — but since each SetTimer call creates a NEW lambda, we cannot cancel
    ; individually. Resetting the counters to 0 achieves the same invariant: any
    ; stale release timer that fires will call Max(0, 0-1) = 0 (a no-op floor).
    if IsSet(_PrefixWatcherSuppressed)
        _PrefixWatcherSuppressed := 0
    ; HSE_Suppress(false) no longer wipes the buffer (HSE_DispatchMatch
    ; relies on the post-expansion state surviving the burst). Hard-reset
    ; here so each test starts from a known-empty buffer; HSE_FeedReset(true)
    ; then restores the canonical « fresh launch » boundary flag.
    HSE_HardReset()
    HSE_FeedReset(true)
    ; A keystroke stamp left by an earlier test would read as a pause and
    ; start a new word in the middle of this one (hotstrings.idle_reset_seconds).
    _PrefixLastKeyTick := ""
}





; ==================================
; ==================================
; ======= 2/ Buffer mutation =======
; ==================================
; ==================================

TestHSE_FeedCharAppends() {
    HSE_TestReset()
    HSE_FeedChar("c")
    HSE_FeedChar("a")
    HSE_FeedChar("t")
    AssertEqual("cat", HSE_Buffer)
}
Test("HSE FeedChar appends to buffer", TestHSE_FeedCharAppends)

TestHSE_FeedSpaceKeptInBuffer() {
    HSE_TestReset()
    HSE_FeedChar("h")
    HSE_FeedChar("i")
    HSE_FeedChar(" ")
    AssertEqual("hi ", HSE_Buffer,
        "terminators stay in the buffer so triggers spanning them (e.g. ',a' personal hotstrings) can still match")
    AssertTrue(HSE_StartIsWordBoundary,
        "boundary flag stays true — it describes the LEFT of the buffer, which has not changed")
}
Test("HSE word terminator stays in the buffer (no reset on space)",
    TestHSE_FeedSpaceKeptInBuffer)

TestHSE_FeedPunctuationKeptInBuffer() {
    HSE_TestReset()
    HSE_FeedChar("h")
    HSE_FeedChar("i")
    HSE_FeedChar(".")
    AssertEqual("hi.", HSE_Buffer, "punctuation stays in the buffer like any other char")
    AssertTrue(HSE_StartIsWordBoundary)
}
Test("HSE punctuation stays in the buffer (no reset on period)",
    TestHSE_FeedPunctuationKeptInBuffer)

TestHSE_BackspaceChopsLastChar() {
    HSE_TestReset()
    HSE_FeedChar("a")
    HSE_FeedChar("b")
    HSE_FeedChar("c")
    HSE_FeedBackspace()
    AssertEqual("ab", HSE_Buffer)
    HSE_FeedBackspace()
    AssertEqual("a", HSE_Buffer)
}
Test("HSE backspace chops one char off the buffer",
    TestHSE_BackspaceChopsLastChar)

TestHSE_BackspaceOnEmptyBufferFlipsBoundary() {
    HSE_TestReset()
    AssertTrue(HSE_StartIsWordBoundary, "init flag is true")
    HSE_FeedBackspace()
    AssertEqual("", HSE_Buffer)
    AssertFalse(HSE_StartIsWordBoundary,
        "backspace on empty buffer flips boundary to false")
}
Test("HSE backspace on empty buffer marks unknown context",
    TestHSE_BackspaceOnEmptyBufferFlipsBoundary)

/** Replays the driver's actual burst into an owned hidden native Edit control. */
TestHSE_UnicodeNativeErase(Paste := false, EndChar := "", Admission := false) {
	if Paste
		return _HUE_NativeNotepad()

	global CategoryEnabled, Features, _PrefixBuffer, _PrefixFocusedControlToken
	global _HSResolveCache, _HSResolveGen
	SavedCallback := { Categories: CategoryEnabled, Features: Features,
		Prefix: _PrefixBuffer, Focus: _PrefixFocusedControlToken, Resolver: _HSResolveCache }
	global HSE_Buffer, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, _Stub_RecordedSends
	SavedTerminators := HSE_WORD_TERMINATORS
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Emoji := Chr(0x1F600)
	Trigger := Emoji . "x"
	Window := Gui()
	EditControl := Window.AddEdit(, "A" . Trigger . EndChar)
	Window.Show("Hide")
	SendMessage(0x00B1, StrLen(EditControl.Value), StrLen(EditControl.Value), EditControl)
	try {
		if EndChar != "" {
			HSE_WORD_TERMINATORS .= EndChar
			HSE_CONSUMED_DELIMITERS .= EndChar
		}
		CreateHotstring(EndChar == "" ? "*?C" : "?C", Trigger, "R",
			Map("Category", "_unicode_probe", "Section", "native"))
		if Admission {
			CategoryEnabled := Map("Hotstrings", true)
			Features := Map()
			_PrefixBuffer := ""
			_PrefixFocusedControlToken := 1
			_HSResolveCache := Map("_unicode_probe|native", {
				gen: _HSResolveGen, val: { ShowTooltip: false } })
			for Char in ["A", Emoji, "x", EndChar] {
				if Char == ""
					continue
				_OnPrefixChar(0, Char, (*) => 0, (*) => true)
				_PrefixCancelRender()
			}
			AssertEqual(1, _Stub_RecordedSends.Length, "the real callback must dispatch exactly once")
		} else {
			HSE_FeedChar("A")
			HSE_FeedChar(Emoji)
			Match := HSE_FeedChar("x")
			if EndChar != ""
				Match := HSE_FeedChar(EndChar)
			AssertTrue(IsObject(Match), "the non-BMP trigger must match")
			AssertTrue(HSE_DispatchMatch(Match, EndChar), "the actual dispatcher must send")
		}
		ControlSend(_ConformDF_LastBurst(), EditControl)
		Sleep(30)
		AssertEqual("AR", EditControl.Value, "native Backspace must preserve the preceding character")
		AssertEqual(EditControl.Value, HSE_Buffer, "UTF-16 buffer edits must match native output")
	} finally {
		Window.Destroy()
		if Admission
			_PrefixInvalidateDeferredEffects()
		CategoryEnabled := SavedCallback.Categories
		Features := SavedCallback.Features
		_PrefixBuffer := SavedCallback.Prefix
		_PrefixFocusedControlToken := SavedCallback.Focus
		_HSResolveCache := SavedCallback.Resolver
		HSE_WORD_TERMINATORS := SavedTerminators
		HSE_CONSUMED_DELIMITERS := SavedConsumed
		HSE_TestReset()
	}
}
Test("HSE Unicode erase preserves the native preceding character (unicode-erase)",
	TestHSE_UnicodeNativeErase)
Test("HSE Unicode paste erase preserves native context (unicode-erase)",
	TestHSE_UnicodeNativeErase.Bind(true))
Test("HSE Unicode completion consumes its complete UTF-16 span (unicode-erase)",
	TestHSE_UnicodeNativeErase.Bind(false, Chr(0x1F600)))
Test("HSE real input callback preserves supplementary trigger context (unicode-erase)",
	TestHSE_UnicodeNativeErase.Bind(false, "", true))
Test("HSE real input callback consumes a whole supplementary completion (unicode-erase)",
	TestHSE_UnicodeNativeErase.Bind(false, Chr(0x1F600), true))

/** One physical Backspace erases a surrogate pair from both observed buffers. */
TestHSE_UnicodePhysicalBackspace() {
	global HSE_Buffer, _PrefixBuffer
	HSE_TestReset()
	try {
		HSE_Buffer := "A" . Chr(0x1F600)
		_PrefixBuffer := HSE_Buffer
		_PrefixCommitBackspace()
		AssertEqual("A", HSE_Buffer, "the canonical buffer must not retain a lone surrogate")
		AssertEqual("A", _PrefixBuffer, "the preview must erase the same scalar")
	} finally {
		_PrefixBuffer := ""
		HSE_TestReset()
	}
}
Test("HSE physical Backspace erases one Unicode scalar (unicode-erase)",
	TestHSE_UnicodePhysicalBackspace)

_UnicodeRawApply(EditControl, EndChar) {
	ControlSend("{BackSpace 2}{Text}R", EditControl)
	return {Ok: true, Bs: 2, Ins: "R"}
}

/** The raw callback's native key count must publish a UTF-16 buffer effect. */
TestHSE_UnicodeRawErase() {
	global HSE_Buffer
	HSE_TestReset()
	HSE_Buffer := "A" . Chr(0x1F600) . "x"
	Window := Gui()
	EditControl := Window.AddEdit(, HSE_Buffer)
	Window.Show("Hide")
	SendMessage(0x00B1, StrLen(EditControl.Value), StrLen(EditControl.Value), EditControl)
	try {
		Spec := {Callback: _UnicodeRawApply.Bind(EditControl)}
		Effect := 0
		AssertTrue(_HSE_DispatchRawCallback(Spec, "", &Effect))
		Sleep(30)
		AssertEqual("AR", EditControl.Value)
		AssertEqual(EditControl.Value, HSE_Buffer)
		AssertEqual(3, Effect.DeleteFromEnd, "two keys erase three UTF-16 units")
	} finally {
		Window.Destroy()
		HSE_TestReset()
	}
}
Test("HSE raw Unicode erase publishes its complete UTF-16 span (unicode-erase)",
	TestHSE_UnicodeRawErase)

TestHSE_FeedResetClearsBufferAndFlag() {
    HSE_TestReset()
    HSE_FeedChar("x")
    HSE_FeedReset(false)
    AssertEqual("", HSE_Buffer)
    AssertFalse(HSE_StartIsWordBoundary)
    HSE_FeedReset(true)
    AssertTrue(HSE_StartIsWordBoundary, "FeedReset(true) sets boundary true")
}
Test("HSE FeedReset clears buffer and respects KnownTerminatorBefore",
    TestHSE_FeedResetClearsBufferAndFlag)

TestHSE_BufferTrimmedAtMaxLength() {
    HSE_TestReset()
    Loop HSE_MAX_BUFFER_LEN + 5 {
        HSE_FeedChar("a")
    }
    AssertEqual(HSE_MAX_BUFFER_LEN, StrLen(HSE_Buffer))
    AssertFalse(HSE_StartIsWordBoundary,
        "the discarded word character does not establish a boundary")
}
Test("HSE buffer is trimmed at HSE_MAX_BUFFER_LEN", TestHSE_BufferTrimmedAtMaxLength)

TestHSE_IdentityReplacementUsesTypedCase() {
    global HSE_Buffer
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    try {
        CreateHotstring("*?", "abc", "abc")
        HSE_FeedChar("A")
        HSE_FeedChar("B")
        Match := HSE_FeedChar("C")
        AssertTrue(IsObject(Match), "different typed case is a real literal replacement")
        AssertTrue(HSE_DispatchMatch(Match, ""), "case normalization must dispatch")
        AssertEqual("abc", HSE_Buffer, "the buffer must reflect normalized lowercase text")
        AssertEqual("{BackSpace 3}{Text}abc", _ConformDF_LastBurst(),
            "the emitted edit must replace exactly the three uppercase characters")
    } finally {
        HSE_TestReset()
    }
}
Test("HSE no-op: literal identity still normalizes typed case (hse-actual-noop)",
    TestHSE_IdentityReplacementUsesTypedCase)

TestHSE_IdentityReplacementConsumesDelimiter() {
    global HSE_CONSUMED_DELIMITERS, HSE_Buffer, HSE_LastEndChar
    SavedConsumed := HSE_CONSUMED_DELIMITERS
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    try {
        HSE_CONSUMED_DELIMITERS := " "
        CreateHotstring("?", "abc", "abc")
        for Char in StrSplit("abc")
            HSE_FeedChar(Char)
        Match := HSE_FeedChar(" ")
        AssertTrue(IsObject(Match), "consuming a delimiter changes the output even with identical text")
        AssertTrue(HSE_DispatchMatch(Match, HSE_LastEndChar), "delimiter consumption must dispatch")
        AssertEqual("abc", HSE_Buffer, "the completing space must be consumed")
        AssertEqual("{BackSpace 4}{Text}abc", _ConformDF_LastBurst(),
            "the emitted edit must delete the delimiter without replaying it")
    } finally {
        HSE_CONSUMED_DELIMITERS := SavedConsumed
        HSE_TestReset()
    }
}
Test("HSE no-op: literal identity still consumes its delimiter (hse-actual-noop)",
    TestHSE_IdentityReplacementConsumesDelimiter)

TestHSE_IdentityWinnerStillMasksLowerPriority() {
    HSE_TestReset()
    try {
        HSE_Register("*?", "abc", (*) => 0, {Priority: 10, Replacement: "changed", OnlyText: true})
        HSE_Register("*?", "abc", (*) => 0, {Priority: 50, Replacement: "abc", OnlyText: true})
        for Char in StrSplit("ab")
            HSE_FeedChar(Char)
        AssertFalse(IsObject(HSE_FeedChar("c")), "a true no-op winner must still mask lower priority")
        HSE_FeedReset(true)
        for Char in StrSplit("AB")
            HSE_FeedChar(Char)
        Match := HSE_FeedChar("C")
        AssertTrue(IsObject(Match), "the same winner must normalize differently cased input")
        AssertEqual("abc", Match.Replacement, "lower priority must never take over")
    } finally {
        HSE_TestReset()
    }
}
Test("HSE no-op: winner priority survives effect classification (hse-actual-noop)",
    TestHSE_IdentityWinnerStillMasksLowerPriority)

TestHSE_NoOpRespectsDispatchSemantics() {
    HSE_TestReset()
    try {
        Conform := {Trigger: "abc", Length: 3, Replacement: "abc", OnlyText: true,
            CaseConform: true}
        AssertTrue(_HSE_IsLiteralNoOp(Conform, "ABC", "", false),
            "case-conformed identical output is a true no-op")
        AssertFalse(_HSE_IsLiteralNoOp(Conform, "AbC", "", false),
            "mixed case must retain the dispatcher's refusal semantics")
        Action := {Trigger: "{Tab}", Length: 5, Replacement: "{Tab}", OnlyText: false}
        AssertFalse(_HSE_IsLiteralNoOp(Action, "{Tab}", "", false),
            "interpreted Send syntax is not literal identity")
        Raw := {Trigger: "abc", Length: 3, Replacement: "abc", RawCallback: true}
        AssertFalse(_HSE_IsLiteralNoOp(Raw, "abc", "", false),
            "a raw callback must retain ownership of its effects")
        Calls := [0]
        Dynamic := {Trigger: "abc", Length: 3, Replacement: (*) => (Calls[1] += 1, "abc")}
        AssertFalse(_HSE_IsLiteralNoOp(Dynamic, "abc", "", false),
            "dynamic replacements cannot be classified without resolving them")
        AssertEqual(0, Calls[1], "matching must not execute a dynamic replacement")
        AssertFalse(_HSE_IsLiteralNoOp(Conform, "abc" . Chr(0xA0) . ":", ":", true),
            "removing typography framing is an observable effect")
    } finally {
        HSE_TestReset()
    }
}
Test("HSE no-op: text, conformity and callbacks keep their effects (hse-actual-noop)",
    TestHSE_NoOpRespectsDispatchSemantics)

TestHSE_SuppressShortCircuitsFeeds() {
    HSE_TestReset()
    HSE_FeedChar("x")  ; pre-burst buffer
    HSE_Suppress(true)
    HSE_FeedChar("a")
    HSE_FeedBackspace()
    HSE_FeedReset(true)
    AssertEqual("x", HSE_Buffer, "suppressed feeds do not mutate the buffer")
    HSE_Suppress(false)
    AssertEqual("x", HSE_Buffer,
        "release preserves the buffer — HSE_DispatchMatch sets the post-expansion state itself")
}
Test("HSE suppression short-circuits all feeds without wiping on release",
    TestHSE_SuppressShortCircuitsFeeds)

TestHSE_HardResetClearsBufferAndBoundary() {
    HSE_TestReset()
    HSE_FeedChar("x")
    HSE_HardReset()
    AssertEqual("", HSE_Buffer, "HardReset wipes the buffer")
    AssertFalse(HSE_StartIsWordBoundary,
        "HardReset flips the boundary flag to false (unknown left-hand context)")
}
Test("HSE HardReset clears the buffer and the boundary flag",
    TestHSE_HardResetClearsBufferAndBoundary)





; ===========================
; ===========================
; ======= 3/ Registry =======
; ===========================
; ===========================

TestHSE_RegisterBucketsByLastChar() {
    HSE_TestReset()
    HSE_Register("*", "abc", () => 0)
    HSE_Register("*", "xyz", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("c"))
    AssertTrue(HSE_RegistryByLastChar.Has("z"))
    AssertEqual(1, HSE_RegistryByLastChar["c"].Length)
    AssertEqual(1, HSE_RegistryByLastChar["z"].Length)
}
Test("HSE registry buckets by trigger last char",
    TestHSE_RegisterBucketsByLastChar)

TestHSE_RegisterCaseInsensitiveLowercasesBucket() {
    HSE_TestReset()
    HSE_Register("*", "abZ", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("z"),
        "case-insensitive triggers bucket under lowercase last char")
    AssertFalse(HSE_RegistryByLastChar.Has("Z"))
}
Test("HSE case-insensitive registration uses lowercase bucket",
    TestHSE_RegisterCaseInsensitiveLowercasesBucket)

TestHSE_RegisterCaseSensitiveKeepsLiteralBucket() {
    HSE_TestReset()
    HSE_Register("*C", "abZ", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("Z"),
        "case-sensitive triggers keep literal last char as bucket key")
}
Test("HSE case-sensitive registration uses literal-case bucket",
    TestHSE_RegisterCaseSensitiveKeepsLiteralBucket)

TestHSE_RegistryClearEmptiesIndex() {
    HSE_TestReset()
    HSE_Register("*", "abc", () => 0)
    HSE_RegistryClear()
    AssertEqual(0, HSE_RegistryByLastChar.Count)
}
Test("HSE RegistryClear empties the bucket map",
    TestHSE_RegistryClearEmptiesIndex)

TestHSE_RegisterIgnoresEmptyTrigger() {
    HSE_TestReset()
    HSE_Register("*", "", () => 0)
    AssertEqual(0, HSE_RegistryByLastChar.Count)
}
Test("HSE Register ignores an empty trigger",
    TestHSE_RegisterIgnoresEmptyTrigger)



; ==================================================
; ===== 3.1) Boot-perf registration invariants =====
; ==================================================

; These pin two startup hot-path optimisations (magic-key text expansion is the
; single heaviest boot category — ~3100 star registrations). The behaviour they
; lock must stay byte-identical to the pre-optimisation code, so a future refactor
; that "simplifies" either path cannot silently change the index it builds.

; _HSE_IndexStarPrefixes builds each successive prefix incrementally instead of
; re-slicing from position 1. The resulting prefix -> next-char set must be exactly
; {"a": {"b"}, "ab": {"c"}} for the 3-char trigger "abc".
TestHSE_StarPrefixIndexContent() {
    HSE_TestReset()
    HSE_Register("*", "abc", () => 0)
    AssertEqual(2, HSE_StarPrefixSetCI.Count,
        "a 3-char star trigger contributes exactly two prefixes")
    AssertTrue(HSE_StarPrefixSetCI.Has("a") and HSE_StarPrefixSetCI["a"].Has("b"),
        "prefix 'a' maps to next-char 'b'")
    AssertTrue(HSE_StarPrefixSetCI.Has("ab") and HSE_StarPrefixSetCI["ab"].Has("c"),
        "prefix 'ab' maps to next-char 'c'")
}
Test("HSE star-prefix index builds the exact prefix -> next-char set",
    TestHSE_StarPrefixIndexContent)

; The case-insensitive path now lowercases the whole trigger ONCE before slicing.
; A mixed-case trigger "AbC" must still yield the SAME lowercase keys as "abc" —
; no uppercase prefix or next-char may leak into the CI set.
TestHSE_StarPrefixIndexLowercasesCI() {
    HSE_TestReset()
    HSE_Register("*", "AbC", () => 0)
    AssertTrue(HSE_StarPrefixSetCI.Has("a") and HSE_StarPrefixSetCI["a"].Has("b"),
        "CI prefix 'A' is lowercased to 'a', next-char 'b'")
    AssertTrue(HSE_StarPrefixSetCI.Has("ab") and HSE_StarPrefixSetCI["ab"].Has("c"),
        "CI next-char 'C' is lowercased to 'c'")
    AssertFalse(HSE_StarPrefixSetCI.Has("A"),
        "no uppercase prefix key leaks into the case-insensitive set")
}
Test("HSE star-prefix index lowercases the case-insensitive keys once",
    TestHSE_StarPrefixIndexLowercasesCI)

; Case-sensitive star triggers keep literal case in the CS prefix set.
TestHSE_StarPrefixIndexCSKeepsCase() {
    HSE_TestReset()
    HSE_Register("*C", "AbC", () => 0)
    AssertTrue(HSE_StarPrefixSetCS.Has("A") and HSE_StarPrefixSetCS["A"].Has("b"),
        "case-sensitive prefixes keep literal case 'A'")
    AssertTrue(HSE_StarPrefixSetCS.Has("Ab") and HSE_StarPrefixSetCS["Ab"].Has("C"),
        "case-sensitive next-char keeps literal case 'C'")
    AssertEqual(0, HSE_StarPrefixSetCI.Count,
        "a case-sensitive trigger contributes nothing to the CI set")
}
Test("HSE star-prefix index keeps literal case for case-sensitive triggers",
    TestHSE_StarPrefixIndexCSKeepsCase)

; _MirrorRegistrationToHSE parses the ":<flags>:<abbrev>" spec with InStr instead
; of a regex. It must split on the SECOND colon so an abbreviation that itself
; contains a colon (the ":=" assign roll) keeps every colon after the separator.
TestHSE_MirrorParseAbbrevWithColon() {
    HSE_TestReset()
    _MirrorRegistrationToHSE(":*?B0O:a:b", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("b"),
        "abbrev 'a:b' buckets under its real last char 'b'")
    Spec := HSE_RegistryByLastChar["b"][1]
    AssertEqual("a:b", Spec.Trigger,
        "a colon inside the abbreviation survives the split on the second colon")
    AssertTrue(Spec.Star, "the '*' flag is parsed from the flags portion")
    AssertTrue(Spec.InWord, "the '?' flag is parsed from the flags portion")
    AssertFalse(Spec.CaseSensitive, "no 'C' in the flags portion -> case-insensitive")
}
Test("HSE mirror-parse splits on the second colon (abbrev may contain colons)",
    TestHSE_MirrorParseAbbrevWithColon)

; A malformed spec with no second colon registers nothing (matched the old regex,
; which required both colons and a non-empty abbreviation).
TestHSE_MirrorParseRejectsMalformed() {
    HSE_TestReset()
    _MirrorRegistrationToHSE(":justflags", () => 0)
    _MirrorRegistrationToHSE(":flags:", () => 0)
    _MirrorRegistrationToHSE("noLeadingColon", () => 0)
    AssertEqual(0, HSE_RegistryByLastChar.Count,
        "specs missing the second colon, an abbrev, or the leading colon register nothing")
}
Test("HSE mirror-parse rejects malformed specs (no second colon / empty abbrev)",
    TestHSE_MirrorParseRejectsMalformed)
