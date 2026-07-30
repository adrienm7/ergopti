; ui/menu/menu_init.ahk

; ==============================================================================
; MODULE: Tray Menu / Main Builder
; DESCRIPTION:
; The top-level initMenu orchestrator plus the personal-shortcuts and language submenu builders it appends. Assembles the whole tray context menu from the category builders.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Render the runtime-registered personal shortcuts at the bottom of the
; Raccourcis menu when any have been declared by personal_shortcuts.ahk
; (separator + nested submenu of per-name toggles). Reads from the
; ``_PersonalShortcutsRegistry`` global populated by RegisterPersonalFeature
; so no Features v1 Map access is required.
_AppendPersonalShortcutsSubmenuIfAny(ShortcutsMenu) {
	global _PersonalShortcutsRegistry
	if !_PersonalShortcutsRegistry.Has("__Order") {
		return
	}
	Names := _PersonalShortcutsRegistry["__Order"]
	if (Names.Length == 0) {
		return
	}

	PersonalMenu := Menu()
	for _, Name in Names {
		; Label comes straight from the registry (the description, or the name
		; itself when none); the v2 path keys the lowercased name under
		; [ahk.shortcuts.personal]. Names are already lowercased at registration.
		Desc  := _PersonalShortcutsRegistry.Has(Name) ? _PersonalShortcutsRegistry[Name] : ""
		Label := (Desc != "") ? Desc : Name
		MenuAddItemWithLabel(PersonalMenu, "ahk.shortcuts.personal." . Name, Label, "Shortcuts")
	}
	ShortcutsMenu.Add()
	ShortcutsMenu.Add(t("menu.shortcuts.personal"), PersonalMenu)
}


; Post-"ready" population of the 21-locale language submenu — the ~156 ms (Win32
; menu-item registration + flag-icon loads) the boot pass skips. Armed once via a
; one-shot SetTimer from ErgoptiPlus.ahk; the live-rebuild path populates inline.
; Wrapped in try so a transient failure can never crash the timer thread.
BuildLanguageMenuDeferred() {
	global A_TrayMenu, _LangMenuRef, _LangMenuBuildPending
	try {
		; The placeholder submenu is disabled until this detached tree is ready.
		; Filling the published Menu in place left a brief but real empty-menu
		; click window during boot and language refreshes.
		StagedMenu := Menu()
		I18nBuildLanguageMenu(StagedMenu)
		_PublishCritical := Critical("On")
		try {
			A_TrayMenu.Add(t("menu.global.language"), StagedMenu)
			A_TrayMenu.Enable(t("menu.global.language"))
			_LangMenuRef := StagedMenu
			_LangMenuBuildPending := false
		} finally {
			Critical(_PublishCritical)
		}
	} catch as e {
		try LoggerError("TrayMenu", "Deferred language-menu build failed: {1}", e.Message)
	}
}


initMenu() {
	global SubMenus, A_TrayMenu, HotstringCategories
	global _TrayTitleCache, _FmtCountCache, _I18nSortedLocalesCache
	global _DriverReady, _LangMenuRef, _LangMenuBuildPending
	TrayMenuStage_Begin()
	try {
	_TrayTitleCache := Map()
	_FmtCountCache := Map()
	_I18nSortedLocalesCache := false
	_HS_InvalidateCaches()
	MenuManifest_InvalidateCache()

	BootProfile_Mark("MENU/initMenu: caches reset + tray staged")

	; Shortcuts submenu — built by MenuRenderer_Build("shortcuts_menu", …) and
	; owned by InitSubMenus. The renderer handles the category toggle, feature
	; toggles, separator placement, modifier-combos group, and dynamic blocks
	; (personal shortcuts, script control, extensions, edit action) via the
	; handler Map injected by _BuildShortcutsSubmenu's dynamic handlers.
	; The Alt/Ctrl/Ctrl+Shift/Win splice belongs to InitSubMenus, NOT here:
	; initMenu only READS SubMenus. Mutating a SubMenus entry from here is
	; unbounded, because _Updater_RebuildMenu calls initMenu() ALONE — the
	; submenu is never rebuilt, and Menu.Insert appends rather than merging.
	ShortcutsGated := IsCategoryGated("Shortcuts")

	; ── 🌐 Disposition clavier — built from manifest via MenuRenderer_Build.
	; Dynamic handler ``layout_features`` iterates ``ahk.layout`` entries;
	; ``active_layouts`` is macOS-only and skipped by the AHK platform filter.
	LayoutDynHandlers := Map(
		"layout_features_base",   (M, C) => _LAY_LayoutFeaturesBase(M, C),
		"layout_features_altgr",  (M, C) => _LAY_LayoutFeaturesAltGr(M, C),
	)
	LayoutMenu  := MenuRenderer_Build("layout_menu", "Layout", LayoutDynHandlers)
	; Grey out accented-letter shortcuts when Ergopti keyboard emulation is off —
	; the shortcuts depend on Ergopti key positions and are unusable without it.
	if !Features["layout"]["ergopti_base"] {
		LayoutMenu.Disable(t("menu.shortcuts.group_accented"))
	}
	LayoutGated := IsCategoryGated("Layout")
	LayoutMenuTitle := t("menu.layout.title")
	TrayMenuStage_Add(LayoutMenuTitle, LayoutMenu)
	if LayoutGated {
		TrayMenuStage_Check(LayoutMenuTitle)
	}
	BootProfile_Mark("MENU/initMenu: layout built+added")

	; ── Hotstrings ⚡ — built from manifest via MenuRenderer_Build.
	; Dynamic handlers supply the runtime-dependent blocks (params, categories,
	; personal tree, extensions). The toggle is rendered by the manifest toggle
	; type entry but uses the ToggleAllHostrings* pattern for hotstrings.
	HotstringsAllEnabled := IsCategoryGated("Hotstrings")

	_HotDynHandlers := Map(
		"hotstring_categories_standard", (M, C) => _HS_CategoriesStandard(M, C),
		"hotstring_categories_dynamic",  (M, C) => _HS_CategoriesDynamic(M, C),
		"hotstring_categories_ergopti",  (M, C) => _HS_CategoriesErgopti(M, C),
		"hotstring_personal",            (M, C) => _HS_Personal(M, C),
		"hotstring_extensions",          (M, C) => _HS_Extensions(M, C),
		"magic_key_config",              (M, C) => _HS_MagicKeyConfig(M, C),
		"repeat_key",                    (M, C) => _HS_RepeatKey(M, C),
		"hotstring_bulk_actions",        (M, C) => _HS_BulkActions(M, C),
		"delays_colors",                 (M, C) => _HS_DelaysColors(M, C),
		"word_expanders",                (M, C) => _HS_WordExpanders(M, C),
	)

	_HotGroupBuilders := Map(
		"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers),
	)
	BootProfile_Mark("MENU/initMenu: pre-hotstrings render")
	HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders)
	BootProfile_Mark("MENU/initMenu: hotstrings menu rendered")

	HotstringsMenuTitle := t("menu.hotstrings.title") . " (" . FmtCount(_HS_ComputeGrandTotal()) . ")"
	TrayMenuStage_Add(HotstringsMenuTitle, HotstringsMenu)
	if HotstringsAllEnabled {
		TrayMenuStage_Check(HotstringsMenuTitle)
	}
	BootProfile_Mark("MENU/initMenu: hotstrings grandtotal+added")

	global _LLM_Menu_InTray
	_LLM_Menu_InTray := false
	_LlmSavedOpts := LLM_Menu_BuildSavedOpts(_IniCache)

	_LlmRawOnboarded := IniCacheGet(_IniCache, "llm", "onboarding_seen")
	if (_LlmRawOnboarded != "_")
		_LlmSavedOpts["onboarding_seen"] := (_LlmRawOnboarded = true or _LlmRawOnboarded == 1
			or _LlmRawOnboarded == "1" or _LlmRawOnboarded == "true")
	_LlmRawAppOverrides := IniCacheGet(_IniCache, "llm", "app_profile_overrides")
	if _LlmRawAppOverrides != "_" and _LlmRawAppOverrides != "" {
		_LlmAppOverridesMap := Map()
		for _LlmAppPair in StrSplit(_LlmRawAppOverrides, ";") {
			_LlmAppPair := Trim(_LlmAppPair)
			if (_LlmAppPair == "")
				continue
			_LlmAppKv := StrSplit(_LlmAppPair, "=", , 2)
			if (_LlmAppKv.Length == 2 and _LlmAppKv[1] != "" and _LlmAppKv[2] != "")
				_LlmAppOverridesMap[_LlmAppKv[1]] := _LlmAppKv[2]
		}
		_LlmSavedOpts["app_profile_overrides"] := _LlmAppOverridesMap
	}
	LLM_Menu_Init(_LlmSavedOpts)
	BootProfile_Mark("MENU/initMenu: LLM tray init")

	MetricsMenu := BuildMetricsMenu()
	TrayMenuStage_Add(t("menu.metrics.title"), MetricsMenu)
	if MetricsShortcuts.enabled {
		TrayMenuStage_Check(t("menu.metrics.title"))
	}
	BootProfile_Mark("MENU/initMenu: metrics menu")

	if SubMenus.Has("Shortcuts") {
		TrayMenuStage_Add(GetCategoryTitle("Shortcuts"), SubMenus["Shortcuts"])
		if ShortcutsGated {
			TrayMenuStage_Check(GetCategoryTitle("Shortcuts"))
		}
	}
	if SubMenus.Has("TapHolds") {
		TrayMenuStage_Add(GetCategoryTitle("TapHolds"), SubMenus["TapHolds"])
		if IsCategoryGated("TapHolds") {
			TrayMenuStage_Check(GetCategoryTitle("TapHolds"))
		}
	}

	GesturesMenu := BuildGesturesMenu()
	TrayMenuStage_Add(GetCategoryTitle("Gestures"), GesturesMenu)
	if Features["gestures"]["enabled"] {
		TrayMenuStage_Check(GetCategoryTitle("Gestures"))
	}

	; ─── Tail (global_actions onwards): order driven by the shared manifest top_level.
	; Each id dispatches to its builder/registrar — only action closures and OS glue
	; live here; layout data comes from menu_manifest.json.
	_MI_AppendTail()
	BootProfile_Mark("MENU/initMenu: tail (global_actions…debug)")
	TrayMenuStage_Publish()
	} catch as e {
		TrayMenuStage_Abort()
		throw e
	}
}


; Appends the tail section of the tray menu (from global_actions to debug) in the
; order declared in menu_manifest.json top_level, filtered for AHK.  Behaviour
; change vs. the previous hard-coded order: language now sits right after
; global_actions, config_folder before setup_wizard, about after setup_wizard.
_MI_AppendTail() {
	global A_TrayMenu, _DriverReady, _LangMenuRef, _LangMenuBuildPending, MenuSuspend

	TailItems := MenuManifest_LoadTopLevelTail()
	for _, Entry in TailItems {
		Id := Entry["id"]
		if Id == "---" {
			TrayMenuStage_Add()
		} else if Id == "global_actions" {
			GlobalActionsMenu := _MI_BuildGlobalActionsMenu()
			TrayMenuStage_Add(t("menu.global.title"), GlobalActionsMenu)
		} else if Id == "language" {
			LangMenu := Menu()
			TrayMenuStage_Add(t("menu.global.language"), LangMenu)
			; The 21-locale language submenu costs ~156 ms on the first build.
			; On the boot pass, defer it; on a live rebuild populate synchronously.
			_LangMenuRef := LangMenu
			if _DriverReady
				I18nBuildLanguageMenu(LangMenu)
			else {
				; A disabled placeholder makes the deferred population visible as
				; unavailable rather than accepting a click that cannot select a
				; locale yet. BuildLanguageMenuDeferred atomically enables it.
				TrayMenuStage_Disable(t("menu.global.language"))
				_LangMenuBuildPending := true
			}
		} else if Id == "config_folder" {
			TrayMenuStage_AddAction(t("menu.global.config_folder"), FilePathsEditor)
		} else if Id == "setup_wizard" {
			TrayMenuStage_AddAction(t("menu.global.setup_wizard"), Onboarding_ShowFromMenu)
		} else if Id == "about" {
			TrayMenuStage_Add(t("menu.about.title"), _MI_BuildAboutMenu())
		} else if Id == "suspend" {
			MenuSuspend := t("menu.global.suspend")
			TrayMenuStage_AddAction(MenuSuspend, ToggleSuspend)
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
		} else if Id == "reload" {
			TrayMenuStage_AddAction(t("menu.global.reload"), ActivateReload)
		} else if Id == "quit" {
			TrayMenuStage_AddAction(t("menu.global.quit"), ActivateExitApp)
		} else if Id == "debug" {
			TrayMenuStage_Add(t("menu.debug.title"), _MI_BuildDebuggingMenu())
		}
	}
}


; Builds the "Actions globales" submenu from the manifest's global_actions array (MENU-2).
_MI_BuildGlobalActionsMenu() {
	M := Menu()
	for _, Entry in MenuManifest_LoadGlobalActions() {
		Id := Entry["id"]
		if Id == "---" {
			M.Add()
		} else if Id == "enable_all" {
			RegisterMenuItem(M, t("menu.global.enable_all"),    ToggleAllFeaturesOn)
		} else if Id == "disable_all" {
			RegisterMenuItem(M, t("menu.global.disable_all"),   ToggleAllFeaturesOff)
		} else if Id == "reset_defaults" {
			RegisterMenuItem(M, t("menu.global.reset_defaults"), ReloadWithDefaultConfig)
		}
	}
	return M
}


; Builds the About submenu (version, channel, update frequency, changelog).
_MI_BuildAboutMenu() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INTERVAL_PRESETS, UPDATER_LATEST_RELEASE
	AboutMenu := Menu()
	Ver := Updater_CurrentVersion()
	VerLabel := "ErgoptiPlus " . Ver
	if Updater_IsLocalSource() {
		AboutMenu.Add(VerLabel, (*) => NoAction())
		AboutMenu.Disable(VerLabel)
	} else {
		RegisterMenuItem(AboutMenu, VerLabel, Updater_OpenCurrentRelease)
	}
	AboutMenu.Add()
	ChannelMenu := Menu()
	RegisterMenuItem(ChannelMenu, t("menu.about.channel_main"), (*) => Updater_SetChannel("main"))
	RegisterMenuItem(ChannelMenu, t("menu.about.channel_dev"),  (*) => Updater_SetChannel("dev"))
	ChannelMenu.Check((UPDATER_CHANNEL == "dev") ? t("menu.about.channel_dev") : t("menu.about.channel_main"))
	ChannelDisplay := (UPDATER_CHANNEL == "dev") ? t("menu.about.channel_dev") : t("menu.about.channel_main")
	AboutMenu.Add(t("menu.about.channel_menu") . ": " . ChannelDisplay, ChannelMenu)
	if not Updater_IsLocalSource() {
		FreqMenu := Menu()
		CurrentLabel := ""
		CurrentCode  := ""
		for _, Preset in UPDATER_INTERVAL_PRESETS {
			Label := t("menu.about.frequency." . Preset.Code)
			RegisterMenuItem(FreqMenu, Label, _MakeFreqSetter(Preset.Seconds))
			if (Preset.Seconds == UPDATER_CHECK_INTERVAL) {
				CurrentLabel := Label
				CurrentCode  := Preset.Code
			}
		}
		if (CurrentLabel != "")
			FreqMenu.Check(CurrentLabel)
		FreqDisplay := (CurrentCode != "") ? CurrentCode : "?"
		AboutMenu.Add(t("menu.about.frequency_menu") . ": " . FreqDisplay, FreqMenu)
		UpdateLabel := Updater_GetUpdateMenuLabel()
		RegisterMenuItem(AboutMenu, UpdateLabel, Updater_OneClickUpdate)
		if (Updater_GetUpdateState() == "checking")
			AboutMenu.Disable(UpdateLabel)
	}
	AboutMenu.Add()
	RegisterMenuItem(AboutMenu, t("menu.about.changelog"), Updater_ShowChangelog)
	RegisterMenuItem(AboutMenu, t("menu.about.open_releases_page"), (*) => Run(Updater_ReleasesPageUrl()))
	return AboutMenu
}


; Builds the Debug submenu from the manifest's debug_menu array.
_MI_BuildDebuggingMenu() {
	DebuggingMenu := Menu()
	for _, Entry in MenuManifest_LoadDebugMenu() {
		Id := Entry["id"]
		if Id == "---" {
			DebuggingMenu.Add()
		} else if Id == "window_spy" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.window_spy"),     WindowSpy)
		} else if Id == "list_vars" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.list_vars"),      ActivateListVars)
		} else if Id == "key_history" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.key_history"),    ActivateKeyHistory)
		} else if Id == "log_level" {
			DebuggingMenu.Add(_LogLevelMenuLabel(), _BuildLogLevelMenu())
		} else if Id == "open_logs" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_logs"),      OpenLogsFolder)
		} else if Id == "open_today_log" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_today_log"), OpenTodayLog)
		} else if Id == "open_error_log" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_error_log"), OpenErrorLog)
		} else if Id == "healthcheck" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.healthcheck"),    ShowHealthCheck)
		}
	}
	return DebuggingMenu
}
