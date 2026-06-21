; tests/meta/test_hotstrings_deadkey_uppercase_cleanup.ahk

; ==============================================================================
; MODULE: Hotstrings Dead-Key Uppercase Cleanup Meta Test
; DESCRIPTION:
; Static source guard for the "hotstrings-deadkey-uppercase-duplicate" audit
; finding in modules/hotstrings.ahk.
;
; ROOT CAUSE ENCODED:
; The dead-key-ê cleanup loop deleted lowercase vowels ("a", "à", "i", "o",
; "u", "s") from DeadkeyMappingCircumflexModified, but forgot to delete their
; uppercase counterparts ("A", "À", "I", "O", "U", "S"). Because
; CreateCaseSensitiveHotstrings already registers both the lowercase and
; uppercase trigger forms (e.g. "êa" → "â" and "êA" → "Â"), the subsequent
; for-loop over DeadkeyMappingCircumflexModified would call
; CreateDeadkeyHotstring("A", "Â", …) — registering "êA" a second time.
; This produced duplicate HSE entries and wasted CPU at startup and on every
; live rebuild. The same problem affected "e"/"E" and "t"/"T" which were
; removed explicitly below the loop.
;
; The fix adds explicit .Delete() calls for the uppercase variants inside the
; loop and for "E" and "T" below it.
;
; This test verifies:
;   1. The loop body deletes both the lowercase vowel AND its uppercase form.
;   2. "E" is deleted explicitly (for the "êe" → "œ" roll).
;   3. "T" is deleted explicitly (for the "être" sequence).
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ Uppercase vowels deleted inside the loop =========
; =============================================================
; =============================================================

_HSDU_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_HSDU_UppercaseDeletedInLoop() {
	Raw := _DriverDirConcat("modules")
	Src := _HSDU_StripComments(Raw)
	Assert(Src != "", "modules/hotstrings.ahk must be readable")

	; The fix uses StrUpper(Vowel) inside the loop to compute and delete the
	; uppercase counterpart dynamically — look for that pattern.
	Assert(InStr(Src, "StrUpper(Vowel)") > 0,
		"hotstrings.ahk must call StrUpper(Vowel) inside the dead-key cleanup loop to delete uppercase variants (hotstrings-deadkey-uppercase-duplicate)")

	Assert(RegExMatch(Src, "DeadkeyMappingCircumflexModified\.Delete\(UpperVowel\)"),
		"hotstrings.ahk must delete UpperVowel from DeadkeyMappingCircumflexModified (hotstrings-deadkey-uppercase-duplicate)")
}
Test("hotstrings: dead-key loop deletes uppercase vowel variants via StrUpper(Vowel) (hotstrings-deadkey-uppercase-duplicate)", _HSDU_UppercaseDeletedInLoop)




; ====================================================
; ====================================================
; ======= 2/ "E" and "T" explicitly deleted ===========
; ====================================================
; ====================================================

_HSDU_ETExplicitlyDeleted() {
	Raw := _DriverDirConcat("modules")
	Src := _HSDU_StripComments(Raw)

	; "E" must be explicitly deleted (uppercase counterpart of "e" which closes "êe" → "œ")
	Assert(RegExMatch(Src, 'DeadkeyMappingCircumflexModified\.Delete\("E"\)'),
		'hotstrings.ahk must call DeadkeyMappingCircumflexModified.Delete("E") (hotstrings-deadkey-uppercase-duplicate)')

	; "T" must be explicitly deleted (uppercase counterpart of "t" used in "être")
	Assert(RegExMatch(Src, 'DeadkeyMappingCircumflexModified\.Delete\("T"\)'),
		'hotstrings.ahk must call DeadkeyMappingCircumflexModified.Delete("T") (hotstrings-deadkey-uppercase-duplicate)')
}
Test('hotstrings: "E" and "T" are explicitly removed from DeadkeyMappingCircumflexModified (hotstrings-deadkey-uppercase-duplicate)', _HSDU_ETExplicitlyDeleted)
