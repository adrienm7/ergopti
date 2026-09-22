; static/ergopti_plus/windows/tests/unit/test_menu_languages_and_global_separator.ahk

; ============================================================================
; MODULE: Hotstring Language Header And Global Actions Separator Tests
; DESCRIPTION:
; Two layout fixes to menus the three drivers render from the shared manifest.
; The language packs were one bare « Français (n) » row among the neutral
; categories, which users read as one more category and overlooked: they now
; sit under their own header, behind a separator, and carry their locale's flag
; (an icon here, since Win32 menus cannot render flag emoji). The cleanup of
; unused settings edits the configuration file while the rows above it switch
; features, so a separator now sets it apart.
; ============================================================================

; Index of the first manifest entry of ``Key`` whose ``Field`` equals ``Value``.
_MLG_IndexOf(Entries, Field, Value) {
	for Index, Entry in Entries {
		if (Entry.Get(Field, "") == Value)
			return Index
	}
	return 0
}

_MLG_LanguagesHaveTheirHeader() {
	Entries := _MM_GetManifestRoot()["hotstrings_menu"]
	At := _MLG_IndexOf(Entries, "id", "hotstring_languages")
	AssertTrue(At > 2, "hotstrings_menu must declare the language rows after other rows")
	AssertEqual("section_header", Entries[At - 1]["type"], "a header must precede the language rows")
	AssertEqual("menu.hotstrings.header_languages", Entries[At - 1]["i18n"])
	AssertEqual("---", Entries[At - 2]["type"], "and a separator must precede that header")
	AssertTrue(t("menu.hotstrings.header_languages") != "menu.hotstrings.header_languages",
		"the header must be translated")
}
Test("menu layout: the hotstring language rows sit under their own header (menu-languages-header)",
	_MLG_LanguagesHaveTheirHeader)

_MLG_LanguageRowCarriesItsFlag() {
	Path := I18nFlagIconPath("fr")
	AssertTrue(SubStr(Path, -StrLen("\img\flags\fr.png")) == "\img\flags\fr.png",
		"the French flag icon must be the one the language selector draws, got " . Path)
	AssertTrue(FileExist(Path) != "", "the French flag icon must ship at " . Path)
	AssertEqual("", I18nFlagIconPath("xx"), "a locale without a flag icon draws none")
	Body := _DriverFuncBody("_HS_LanguageRows")
	AssertTrue(Body != "", "_HS_LanguageRows must be found")
	AssertTrue(InStr(Body, '"icon",  I18nFlagIconPath(Pack["locale"])') > 0,
		"each language pack row must carry its locale's flag icon")
}
Test("menu layout: each hotstring language row carries its locale's flag (menu-languages-flag)",
	_MLG_LanguageRowCarriesItsFlag)

_MLG_CleanupIsSetApart() {
	Entries := _MM_GetManifestRoot()["global_actions"]
	At := _MLG_IndexOf(Entries, "id", "clean_unused_keys")
	AssertTrue(At > 1, "global_actions must declare the cleanup after the other actions")
	AssertEqual("---", Entries[At - 1]["type"], "a separator must precede the unused-settings cleanup")
}
Test("menu layout: a separator precedes the unused-settings cleanup (menu-global-separator)",
	_MLG_CleanupIsSetApart)
