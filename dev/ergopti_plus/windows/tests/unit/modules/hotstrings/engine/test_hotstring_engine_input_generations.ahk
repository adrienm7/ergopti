; tests/unit/modules/hotstrings/engine/test_hotstring_engine_input_generations.ahk

; ==============================================================================
; MODULE: Hotstring Engine Focused-Control Input Generations
; DESCRIPTION:
; AHK-06: the focused-control input generation resets the armed context
; when the control changes and keeps it otherwise.
; ==============================================================================

#Requires AutoHotkey v2.0





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
    PrevKeystatsInit := Keystats.initialized
    ResetHotstringRecorders()
    Keystats.initialized := false
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
        Keystats.initialized := PrevKeystatsInit
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


; Invalid conform input is not an executable candidate. Its earlier sequence or
; higher priority must never mask an exact spelling that the user can type.
_TestHSE_ConformCompetition(Star, ExactFirst) {
    HSE_TestReset()
    Calls := []
    Callback := (*) => Calls.Push("unexpected matcher callback")
    Flags := Star ? "*?" : "?"
    ExactMeta := { Replacement: "EXACT", Priority: 1 }
    ConformMeta := { Replacement: "conformed", CaseConform: true,
        ConformOneChar: false, Priority: 100 }
    if ExactFirst
        HSE_Register(Flags . "C", "aBc", Callback, ExactMeta)
    HSE_Register(Flags, "abc", Callback, ConformMeta)
    if !ExactFirst
        HSE_Register(Flags . "C", "aBc", Callback, ExactMeta)
    for Char in StrSplit("aBc")
        Match := HSE_FeedChar(Char)
    if !Star
        Match := HSE_FeedChar(" ")
    Assert(IsObject(Match), "the executable exact entry must survive conform refusal")
    AssertEqual("aBc", Match.Trigger)
    AssertEqual(1, Match.Priority, "a declined high-priority candidate never participates in arbitration")
    AssertEqual(ExactFirst ? 1 : 2, Match.Seq,
        "case admission leaves the registry's own insertion sequence unchanged")
    Decision := _HSE_PrepareDispatchDecision(Match, Star ? "aBc" : "aBc ", Star ? "" : " ")
    Assert(IsObject(Decision), "the matcher winner must have an executable dispatch decision")
    AssertEqual("EXACT", Decision.Replacement)
    AssertEqual(0, Calls.Length, "matching and preparation invoke no user callback")
}

TestHSE_ConformAdmissionPrecedesArbitration() {
    for Star in [true, false]
        for ExactFirst in [true, false]
            _TestHSE_ConformCompetition(Star, ExactFirst)
}
Test("HSE: mixed conform case yields to exact STAR and END candidates in either insertion order",
    TestHSE_ConformAdmissionPrecedesArbitration)

TestHSE_ConformAdmissionKeepsValidCaseAndNoOpMasking() {
    for Typed in ["abc", "Abc", "ABC"] {
        HSE_TestReset()
        HSE_Register("*?", "abc", (*) => 0,
            { Replacement: "word", CaseConform: true, ConformOneChar: false, Priority: 100 })
        HSE_Register("*?C", Typed, (*) => 0, { Replacement: "fallback", Priority: 1 })
        for Char in StrSplit(Typed)
            Match := HSE_FeedChar(Char)
        Assert(IsObject(Match), "clean lower, Title and UPPER remain conform candidates")
        AssertEqual(100, Match.Priority, "admitted conform candidates retain their actual priority")
        AssertEqual(1, Match.Seq, "admitted conform candidates retain their actual insertion order")
    }
    HSE_TestReset()
    HSE_Register("*?", "abc", (*) => 0,
        { Replacement: "abc", CaseConform: true, ConformOneChar: false, Priority: 100 })
    HSE_Register("*?C", "ABC", (*) => 0, { Replacement: "fallback", Priority: 1 })
    for Char in StrSplit("ABC")
        Match := HSE_FeedChar(Char)
    AssertEqual("", Match, "an admitted conform identity still masks lower-priority replacements")
    HSE_TestReset()
    HSE_Register("*?", "abc", (*) => 0,
        { Replacement: "word", CaseConform: true, ConformOneChar: false })
    for Char in StrSplit("aBc")
        Match := HSE_FeedChar(Char)
    AssertEqual("", Match, "a declined mixed form invents no fallback when none is registered")
}
Test("HSE: conform admission preserves clean casing, registry precedence and identity masking",
    TestHSE_ConformAdmissionKeepsValidCaseAndNoOpMasking)


; Explicit ownership is distinct from the fallback group name. In particular,
; source provenance must not let a bundled section claim a registration whose
; caller deliberately retains the default owner.
_TestHSE_ExplicitGroupAuthority(UseMap, HasGroup, GroupName, Category, Section, Expected) {
    global HSE_RegistryByGroup, HSE_SeqCounter
    HSE_TestReset()
    try {
        Meta := UseMap ? Map("Category", Category, "Section", Section, "Replacement", "owned")
            : { Category: Category, Section: Section, Replacement: "owned" }
        if HasGroup {
            if UseMap
                Meta["group"] := GroupName
            else
                Meta.group := GroupName
        }
        Spec := HSE_Register("*", "qz", (*) => "", Meta)
        AssertEqual(Expected, Spec.Group, "the explicit native owner wins independently of source provenance")
        AssertEqual(Category, Spec.Category, "ownership never rewrites the supplied category")
        AssertEqual(Section, Spec.Section, "ownership never rewrites the supplied section")
        AssertEqual(0, Spec.GroupOrder, "provenance does not invent a load-order rank")
        AssertEqual(1, HSE_SeqCounter, "one registration allocates exactly one insertion sequence")
        AssertTrue(HSE_RegistryByGroup.Has(Expected), "the owning native group is indexed")
        AssertEqual(1, HSE_RegistryByGroup.Count, "no derived or duplicate owner is indexed")
        AssertTrue(HSE_RegistryByGroup[Expected][1] == Spec, "the native group retains the exact registered object")

        Foreign := Expected == "rolls.hc" ? "default" : "rolls.hc"
        HSE_DisableGroup(Foreign)
        HSE_FeedReset(true)
        HSE_FeedChar("q")
        Found := HSE_FeedChar("z")
        AssertTrue(IsObject(Found), "a foreign section gate cannot steal this native registration")
        AssertEqual("qz", Found.Trigger)

        HSE_DisableGroup(Expected)
        HSE_FeedReset(true)
        HSE_FeedChar("q")
        AssertEqual("", HSE_FeedChar("z"), "only its actual owner silences the registration")
        AssertTrue(HSE_RegistryByGroup[Expected][1] == Spec, "disabling retains the exact owned specification")
        HSE_EnableGroup(Expected)
        HSE_FeedReset(true)
        HSE_FeedChar("q")
        Restored := HSE_FeedChar("z")
        AssertTrue(IsObject(Restored), "the owning native gate restores the registration")
        AssertEqual("qz", Restored.Trigger)
        AssertEqual(1, HSE_RegistryByGroup[Expected].Length, "re-enabling never duplicates a registration")
        AssertTrue(HSE_RegistryByGroup[Expected][1] == Spec)
        AssertEqual(1, HSE_SeqCounter, "toggle publication never allocates another insertion sequence")
    } finally {
        HSE_TestReset()
    }
}

Test("HSE explicit default Map owner survives non-empty category provenance",
    () => _TestHSE_ExplicitGroupAuthority(true, true, "default", "rolls", "hc", "default"))
Test("HSE explicit default object owner survives non-empty category provenance",
    () => _TestHSE_ExplicitGroupAuthority(false, true, "default", "rolls", "hc", "default"))

_TestHSE_GroupAuthorityGoldens(UseMap) {
    ; Independent goldens preserve named, future and legacy-empty explicit
    ; groups, and the old derivation only when no explicit owner was supplied.
    for AuthorityRecord in [
        { Present: true, Name: "custom_group", Category: "rolls", Section: "hc", Expected: "custom_group" },
        { Present: true, Name: "future: Équipe / source", Category: "rolls", Section: "hc", Expected: "future: Équipe / source" },
        { Present: true, Name: "", Category: "rolls", Section: "hc", Expected: "" },
        { Present: false, Name: "", Category: "rolls", Section: "hc", Expected: "rolls.hc" },
        { Present: false, Name: "", Category: "", Section: "", Expected: "default" }
    ]
        _TestHSE_ExplicitGroupAuthority(UseMap, AuthorityRecord.Present, AuthorityRecord.Name,
            AuthorityRecord.Category, AuthorityRecord.Section, AuthorityRecord.Expected)
}
Test("HSE Map group authority retains independent named and missing-owner goldens",
    () => _TestHSE_GroupAuthorityGoldens(true))
Test("HSE object group authority retains independent named and missing-owner goldens",
    () => _TestHSE_GroupAuthorityGoldens(false))


TestHSE_MagicCompletionDoesNotOpenWord() {
    global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, HSE_Terminators
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN
    SavedWords := HSE_WORD_TERMINATORS
    SavedConsumed := HSE_CONSUMED_DELIMITERS
    SavedCapacity := HSE_MAX_BUFFER_LEN
    SavedCatalogue := HSE_Terminators
    Magic := ""
    for Entry in HSE_Terminators.all()
        if Entry["key"] == "star"
            Magic := Entry["chars"][1]
    Assert(Magic != "", "the shipped catalogue must own a magic completion slot")
    try {
        HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters()
        HSE_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters()
        for Flags in ["*", ""] {
            HSE_TestReset()
            HSE_Register(Flags, "the", (*) => 0, { Replacement: "THE" })
            for Char in StrSplit(Magic . "the")
                Match := HSE_FeedChar(Char)
            if Flags == ""
                Match := HSE_FeedChar(" ")
            AssertEqual("", Match, "magic-completion-word-boundary: the selector is word text")
        }
        AssertEqual(Magic . "the", _PrefixWordTail(Magic . "the"),
            "preview must not offer a suffix the matcher refuses")
        HSE_TestReset()
        HSE_Register("*", "the", (*) => 0, { Replacement: "THE" })
        AssertEqual("", HSE_PreviewNextDecision(Magic . "th", "e"),
            "the real preview decision must reject the same suffix")
        for Boundary in [" ", ".", "-", "'", Chr(0x2019), Chr(0xA0), Chr(0x202F)] {
            HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters() . Boundary
            HSE_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters() . " "
            HSE_TestReset()
            HSE_Register("*", "the", (*) => 0, { Replacement: "THE" })
            for Char in StrSplit(Boundary . "the")
                Match := HSE_FeedChar(Char)
            Assert(IsObject(Match), "configured punctuation, whitespace and quotes still open words")
        }
        HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters()
        HSE_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters()
        HSE_TestReset()
        HSE_Register("", "foo", (*) => 0, { Replacement: "BAR" })
        for Char in StrSplit("foo" . Magic)
            Match := HSE_FeedChar(Char)
        Assert(IsObject(Match), "magic must remain an end-character selector")
        Effect := HSE_ApplyExpansion(Match, "BAR", Magic)
        AssertEqual("BAR", HSE_Buffer, "the selector is consumed after completion")
        AssertFalse(Effect.KnownBoundaryAfter)
        HSE_TestReset()
        HSE_Register("*", "foo", (*) => 0, { Replacement: Magic })
        for Char in StrSplit("foo")
            Match := HSE_FeedChar(Char)
        Effect := HSE_ApplyExpansion(Match, Magic)
        AssertFalse(Effect.KnownBoundaryAfter, "inserted magic text cannot invent a boundary")
        HSE_MAX_BUFFER_LEN := 3
        HSE_Buffer := Magic . "the"
        HSE_StartIsWordBoundary := true
        _HSE_TrimBufferToCapacity()
        AssertEqual("the", HSE_Buffer)
        AssertFalse(HSE_StartIsWordBoundary, "eviction must retain the real preceding word character")
        HSE_MAX_BUFFER_LEN := SavedCapacity
        HSE_Terminators := Terminators()
        for SlotChar in ["§", "-"] {
            HSE_Terminators.updateMagicKey(SlotChar)
            HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters()
            HSE_TestReset()
            HSE_Register("*", "the", (*) => 0, { Replacement: "THE" })
            for Char in StrSplit(SlotChar . "the")
                Match := HSE_FeedChar(Char)
            if SlotChar == "-"
                Assert(IsObject(Match), "an ASCII magic slot keeps its punctuation role")
            else
                AssertEqual("", Match, "a renamed Unicode slot retains completion-only semantics")
        }
    } finally {
        HSE_Terminators := SavedCatalogue
        HSE_WORD_TERMINATORS := SavedWords
        HSE_CONSUMED_DELIMITERS := SavedConsumed
        HSE_MAX_BUFFER_LEN := SavedCapacity
        HSE_TestReset()
    }
}
Test("HSE magic-completion-word-boundary: completion and word opening have separate roles",
    TestHSE_MagicCompletionDoesNotOpenWord)

_UCAP_WithEngine(Body) {
	global HSE_MAX_BUFFER_LEN, HSE_WORD_TERMINATORS
	Saved := { Capacity: HSE_MAX_BUFFER_LEN, Terminators: HSE_WORD_TERMINATORS }
	try {
		HSE_TestReset()
		HSE_MAX_BUFFER_LEN := 3
		HSE_WORD_TERMINATORS := HSE_TerminatorDefaultWordDelimiters()
		Body()
	} finally {
		HSE_MAX_BUFFER_LEN := Saved.Capacity
		HSE_WORD_TERMINATORS := Saved.Terminators
		HSE_TestReset()
	}
}

_UCAP_EngineTail(Boundary) {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS
	if Boundary
		HSE_WORD_TERMINATORS .= Chr(0x1F600)
	for Char in ["A", Chr(0x1F600), "b", "c"]
		HSE_FeedChar(Char)
	AssertEqual("bc", HSE_Buffer, "a bounded tail drops the complete oldest pair")
	AssertEqual(Boundary, HSE_StartIsWordBoundary,
		"the last discarded complete scalar determines the left boundary")
}
Test("HSE unicode-context-cap: typed tail never starts with half a pair", (*) =>
	_UCAP_WithEngine(_UCAP_EngineTail.Bind(false)))
Test("HSE unicode-context-cap: discarded supplementary boundary remains known", (*) =>
	_UCAP_WithEngine(_UCAP_EngineTail.Bind(true)))

_UCAP_EngineFraming() {
	global HSE_WORD_TERMINATORS, HSE_Buffer, HSE_LastEndChar
	Delimiter := Chr(0x1F600)
	HSE_WORD_TERMINATORS .= Delimiter
	HSE_Register("?C", "abc", (*) => 0)
	for Char in ["a", "b", "c"]
		HSE_FeedChar(Char)
	Match := HSE_FeedChar(Delimiter)
	AssertEqual("abc" . Delimiter, HSE_Buffer,
		"the full completion scalar is framing outside the trigger capacity")
	Assert(IsObject(Match), "the longest admitted END trigger still matches")
	AssertEqual(Delimiter, HSE_LastEndChar)
}
Test("HSE unicode-context-cap: supplementary END framing does not evict trigger text", (*) =>
	_UCAP_WithEngine(_UCAP_EngineFraming))

_UCAP_EngineReplacement() {
	global HSE_Buffer
	Spec := HSE_Register("*?", "x", (*) => 0)
	HSE_FeedChar("x")
	HSE_ApplyExpansion(HSE_LastMatch, "A" . Chr(0x1F600) . "bc")
	AssertEqual("bc", HSE_Buffer, "replacement commits share the pair-safe capacity owner")
}
Test("HSE unicode-context-cap: committed replacement retains a valid bounded suffix", (*) =>
	_UCAP_WithEngine(_UCAP_EngineReplacement))

/** Exercises pending output through TextSender and an owned native Edit boundary. */
_HUE_NativeNotepad() {
	_HNP_Run(_HUE_NativeNotepadBody)
}

_HUE_NativeNotepadBody() {
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer, _LSC_LEN
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL, _TEXT_CLIPBOARD_QUEUE
	global _HSE_FireLogQueue, _PrefixWatcherSuppressed, _Stub_RecordedSends
	AssertFalse(_TEXT_NATIVE_OWNER, "the Unicode fixture cannot adopt a native output")
	SavedSerial := _TEXT_NATIVE_SERIAL
	QueueLength := _TEXT_CLIPBOARD_QUEUE.Length
	PreviousCritical := Critical("Off")
	Receiver := Gui()
	State := { NativeOwner: 0, Replaced: false }
	try {
		Emoji := Chr(0x1F600)
		Seed := "A" . Emoji . "x"
		Editor := Receiver.AddEdit(, Seed)
		State := { Receiver: Receiver, Editor: Editor, Seed: Seed, Phase: 1,
			Requests: [], Scheduled: 0, NativeOwner: 0, Begins: 0, Decisions: 0,
			Closes: 0, Callbacks: 0, Replaced: false, RingLength: 0, CallbackError: "" }
		Receiver.Show("Hide")
		SendMessage(0xB1, 4, 4, Editor)
		_HUE_AssertCaret(Editor, 4, 4)
		ResetHotstringRecorders()
		SimulateNotepadActive()
		HSE_TestReset()
		CreateHotstring("*?C", Emoji . "x", "R",
			Map("Category", "_unicode_probe", "Section", "native"))
		HSE_FeedChar("A")
		HSE_FeedChar(Emoji)
		Match := HSE_FeedChar("x")
		AssertTrue(IsObject(Match), "the supplementary trigger must match")
		_PrefixBuffer := Seed
		_LLM_Bridge_Buffer := Seed
		_LSCResetFrom(["A", Emoji, "x"])
		State.RingLength := _LSC_LEN
		State.Port := Map("focus", _HUE_Focus.Bind(State), "begin", _HUE_Begin.Bind(State),
			"poll", _HUE_Poll.Bind(State), "decide", _HUE_Decide.Bind(State),
			"close", _HUE_Close.Bind(State), "schedule", _HUE_Schedule.Bind(State))
		Effect := 0
		Pending := HSE_DispatchMatch(Match, "", &Effect, false, _HUE_Send.Bind(State))
		AssertEqual("", State.CallbackError, "the recording native port must not refuse before admission")
		AssertTrue(Pending is Map, "the actual dispatcher returns its pending native owner")
		AssertTrue(Pending["Pending"], "queueing cannot claim receiving success")
		AssertEqual(1, State.Requests.Length, "one real request owns completion")
		Request := State.Requests[1]
		AssertEqual("native", Request.Opts["mode"], "Notepad uses its native owner")
		AssertEqual(2, Request.Opts["erase_before"], "the erasure counts two Unicode scalars")
		AssertEqual(Emoji . "x", Request.Opts["deleted_text"], "the exact typed tail is retained")
		AssertEqual(3, StrLen(Request.Opts["deleted_text"]), "the native range spans three UTF-16 units")
		AssertEqual("R", Request.Text, "the literal replacement remains exact")
		_HUE_AssertPending(State)
		State.Scheduled.Call()
		AssertEqual(1, State.Begins, "the real TextSender scheduler begins once")
		_HUE_AssertPending(State)
		State.Phase := 2
		State.Scheduled.Call()
		AssertEqual(1, State.Decisions, "ready admission authorizes one owned editor mutation")
		AssertEqual("AR", Editor.Value, "native replacement preserves the preceding character")
		_HUE_AssertCaret(Editor, 2, 2)
		_HUE_AssertPending(State)
		State.Scheduled.Call()
		AssertTrue(Pending["FinalSucceeded"], "verified output completes the canonical owner")
		AssertEqual(Editor.Value, HSE_Buffer, "the complete HSE mirror equals native output")
		AssertEqual(Editor.Value, _LLM_Bridge_Buffer, "the complete LLM mirror equals native output")
		AssertEqual("R", GetLastSentCharacterAt(-1), "completion updates the real last-character ring")
		AssertEqual(1, _HSE_FireLogQueue.Length, "completion records one verified fire")
		AssertEqual(0, _PrefixWatcherSuppressed, "completion releases suppression once")
		AssertEqual(1, State.Callbacks, "TextSender publishes one completion callback")
		AssertEqual(1, State.Closes, "the recording native job closes once")
		State.Scheduled.Call()
		AssertEqual(1, State.Callbacks, "duplicate polling cannot publish another callback")
		AssertEqual(1, State.Decisions, "duplicate polling cannot repeat the editor mutation")
		AssertEqual(1, _HSE_FireLogQueue.Length, "duplicate polling cannot repeat the fire")
		AssertEqual(0, _Stub_RecordedSends.Length, "no keyboard or clipboard sender runs")
		AssertEqual(QueueLength, _TEXT_CLIPBOARD_QUEUE.Length, "no clipboard output is queued")
	} finally {
		try {
			if State.NativeOwner && _TEXT_NATIVE_OWNER == State.NativeOwner
				_TextSenderFinishNative(State.NativeOwner, State.Replaced ? 6 : 5,
					0, "Unicode fixture cleanup")
		} finally {
			try Receiver.Destroy()
			finally {
				_TEXT_NATIVE_SERIAL := SavedSerial
				HSE_TestReset()
				Critical(PreviousCritical)
			}
		}
	}
}

_HUE_AssertPending(State) {
	global HSE_Buffer, _LLM_Bridge_Buffer, _LSC_LEN, _HSE_FireLogQueue
	AssertEqual(State.Seed, HSE_Buffer, "pending output cannot rewrite HSE")
	AssertEqual(State.Seed, _LLM_Bridge_Buffer, "pending output cannot rewrite LLM")
	AssertEqual(State.RingLength, _LSC_LEN, "pending output cannot edit the ring length")
	AssertEqual("x", GetLastSentCharacterAt(-1), "pending output cannot edit the last character")
	AssertEqual(0, _HSE_FireLogQueue.Length, "pending output is not a fire")
	AssertEqual(0, State.Callbacks, "receiving verification precedes completion")
}

_HUE_AssertCaret(Editor, Start, Finish) {
	StartBuffer := Buffer(4, 0)
	FinishBuffer := Buffer(4, 0)
	SendMessage(0xB0, StartBuffer.Ptr, FinishBuffer.Ptr, Editor)
	AssertEqual(Start, NumGet(StartBuffer, 0, "UInt"), "the full DWORD selection start is exact")
	AssertEqual(Finish, NumGet(FinishBuffer, 0, "UInt"), "the full DWORD selection end is exact")
}

_HUE_Send(State, Text, Opts, Callback) {
	global _TEXT_NATIVE_OWNER
	State.Requests.Push({ Text: Text, Opts: Opts, Callback: Callback })
	Options := Opts.Clone()
	Options["native_port"] := State.Port
	TextSend(Text, Options, _HUE_Completed.Bind(State, Callback))
	State.NativeOwner := _TEXT_NATIVE_OWNER
}

_HUE_Completed(State, Callback, Ok, ErrorMessage := "") {
	State.Callbacks += 1
	State.CallbackError := ErrorMessage
	Callback.Call(Ok, ErrorMessage)
}

_HUE_Focus(State) {
	global DriverPid
	return Map("hwnd", State.Receiver.Hwnd, "control", State.Editor.Hwnd, "pid", DriverPid)
}

_HUE_Begin(State, Owner) {
	State.Begins += 1
	AssertTrue(Owner == State.NativeOwner, "the recording boundary receives the real queued owner")
	return 0
}

_HUE_Poll(State, Token) {
	AssertEqual(State.NativeOwner.Token, Token, "poll uses the exact native request token")
	return Map("phase", State.Phase, "os_error", 0)
}

_HUE_Decide(State, Token, Commit) {
	AssertEqual(State.NativeOwner.Token, Token, "decision uses the exact native request token")
	AssertEqual(1, Commit, "the immutable request remains admitted")
	State.Decisions += 1
	AssertEqual(State.Seed, State.Editor.Value, "the owned receiver retains the complete pre-edit document")
	_HUE_AssertCaret(State.Editor, 4, 4)
	SendMessage(0xB1, 1, 4, State.Editor)
	_HUE_AssertCaret(State.Editor, 1, 4)
	Literal := Buffer(4, 0)
	StrPut("R", Literal, "UTF-16")
	SendMessage(0xC2, 1, Literal.Ptr, State.Editor)
	State.Replaced := true
	AssertEqual("AR", State.Editor.Value, "the receiving editor independently verifies the complete document")
	_HUE_AssertCaret(State.Editor, 2, 2)
	State.Phase := 4
	return 0
}

_HUE_Close(State, Token) {
	AssertEqual(State.NativeOwner.Token, Token, "close uses the exact native request token")
	State.Closes += 1
	return 0
}

_HUE_Schedule(State, Callback) {
	State.Scheduled := Callback
}

#Include test_hotstring_scalar_framing.ahk
