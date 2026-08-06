; tests/unit/test_preview_provider_at_triggers.ahk

; ==============================================================================
; MODULE: Regression — no trigger starting with "@" ever produced a preview
;         (at-triggers-have-no-preview-candidate-source)
; DESCRIPTION:
; Typing @nptruc, @np or even @n expanded correctly and showed no tooltip at
; all. Not one tag of the family, not one combo, not the dates.
;
; ROOT CAUSE ENCODED: the preview's candidate set came from _PrefixIndex and
; from nowhere else, and _PrefixIndex is written by _AddTriggerToIndex whose
; only three callers are file-driven — the bundled category TOMLs, their
; in-memory cache and the extension packs. Every @ trigger is created
; imperatively at boot by CreateHotstring, which ends at the ENGINE registry and
; never touches the preview index, and no bundled TOML holds a trigger starting
; with "@". So no key beginning with "@" could exist in that index,
; _PrefixCollectCandidates returned an empty array for any @ buffer, and
; _LookupAndRender hid the tooltip. The defect was a MISSING CANDIDATE SOURCE,
; not a filter, a buffer reset or a toggle — which is why every assertion below
; registers its triggers through CreateHotstring exactly as production does, and
; asks the collector rather than the index.
;
; The cure is a provider consulted alongside the index. Inserting the @ triggers
; INTO the index would work until the next HotstringPrefixWatcherRebuildIndex —
; a live section toggle, a personal save, the boot-tail warm-up — which builds a
; fresh Map and swaps it in; the bug would then return intermittently and look
; like a race, so the tests below also pin that the index is left alone.
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
	global HSE_Suppressed
	global _PrefixIndex, _TriggerSet, _PrefixBuffer
	global PersonalInformation, PersonalInformationLetters
	Saved := { Index: _PrefixIndex, Set: _TriggerSet, Buffer: _PrefixBuffer }
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
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
	global _PrefixIndex, _TriggerSet, _PrefixBuffer
	HSE_RegistryClear()
	HSE_HardReset()
	_PrefixIndex  := Saved.Index
	_TriggerSet   := Saved.Set
	_PrefixBuffer := Saved.Buffer
}

; The @ triggers exactly as modules/hotstrings registers them: CreateHotstring,
; the engine registry, nothing else.
_PIPP_RegisterAtTriggers() {
	global ScriptInformation, PersonalInformation
	MK := ScriptInformation["MagicKey"]
	CreateHotstring("*", "@n" . MK, PersonalInformation["last_name"], Map("FinalResult", True))
	CreateHotstring("*", "@np" . MK, "Moreau{Tab}Adrien{Tab}", Map("FinalResult", True))
	CreateHotstring("*", "@iban" . MK, PersonalInformation["iban"], Map("FinalResult", True))
	CreateHotstring("*", "@t" . MK, PersonalInformation["phone_number"], Map("FinalResult", True))
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
			"a provider row is private: the collector stamps every one of them, so a source that resolves the user's own data cannot leak it into the 14-day keylogger by forgetting to say so")
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


; The tooltip must never promise an expansion that will not fire. A combo
; resolves letter by letter, so @npn spells three known aliases while only @n
; and @np are registered — the engine is the authority on what exists.
_PIPP_UnregisteredComboIsNotPreviewed() {
	global HSE_Buffer, HSE_StartIsWordBoundary
	Saved := _PIPP_Setup()
	try {
		_PIPP_RegisterAtTriggers()
		HSE_Buffer := "@npn"
		HSE_StartIsWordBoundary := true

		AssertEqual(0, _PrefixCollectCandidates().Length,
			"@npn spells three valid letter aliases but is not a registered trigger, so it must produce no row. A tooltip offering an expansion the magic key will not deliver is worse than no tooltip")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: an @ combo the engine does not hold is not previewed (at-triggers-have-no-preview-candidate-source)",
	_PIPP_UnregisteredComboIsNotPreviewed)


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


; A provider must never shadow a trigger the index already answered for: the
; index row carries the real category, section and priority of the mapping that
; will fire, and two rows for one trigger would show the same expansion twice.
_PIPP_ProviderNeverShadowsTheIndex() {
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
			"one trigger, one row: a provider row for a trigger the index already holds must be dropped")
		AssertEqual("the indexed replacement", _PIPP_CandidateFor(Candidates, "@np" . MK).Output,
			"and the surviving row must be the INDEX one, which carries the real category, section and priority of the mapping the engine will fire")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: a preview provider never shadows an indexed trigger (at-triggers-have-no-preview-candidate-source)",
	_PIPP_ProviderNeverShadowsTheIndex)


; The index is rebuilt from scratch by HotstringPrefixWatcherRebuildIndex, which
; swaps a fresh Map in. Anything written to it outside that loop is erased on the
; first live section toggle, personal save or warm-up rebuild — so the fix must
; not have taken that route, and this says so.
_PIPP_TheIndexStaysFileDriven() {
	global _PrefixIndex, _TriggerSet
	Saved := _PIPP_Setup()
	try {
		_PIPP_RegisterAtTriggers()
		AssertEqual(0, _PrefixIndex.Count,
			"registering an @ trigger must not write to the preview index: the index is rebuilt from files and swapped wholesale, so an entry inserted here disappears at the next rebuild and the bug returns looking like a race")
		AssertEqual(0, _TriggerSet.Count,
			"nor to the near-miss trigger set, which forwards Entry.Output to the analytics log — that would write the raw IBAN, SSN and card number into it")
	} finally {
		_PIPP_Teardown(Saved)
	}
}
Test("hotstrings: an @ registration still writes to neither preview index (at-triggers-have-no-preview-candidate-source)",
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
