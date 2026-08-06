; tests/unit/test_personal_info_combo_resolver.ahk

; ==============================================================================
; MODULE: Regression — @-combos came from a hand-written list that had rotted
;         (personal-info-combo-hand-list)
; DESCRIPTION:
; @npd expanded and @npdt did nothing. @t expanded and @nt did nothing. The
; letters resolved, the values existed, and the only thing missing was a line in
; a list: pattern_max_length is 1, so the registration loop produced ONLY the
; single-letter combos, and every multi-letter one came from thirty-one
; hand-written CreateHotstringComboAuto calls. @npdt and @nt were not among them.
;
; ROOT CAUSE ENCODED: a pre-registered combo is an enumeration, and with thirteen
; alias letters the space is 169 at length two, 2 197 at three and 28 561 at
; four. A list can only ever be a sample of that, and nothing anywhere reports
; which members it dropped — the key simply does nothing, silently. So the fix is
; not a longer list: HSE_TryPersonalInfoCombo resolves @<letters>★ at FIRE time,
; which makes every combination work at flat memory cost.
;
; WHAT THESE TESTS PIN:
; the two reported cases by name, order significance (@np is not @pn), the
; refusal cases that keep a typo from typing a partial identity, and the
; escaping — because the resolver registers with OnlyText:False, where a "+" in
; an email address is read as Shift.
; ==============================================================================

#Requires AutoHotkey v2.0

; The magic key the tests drive the resolver with. Not the literal ★ everywhere:
; the resolver takes it as an argument, and hard-coding it in the assertions
; would hide a resolver that ignored the parameter and assumed one.
global _PICR_MK := Chr(0x2605)

; Field values chosen so each is distinguishable in a concatenation and so one
; of them carries a Send metacharacter. Nobody's data.
global _PICR_INFO := Map(
	"last_name",     "Dupont",
	"first_name",    "Marie",
	"date_of_birth", "01/02/1990",
	"phone_number",  "0606060606",
	"email_address", "marie+tag@example.org",
	"iban",          "FR7630006000011234567890189"
)

global _PICR_LETTERS := Map(
	"n", "last_name",
	"p", "first_name",
	"d", "date_of_birth",
	"t", "phone_number",
	"m", "email_address",
	"i", "iban"
)





; ==========================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==========================

; Drives the REAL resolver against a buffer, with the personal-info globals
; swapped for the fixtures above and restored afterwards. Everything the
; resolver reads is a global, so a test that forgot to restore one would corrupt
; every later test in the suite rather than fail here.
_PICR_Resolve(Buffer) {
	global HSE_Buffer, HSE_Suppressed, HSE_RebuildInProgress, HSE_PersonalInfoCombosEnabled
	global PersonalInformation, PersonalInformationLetters, _PICR_MK, _PICR_INFO, _PICR_LETTERS
	PrevBuf := HSE_Buffer
	PrevInfo := PersonalInformation
	PrevLetters := PersonalInformationLetters
	PrevEnabled := HSE_PersonalInfoCombosEnabled
	PrevSuppressed := HSE_Suppressed
	PrevRebuild := HSE_RebuildInProgress
	HSE_Buffer := Buffer
	PersonalInformation := _PICR_INFO
	PersonalInformationLetters := _PICR_LETTERS
	HSE_PersonalInfoCombosEnabled := true
	HSE_Suppressed := false
	HSE_RebuildInProgress := false
	try {
		return HSE_TryPersonalInfoCombo(_PICR_MK)
	} finally {
		HSE_Buffer := PrevBuf
		PersonalInformation := PrevInfo
		PersonalInformationLetters := PrevLetters
		HSE_PersonalInfoCombosEnabled := PrevEnabled
		HSE_Suppressed := PrevSuppressed
		HSE_RebuildInProgress := PrevRebuild
	}
}

; The replacement the resolver produced for "@<tag>★", or "" when it declined.
_PICR_ReplacementFor(Tag) {
	global _PICR_MK
	Spec := _PICR_Resolve("@" . Tag . _PICR_MK)
	return IsObject(Spec) ? Spec.Replacement : ""
}





; ===========================================================
; ===========================================================
; ======= 2/ The two cases the user reported, by name =======
; ===========================================================
; ===========================================================

; @npd worked because it was in the hand list; @npdt did not because it was not.
; Both must work now, and the assertion names both so a future regression says
; which half broke.
_PICR_ReportedCasesExpand() {
	AssertEqual("Dupont{Tab}Marie{Tab}01/02/1990", _PICR_ReplacementFor("npd"),
		"@npd expanded before the rewrite (it was one of the thirty-one hand-listed combos) and must still expand")
	AssertEqual("Dupont{Tab}Marie{Tab}01/02/1990{Tab}0606060606", _PICR_ReplacementFor("npdt"),
		"@npdt is the case that was reported: same letters plus one, all four aliasing filled-in fields, and it did nothing because no line in the hand-written list named it")
}
Test("combo resolver: @npd and @npdt both expand (personal-info-combo-hand-list)",
	_PICR_ReportedCasesExpand)


; The second reported pair. @t is a single letter, so the registration loop
; produced it (pattern_max_length = 1); @nt is two, so only the hand list could
; have — and did not.
_PICR_TwoLetterCaseExpands() {
	AssertEqual("0606060606", _PICR_ReplacementFor("t"),
		"@t is a single-letter combo, produced by the registration loop, and must keep working")
	AssertEqual("Dupont{Tab}0606060606", _PICR_ReplacementFor("nt"),
		"@nt is the second reported case: two letters is already past pattern_max_length, so every two-letter combo depended on being hand-listed")
}
Test("combo resolver: @t and @nt both expand (personal-info-combo-hand-list)",
	_PICR_TwoLetterCaseExpands)


; The hand list held thirty-one entries out of a space of tens of thousands.
; Sampling a spread of lengths is not proof of completeness, but a resolver that
; special-cased anything would fail one of these.
_PICR_ArbitraryCombosExpand() {
	AssertEqual("Marie", _PICR_ReplacementFor("p"), "one letter")
	AssertEqual("Marie{Tab}Dupont", _PICR_ReplacementFor("pn"), "two letters")
	AssertEqual("0606060606{Tab}01/02/1990{Tab}Dupont", _PICR_ReplacementFor("tdn"), "three letters, an order nobody would have listed")
	AssertEqual("01/02/1990{Tab}0606060606{Tab}Marie{Tab}Dupont", _PICR_ReplacementFor("dtpn"), "four letters, likewise")
	AssertEqual("Dupont{Tab}Dupont", _PICR_ReplacementFor("nn"),
		"a repeated letter is a legitimate combo (the same value twice) and must NOT be intercepted by the repeat-key fallback")
}
Test("combo resolver: combinations of every length resolve, listed or not",
	_PICR_ArbitraryCombosExpand)


; Order is the whole point of a combo — the fields land in consecutive form
; fields in the sequence typed. A resolver that sorted or set-ified the letters
; would pass every test above and still put the surname in the forename box.
_PICR_OrderIsSignificant() {
	AssertEqual("Dupont{Tab}Marie", _PICR_ReplacementFor("np"), "@np is surname then forename")
	AssertEqual("Marie{Tab}Dupont", _PICR_ReplacementFor("pn"), "@pn is the reverse, and must not resolve to the same string")
	Assert(_PICR_ReplacementFor("np") !== _PICR_ReplacementFor("pn"),
		"the two orders must differ: if they did not, the resolver is treating the letters as a set and the values would land in the wrong form fields")
}
Test("combo resolver: letter order decides field order (@np is not @pn)",
	_PICR_OrderIsSignificant)





; ======================================
; ======================================
; ======= 3/ What it must refuse =======
; ======================================
; ======================================

; A typo must not type a partial identity. macOS's resolver SKIPS letters it
; cannot resolve, which silently drops a field; this one declines the combo so
; the user sees nothing happen and retypes, rather than submitting a form with
; the remaining values shifted up by one.
_PICR_UnknownLetterDeclinesWholeCombo() {
	AssertEqual("", _PICR_ReplacementFor("npz"),
		"'z' aliases no field — the combo must be declined whole, not silently expanded as @np")
	AssertEqual("", _PICR_ReplacementFor("z"),
		"and a single unknown letter is not a combo at all")
}
Test("combo resolver: one unknown letter declines the whole combo",
	_PICR_UnknownLetterDeclinesWholeCombo)


; An alias pointing at a field the user left blank is the same hazard: expanding
; the rest shifts every later value into the wrong box.
_PICR_EmptyFieldDeclinesWholeCombo() {
	global HSE_Buffer, PersonalInformation, PersonalInformationLetters
	global HSE_PersonalInfoCombosEnabled, HSE_Suppressed, HSE_RebuildInProgress, _PICR_MK
	PrevBuf := HSE_Buffer, PrevInfo := PersonalInformation, PrevLetters := PersonalInformationLetters
	PrevEnabled := HSE_PersonalInfoCombosEnabled, PrevSup := HSE_Suppressed, PrevReb := HSE_RebuildInProgress
	PersonalInformation := Map("last_name", "Dupont", "first_name", "")
	PersonalInformationLetters := Map("n", "last_name", "p", "first_name")
	HSE_PersonalInfoCombosEnabled := true
	HSE_Suppressed := false
	HSE_RebuildInProgress := false
	HSE_Buffer := "@np" . _PICR_MK
	try {
		Spec := HSE_TryPersonalInfoCombo(_PICR_MK)
		Assert(!IsObject(Spec),
			"a blank field must decline the whole combo — expanding the rest shifts every later value into the wrong form field, which is worse than nothing happening")
	} finally {
		HSE_Buffer := PrevBuf, PersonalInformation := PrevInfo, PersonalInformationLetters := PrevLetters
		HSE_PersonalInfoCombosEnabled := PrevEnabled, HSE_Suppressed := PrevSup, HSE_RebuildInProgress := PrevReb
	}
}
Test("combo resolver: a blank field declines the whole combo",
	_PICR_EmptyFieldDeclinesWholeCombo)


; The resolver is a fallback on a keystroke path. Everything that means "not now"
; has to stop it, or a live rebuild expands a combo that a registered tag is
; about to reclaim.
_PICR_GuardsDecline() {
	global HSE_Buffer, HSE_PersonalInfoCombosEnabled, HSE_Suppressed, HSE_RebuildInProgress
	global PersonalInformation, PersonalInformationLetters, _PICR_MK, _PICR_INFO, _PICR_LETTERS
	PrevBuf := HSE_Buffer, PrevInfo := PersonalInformation, PrevLetters := PersonalInformationLetters
	PrevEnabled := HSE_PersonalInfoCombosEnabled, PrevSup := HSE_Suppressed, PrevReb := HSE_RebuildInProgress
	PersonalInformation := _PICR_INFO
	PersonalInformationLetters := _PICR_LETTERS
	HSE_Buffer := "@np" . _PICR_MK
	try {
		HSE_PersonalInfoCombosEnabled := false, HSE_Suppressed := false, HSE_RebuildInProgress := false
		Assert(!IsObject(HSE_TryPersonalInfoCombo(_PICR_MK)),
			"the feature toggle must disable the resolver — a setting the user switches off has to stop the behaviour, not just the registration")
		HSE_PersonalInfoCombosEnabled := true, HSE_Suppressed := true, HSE_RebuildInProgress := false
		Assert(!IsObject(HSE_TryPersonalInfoCombo(_PICR_MK)),
			"HSE_Suppressed means the engine is mid-send-burst; resolving there would expand text the driver is itself typing")
		HSE_PersonalInfoCombosEnabled := true, HSE_Suppressed := false, HSE_RebuildInProgress := true
		Assert(!IsObject(HSE_TryPersonalInfoCombo(_PICR_MK)),
			"during a live rebuild the matcher answers '' for EVERY sequence — that means 'cannot answer now', not 'nothing claims this', and expanding then beats the registered tag that is about to come back")
	} finally {
		HSE_Buffer := PrevBuf, PersonalInformation := PrevInfo, PersonalInformationLetters := PrevLetters
		HSE_PersonalInfoCombosEnabled := PrevEnabled, HSE_Suppressed := PrevSup, HSE_RebuildInProgress := PrevReb
	}
}
Test("combo resolver: the toggle, the suppress flag and the rebuild fence each decline",
	_PICR_GuardsDecline)


; The buffer must genuinely end with the magic key and a well-formed tag.
_PICR_MalformedBuffersDecline() {
	global _PICR_MK
	Assert(!IsObject(_PICR_Resolve("np" . _PICR_MK)),
		"no leading '@' is not a combo — it is an ordinary two-letter word followed by the magic key, which the repeat fallback owns")
	Assert(!IsObject(_PICR_Resolve("@" . _PICR_MK)),
		"'@' with no letters is not a combo yet")
	Assert(!IsObject(_PICR_Resolve("@np")),
		"without the magic key the sequence is still being typed")
	Assert(!IsObject(_PICR_Resolve("")),
		"an empty buffer must not throw")
	AssertEqual("Dupont{Tab}Marie", _PICR_ReplacementFor("np"),
		"and the well-formed case still resolves after all of those — a guard that declined everything would satisfy every assertion above")
}
Test("combo resolver: a malformed buffer declines without throwing",
	_PICR_MalformedBuffersDecline)





; ====================================================
; ====================================================
; ======= 4/ Escaping and the privacy contract =======
; ====================================================
; ====================================================

; The resolver registers with OnlyText:False, so the replacement is interpreted
; by Send. A "+" in an email address reads as Shift and the address is typed
; wrong — silently, into someone's form, with their own data.
_PICR_ValuesAreEscaped() {
	Repl := _PICR_ReplacementFor("m")
	Assert(!InStr(Repl, "marie+tag"),
		"the raw '+' must not survive into the replacement: Send reads it as Shift, so 'marie+tag@example.org' types as 'marieTAG@example.org' or worse")
	AssertEqual("marie{+}tag@example.org", Repl,
		"it must be the escaped form SendEscapeLiteral produces, so the address lands verbatim")
}
Test("combo resolver: field values are escaped for the Send engine (F17 regression)",
	_PICR_ValuesAreEscaped)


; Every field the resolver can reach comes out of personal_info.toml, so the
; replacement is by construction the user's own data. Without IsPrivate the fire
; writes it verbatim into today.log — the leak the whole personal-info privacy
; contract exists to prevent.
_PICR_SpecCarriesPrivacyFlag() {
	global _PICR_MK
	Spec := _PICR_Resolve("@i" . _PICR_MK)
	Assert(IsObject(Spec), "the IBAN combo must resolve — the rest of this test is vacuous otherwise")
	Assert(Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate,
		"the transient Spec must carry IsPrivate: every field this resolver reaches is personal_info data, and the flag is what keeps the resolved IBAN out of the metrics row and the fire trace")
	Assert(Spec.HasOwnProp("FinalResult") and Spec.FinalResult,
		"and FinalResult, so the send takes SendFinalResult like every other @ registration rather than the observed SendEvent path")
	AssertEqual("@i" . _PICR_MK, Spec.Trigger,
		"the Spec's trigger must be the sequence actually typed, so the fire log and the buffer arithmetic agree on how much to erase")
	AssertEqual(StrLen("@i" . _PICR_MK), Spec.Length,
		"and its Length must match that trigger — the dispatcher backspaces Length characters")
}
Test("combo resolver: the transient Spec is marked private and final",
	_PICR_SpecCarriesPrivacyFlag)
