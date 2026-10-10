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


initMenu(PublishAuthorizeFn := 0, GlobalsOnly := false) {
	global _TrayTitleCache, _FmtCountCache, _I18nSortedLocalesCache
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
		_MI_StageTopLevel(MenuManifest_LoadTopLevel(), _MI_TopLevelBuilders(),
			(Entry) => !Entry.Get("greyed_when_paused", false))
	} else
		_MI_StageTopLevel(MenuManifest_LoadTopLevel(), _MI_TopLevelBuilders())
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
		"tap_holds",       _MI_StageTapHolds,
		"gestures",        _MI_StageGestures,
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
			BootProfile_StageAbort("menu row " . Id, Err.Message)
			throw Err
		}
		Dispatched += 1
	}
	return Dispatched
}


; ── 🌐 Disposition clavier — built from manifest via MenuRenderer_Build.
; The two feature blocks are `list` providers: they enumerate ``ahk.layout``
; entries and return one row per feature, which the renderer materialises.
; ``active_layouts`` is macOS-only and skipped by the AHK platform filter.
_MI_StageLayout() {
	Receiver := MenuRenderer_GroupReceiver("top_level", "keyboard_layout")
	if !Receiver
		throw Error("The declared keyboard_layout feature parent was refused before native construction.")
	LayoutListProviders := Map(
		"number_row_policy",      (*) => _LAY_NumberRowRows(),
		"custom_layouts",         (*) => _LAY_CustomLayoutRows(),
		"layout_features_base",   (*) => _LAY_LayoutFeatureBaseRows(),
		"layout_features_altgr",  (*) => _LAY_LayoutFeatureAltGrRows(),
		"magic_key_source",       (*) => MagicKeySourceMenuRows(),
	)
	; The accented-letter group stays enabled without the Ergopti emulation: the
	; shortcuts then follow the user's own layout (accented_shortcuts.ahk).
	LayoutMenu  := MenuRenderer_Build("layout_menu", "Layout", "", "", LayoutListProviders,
		_LAY_ScopeCommands(),
		Map("layout_enabled", () => IsCategoryGated("Layout")))
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
		"repeat_key", ToggleRepeatKeyEnabled,
	)
	_HotParamGetters := Map(
		"hotstrings_repeat_enabled", () => ReadFeatureStateV2("hotstrings.repeat_key_enabled").Get("enabled", false),
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
		"hotstring_languages",           (*) => _HS_LanguageRows(),
		"hotstring_personal",           (*) => _HS_PersonalRows(),
		"hotstring_extensions",          (*) => _HS_ExtensionRows(),
	)

	; The bulk rows were ONE `dynamic` row that expanded to two, then two
	; `command` rows « tout activer » / « tout désactiver ». They are one `check`
	; row now: ticked when every section is on, and a click switches the whole
	; tree to the other side. Read once per build, like every tick here.
	HotstringsAllSectionsOn := _HS_AllHotstringsOn()
	; « Restore recommended » and « Clear » come from the tested terminal
	; provider, so the rows reach the same scope owner as its unit tests.
	_HotCommands := _HS_ScopeCommands()
	_HotCommands["hotstrings_toggle"] := MenuRenderer_CategoryGateCommand("Hotstrings")
	_HotCommands["hotstrings_all_sections"] := (*) => ToggleAllHotstrings(!HotstringsAllSectionsOn)
	_HotGetters := Map(
		"hotstrings_enabled",              () => IsCategoryGated("Hotstrings"),
		"hotstrings_all_sections_enabled", () => HotstringsAllSectionsOn,
	)

	_HotGroupBuilders := Map(
		"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers, "", _HotListProviders, _HotParamCommands, _HotParamGetters),
	)
	BootProfile_Mark("MENU/initMenu: pre-hotstrings render")
	HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders, _HotListProviders, _HotCommands, _HotGetters)
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
	global _LLM_Menu_InTray, _DriverInputInitPending
	_LLM_Menu_InTray := false
	_LlmSavedOpts := LLM_Menu_BuildSavedOpts(_IniCache)
	_LLM_Menu_LoadAppProfileOverridesFromCache(_LlmSavedOpts, _IniCache)
	LLM_Menu_Init(_LlmSavedOpts, !(IsSet(_DriverInputInitPending) && _DriverInputInitPending))
	BootProfile_Mark("MENU/initMenu: LLM tray init")
}


; ── 🤖 AI agent — its own top-level submenu (ui/menu/menu_llm/menu_agent.ahk),
; ticked while the agent is not off.
_MI_StageAgent() {
	AgentTitle := t("menu.agent.title")
	TrayMenuStage_AddFeature(AgentTitle, LLM_Agent_MenuBuild())
	if (LLM_Agent_Setting("agent_mode") != "off")
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
	Receiver := MenuRenderer_GroupReceiver("top_level", "tap_holds")
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
		TrayMenuStage_AddAction(Row["label"], MenuStartupSafeCommand(Row["action"]))
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
		"clean_unused_keys",   ShowUnusedConfigKeysCleanup,
		"config_folder",       FilePathsEditor,
		"setup_wizard",        Onboarding_ShowFromMenu,
		"restore_touchpad_gestures", TouchpadRegistryRestoreFromMenu
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
		"about_changelog",     Updater_ShowChangelog,
		"about_releases_page", Updater_OpenReleasesPage,
		"start_at_login",      StartupCommand,
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

	Rows.Push(_MI_ChannelPickerRow(SetChannelFn))

	; The preset in force, which both the live picker and its greyed stand-in name
	; (a live value outside the presets reads as its nearest preset, the one a
	; reload would load).
	FrequencyRow := _MI_FrequencyPickerRow(SetIntervalFn)

	if IsLocal {
		; A local version has no installation to update, so it checks for nothing.
		; The two rows are still drawn, greyed with the reason: left out, nobody
		; could tell whether the automatic update exists.
		SourceRow := MenuRenderer_CommandRow("about_source_menu", "about_source_check",
			Map("about_source_check", (*) => false),
			Map("about_source_release_ready", () => !IsLocal))
		if SourceRow is Map
			Rows.Push(SourceRow)
		FrequencyRow.Delete("items")
		FrequencyRow["disabled"] := true
		FrequencyRow["disabled_reason_key"] := "menu.about.source_run_reason"
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
_MI_FrequencyPickerRow(SetIntervalFn := 0) {
	global UPDATER_CHECK_INTERVAL
	if !IsObject(SetIntervalFn)
		SetIntervalFn := Updater_SetCheckInterval
	return MenuRenderer_ChoiceRow("about_update_frequency_menu", "update_check_interval",
		Map("update_check_interval", SetIntervalFn),
		Map("updater.check_interval_seconds", () => UpdateSchedule_SnapInterval(UPDATER_CHECK_INTERVAL).Seconds))
}

; The channel picker: one submenu titled with the subscribed channel's registry
; name, one row per registry channel in registry order, ticked on the subscribed
; one. A click subscribes through the injected setter (Updater_SetChannel in
; production), which persists the choice and rebuilds the tray, so the title
; follows.
_MI_ChannelPickerRow(SetChannelFn) {
	global UPDATER_CHANNEL
	return MenuRenderer_ChoiceRow("about_update_channel_menu", "update_channel",
		Map("update_channel", (Id) => SetChannelFn.Call(Id)),
		Map("updater.channel", () => UPDATER_CHANNEL))
}




; Builds the Debug submenu from the manifest's debug_menu array.
;
; Shared commands and one enum choice: native code supplies only the actual
; setter and current runtime value, while the manifest owns the row policy.
_MI_BuildDebuggingMenu(LogLevelCommand := 0) {
	global LOGGER_MIN_LEVEL
	if !HasMethod(LogLevelCommand, "Call")
		LogLevelCommand := LoggerSetLevel
	Commands := Map(
		"window_spy",     WindowSpy,
		"list_vars",      ActivateListVars,
		"key_history",    ActivateKeyHistory,
		"open_logs",      OpenLogsFolder,
		"open_today_log", OpenTodayLog,
		"open_error_log", OpenErrorLog,
		"healthcheck",    MenuStartupUiCommand(ShowHealthCheck, MenuStartupDiagnosticsReady),
		"report_bug",      (*) => HealthCheck_ReportBug(),
		"suggest_feature", (*) => HealthCheck_SuggestFeature(),
		"show_error_dialog", (*) => ErrorDialog_SetEnabled(!ErrorDialog_IsEnabled()),
		"log_level", LogLevelCommand
	)
	StateGetters := Map("error_dialog_enabled", ErrorDialog_IsEnabled,
		"script.log_level", (*) => LOGGER_MIN_LEVEL)
	return MenuRenderer_Build("debug_menu", "Debug", "", "", Map(), Commands, StateGetters)
}

; Keep command registration shared by the real menu and its persistence tests.
_LAY_ScopeCommands(Options := unset) {
	Commands := ConfigScopeMenuCommands("keyboard_layout", Map(), IsSet(Options) ? Options : Map())
	Commands["layout_toggle"] := MenuRenderer_CategoryGateCommand("Layout")
	Commands["layout_manager"] := LayoutManager_Open
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
	Selected := IsSet(Options) ? Options : Map("layers_config_dir", _ConfigDir)
	return Map(
		"scope_restore", (*) => ConfigGlobalScopeApply("recommended", Selected),
		"scope_clear", (*) => ConfigGlobalScopeApply("clear", Selected))
}
