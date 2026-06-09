; static/ergopti_plus/windows/tests/test_hotstring_live_toggle.ahk

; ==============================================================================
; MODULE: Hotstring Live-Toggle Whitelist Tests
; DESCRIPTION:
; Pins the classification that decides which hotstring section toggles are
; applied LIVE (HSE group enable/disable, no Reload) versus which fall back to a
; full Reload. The tray fast path (ui/tray_menu.ahk _HS_TryLiveToggle) trusts
; this whitelist, so a misclassification here would either reload needlessly or,
; worse, silently fail to toggle a section. These tests guard both directions.
;
; Only the pure, dependency-light helpers from
; lib/hotstrings/hotstring_live_toggle.ahk are exercised here - the tray glue
; (_HS_ResolveLiveToggle / _HS_TryLiveToggle) needs the menu and is covered by
; live testing.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Group Derivation =========
; =====================================
; =====================================

TestHSLT_DeriveStripsUnderscoresFromCategoryOnly() {
	AssertEqual("distancesreduction.qu",
		_HS_DeriveLiveToggleGroup("distances_reduction", "qu"),
		"category underscores are removed for the loader name")
	AssertEqual("sfbsreduction.comma",
		_HS_DeriveLiveToggleGroup("sfbs_reduction", "comma"))
	AssertEqual("autocorrection.errors",
		_HS_DeriveLiveToggleGroup("autocorrection", "errors"),
		"a category with no underscore is unchanged")
	AssertEqual("magickey.text_expansion_emojis",
		_HS_DeriveLiveToggleGroup("magic_key", "text_expansion_emojis"),
		"underscores in the SECTION id are preserved (only the category is stripped)")
}
Test("HSLT derive group strips underscores from the category only",
	TestHSLT_DeriveStripsUnderscoresFromCategoryOnly)





; =========================================
; =========================================
; ======= 2/ Whitelist Membership =========
; =========================================
; =========================================

TestHSLT_WhitelistAcceptsPureSections() {
	AssertTrue(_HS_IsLiveToggleGroup("autocorrection.errors"))
	AssertTrue(_HS_IsLiveToggleGroup("autocorrection.accents"))
	AssertTrue(_HS_IsLiveToggleGroup("rolls.hc"))
	AssertTrue(_HS_IsLiveToggleGroup("rolls.ct"))
	AssertTrue(_HS_IsLiveToggleGroup("sfbsreduction.comma"))
	AssertTrue(_HS_IsLiveToggleGroup("distancesreduction.qu"))
	AssertTrue(_HS_IsLiveToggleGroup("magickey.text_expansion_symbols_typst"))
}
Test("HSLT whitelist accepts pure LoadHotstringsSection sections",
	TestHSLT_WhitelistAcceptsPureSections)

TestHSLT_WhitelistRejectsInlineMixedAndDependencySections() {
	; Inline-generated (custom CreateHotstring, SpaceAroundSymbols) -> Reload.
	AssertFalse(_HS_IsLiveToggleGroup("rolls.assign"),
		"rolls.assign is inline-generated (SpaceAroundSymbols) and must reload")
	AssertFalse(_HS_IsLiveToggleGroup("rolls.not_equal"))
	AssertFalse(_HS_IsLiveToggleGroup("rolls.left_arrow"))
	AssertFalse(_HS_IsLiveToggleGroup("rolls.equal_string"))
	AssertFalse(_HS_IsLiveToggleGroup("rolls.english_negation"))

	; Mixed (LoadHotstringsSection + inline supplement) -> Reload.
	AssertFalse(_HS_IsLiveToggleGroup("autocorrection.typographic_apostrophe"),
		"typographic_apostrophe also registers inline y'<letter> guards -> reload")
	AssertFalse(_HS_IsLiveToggleGroup("autocorrection.caps"))
	AssertFalse(_HS_IsLiveToggleGroup("autocorrection.multiple_punctuation_marks"))

	; Dependency target: sfbs_reduction.bu reads magic_key.text_expansion at boot.
	AssertFalse(_HS_IsLiveToggleGroup("magickey.text_expansion"),
		"magic_key.text_expansion is a cross-feature dependency target -> reload")

	; Cross-dependent / inline sfbs sections.
	AssertFalse(_HS_IsLiveToggleGroup("sfbsreduction.bu"))
	AssertFalse(_HS_IsLiveToggleGroup("sfbsreduction.i_e_acute"))

	; Inline comma / deadkey sections.
	AssertFalse(_HS_IsLiveToggleGroup("distancesreduction.comma_j"))
	AssertFalse(_HS_IsLiveToggleGroup("distancesreduction.comma_far_letters"))
	AssertFalse(_HS_IsLiveToggleGroup("distancesreduction.dead_key_e_circumflex"))

	; Dynamic sections (fire-time values, inline, group "default") -> Reload.
	AssertFalse(_HS_IsLiveToggleGroup("dynamic.date_fr"))
	AssertFalse(_HS_IsLiveToggleGroup("dynamic.phone_prefixes"))

	; Garbage / unknown -> Reload.
	AssertFalse(_HS_IsLiveToggleGroup(""))
	AssertFalse(_HS_IsLiveToggleGroup("not.a.section"))
}
Test("HSLT whitelist rejects inline, mixed, and dependency-target sections",
	TestHSLT_WhitelistRejectsInlineMixedAndDependencySections)





; =====================================
; =====================================
; ======= 3/ Personal Detection =======
; =====================================
; =====================================

TestHSLT_PersonalDetection() {
	AssertTrue(_HS_IsPersonalLiveToggle("Personal.EmailShortcuts"))
	AssertTrue(_HS_IsPersonalLiveToggle("Personal.code"))
	AssertFalse(_HS_IsPersonalLiveToggle("Autocorrection.Errors"),
		"a bundled hotstring path is not a personal section")
	AssertFalse(_HS_IsPersonalLiveToggle("Personal"),
		"a bare 'Personal' with no section id is not a personal section toggle")
	AssertFalse(_HS_IsPersonalLiveToggle("Shortcuts.Personal.Foo"),
		"Shortcuts.Personal.* (3 segments) is a shortcut, not a hotstring section")
}
Test("HSLT personal section detection", TestHSLT_PersonalDetection)
