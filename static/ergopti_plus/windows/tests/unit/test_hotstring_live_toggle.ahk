; static/ergopti_plus/windows/tests/unit/test_hotstring_live_toggle.ahk

; ==============================================================================
; MODULE: Hotstring Live-Toggle Classification Tests
; DESCRIPTION:
; Pins the inverted classification that decides which hotstring section toggles
; rebuild in-process (no Reload) versus which must Reload. After the
; RegisterAllHotstrings() wrap, the tray fast path (ui/tray_menu.ahk
; _HS_TryLiveToggle) treats EVERY hotstring section as live-eligible except the
; reload-only groups in the blocklist. These tests guard that the blocklist holds
; exactly those exceptions: a cross-dependent or inline section must never be
; wrongly forced onto the Reload path, and a native or layout-backed feature must
; never be wrongly toggled live.
;
; Only the pure, dependency-light helpers from
; infra/hotstrings/hotstring_live_toggle.ahk are exercised here - the tray glue
; (_HS_TryLiveToggle / _HS_ApplyLiveToggle / RebuildHotstringsLive) needs the
; menu and is covered by live testing.
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
; ======= 2/ Reload-Only Blocklist ========
; =========================================
; =========================================

TestHSLT_BlocklistPinsTheReloadOnlySections() {
	; The Ê deadkey and the "..." rule register via the native AHK Hotstring()
	; engine, skipped by the live rebuild -> they MUST Reload.
	AssertTrue(_HS_IsReloadOnlyGroup("distancesreduction.dead_key_e_circumflex"),
		"the deadkey is native-engine and must reload")
	AssertTrue(_HS_IsReloadOnlyGroup("autocorrection.multiple_punctuation_marks"),
		"the multiple-punctuation rule is native-engine and must reload")
	; magic_key.replace lives under "hotstrings.*" but is a LAYOUT remap (J -> star)
	; applied by modules/keymap/layout.ahk, so RegisterAllHotstrings never touches it.
	AssertTrue(_HS_IsReloadOnlyGroup("magickey.replace"),
		"the magic-key remap is a layout feature and must reload")
}
Test("HSLT blocklist pins the reload-only sections",
	TestHSLT_BlocklistPinsTheReloadOnlySections)

TestHSLT_BlocklistRejectsEverythingElse() {
	; Pure LoadHotstringsSection sections rebuild in-process -> not reload-only.
	AssertFalse(_HS_IsReloadOnlyGroup("autocorrection.errors"))
	AssertFalse(_HS_IsReloadOnlyGroup("autocorrection.accents"))
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.hc"))
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.ct"))
	AssertFalse(_HS_IsReloadOnlyGroup("sfbsreduction.comma"))
	AssertFalse(_HS_IsReloadOnlyGroup("distancesreduction.qu"))
	AssertFalse(_HS_IsReloadOnlyGroup("magickey.text_expansion_symbols_typst"))

	; The magic-key text-expansion sections ARE registered by RegisterAllHotstrings
	; (siblings of the reload-only magickey.replace), so they rebuild live.
	AssertFalse(_HS_IsReloadOnlyGroup("magickey.text_expansion"),
		"magic_key.text_expansion is a real hotstring section -> live")
	AssertFalse(_HS_IsReloadOnlyGroup("magickey.repeat_corrections"))

	; Previously Reload-only (inline / cross-dependent) sections are now live via
	; the in-process rebuild. Regression guard for the cut-over: re-running
	; RegisterAllHotstrings() re-evaluates their guards and recomputes
	; SpaceAroundSymbols.
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.assign"),
		"inline rolls operators rebuild in-process now")
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.not_equal"))
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.left_arrow"))
	AssertFalse(_HS_IsReloadOnlyGroup("rolls.equal_string"))
	AssertFalse(_HS_IsReloadOnlyGroup("autocorrection.typographic_apostrophe"))
	AssertFalse(_HS_IsReloadOnlyGroup("autocorrection.caps"))
	AssertFalse(_HS_IsReloadOnlyGroup("sfbsreduction.bu"))
	AssertFalse(_HS_IsReloadOnlyGroup("sfbsreduction.i_e_acute"))
	AssertFalse(_HS_IsReloadOnlyGroup("distancesreduction.comma_j"))
	AssertFalse(_HS_IsReloadOnlyGroup("distancesreduction.comma_far_letters"))
	AssertFalse(_HS_IsReloadOnlyGroup("dynamic.date_fr"))
	AssertFalse(_HS_IsReloadOnlyGroup("dynamic.phone_prefixes"))

	; Garbage / unknown -> not reload-only (the caller's manifest check rejects
	; these before the blocklist is consulted).
	AssertFalse(_HS_IsReloadOnlyGroup(""))
	AssertFalse(_HS_IsReloadOnlyGroup("not.a.section"))
}
Test("HSLT blocklist rejects every non-reload-only section",
	TestHSLT_BlocklistRejectsEverythingElse)





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
