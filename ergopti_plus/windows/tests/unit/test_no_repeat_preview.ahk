; tests/unit/test_no_repeat_preview.ahk

; ==============================================================================
; MODULE: Regression — the bubble never offers a key doubling (no-repeat-preview)
; DESCRIPTION:
; Maintainer report: « le tooltip me propose hotstring pour doublement de
; touche ». With the repeat key on, typing "ef" put "ff" in the bubble, and so
; did almost every other letter that is not the first of its word.
;
; ROOT CAUSE ENCODED: HSE_PreviewNextDecision is the truthful oracle for what
; the magic key fires, and it includes the repeat fallback (HSE_TryRepeatKey) so
; that no lower candidate can be advertised in its place. _PrefixCollectCandidates
; published every decision that oracle returned, the doubling included.
;
; WHAT COUNTS AS A DOUBLING: a decision whose Spec carries IsRepeat, the
; engine's own marker, set by the transient fallback and by any Spec registered
; with that option. No bundled TOML entry doubles its trigger's last character
; (repeat_corrections maps ccê to ccu and guards arrê), so the data carries no
; doubling for a flag of its own to mark.
;
; Both halves are asserted: a doubling is withheld while the engine still fires
; it, and every other row, ordinary magic-key expansions included, is offered.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ The fixture =======
; ==============================
; ==============================

; Isolates the engine state these cases drive: the repeat key on, the personal
; resolver off, so the magic key's only fallback is the doubling.
; @return The saved state, to be handed back to _NRP_Teardown.
_NRP_Setup() {
	global HSE_Suppressed, HSE_RebuildInProgress, HSE_RepeatEnabled
	global HSE_PersonalInfoCombosEnabled
	Saved := { Suppressed:    HSE_Suppressed,
	           Rebuild:       HSE_RebuildInProgress,
	           RepeatEnabled: HSE_RepeatEnabled,
	           CombosEnabled: HSE_PersonalInfoCombosEnabled }
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_RebuildInProgress := false
	HSE_RepeatEnabled := true
	HSE_PersonalInfoCombosEnabled := false
	HSE_FeedReset(true)
	return Saved
}

; @param Saved The value _NRP_Setup returned.
_NRP_Teardown(Saved) {
	global HSE_Suppressed, HSE_RebuildInProgress, HSE_RepeatEnabled
	global HSE_PersonalInfoCombosEnabled
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := Saved.Suppressed
	HSE_RebuildInProgress := Saved.Rebuild
	HSE_RepeatEnabled := Saved.RepeatEnabled
	HSE_PersonalInfoCombosEnabled := Saved.CombosEnabled
}

; @param Decision A value returned by HSE_PreviewNextDecision.
; @return {Boolean} Whether the engine's answer is a doubling.
_NRP_IsDoubling(Decision) {
	return (IsObject(Decision) and Decision.Spec.HasOwnProp("IsRepeat")
		and Decision.Spec.IsRepeat) ? true : false
}





; ==============================================
; ==============================================
; ======= 2/ A doubling is never offered =======
; ==============================================
; ==============================================

; The reported case. Nothing is registered, so the magic key after "ef" can only
; double the "f", and the bubble used to say so on every such keystroke.
_NRP_RepeatFallbackIsNeverOffered() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _NRP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		HSE_Buffer := "ef"
		HSE_StartIsWordBoundary := true

		Decision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		Assert(_NRP_IsDoubling(Decision),
			"sanity: the magic key after 'ef' must be the engine's doubling, or this case proves nothing")
		AssertEqual("ff", Decision.Spec.Replacement,
			"sanity: the doubling repeats the letter before the magic key")
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"the bubble must never propose a key doubling: one is available after almost every letter, so its row sat on nearly every keystroke")

		; Withholding the promise must not withdraw the expansion. _OnPrefixChar
		; makes exactly this call when the magic key arrives.
		HSE_Buffer := "ef" . MK
		Fired := HSE_TryRepeatKey(MK)
		Assert(IsObject(Fired) and Fired.IsRepeat,
			"the magic key must still double the letter once it is typed")
		AssertEqual("ff", Fired.Replacement,
			"the unannounced doubling must still type the repeated letter")
	} finally {
		_NRP_Teardown(Saved)
	}
}
Test("hotstrings: the bubble never proposes the repeat key's doubling (no-repeat-preview)",
	_NRP_RepeatFallbackIsNeverOffered)

; The class, not the instance: a doubling registered with the IsRepeat option is
; the same noise as the fallback, so the exclusion must key on the marker rather
; than on the fallback's transient kind.
_NRP_RegisteredDoublingIsNeverOffered() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, HSE_PRIORITY_COMMON
	Saved := _NRP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		CreateHotstring("*?", "z" . MK, "zz",
			Map("IsRepeat", true, "Priority", HSE_PRIORITY_COMMON,
				"Category", "test", "Section", "doubling"))
		HSE_Buffer := "az"
		HSE_StartIsWordBoundary := true

		Decision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		Assert(_NRP_IsDoubling(Decision)
			and !Decision.Spec.HasOwnProp("TransientKind"),
			"sanity: the registered doubling, not the engine fallback, must be the magic key's winner here")
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a registered doubling must be withheld exactly like the fallback")
	} finally {
		_NRP_Teardown(Saved)
	}
}
Test("hotstrings: a registered doubling is never proposed either (no-repeat-preview)",
	_NRP_RegisteredDoublingIsNeverOffered)





; ===================================================
; ===================================================
; ======= 3/ Every other row is still offered =======
; ===================================================
; ===================================================

; The permitted half on a text_expansion_symbols entry from magickey.toml,
; "(v)★" = "✓" (is_word, auto_expand, strict case), registered through the TOML
; loader's own entry point. No activation delay, so key timing plays no part.
_NRP_OrdinaryMagicExpansionIsOffered() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, HSE_PRIORITY_COMMON
	Saved := _NRP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		HSE_RegisterFromTomlFlags(true, "*C", "(v)" . MK, Chr(0x2713),
			Map("TimeActivationSeconds", 0, "FinalResult", false,
				"Category", "magickey", "Section", "text_expansion_symbols",
				"Priority", HSE_PRIORITY_COMMON))
		HSE_Buffer := "(v)"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"an ordinary magic-key expansion must still be offered: only doublings are withheld")
		AssertEqual("(v)" . MK, Rows[1].Trigger,
			"the row must name the magic-key trigger the engine will fire")
		AssertEqual(Chr(0x2713), Rows[1].Output,
			"the row must show the symbol the magic key will type")
	} finally {
		_NRP_Teardown(Saved)
	}
}
Test("hotstrings: an ordinary magic-key expansion is still proposed (no-repeat-preview)",
	_NRP_OrdinaryMagicExpansionIsOffered)

; Withholding one completion must leave the other untouched: on "ef" the end
; character fires a registered correction while the magic key would double.
_NRP_EndCharRowSurvivesBesideDoubling() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _NRP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		HSE_Register("", "ef", 0,
			Map("Replacement", "EF", "OnlyText", true, "Category", "test", "Section", "endchar"))
		HSE_Buffer := "ef"
		HSE_StartIsWordBoundary := true

		Assert(_NRP_IsDoubling(HSE_PreviewNextDecision(HSE_Buffer, MK)),
			"sanity: the magic key must still be answered by the doubling beside the end-character row")
		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"only the doubling may be withheld; the end-character row must stay")
		AssertEqual("EF", Rows[1].Output,
			"the surviving row must be the end-character correction")
	} finally {
		_NRP_Teardown(Saved)
	}
}
Test("hotstrings: the end-character row survives beside a withheld doubling (no-repeat-preview)",
	_NRP_EndCharRowSurvivesBesideDoubling)

/** Exercise the real repeat owner using literal complete-scalar expectations. */
_NRP_UnicodeRepeat(Buffer, Expected, KnownStart := true, Magic := "★") {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS
	Saved := _NRP_Setup()
	SavedTerminators := HSE_WORD_TERMINATORS
	try {
		HSE_WORD_TERMINATORS := SavedTerminators . Chr(0x1F600)
		HSE_Buffer := Buffer . Magic
		HSE_StartIsWordBoundary := KnownStart
		Spec := HSE_TryRepeatKey(Magic)
		if Expected == "" {
			AssertEqual("", Spec, "no confirmed second character means no repeat")
			return
		}
		AssertTrue(IsObject(Spec), "a complete non-boundary predecessor permits the real fallback")
		AssertEqual(Expected, Spec.Replacement, "repeat exactly the complete preceding scalar")
		AssertEqual(SubStr(Expected, 1, StrLen(Expected) // 2) . Magic, Spec.Trigger,
			"the transient trigger must erase the complete original suffix")
		AssertEqual(StrLen(Spec.Trigger), Spec.Length, "internal match spans remain UTF16 units")
	} finally {
		HSE_WORD_TERMINATORS := SavedTerminators
		_NRP_Teardown(Saved)
	}
}
Test("repeat unicode-boundary-owner: supplementary scalar at word start never doubles", (*) =>
	_NRP_UnicodeRepeat(Chr(0x1F601), ""))
Test("repeat unicode-boundary-owner: supplementary non-delimiter repeats completely", (*) =>
	_NRP_UnicodeRepeat("a" . Chr(0x1F601), Chr(0x1F601) . Chr(0x1F601)))
Test("repeat unicode-boundary-owner: actual supplementary delimiter refuses the first letter", (*) =>
	_NRP_UnicodeRepeat(Chr(0x1F600) . "a", ""))
Test("repeat unicode-boundary-owner: sharing only the delimiter low surrogate permits doubling", (*) =>
	_NRP_UnicodeRepeat(Chr(0x1FA00) . "a", "aa"))
Test("repeat unicode-boundary-owner: supplementary first predecessor retains unknown-start refusal", (*) =>
	_NRP_UnicodeRepeat(Chr(0x1F601) . "a", "", false))
Test("repeat unicode-boundary-owner: known supplementary predecessor allows doubling", (*) =>
	_NRP_UnicodeRepeat(Chr(0x1FA00) . "a", "aa", true))
Test("repeat unicode-boundary-owner: supplementary magic key keeps the complete trigger span", (*) =>
	_NRP_UnicodeRepeat("ab", "bb", true, Chr(0x1F601)))


/** Check the shared STAR/END and repeat boundary owner without dispatching output. */
_NRP_UnicodeBoundary(Prefix, Repeating, Expected, KnownStart := true) {
	global HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS
	SavedStart := HSE_StartIsWordBoundary
	SavedTerminators := HSE_WORD_TERMINATORS
	try {
		HSE_StartIsWordBoundary := KnownStart
		HSE_WORD_TERMINATORS := SavedTerminators . Chr(0x1F600)
		Spec := { Length: 3, InWord: Repeating, IsRepeat: Repeating }
		AssertEqual(Expected, _HSE_WordBoundaryAllows(Prefix . "the", Spec),
			"boundary admission compares a complete preceding character")
	} finally {
		HSE_StartIsWordBoundary := SavedStart
		HSE_WORD_TERMINATORS := SavedTerminators
	}
}
Test("boundary unicode-boundary-owner: a shared low surrogate cannot license a word", (*) =>
	_NRP_UnicodeBoundary(Chr(0x1FA00), false, false))
Test("boundary unicode-boundary-owner: an actual supplementary delimiter licenses a word", (*) =>
	_NRP_UnicodeBoundary(Chr(0x1F600), false, true))
Test("boundary unicode-boundary-owner: a shared low surrogate cannot refuse a repeat", (*) =>
	_NRP_UnicodeBoundary(Chr(0x1FA00), true, true))
Test("boundary unicode-boundary-owner: an actual supplementary delimiter refuses a repeat", (*) =>
	_NRP_UnicodeBoundary(Chr(0x1F600), true, false))
Test("boundary unicode-boundary-owner: empty predecessor retains known-start admission", (*) =>
	_NRP_UnicodeBoundary("", false, true))
Test("boundary unicode-boundary-owner: empty predecessor retains unknown-start refusal", (*) =>
	_NRP_UnicodeBoundary("", false, false, false))
Test("boundary unicode-boundary-owner: ordinary punctuation retains word admission", (*) =>
	_NRP_UnicodeBoundary(".", false, true))
Test("repeat unicode-boundary-owner: an unpaired low surrogate retains unit semantics", (*) =>
	_NRP_UnicodeRepeat("a" . Chr(0xDC01), Chr(0xDC01) . Chr(0xDC01)))
Test("repeat unicode-boundary-owner: an unpaired high surrogate retains unit semantics", (*) =>
	_NRP_UnicodeRepeat("a" . Chr(0xD801), Chr(0xD801) . Chr(0xD801)))
