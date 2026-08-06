; tests/unit/test_personal_info_tags_single_source.ahk

; ==============================================================================
; MODULE: The @-tag map has one owner (personal-info-tag-map-single-source)
; DESCRIPTION:
; @bic, @cb, @cc, @iban, @rib, @ss, @tel and @tél each expand to one
; personal_info field, and each is ALSO previewed. The set of tags and the field
; a tag names therefore have two readers, and they used to have two copies: the
; registration wrote eight CreateHotstring calls by hand, and anything that
; wanted to know what "@rib" meant had to restate it.
;
; ROOT CAUSE ENCODED: a tag that expands one field and previews another is
; invisible. The bubble looks right, the expansion looks right, and only a user
; comparing the two notices — which is exactly the failure mode
; _shared/modules/personal_info/fields.toml's own header describes for the
; masked-field list, and the reason that file writes every field out both ways.
; One map, read by both sides, is the only shape in which the two cannot
; disagree.
;
; The second half is the join to the shared declaration: a tag naming a field
; that nobody classified masks fail-closed, so the preview would silently hide a
; value the user asked to see, with nothing anywhere saying why.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ One map, two readers =======
; =======================================
; =======================================

_PITS_TheMapIsTheOnlyDeclaration() {
	global PERSONAL_INFO_TAGS, PERSONAL_INFO_TAG_ORDER
	Assert(PERSONAL_INFO_TAGS is Map and PERSONAL_INFO_TAGS.Count >= 8,
		"PERSONAL_INFO_TAGS must declare the eight shipped single-field tags")
	Assert(PERSONAL_INFO_TAG_ORDER is Array,
		"PERSONAL_INFO_TAG_ORDER must state the registration order — a Map does not enumerate in insertion order and that order is the engine's last collision tie-break")
	AssertEqual(PERSONAL_INFO_TAGS.Count, PERSONAL_INFO_TAG_ORDER.Length,
		"every tag must be registered: an entry present in the map and absent from the order list is a tag that previews and never expands")
	for _, Tag in PERSONAL_INFO_TAG_ORDER {
		Assert(PERSONAL_INFO_TAGS.Has(Tag),
			"'@" . Tag . "' is registered but names no field — the order list and the map must hold the same tags")
	}
}
Test("personal-info tags: the order list and the tag map hold the same tags (personal-info-tag-map-single-source)",
	_PITS_TheMapIsTheOnlyDeclaration)


_PITS_BothReadersUseTheMap() {
	Registration := _DriverFuncBody("_HS_RegisterTextExpansionAndDynamic")
	Assert(InStr(Registration, "PERSONAL_INFO_TAG_ORDER") > 0,
		"the registration must build its @-tag hotstrings from the shared order list")
	Assert(InStr(Registration, "PERSONAL_INFO_TAGS[") > 0,
		"and resolve each tag's field through the shared map")
	; Comments are stripped by _DriverFuncBody, so a tag named in the prose above
	; the loop cannot satisfy or trip this. The literal it forbids is a QUOTED
	; trigger string, which is what a hand-written call site looks like.
	Assert(InStr(Registration, '"@iban"') == 0,
		"no hand-written @-tag trigger may come back: eight literal call sites here and a second copy of the map in the preview is how a tag comes to expand one field and preview another")
	Assert(InStr(Registration, '"@bic"') == 0,
		"same for @bic")

	Resolver := _DriverFuncBody("_PIPreviewFieldsForTag")
	Assert(InStr(Resolver, "PERSONAL_INFO_TAGS") > 0,
		"the preview must resolve a tag through the SAME map the registration used — a private list here is the second source this whole test exists to forbid")
}
Test("personal-info tags: registration and preview read one shared map (personal-info-tag-map-single-source)",
	_PITS_BothReadersUseTheMap)





; ===================================================
; ===================================================
; ======= 2/ Every tag names a declared field =======
; ===================================================
; ===================================================

_PITS_EveryTagNamesADeclaredField() {
	global PERSONAL_INFO_TAGS
	PersonalInfoMaskReset()
	Declaration := PersonalInfoMaskDeclaration()
	Assert(Declaration.Fields.Count >= 10,
		"floor: the shared declaration must have been read (only " . Declaration.Fields.Count . " field(s)) — against the fail-closed policy every assertion below would pass over an empty map")
	for Tag, Field in PERSONAL_INFO_TAGS {
		Assert(Declaration.Fields.Has(Field),
			"'@" . Tag . "' names the field '" . Field . "', which _shared/modules/personal_info/fields.toml does not declare. An undeclared field masks fail-closed, so the preview would hide a value the user asked to see and nothing would say why")
	}
}
Test("personal-info tags: every tag names a field the shared declaration classifies (personal-info-tag-map-single-source)",
	_PITS_EveryTagNamesADeclaredField)
