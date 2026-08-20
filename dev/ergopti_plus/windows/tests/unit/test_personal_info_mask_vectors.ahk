; tests/unit/test_personal_info_mask_vectors.ahk

; ==============================================================================
; MODULE: Corpus — the shared preview-masking vectors
; DESCRIPTION:
; Replays _shared/modules/personal_info/preview_vectors.toml through this
; driver's masking path and asserts every expected preview character for
; character.
;
; WHY A CORPUS AND NOT EXPECTATIONS WRITTEN HERE:
; fields.toml says WHICH fields are secret and _shared/lua/personal_info/mask.lua
; says HOW MUCH of one is hidden, but neither pins the ANSWER. Windows is
; AutoHotkey and cannot require the shared Lua, so infra/personal_info_mask.ahk
; is a PORT rather than a binding — and two implementations in two languages do
; not converge on intent alone. The corpus is what measures "identical on all
; three drivers"; asserting against expectations restated here would certify
; exactly the divergence the corpus exists to catch.
;
; ROOT CAUSE ENCODED: a value that reads differently on two machines is not a
; cosmetic difference. The bubble exists so a user can confirm WHICH of their
; values is about to be typed — if Windows reveals four digits where macOS
; reveals none, the check the bubble offers is not the same check.
;
; The floor assertions matter as much as the comparisons: a corpus that parsed
; to zero rows would make the replay loop pass over nothing at all, which is the
; classic shape of a test that cannot fail.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Reading the corpus =======================
; =====================================================
; =====================================================

; The corpus is an array of tables, which ParseTomlFile flattens to ONE section
; (later keys overwrite earlier ones), so it is scanned by hand here. Only the
; three keys this driver has to satisfy are read; `why` is prose for humans.
_PIMV_ReadVectors() {
	global _SharedDir
	Vectors := []
	Path := _SharedDir . "\modules\personal_info\preview_vectors.toml"
	if !FileExist(Path) {
		return Vectors
	}
	Content := FileRead(Path, "UTF-8")
	Current := ""
	Loop Parse, Content, "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "[[vectors]]") {
			if IsObject(Current) {
				Vectors.Push(Current)
			}
			; A vector with no `field` key is a real case in the corpus: it is the
			; one that asks what happens when the provenance was lost on the way to
			; the bubble. "" is that state, not a parse failure.
			Current := { Field: "", Input: "", Preview: "" }
			continue
		}
		if (!IsObject(Current) or Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		if RegExMatch(Line, '^field\s*=\s*"(.*)"$', &FieldMatch) {
			Current.Field := UnescapeTomlString(FieldMatch[1])
		} else if RegExMatch(Line, '^input\s*=\s*"(.*)"$', &InputMatch) {
			Current.Input := UnescapeTomlString(InputMatch[1])
		} else if RegExMatch(Line, '^preview\s*=\s*"(.*)"$', &PreviewMatch) {
			Current.Preview := UnescapeTomlString(PreviewMatch[1])
		}
	}
	if IsObject(Current) {
		Vectors.Push(Current)
	}
	return Vectors
}




; =====================================================
; =====================================================
; ======= 2/ Replaying it =============================
; =====================================================
; =====================================================

; The floor. Both arms of the decision have to be represented or the corpus
; proves half of it: a wrong port is most likely to over-mask, and only the
; public vectors catch that.
_PIMV_CorpusIsSubstantial() {
	Vectors := _PIMV_ReadVectors()
	Assert(Vectors.Length >= 15,
		"the shared corpus parsed to " . Vectors.Length . " vector(s) — it carried 16 when this test was written, and a replay loop over an empty array passes without asserting anything")
	Bullet := Chr(0x2022)
	Masked := 0
	for _, Vector in Vectors {
		Assert(Vector.Input != "", "every vector must carry an input")
		Assert(Vector.Preview != "", "every vector must carry an expected preview")
		if InStr(Vector.Preview, Bullet) {
			Masked += 1
		}
	}
	Assert(Masked >= 6,
		"the corpus holds " . Masked . " masked vector(s) — at least 6 are needed for the secret half of the decision to be measured")
	Assert(Vectors.Length - Masked >= 5,
		"the corpus holds " . (Vectors.Length - Masked) . " unmasked vector(s) — the phone number and the other public fields are half the decision, and only they catch a port that masks everything")
}
Test("personal-info mask: the shared corpus is present and covers both arms (preview-masking-cross-driver)",
	_PIMV_CorpusIsSubstantial)


; The declaration really was read. Every public vector would fail below if the
; loader had degraded to its fail-closed policy, but this says so directly —
; a suite that only reports "vector 10 differs" sends the reader to the mask
; when the fault is one directory away, in the file it could not open.
_PIMV_DeclarationWasRead() {
	PersonalInfoMaskReset()
	Assert(PersonalInfoMaskIsMasked("iban"),
		"fields.toml declares iban a secret")
	Assert(PersonalInfoMaskIsMasked("bic"),
		"fields.toml declares bic a secret")
	Assert(PersonalInfoMaskIsMasked("credit_card"),
		"fields.toml declares credit_card a secret")
	Assert(PersonalInfoMaskIsMasked("social_security_number"),
		"fields.toml declares social_security_number a secret")
	Assert(!PersonalInfoMaskIsMasked("phone_number"),
		"fields.toml declares phone_number NOT a secret, by the maintainer's decision — a driver reading a degraded policy would mask it and every public vector below would fail with no clue why")
	Assert(!PersonalInfoMaskIsMasked("first_name"),
		"fields.toml declares first_name NOT a secret")
	Assert(PersonalInfoMaskIsMasked("not_a_declared_field"),
		"an undeclared field is masked — absence is never permission")
	Assert(PersonalInfoMaskIsMasked(""),
		"a lost field name is masked for the same reason")
}
Test("personal-info mask: the shared field declaration is read, not guessed (preview-masking-cross-driver)",
	_PIMV_DeclarationWasRead)


; The acceptance criterion itself.
_PIMV_EveryVectorMatches() {
	Vectors := _PIMV_ReadVectors()
	Assert(Vectors.Length >= 15,
		"floor: the corpus must parse to at least 15 vectors before this loop means anything")
	PersonalInfoMaskReset()
	for Index, Vector in Vectors {
		Named := (Vector.Field == "") ? "<no field>" : Vector.Field
		AssertEqual(Vector.Preview, PersonalInfoMaskForPreview(Vector.Input, Vector.Field),
			"vector " . Index . " (" . Named . "): the AHK port must reproduce the shared preview character for character. macOS and Linux render the same value from the same declaration, and a driver that reveals more or less is offering the user a different check")
	}
}
Test("personal-info mask: every shared vector is reproduced byte for byte (preview-masking-cross-driver)",
	_PIMV_EveryVectorMatches)


; What is TYPED is never what the bubble shows. The mask is a display function
; and has no route to the injection path; this pins the other direction — that a
; masked preview is derived from, and leaves untouched, the complete value.
_PIMV_MaskingDoesNotMutateTheValue() {
	PersonalInfoMaskReset()
	Iban := "FR7630006000011234567890189"
	Shown := PersonalInfoMaskForPreview(Iban, "iban")
	Assert(Shown !== Iban,
		"sanity: a declared secret must not be shown as typed")
	AssertEqual("FR7630006000011234567890189", Iban,
		"masking must not mutate the value it was handed — the expansion types this string, and a driver that typed bullets into a bank form would corrupt real data while looking like the feature working")
	AssertEqual(StrLen(Iban), StrLen(Shown),
		"the masked preview keeps the shape of the value so the user can still recognise it")
}
Test("personal-info mask: masking a value leaves the value it will type untouched (preview-masking-cross-driver)",
	_PIMV_MaskingDoesNotMutateTheValue)
