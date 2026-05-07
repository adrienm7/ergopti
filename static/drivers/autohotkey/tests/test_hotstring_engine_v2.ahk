; static/drivers/autohotkey/tests/test_hotstring_engine_v2.ahk

; ==============================================================================
; MODULE: Hotstring Engine V2 Tests
; DESCRIPTION:
; Pure-helper tests for the new hotstring engine. Covers buffer semantics
; (FeedChar / FeedBackspace / FeedReset / ApplyExpansion), the registry's
; last-char bucketing, and HSE_FindMatchAtEnd's word-boundary + end-char +
; case-sensitivity gates.
;
; All tests reset module globals through HSE_RegistryClear / HSE_FeedReset
; in their own setup so they can run in any order without leakage.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Helpers =======
; ============================================
; ============================================

HSEv2_TestReset() {
    HSE_RegistryClear()
    HSE_Suppress(false)
    ; HSE_Suppress(false) no longer wipes the buffer (HSE_DispatchMatch
    ; relies on the post-expansion state surviving the burst). Hard-reset
    ; here so each test starts from a known-empty buffer; HSE_FeedReset(true)
    ; then restores the canonical « fresh launch » boundary flag.
    HSE_HardReset()
    HSE_FeedReset(true)
}




; ============================================
; ============================================
; ======= 2/ Buffer mutation =======
; ============================================
; ============================================

TestHSEv2_FeedCharAppends() {
    HSEv2_TestReset()
    HSE_FeedChar("c")
    HSE_FeedChar("a")
    HSE_FeedChar("t")
    AssertEqual("cat", HSE_Buffer)
}
Test("HSEv2 FeedChar appends to buffer", TestHSEv2_FeedCharAppends)

TestHSEv2_FeedSpaceKeptInBuffer() {
    HSEv2_TestReset()
    HSE_FeedChar("h")
    HSE_FeedChar("i")
    HSE_FeedChar(" ")
    AssertEqual("hi ", HSE_Buffer,
        "terminators stay in the buffer so triggers spanning them (e.g. ',a' personal hotstrings) can still match")
    AssertTrue(HSE_StartIsWordBoundary,
        "boundary flag stays true — it describes the LEFT of the buffer, which has not changed")
}
Test("HSEv2 word terminator stays in the buffer (no reset on space)",
    TestHSEv2_FeedSpaceKeptInBuffer)

TestHSEv2_FeedPunctuationKeptInBuffer() {
    HSEv2_TestReset()
    HSE_FeedChar("h")
    HSE_FeedChar("i")
    HSE_FeedChar(".")
    AssertEqual("hi.", HSE_Buffer, "punctuation stays in the buffer like any other char")
    AssertTrue(HSE_StartIsWordBoundary)
}
Test("HSEv2 punctuation stays in the buffer (no reset on period)",
    TestHSEv2_FeedPunctuationKeptInBuffer)

TestHSEv2_BackspaceChopsLastChar() {
    HSEv2_TestReset()
    HSE_FeedChar("a")
    HSE_FeedChar("b")
    HSE_FeedChar("c")
    HSE_FeedBackspace()
    AssertEqual("ab", HSE_Buffer)
    HSE_FeedBackspace()
    AssertEqual("a", HSE_Buffer)
}
Test("HSEv2 backspace chops one char off the buffer",
    TestHSEv2_BackspaceChopsLastChar)

TestHSEv2_BackspaceOnEmptyBufferFlipsBoundary() {
    HSEv2_TestReset()
    AssertTrue(HSE_StartIsWordBoundary, "init flag is true")
    HSE_FeedBackspace()
    AssertEqual("", HSE_Buffer)
    AssertFalse(HSE_StartIsWordBoundary,
        "backspace on empty buffer flips boundary to false")
}
Test("HSEv2 backspace on empty buffer marks unknown context",
    TestHSEv2_BackspaceOnEmptyBufferFlipsBoundary)

TestHSEv2_FeedResetClearsBufferAndFlag() {
    HSEv2_TestReset()
    HSE_FeedChar("x")
    HSE_FeedReset(false)
    AssertEqual("", HSE_Buffer)
    AssertFalse(HSE_StartIsWordBoundary)
    HSE_FeedReset(true)
    AssertTrue(HSE_StartIsWordBoundary, "FeedReset(true) sets boundary true")
}
Test("HSEv2 FeedReset clears buffer and respects KnownTerminatorBefore",
    TestHSEv2_FeedResetClearsBufferAndFlag)

TestHSEv2_BufferTrimmedAtMaxLength() {
    HSEv2_TestReset()
    Loop HSE_MAX_BUFFER_LEN + 5 {
        HSE_FeedChar("a")
    }
    AssertEqual(HSE_MAX_BUFFER_LEN, StrLen(HSE_Buffer))
    AssertFalse(HSE_StartIsWordBoundary,
        "trimming flips boundary to false because old chars are now lost")
}
Test("HSEv2 buffer is trimmed at HSE_MAX_BUFFER_LEN", TestHSEv2_BufferTrimmedAtMaxLength)

TestHSEv2_SuppressShortCircuitsFeeds() {
    HSEv2_TestReset()
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
Test("HSEv2 suppression short-circuits all feeds without wiping on release",
    TestHSEv2_SuppressShortCircuitsFeeds)

TestHSEv2_HardResetClearsBufferAndBoundary() {
    HSEv2_TestReset()
    HSE_FeedChar("x")
    HSE_HardReset()
    AssertEqual("", HSE_Buffer, "HardReset wipes the buffer")
    AssertFalse(HSE_StartIsWordBoundary,
        "HardReset flips the boundary flag to false (unknown left-hand context)")
}
Test("HSEv2 HardReset clears the buffer and the boundary flag",
    TestHSEv2_HardResetClearsBufferAndBoundary)




; ============================================
; ============================================
; ======= 3/ Registry =======
; ============================================
; ============================================

TestHSEv2_RegisterBucketsByLastChar() {
    HSEv2_TestReset()
    HSE_Register("*", "abc", () => 0)
    HSE_Register("*", "xyz", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("c"))
    AssertTrue(HSE_RegistryByLastChar.Has("z"))
    AssertEqual(1, HSE_RegistryByLastChar["c"].Length)
    AssertEqual(1, HSE_RegistryByLastChar["z"].Length)
}
Test("HSEv2 registry buckets by trigger last char",
    TestHSEv2_RegisterBucketsByLastChar)

TestHSEv2_RegisterCaseInsensitiveLowercasesBucket() {
    HSEv2_TestReset()
    HSE_Register("*", "abZ", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("z"),
        "case-insensitive triggers bucket under lowercase last char")
    AssertFalse(HSE_RegistryByLastChar.Has("Z"))
}
Test("HSEv2 case-insensitive registration uses lowercase bucket",
    TestHSEv2_RegisterCaseInsensitiveLowercasesBucket)

TestHSEv2_RegisterCaseSensitiveKeepsLiteralBucket() {
    HSEv2_TestReset()
    HSE_Register("*C", "abZ", () => 0)
    AssertTrue(HSE_RegistryByLastChar.Has("Z"),
        "case-sensitive triggers keep literal last char as bucket key")
}
Test("HSEv2 case-sensitive registration uses literal-case bucket",
    TestHSEv2_RegisterCaseSensitiveKeepsLiteralBucket)

TestHSEv2_RegistryClearEmptiesIndex() {
    HSEv2_TestReset()
    HSE_Register("*", "abc", () => 0)
    HSE_RegistryClear()
    AssertEqual(0, HSE_RegistryByLastChar.Count)
}
Test("HSEv2 RegistryClear empties the bucket map",
    TestHSEv2_RegistryClearEmptiesIndex)

TestHSEv2_RegisterIgnoresEmptyTrigger() {
    HSEv2_TestReset()
    HSE_Register("*", "", () => 0)
    AssertEqual(0, HSE_RegistryByLastChar.Count)
}
Test("HSEv2 Register ignores an empty trigger",
    TestHSEv2_RegisterIgnoresEmptyTrigger)




; ============================================
; ============================================
; ======= 4/ Match logic =======
; ============================================
; ============================================

TestHSEv2_MatchStarTriggerOnLastChar() {
    HSEv2_TestReset()
    HSE_Register("*", "ct", () => 0)
    HSE_FeedChar("c")
    Match := HSE_FeedChar("t")
    AssertTrue(Match != "", "star trigger fires on its last char")
    AssertEqual("ct", Match.Trigger)
}
Test("HSEv2 star trigger fires on the last char of its body",
    TestHSEv2_MatchStarTriggerOnLastChar)

TestHSEv2_NonStarTriggerNeedsEndChar() {
    HSEv2_TestReset()
    HSE_Register("", "btw", () => 0)
    HSE_FeedChar("b")
    HSE_FeedChar("t")
    Match := HSE_FeedChar("w")
    AssertEqual("", Match,
        "non-star trigger does not fire on the last char alone")
    Match := HSE_FeedChar(" ")
    AssertTrue(Match != "",
        "non-star trigger fires when an end char follows the body")
    AssertEqual("btw", Match.Trigger)
}
Test("HSEv2 non-star trigger requires an end char to fire",
    TestHSEv2_NonStarTriggerNeedsEndChar)

TestHSEv2_WordBoundaryRespectedAtBufferStart() {
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    Match := HSE_FeedChar("u")
    AssertEqual("", Match, "single char does not yet match the trigger body")
    Match := HSE_FeedChar("i")
    AssertTrue(Match != "",
        "trigger fires at start of buffer when boundary flag is true")
    AssertEqual("ui", Match.Trigger)
}
Test("HSEv2 word-boundary check passes when buffer starts on a known boundary",
    TestHSEv2_WordBoundaryRespectedAtBufferStart)

TestHSEv2_WordBoundaryFailsAfterBackspaceFromEmpty() {
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedBackspace() ; flips boundary flag false
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "trigger does not fire after backspace from empty buffer (oui+BS+UI case)")
}
Test("HSEv2 word-boundary check fails after backspace through empty buffer",
    TestHSEv2_WordBoundaryFailsAfterBackspaceFromEmpty)

TestHSEv2_WordBoundaryFailsAfterArrowReset() {
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedReset(false) ; arrow / Home / mouse click semantics
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "navigation reset clears the boundary flag — trigger stays silent")
}
Test("HSEv2 word-boundary check fails after navigation reset",
    TestHSEv2_WordBoundaryFailsAfterArrowReset)

TestHSEv2_WordBoundaryHonouredMidBuffer() {
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedChar("a") ; non-terminator before "ui" → mid-word
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "trigger does not fire mid-word when InWord flag is false")
}
Test("HSEv2 word-boundary check fails mid-buffer when previous char is a letter",
    TestHSEv2_WordBoundaryHonouredMidBuffer)

TestHSEv2_InWordTriggerFiresAnywhere() {
    HSEv2_TestReset()
    HSE_Register("*?", "ui", () => 0)
    HSE_FeedChar("a")
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertTrue(Match != "",
        "InWord trigger ignores the boundary check and fires mid-word")
}
Test("HSEv2 InWord trigger ignores the word-boundary check",
    TestHSEv2_InWordTriggerFiresAnywhere)

TestHSEv2_CaseInsensitiveMatchesAnyCase() {
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedChar("U")
    Match := HSE_FeedChar("I")
    AssertTrue(Match != "",
        "case-insensitive trigger matches uppercased input")
}
Test("HSEv2 case-insensitive registration matches any case",
    TestHSEv2_CaseInsensitiveMatchesAnyCase)

TestHSEv2_CaseSensitiveRejectsWrongCase() {
    HSEv2_TestReset()
    HSE_Register("*C", "UI", () => 0)
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "case-sensitive trigger rejects lowercased input")
    HSE_FeedReset(true)
    HSE_FeedChar("U")
    Match := HSE_FeedChar("I")
    AssertTrue(Match != "",
        "case-sensitive trigger fires on the literal trigger casing")
}
Test("HSEv2 case-sensitive registration is strict on letter case",
    TestHSEv2_CaseSensitiveRejectsWrongCase)

TestHSEv2_LongestMatchWins() {
    HSEv2_TestReset()
    HSE_Register("*", "re", () => 0)
    HSE_Register("*", "fre", () => 0)
    HSE_FeedChar("f")
    HSE_FeedChar("r")
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "")
    AssertEqual("fre", Match.Trigger,
        "longest matching trigger wins when several share a suffix")
}
Test("HSEv2 longest match wins when multiple triggers share a suffix",
    TestHSEv2_LongestMatchWins)




; ============================================
; ============================================
; ======= 5/ Buffer update on expansion =======
; ============================================
; ============================================

TestHSEv2_ApplyExpansionRewritesBufferTail() {
    HSEv2_TestReset()
    HSE_Register("*", "config★", () => 0)
    for Char in StrSplit("config★") {
        HSE_FeedChar(Char)
    }
    AssertEqual("config★", HSE_Buffer)
    Spec := HSE_LastMatch
    HSE_ApplyExpansion(Spec, "configuration")
    AssertEqual("configuration", HSE_Buffer,
        "buffer reflects the on-screen content post-expansion")
    AssertTrue(HSE_StartIsWordBoundary,
        "boundary flag describes what is LEFT of the buffer; nothing was prepended"
        . " so it stays on the same value it had pre-expansion (true)")
}
Test("HSEv2 ApplyExpansion replaces the trigger suffix with the replacement",
    TestHSEv2_ApplyExpansionRewritesBufferTail)

TestHSEv2_ApplyExpansionWithEndCharKeepsTerminatorInBuffer() {
    HSEv2_TestReset()
    HSE_Register("", "btw", () => 0)
    HSE_FeedChar("b")
    HSE_FeedChar("t")
    HSE_FeedChar("w")
    Match := HSE_FeedChar(" ")
    AssertTrue(Match != "")
    AssertEqual(" ", HSE_LastEndChar,
        "non-star match on a terminator surfaces the terminator as end char")
    HSE_ApplyExpansion(Match, "by the way", " ")
    AssertEqual("by the way ", HSE_Buffer,
        "post-expansion buffer mirrors what is on screen: replacement + re-emitted end char")
}
Test("HSEv2 ApplyExpansion keeps the trailing terminator in the buffer post-expansion",
    TestHSEv2_ApplyExpansionWithEndCharKeepsTerminatorInBuffer)

TestHSEv2_ApplyExpansionAfterPrefixContext() {
    HSEv2_TestReset()
    HSE_Register("*", "ct★", () => 0)
    for Char in StrSplit("hello ct★") {
        HSE_FeedChar(Char)
    }
    Spec := HSE_LastMatch
    AssertTrue(Spec != "", "trigger fires after a space + body")
    HSE_ApplyExpansion(Spec, "what")
    AssertEqual("hello what", HSE_Buffer,
        "expansion rewrites only the trigger tail, leaving the leading 'hello ' prefix in the buffer")
}
Test("HSEv2 ApplyExpansion preserves the buffer prefix to the left of the trigger",
    TestHSEv2_ApplyExpansionAfterPrefixContext)

TestHSEv2_PersonalCommaPrefixTriggerFires() {
    HSEv2_TestReset()
    ; Personal hotstring: typing « ,a » should fire to emit « ja ».
    ; Star flag (immediate fire on the « a »); the comma stays in the
    ; buffer instead of resetting it, otherwise the trigger could never
    ; complete.
    HSE_Register("*", ",a", () => 0)
    HSE_FeedChar(",")
    AssertEqual("", HSE_LastMatch, "comma alone does not fire ,a")
    AssertEqual(",", HSE_Buffer, "comma stays in the buffer")
    HSE_FeedChar("a")
    AssertTrue(HSE_LastMatch != "", "« ,a » fires once the « a » is typed")
    AssertEqual(",a", HSE_LastMatch.Trigger)
    AssertEqual("", HSE_LastEndChar, "star match has no end char")
}
Test("HSEv2 personal ,a-style trigger fires when the comma stays in the buffer",
    TestHSEv2_PersonalCommaPrefixTriggerFires)




; ============================================
; ============================================
; ======= 6/ Scenario regression checks =======
; ============================================
; ============================================

TestHSEv2_ConfigStarFiresAfterCtrlAReset() {
    ; Ctrl+A is a context-replacing keystroke handled at a higher layer by
    ; calling HSE_FeedReset(true). The next typed run should fire even
    ; though the buffer was non-empty before the Ctrl+A.
    HSEv2_TestReset()
    HSE_Register("*", "config★", () => 0)
    for Char in StrSplit("lorem ipsum") {
        HSE_FeedChar(Char)
    }
    HSE_FeedReset(true) ; Ctrl+A
    for Char in StrSplit("config★") {
        HSE_FeedChar(Char)
    }
    AssertTrue(HSE_LastMatch != "",
        "config★ fires after Ctrl+A even though the prior buffer had no terminator")
    AssertEqual("config★", HSE_LastMatch.Trigger)
}
Test("HSEv2 regression: config★ fires after Ctrl+A reset",
    TestHSEv2_ConfigStarFiresAfterCtrlAReset)

TestHSEv2_OuiBackspaceUiDoesNotFire() {
    ; Reproduces the « oui + BS×3 + UI » case: triple backspace empties the
    ; buffer and flips the boundary flag false on the third invocation,
    ; signalling « we deleted into unknown context ». Retyping ui should
    ; therefore NOT fire the autocorrect trigger.
    HSEv2_TestReset()
    HSE_Register("*", "ui", () => 0)
    for Char in StrSplit("oui") {
        HSE_FeedChar(Char)
    }
    HSE_FeedBackspace()
    HSE_FeedBackspace()
    HSE_FeedBackspace()
    HSE_FeedBackspace() ; one extra: chops past the buffer start
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "ui does not fire after backspacing past the buffer start")
}
Test("HSEv2 regression: ui does not fire after oui+BS+UI",
    TestHSEv2_OuiBackspaceUiDoesNotFire)
