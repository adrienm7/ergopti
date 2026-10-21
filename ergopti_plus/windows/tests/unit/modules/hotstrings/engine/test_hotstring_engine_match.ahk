; tests/unit/modules/hotstrings/engine/test_hotstring_engine_match.ahk

; ==============================================================================
; MODULE: Hotstring Engine Match Logic
; DESCRIPTION:
; Star, end-char and word triggers fire on the right character with the
; right replacement, through the by-trigger and prefix indexes.
; ==============================================================================

#Requires AutoHotkey v2.0





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

TestHSE_RegistrationOwnsSequenceAfterClear() {
    global HSE_SeqCounter
    HSE_TestReset()
    try {
        EarlierMeta := _MakeHotstringMeta("earlier construction", "seq", true, false, 0)
        LaterMeta := _MakeHotstringMeta("later construction", "seq", true, false, 0)
        AssertEqual(0, HSE_SeqCounter, "constructing metadata must not reserve a registry identity")
        HSE_Register("*?", "discarded", () => 0, EarlierMeta)
        HSE_RegistryClear()
        First := HSE_Register("*?", "seq", () => 0, LaterMeta)
        Second := HSE_Register("*?", "seq", () => 0, EarlierMeta)
        AssertEqual(1, First.Seq, "the first registration after clear starts at one, regardless of construction history")
        AssertEqual(2, Second.Seq, "reverse metadata construction order cannot reverse insertion precedence")
        AssertEqual(2, HSE_SeqCounter, "only live registry allocations own the sequence")
        AssertTrue(_HSE_Beats(First, Second), "the first real registration wins an equal-priority collision")
        AssertFalse(_HSE_Beats(Second, First), "an older metadata object cannot outrank an earlier registration")
    } finally HSE_TestReset()
}
Test("HSE registration owns insertion sequence after metadata construction and registry clear (hotstring-sequence-owner)",
    TestHSE_RegistrationOwnsSequenceAfterClear)

TestHSE_MetadataCannotReplaceRegistrationSequence() {
    global HSE_SeqCounter
    HSE_TestReset()
    try {
        MapMeta := Map("group", "sequence.map", "Seq", 999, "FutureField", "map transport")
        ObjectMeta := { group: "sequence.object", SEQ: -1, FutureField: "object transport" }
        LowercaseMeta := Map("group", "sequence.lowercase", "seq", 77, "FutureField", "lowercase transport")
        for Index, Meta in [MapMeta, ObjectMeta, LowercaseMeta] {
            Spec := HSE_Register("*?", "seq", () => 0, Meta)
            AssertEqual(Index, Spec.Seq, "Map and object metadata, including case variants, cannot assign registry identity")
            ExpectedField := Index == 1 ? "map transport" : Index == 2 ? "object transport" : "lowercase transport"
            AssertEqual(ExpectedField, Spec.FutureField, "unrelated metadata must retain its existing transport contract")
        }
        AssertEqual(3, HSE_SeqCounter)
        AssertEqual(999, MapMeta["Seq"], "the owner must not mutate caller metadata")
        AssertEqual(-1, ObjectMeta.SEQ)
        AssertEqual(77, LowercaseMeta["seq"])
    } finally HSE_TestReset()
}
Test("HSE metadata preserves arbitrary fields while the registry owns sequence identity (hotstring-sequence-owner)",
    TestHSE_MetadataCannotReplaceRegistrationSequence)

TestHSE_MixedFactoriesKeepSequenceAndGroupIsolation() {
    global _HotstringRegistrar, HSE_SeqCounter, HSE_RegistryByGroup, HSE_RegistryByLastChar, HSE_StarSpecs
    SavedRegistrar := _HotstringRegistrar
    HSE_TestReset()
    try {
        _HotstringRegistrar := 0
        RawFirst := HSE_Register("*?", "seqmix", () => 0, Map("group", "sequence.first", "Priority", 10))
        CreateHotstring("*?", "seqmix", "builder", Map("Category", "sequence", "Section", "builder", "Priority", 10))
        CreateRawCallbackHotstring("*?", "seqmix", () => 0,
            Map("Category", "sequence", "Section", "callback", "Priority", 10))
        RawLast := HSE_Register("*?", "seqmix", () => 0, Map("group", "sequence.last", "Priority", 10))
        Built := HSE_RegistryByGroup["sequence.builder"][1]
        Callback := HSE_RegistryByGroup["sequence.callback"][1]
        for Index, Spec in [RawFirst, Built, Callback, RawLast]
            AssertEqual(Index, Spec.Seq, "bare, builder and raw-callback paths share exactly one insertion order")
        AssertEqual(4, HSE_SeqCounter)
        AssertEqual(4, HSE_RegistryByLastChar["x"].Length)
        AssertEqual(4, HSE_StarSpecs.Length)
        HSE_FeedReset(true)
        for Char in StrSplit("seqmix")
            Match := HSE_FeedChar(Char)
        AssertEqual("sequence.first", Match.Group, "the first registration keeps equal-priority precedence")
        HSE_DisableGroup("sequence.builder")
        AssertEqual(3, HSE_RegistryByLastChar["x"].Length, "disabling the builder removes only its own spec")
        AssertEqual(3, HSE_StarSpecs.Length, "star identities cannot collide across registration paths")
        Seen := Map()
        for Spec in HSE_RegistryByLastChar["x"]
            Seen[Spec.Group] := true
        AssertEqual(3, Seen.Count)
        AssertTrue(Seen.Has("sequence.first") && Seen.Has("sequence.callback") && Seen.Has("sequence.last"),
            "every foreign group survives the builder disable")
        HSE_DisableGroup("sequence.first")
        HSE_DisableGroup("sequence.last")
        AssertEqual(1, HSE_RegistryByLastChar["x"].Length)
        AssertEqual("sequence.callback", HSE_RegistryByLastChar["x"][1].Group)
        HSE_EnableGroup("sequence.builder")
        HSE_EnableGroup("sequence.builder")
        AssertEqual(2, HSE_RegistryByLastChar["x"].Length, "repeated enable is idempotent across factory paths")
        AssertEqual(2, HSE_StarSpecs.Length)
        HSE_FeedReset(true)
        for Char in StrSplit("seqmix")
            Match := HSE_FeedChar(Char)
        AssertEqual("sequence.builder", Match.Group, "the earlier builder wins after its isolated group is restored")
    } finally {
        HSE_TestReset()
        _HotstringRegistrar := SavedRegistrar
    }
}
Test("HSE mixed registration factories preserve order and isolate idempotent group toggles (hotstring-sequence-owner)",
    TestHSE_MixedFactoriesKeepSequenceAndGroupIsolation)

TestHSE_GroupTogglesRejectMetadataIdentityCollisions() {
    global HSE_RegistryByLastChar, HSE_StarSpecs
    HSE_TestReset()
    try {
        Keep := HSE_Register("*?", "alias", () => 0, Map("group", "sequence.keep", "Seq", 42))
        Toggle := HSE_Register("*?", "alias", () => 0, Map("group", "sequence.toggle", "Seq", 42))
        HSE_DisableGroup("sequence.toggle")
        AssertEqual(1, HSE_RegistryByLastChar["s"].Length, "a repeated caller identity cannot remove another group's live spec")
        AssertEqual("sequence.keep", HSE_RegistryByLastChar["s"][1].Group)
        AssertEqual(1, HSE_StarSpecs.Length)
        HSE_EnableGroup("sequence.toggle")
        HSE_EnableGroup("sequence.toggle")
        AssertEqual(2, HSE_RegistryByLastChar["s"].Length, "a repeated caller identity cannot suppress the restored spec")
        AssertEqual(2, HSE_StarSpecs.Length, "repeated enable does not duplicate either owned identity")
        AssertEqual(1, Keep.Seq)
        AssertEqual(2, Toggle.Seq)
        HSE_FeedReset(true)
        for Char in StrSplit("alias")
            Match := HSE_FeedChar(Char)
        AssertEqual("sequence.keep", Match.Group, "the earlier foreign spec retains precedence after a toggle")
    } finally HSE_TestReset()
}
Test("HSE group toggles preserve foreign specs despite repeated caller sequence metadata (hotstring-sequence-owner)",
    TestHSE_GroupTogglesRejectMetadataIdentityCollisions)

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

; A tester's personal entry won its collision at priority 100 yet could not type
; its capitalised output: the cased family lowercased the replacement before
; registering, so "ppt" typed "powerpoint" and "Ppt" typed "Powerpoint". Only the
; typed casing may change the output: lower keeps the replacement as written,
; Title capitalises its first letter, UPPER upper-cases all of it.
_HSE_FeedWordThenSpace(Word) {
    HSE_FeedReset(true)
    loop parse Word
        HSE_FeedChar(A_LoopField)
    return HSE_FeedChar(" ")
}
TestHSE_CasedFamilyKeepsReplacementCapitals() {
    global HSE_PRIORITY_COMMON
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("", "ppt", "ppt", Map("Priority", HSE_PRIORITY_COMMON))
    CreateCaseSensitiveHotstrings("", "ppt", "PowerPoint", Map("Priority", 100))
    for Vector in [["ppt", "PowerPoint"], ["Ppt", "PowerPoint"], ["PPT", "POWERPOINT"]] {
        Match := _HSE_FeedWordThenSpace(Vector[1])
        AssertTrue(Match != "", "the priority 100 entry fires on '" . Vector[1] . "'")
        AssertEqual(100, Match.Priority, "the priority 100 entry wins on '" . Vector[1] . "'")
        AssertTrue(Match.Replacement == Vector[2],
            "'" . Vector[1] . "' types '" . Vector[2] . "', got '" . Match.Replacement . "'")
    }
}
Test("HSE cased family keeps the replacement's own capitals at any priority",
    TestHSE_CasedFamilyKeepsReplacementCapitals)

; The literal registration (the editor's « Case sensitive » box) emits the output
; exactly as written whatever casing was typed: that is the setting for an output
; that must never change case, at the priority that wins the collision.
TestHSE_LiteralEntryEmitsVerbatimAtPriority() {
    global HSE_PRIORITY_COMMON
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("", "ppt", "ppt", Map("Priority", HSE_PRIORITY_COMMON))
    HSE_RegisterFromTomlFlags(true, "", "ppt", "PowerPoint", Map("Priority", 100))
    for Typed in ["ppt", "Ppt", "PPT"] {
        Match := _HSE_FeedWordThenSpace(Typed)
        AssertTrue(Match != "" && Match.Priority == 100, "the literal priority 100 entry wins on '" . Typed . "'")
        AssertTrue(Match.Replacement == "PowerPoint", "'" . Typed . "' types the literal output")
    }
}
Test("HSE literal entry emits its output verbatim at the winning priority",
    TestHSE_LiteralEntryEmitsVerbatimAtPriority)

; The preview indexes the same variants the engine registers, with the same
; casing, or the tooltip promises "powerpoint" while "PowerPoint" is typed.
TestHSE_PreviewVariantsKeepReplacementCapitals() {
    Index := Map(), Triggers := Map()
    _AddTriggerVariants("ppt", "PowerPoint", "personal", "s", false, false, "", Index, Triggers, 100)
    AssertTrue(Index["ppt"][1].Output == "PowerPoint", "lower-case preview keeps the capitals")
    AssertTrue(Index["Ppt"][1].Output == "PowerPoint", "Title preview keeps the inner capitals")
    AssertTrue(Index["PPT"][1].Output == "POWERPOINT", "UPPER preview upper-cases the output")
}
Test("HSE preview variants keep the replacement's own capitals",
    TestHSE_PreviewVariantsKeepReplacementCapitals)

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
