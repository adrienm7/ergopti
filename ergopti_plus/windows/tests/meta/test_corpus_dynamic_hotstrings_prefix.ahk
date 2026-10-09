; tests/meta/test_corpus_dynamic_hotstrings_prefix.ahk

; ==============================================================================
; MODULE: Dynamic Hotstrings Prefix Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json and validates
; the AHK personal-info prefix counter (CountDynamicSection, infra/menu_helpers.ahk)
; against it — proving the AHK reimplementation of the phone/SSN/IBAN threshold
; arithmetic still matches the shared Lua reference it was hand-copied from
; (_shared/lua/dynamic_hotstrings/init.lua:compute_prefix_counts).
;
; The macOS half lives in macos/tests/unit/meta/test_corpus_dynamic_hotstrings_prefix.lua
; and calls the shared Lua function directly — this file exists because AHK has
; no equivalent shared-module delegation and must be pinned against the corpus
; instead.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusDynHS_Root() {
	; A_ScriptDir is windows/tests/ — two levels up reaches ergopti_plus/.
	return A_ScriptDir . "\..\..\_shared\tests\corpus\dynamic_hotstrings\prefix_vectors.json"
}

_CorpusDynHS_Parse() {
	Path := _CorpusDynHS_Root()
	if !FileExist(Path) {
		return ""
	}
	Raw := FileRead(Path, "UTF-8")
	if Raw == "" {
		return ""
	}
	return JsonParse(Raw)
}




; ============================================
; ============================================
; ======= 2/ Corpus integrity ================
; ============================================
; ============================================

_CorpusDynHS_FileIsReadableAndParseable() {
	Corpus := _CorpusDynHS_Parse()
	AssertTrue(Corpus != "", "corpus JSON must be readable and parse without error")
	AssertTrue(Corpus.Has("prefix_count_vectors"), "corpus must have a prefix_count_vectors key")
	AssertTrue(Corpus["prefix_count_vectors"].Length > 0, "corpus must contain at least one prefix_count_vector")
	AssertTrue(Corpus.Has("spaced_prefix_vectors"), "corpus must have a spaced_prefix_vectors key")
	AssertTrue(Corpus["spaced_prefix_vectors"].Length > 0, "corpus must contain at least one spaced_prefix_vector")
}
Test("dynamic hotstrings prefix corpus — file is readable and parseable", _CorpusDynHS_FileIsReadableAndParseable)





; =============================================
; =============================================
; ======= 3/ CountDynamicSection parity =======
; =============================================
; =============================================

; Runs every prefix_count_vectors entry through CountDynamicSection and
; compares against the corpus expectation. Resets both PersonalInformation and
; _TomlCountCache per vector so a cached count from one vector never leaks
; into the next (CountDynamicSection memoises by section name only).
_CorpusDynHS_CountDynamicSectionMatchesCorpus() {
	global PersonalInformation, _TomlCountCache
	Corpus := _CorpusDynHS_Parse()
	if Corpus == "" {
		Assert(false, "corpus must be parseable")
		return
	}

	Mismatches := ""
	for Vector in Corpus["prefix_count_vectors"] {
		PersonalInformation := Map(
			"phone_number", Vector["phone"],
			"phone_number_clean", Vector["fphone"],
			"social_security_number", Vector["ssn_raw"],
			"iban", Vector["iban_raw"]
		)
		_TomlCountCache := Map()

		Expected := Vector["expected"]
		PhoneN := CountDynamicSection("PhonePrefixes")
		SsnN   := CountDynamicSection("SsnPrefixes")
		IbanN  := CountDynamicSection("IbanPrefixes")

		if PhoneN != Expected["phoneprefixes"]
			Mismatches .= "`n  [" . Vector["id"] . "] phoneprefixes: got " . PhoneN . ", expected " . Expected["phoneprefixes"]
		if SsnN != Expected["ssnprefixes"]
			Mismatches .= "`n  [" . Vector["id"] . "] ssnprefixes: got " . SsnN . ", expected " . Expected["ssnprefixes"]
		if IbanN != Expected["ibanprefixes"]
			Mismatches .= "`n  [" . Vector["id"] . "] ibanprefixes: got " . IbanN . ", expected " . Expected["ibanprefixes"]
	}

	Assert(Mismatches == "", "CountDynamicSection mismatches against the corpus:" . Mismatches)
}
Test("dynamic hotstrings prefix corpus — CountDynamicSection matches every prefix_count_vector", _CorpusDynHS_CountDynamicSectionMatchesCorpus)
