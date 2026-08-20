; tests/unit/test_preview_provider_at_triggers.ahk

; ==============================================================================
; MODULE: Regression — imperative and dynamic triggers use canonical decisions
;         (at-triggers-have-no-preview-candidate-source)
; DESCRIPTION:
; Typing @nptruc, @np or even @n expanded correctly and showed no tooltip at
; all. Not one tag of the family, not one combo, not the dates.
;
; ROOT CAUSE ENCODED: the preview originally knew only the file index, so every
; @ trigger registered imperatively at boot fired while the bubble stayed
; silent. A provider filled that hole but became a second matcher: it resolved
; personal state independently, could lose to a registered suffix, and could
; show a dynamic value different from the one dispatch resolved later. The
; collector now asks HSE_PreviewNextDecision directly. These tests therefore
; register through the production engine boundary, assert the exact FireDecision
; carried by each row, and prove the visible dynamic snapshot is consumed once.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ The fixture =======
; ==============================
; ==============================

; A known identity, so the expected previews can be written out in full. ASCII
; on purpose: the assertions compare character for character, and an accented
; literal here would be testing this file's encoding rather than the masking.
; @return The saved state, to be handed back to _PIPP_Teardown.
_PIPP_Setup() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RebuildInProgress, HSE_PersonalInfoCombosEnabled, HSE_RepeatEnabled
	global _PrefixIndex, _TriggerSet, _PrefixBuffer
	global PersonalInformation, PersonalInformationLetters
	InfoWasSet := IsSet(PersonalInformation)
	LettersWereSet := IsSet(PersonalInformationLetters)
	Saved := { Index:         _PrefixIndex,
	           Set:           _TriggerSet,
	           PrefixBuffer:  _PrefixBuffer,
	           Suppressed:    HSE_Suppressed,
	           Rebuild:       HSE_RebuildInProgress,
	           CombosEnabled: HSE_PersonalInfoCombosEnabled,
	           RepeatEnabled: HSE_RepeatEnabled,
	           InfoWasSet:    InfoWasSet,
	           Info:          InfoWasSet ? PersonalInformation : 0,
	           LettersWereSet: LettersWereSet,
	           Letters:       LettersWereSet ? PersonalInformationLetters : 0 }
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_RebuildInProgress := false
	HSE_PersonalInfoCombosEnabled := true
	HSE_RepeatEnabled := true
	HSE_FeedReset(true)
	_PrefixIndex := Map()
	_TriggerSet  := Map()
	PersonalInformation := Map(
		"first_name",   "Adrien",
		"last_name",    "Moreau",
		"iban",         "FR7630006000011234567890189",
		"phone_number", "+33 6 12 34 56 78")
	PersonalInformationLetters := Map(
		"i", "iban",
		"n", "last_name",
		"p", "first_name",
		"t", "phone_number")
	PersonalInfoMaskReset()
	return Saved
}

; @param Saved The value _PIPP_Setup returned.
_PIPP_Teardown(Saved) {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RebuildInProgress, HSE_PersonalInfoCombosEnabled, HSE_RepeatEnabled
	global _PrefixIndex, _TriggerSet, _PrefixBuffer
	global PersonalInformation, PersonalInformationLetters
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := Saved.Suppressed
	HSE_RebuildInProgress := Saved.Rebuild
	HSE_PersonalInfoCombosEnabled := Saved.CombosEnabled
	HSE_RepeatEnabled := Saved.RepeatEnabled
	_PrefixIndex  := Saved.Index
	_TriggerSet   := Saved.Set
	_PrefixBuffer := Saved.PrefixBuffer
	if Saved.InfoWasSet
		PersonalInformation := Saved.Info
	else
		PersonalInformation := unset
	if Saved.LettersWereSet
		PersonalInformationLetters := Saved.Letters
	else
		PersonalInformationLetters := unset
}

; The @ triggers exactly as modules/hotstrings registers them: CreateHotstring,
; the engine registry, nothing else.
_PIPP_RegisterAtTriggers() {
	global ScriptInformation, PersonalInformation
	MK := ScriptInformation["MagicKey"]
	CreateHotstring("*", "@n" . MK, PersonalInformation["last_name"],
		Map("FinalResult", True).Set("IsPrivate", True)
			.Set("PreviewFields", ["last_name"])
			.Set("PreviewValues", [PersonalInformation["last_name"]]))
	CreateHotstring("*", "@np" . MK, "Moreau{Tab}Adrien",
		Map("OnlyText", False).Set("FinalResult", True).Set("IsPrivate", True)
			.Set("PreviewFields", ["last_name", "first_name"])
			.Set("PreviewValues", ["Moreau", "Adrien"]))
	CreateHotstring("*", "@iban" . MK, PersonalInformation["iban"],
		Map("FinalResult", True).Set("IsPrivate", True)
			.Set("PreviewFields", ["iban"])
			.Set("PreviewValues", [PersonalInformation["iban"]]))
	CreateHotstring("*", "@t" . MK, PersonalInformation["phone_number"],
		Map("FinalResult", True).Set("IsPrivate", True)
			.Set("PreviewFields", ["phone_number"])
			.Set("PreviewValues", [PersonalInformation["phone_number"]]))
}

; The masked form of the fixture IBAN, spelled out from the shared policy rather
; than produced by the mask: head 2, tail 4, 27 characters, no separators.
_PIPP_MaskedIban() {
	Out := "FR"
	Loop 21 {
		Out .= Chr(0x2022)
	}
	return Out . "0189"
}

; The candidate naming a given trigger, or "". The collector returns the whole
; ranked set, and a test that indexed blindly into it would drift the day a
; second source answers for the same buffer.
_PIPP_CandidateFor(Candidates, Trigger) {
	for _, Candidate in Candidates {
		if (Candidate.Trigger == Trigger) {
			return Candidate
		}
	}
	return ""
}





; ============================================
; ============================================
; ======= 2/ The @ family is previewed =======
; ============================================
; ============================================

_PIPP_MultiLetterComboIsPreviewed() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@np"
		HSE_StartIsWordBoundary := true

		Candidates := _PrefixCollectCandidates()
		Assert(Candidates.Length >= 1,
			"@np must produce a preview candidate. The whole @ family is registered by CreateHotstring, which feeds only the engine registry, so it has no key in _PrefixIndex — every one of those triggers fired while the bubble stayed silent")
		Row := _PIPP_CandidateFor(Candidates, "@np" . MK)
		Assert(IsObject(Row), "the candidate must name the trigger the engine holds")
		AssertEqual("Moreau " . Chr(0x21E5) . " Adrien", Row.Output,
			"a multi-field combo previews its fields joined by the tab glyph. The registered replacement is a send string full of {Tab} escapes, so the row has to be rebuilt from the personal-info values rather than shown raw")
		Assert(Row.HasOwnProp("IsPrivate") and Row.IsPrivate,
			"a personal decision is private, so resolving the user's own data cannot leak it into the 14-day keylogger")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a multi-letter @ combo produces a preview candidate (at-triggers-have-no-preview-candidate-source)",
	_PIPP_MultiLetterComboIsPreviewed)


_PIPP_SingleLetterComboIsPreviewed() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@n"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@n" . MK)
		Assert(IsObject(Row),
			"@n — the shortest combo there is — must produce a candidate too. It is the case the maintainer named, and a fix that only covered long combos would leave it silent")
		AssertEqual("Moreau", Row.Output,
			"last_name is declared masked = false, so it is previewed exactly as it will be typed")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: the shortest @ combo produces a preview candidate (at-triggers-have-no-preview-candidate-source)",
	_PIPP_SingleLetterComboIsPreviewed)


; The tooltip must never promise an expansion that will not fire, and it must
; never withhold one that will. The boundary MOVED when the multi-letter combos
; stopped being pre-registered: this used to assert that @npn produced no row
; because only @n and @np were registered, and that was right while a
; hand-written list decided what existed. HSE_TryPersonalInfoCombo now resolves
; any @<letters>★ at fire time, so @npn fires — and a bubble that stayed silent
; would be the tooltip lying in the other direction.
;
; The INVARIANT is unchanged and is what these two tests assert: preview and fire
; answer the same question. So both are asked, of the same tag, in the same test.
_PIPP_ResolvableComboIsPreviewedAndFires() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@npn"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@npn" . MK)
		Assert(IsObject(Row),
			"@npn spells three valid letter aliases, so the fire-time resolver expands it — and a tag that expands must be previewed, or the bubble is silent about an expansion the magic key will deliver")

		; The other half: the same tag, asked of the engine.
		HSE_Buffer := "@npn" . MK
		Assert(IsObject(HSE_TryPersonalInfoCombo(MK)),
			"and the engine must actually hold it — if this fails, the bubble above is promising an expansion that will not fire, which is the thing this test has always existed to forbid")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a resolvable @ combo is both previewed and fired (at-triggers-have-no-preview-candidate-source)",
	_PIPP_ResolvableComboIsPreviewedAndFires)


; The forbidding half for the personal resolver. "z" aliases no field, so the
; @ expansion must not be advertised. The canonical engine still owns its next
; fallback: because z is mid-word, repeat legitimately wins and must be shown.
_PIPP_UnresolvableComboYieldsToRepeat() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@npz"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		Assert(!IsObject(_PIPP_CandidateFor(Rows, "@npz" . MK)),
			"'z' aliases no personal_info field, so the tooltip must not invent an @npz expansion")
		AssertEqual(1, Rows.Length,
			"the declined personal resolver must yield to the one canonical fallback")
		AssertEqual("z" . MK, Rows[1].Trigger,
			"the actual repeat fallback must remain visible instead of being hidden by the failed @ resolver")

		HSE_Buffer := "@npz" . MK
		Assert(!IsObject(HSE_TryPersonalInfoCombo(MK)),
			"the personal resolver must decline the same invalid tag")
		Assert(IsObject(HSE_TryRepeatKey(MK)),
			"sanity: the repeat fallback shown above must be fireable on the same completed buffer")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: an unresolvable @ combo yields visibly to repeat (at-triggers-have-no-preview-candidate-source)",
	_PIPP_UnresolvableComboYieldsToRepeat)


; A registered personal Spec is an immutable snapshot until the terminal Reload
; replaces the process. The editor publishes the new PersonalInformation Map
; before that Reload and can hold a confirmation MsgBox open in between, so a
; preview path that re-reads the Map advertises the new value while the engine
; still owns and emits the old one
_PIPP_RegisteredSpecSnapshotSurvivesPublishedMapChange() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, PersonalInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		PersonalInformation["last_name"] := "Nouveau"
		HSE_Buffer := "@n"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@n" . MK)
		Assert(IsObject(Row), "the registered @n trigger must still produce a row during the save-to-Reload transition")
		Winner := HSE_FeedChar(MK, true)
		Assert(IsObject(Winner), "the engine must still own the registered pre-Reload Spec")
		AssertEqual("Moreau", Winner.Replacement,
			"the registered Spec must retain the old value until Reload replaces the process")
		AssertEqual(Winner.Replacement, Row.Output,
			"the tooltip must render the registered Spec’s value snapshot, not the newly published PersonalInformation Map")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a personal preview renders the registered value snapshot during save-to-Reload",
	_PIPP_RegisteredSpecSnapshotSurvivesPublishedMapChange)


; The resolver declines a combo whole when any field is blank, because emitting
; the remaining fields would shift values into the wrong form controls. The
; canonical preview must not assemble a partial row and must surface the repeat
; fallback that really wins next.
_PIPP_BlankFieldComboYieldsToRepeat() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, PersonalInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		PersonalInformation["first_name"] := ""
		HSE_Buffer := "@npn"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		Assert(!IsObject(_PIPP_CandidateFor(Rows, "@npn" . MK)),
			"@npn contains a blank first_name field, so the tooltip must not promise a partial personal expansion")
		AssertEqual(1, Rows.Length,
			"declining the personal combo must not hide the canonical repeat fallback")
		AssertEqual("n" . MK, Rows[1].Trigger,
			"the visible row must describe the repeat the engine will actually fire")
		HSE_Buffer := "@npn" . MK
		Assert(!IsObject(HSE_TryPersonalInfoCombo(MK)),
			"the engine declines the same combo whole; preview and fire must agree on the blank-field gate")
		Assert(IsObject(HSE_TryRepeatKey(MK)),
			"sanity: the shown repeat fallback must fire after the personal gate declines")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a personal combo containing a blank field yields visibly to repeat",
	_PIPP_BlankFieldComboYieldsToRepeat)


; Registered matching runs before the personal fallback. A shorter registered
; suffix can therefore own the magic-key press even though the visible buffer
; also spells a longer, resolvable @ combo
_PIPP_RegisteredSuffixWinnerSuppressesPersonalFallbackRow() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		CreateHotstring("*?", "np" . MK, "registered suffix")
		HSE_Buffer := "@np"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"the collector must expose the registered suffix selected before the personal fallback")
		AssertEqual("np" . MK, Rows[1].Trigger,
			"the visible row must name the real registered winner, never the longer-looking @ fallback")
		AssertEqual("registered suffix", Rows[1].Output,
			"the visible output must come from the registered winner's canonical decision")
		Winner := HSE_FeedChar(MK, true)
		Assert(IsObject(Winner), "the registered suffix must produce an engine winner")
		AssertEqual("np" . MK, Winner.Trigger,
			"the actual engine ordering is registered matcher first, personal fallback second")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a registered suffix winner suppresses a conflicting personal fallback preview",
	_PIPP_RegisteredSuffixWinnerSuppressesPersonalFallbackRow)


; The live-rebuild fence means the registry cannot answer, not that no registered
; trigger exists. Both registered matches and fallbacks deliberately decline
; until the new registry generation is fully published
_PIPP_RebuildFenceHidesPersonalDecisions() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RebuildInProgress, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@n"
		HSE_StartIsWordBoundary := true
		HSE_RebuildInProgress := true

		AssertEqual(0, _PrefixCollectCandidates().Length,
			"the collector must offer no row while the engine's live-rebuild fence refuses every match")
		Assert(!IsObject(HSE_FeedChar(MK, true)),
			"the real matcher must decline the same key during the rebuild window")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: the live-rebuild fence hides personal decisions",
	_PIPP_RebuildFenceHidesPersonalDecisions)


; @dt spells two valid letter aliases (d, t) AND is the short-date trigger. Only
; the engine's Spec knows which one it will fire, which is why the rendering
; branch is chosen from the Spec's replacement and never from the tag.
_PIPP_DateTriggerPreviewsItsDate() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, PersonalInformationLetters
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		PersonalInformationLetters["d"] := "first_name"
		_PIPP_RegisterAtTriggers()
		CreateHotstring("*?", "@dt" . MK, _DateShortFr, Map("FinalResult", True))
		HSE_Buffer := "@dt"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@dt" . MK)
		Assert(IsObject(Row), "@dt must produce a candidate — it is an @ trigger like the others")
		AssertEqual(FormatTime(, "dd/MM/yyyy"), Row.Output,
			"@dt is the short-date trigger, and its letters ALSO resolve as personal-info aliases. Reading the tag instead of the engine's Spec would preview a first name and a phone number for a trigger that types today's date")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: an @ date trigger previews the date the engine will type (at-triggers-have-no-preview-candidate-source)",
	_PIPP_DateTriggerPreviewsItsDate)


; The catalogue is allowed to be stale during a registry publication, but it is
; no longer allowed to answer the user-facing question at all.
_PIPP_StaleIndexNeverShadowsCanonicalPersonalDecision() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		_AddTriggerToIndex("@np" . MK, "the indexed replacement", "personal", "custom", 50)
		HSE_Buffer := "@np"
		HSE_StartIsWordBoundary := true

		Candidates := _PrefixCollectCandidates()
		Matches := 0
		for _, Candidate in Candidates {
			if (Candidate.Trigger == "@np" . MK) {
				Matches += 1
			}
		}
		AssertEqual(1, Matches,
			"one completion must produce one canonical row even when the catalogue holds the same trigger")
		Row := _PIPP_CandidateFor(Candidates, "@np" . MK)
		AssertEqual("Moreau " . Chr(0x21E5) . " Adrien", Row.Output,
			"a stale indexed replacement must never shadow the value owned by the live personal Spec")
		Assert(Row.HasOwnProp("FireDecision") and IsObject(Row.FireDecision.Spec),
			"the surviving row must be backed by a complete engine decision, not index metadata")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a stale index never shadows the canonical personal decision (at-triggers-have-no-preview-candidate-source)",
	_PIPP_StaleIndexNeverShadowsCanonicalPersonalDecision)


; The auxiliary catalogue is rebuilt from files and swapped wholesale. An
; imperative secret must not be injected into that separate lifecycle: it would
; disappear at the next rebuild and, in `_TriggerSet`, enter persisted near-miss
; analytics with its trigger and raw output.
_PIPP_TheIndexStaysFileDriven() {
	global _PrefixIndex, _TriggerSet
	Saved := _PIPP_Setup()
	try {
		_PIPP_RegisterAtTriggers()
		AssertEqual(0, _PrefixIndex.Count,
			"registering an @ trigger must not write to the file-derived auxiliary index")
		AssertEqual(0, _TriggerSet.Count,
			"nor to the near-miss trigger set, which forwards Entry.Output to the analytics log — that would write the raw IBAN, SSN and card number into it")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: an @ registration writes to neither auxiliary catalogue (at-triggers-have-no-preview-candidate-source)",
	_PIPP_TheIndexStaysFileDriven)





; ==================================================
; ==================================================
; ======= 3/ Masked on screen, typed in full =======
; ==================================================
; ==================================================

_PIPP_SecretIsMaskedInThePreview() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@iban"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@iban" . MK)
		Assert(IsObject(Row), "@iban must produce a candidate")
		AssertEqual(_PIPP_MaskedIban(), Row.Output,
			"an IBAN is a declared secret, so the bubble shows the first two and the last four characters. The tooltip exists so the user can confirm WHICH of their values is about to be typed, and the tail is what identifies an account")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a declared secret is masked in the preview row (preview-masking-cross-driver)",
	_PIPP_SecretIsMaskedInThePreview)


_PIPP_PublicFieldIsShownInFull() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@t"
		HSE_StartIsWordBoundary := true

		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@t" . MK)
		Assert(IsObject(Row), "@t must produce a candidate")
		AssertEqual("+33 6 12 34 56 78", Row.Output,
			"the phone number is declared masked = false by the maintainer's decision: it is read aloud, printed on cards and given to strangers, and hiding it in the user's own preview costs confirmation and buys nothing")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a field declared public is previewed in full (preview-masking-cross-driver)",
	_PIPP_PublicFieldIsShownInFull)


; The boundary the masking must never cross. Typing bullets into a bank form is
; silent, corrupts real data and looks exactly like the feature working.
_PIPP_TheTypedValueIsComplete() {
	global HSE_Buffer, HSE_StartIsWordBoundary, ScriptInformation, PersonalInformation
	Saved := _PIPP_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_PIPP_RegisterAtTriggers()
		Iban := PersonalInformation["iban"]

		; The preview row first, so the mask has definitely run before the engine
		; is asked what it will type.
		HSE_Buffer := "@iban"
		HSE_StartIsWordBoundary := true
		Row := _PIPP_CandidateFor(_PrefixCollectCandidates(), "@iban" . MK)
		Assert(IsObject(Row), "sanity: the masked row must exist for this comparison to mean anything")
		Assert(Row.Output !== Iban, "sanity: the row must actually be masked")

		HSE_Buffer := "@iban"
		Winner := HSE_FeedChar(MK)
		Assert(IsObject(Winner), "sanity: the engine must match @iban plus the magic key")
		AssertEqual(Iban, Winner.Replacement,
			"the expansion must still carry the COMPLETE value. Masking is a display transform on a separate string; if it ever reached the replacement the driver would quietly type bullets into a bank form")
		AssertEqual("FR7630006000011234567890189", PersonalInformation["iban"],
			"and the personal-info value itself must be untouched — the mask must never write back into the map it read from")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: masking the preview leaves the typed expansion complete (preview-masking-cross-driver)",
	_PIPP_TheTypedValueIsComplete)





; ==========================================
; ==========================================
; ======= 4/ Privacy at the log sink =======
; ==========================================
; ==========================================

; The preview's telemetry writes the trigger AND the replacement to the 14-day
; keylogger on every suggestion. Landing the @ preview without this would put the
; phone, IBAN, SSN and card number in there on every preview keystroke — a
; regression against the already-shipped log-redaction contract that no existing
; test would have caught, because nothing previewable reached that sink before.
_PIPP_PrivateSuggestionIsWithheldWhole() {
	global _Stub_HotstringSuggestedCalls, _Stub_HotstringDismissedCalls, _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	_KLLastShownSuggestion := ""
	_Stub_HotstringSuggestedCalls := []
	_Stub_HotstringDismissedCalls := []
	try {
		_NotifySuggestionShown("@iban" . Chr(0x2605), "FR7630006000011234567890189", "personal", true)
		AssertEqual(0, _Stub_HotstringSuggestedCalls.Length,
			"a private mapping is withheld WHOLE. Both columns are secrets — the replacement IS the IBAN and the trigger is a fragment of it — so redacting one and keeping the other still leaks")
		_NotifySuggestionDismissed()
		AssertEqual(0, _Stub_HotstringDismissedCalls.Length,
			"and its dismissal is withheld too, or the value reaches the log by the back door")
	} finally {
		_KLLastShownSuggestion := Prev
	}
}
Test("hotstrings: a private preview row is never persisted to the keylogger (at-triggers-have-no-preview-candidate-source)",
	_PIPP_PrivateSuggestionIsWithheldWhole)


; The other half: an ordinary suggestion must still be recorded, or the guard
; above would be satisfied by telemetry that had stopped working altogether.
_PIPP_OrdinarySuggestionIsStillPersisted() {
	global _Stub_HotstringSuggestedCalls, _Stub_HotstringDismissedCalls, _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	_KLLastShownSuggestion := ""
	_Stub_HotstringSuggestedCalls := []
	_Stub_HotstringDismissedCalls := []
	try {
		_NotifySuggestionShown("ct" . Chr(0x2605), "c'etait", "magickey")
		AssertEqual(1, _Stub_HotstringSuggestedCalls.Length,
			"an ordinary suggestion is still logged — the privacy guard must narrow the sink, not close it")
		_NotifySuggestionDismissed()
		AssertEqual(1, _Stub_HotstringDismissedCalls.Length,
			"and it is still paired with exactly one dismissal")
	} finally {
		_KLLastShownSuggestion := Prev
	}
}
Test("hotstrings: an ordinary preview row is still persisted (at-triggers-have-no-preview-candidate-source)",
	_PIPP_OrdinarySuggestionIsStillPersisted)


; A private row replacing a public one must still close the public one out, or
; the log grows a suggestion that is never dismissed.
_PIPP_PrivateRowStillClosesThePublicOne() {
	global _Stub_HotstringSuggestedCalls, _Stub_HotstringDismissedCalls, _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	_KLLastShownSuggestion := ""
	_Stub_HotstringSuggestedCalls := []
	_Stub_HotstringDismissedCalls := []
	try {
		_NotifySuggestionShown("ct" . Chr(0x2605), "c'etait", "magickey")
		_NotifySuggestionShown("@iban" . Chr(0x2605), "FR7630006000011234567890189", "personal", true)
		AssertEqual(1, _Stub_HotstringDismissedCalls.Length,
			"the public suggestion the private one replaced must still be dismissed — the state machine runs for both, only the write is withheld")
		AssertEqual(1, _Stub_HotstringSuggestedCalls.Length,
			"and no second suggestion is written")
	} finally {
		_KLLastShownSuggestion := Prev
	}
}
Test("hotstrings: a private row still closes out the suggestion it replaced (at-triggers-have-no-preview-candidate-source)",
	_PIPP_PrivateRowStillClosesThePublicOne)





; =======================================================================
; =======================================================================
; ======= 5/ A visible dynamic value is one immutable transaction =======
; =======================================================================
; =======================================================================

global _PIPP_DynamicResolutionCalls := 0

_PIPP_NextDynamicValue() {
	global _PIPP_DynamicResolutionCalls
	_PIPP_DynamicResolutionCalls += 1
	return "shown-" . _PIPP_DynamicResolutionCalls
}

_PIPP_VisibleDynamicDecisionImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_LastEndChar, HSE_Suppressed
	global HSE_SUPPRESS_RELEASE_DELAY_MS
	global _PIPP_DynamicResolutionCalls, _AHK04_SendCalls, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	HotstringPrefixWatcherClearVisibleDecisions()
	_AHK04_SetSendVerdict(true)
	try {
		_PIPP_DynamicResolutionCalls := 0
		Spec := HSE_Register("*?", "dyn" . MK, 0,
			Map("Replacement", _PIPP_NextDynamicValue, "OnlyText", true,
				"Category", "dynamichotstrings", "Section", "visible"))
		HSE_Buffer := "dyn"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"the dynamic star trigger must produce one canonical preview row")
		Row := Rows[1]
		AssertEqual("shown-1", Row.Output,
			"the first callable result is the value committed to pixels")
		AssertEqual(1, _PIPP_DynamicResolutionCalls,
			"building one preview decision must resolve the callable exactly once")
		Assert(ObjPtr(Row.FireDecision.Spec) == ObjPtr(Spec),
			"the visible decision must retain the exact registered Spec")
		Assert(HotstringPrefixWatcherPublishVisibleDecisions([Row]),
			"a current decision must publish as the owner of the visible row")

		Winner := HSE_FeedChar(MK, true)
		Assert(IsObject(Winner) and ObjPtr(Winner) == ObjPtr(Spec),
			"the physical completion must select the same Spec the row advertised")
		Effect := 0
		Assert(HSE_DispatchMatch(Winner, HSE_LastEndChar, &Effect),
			"dispatch must commit the visible dynamic decision")
		AssertEqual(1, _PIPP_DynamicResolutionCalls,
			"dispatch must reuse the visible ResolvedBase instead of invoking the callable again")
		AssertEqual(1, _AHK04_SendCalls.Length,
			"the expansion must be emitted as one atomic send burst")
		Burst := _AHK04_SendCalls[1].Args[1]
		Assert(InStr(Burst, "shown-1") > 0 and InStr(Burst, "shown-2") == 0,
			"the emitted burst must contain exactly the value the tooltip displayed")
		Assert(IsObject(Effect) and Effect.InsertedText == "shown-1",
			"the canonical screen effect must commit the same frozen value")

		; Once the visible owner is invalidated, a new user-visible decision is a
		; new transaction and may legitimately resolve dynamic state again.
		; Let the real deferred suppression release run first; forcing the counters
		; down by hand would leave its already-armed timer to underflow later.
		PreviousCritical := Critical("Off")
		Sleep(HSE_SUPPRESS_RELEASE_DELAY_MS + 20)
		Critical(PreviousCritical ? PreviousCritical : "Off")
		HotstringPrefixWatcherClearVisibleDecisions()
		HSE_Buffer := "dyn"
		HSE_StartIsWordBoundary := true
		NextRows := _PrefixCollectCandidates()
		AssertEqual(1, NextRows.Length,
			"the trigger must remain previewable after invalidating the prior visible owner")
		AssertEqual("shown-2", NextRows[1].Output,
			"a new decision after invalidation must resolve the callable again")
		AssertEqual(2, _PIPP_DynamicResolutionCalls,
			"one old decision plus one new decision must produce exactly two resolutions")
	} finally {
		HotstringPrefixWatcherClearVisibleDecisions()
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

_PIPP_VisibleDynamicDecisionIsReusedByDispatch() {
	; Reuse the send-transaction harness that already owns suppression timers,
	; synthetic-keylogger state and the dry-run sender. A local ad-hoc stub would
	; let those asynchronous releases leak into the next shared-suite test.
	_AHK04_RunIsolated(_PIPP_VisibleDynamicDecisionImpl)
}
Test("hotstrings: dispatch reuses the visible dynamic value and a new decision resolves again",
	_PIPP_VisibleDynamicDecisionIsReusedByDispatch)
