; tests/unit/modules/hotstrings/engine/test_hotstring_engine_expansion.ahk

; ==============================================================================
; MODULE: Hotstring Engine Expansion and Grouping
; DESCRIPTION:
; ApplyExpansion rewrites the buffer tail, scenario regressions replay
; reported sequences, and each loaded hotstring carries the live-toggle
; group of its TOML section.
; ==============================================================================

#Requires AutoHotkey v2.0





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

TestHSE_CrossSensitivityStarArbitration() {
    global HSE_WORD_TERMINATORS
    ; Every star sensitivity is authoritative for its own prefix semantics.
    ; In particular, a CI star must shadow a cased end trigger, while a CS star
    ; may shadow a CI end only when the suffix actually typed has exact case.
    Cases := [
        { EndFlags: "", End: "ab", StarFlags: "*", Star: "ab★c", Typed: "Ab", Shadow: true },
        { EndFlags: "C", End: "Ab", StarFlags: "*", Star: "ab★c", Typed: "Ab", Shadow: true },
        { EndFlags: "", End: "ab", StarFlags: "*C", Star: "Ab★c", Typed: "Ab", Shadow: true },
        { EndFlags: "C", End: "Ab", StarFlags: "*C", Star: "Ab★c", Typed: "Ab", Shadow: true },
        { EndFlags: "", End: "ab", StarFlags: "*C", Star: "ab★c", Typed: "Ab", Shadow: false },
        { EndFlags: "C", End: "Ab", StarFlags: "*C", Star: "ab★c", Typed: "Ab", Shadow: false }
    ]
    SavedTerminators := HSE_WORD_TERMINATORS
    try {
        if !InStr(HSE_WORD_TERMINATORS, "★")
            HSE_WORD_TERMINATORS .= "★"
        for Index, Vector in Cases {
            HSE_TestReset()
            HSE_Register(Vector.EndFlags, Vector.End, () => 0)
            HSE_Register(Vector.StarFlags, Vector.Star, () => 0)
            for Char in StrSplit(Vector.Typed)
                HSE_FeedChar(Char)
            PrefixMatch := HSE_FeedChar("★")
            if Vector.Shadow {
                AssertEqual("", PrefixMatch,
                    "case " . Index . ": incomplete longer star must defer the end trigger")
                CompleteMatch := HSE_FeedChar("c")
                AssertTrue(CompleteMatch != "",
                    "case " . Index . ": longer star must remain completable")
                AssertEqual(Vector.Star, CompleteMatch.Trigger,
                    "case " . Index . ": completed star must win")
            } else {
                AssertTrue(PrefixMatch != "",
                    "case " . Index . ": mismatched CS star must not suppress the end trigger")
                AssertEqual(Vector.End, PrefixMatch.Trigger,
                    "case " . Index . ": the valid end trigger must fire")
            }
        }
    } finally {
        HSE_WORD_TERMINATORS := SavedTerminators
    }
}
Test("HSE cross-sensitivity end/star arbitration follows the star candidate",
    TestHSE_CrossSensitivityStarArbitration)

TestHSE_StarPrefixRequiresEligibleContinuation() {
    Cases := [
        { Flags: "*", Typed: "xfoo", Boundary: true, Conform: false, Shadow: false },
        { Flags: "*?", Typed: "xfoo", Boundary: true, Conform: false, Shadow: true },
        { Flags: "*", Typed: "foo", Boundary: true, Conform: false, Shadow: true },
        { Flags: "*", Typed: "foo", Boundary: false, Conform: false, Shadow: false },
        { Flags: "*", Typed: "x'foo", Boundary: false, Conform: false, Shadow: true },
        { Flags: "*?", Typed: "fOo", Boundary: true, Conform: true, Shadow: false },
        { Flags: "*?", Typed: "Foo", Boundary: true, Conform: true, Shadow: true },
        { Flags: "*?", Typed: "FOO", Boundary: true, Conform: true, Shadow: true }
    ]
    for Index, Vector in Cases {
        HSE_TestReset()
        try {
            HSE_FeedReset(Vector.Boundary)
            HSE_Register("?", "foo", () => 0)
            HSE_Register(Vector.Flags, "foo bar", () => 0,
                Map("CaseConform", Vector.Conform))
            for Char in StrSplit(Vector.Typed)
                HSE_FeedChar(Char)
            Match := HSE_FeedChar(" ")
            if Vector.Shadow {
                AssertEqual("", Match, "case " . Index . ": an eligible longer star still reserves its prefix")
            } else {
                AssertTrue(IsObject(Match), "case " . Index . ": an impossible star must not silence the end trigger")
                AssertEqual("foo", Match.Trigger, "case " . Index . ": the valid end trigger wins")
            }
        } finally {
            HSE_TestReset()
        }
    }
}
Test("HSE star prefix checks word scope and conform case (star-prefix-eligibility)",
    TestHSE_StarPrefixRequiresEligibleContinuation)

TestHSE_StarPrefixEligibilitySurvivesGroupToggles() {
    HSE_TestReset()
    try {
        HSE_Register("?", "foo", () => 0)
        Restricted := HSE_Register("*", "foo bar", () => 0, Map("group", "restricted"))
        InWord := HSE_Register("*?", "foo baz", () => 0, Map("group", "inword"))
        AssertEqual("restricted", Restricted.Group, "the restricted candidate is in its own group")
        AssertEqual("inword", InWord.Group, "the in-word candidate is independently toggleable")
        for Enabled in [true, false, true] {
            if Enabled
                HSE_EnableGroup("inword")
            else
                HSE_DisableGroup("inword")
            HSE_FeedReset(true)
            for Char in StrSplit("xfoo")
                HSE_FeedChar(Char)
            Match := HSE_FeedChar(" ")
            AssertEqual(!Enabled, IsObject(Match),
                "any eligible continuation may suppress; a disabled or word-scoped one cannot")
            if IsObject(Match)
                AssertEqual("foo", Match.Trigger, "the end trigger remains live across index rebuilds")
        }
    } finally {
        HSE_TestReset()
    }
}
Test("HSE star prefix retains candidate eligibility across group toggles (star-prefix-eligibility)",
    TestHSE_StarPrefixEligibilitySurvivesGroupToggles)





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
