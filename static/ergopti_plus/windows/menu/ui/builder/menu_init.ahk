; menu/ui/builder/menu_init.ahk

; ==============================================================================
; MODULE: Tray Menu / Main Builder
; DESCRIPTION:
; The top-level initMenu orchestrator plus the personal-shortcuts and language submenu builders it appends. Assembles the whole tray context menu from the category builders.
;
; Split out of menu/ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================

; The generated menu-command constants; #Include skips a file the entry script
; already loaded.
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk




; Collect runtime-registered personal shortcut DATA without a native destination.
; Literal zero means absent registry; a present empty child Array remains valid.
; The central declared frame receiver owns separator and group rendering. Reads from the
; ``_PersonalShortcutsRegistry`` global populated by RegisterPersonalFeature
; so no Features v1 Map access is required.
_PersonalShortcutRows() {
	global _PersonalShortcutsRegistry
	if !_PersonalShortcutsRegistry.Has("__Order") {
		return 0
	}
	Names := _PersonalShortcutsRegistry["__Order"]
	if (Names.Length == 0) {
		return 0
	}

	; One nested row per registered personal shortcut, drawn by the renderer.
	PersonalRows := []
	for _, Name in Names {
		; Label comes straight from the registry (the description, or the name
		; itself when none); the v2 path keys the lowercased name under
		; [shortcuts.personal]. Names are already lowercased at registration.
		Desc  := _PersonalShortcutsRegistry.Has(Name) ? _PersonalShortcutsRegistry[Name] : ""
		Label := (Desc != "") ? Desc : Name
		Row := MenuRowWithLabel("shortcuts.personal." . Name, Label, "Shortcuts")
		if (Row != "") {
			PersonalRows.Push(Row)
		}
	}
	return PersonalRows
}


; Post-"ready" population of the 21-locale language submenu — the ~156 ms (Win32
; menu-item registration + flag-icon loads) the boot pass skips. Armed once via a
; one-shot SetTimer from ErgoptiPlus.ahk; the live-rebuild path populates inline.
; Wrapped in try so a transient failure can never crash the timer thread.
BuildLanguageMenuDeferred() {
	global A_TrayMenu, _LangMenuRef, _LangMenuBuildPending, _I18nLocale
	static ReplacementOwner := MenuRenderer_GroupReplacement, BuilderOwner := I18nBuildLanguageMenu
	OwnersLive() {
		return ReplacementOwner == MenuRenderer_GroupReplacement && BuilderOwner == I18nBuildLanguageMenu
			&& !Object.Prototype.HasOwnProp.Call(ReplacementOwner, "Call")
			&& !Object.Prototype.HasOwnProp.Call(BuilderOwner, "Call")
	}
	try {
		if !OwnersLive() || !_LangMenuBuildPending
			return false
		Destination := A_TrayMenu, PreviousChild := _LangMenuRef, Locale := _I18nLocale
		Publish := ReplacementOwner.Call(Destination, "top_level", "language", PreviousChild)
		if !OwnersLive() || !HasMethod(Publish, "Call") || Object.Prototype.HasOwnProp.Call(Publish, "Call")
			throw Error("Declared deferred language parent was refused.")
		; Capture the current parent before the actual locale builder can yield.
		StagedMenu := Menu()
		BuilderOwner.Call(StagedMenu)
		_PublishCritical := Critical("On")
		try {
			if !OwnersLive() || A_TrayMenu != Destination || _LangMenuRef != PreviousChild
				|| !_LangMenuBuildPending || _I18nLocale != Locale || Object.Prototype.HasOwnProp.Call(Publish, "Call")
				|| !Publish.Call(StagedMenu)
				throw Error("Declared deferred language parent was withdrawn.")
			_LangMenuRef := StagedMenu
			_LangMenuBuildPending := false
		} finally {
			Critical(_PublishCritical)
		}
		return true
	} catch as e {
		try LoggerError("TrayMenu", "Deferred language-menu build failed: {1}", e.Message)
		return false
	}
}


initMenu(PublishAuthorizeFn := 0, GlobalsOnly := false, PrebuiltLlm := unset) {
	global _TrayTitleCache, _FmtCountCache, _I18nSortedLocalesCache, _LLM_Menu_Handle
	Builders := _MI_TopLevelBuilders()
	if IsSet(PrebuiltLlm) {
		if GlobalsOnly || !(PrebuiltLlm is Menu) || _LLM_Menu_Handle != PrebuiltLlm
			throw Error("The caller-owned AI submenu cannot enter this root projection.")
		; This invocation owns the detached child; default boot/root builders
		; retain their original initialization and construction path.
		Builders["llm"] := _MI_StagePrebuiltLlm.Bind(PrebuiltLlm)
	}
	TrayMenuStage_Begin()
	try {
	_TrayTitleCache := Map()
	_FmtCountCache := Map()
	_I18nSortedLocalesCache := false
	_HS_InvalidateCaches()
	MenuManifest_InvalidateCache()

	BootProfile_Mark("MENU/initMenu: caches reset + tray staged")

	; Every top-level row, separators included, in the order the manifest's
	; top_level declares for this platform. The feature rows used to be a fixed
	; sequence of calls here, compared with the manifest by a log line only, ahead
	; of a tail read from the manifest — so the declared order reached half of
	; the tray, and a reordered top level changed the other two drivers alone.
	if GlobalsOnly {
		_MI_StageTopLevel(MenuManifest_LoadTopLevel(), Builders,
			(Entry) => !Entry.Get("greyed_when_paused", false))
	} else
		_MI_StageTopLevel(MenuManifest_LoadTopLevel(), Builders)
	BootProfile_Mark("MENU/initMenu: top level staged")
	Published := TrayMenuStage_Publish(PublishAuthorizeFn)
	return Published
	} catch as e {
		TrayMenuStage_Abort()
		throw e
	}
}


; One builder per top-level id; each stages its own row. WHERE the row lands is
; decided by _MI_StageTopLevel from the manifest, never by this table's order.
; The drift gate and tools/test/test-menu-top-level-parity.cjs hold these keys
; to the ids the manifest declares for this platform, in both directions.
_MI_TopLevelBuilders() {
	return Map(
		"keyboard_layout", _MI_StageLayout,
		"hotstrings",      _MI_StageHotstrings,
		"llm",             _MI_StageLlm,
		"agent",           _MI_StageAgent,
		"metrics",         _MI_StageMetrics,
		"shortcuts",       _MI_StageShortcuts,
		ConfigLeaf.TAP_HOLDS,       _MI_StageTapHolds,
		"gestures",        _MI_StageGestures,
		"apps",            _MI_StageApps,
		"configuration",   _MI_StageConfiguration,
		"language",        _MI_StageLanguage,
		"about",           _MI_StageAbout,
		"suspend",         _MI_StageSuspend,
		"reload",          _MI_StageReload,
		"quit",            _MI_StageQuit,
		"debug",           _MI_StageDebug
	)
}


; Stages every row of TopLevel visible on this platform through its builder,
; in the array's order. A separator is staged only between two staged rows, so
; a row filtered out for this platform never leaves two in a row or one at
; either end. A declared id with no builder is a row the user was promised and
; will not see: it is reported, and the rest of the root still builds.
; @param TopLevel {Array} The manifest's top_level rows.
; @param Builders {Map} Id → builder that stages the row.
; @param IncludeFn {Func} Optional projection filter for manifest rows.
; @returns {Integer} How many rows were dispatched.
_MI_StageTopLevel(TopLevel, Builders, IncludeFn := 0) {
	Dispatched := 0
	SeparatorPending := false
	for _, Entry in TopLevel {
		if !(Entry is Map) || !Entry.Has("id")
			continue
		if HasMethod(IncludeFn, "Call") && !IncludeFn.Call(Entry)
			continue
		Id := Entry["id"]
		if (Id == "---") {
			SeparatorPending := (Dispatched > 0)
			continue
		}
		if !_MR_IsForAhk(Entry)
			continue
		if !Builders.Has(Id) {
			try LoggerError("Menu", "No builder for top-level row '{1}' — the entry is missing.", Id)
			continue
		}
		if SeparatorPending {
			TrayMenuStage_Add()
			SeparatorPending := false
		}
		BootProfile_StageBegin("menu row " . Id)
		try {
			if Entry.Get("disabled", false)
				MenuRenderer_StageDisabledTopLevel(Entry)
			else
				Builders[Id].Call()
			BootProfile_StageEnd("menu row " . Id)
		} catch as Err {
			BootProfile_StageAbort("menu row " . Id, ErrorNet_Describe(Err))
			throw Err
		}
		Dispatched += 1
	}
	return Dispatched
}


; ── 🌐 Disposition clavier — built from manifest via MenuRenderer_Build.
; The two feature blocks are `list` providers: each names its layout feature
; and returns its row, which the renderer materialises.
; ``active_layouts`` lists the layouts installed for the user (_LAY_ActiveLayoutRows);
; ``layout_system_install`` installs the Ergopti system layout (SystemLayout_MenuRows).
_MI_StageLayout() {
	Receiver := MenuRenderer_GroupReceiver("top_level", "keyboard_layout")
	if !Receiver
		throw Error("The declared keyboard_layout feature parent was refused before native construction.")
	LayoutListProviders := Map(
		"number_row_policy",      (*) => _LAY_NumberRowRows(),
		"custom_layouts",         (*) => _LAY_CustomLayoutRows(),
		"layout_emulation",       (*) => _LAY_EmulationChoiceRows(),
		"layout_features_base",   (*) => _LAY_LayoutFeatureBaseRows(),
		"layout_features_altgr",  (*) => _LAY_LayoutFeatureAltGrRows(),
		ConfigLeaf.MAGIC_KEY_SOURCE,       (*) => MagicKeySourceMenuRows(),
		"layout_switching",       (*) => PauseLayoutSwitch_MenuRows(),
		"active_layouts",         (*) => _LAY_ActiveLayoutRows(),
		"layout_system_install",  (*) => SystemLayout_MenuRows(),
	)
	; The accented-letter group stays enabled without the Ergopti emulation: the
	; shortcuts then follow the user's own layout (accented_shortcuts.ahk).
	; The emulated-row switches are the manifest's layout_emulated_rows_group.
	LayoutGroupBuilders := Map("layout_emulated_rows", () => MenuRenderer_Build("layout_emulated_rows_group", "Layout",
		"", "", "", _LAY_ScopeCommands(), Map("layout_enabled", () => IsCategoryGated("Layout"))))
	LayoutMenu  := MenuDeferOrBuild((Target) => MenuRenderer_Build("layout_menu", "Layout", "", LayoutGroupBuilders,
		LayoutListProviders, _LAY_ScopeCommands(),
		Map("layout_enabled", () => IsCategoryGated("Layout")), Target), "layout_menu")
	_MI_StageDeclaredFeature(Receiver, LayoutMenu, Map("layout_enabled", () => IsCategoryGated("Layout")), true)
	BootProfile_Mark("MENU/initMenu: layout built+added")
}


; ── Hotstrings ⚡ — built from manifest via MenuRenderer_Build.
; Dynamic handlers supply the runtime-dependent blocks (params, categories,
; personal tree, extensions). The switch is the manifest's hotstrings_toggle
; row: the Hotstrings master gate, which leaves every category as it is.
_MI_StageHotstrings() {
	Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
	if !Receiver
		throw Error("The declared hotstrings feature parent was refused before native construction.")
	HotstringsAllEnabled := IsCategoryGated("Hotstrings")

	; Empty since 2026-08-07: every row of the hotstrings tree is declarative or a
	; list provider now. Kept as a Map rather than removed so the renderer's
	; handler argument stays a Map and a future `dynamic` row has somewhere to go.
	_HotDynHandlers := Map()

	; repeat_key left _HotDynHandlers: its manifest row is `type = "check"` now,
	; so the renderer draws the row, its label and its tick from the declaration
	; and this driver supplies only the toggle and the state behind the tick. It
	; was three copies of one checkbox before that, one per driver.
	_HotParamCommands := Map(
		MenuCommand.REPEAT_KEY, ToggleRepeatKeyEnabled,
		; The word-reset rows: the idle choice is called with the chosen seconds,
		; its free entry and the click checkbox with the native menu arguments,
		; which the seams of these commands must never receive.
		MenuCommand.IDLE_RESET, (Seconds) => SetHotstringsIdleResetSeconds(Seconds),
		"idle_reset_custom", (*) => PromptHotstringsIdleResetSeconds(),
		MenuCommand.CASCADE_MAX_ARROWS, (Arrows) => SetHotstringsCascadeMaxArrows(Arrows),
		ConfigLeaf.CLICK_RESETS_WORD, (*) => ToggleHotstringsClickResetsWord(),
		ConfigLeaf.ARROW_RESETS_WORD, (*) => ToggleHotstringsWordResetFlag(ConfigLeaf.ARROW_RESETS_WORD),
		ConfigLeaf.SHORTCUT_RESETS_WORD, (*) => ToggleHotstringsWordResetFlag(ConfigLeaf.SHORTCUT_RESETS_WORD),
		ConfigLeaf.TAP_HOLD_RESETS_WORD, (*) => ToggleHotstringsWordResetFlag(ConfigLeaf.TAP_HOLD_RESETS_WORD),
	)
	_HotParamGetters := Map(
		"hotstrings_repeat_enabled", () => ReadFeatureStateV2(ConfigKey.HOTSTRINGS_REPEAT_KEY_ENABLED).Get("enabled", false),
		ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS, () => HSE_IdleResetSecondsCurrent(),
		ConfigKey.HOTSTRINGS_CASCADE_MAX_ARROWS, () => HSE_CascadeMaxArrowsCurrent(),
		"hotstrings_click_resets_word", () => HSE_ClickResetsWordCurrent(),
		"hotstrings_arrow_resets_word", () => HSE_WordResetFlagCurrent(ConfigLeaf.ARROW_RESETS_WORD),
		"hotstrings_shortcut_resets_word", () => HSE_WordResetFlagCurrent(ConfigLeaf.SHORTCUT_RESETS_WORD),
		"hotstrings_tap_hold_resets_word", () => HSE_WordResetFlagCurrent(ConfigLeaf.TAP_HOLD_RESETS_WORD),
	)

	; word_expanders left _HotDynHandlers: its manifest row is `type = "list"`
	; now, so the renderer materialises every row of the submenu from the data
	; the provider returns instead of the driver building a Menu object.
	_HotListProviders := Map(
		"word_expanders",                (*) => _HS_WordExpanderRows(),
		; magic_key_config left _HotDynHandlers on 2026-08-07 for the same reason
		; word_expanders did: its manifest row is `type = "list"` now, so the
		; renderer builds the item from the data this returns.
		"magic_key_config",              (*) => _HS_MagicKeyRows(),
		"delays_colors",                 (*) => _HS_DelaysColorsRows(),
		"preview_bubbles",               (*) => _HS_PreviewBubbleRows(),
		; The five category blocks. Their ROW — label, count, checkmark and
		; position — is the renderer's now; the submenu hanging off each one is
		; still SubMenus[Category], assembled by a different subsystem, and is
		; handed over as a native Menu until that tree becomes data too.
		"hotstring_categories_standard", (*) => _HS_CategoryRowsStandard(),
		"hotstring_categories_dynamic",  (*) => _HS_CategoryRowsDynamic(),
		"hotstring_languages",           (*) => _HS_LanguageRows(),
		"hotstring_personal",           (*) => _HS_PersonalRows(),
		"hotstring_extensions",          (*) => _HS_ExtensionRows(),
	)

	; « Restore recommended » and « Clear » come from the tested terminal
	; provider, so the rows reach the same scope owner as its unit tests. There
	; is no whole-tree « all sections » row: each submenu owns its bulk rows.
	_HotCommands := _HS_ScopeCommands()
	_HotCommands[MenuCommand.HOTSTRINGS_TOGGLE] := MenuRenderer_CategoryGateCommand("Hotstrings")
	_HotGetters := Map(
		"hotstrings_enabled", () => IsCategoryGated("Hotstrings"),
	)

	_HotGroupBuilders := Map(
		"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers, "", _HotListProviders, _HotParamCommands, _HotParamGetters),
	)
	BootProfile_Mark("MENU/initMenu: pre-hotstrings render")
	HotstringsMenu := MenuDeferOrBuild((Target) => MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders, _HotListProviders, _HotCommands, _HotGetters, Target), "hotstrings_menu")
	BootProfile_Mark("MENU/initMenu: hotstrings menu rendered")

	HotstringsTotal := _HS_ComputeGrandTotal()
	_MI_StageDeclaredFeature(Receiver, HotstringsMenu, Map("hotstrings_enabled", () => HotstringsAllEnabled,
		"hotstrings_parent_total", () => HotstringsTotal, "hotstrings_parent_count_present", () => true), true)
	BootProfile_Mark("MENU/initMenu: hotstrings grandtotal+added")
}


; ── ✨ IA — LLM_Menu_Init stages its own row (menu_llm/init.ahk), because the
; persistent IA submenu outlives a root rebuild and only that module knows
; whether it is already built. The in-tray flag is reset first: a health-probe
; timer can build the IA menu before this root does, and the stale flag would
; then skip the row in the root being staged.
_MI_StageLlm() {
	global _LLM_Menu_InTray, _DriverInputInitPending, _LLM_Menu_Loaded, _IniCache
	_LLM_Menu_InTray := false
	; The boot snapshot serves the one build that restores it. A later rebuild would
	; throw the options away, and the read refuses once a save has changed
	; config.toml, which failed the rebuild (stale-boot-snapshot-replayed-by-rebuild).
	_LlmSavedOpts := Map()
	if !_LLM_Menu_Loaded {
		_LlmSavedOpts := LLM_Menu_BuildSavedOpts(_IniCache)
		_LLM_Menu_LoadAppProfileOverridesFromCache(_LlmSavedOpts, _IniCache)
	}
	LLM_Menu_Init(_LlmSavedOpts, !(IsSet(_DriverInputInitPending) && _DriverInputInitPending))
	BootProfile_Mark("MENU/initMenu: LLM tray init")
}



/** Attaches only the exact detached child already constructed by this caller. */
_MI_StagePrebuiltLlm(Submenu) {
	global _LLM_Menu_Handle, _LLM_Menu
	if !(Submenu is Menu) || _LLM_Menu_Handle != Submenu || !(_LLM_Menu is Map)
		throw Error("The caller-owned AI submenu was withdrawn before root staging.")
	Title := LLM_Menu_TrayTitle()
	TrayMenuStage_AddFeature(Title, Submenu)
	if _LLM_Menu["enabled"]
		TrayMenuStage_Check(Title)
	BootProfile_Mark("MENU/initMenu: caller-owned LLM tray projection")
}

; ── 🤖 AI agent — its own top-level submenu (ui/menu/menu_llm/menu_agent.ahk),
; ticked while the agent is not off.
_MI_StageAgent() {
	AgentTitle := t("menu.agent.title")
	TrayMenuStage_AddFeature(AgentTitle, LLM_Agent_MenuBuild())
	if (LLM_Agent_Setting(ConfigLeaf.AGENT_MODE) != "off")
		TrayMenuStage_Check(AgentTitle)
	BootProfile_Mark("MENU/initMenu: agent menu")
}


_MI_StageMetrics() {
	MetricsMenu := BuildMetricsMenu()
	TrayMenuStage_AddFeature(t("menu.metrics.title"), MetricsMenu)
	if MetricsShortcuts.enabled {
		TrayMenuStage_Check(t("menu.metrics.title"))
	}
	BootProfile_Mark("MENU/initMenu: metrics menu")
}


; Shortcuts submenu — built by MenuRenderer_Build("shortcuts_menu", …) and
; owned by InitSubMenus. The renderer handles the category toggle, feature
; toggles, separator placement, modifier-combos group, and dynamic blocks
; (personal shortcuts, script control, extensions, edit action) via the
; handler Map injected by _BuildShortcutsSubmenu's dynamic handlers.
; The Alt/Ctrl/Ctrl+Shift/Win splice belongs to InitSubMenus, NOT here: the
; root builders only READ SubMenus. Mutating a SubMenus entry from here is
; unbounded, because _Updater_RebuildMenu calls initMenu() ALONE — the
; submenu is never rebuilt, and Menu.Insert appends rather than merging.
_MI_StageShortcuts() {
	Receiver := MenuRenderer_GroupReceiver("top_level", "shortcuts")
	if !Receiver
		throw Error("The declared shortcuts feature parent was refused before native construction.")
	global SubMenus
	if !SubMenus.Has("Shortcuts") {
		try LoggerError("Menu", "The Shortcuts submenu was not built — its tray row is missing.")
		return
	}
	_MI_StageDeclaredFeature(Receiver, SubMenus["Shortcuts"], Map("shortcuts_enabled", () => IsCategoryGated("Shortcuts")))
}


_MI_StageTapHolds() {
	Receiver := MenuRenderer_GroupReceiver("top_level", ConfigLeaf.TAP_HOLDS)
	if !Receiver
		throw Error("The declared tap_holds feature parent was refused before native construction.")
	global SubMenus
	if !SubMenus.Has("TapHolds") {
		try LoggerError("Menu", "The Tap-Holds submenu was not built — its tray row is missing.")
		return
	}
	_MI_StageDeclaredFeature(Receiver, SubMenus["TapHolds"], Map("tapholds_enabled", () => IsCategoryGated("TapHolds")))
}


_MI_StageGestures() {
	Receiver := MenuRenderer_GroupReceiver("top_level", "gestures")
	if !Receiver
		throw Error("The declared gestures feature parent was refused before native construction.")
	GesturesMenu := BuildGesturesMenu()
	_MI_StageDeclaredFeature(Receiver, GesturesMenu, Map("gestures_enabled", () => Features["gestures"]["enabled"]), true)
}


; Publication consumes only the declared parent and its captured genuine native child.
_MI_StageDeclaredFeature(Receiver, Child, Getters, DisposeOnRefusal := false) {
	Published := false
	try {
		Row := Receiver.Call(Child, Getters)
		if !(Row is Map) || Row.Get("submenu", false) != Child
			throw Error("The canonical feature parent changed during native construction.")
		TrayMenuStage_AddFeature(Row["label"], Child)
		Published := true
		if Row.Get("checked", false)
			TrayMenuStage_Check(Row["label"])
		return true
	} finally {
		if DisposeOnRefusal && !Published {
			try Child.Delete()
			finally MenuDispatcher_PruneMenu(Child)
		}
	}
}

_MI_StageConfiguration() {
	TrayMenuStage_Add(t("menu.configuration.title"), _MI_BuildConfigurationMenu())
}


; The 21-locale language submenu costs ~156 ms on the first build. On the boot
; pass, defer it; on a live rebuild populate synchronously.
_MI_StageLanguage() {
	global _DriverReady, _LangMenuRef, _LangMenuBuildPending, _DriverInputInitPending
	LangMenu := Menu()
	TrayMenuStage_Add(t("menu.global.language"), LangMenu)
	_LangMenuRef := LangMenu
	if _DriverReady || (IsSet(_DriverInputInitPending) && _DriverInputInitPending)
		I18nBuildLanguageMenu(LangMenu)
	else {
		; A disabled placeholder makes the deferred population visible as
		; unavailable rather than accepting a click that cannot select a
		; locale yet. BuildLanguageMenuDeferred atomically enables it.
		TrayMenuStage_Disable(t("menu.global.language"))
		_LangMenuBuildPending := true
	}
}


_MI_StageAbout() {
	TrayMenuStage_Add(t("menu.about.title"), _MI_BuildAboutMenu())
}


_MI_StageSuspend() {
	global MenuSuspend
	MenuSuspend := t("menu.global.suspend")
	TrayMenuStage_AddAction(MenuSuspend, MenuStartupSafeCommand(MenuStartupLifecycleDispatch.Bind("suspend", ToggleSuspend)))
	; The row carries its own checked state at its single construction
	; point, so no rebuild caller can forget it. UpdateTrayIcon owns the
	; indicator but is wired only to state TRANSITIONS and to the boot
	; build, while TrayMenuStage_Publish deletes and replays the whole
	; root — a rebuild while paused (updater refresh, tray toggle) would
	; otherwise show « Suspendre » UNCHECKED on a paused driver, and the
	; click that reads as "pause" would in fact RESUME.
	if A_IsSuspended {
		TrayMenuStage_Check(MenuSuspend)
	}
}


_MI_StageReload() {
	Row := MenuRenderer_CommandRow("top_level", "reload",
		Map("reload", MenuStartupLifecycleDispatch.Bind("reload", ActivateReload)))
	if Row is Map && Row.Has("action") {
		; Keep lifecycle admission explicit after the shared provider wraps its callback.
		TrayMenuStage_AddAction(Row["label"], MenuStartupReloadCommand(Row["action"]))
		if Row.Get("disabled", false)
			TrayMenuStage_Disable(Row["label"])
	}
}


_MI_StageQuit() {
	Row := MenuRenderer_CommandRow("top_level", "quit",
		Map("quit", MenuStartupLifecycleDispatch.Bind("quit", ActivateExitApp)))
	if Row is Map && Row.Has("action") {
		; Keep lifecycle admission explicit after the shared provider wraps its callback.
		TrayMenuStage_AddAction(Row["label"], MenuStartupSafeCommand(Row["action"]))
		if Row.Get("disabled", false)
			TrayMenuStage_Disable(Row["label"])
	}
}


_MI_StageDebug() {
	TrayMenuStage_Add(t("menu.debug.title"), _MI_BuildDebuggingMenu())
}


; Builds the Configuration submenu from the manifest's configuration_menu array.
;
; Every row there is a `command`, so the renderer builds each label and the
; separator from the declaration and this driver supplies only what a click
; does. It replaced « Actions globales » and the two top-level rows that opened
; the folders editor and the setup wizard.
_MI_BuildConfigurationMenu() {
	Commands := _MI_GlobalScopeCommands()
	for Id, Callback in Map(
		MenuCommand.CLEAN_UNUSED_KEYS,   ShowUnusedConfigKeysCleanup,
		MenuCommand.CONFIG_FOLDER,       FilePathsEditor,
		MenuCommand.SETUP_WIZARD,        Onboarding_ShowFromMenu,
		MenuCommand.PROXY_OVERRIDE,      ProxyOverride_Command
	)
		Commands[Id] := Callback
	return MenuRenderer_Build("configuration_menu", "Configuration", "", "", "", Commands)
}


; Builds the About submenu (version, channels, update check, check frequency,
; Versions and its GitHub page, then startup and Uninstall after a separator).
_MI_BuildAboutMenu(StartupCommand := 0, StartupState := 0) {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_LATEST_RELEASE

	if !IsObject(StartupCommand)
		StartupCommand := ToggleStartAtLogin
	if !IsObject(StartupState)
		StartupState := StartAtLoginEnabled

	; The updater block is provider DATA since 2026-08-07: one row per entry,
	; with the channel and frequency pickers handed over as the native Menus they
	; already are. The changelog, releases and uninstall rows are `command`
	; declarations. Until then the whole submenu was assembled here and described
	; nowhere — on all three drivers at once.
	Providers := Map("about_updates", (*) => _MI_AboutUpdateRows())
	Commands := Map(
		MenuCommand.ABOUT_CHANGELOG,     Updater_ShowChangelog,
		MenuCommand.ABOUT_RELEASES_PAGE, Updater_OpenReleasesPage,
		MenuCommand.START_AT_LOGIN,      StartupCommand,
		"uninstall",           ShowUninstallErgopti
	)
	; A local version run from source has nothing to uninstall: the row stays,
	; greyed, and says why (the manifest's disabled_reason_key).
	StateGetters := Map("installed_build", () => !Updater_IsLocalSource(),
		"start_at_login_enabled", StartupState,
		"startup_command_available", StartAtLoginCommandAvailable)
	return MenuRenderer_Build("about_menu", "About", "", "", Providers, Commands, StateGetters)
}

; List provider: the version row (the build and its commit), the channel picker
; right before the check row, then the update-frequency picker. A local
; checkout has neither the check row nor the frequency picker: it has no release
; to update from.
_MI_AboutUpdateRows(IsLocal := Updater_IsLocalSource(), SetChannelFn := Updater_SetChannel,
		IdentityFn := Updater_BuildIdentity, SetIntervalFn := 0) {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_LATEST_RELEASE
	Rows := []

	; The build and the commit it was built from, in the shared wording:
	; « Version 0.0.0-dev.144 (c3005e0b9) » for a release, « Version locale
	; (c3005e0b9) » for a source run. The identity is resolved once per script
	; by Updater_BuildIdentity, so a rebuild reads no file.
	Identity := IdentityFn.Call()
	VerLabel := Updater_VersionRowLabel(Identity["kind"], Identity["version"], Identity["commit"])
	if IsLocal {
		; A local checkout has no release to open, so the version reads as a label.
		Rows.Push(Map("label", VerLabel, "disabled", true))
	} else {
		Rows.Push(Map("label", VerLabel, "action", Updater_OpenCurrentRelease))
	}
	SeparatorRows := MenuRenderer_TemplateRows("about_version_separator", Map(), Map(), Map())
	if !(SeparatorRows is Array)
		return []
	for Row in SeparatorRows
		Rows.Push(Row)

	; A local version installs nothing: the manifest's
	; ``disabled_when = ["installed_build"]`` greys both choices with the reason.
	Rows.Push(_MI_ChannelPickerRow(SetChannelFn, IsLocal))

	; The preset in force, which both the live picker and its greyed stand-in name
	; (a live value outside the presets reads as its nearest preset, the one a
	; reload would load).
	FrequencyRow := _MI_FrequencyPickerRow(SetIntervalFn, IsLocal)

	if IsLocal {
		; A local version has no installation to update, so it checks for nothing.
		; The two rows are still drawn, greyed with the reason: left out, nobody
		; could tell whether the automatic update exists.
		SourceRow := MenuRenderer_CommandRow("about_source_menu", MenuCommand.ABOUT_SOURCE_CHECK,
			Map(MenuCommand.ABOUT_SOURCE_CHECK, (*) => false),
			Map("about_source_release_ready", () => !IsLocal))
		if SourceRow is Map
			Rows.Push(SourceRow)
		Rows.Push(FrequencyRow)
		return Rows
	}

	Rows.Push(Map(
		"label",    Updater_GetUpdateMenuLabel(),
		"action",   Updater_OneClickUpdate,
		"disabled", (Updater_GetUpdateState() == "checking")))

	Rows.Push(FrequencyRow)
	return Rows
}

/** Supplies the registered cadence row to its acknowledged native owner. */
_MI_FrequencyPickerRow(SetIntervalFn := 0, IsLocal := Updater_IsLocalSource()) {
	global UPDATER_CHECK_INTERVAL
	if !IsObject(SetIntervalFn)
		SetIntervalFn := Updater_SetCheckInterval
	return MenuRenderer_ChoiceRow("about_update_frequency_menu", MenuCommand.UPDATE_CHECK_INTERVAL,
		Map(MenuCommand.UPDATE_CHECK_INTERVAL, SetIntervalFn),
		Map(ConfigKey.UPDATER_CHECK_INTERVAL_SECONDS, () => UpdateSchedule_SnapInterval(UPDATER_CHECK_INTERVAL).Seconds,
			"installed_build", () => !IsLocal))
}

; The channel picker: one submenu titled with the subscribed channel's registry
; name, one row per registry channel in registry order, ticked on the subscribed
; one. A click subscribes through the injected setter (Updater_SetChannel in
; production), which persists the choice and rebuilds the tray, so the title
; follows.
_MI_ChannelPickerRow(SetChannelFn, IsLocal := Updater_IsLocalSource()) {
	global UPDATER_CHANNEL
	return MenuRenderer_ChoiceRow("about_update_channel_menu", MenuCommand.UPDATE_CHANNEL,
		Map(MenuCommand.UPDATE_CHANNEL, (Id) => SetChannelFn.Call(Id)),
		Map(ConfigKey.UPDATER_CHANNEL, () => UPDATER_CHANNEL, "installed_build", () => !IsLocal))
}




; Builds the Debug submenu from the manifest's debug_menu array.
;
; Shared commands and one enum choice: native code supplies only the actual
; setter and current runtime value, while the manifest owns the row policy. The
; checks and probes hang in its « Tests » group, built from debug_tests_menu
; with the same command owners; no Tests row is drawn when none is for Windows.
_MI_BuildDebuggingMenu(LogLevelCommand := 0) {
	global LOGGER_MIN_LEVEL
	if !HasMethod(LogLevelCommand, "Call")
		LogLevelCommand := LoggerSetLevel
	Commands := Map(
		MenuCommand.WINDOW_SPY,     WindowSpy,
		MenuCommand.LIST_VARS,      ActivateListVars,
		MenuCommand.KEY_HISTORY,    ActivateKeyHistory,
		MenuCommand.OPEN_LOGS,      OpenLogsFolder,
		MenuCommand.OPEN_TODAY_LOG, OpenTodayLog,
		MenuCommand.OPEN_ERROR_LOG, OpenErrorLog,
		"healthcheck",    MenuStartupUiCommand(ShowHealthCheck, MenuStartupDiagnosticsReady),
		MenuCommand.SEND_PROBE, InputProbe_SendComparisonCommand,
		MenuCommand.HOOK_PROBE, InputProbe_HookOrderCommand,
		MenuCommand.COMPOSER_CHECK, ComposerCheck_Command,
		MenuCommand.FIELD_CHECK_NETWORK, NetworkCheck_Command,
		MenuCommand.REPORT_BUG,      (*) => HealthCheck_ReportBug(),
		MenuCommand.SUGGEST_FEATURE, (*) => HealthCheck_SuggestFeature(),
		ConfigLeaf.SHOW_ERROR_DIALOG, (*) => ErrorDialog_SetEnabled(!ErrorDialog_IsEnabled()),
		ConfigLeaf.LOG_LEVEL, LogLevelCommand
	)
	StateGetters := Map("error_dialog_enabled", ErrorDialog_IsEnabled,
		ConfigKey.SCRIPT_LOG_LEVEL, (*) => LOGGER_MIN_LEVEL)
	GroupBuilders := Map("debug_tests", () => _MI_BuildDebugTestsMenu(Commands, StateGetters))
	return MenuRenderer_Build("debug_menu", "Debug", "", GroupBuilders, Map(), Commands, StateGetters)
}

; The « Tests » submenu of Debug, or false when it would hold no row: the
; renderer then draws no parent, so the menu never offers an empty submenu.
_MI_BuildDebugTestsMenu(Commands, StateGetters) {
	Tests := MenuRenderer_Build("debug_tests_menu", "Debug", "", "", Map(), Commands, StateGetters)
	return TrayMenuItemCount(Tests) > 0 ? Tests : false
}

; Keep command registration shared by the real menu and its persistence tests.
_LAY_ScopeCommands(Options := unset) {
	Commands := ConfigScopeMenuCommands("keyboard_layout", Map(), IsSet(Options) ? Options : Map())
	Commands[MenuCommand.LAYOUT_TOGGLE] := MenuRenderer_CategoryGateCommand("Layout")
	Commands[MenuCommand.LAYOUT_MANAGER] := LayoutManager_Open
	Commands[MenuCommand.OPEN_LAYOUT_EDITOR] := LayoutManager_OpenEditor
	return Commands
}

/**
 * The Configuration menu's first group: the global restore and clear, each one
 * composed transaction over every category's owner, applied at once after its
 * backups. The tray's restore also creates the configuration folder's
 * layers.toml from the recommended layer when it has none; injected options
 * name their own.
 */
_MI_GlobalScopeCommands(Options := unset) {
	global _ConfigDir
	; The clear also restores the real touchpad (TouchpadRegistryClearFromScope).
	Selected := IsSet(Options) ? Options
		: Map("layers_config_dir", _ConfigDir, "touchpad_restore", TouchpadRegistryRestore)
	return Map(
		MenuCommand.SCOPE_RESTORE, (*) => ConfigGlobalScopeApply("recommended", Selected),
		MenuCommand.SCOPE_CLEAR, (*) => ConfigGlobalScopeApply("clear", Selected))
}
