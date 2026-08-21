; ui/menu/menu_init.ahk

; ==============================================================================
; MODULE: Tray Menu / Main Builder
; DESCRIPTION:
; The top-level initMenu orchestrator plus the personal-shortcuts and language submenu builders it appends. Assembles the whole tray context menu from the category builders.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
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
	MenuRenderer_AppendRows(ShortcutsMenu, "shortcuts_menu", "personal_shortcuts", [
		Map("separator", true),
		Map("label", t("menu.shortcuts.personal"), "items", PersonalRows)
	])
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


initMenu(PublishAuthorizeFn := 0) {
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
	; The two feature blocks are `list` providers: they enumerate ``ahk.layout``
	; entries and return one row per feature, which the renderer materialises.
	; ``active_layouts`` is macOS-only and skipped by the AHK platform filter.
	LayoutListProviders := Map(
		"layout_features_base",   (*) => _LAY_LayoutFeatureBaseRows(),
		"layout_features_altgr",  (*) => _LAY_LayoutFeatureAltGrRows(),
	)
	LayoutMenu  := MenuRenderer_Build("layout_menu", "Layout", "", "", LayoutListProviders)
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

	; Empty since 2026-08-07: every row of the hotstrings tree is declarative or a
	; list provider now. Kept as a Map rather than removed so the renderer's
	; handler argument stays a Map and a future `dynamic` row has somewhere to go.
	_HotDynHandlers := Map()

	; repeat_key left _HotDynHandlers: its manifest row is `type = "check"` now,
	; so the renderer draws the row, its label and its tick from the declaration
	; and this driver supplies only the toggle and the state behind the tick. It
	; was three copies of one checkbox before that, one per driver.
	_HotParamCommands := Map(
		"repeat_key", ToggleRepeatKeyEnabled,
	)
	_HotParamGetters := Map(
		"hotstrings_repeat_enabled", () => HSE_RepeatEnabled,
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
		; The five category blocks. Their ROW — label, count, checkmark and
		; position — is the renderer's now; the submenu hanging off each one is
		; still SubMenus[Category], assembled by a different subsystem, and is
		; handed over as a native Menu until that tree becomes data too.
		"hotstring_categories_standard", (*) => _HS_CategoryRowsStandard(),
		"hotstring_categories_dynamic",  (*) => _HS_CategoryRowsDynamic(),
		"hotstring_categories_ergopti",  (*) => _HS_CategoryRowsErgopti(),
		"hotstring_personal",            (*) => _HS_PersonalRows(),
		"hotstring_extensions",          (*) => _HS_ExtensionRows(),
	)

	; The two bulk rows were ONE `dynamic` row that expanded to two, so the
	; manifest described neither. They are two `command` rows now — which is
	; also how macOS got them: it had no handler for the old id at all.
	_HotCommands := Map(
		"hotstrings_enable_all",  ToggleAllHotstringsOn,
		"hotstrings_disable_all", ToggleAllHotstringsOff,
	)

	_HotGroupBuilders := Map(
		"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers, "", _HotListProviders, _HotParamCommands, _HotParamGetters),
	)
	BootProfile_Mark("MENU/initMenu: pre-hotstrings render")
	HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders, _HotListProviders, _HotCommands)
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

	_LlmRawAppOverrides := IniCacheGet(_IniCache, "llm", "app_profile_overrides")
	if (_LlmRawAppOverrides is String)
			&& _LlmRawAppOverrides != "_" && _LlmRawAppOverrides != "" {
		_LlmAppOverridesMap := _LLM_Menu_DeserializeAppProfileOverrides(
			_LlmRawAppOverrides)
		if (_LlmAppOverridesMap is Map)
			_LlmSavedOpts["app_profile_overrides"] := _LlmAppOverridesMap
		else
			LoggerError("LLM", "Persisted app-profile overrides are malformed; refusing partial restore.")
	} else if !(_LlmRawAppOverrides is String)
		LoggerError("LLM", "Persisted app-profile overrides have the wrong type; refusing restore.")
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

	; The HEAD is staged in the fixed sequence above, and the manifest declares
	; that sequence too — so the two can disagree, and nothing would say which is
	; right. This names what was staged, in order, and compares it with what
	; top_level declares for this platform: a reordered manifest that this file
	; does not follow is reported instead of silently ignored.
	_MI_AssertHeadOrder(["keyboard_layout", "hotstrings", "llm", "metrics",
		"shortcuts", "tap_holds", "gestures"])

	; ─── Tail (global_actions onwards): order driven by the shared manifest top_level.
	; Each id dispatches to its builder/registrar — only action closures and OS glue
	; live here; layout data comes from menu_manifest.json.
	_MI_AppendTail()
	BootProfile_Mark("MENU/initMenu: tail (global_actions…debug)")
	Published := TrayMenuStage_Publish(PublishAuthorizeFn)
	return Published
	} catch as e {
		TrayMenuStage_Abort()
		throw e
	}
}


; Reports a head order that no longer matches the shared declaration.
;
; The tail below reads menu_manifest.json and dispatches by id; the head is a
; fixed sequence of calls, because each entry needs different state assembled in
; a different way and a generic dispatch would gain nothing. What it must not do
; is DIFFER from the declaration — the two Lua drivers place the same entries by
; reading it, so a manifest edit that this file ignores puts the same menu in two
; orders.
;
; Reported, not enforced: reordering the calls is a real change with real
; sequencing (the IA menu is initialised where it is because the metrics build
; below depends on nothing it does), and a build-time ERROR naming the drift is
; what tells the next person to make it deliberately.
_MI_AssertHeadOrder(StagedIds) {
	Declared := []
	for _, Entry in MenuManifest_LoadTopLevel() {
		if !(Entry is Map) or !Entry.Has("id")
			continue
		Id := Entry["id"]
		if (Id == "---")
			break  ; the head ends at the first separator; the tail is read below
		if _MR_IsForAhk(Entry)
			Declared.Push(Id)
	}
	if (Declared.Length == 0) {
		try LoggerWarn("Menu", "top_level declares no head row for this platform — the order check read nothing.")
		return
	}
	Mismatch := (Declared.Length != StagedIds.Length)
	if !Mismatch {
		for Index, Id in Declared {
			if (Id != StagedIds[Index]) {
				Mismatch := true
				break
			}
		}
	}
	if Mismatch {
		try LoggerError("Menu",
			"The tray head is staged as [{1}] and menu_manifest.json declares [{2}] — the same menu is in two orders across the drivers.",
			_MI_JoinIds(StagedIds), _MI_JoinIds(Declared))
	}
}

; Comma-joins ids for the message above.
_MI_JoinIds(Ids) {
	Out := ""
	for _, Id in Ids {
		Out .= (Out == "" ? "" : ", ") . Id
	}
	return Out
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


; Builds the "Actions globales" submenu from the manifest's global_actions array.
;
; Every row there is a `command`, so the renderer builds each label and each
; separator from the declaration and this driver supplies only what a click does.
; It used to iterate the same array and then write the label for each id by hand,
; in a chain of `else if` — the manifest decided the ORDER and this file decided
; everything else. Linux has rendered this same array for weeks.
_MI_BuildGlobalActionsMenu() {
	Commands := Map(
		"enable_all",     ToggleAllFeaturesOn,
		"disable_all",    ToggleAllFeaturesOff,
		"reset_defaults", ReloadWithDefaultConfig
	)
	return MenuRenderer_Build("global_actions", "Global", "", "", "", Commands)
}


; Builds the About submenu (version, channel, update frequency, changelog).
_MI_BuildAboutMenu() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INTERVAL_PRESETS, UPDATER_LATEST_RELEASE

	; The updater block is provider DATA since 2026-08-07: one row per entry,
	; with the channel and frequency pickers handed over as the native Menus they
	; already are. The changelog and releases rows are `command` declarations.
	; Until then the whole submenu was assembled here and described nowhere — on
	; all three drivers at once.
	Providers := Map("about_updates", (*) => _MI_AboutUpdateRows())
	Commands := Map(
		"about_changelog",     Updater_ShowChangelog,
		"about_releases_page", Updater_OpenReleasesPage
	)
	return MenuRenderer_Build("about_menu", "About", "", "", Providers, Commands)
}

; List provider: the version row, the channel picker, and — unless this is a
; local checkout — the update-frequency picker and the one-click update row.
_MI_AboutUpdateRows() {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INTERVAL_PRESETS, UPDATER_LATEST_RELEASE
	Rows := []

	VerLabel := "ErgoptiPlus " . Updater_CurrentVersion()
	if Updater_IsLocalSource() {
		; A local checkout has no release to open, so the version reads as a label.
		Rows.Push(Map("label", VerLabel, "disabled", true))
	} else {
		Rows.Push(Map("label", VerLabel, "action", Updater_OpenCurrentRelease))
	}
	Rows.Push(Map("separator", true))

	; The two channels as nested row DATA. The parent's label carries the channel
	; currently set, which is why the row stays a provider's rather than a
	; declaration's — but what hangs off it is the renderer's to draw.
	ChannelDisplay := (UPDATER_CHANNEL == "dev") ? t("menu.about.channel_dev") : t("menu.about.channel_main")
	Rows.Push(Map(
		"label", t("menu.about.channel_menu") . ": " . ChannelDisplay,
		"items", [
			Map("label",   t("menu.about.channel_main"),
				"action",  (*) => Updater_SetChannel("main"),
				"checked", (UPDATER_CHANNEL != "dev")),
			Map("label",   t("menu.about.channel_dev"),
				"action",  (*) => Updater_SetChannel("dev"),
				"checked", (UPDATER_CHANNEL == "dev"))
		]))

	if Updater_IsLocalSource() {
		return Rows
	}

	; Same shape for the check-frequency presets: one nested row per preset, the
	; tick on whichever matches the interval in force.
	FreqRows := []
	CurrentLabel := ""
	CurrentCode  := ""
	for _, Preset in UPDATER_INTERVAL_PRESETS {
		Label := t("menu.about.frequency." . Preset.Code)
		FreqRows.Push(Map(
			"label",   Label,
			"action",  _MakeFreqSetter(Preset.Seconds),
			"checked", (Preset.Seconds == UPDATER_CHECK_INTERVAL)))
		if (Preset.Seconds == UPDATER_CHECK_INTERVAL) {
			CurrentLabel := Label
			CurrentCode  := Preset.Code
		}
	}
	FreqDisplay := (CurrentCode != "") ? CurrentCode : "?"
	Rows.Push(Map(
		"label", t("menu.about.frequency_menu") . ": " . FreqDisplay,
		"items", FreqRows))

	Rows.Push(Map(
		"label",    Updater_GetUpdateMenuLabel(),
		"action",   Updater_OneClickUpdate,
		"disabled", (Updater_GetUpdateState() == "checking")))
	return Rows
}



; Builds the Debug submenu from the manifest's debug_menu array.
;
; Same move as the global actions above, and the same day: every row is a
; `command` except the log-level picker, whose label carries the CURRENT level
; and is therefore a `list` — exactly the shape Linux declared for it.
_MI_BuildDebuggingMenu() {
	Commands := Map(
		"window_spy",     WindowSpy,
		"list_vars",      ActivateListVars,
		"key_history",    ActivateKeyHistory,
		"open_logs",      OpenLogsFolder,
		"open_today_log", OpenTodayLog,
		"open_error_log", OpenErrorLog,
		"healthcheck",    ShowHealthCheck
	)
	ListProviders := Map("log_level", (*) => _MI_LogLevelRows())
	return MenuRenderer_Build("debug_menu", "Debug", "", "", ListProviders, Commands)
}

; List provider: the log-level picker, whose parent row reads the current level.
_MI_LogLevelRows() {
	return [Map(
		"label", _LogLevelMenuLabel(),
		"items", _MI_LogLevelChoiceRows())]
}
