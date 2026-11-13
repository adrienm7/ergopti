; static/ergopti_plus/windows/tests/unit/ui/menu/test_menu_languages_and_global_separator.ahk

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
; Version / Updates submenu, after a separator, since 2026-09. The Debug
; submenu opens with its user-facing rows and closes with one Tests submenu.
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

; The rows of one manifest menu, ids, separators and section headers (which
; carry no id), joined in order.
_MLG_Order(MenuName) {
	Order := ""
	for _, Entry in _MM_GetManifestRoot()[MenuName] {
		Kind := Entry.Get("type", "")
		Order .= (Order == "" ? "" : ", ") . (Kind == "---" ? "---"
			: Kind == "section_header" && !Entry.Has("id") ? "header " . Entry["i18n"] : Entry["id"])
	}
	return Order
}

; The Configuration submenu: the global restore and clear, a separator, the
; cleanup, a separator, then configuration windows, then a separator and the
; download proxy (moved from Debug on 2026-11-03), with no separator left
; dangling at its end. The Windows-only touchpad restore was merged into the
; Gestures clear (2026-11-03). The macOS-only Karabiner rows left with the owned
; runtime default (ADR 011).
_MLG_ConfigurationRowsInOrder() {
	AssertEqual("scope_restore, scope_clear, ---, clean_unused_keys, ---, config_folder, "
		. "setup_wizard, ---, proxy_override",
		_MLG_Order("configuration_menu"), "configuration_menu must declare its rows in this order")
	; The download proxy is configuration, not debugging (maintainer, 2026-11-03).
	AssertFalse(InStr(_MLG_Order("debug_menu"), "proxy_override"), "Debug no longer declares the proxy row")
	AssertEqual(0, InStr(_DriverFuncBody("_MI_BuildDebuggingMenu"), "ProxyOverride_Command"),
		"Debug no longer dispatches the proxy row")
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
			["proxy_override", "ProxyOverride_Command"]]
		AssertTrue(RegExMatch(Body, '"' . Pair[1] . '",\s+' . Pair[2]) > 0,
			"the Configuration menu must dispatch " . Pair[1] . " to " . Pair[2])
	AssertEqual(0, InStr(Body, "ShowUninstallErgopti"), "Configuration no longer offers Uninstall")
	AssertEqual(0, InStr(Body, "start_at_login"), "Configuration no longer offers login startup")
}
Test("menu layout: the Configuration rows rewrite first, then open windows (menu-configuration)",
	_MLG_ConfigurationRowsInOrder)

; Runs Body under one shipped locale, then restores the translation cache.
_MLG_WithLocale(Code, Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	HadCache := IsSet(_I18nCache), OldCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), OldLoaded := HadLoaded ? _I18nCacheLoaded : false
	try {
		_I18nCache := JsonParse(FileRead(_SharedDir . "\core\i18n\data\locales\" . Code . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		Body.Call()
	} finally {
		if HadCache
			_I18nCache := OldCache
		else
			_I18nCache := unset
		if HadLoaded
			_I18nCacheLoaded := OldLoaded
		else
			_I18nCacheLoaded := unset
	}
}

; The shared corpus captions the Configuration parent and its rows in English
; and French ("-" is a separator); the real Windows builder draws them.
_MLG_ConfigurationCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\configuration_parent.json", "UTF-8"))
	for _, Code in ["en", "fr"] {
		AssertTrue(Corpus.Has(Code), "the corpus captions the " . Code . " Configuration parent")
		_MLG_WithLocale(Code, _MLG_CheckConfigurationCorpus.Bind(Code, Corpus[Code]))
	}
}

_MLG_CheckConfigurationCorpus(Code, Expected) {
	AssertEqual(Expected["parent"], t("menu.configuration.title"), Code . ": the parent caption _MI_StageConfiguration adds")
	Built := _MI_BuildConfigurationMenu()
	try {
		Labels := _MLG_NativeLabels(Built)
		AssertEqual(Expected["children"].Length, Labels.Length, Code . ": one native row per corpus row")
		; The corpus holds the visible caption; a native menu stores each literal
		; "&" doubled (manifest_menu.ahk), the renderer's own encoding.
		for Position, Caption in Expected["children"]
			AssertEqual(Caption == "-" ? "" : StrReplace(Caption, "&", "&&"), Labels[Position],
				Code . ": Configuration row " . Position)
	} finally _CTC_ReleaseMenu(Built)
}
Test("menu layout: the Configuration parent and rows keep their corpus captions (configuration-parent)",
	_MLG_ConfigurationCorpus)

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

; The zero-based position of the first native row whose text starts with a
; translated caption, or -1.
_MLG_RowStarting(TargetMenu, Key) {
	Caption := t(Key)
	loop TrayMenuItemCount(TargetMenu) {
		if InStr(_CTC_LabelAt(TargetMenu, A_Index - 1), Caption, true) == 1
			return A_Index - 1
	}
	return -1
}

; The texts of every native row, a separator reading as an empty text.
_MLG_NativeLabels(TargetMenu) {
	Labels := []
	loop TrayMenuItemCount(TargetMenu)
		Labels.Push(_CTC_LabelAt(TargetMenu, A_Index - 1))
	return Labels
}

; Refuses a separator that leads, trails or follows another one.
_MLG_AssertCleanSeparators(Labels, State) {
	AssertTrue(Labels.Length > 0, State . ": rows are drawn")
	AssertTrue(Labels[1] != "", State . ": no leading separator")
	AssertTrue(Labels[Labels.Length] != "", State . ": no trailing separator")
	for Position, Label in Labels
		AssertFalse(Position > 1 && Label == "" && Labels[Position - 1] == "",
			State . ": two separators in a row at " . Position)
}

; debug-tests-submenu (maintainer, 2026-11-03): the built Debug menu shows the
; user-facing rows first (diagnostics, report a bug, suggest a feature, then the
; logs), and one « Tests » submenu, after a separator, closes it with every
; Windows check and probe in topic order; none of them stays among the rows.
_MLG_DebugTestsCloseTheMenu() {
	Built := _MI_BuildDebuggingMenu()
	try {
		Labels := _MLG_NativeLabels(Built)
		_MLG_AssertCleanSeparators(Labels, "Debug")
		Diagnostics := _MLG_RowStarting(Built, "menu.debug.healthcheck")
		Report := _MLG_RowStarting(Built, "menu.debug.report_bug")
		Suggest := _MLG_RowStarting(Built, "menu.debug.suggest_feature")
		Logs := _MLG_RowStarting(Built, "menu.debug.log_level")
		AssertTrue(Diagnostics >= 0 && Diagnostics < Report && Report < Suggest && Suggest < Logs,
			"diagnostics, report and suggest come first, then the logs: " . Diagnostics . " " . Report
			. " " . Suggest . " " . Logs)
		Last := TrayMenuItemCount(Built) - 1
		AssertEqual(t("menu.debug.tests"), Labels[Last + 1], "the Tests submenu closes Debug")
		AssertEqual("", Labels[Last], "one separator sets Tests apart")
		Child := DllCall("GetSubMenu", "ptr", Built.Handle, "int", Last, "ptr")
		AssertTrue(Child != 0, "Tests opens a submenu")
		Tests := _MLG_NativeLabels(MenuFromHandle(Child))
		_MLG_AssertCleanSeparators(Tests, "Tests")
		Keys := ["menu.debug.field_check_network", "menu.debug.composer_check",
			"menu.debug.send_probe", "menu.debug.hook_probe"]
		AssertEqual(Keys.Length, Tests.Length, "Tests holds the four Windows checks")
		for Position, Key in Keys {
			AssertEqual(t(Key), Tests[Position], "Tests keeps the topic order at " . Position)
			AssertEqual(-1, _MLG_RowStarting(Built, Key), "no check stays among the Debug rows: " . Key)
		}
	} finally _CTC_ReleaseMenu(Built)
}
Test("menu layout: the user-facing Debug rows come first and Tests closes the menu (debug-tests-submenu)",
	_MLG_DebugTestsCloseTheMenu)

; With no check for Windows, Debug draws no empty Tests submenu and leaves no
; separator behind it.
_MLG_DebugDrawsNoEmptyTests() {
	Root := _MR_GetManifestRoot()
	Saved := Root["debug_tests_menu"]
	Root["debug_tests_menu"] := []
	try {
		Built := _MI_BuildDebuggingMenu()
		try {
			Labels := _MLG_NativeLabels(Built)
			_MLG_AssertCleanSeparators(Labels, "Debug without a check")
			AssertEqual(-1, _MLG_RowStarting(Built, "menu.debug.tests"), "no Tests row without a check")
		} finally _CTC_ReleaseMenu(Built)
	} finally Root["debug_tests_menu"] := Saved
}
Test("menu layout: Debug draws no empty Tests submenu (debug-tests-submenu-empty)",
	_MLG_DebugDrawsNoEmptyTests)

; The shared corpus captions the Debug parent and its closing Tests submenu in
; English and French; its row lists belong to macOS and Linux, whose Debug
; rows differ from the Windows ones by declaration.
_MLG_DebugCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\debug_parent.json", "UTF-8"))
	for _, Code in ["en", "fr"] {
		AssertTrue(Corpus.Has(Code), "the corpus captions the " . Code . " Debug parent")
		_MLG_WithLocale(Code, _MLG_CheckDebugCorpus.Bind(Code, Corpus[Code]))
	}
}

_MLG_CheckDebugCorpus(Code, Expected) {
	AssertEqual(Expected["parent"], t("menu.debug.title"), Code . ": the parent caption _MI_StageDebug adds")
	Built := _MI_BuildDebuggingMenu()
	try {
		Labels := _MLG_NativeLabels(Built)
		AssertEqual(Expected["tests"], Labels[Labels.Length], Code . ": the Tests submenu closes Debug")
	} finally _CTC_ReleaseMenu(Built)
}
Test("menu layout: the Debug parent and its Tests submenu keep their corpus captions (debug-parent)",
	_MLG_DebugCorpus)

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
