; tests/meta/test_personal_section_label_disambiguation_wired.ahk

; ==============================================================================
; MODULE: Personal-Section Label Disambiguation Wiring Meta Test
; DESCRIPTION:
; Static source guard for finding F15
; (duplicate-personal-section-desc-menu-mistarget).
;
; Two personal-hotstring sections with an identical user-typed description
; produce identical Menu labels; AHK's name-based Menu.Check/Uncheck always
; resolves to the FIRST item carrying that label, so toggling/selecting the
; SECOND section silently painted the checkmark on the FIRST. The fix builds a
; per-section disambiguated label (infra/menu_helpers.ahk's
; _HS_BuildDisambiguatedSectionLabels) and threads it through every
; Check/Uncheck-relevant call site in the personal-section submenus instead of
; the raw TomlData[...]["description"].
;
; Source-scan rather than behavioral: driving a real duplicate-description
; scenario end-to-end needs a live Menu() + i18n + ScriptInformation harness;
; the disambiguation LOGIC itself is covered behaviorally by
; tests/unit/test_menu_helpers.ahk. This test only pins that the render/toggle
; call sites actually consume the disambiguated map.
; ==============================================================================

#Requires AutoHotkey v2.0




_PSLD_AssertWired() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "_HS_BuildDisambiguatedSectionLabels(TomlData)") > 0,
		"_HS_Personal must build the disambiguated label map before rendering the personal-section submenus (duplicate-personal-section-desc-menu-mistarget)")

	SetBody := _DriverFuncBody("_SetPersonalDefaultSection")
	Assert(SetBody != "", "_SetPersonalDefaultSection() declaration must exist")
	Assert(InStr(SetBody, "DisambiguatedLabels") > 0,
		"_SetPersonalDefaultSection must Check/Uncheck by the disambiguated label, not the raw (possibly duplicate) description (duplicate-personal-section-desc-menu-mistarget)")
	Assert(InStr(SetBody, 'SD["description"]') == 0 and InStr(SetBody, 'TomlData["sections"][SecName]["description"]') == 0,
		"_SetPersonalDefaultSection must not Check/Uncheck against the raw description directly (duplicate-personal-section-desc-menu-mistarget)")
}
Test("menu: personal-section Check/Uncheck uses disambiguated labels (duplicate-personal-section-desc-menu-mistarget)",
	_PSLD_AssertWired)
