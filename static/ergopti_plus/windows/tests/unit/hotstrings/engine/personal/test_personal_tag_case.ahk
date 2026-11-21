; tests/unit/hotstrings/engine/personal/test_personal_tag_case.ahk

; ==============================================================================
; MODULE: Personal @-Tag Case (hcd-5-tag-case)
; DESCRIPTION:
; Replays _shared/tests/corpus/personal_info/tag_case_vectors.json through the
; fire-time resolver (HSE_TryPersonalInfoCombo) and, for one-letter tags,
; through the registered tags (PersonalInfoRegisterLetterTag + HSE_FeedChar).
; A personal tag follows the typed case, one field per letter (maintainer
; decision HCD-5, 2026-11-21); Windows used to fold the case, so `@N★` typed
; « Nom » and `@Np★` « Nom Prénom ». macOS and Linux replay the same vectors.
; The registered tags and the resolver also carry the dynamic category's delay
; (HCD-4).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==========================

_PTC_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\personal_info\tag_case_vectors.json", "UTF-8"))
}

; The replacement the registered or resolved tag types for the vector's values.
_PTC_Expected(Values) {
	Text := ""
	for Index, Value in Values
		Text .= (Index > 1 ? "{Tab}" : "") . SendEscapeLiteral(Value)
	return Text
}

; Runs Body with the corpus as the personal-info globals, restored afterwards.
_PTC_WithCorpus(Corpus, Body) {
	global PersonalInformation, PersonalInformationLetters, HSE_PersonalInfoCombosEnabled
	global HSE_Suppressed, HSE_RebuildInProgress
	InfoWasSet := IsSet(PersonalInformation)
	LettersWereSet := IsSet(PersonalInformationLetters)
	PrevInfo := InfoWasSet ? PersonalInformation : 0
	PrevLetters := LettersWereSet ? PersonalInformationLetters : 0
	PrevEnabled := HSE_PersonalInfoCombosEnabled
	PrevSuppressed := HSE_Suppressed
	PrevRebuild := HSE_RebuildInProgress
	PersonalInformation := Corpus["info"]
	PersonalInformationLetters := Corpus["letters"]
	HSE_PersonalInfoCombosEnabled := true
	HSE_Suppressed := false
	HSE_RebuildInProgress := false
	try
		Body.Call()
	finally {
		if InfoWasSet
			PersonalInformation := PrevInfo
		else
			PersonalInformation := unset
		if LettersWereSet
			PersonalInformationLetters := PrevLetters
		else
			PersonalInformationLetters := unset
		HSE_PersonalInfoCombosEnabled := PrevEnabled
		HSE_Suppressed := PrevSuppressed
		HSE_RebuildInProgress := PrevRebuild
	}
}





; ===========================================
; ===========================================
; ======= 2/ The fire-time resolver =========
; ===========================================
; ===========================================

_PTC_Resolver(Vector) {
	_PTC_WithCorpus(_PTC_Corpus(), _PTC_ResolverBody.Bind(Vector))
}

_PTC_ResolverBody(Vector) {
	global HSE_Buffer, ScriptInformation
	MagicKey := ScriptInformation["MagicKey"]
	HSE_Buffer := "@" . Vector["tag"] . MagicKey
	Spec := HSE_TryPersonalInfoCombo(MagicKey)
	AssertEqual(_PTC_Expected(Vector["values"]), IsObject(Spec) ? Spec.Replacement : "",
		Vector["id"] . ": the resolver types the vector's values")
	if IsObject(Spec)
		AssertEqual(_DynamicHotstringDelay(), Spec.TimeActivationSeconds,
			Vector["id"] . ": the resolver carries the dynamic category's delay (HCD-4)")
}

for _PTC_Vector in _PTC_Corpus()["vectors"]
	Test("personal tag case resolver: " . _PTC_Vector["id"] . " (hcd-5-tag-case)",
		_HOF_Run.Bind(_PTC_Resolver.Bind(_PTC_Vector)))





; ======================================
; ======================================
; ======= 3/ The registered tags =======
; ======================================
; ======================================

_PTC_Registered(Vector) {
	global ScriptInformation
	Corpus := _PTC_Corpus()
	MagicKey := ScriptInformation["MagicKey"]
	for Letter, Field in Corpus["letters"]
		PersonalInfoRegisterLetterTag(Letter, Field, Corpus["info"][Field])
	Match := ""
	for Char in StrSplit("@" . Vector["tag"] . MagicKey)
		Match := HSE_FeedChar(Char, true)
	AssertTrue(IsObject(Match), Vector["id"] . ": the one-letter tag is registered")
	AssertEqual(_PTC_Expected(Vector["values"]), Match.Replacement,
		Vector["id"] . ": the registered tag types the vector's value")
	AssertEqual(_DynamicHotstringDelay(), Match.TimeActivationSeconds,
		Vector["id"] . ": the registered tag carries the dynamic category's delay (HCD-4)")
}

for _PTC_Vector in _PTC_Corpus()["vectors"] {
	if (StrLen(_PTC_Vector["tag"]) == 1 && _PTC_Vector["values"].Length == 1)
		Test("personal tag case registered: " . _PTC_Vector["id"] . " (hcd-5-tag-case)",
			_HOF_Run.Bind(_PTC_Registered.Bind(_PTC_Vector)))
}
