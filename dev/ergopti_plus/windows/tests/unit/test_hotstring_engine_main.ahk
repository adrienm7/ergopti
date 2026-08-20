; static/ergopti_plus/windows/tests/unit/test_hotstring_engine_main.ahk

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
    global HSE_Suppressed, _PrefixWatcherSuppressed
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
        "trimming flips boundary to false because old chars are now lost")
}
Test("HSE buffer is trimmed at HSE_MAX_BUFFER_LEN", TestHSE_BufferTrimmedAtMaxLength)

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





; ==============================
; ==============================
; ======= 4/ Match logic =======
; ==============================
; ==============================

TestHSE_MatchStarTriggerOnLastChar() {
    HSE_TestReset()
    HSE_Register("*", "ct", () => 0)
    HSE_FeedChar("c")
    Match := HSE_FeedChar("t")
    AssertTrue(Match != "", "star trigger fires on its last char")
    AssertEqual("ct", Match.Trigger)
}
Test("HSE star trigger fires on the last char of its body",
    TestHSE_MatchStarTriggerOnLastChar)

; Regression for the magic-key latency optimisation: HSE_FindMatchAtEnd resolves
; star triggers through the by-trigger index (O(buffer-suffix) lookups) instead of
; scanning the whole last-char bucket — the magic-key bucket alone held ~2100
; triggers and the linear scan cost ~21 ms on every magic-key press. These guard
; the index's two failure modes: not being populated, and drifting out of sync
; with the live registry when a group is toggled.
TestHSE_StarByTriggerIndexPopulated() {
    HSE_TestReset()
    HSE_Register("*", "abc", () => 0)
    AssertTrue(HSE_StarByTriggerCI.Has("abc"),
        "registering a CI star trigger must populate the by-trigger index — without it "
        . "HSE_FindMatchAtEnd would fall back to scanning the whole last-char bucket")
    AssertEqual(3, HSE_MaxStarTriggerLen,
        "HSE_MaxStarTriggerLen must track the longest star trigger so suffix probing is bounded")
}
Test("HSE star by-trigger index is populated on registration",
    TestHSE_StarByTriggerIndexPopulated)

TestHSE_StarTriggerIndexSurvivesGroupToggle() {
    HSE_TestReset()
    HSE_Register("*", "qz", () => 0, Map("group", "grp_idx_test"))

    ; Enabled: the by-trigger index resolves it.
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    Match := HSE_FeedChar("z")
    AssertTrue(Match != "" and Match.Trigger == "qz",
        "star trigger must match via the by-trigger index while its group is enabled")

    ; Disabled: HSE_DisableGroup rebuilds the index from the spliced star set,
    ; so the trigger must no longer resolve (the index-desync regression guard).
    HSE_DisableGroup("grp_idx_test")
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    Match := HSE_FeedChar("z")
    AssertEqual("", Match,
        "disabling the group must drop the trigger from the by-trigger index")

    ; Re-enabled: HSE_EnableGroup re-inserts into the index incrementally.
    HSE_EnableGroup("grp_idx_test")
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    Match := HSE_FeedChar("z")
    AssertTrue(Match != "" and Match.Trigger == "qz",
        "re-enabling the group must restore the trigger to the by-trigger index")
}
Test("HSE star by-trigger index stays in sync through group disable/enable",
    TestHSE_StarTriggerIndexSurvivesGroupToggle)

; Priority tie-break: equal-length collisions resolve by higher Priority instead
; of registration order, so a user can make a hotstring win regardless of where
; it loads. InWord ("*?") triggers are used so the word-boundary gate never
; interferes — these isolate the precedence logic itself.
TestHSE_PriorityBreaksEqualLengthTie() {
    HSE_TestReset()
    HSE_Register("*?", "zz", () => 0, Map("group", "low",  "Priority", 10))
    HSE_Register("*?", "zz", () => 0, Map("group", "high", "Priority", 90))
    HSE_FeedReset(true)
    HSE_FeedChar("z")
    Match := HSE_FeedChar("z")
    AssertTrue(Match != "", "a star trigger must fire")
    AssertEqual("high", Match.Group,
        "the higher-priority spec must win the equal-length collision, not the first-registered one")
}
Test("HSE higher priority wins an equal-length star collision",
    TestHSE_PriorityBreaksEqualLengthTie)

TestHSE_PriorityOrderIndependent() {
    HSE_TestReset()
    ; High-priority registered FIRST this time — outcome must be unchanged.
    HSE_Register("*?", "yy", () => 0, Map("group", "high", "Priority", 90))
    HSE_Register("*?", "yy", () => 0, Map("group", "low",  "Priority", 10))
    HSE_FeedReset(true)
    HSE_FeedChar("y")
    Match := HSE_FeedChar("y")
    AssertEqual("high", Match.Group,
        "priority precedence must not depend on registration order")
}
Test("HSE priority precedence is registration-order independent",
    TestHSE_PriorityOrderIndependent)

TestHSE_EqualPriorityFallsBackToSeq() {
    HSE_TestReset()
    ; No explicit priority (both default 50) → first-registered wins (Seq),
    ; preserving the historical behaviour when no priorities are set.
    HSE_Register("*?", "ww", () => 0, Map("group", "first"))
    HSE_Register("*?", "ww", () => 0, Map("group", "second"))
    HSE_FeedReset(true)
    HSE_FeedChar("w")
    Match := HSE_FeedChar("w")
    AssertEqual("first", Match.Group,
        "equal priority must fall back to first-registered (Seq), the pre-priority default")
}
Test("HSE equal priority falls back to first-registered (Seq)",
    TestHSE_EqualPriorityFallsBackToSeq)

TestHSE_LongerBeatsHigherPriority() {
    HSE_TestReset()
    ; Length stays primary: a longer trigger wins even with far lower priority.
    HSE_Register("*?", "x",  () => 0, Map("group", "short", "Priority", 99))
    HSE_Register("*?", "vx", () => 0, Map("group", "long",  "Priority", 1))
    HSE_FeedReset(true)
    HSE_FeedChar("v")
    Match := HSE_FeedChar("x")
    AssertEqual("long", Match.Group,
        "longest-match must stay primary — a longer trigger beats a shorter higher-priority one")
}
Test("HSE longest match still wins over a shorter higher-priority trigger",
    TestHSE_LongerBeatsHigherPriority)

; Source-default priorities and the CreateHotstring -> HSE pass-
; through. The ranking personal > package > common is the user-facing contract —
; personal hotstrings win an equal-length collision against a package, which wins
; against a bundled common trigger, with no manual tuning.
TestHSE_SourcePriorityDefaults() {
    global HSE_PRIORITY_COMMON, HSE_PRIORITY_PACKAGE, HSE_PRIORITY_PERSONAL
    AssertEqual(10, HSE_PRIORITY_COMMON,   "common source default must be 10")
    AssertEqual(30, HSE_PRIORITY_PACKAGE,  "package source default must be 30")
    AssertEqual(50, HSE_PRIORITY_PERSONAL, "personal source default must be 50")
    AssertTrue(HSE_PRIORITY_PERSONAL > HSE_PRIORITY_PACKAGE
        and HSE_PRIORITY_PACKAGE > HSE_PRIORITY_COMMON,
        "source ranking must be personal > package > common")
}
Test("HSE source priority defaults rank personal > package > common",
    TestHSE_SourcePriorityDefaults)

TestHSE_CreateHotstringForwardsPriority() {
    HSE_TestReset()
    CreateHotstring("*?", "qp", "out", Map("Priority", 77))
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    Match := HSE_FeedChar("p")
    AssertTrue(Match != "", "trigger must fire")
    AssertEqual(77, Match.Priority,
        "CreateHotstring must forward options['Priority'] into the HSE spec")
}
Test("HSE CreateHotstring forwards an explicit priority into the spec",
    TestHSE_CreateHotstringForwardsPriority)

; Regression (2026-06-12): the hand loader (modules/hotstrings.ahk) calls the
; factories with NO options at all — e.g. CreateCaseSensitiveHotstrings("*", abbr, repl).
; The priority resolve must guard IsSet(options) at the CALL SITE; an earlier
; version passed the unset ``options`` variable straight into the resolve helper, which
; threw UnsetError ("This parameter has not been assigned a value", options) at boot and
; crashed RegisterAllHotstrings. Reaching the assertions proves neither factory threw.
TestHSE_FactoriesNoOptionsNoCrash() {
    global HSE_PRIORITY_COMMON
    HSE_TestReset()
    CreateHotstring("*?", "qza", "out1")                 ; no options — must not throw
    CreateCaseSensitiveHotstrings("*?", "qzb", "out2")   ; no options — the crash site
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    HSE_FeedChar("z")
    M := HSE_FeedChar("a")
    AssertTrue(M != "", "a no-options CreateHotstring trigger must still register and fire")
    AssertEqual(HSE_PRIORITY_COMMON, M.Priority,
        "a no-options (no category) registration lands at the common source default")
}
Test("HSE factories register with no options (no UnsetError) and default to common priority",
    TestHSE_FactoriesNoOptionsNoCrash)

; Generated loaders pass Category/Section but NO Priority. The factory must
; fold in the section/file/source override cascade via HotstringsResolve so a user's
; per-section priority override reaches the ~3000 bundled hotstrings (previously they
; always landed at the common tier 10, ignoring the override).
TestHSE_NoExplicitPriorityResolvesOverrideCascade() {
	global _HotstringsOverrides, _HotstringsOverridesPath, HSE_PRIORITY_COMMON
	SavedOverrides := _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	Path := A_Temp . "\hotstrings_engine_priority_overrides.toml"
	try FileDelete(Path)
	_HotstringsOverrides := Map()
	_HotstringsOverridesPath := Path
	HotstringsResolveBumpGen()
	try {
		; No override → the common source default (synthetic non-personal/ext category).
		HSE_TestReset()
		CreateHotstring("*?", "qzc", "o", Map("Category", "phase3cat", "Section", "names"))
		HSE_FeedReset(true)
		HSE_FeedChar("q")
		HSE_FeedChar("z")
		M := HSE_FeedChar("c")
		AssertTrue(M != "", "trigger must fire")
		AssertEqual(HSE_PRIORITY_COMMON, M.Priority,
			"no override → a no-explicit-priority registration lands at the common source default")

		; A section-level override must reach the no-explicit-priority (generated-style) path.
		HotstringsSetOverride("phase3cat", "names", "priority", 42)
		HSE_TestReset()
		CreateHotstring("*?", "qzd", "o", Map("Category", "phase3cat", "Section", "names"))
		HSE_FeedReset(true)
		HSE_FeedChar("q")
		HSE_FeedChar("z")
		M2 := HSE_FeedChar("d")
		AssertTrue(M2 != "", "trigger must fire")
		AssertEqual(42, M2.Priority,
			"a per-section priority override reaches a no-explicit-priority (generated-style) registration")
	} finally {
		_HotstringsOverrides := SavedOverrides
		_HotstringsOverridesPath := SavedPath
		HotstringsResolveBumpGen()
		try FileDelete(Path)
	}
}
Test("HSE no-explicit-priority registration honours the section override cascade",
    TestHSE_NoExplicitPriorityResolvesOverrideCascade)

TestHSE_NonStarTriggerNeedsEndChar() {
    HSE_TestReset()
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
Test("HSE non-star trigger requires an end char to fire",
    TestHSE_NonStarTriggerNeedsEndChar)

TestHSE_WordBoundaryRespectedAtBufferStart() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    Match := HSE_FeedChar("u")
    AssertEqual("", Match, "single char does not yet match the trigger body")
    Match := HSE_FeedChar("i")
    AssertTrue(Match != "",
        "trigger fires at start of buffer when boundary flag is true")
    AssertEqual("ui", Match.Trigger)
}
Test("HSE word-boundary check passes when buffer starts on a known boundary",
    TestHSE_WordBoundaryRespectedAtBufferStart)

TestHSE_WordBoundaryFailsAfterBackspaceFromEmpty() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedBackspace() ; flips boundary flag false
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "trigger does not fire after backspace from empty buffer (oui+BS+UI case)")
}
Test("HSE word-boundary check fails after backspace through empty buffer",
    TestHSE_WordBoundaryFailsAfterBackspaceFromEmpty)

TestHSE_WordBoundaryPassesAfterArrowReset() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedReset(true) ; arrow / mouse click — next run starts fresh
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertTrue(Match != "",
        "navigation reset sets word boundary — trigger fires immediately after")
    AssertEqual("ui", Match.Trigger,
        "navigation reset sets word boundary — trigger fires immediately after")
}
Test("HSE word-boundary passes after navigation reset",
    TestHSE_WordBoundaryPassesAfterArrowReset)

TestHSE_WordBoundaryFailsAfterCtrlX() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedReset(false) ; Ctrl+X / Ctrl+V / Ctrl+Z — unknown buffer content
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "cut/paste/undo reset clears the boundary flag — trigger stays silent")
}
Test("HSE word-boundary check fails after cut/paste/undo reset",
    TestHSE_WordBoundaryFailsAfterCtrlX)

TestHSE_WordBoundaryHonouredMidBuffer() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedChar("a") ; non-terminator before "ui" → mid-word
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertEqual("", Match,
        "trigger does not fire mid-word when InWord flag is false")
}
Test("HSE word-boundary check fails mid-buffer when previous char is a letter",
    TestHSE_WordBoundaryHonouredMidBuffer)

TestHSE_InWordTriggerFiresAnywhere() {
    HSE_TestReset()
    HSE_Register("*?", "ui", () => 0)
    HSE_FeedChar("a")
    HSE_FeedChar("u")
    Match := HSE_FeedChar("i")
    AssertTrue(Match != "",
        "InWord trigger ignores the boundary check and fires mid-word")
}
Test("HSE InWord trigger ignores the word-boundary check",
    TestHSE_InWordTriggerFiresAnywhere)

TestHSE_ApostropheActsAsWordBoundaryStraight() {
    HSE_TestReset()
    ; Non-star, is_word=true trigger "ia" — only fires when a terminator is
    ; typed after AND the char preceding "i" is itself a word boundary.
    HSE_Register("", "ia", () => 0)
    ; Type "l'ia " with the ASCII apostrophe (Chr 0x27).
    HSE_FeedChar("l")
    HSE_FeedChar(Chr(0x27))
    HSE_FeedChar("i")
    HSE_FeedChar("a")
    Match := HSE_FeedChar(" ")   ; terminator fires the end-char path
    AssertTrue(Match != "",
        "trigger fires after l'ia + space — ' is treated as a word boundary")
    AssertEqual("ia", Match.Trigger)
}
Test("HSE ASCII apostrophe acts as word boundary (l'ia + space fires)",
    TestHSE_ApostropheActsAsWordBoundaryStraight)

TestHSE_ApostropheActsAsWordBoundaryTypographic() {
    HSE_TestReset()
    HSE_Register("", "ia", () => 0)
    ; Same as above but with the typographic apostrophe (Chr 0x2019).
    HSE_FeedChar("l")
    HSE_FeedChar(Chr(0x2019))
    HSE_FeedChar("i")
    HSE_FeedChar("a")
    Match := HSE_FeedChar(" ")
    AssertTrue(Match != "",
        "trigger fires after l’ia + space — typographic apostrophe is a word boundary")
    AssertEqual("ia", Match.Trigger)
}
Test("HSE typographic apostrophe acts as word boundary (l’ia + space fires)",
    TestHSE_ApostropheActsAsWordBoundaryTypographic)

TestHSE_CaseInsensitiveMatchesAnyCase() {
    HSE_TestReset()
    HSE_Register("*", "ui", () => 0)
    HSE_FeedChar("U")
    Match := HSE_FeedChar("I")
    AssertTrue(Match != "",
        "case-insensitive trigger matches uppercased input")
}
Test("HSE case-insensitive registration matches any case",
    TestHSE_CaseInsensitiveMatchesAnyCase)

TestHSE_CaseSensitiveRejectsWrongCase() {
    HSE_TestReset()
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
Test("HSE case-sensitive registration is strict on letter case",
    TestHSE_CaseSensitiveRejectsWrongCase)

TestHSE_LongestMatchWins() {
    HSE_TestReset()
    HSE_Register("*", "re", () => 0)
    HSE_Register("*", "fre", () => 0)
    HSE_FeedChar("f")
    HSE_FeedChar("r")
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "")
    AssertEqual("fre", Match.Trigger,
        "longest matching trigger wins when several share a suffix")
}
Test("HSE longest match wins when multiple triggers share a suffix",
    TestHSE_LongestMatchWins)


; ── nnbsp/nbsp + punctuation + vowel → J triggers ──
; The Ergopti shift layer sends Chr(0x202F) (nnbsp) + ';' or ':' and the ¨+s
; deadkey sends Chr(0x00A0) (nbsp). These prefixes act as a "shifted comma"
; that must expand the following vowel to a capital J form (e.g. nnbsp+;+e →
; "Je"). The triggers are star (*) + in-word (?) + case-sensitive (C). These
; tests prove the engine matches the multi-char prefix as a suffix even though
; ';' and ':' are themselves word terminators — the regression that made the
; feature silently fail on Windows.
TestHSE_NnbspSemicolonVowelFires() {
    HSE_TestReset()
    Trigger := Chr(0x202F) Chr(0x3B) "e"   ; nnbsp + ';' + 'e'
    HSE_Register("*?C", Trigger, () => 0)
    HSE_FeedChar(Chr(0x202F))
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "",
        "nnbsp+';'+'e' fires the star trigger despite ';' being a terminator")
    AssertEqual(Trigger, Match.Trigger)
}
Test("HSE nnbsp + semicolon + vowel fires the J trigger",
    TestHSE_NnbspSemicolonVowelFires)

TestHSE_NnbspColonVowelFires() {
    HSE_TestReset()
    Trigger := Chr(0x202F) ":" "e"         ; nnbsp + ':' + 'e'
    HSE_Register("*?C", Trigger, () => 0)
    HSE_FeedChar(Chr(0x202F))
    HSE_FeedChar(":")
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "",
        "nnbsp+':'+'e' fires the star trigger despite ':' being a terminator")
    AssertEqual(Trigger, Match.Trigger)
}
Test("HSE nnbsp + colon + vowel fires the J trigger",
    TestHSE_NnbspColonVowelFires)

TestHSE_NbspSemicolonVowelFires() {
    HSE_TestReset()
    Trigger := Chr(0x00A0) Chr(0x3B) "e"   ; nbsp + ';' + 'e'
    HSE_Register("*?C", Trigger, () => 0)
    HSE_FeedChar(Chr(0x00A0))
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "",
        "nbsp (U+00A0) variant fires too — the deadkey ¨+s path")
    AssertEqual(Trigger, Match.Trigger)
}
Test("HSE nbsp + semicolon + vowel fires the J trigger",
    TestHSE_NbspSemicolonVowelFires)

TestHSE_NnbspPrefixFiresAfterLeadingWord() {
    HSE_TestReset()
    Trigger := Chr(0x202F) Chr(0x3B) "e"
    HSE_Register("*?C", Trigger, () => 0)
    ; Mimic the real buffer: a finished word, a space, then the prefix+vowel.
    ; InWord (?) makes the match robust to anything left of the prefix.
    for Char in StrSplit("Bonjour ") {
        HSE_FeedChar(Char)
    }
    HSE_FeedChar(Chr(0x202F))
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "",
        "suffix match fires regardless of preceding word context (InWord trigger)")
    AssertEqual(Trigger, Match.Trigger)
}
Test("HSE nnbsp J trigger fires as a suffix after a leading word",
    TestHSE_NnbspPrefixFiresAfterLeadingWord)

TestHSE_NnbspUppercaseVowelNeedsOwnTrigger() {
    HSE_TestReset()
    ; The lowercase trigger is case-sensitive (C) and must NOT match an
    ; uppercase vowel — proving the explicit uppercase registrations are
    ; required (the bug where ':E' produced nothing).
    LowerTrigger := Chr(0x202F) Chr(0x3B) "e"
    HSE_Register("*?C", LowerTrigger, () => 0)
    HSE_FeedChar(Chr(0x202F))
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("E")
    AssertEqual("", Match,
        "case-sensitive lowercase trigger does NOT fire on an uppercase vowel")
    ; Now register the uppercase variant and confirm it fires.
    UpperTrigger := Chr(0x202F) Chr(0x3B) "E"
    HSE_Register("*?C", UpperTrigger, () => 0)
    HSE_FeedReset(true)
    HSE_FeedChar(Chr(0x202F))
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("E")
    AssertTrue(Match != "",
        "explicit uppercase trigger fires on the uppercase vowel")
    AssertEqual(UpperTrigger, Match.Trigger)
}
Test("HSE uppercase vowel requires its own case-sensitive J trigger",
    TestHSE_NnbspUppercaseVowelNeedsOwnTrigger)

TestHSE_BareSemicolonVowelFiresInWord() {
    HSE_TestReset()
    ; The bare ";" (comma-layer key) J trigger is registered "*?C" — in-word —
    ; so the capital J is guaranteed in EVERY context, never word-boundary-gated.
    ; This locks in the deliberate design: "test;e" must still expand to "testJe".
    Trigger := Chr(0x3B) "e"   ; ";" + "e"
    HSE_Register("*?C", Trigger, () => 0)
    for Char in StrSplit("test") {
        HSE_FeedChar(Char)
    }
    HSE_FeedChar(Chr(0x3B))
    Match := HSE_FeedChar("e")
    AssertTrue(Match != "",
        "bare ';'+vowel fires unconditionally (in-word), even straight after a letter")
    AssertEqual(Trigger, Match.Trigger)
}
Test("HSE bare semicolon + vowel fires unconditionally (in-word, not gated)",
    TestHSE_BareSemicolonVowelFiresInWord)


; ── ",d → ds" SFB-reduction hotstring: shifted-comma case variants ──
; The base trigger ",d" (auto_expand=true, is_word=false, is_case_sensitive=false)
; expands to "ds". On the Ergopti Shift layer the comma key emits NNBSP + ";" and
; the period key emits NBSP + ":", so the "uppercase" comma is a no-break-space-
; prefixed punctuation — NEVER a plain ASCII space. Matching is deliberately
; lenient: "DS" must come out regardless of WHICH no-break space precedes the
; punctuation. These tests pin two regressions from when _BuildUppercasedSymbols
; used a plain space: (1) the nbsp/nnbsp-prefixed forms never matched (so caps
; never produced "DS"), and (2) a bare "<space>:D" emoji DID match and got
; swallowed into "DS".
TestHSE_CommaShiftCaseVariantsFire() {
    NNBSP := Chr(0x202F)
    NBSP  := Chr(0xA0)
    Colon := ":"
    Semi  := Chr(0x3B)

    ; "DS" must come out for every no-break-space + punctuation combination —
    ; the layout pairs NBSP with ":" and NNBSP with ";", but the deadkey path
    ; and matching leniency make all four prefixes valid "shifted commas".
    Combos := [[NNBSP, Colon], [NBSP, Colon], [NNBSP, Semi], [NBSP, Semi]]
    for _, Combo in Combos {
        HSE_TestReset()
        ; Register exactly the production ",d → ds" entry (flags: * auto, ? in-word).
        CreateCaseSensitiveHotstrings("*?", ",d", "ds")
        HSE_FeedChar(Combo[1])
        HSE_FeedChar(Combo[2])
        Match := HSE_FeedChar("D")
        AssertTrue(Match != "",
            "shifted-comma variant must fire for a no-break-space + punctuation prefix")
        AssertEqual("DS", Match.Replacement,
            "uppercase D yields uppercase replacement DS regardless of nbsp/nnbsp type")
    }

    ; Lowercase vowel after the shifted comma yields titlecase "Ds".
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", ",d", "ds")
    HSE_FeedChar(NNBSP)
    HSE_FeedChar(Semi)
    Match2 := HSE_FeedChar("d")
    AssertTrue(Match2 != "", "nnbsp + semicolon + d must fire the shifted-comma variant")
    AssertEqual("Ds", Match2.Replacement, "lowercase d yields titlecase replacement Ds")
}
Test("HSE comma-shift case variants fire on any nbsp/nnbsp + punctuation",
    TestHSE_CommaShiftCaseVariantsFire)

TestHSE_PlainSpaceColonDDoesNotFire() {
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", ",d", "ds")
    ; A plain ASCII space + ":" + "D" is the ":D" emoji typed after a normal word —
    ; it MUST NOT match the comma hotstring. Anchoring the shifted comma on
    ; nbsp/nnbsp (not a plain space) is exactly what keeps the emoji alive.
    HSE_FeedChar(" ")
    HSE_FeedChar(":")
    Match := HSE_FeedChar("D")
    AssertEqual("", Match,
        "<space> + : + D must NOT fire -- the ':D' emoji stays literal")
}
Test("HSE plain-space colon-D does not fire the comma hotstring (':D' emoji preserved)",
    TestHSE_PlainSpaceColonDDoesNotFire)





; =============================================
; =============================================
; ======= 5/ Buffer update on expansion =======
; =============================================
; =============================================

TestHSE_ApplyExpansionRewritesBufferTail() {
    HSE_TestReset()
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
Test("HSE ApplyExpansion replaces the trigger suffix with the replacement",
    TestHSE_ApplyExpansionRewritesBufferTail)

TestHSE_ApplyExpansionWithEndCharKeepsTerminatorInBuffer() {
    HSE_TestReset()
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
Test("HSE ApplyExpansion keeps the trailing terminator in the buffer post-expansion",
    TestHSE_ApplyExpansionWithEndCharKeepsTerminatorInBuffer)

TestHSE_ApplyExpansionAfterPrefixContext() {
    HSE_TestReset()
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
Test("HSE ApplyExpansion preserves the buffer prefix to the left of the trigger",
    TestHSE_ApplyExpansionAfterPrefixContext)

TestHSE_PersonalCommaPrefixTriggerFires() {
    HSE_TestReset()
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
Test("HSE personal ,a-style trigger fires when the comma stays in the buffer",
    TestHSE_PersonalCommaPrefixTriggerFires)





; =============================================
; =============================================
; ======= 6/ Scenario regression checks =======
; =============================================
; =============================================

TestHSE_ConfigStarFiresAfterCtrlAReset() {
    ; Ctrl+A is a context-replacing keystroke handled at a higher layer by
    ; calling HSE_FeedReset(true). The next typed run should fire even
    ; though the buffer was non-empty before the Ctrl+A.
    HSE_TestReset()
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
Test("HSE regression: config★ fires after Ctrl+A reset",
    TestHSE_ConfigStarFiresAfterCtrlAReset)

TestHSE_OuiBackspaceUiDoesNotFire() {
    ; Reproduces the « oui + BS×3 + UI » case: triple backspace empties the
    ; buffer and flips the boundary flag false on the third invocation,
    ; signalling « we deleted into unknown context ». Retyping ui should
    ; therefore NOT fire the autocorrect trigger.
    HSE_TestReset()
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
Test("HSE regression: ui does not fire after oui+BS+UI",
    TestHSE_OuiBackspaceUiDoesNotFire)

TestHSE_EndCharTriggerNotSuppressedByUnreachableStarTrigger() {
    ; Regression: end-char trigger "ia" was incorrectly suppressed by star
    ; trigger "ia★" even when the typed end char was space, not the magic key.
    ; The suppression logic must only block the end-char match when the typed
    ; end char could itself continue toward the star trigger — space cannot.
    HSE_TestReset()
    HSE_Register("", "ia", () => 0)        ; end-char trigger: ia + terminator
    HSE_Register("*", "ia★", () => 0)      ; star trigger: ia + magic key
    HSE_FeedChar("i")
    HSE_FeedChar("a")
    Match := HSE_FeedChar(" ")             ; space — cannot lead to ia★
    AssertTrue(Match != "",
        "ia + space fires the end-char trigger even though ia★ is registered")
    AssertEqual("ia", Match.Trigger,
        "end-char trigger ia is not suppressed by unrelated star trigger ia★")
}
Test("HSE regression: ia + space fires end-char trigger despite ia★ star trigger",
    TestHSE_EndCharTriggerNotSuppressedByUnreachableStarTrigger)

TestHSE_EndCharTriggerSuppressedWhenEndCharLeadsToStarTrigger() {
    ; Companion to the regression above: when the end char IS the magic key,
    ; the star trigger ia★ should win over the end-char trigger ia.
    HSE_TestReset()
    HSE_Register("", "ia", () => 0)
    HSE_Register("*", "ia★", () => 0)
    HSE_FeedChar("i")
    HSE_FeedChar("a")
    Match := HSE_FeedChar("★")             ; magic key — can continue to ia★
    AssertTrue(Match != "",
        "ia★ star trigger fires when the magic key is typed after ia")
    AssertEqual("ia★", Match.Trigger,
        "star trigger ia★ wins over end-char trigger ia when ★ is typed")
}
Test("HSE end-char trigger is suppressed when the end char continues toward a star trigger",
    TestHSE_EndCharTriggerSuppressedWhenEndCharLeadsToStarTrigger)





; =====================================================
; =====================================================
; ======= 8/ Per-section grouping (live toggle) =======
; =====================================================
; =====================================================

; Each hotstring loaded for a TOML section must land in its own
; "<category>.<section>" HSE group so HSE_EnableGroup / HSE_DisableGroup can
; toggle the section live (no Reload). These tests pin that contract — the
; reload-free tray toggles in ui/tray_menu.ahk depend on it.

TestHSE_GroupDerivedFromObjectMeta() {
    HSE_TestReset()
    Spec := HSE_Register("*", "qz", (*) => "",
        { Category: "autocorrection", Section: "errors", Replacement: "X" })
    AssertEqual("autocorrection.errors", Spec.Group,
        "object Meta with Category/Section derives the <category>.<section> group")
    AssertTrue(HSE_RegistryByGroup.Has("autocorrection.errors"),
        "the derived group is indexed in HSE_RegistryByGroup")
}
Test("HSE group is derived from object Meta Category/Section", TestHSE_GroupDerivedFromObjectMeta)

TestHSE_GroupDerivedFromMapMeta() {
    HSE_TestReset()
    Spec := HSE_Register("*", "qz", (*) => "",
        Map("Category", "rolls", "Section", "hc", "Replacement", "Y"))
    AssertEqual("rolls.hc", Spec.Group,
        "Map Meta with Category/Section derives the <category>.<section> group")
}
Test("HSE group is derived from Map Meta Category/Section", TestHSE_GroupDerivedFromMapMeta)

TestHSE_SectionlessStaysDefault() {
    HSE_TestReset()
    Spec := HSE_Register("*", "qz", (*) => "")
    AssertEqual("default", Spec.Group,
        "a registration with no Category/Section keeps the default group")
}
Test("HSE section-less registration stays in the default group", TestHSE_SectionlessStaysDefault)

TestHSE_ExplicitGroupOverridesDerived() {
    HSE_TestReset()
    Spec := HSE_Register("*", "qz", (*) => "",
        Map("group", "custom_group", "Category", "rolls", "Section", "hc"))
    AssertEqual("custom_group", Spec.Group,
        "an explicit Meta group wins over the derived category.section")
}
Test("HSE explicit Meta group overrides the derived section group", TestHSE_ExplicitGroupOverridesDerived)

TestHSE_DisableGroupStopsSectionFiringSiblingSurvives() {
    HSE_TestReset()
    ; Two star triggers ending in "z", each in its own section group.
    HSE_Register("*", "qz", (*) => "",
        Map("Category", "rolls", "Section", "alpha", "Replacement", "A"))
    HSE_Register("*", "wz", (*) => "",
        Map("Category", "rolls", "Section", "beta", "Replacement", "B"))

    ; Both fire while enabled.
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    M := HSE_FeedChar("z")
    AssertEqual("qz", M.Trigger, "rolls.alpha fires while enabled")

    ; Disabling rolls.alpha removes only its trigger from the live index.
    HSE_DisableGroup("rolls.alpha")
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    M2 := HSE_FeedChar("z")
    AssertEqual("", M2, "rolls.alpha no longer fires once its group is disabled")

    HSE_FeedReset(true)
    HSE_FeedChar("w")
    M3 := HSE_FeedChar("z")
    AssertEqual("wz", M3.Trigger, "sibling section rolls.beta still fires after rolls.alpha is disabled")

    ; Re-enabling rolls.alpha restores its trigger.
    HSE_EnableGroup("rolls.alpha")
    HSE_FeedReset(true)
    HSE_FeedChar("q")
    M4 := HSE_FeedChar("z")
    AssertEqual("qz", M4.Trigger, "rolls.alpha fires again after its group is re-enabled")
}
Test("HSE disabling a section group stops only that section, enabling restores it",
    TestHSE_DisableGroupStopsSectionFiringSiblingSurvives)

; F36 (audit 2026-07-20): a raw callback is allowed to DECLINE (the E-circumflex
; deadkey and ellipsis guards refuse in the wrong context) by returning a falsy effect
; or {Bs:0, Ins:""}. _HSE_DispatchRawCallback swallowed that verdict and returned void,
; so the caller could not tell a fire from a decline and logged every match as a fired
; hotstring — inflating the hotstring counters and per-section stats with expansions
; that never appeared on screen.
TestHSE_DeclinedRawCallbackReportsNotFired() {
    ; A callback that expands reports true; one that declines reports false.
    Fired := HSE_DispatchMatch({ RawCallback: true, Callback: (EndChar) => ({ Bs: 0, Ins: "" }) }, "")
    AssertEqual(false, Fired,
        "a raw callback returning {Bs:0, Ins:''} declined — HSE_DispatchMatch must report false so no fire is logged")

    Fired2 := HSE_DispatchMatch({ RawCallback: true, Callback: (EndChar) => ("") }, "")
    AssertEqual(false, Fired2,
        "a raw callback returning a falsy effect declined — HSE_DispatchMatch must report false")

    AssertEqual(false, HSE_DispatchMatch("", ""),
        "an empty spec is not a fire")
}
Test("HSE: a declined raw callback reports 'not fired' so it is never logged as an expansion",
    TestHSE_DeclinedRawCallbackReportsNotFired)





; ======================================================
; ======================================================
; ======= 9/ Focused-control input generations ========
; ======================================================
; ======================================================

; Seed the exact AHK-06 state: both buffers believe ``ia`` sits left of the
; caret and a preview row is live. The caller owns cleanup because these are
; production globals shared by every test in the runner.
_HSE_SeedArmedInputContext(Token, Generation) {
    global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixInputContextGeneration
    global _KLLastShownSuggestion
    HSE_TestReset()
    HSE_Register("", "ia", (*) => "", { Replacement: "IA" })
    HSE_FeedChar("i", true)
    HSE_FeedChar("a", true)
    _PrefixBuffer := "ia"
    _PrefixFocusedControlToken := Token
    _PrefixInputContextGeneration := Generation
    _KLLastShownSuggestion := { Trigger: "ia", Output: "IA", Category: "autocorrection", IsPrivate: false }
}

TestHSE_InputContextGenerationGuardsRelocation() {
    global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixInputContextGeneration
    global _KLLastShownSuggestion, _Stub_RecordedSends
    PrevPrefix := _PrefixBuffer
    PrevToken := _PrefixFocusedControlToken
    PrevGeneration := _PrefixInputContextGeneration
    PrevSuggestion := _KLLastShownSuggestion
    PrevKeyloggerInit := Keylogger.initialized
    ResetHotstringRecorders()
    Keylogger.initialized := false
    try {
        ; Exact AHK-06 reproductions: both genuine Ctrl chords invalidate before
        ; their target control exists, then Space arrives after the token changes.
        for TestCase in [{ VK: 0x46, Label: "Ctrl+F" }, { VK: 0x4C, Label: "Ctrl+L" }] {
            ResetHotstringRecorders()
            _HSE_SeedArmedInputContext(1001, 40)
            AssertTrue(_PrefixHandleCtrlContextChord(TestCase.VK, true, false),
                TestCase.Label . " must publish a new input-context generation")
            AssertEqual("", HSE_Buffer,
                TestCase.Label . " must clear the engine buffer before focus can move")
            AssertEqual("", _PrefixBuffer,
                TestCase.Label . " must clear the preview buffer in the same transaction")
            AssertEqual("", _KLLastShownSuggestion,
                TestCase.Label . " must remove the preview row owned by the old control")
            AssertEqual(0, _PrefixFocusedControlToken,
                TestCase.Label . " must stay unbound until the destination is observable")
            AssertEqual(41, _PrefixInputContextGeneration)

            AssertTrue(_PrefixEnsureInputContext(2002),
                "the next physical character must bind the destination control")
            AssertEqual(42, _PrefixInputContextGeneration)
            Match := HSE_FeedChar(" ", true)
            if (Match != "")
                HSE_DispatchMatch(Match, HSE_LastEndChar)
            AssertEqual("", Match,
                TestCase.Label . " followed by Space must not reuse old-control trigger ia")
            AssertEqual(0, _Stub_RecordedSends.Length,
                "no stale match means no backspace burst can target the destination")
            AssertEqual("", _KLLastShownSuggestion,
                "Space in the destination must not resurrect the old preview row")
        }

        ; The token is canonical. Bypass the F/L classifier so a chord-only fix
        ; cannot satisfy the test.
        _HSE_SeedArmedInputContext(3003, 80)
        AssertTrue(_PrefixEnsureInputContext(4004))
        AssertEqual("", HSE_Buffer,
            "a focused-control token change must invalidate the engine without a known chord")
        AssertEqual("", _PrefixBuffer,
            "a focused-control token change must invalidate the preview without a known chord")
        AssertEqual("", _KLLastShownSuggestion,
            "the old control's preview row must be dismissed")
        AssertEqual(81, _PrefixInputContextGeneration)
        AssertEqual("", HSE_FeedChar(" ", true),
            "Space in the new control must not complete the old control's ia trigger")

        ; A transient adapter failure ignores input. Recovery must preserve the
        ; unknown-boundary verdict or a later suffix can erase ignored text.
        _HSE_SeedArmedInputContext(6006, 160)
        AssertFalse(_PrefixEnsureInputContext(0),
            "an unverifiable target must fail closed before HSE sees the character")
        AssertFalse(HSE_StartIsWordBoundary,
            "losing focus identity must mark left-hand text unknown")

        AssertTrue(_PrefixEnsureInputContext(6006),
            "tracking may resume even when a windowless control falls back to the same token")
        AssertFalse(HSE_StartIsWordBoundary,
            "focus recovery must not invent a boundary after one or more ignored characters")
        HSE_FeedChar("i", true)
        HSE_FeedChar("a", true)
        AssertEqual("", HSE_FeedChar(" ", true),
            "a suffix typed after unverifiable text must not backspace that unknown text")

        ; AltGr raises synthetic Ctrl on Windows. It must remain a character path,
        ; not be mistaken for either relocation command.
        for VK in [0x46, 0x4C] {
            _HSE_SeedArmedInputContext(5005, 120)
            AssertFalse(_PrefixHandleCtrlContextChord(VK, true, true),
                "AltGr's synthetic Ctrl must not be classified as genuine Ctrl+F/Ctrl+L")
            AssertEqual("ia", HSE_Buffer,
                "an AltGr character must keep the engine context until OnChar feeds it")
            AssertEqual("ia", _PrefixBuffer,
                "an AltGr character must keep the preview context until OnChar feeds it")
            AssertEqual(120, _PrefixInputContextGeneration,
                "AltGr must not advance the focused-control generation")
        }
    } finally {
        Keylogger.initialized := PrevKeyloggerInit
        ResetHotstringRecorders()
        HSE_TestReset()
        _PrefixBuffer := PrevPrefix
        _PrefixFocusedControlToken := PrevToken
        _PrefixInputContextGeneration := PrevGeneration
        _KLLastShownSuggestion := PrevSuggestion
    }
}
Test("HSE input-context-generation: focused-control ownership blocks stale Ctrl+F/Ctrl+L fires",
    TestHSE_InputContextGenerationGuardsRelocation)
