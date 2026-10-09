; static/ergopti_plus/windows/tests/unit/test_menu_languages_and_global_separator.ahk

; ============================================================================
; MODULE: Hotstring Language Header And Global Actions Separator Tests
; DESCRIPTION:
; Two layout fixes to menus the three drivers render from the shared manifest.
; The language packs were one bare « Français (n) » row among the neutral
; categories, which users read as one more category and overlooked: they now
; sit under their own header, behind a separator, and carry their locale's flag
; (an icon here, since Win32 menus cannot render flag emoji). The Configuration
; submenu opens with the global restore and clear (the first group of every
; settings menu), a separator, the cleanup, a separator, then the rows that
; open a window, and ends there: startup precedes Uninstall in the
; Version / Updates submenu, after a separator, since 2026-09.
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
	global SubMenus, _FmtCountCache, _I18nFlagExistsCache
	SavedMenus := IsSet(SubMenus) ? SubMenus : unset
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedFlags := IsSet(_I18nFlagExistsCache) ? _I18nFlagExistsCache : unset
	try {
		SubMenus := Map(), _FmtCountCache := Map(), _I18nFlagExistsCache := Map()
		Path := I18nFlagIconPath("fr")
		AssertTrue(SubStr(Path, -StrLen("\img\flags\fr.bmp")) == "\img\flags\fr.bmp",
			"the French flag icon must be the one the language selector draws, got " . Path)
		AssertTrue(FileExist(Path) != "", "the French flag icon must ship at " . Path)
		AssertEqual("", I18nFlagIconPath("xx"), "a locale without a flag icon draws none")
		Body := _DriverFuncBody("_HS_LanguageRows")
		AssertTrue(Body != "", "_HS_LanguageRows must be found")
		; Empty category menus avoid borrowing native category/count ownership;
		; the real language switch and declared parent still render for every pack.
		Packs := HotstringsLanguageCategories()
		AssertTrue(Packs is Array && Packs.Length > 0, "the declared language packs must be present")
		Rows := _HS_LanguageRows()
		AssertTrue(Rows is Array, "the real language provider must return rows")
		AssertEqual(Packs.Length, Rows.Length, "every declared language pack must render one parent")
		for Index, Pack in Packs {
			Row := Rows[Index]
			AssertTrue(Row is Map, "each declared language parent must be a row")
			AssertEqual(HotstringsLanguageName(Pack["locale"]) . " (" . FmtCount(0) . ")",
				Row.Get("label", ""), "the parent must belong to the corresponding locale")
			ExpectedIcon := I18nFlagIconPath(Pack["locale"])
			AssertTrue(ExpectedIcon != "" && FileExist(ExpectedIcon) != "",
				"each declared language pack must ship its locale's flag icon")
			AssertTrue(Row.Has("icon") && Type(Row["icon"]) == "String",
				"each language pack row must carry its locale's flag icon")
			AssertEqual(ExpectedIcon, Row["icon"],
				"the real language row must carry its own locale's flag icon")
		}
	} finally {
		SubMenus := IsSet(SavedMenus) ? SavedMenus : unset
		_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
		_I18nFlagExistsCache := IsSet(SavedFlags) ? SavedFlags : unset
	}
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

; The Configuration submenu: the global restore and clear, a separator, the
; cleanup and, right under it, the Windows-only touchpad restore (the
; maintainer's request of 2026-10-02: it stood at the very end), a separator,
; then configuration windows and the macOS-only Karabiner rows,
; with no separator left dangling at its end.
_MLG_ConfigurationRowsInOrder() {
	AssertEqual("scope_restore, scope_clear, ---, clean_unused_keys, restore_touchpad_gestures, ---, config_folder, "
		. "setup_wizard, karabiner_integration, remove_from_karabiner",
		_MLG_Order("configuration_menu"), "configuration_menu must declare its rows in this order")
	Body := _DriverFuncBody("_MI_BuildConfigurationMenu")
	Assert(Body != "", "the Configuration builder must exist before checking its commands")
	; Global Restore now composes every persistence owner at its terminal boundary.
	AssertContains(Body, "Commands := _MI_GlobalScopeCommands()",
		"the real Configuration menu must retain the global command factory")
	Commands := _MI_GlobalScopeCommands()
	for _, Id in ["scope_restore", "scope_clear"]
		AssertTrue(Commands.Has(Id) && Commands[Id] is Func,
			"the global owner must expose the " . Id . " command")
	for _, Pair in [["clean_unused_keys", "ShowUnusedConfigKeysCleanup"],
			["config_folder", "FilePathsEditor"],
			["setup_wizard", "Onboarding_ShowFromMenu"],
			["restore_touchpad_gestures", "TouchpadRegistryRestoreFromMenu"]]
		AssertTrue(RegExMatch(Body, '"' . Pair[1] . '",\s+' . Pair[2]) > 0,
			"the Configuration menu must dispatch " . Pair[1] . " to " . Pair[2])
	AssertEqual(0, InStr(Body, "ShowUninstallErgopti"), "Configuration no longer offers Uninstall")
	AssertEqual(0, InStr(Body, "start_at_login"), "Configuration no longer offers login startup")
}
Test("menu layout: the Configuration rows rewrite first, then open windows (menu-configuration)",
	_MLG_ConfigurationRowsInOrder)

; Versions, Configuration, then Language at the top level, and « Afficher une
; fenêtre à chaque erreur » right under « Diagnostic système » in Debug (the
; maintainer's requests of 2026-10-02).
_MLG_RowsFollowTheRequestedOrder() {
	TopLevel := ", " . _MLG_Order("top_level") . ", "
	Assert(InStr(TopLevel, ", about, configuration, language, ") > 0,
		"the top level must list Versions, Configuration, then Language: " . TopLevel)
	Debug := ", " . _MLG_Order("debug_menu") . ", "
	Assert(InStr(Debug, ", healthcheck, show_error_dialog, ") > 0,
		"the error-window switch must follow the system diagnostics row: " . Debug)
}
Test("menu layout: Versions, Configuration, Language; the error window under the diagnostics (menu-order-2026-10-02)",
	_MLG_RowsFollowTheRequestedOrder)

; Uninstall closes the Version / Updates submenu, after a separator, and keeps
; its label key and its action owner.
_MLG_UninstallClosesTheAboutMenu() {
	AssertEqual("about_updates, ---, about_changelog, about_releases_page, ---, start_at_login, uninstall",
		_MLG_Order("about_menu"), "about_menu must end with startup immediately above Uninstall")
	Entries := _MM_GetManifestRoot()["about_menu"]
	AssertEqual("menu.global.uninstall", Entries[Entries.Length]["i18n"], "Uninstall keeps its label key")
	Body := _DriverFuncBody("_MI_BuildAboutMenu")
	Assert(Body != "", "the About builder must exist before checking its commands")
	AssertTrue(RegExMatch(Body, '"uninstall",\s+ShowUninstallErgopti') > 0,
		"the About menu must dispatch uninstall to ShowUninstallErgopti")
}
Test("menu layout: Uninstall closes the Version / Updates submenu (menu-about-uninstall)",
	_MLG_UninstallClosesTheAboutMenu)

; Native labels, checked state and callbacks come from the unchanged startup owner.
_MLG_StartupRecord(State, *) {
	State.Calls += 1
	State.Enabled := !State.Enabled
}

_MLG_StartupPrecedesUninstall() {
	global _MenuDispatchCallbacks
	Body := _DriverFuncBody("_MI_BuildAboutMenu")
	Assert(Body != "", "the About builder must exist before checking its owner")
	AssertContains(Body, "StartupCommand := ToggleStartAtLogin", "the default command remains the native owner")
	AssertContains(Body, "StartupState := StartAtLoginEnabled", "the default state remains the native owner")
	for _, Enabled in [false, true] {
		State := { Enabled: Enabled, Calls: 0 }
		Built := _MI_BuildAboutMenu(_MLG_StartupRecord.Bind(State), () => State.Enabled)
		try {
			Count := TrayMenuItemCount(Built)
			AssertTrue(Count >= 3, "the installation group must be drawn")
			Position := Count - 2
			AssertEqual(t("menu.global.start_at_login"), _CTC_LabelAt(Built, Position),
				"startup sits immediately above Uninstall")
			AssertEqual(Enabled, _CTC_IsChecked(Built, Position), "the native owner supplies the checkmark")
			AssertEqual(0, State.Calls, "building the menu never changes startup")
			Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
			AssertTrue(_MenuDispatchCallbacks.Has(Id), "the startup row retains its dispatcher callback")
			_MenuDispatchCallbacks[Id].Call("", Position + 1, Built)
			AssertEqual(1, State.Calls, "the row invokes its startup owner once")
			AssertEqual(!Enabled, State.Enabled, "the owner toggles the requested state")
		} finally _CTC_ReleaseMenu(Built)
		Rebuilt := _MI_BuildAboutMenu(_MLG_StartupRecord.Bind(State), () => State.Enabled)
		try AssertEqual(!Enabled, _CTC_IsChecked(Rebuilt, TrayMenuItemCount(Rebuilt) - 2),
			"the next build reads the owner's acknowledged state")
		finally _CTC_ReleaseMenu(Rebuilt)
	}
}
Test("menu layout: startup immediately precedes Uninstall and reads its native owner (menu-startup-placement)",
	_MLG_StartupPrecedesUninstall)
