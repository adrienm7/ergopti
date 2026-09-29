; static/ergopti_plus/windows/tests/unit/test_menu_languages_and_global_separator.ahk

; ============================================================================
; MODULE: Hotstring Language Header And Global Actions Separator Tests
; DESCRIPTION:
; Two layout fixes to menus the three drivers render from the shared manifest.
; The language packs were one bare « Français (n) » row among the neutral
; categories, which users read as one more category and overlooked: they now
; sit under their own header, behind a separator, and carry their locale's flag
; (an icon here, since Win32 menus cannot render flag emoji). The Configuration
; submenu draws the two rows that rewrite the configuration, a separator, then
; the rows that open a window and login startup, and ends there: Uninstall
; closes the Version / Updates submenu, after a separator, since 2026-09.
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

; The rows of one manifest menu, ids and separators, joined in order.
_MLG_Order(MenuName) {
	Order := ""
	for _, Entry in _MM_GetManifestRoot()[MenuName]
		Order .= (Order == "" ? "" : ", ") . (Entry.Get("type", "") == "---" ? "---" : Entry["id"])
	return Order
}

; The Configuration submenu: the two rows that rewrite the configuration, a
; separator, then configuration windows and login startup, with no separator
; left dangling at its end.
_MLG_ConfigurationRowsInOrder() {
	AssertEqual("restore_recommended, clean_unused_keys, ---, config_folder, setup_wizard, start_at_login",
		_MLG_Order("configuration_menu"), "configuration_menu must declare its rows in this order")
	Body := _DriverFuncBody("_MI_BuildConfigurationMenu")
	Assert(Body != "", "the Configuration builder must exist before checking its commands")
	; Global Restore now composes every persistence owner at its terminal boundary.
	AssertContains(Body, "Commands := _MI_GlobalScopeCommands()",
		"the real Configuration menu must retain the global command factory")
	Commands := _MI_GlobalScopeCommands()
	AssertTrue(Commands.Has("restore_recommended") && Commands["restore_recommended"] is Func,
		"the global owner must expose the existing Restore command")
	for _, Pair in [["clean_unused_keys", "ShowUnusedConfigKeysCleanup"],
			["config_folder", "FilePathsEditor"],
			["setup_wizard", "Onboarding_ShowFromMenu"],
			["start_at_login", "ToggleStartAtLogin"]]
		AssertTrue(RegExMatch(Body, '"' . Pair[1] . '",\s+' . Pair[2]) > 0,
			"the Configuration menu must dispatch " . Pair[1] . " to " . Pair[2])
	AssertEqual(0, InStr(Body, "ShowUninstallErgopti"), "Configuration no longer offers Uninstall")
}
Test("menu layout: the Configuration rows rewrite first, then open windows (menu-configuration)",
	_MLG_ConfigurationRowsInOrder)

; Uninstall closes the Version / Updates submenu, after a separator, and keeps
; its label key and its action owner.
_MLG_UninstallClosesTheAboutMenu() {
	AssertEqual("about_updates, ---, about_changelog, about_releases_page, ---, uninstall",
		_MLG_Order("about_menu"), "about_menu must end with a separator and Uninstall")
	Entries := _MM_GetManifestRoot()["about_menu"]
	AssertEqual("menu.global.uninstall", Entries[Entries.Length]["i18n"], "Uninstall keeps its label key")
	Body := _DriverFuncBody("_MI_BuildAboutMenu")
	Assert(Body != "", "the About builder must exist before checking its commands")
	AssertTrue(RegExMatch(Body, '"uninstall",\s+ShowUninstallErgopti') > 0,
		"the About menu must dispatch uninstall to ShowUninstallErgopti")
}
Test("menu layout: Uninstall closes the Version / Updates submenu (menu-about-uninstall)",
	_MLG_UninstallClosesTheAboutMenu)
