; ui/tray_menu.ahk

; ==============================================================================
; MODULE: Tray Menu
; DESCRIPTION:
; Builds and manages the Windows system tray icon and right-click context menu.
;
; FEATURES & RATIONALE:
; 1. Full menu hierarchy: hotstrings, metrics, shortcuts, gestures and more.
; 2. Extracted from ErgoptiPlus.ahk to keep the boot file focused on
;    initialization and hotstring routing.
; ==============================================================================

global SubMenus := Map()

CreateSubMenusRecursive(MenuParent, Items, CategoryPath) {
	global SubMenus

	if GetFeatureByPath(CategoryPath).Has("__Order") {
		; Virtual grouping: ">Label" opens a transient submenu (no Features
		; counterpart needed) and "<" closes it. Lets us tidy long flat menus
		; without changing feature paths consumed elsewhere.
		MenuStack := [MenuParent]
		for Feature in GetFeatureByPath(CategoryPath)["__Order"] {
			CurrentMenu := MenuStack[MenuStack.Length]
			if Feature == "-" {
				CurrentMenu.Add() ; Empty line
				continue
			}
			if (SubStr(Feature, 1, 1) == ">") {
				GroupKey := Trim(SubStr(Feature, 2))
				; If the key contains a dot it's an i18n key, otherwise literal label
				GroupLabel := InStr(GroupKey, ".") ? t(GroupKey) : GroupKey
				GroupMenu := Menu()
				CurrentMenu.Add(GroupLabel, GroupMenu)
				MenuStack.Push(GroupMenu)
				continue
			}
			if (Feature == "<") {
				if (MenuStack.Length > 1) {
					MenuStack.Pop()
				}
				continue
			}
			Key := Feature
			Val := GetFeatureByPath(CategoryPath)[Feature]
			CreateSubMenusRecursiveCommonCode(CurrentMenu, Key, Val, CategoryPath)
		}
	} else {
		for Key, Val in Items {
			if Key == "__Configuration" {
				continue
			}
			CreateSubMenusRecursiveCommonCode(MenuParent, Key, Val, CategoryPath)
		}
	}
}

CreateSubMenusRecursiveCommonCode(MenuParent, Key, Val, CategoryPath) {
	FullPath := CategoryPath "." Key

	if (Type(Val) == "Map") {
		; Create submenu and store in SubMenus. The visible label defaults to
		; the raw map key but can be overridden by GetSubMenuLabel for paths
		; whose code identifier is intentionally English while the menu UI is
		; French (Shortcuts.Personal → « Raccourcis personnels », …).
		SubMenu := Menu()
		SubMenuLabel := GetSubMenuLabel(FullPath, Key)
		MenuParent.Add(SubMenuLabel, SubMenu)
		SubMenus[FullPath] := SubMenu
		; Phase 7.5 (UX): grey out the submenu container when its master
		; category gate is off so the user sees the whole sub-tree as
		; inert at a glance instead of having to drill in.
		if !IsCategoryGated(_MasterCategoryFor(CategoryPath)) {
			try MenuParent.Disable(SubMenuLabel)
		}
		; Recursively create nested submenus
		CreateSubMenusRecursive(SubMenu, Val, FullPath)
	} else if IsObject(Val) and Val.HasOwnProp("Enabled") {
		; Features that carry a remap target letter (the EGrave/ECirc/EAcute/
		; AGrave accent shortcuts) render as a letter-picker sub-submenu so
		; the user can pick any of a-z directly from the tray instead of
		; juggling a binary toggle plus a separate Gui editor.
		if Val.HasOwnProp("Letter") {
			MenuAddLetterPicker(MenuParent, CategoryPath, Key)
		} else {
			MenuAddItem(MenuParent, CategoryPath, Key)
		}
		; Mirror HS personal_info module_placeholder: add an editor shortcut
		; below the "Remplissage de formulaires" toggle
		if (StrLower(Key) == "textexpansionpersonalinformation") {
			MenuParent.Add(t("menu.shortcuts.edit_personal_info"), PersonalInformationEditor)
		}
		; Mirror HS ctrl_g pattern: inject the URL editor right below the GPT toggle
		if (StrLower(Key) == "gpt") {
			MenuParent.Add(t("menu.shortcuts.edit_gpt_link"), GPTLinkEditor)
		}
	}
}

MenuAddItem(MenuParent, FeatureCategoryPath, FeatureName) {
	FullPath := FeatureCategoryPath "." FeatureName
	MenuTitle := GetMenuTitleByPath(FullPath)
	; Use the menu-dispatcher bypass (lib/menu_dispatcher.ahk) so an AHK
	; native-dispatch drop is automatically recovered via the WM_COMMAND
	; retry timer. Falls back to MenuParent.Add internally when the
	; bypass cannot discover the item's Win32 ID (rare; same dispatch
	; behavior as before in that case).
	RegisterMenuItem(MenuParent, MenuTitle, (*) => ToggleMenuVariableByPath(FullPath))

	Feature := GetFeatureByPath(FullPath)
	if Feature.Enabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	; Phase 7.5 (UX): grey out the item when its master category gate is
	; off. The toggle is still visible (so the user can see what would be
	; available if they re-enabled the master) but clicking it does
	; nothing — the v2 mirror gates the underlying behavior to false
	; regardless of the per-feature .Enabled value.
	if !IsCategoryGated(_MasterCategoryFor(FeatureCategoryPath)) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Resolve the master-toggle category for a given feature path. Sub-Maps
; under Shortcuts (AltGrLAlt / AltGrCapsLock / LAltCapsLock / Personal /
; ScriptControl) inherit the Shortcuts gate; every hotstrings sub-category
; (Autocorrection / DistancesReduction / SFBsReduction / Rolls / MagicKey /
; DynamicHotstrings / Personal) inherits the Hotstrings gate; everything
; else (Layout / TapHolds / ...) maps to its own first segment.
_MasterCategoryFor(FeatureCategoryPath) {
	First := StrSplit(FeatureCategoryPath, ".")[1]
	; Hotstrings master gates all hotstring sub-trees regardless of their
	; top-level Features key (which is the legacy v1 layout — v2 nests
	; everything under [hotstrings.*]).
	for HotsCat in ["Autocorrection", "DistancesReduction", "SFBsReduction",
		"Rolls", "MagicKey", "DynamicHotstrings"] {
		if (HotsCat == First) {
			return "Hotstrings"
		}
	}
	; ``Personal`` is overloaded — both Shortcuts.Personal and the
	; hotstring Personal extension share the name. By position the
	; tray-menu Personal MenuAddItem call comes from BuildPersonalSubmenu
	; which is under the Hotstrings tree, so default Personal to
	; Hotstrings here; Shortcuts.Personal items use the qualified path
	; "Shortcuts.Personal" and First = "Shortcuts" instead.
	if (First == "Personal") {
		return "Hotstrings"
	}
	return First
}

; Build a sub-submenu listing « Désactivé » + a-z, with the currently active
; letter checked. Picking a letter sets it as the new mapping and enables
; the feature; picking « Désactivé » turns the feature off without losing
; the previously-selected letter (it is re-checked the next time the user
; re-enables via picking any letter). The parent menu entry stays checked
; whenever the feature is enabled, and its label remains the canonical
; "<description><LETTER>" string built by GetMenuTitleByPath.
MenuAddLetterPicker(MenuParent, FeatureCategoryPath, FeatureName) {
	FullPath := FeatureCategoryPath "." FeatureName
	Feature := GetFeatureByPath(FullPath)
	MenuTitle := GetMenuTitleByPath(FullPath)

	LetterMenu := Menu()

	; Entry that disables the remap without touching Letter
	DisabledLabel := t("common.disabled")
	LetterMenu.Add(DisabledLabel, ((p) => (*) => SetFeatureLetterOff(p))(FullPath))
	if !Feature.Enabled {
		LetterMenu.Check(DisabledLabel)
	}

	LetterMenu.Add() ; Separator

	; 26 letters a-z, displayed uppercase for menu legibility.
	; RegisterMenuItem (instead of LetterMenu.Add) installs the OnMessage
	; dispatcher bypass so clicks survive the AHK 2.0 menu-callback drop.
	CurrentLetter := Feature.HasOwnProp("Letter") ? StrLower(Feature.Letter) : ""
	loop 26 {
		L := Chr(Ord("a") + A_Index - 1)
		UpperL := StrUpper(L)
		RegisterMenuItem(LetterMenu, UpperL,
			((p, l) => (*) => SetFeatureLetter(p, l))(FullPath, L))
		if Feature.Enabled and CurrentLetter == L {
			LetterMenu.Check(UpperL)
		}
	}

	MenuParent.Add(MenuTitle, LetterMenu)
	if Feature.Enabled {
		MenuParent.Check(MenuTitle)
	}

	; Phase 7.5 (UX): grey out the picker when its master category gate
	; is off — same rationale as MenuAddItem above.
	if !IsCategoryGated(_MasterCategoryFor(FeatureCategoryPath)) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Sets the remap target letter on a feature and enables it. Persists both
; flags via TOML_Write so the change survives reload, then reloads to wire
; the new shortcut at the layer level.
SetFeatureLetter(FullPath, Letter) {
	Feature := GetFeatureByPath(FullPath)
	pos := InStr(FullPath, ".", , -1)
	FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)
	FeatureName := SubStr(FullPath, pos + 1)

	Feature.Enabled := true
	Feature.Letter := Letter
	TOML_Write(true, ConfigurationFile, FeatureCategoryPath, FeatureName)
	TOML_Write(Letter, ConfigurationFile, FeatureCategoryPath, FeatureName "_Letter")
	Reload
}

; Disables a letter-picker feature without touching its Letter, so the
; previously-selected mapping is restored on the next picker selection.
SetFeatureLetterOff(FullPath) {
	Feature := GetFeatureByPath(FullPath)
	pos := InStr(FullPath, ".", , -1)
	FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)
	FeatureName := SubStr(FullPath, pos + 1)

	Feature.Enabled := false
	TOML_Write(false, ConfigurationFile, FeatureCategoryPath, FeatureName)
	Reload
}

; Resolve the visible label of a sub-Map menu entry. Defaults to the raw
; FallbackKey (the map key as written in features_config.ahk). When the node
; carries a "__Label" key its value is used as an i18n key — avoids hardcoding
; every path here as the feature tree grows.
GetSubMenuLabel(FullPath, FallbackKey) {
	Node := GetFeatureByPath(FullPath)
	if IsObject(Node) and Node.HasOwnProp("__Label")
		return t(Node["__Label"])
	return FallbackKey
}

; Retrieve a feature title by its path
GetMenuTitleByPath(FullPath) {
	Feature := GetFeatureByPath(FullPath)
	if !IsObject(Feature)
		return FullPath

	if Feature.HasOwnProp("Description") {
		MenuTitle := Feature.Description
		if Feature.HasOwnProp("Letter")
			MenuTitle := MenuTitle StrUpper(Feature.Letter)
		return MenuTitle
	}
	return FullPath
}

; Retrieve a feature object by its path
GetFeatureByPath(FullPath) {
	Keys := StrSplit(FullPath, ".")
	Feature := Features
	for K in Keys {
		Feature := Feature[K]
	}
	return Feature
}

ToggleMenuVariableByPath(FullPath) {
	Feature := GetFeatureByPath(FullPath)
	CurrentFeatureActivation := Feature.Enabled ; Needs to be saved before turning off all shortcuts of the category

	; Find position of the last dot
	pos := InStr(FullPath, ".", , -1)
	if (pos) {
		FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)   ; everything left of the last dot
		FeatureName := SubStr(FullPath, pos + 1)              ; everything right of the last dot
	} else {
		FeatureCategoryPath := FullPath
		FeatureName := ""
	}

	; Count dot levels in FullPath
	DotCount := StrLen(FullPath) - StrLen(StrReplace(FullPath, ".", ""))
	if (DotCount >= 2) {
		; Set to False all shortcut possibilities
		FeatureCategory := GetFeatureByPath(FeatureCategoryPath)
		for ShortcutName in FeatureCategory {
			Shortcut := FeatureCategory.Get(ShortcutName)
			Shortcut.Enabled := False
			TOML_Write(Shortcut.Enabled, ConfigurationFile, FeatureCategoryPath, ShortcutName)
		}
	}
	Feature.Enabled := !CurrentFeatureActivation
	TOML_Write(Feature.Enabled, ConfigurationFile, FeatureCategoryPath, FeatureName)
	Reload
}

GetCategoryTitle(Category) {
	switch Category {
		case "DistancesReduction":
			return t("category.distances_reduction")
		case "SFBsReduction":
			return t("category.sfbs_reduction")
		case "Rolls":
			return t("category.rolls")
		case "Autocorrection":
			return t("category.autocorrection")
		case "MagicKey":
			return t("category.magic_key")
		case "DynamicHotstrings":
			return t("category.dynamic_hotstrings")
		case "Personal":
			return t("category.personal")
		case "Shortcuts":
			return t("category.shortcuts")
		case "TapHolds":
			return t("category.tapholds")
		case "Gestures":
			return t("category.gestures")
		default:
			return ""
	}
}

; ===================================
; Gestures menu builder
; ===================================

BuildGesturesMenu() {
	global Features, GestureAssignments, GESTURE_SLOTS, GESTURE_ACTIONS, GESTURE_SLOT_LABELS

	GMenu := Menu()

	; Canonical category toggle — inserted at position 1 with separator at 2.
	GestEnabled := Features["Gestures"]["Enabled"].Enabled
	AddCategoryToggleItem(GMenu,
		t("menu.gestures.on"),
		t("menu.gestures.off"),
		GestEnabled,
		(*) => ToggleGesturesEnabled())

	RegisterMenuItem(GMenu, t("menu.gestures.auto_configure"),  (*) => GestureAutoConfigureAction())
	; Single tutorial entry — combines the previous "Show instructions" and
	; "Open touchpad settings" items into one popup with the tutorial text
	; plus an in-panel button that opens Settings. The two-item flow forced
	; the user to bounce between menus to copy a shortcut and then go open
	; Settings; one panel keeps the whole walkthrough in front of them.
	GMenu.Add(t("menu.gestures.manual_tutorial"), (*) => GestureShowManualTutorialDialog())

	GMenu.Add()

	; Each slot becomes a single clickable item that opens a lazy GUI picker —
	; avoids pre-building hundreds of submenus (N slots × M actions).
	for Slot in GESTURE_SLOTS {
		if (Slot == "tap_4")
			GMenu.Add()
		SlotLabel     := t("gesture.slots." . Slot)
		CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
		CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction) ? _GestureActionLabel(CurrentAction) : t("dialog.action_picker.disabled")
		EntryLabel    := SlotLabel . " : " . CurrentLabel
		RegisterMenuItem(GMenu, EntryLabel, ((_s, _l) => (*) => ShowActionPicker(_l, GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none", (Id) => SetGestureSlotAction(_s, Id)))(Slot, SlotLabel))
		if !GestEnabled
			GMenu.Disable(EntryLabel)
	}

	return GMenu
}

; Applies a new action to a gesture slot and reloads.
SetGestureSlotAction(Slot, ActionName) {
	GestureSaveAssignment(Slot, ActionName)
	Reload
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
	global Features, ConfigurationFile
	Features["Gestures"]["Enabled"].Enabled := !Features["Gestures"]["Enabled"].Enabled
	TOML_Write(Features["Gestures"]["Enabled"].Enabled, ConfigurationFile, "Gestures", "Enabled")
	Reload
}

; ====================================
; ====================================
; ======= 1.X / Category toggle =======
; ====================================
; ====================================

; Insert the canonical « ✅ X activé(s) (cliquer pour désactiver) » /
; « ❌ X désactivé(s) (cliquer pour activer) » synthetic top item into a
; submenu, followed by a separator at position 2. AHK does not let us
; bind a callback on the parent label of a submenu (clicks open the
; submenu), so this is how every category exposes its global on/off
; toggle in a uniform way — same pattern Métriques uses.
;
; ``on_label`` and ``off_label`` are passed in full (not built from a
; template) so each category keeps its own French gender/number
; agreement: « activée » for « Disposition », « activés » for
; « Raccourcis », « activées » for « Métriques », etc.
AddCategoryToggleItem(menu, on_label, off_label, is_enabled, on_click) {
	label := is_enabled ? on_label : off_label
	; Insert via the bypass helper so the category-level toggle gets the
	; same WM_COMMAND retry coverage as the individual feature toggles
	; below. Without this, clicks on the "Activer / Désactiver" row at
	; the top of every submenu are still subject to AHK's native dispatch
	; drop pattern.
	RegisterMenuItemInsert(menu, "1&", label, on_click)
	menu.Insert("2&")  ; separator
}

; ====================================
; ====================================
; ======= 1.X / Metrics menu =======
; ====================================
; ====================================

; Build the « 📊 Métriques » submenu and attach it to the tray. The parent
; entry doubles as an ON/OFF toggle for the global keylogger feature: the
; checkmark reflects MetricsShortcuts.enabled, and clicking it triggers
; ToggleMetricsEnabled() with a confirmation dialog before turning ON.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
BuildMetricsMenu() {
	global A_TrayMenu
	MetricsMenu := Menu()

	enabled := MetricsShortcuts.enabled
	typing_label := t("menu.metrics.show_typing")
	apps_label   := t("menu.metrics.show_apps")
	; A trailing zero-width space differentiates the second « ↳ Raccourci :
	; Aucun » entry from the first — AHK's tray menu uses the label as a
	; unique key and would silently merge two identical strings into one.
	typing_sc := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("typing")
	apps_sc   := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("apps") . Chr(0x200B)

	; Route the Metrics typing/apps toggles through the menu-dispatcher
	; bypass (lib/menu_dispatcher.ahk) so AHK's random callback drops are
	; auto-recovered via the WM_COMMAND retry timer — these rows are
	; clicked often enough that the drop is user-visible.
	RegisterMenuItem(MetricsMenu, typing_label, (*) => KLUI_ToggleTyping())
	RegisterMenuItem(MetricsMenu, typing_sc, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
	MetricsMenu.Add() ; separator
	RegisterMenuItem(MetricsMenu, apps_label, (*) => KLUI_ToggleApps())
	RegisterMenuItem(MetricsMenu, apps_sc, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))

	MetricsMenu.Add()
	privacy_header := MenuSectionTitle(t("menu.metrics.privacy_header"))
	MetricsMenu.Add(privacy_header, (*) => "")
	MetricsMenu.Disable(privacy_header)

	private_label := t("menu.metrics.filter_private")
	MetricsMenu.Add(private_label, ToggleFilterPrivate)
	if MetricsFilters.private_browsing
		MetricsMenu.Check(private_label)

	secure_label := t("menu.metrics.filter_secure")
	MetricsMenu.Add(secure_label, ToggleFilterSecureField)
	if MetricsFilters.secure_field
		MetricsMenu.Check(secure_label)

	sysauth_label := t("menu.metrics.filter_sysauth")
	MetricsMenu.Add(sysauth_label, ToggleFilterSystemAuth)
	if MetricsFilters.system_auth
		MetricsMenu.Check(sysauth_label)

	; App exclusion entry — label reflects the count, click opens the
	; reusable AppPicker Gui. Mirror of HS « Désactivé dans N application(s) ».
	n := MF_DisabledCount()
	excl_label := (n > 0)
		? t("menu.metrics.disabled_in_prefix") . n . (n > 1 ? t("menu.metrics.disabled_in_suffix_p") : t("menu.metrics.disabled_in_suffix_s"))
		: t("menu.metrics.exclude_apps")
	MetricsMenu.Add(excl_label, OpenMetricsAppPicker)

	; ── Real-time WPM display ──────────────────────────────────────────────
	MetricsMenu.Add()
	WpmMenubarLabel       := t("menu.metrics.show_wpm_menubar")
	WpmMenubarColorsLabel := t("menu.metrics.colors_by_source") . Chr(0x200B)
	WpmWidgetLabel        := t("menu.metrics.show_wpm_widget")
	WpmWidgetColorsLabel  := t("menu.metrics.colors_by_source")
	WpmWidgetGraphLabel   := t("menu.metrics.include_realtime")

	; Fat-arrow lambdas capture their enclosing locals by reference in AHK v2,
	; so passing them directly is simpler and more reliable than IIFE patterns,
	; which AHK does not support across line breaks.
	MetricsMenu.Add(WpmMenubarLabel,       (*) => _ToggleWpmMenubar(MetricsMenu, WpmMenubarLabel, WpmMenubarColorsLabel))
	MetricsMenu.Add(WpmMenubarColorsLabel, (*) => _ToggleWpmMenubarColors(MetricsMenu, WpmMenubarColorsLabel))
	MetricsMenu.Add()
	MetricsMenu.Add(WpmWidgetLabel,        (*) => _ToggleWpmWidget(MetricsMenu, WpmWidgetLabel, WpmWidgetColorsLabel, WpmWidgetGraphLabel))
	MetricsMenu.Add(WpmWidgetColorsLabel,  (*) => _ToggleWpmWidgetColors(MetricsMenu, WpmWidgetColorsLabel))
	MetricsMenu.Add(WpmWidgetGraphLabel,   (*) => _ToggleWpmWidgetGraph(MetricsMenu, WpmWidgetGraphLabel))

	if MetricsShortcuts.show_wpm_menubar
		MetricsMenu.Check(WpmMenubarLabel)
	if MetricsShortcuts.show_wpm_menubar && MetricsShortcuts.wpm_menubar_colors
		MetricsMenu.Check(WpmMenubarColorsLabel)
	if WPMWidget.visible
		MetricsMenu.Check(WpmWidgetLabel)
	if WPMWidget.visible && WPMWidget.use_colors
		MetricsMenu.Check(WpmWidgetColorsLabel)
	if WPMWidget.visible && WPMWidget.show_graph
		MetricsMenu.Check(WpmWidgetGraphLabel)

	; Sub-options are disabled when their parent toggle is off.
	if !MetricsShortcuts.show_wpm_menubar
		MetricsMenu.Disable(WpmMenubarColorsLabel)
	if !WPMWidget.visible {
		MetricsMenu.Disable(WpmWidgetColorsLabel)
		MetricsMenu.Disable(WpmWidgetGraphLabel)
	}

	if !enabled {
		MetricsMenu.Disable(typing_label)
		MetricsMenu.Disable(typing_sc)
		MetricsMenu.Disable(apps_label)
		MetricsMenu.Disable(apps_sc)
		MetricsMenu.Disable(private_label)
		MetricsMenu.Disable(secure_label)
		MetricsMenu.Disable(sysauth_label)
		MetricsMenu.Disable(excl_label)
		MetricsMenu.Disable(WpmMenubarLabel)
		MetricsMenu.Disable(WpmMenubarColorsLabel)
		MetricsMenu.Disable(WpmWidgetLabel)
		MetricsMenu.Disable(WpmWidgetColorsLabel)
		MetricsMenu.Disable(WpmWidgetGraphLabel)
	}

	A_TrayMenu.Add(t("menu.metrics.title"), MetricsMenu)
	; Aligned with the canonical ✅/❌ pattern used by every other
	; category submenu. The security-warning dialog still fires inside
	; ToggleMetricsEnabled() before flipping ON, so the privacy
	; safeguard stays in place — the icon change is purely cosmetic.
	AddCategoryToggleItem(MetricsMenu,
		t("menu.metrics.on"),
		t("menu.metrics.off"),
		MetricsShortcuts.enabled,
		(*) => ToggleMetricsEnabled())
}

; ── Filter toggles. Each persists + flips the corresponding flag and
; triggers a Reload so the menu rerenders with the new checkmark state
; (AHK Menu.Check / Uncheck cannot retro-update an entry whose label was
; built into the submenu reference; rebuilding the whole tray is cleaner
; than playing with .ToggleCheck on a stale label).
ToggleFilterPrivate(*) {
	MetricsFilters.private_browsing := !MetricsFilters.private_browsing
	MF_SaveToIni()
	Reload
}

ToggleFilterSecureField(*) {
	MetricsFilters.secure_field := !MetricsFilters.secure_field
	MF_SaveToIni()
	Reload
}

ToggleFilterSystemAuth(*) {
	MetricsFilters.system_auth := !MetricsFilters.system_auth
	MF_SaveToIni()
	Reload
}

; ── WPM toggle helpers — closures capture the menu reference and label strings
; from BuildMetricsMenu locals, so no global state is needed. ──────────────────

_ToggleWpmMenubar(menu, label, colors_label) {
	MetricsShortcuts.show_wpm_menubar := !MetricsShortcuts.show_wpm_menubar
	CS_Save()
	try menu.ToggleCheck(label)
	if MetricsShortcuts.show_wpm_menubar {
		SetTimer(WpmMenubar_Tick, 1000)
		try menu.Enable(colors_label)
	} else {
		SetTimer(WpmMenubar_Tick, 0)
		A_IconTip := "ErgoptiPlus"
		try menu.Disable(colors_label)
	}
}

_ToggleWpmMenubarColors(menu, label) {
	MetricsShortcuts.wpm_menubar_colors := !MetricsShortcuts.wpm_menubar_colors
	CS_Save()
	try menu.ToggleCheck(label)
}

_ToggleWpmWidget(menu, widget_lbl, colors_lbl, graph_lbl) {
	WPMWidget_Toggle()
	try menu.ToggleCheck(widget_lbl)
	if WPMWidget.visible {
		try menu.Enable(colors_lbl)
		try menu.Enable(graph_lbl)
	} else {
		try menu.Disable(colors_lbl)
		try menu.Disable(graph_lbl)
	}
}

_ToggleWpmWidgetColors(menu, label) {
	WPMWidget.use_colors := !WPMWidget.use_colors
	WPMWidget_SaveConfig()
	try menu.ToggleCheck(label)
}

_ToggleWpmWidgetGraph(menu, label) {
	was_visible := WPMWidget.visible
	; Rebuild the widget in the new mode — compact and graph use different Gui layouts.
	if was_visible
		WPMWidget_Hide()
	WPMWidget.show_graph := !WPMWidget.show_graph
	; Destroy existing GUI so it is rebuilt in the correct layout on next show.
	if WPMWidget._gui {
		try WPMWidget._gui.Destroy()
		WPMWidget._gui      := false
		WPMWidget._lbl_wpm  := false
		WPMWidget._lbl_unit := false
	}
	if WPMWidget._graph_gui {
		try WPMWidget._graph_gui.Destroy()
		WPMWidget._graph_gui      := false
		WPMWidget._graph_wv       := false
		WPMWidget._graph_wv_ready := false
	}
	; Reset saved position so default bottom-right is recalculated for new size.
	WPMWidget.pos_x := -1
	WPMWidget.pos_y := -1
	WPMWidget_SaveConfig()
	try menu.ToggleCheck(label)
	if was_visible
		WPMWidget_Show()
}

; Updates A_IconTip with the current live WPM every second.
; When colors are enabled, appends the keystroke-origin tag [HS] or [IA].
WpmMenubar_Tick() {
	result := WPMWidget_Calc()
	wpm    := result["wpm"]
	if (wpm > 0) {
		suffix := ""
		if MetricsShortcuts.wpm_menubar_colors {
			if result["has_ai"]
				suffix := " [IA]"
			else if result["has_hs"]
				suffix := " [HS]"
		}
		A_IconTip := "ErgoptiPlus  |  " . wpm . " " . t("menu.metrics.wpm_unit") . suffix
	} else {
		A_IconTip := "ErgoptiPlus"
	}
}

OpenMetricsAppPicker(*) {
	AppPicker_Show(Map(
		"title",    t("dialog.metrics.exclude_title"),
		"prompt",   t("dialog.metrics.exclude_prompt"),
		"ok_label", t("dialog.metrics.exclude_ok"),
		"initial",  MF_DisabledList(),
		"on_save",  OnMetricsAppPickerSave
	))
}

OnMetricsAppPickerSave(selected) {
	; Replace the disabled-apps map wholesale with the picker's result —
	; the user expects "what's checked = what's filtered", not "diff
	; against the previous state".
	MetricsFilters.disabled_apps := Map()
	for proc in selected
		MetricsFilters.disabled_apps[StrLower(proc)] := true
	MF_SaveToIni()
	Reload
}

; Flip the global keylogger feature with a warning dialog before enabling.
; Persisted via metrics_shortcuts.ini and applied on Reload (the keylogger
; can only initialise its file IO at boot, not mid-session, mirroring the
; Hammerspoon behaviour where toggling the feature triggers HS reload).
ToggleMetricsEnabled() {
	if MetricsShortcuts.enabled {
		; Disabling — no warning needed, just confirm.
		res := MsgBox(
			t("dialog.metrics.disable_confirm"),
			t("dialog.metrics.title"),
			"OKCancel Icon?"
		)
		if (res != "OK")
			return
		MetricsShortcuts.enabled := false
		MS_SaveToIni()
		Reload
		return
	}

	; Enabling — explicit warning, OK is the dangerous action. The metrics
	; folder lives under the user-resolved _ConfigDir (paths.toml override
	; honoured) so the displayed path matches reality, even when the user
	; has relocated their config.
	global _ConfigDir
	metrics_path := _ConfigDir . "metrics"
	warn := Format(t("dialog.metrics.enable_warning"), metrics_path)
	; Icon! = exclamation triangle (warning). Iconx is the red error stop
	; sign and was the wrong choice for a "you are about to enable a
	; logging feature" notice.
	res := MsgBox(warn, t("dialog.metrics.security_warning_title"), "OKCancel Icon!")
	if (res != "OK")
		return
	MetricsShortcuts.enabled := true
	MS_SaveToIni()
	Reload
}

; Runs the auto-configure and shows the result to the user.
GestureAutoConfigureAction() {
	Success := GestureAutoConfigureRegistry()
	if (Success) {
		MsgBox(
			t("dialog.gestures.auto_configure_success"),
			t("dialog.gestures.auto_configure_title"),
			"Iconi"
		)
	} else {
		MsgBox(
			t("dialog.gestures.auto_configure_error"),
			t("dialog.gestures.auto_configure_error_title"),
			"Icon!"
		)
	}
}

; =========================
; Main menu initialization
; =========================

global MenuHotstrings := "⚡ Hotstrings"
global MenuConfigurationShortcuts := t("menu.script_control.title")
; Holds the « Suspendre » label so UpdateTrayIcon can check/uncheck the
; entry by its exact text on A_TrayMenu. Re-assigned in initMenu so future
; label tweaks (icons, hints) only need to change the menu builder.
global MenuSuspend := t("menu.global.suspend")
global MenuDebugging := t("menu.debug.title")

; Load category lists from the shared manifest instead of hard-coding them here
global _HotstringGroups        := MenuManifest_LoadHotstringGroups()
global HotstringCategories     := _HotstringGroups.all
global HotstringCategoriesStd  := _HotstringGroups.standard
global HotstringCategoriesErgopti := _HotstringGroups.ergopti

InitSubMenus() {
	global Features, SubMenus
	SubMenus := Map()
	for Category, Items in Features {
		if Category = "Layout" {
			continue
		}
		SubMenu := Menu()
		SubMenus[Category] := SubMenu ; Only top-level category stored
		CreateSubMenusRecursive(SubMenu, Items, Category)
	}
	; Personal is defined in personal_shortcuts.ahk (not in the static Features map),
	; so it must be wired separately after the loop — only when the user's file loaded it.
	if Features.Has("Personal") {
		PersonalSubMenu := Menu()
		SubMenus["Personal"] := PersonalSubMenu
		CreateSubMenusRecursive(PersonalSubMenu, Features["Personal"], "Personal")
	}
}

initMenu() {
	global Features, SubMenus, A_TrayMenu, HotstringCategories

	A_TrayMenu.Delete()

	; Prepend a global on/off toggle at the top of the Raccourcis submenu —
	; mirrors the HS pattern where clicking the parent title toggles the
	; category. AHK does not support clickable parent titles, so the first
	; item is the toggle.
	;
	; The checkbox reflects « at least one shortcut enabled » rather than
	; « every shortcut enabled »: several built-ins (Save, CtrlJ, the AltGr
	; combo variants, …) ship as off-by-default on purpose, so an « all
	; enabled » metric would always render the toggle unchecked at first
	; launch and falsely suggest the category is inactive. With « any
	; enabled », the toggle ships checked for a fresh install (where most
	; leaf features default to true) and the click action remains intuitive
	; — when checked, click disables every shortcut; when unchecked, click
	; re-enables every shortcut.
	if SubMenus.Has("Shortcuts") {
		; Master gate (Phase 7.4) — see comment in the Layout block below.
		ShortcutsGated := IsCategoryGated("Shortcuts")
		AddCategoryToggleItem(SubMenus["Shortcuts"],
			t("menu.shortcuts.on"),
			t("menu.shortcuts.off"),
			ShortcutsGated,
			(*) => ToggleCategoryAllFeatures("Shortcuts", !ShortcutsGated))
	}

	; Insert the configurable keyboard shortcut groups just before the
	; « Combinaison de modificateurs » group that CreateSubMenusRecursive already
	; added — keeping the modifier combos visually grouped together.
	; Then append « Raccourcis de gestion du script » at the bottom.
	if SubMenus.Has("Shortcuts") {
		InsertKeyboardShortcutGroups(SubMenus["Shortcuts"], t("menu.shortcuts.group_modifiers"))
		SubMenus["Shortcuts"].Add(t("menu.shortcuts.script_shortcuts"), BuildScriptShortcutsMenu())
		SubMenus["Shortcuts"].Add() ; Separator before edit personal shortcuts
		SubMenus["Shortcuts"].Add(t("menu.global.edit_shortcuts"), OpenPersonalShortcuts)

		; Extensions shortcuts — one submenu per bundled extension that ships a
		; shortcuts/menu.ahk. The script is run in a sandboxed #Include context
		; receiving a pre-created Menu object named ExtMenu and the string ExtName.
		global _StaticDir
		ExtShortcutsBaseDir := _StaticDir . "\extensions\"
		HasExtShortcuts := false
		if DirExist(ExtShortcutsBaseDir) {
			Loop Files ExtShortcutsBaseDir . "*", "D" {
				MenuAhkPath := A_LoopFileFullPath . "\shortcuts\menu.ahk"
				if FileExist(MenuAhkPath) {
					HasExtShortcuts := true
					break
				}
			}
		}
		if HasExtShortcuts {
			SubMenus["Shortcuts"].Add() ; Separator before Extensions block
			ExtShortcutsHeader := MenuSectionTitle(t("menu.extensions.header"))
			SubMenus["Shortcuts"].Add(ExtShortcutsHeader, (*) => NoAction())
			SubMenus["Shortcuts"].Disable(ExtShortcutsHeader)
			Loop Files ExtShortcutsBaseDir . "*", "D" {
				ExtId        := A_LoopFileName
				ExtDir       := A_LoopFileFullPath
				MenuAhkPath  := ExtDir . "\shortcuts\menu.ahk"
				if !FileExist(MenuAhkPath)
					continue
				; Read display name from manifest
				ExtName      := ExtId
				ManifestPath := ExtDir . "\manifest.toml"
				if FileExist(ManifestPath) {
					try {
						MC := FileRead(ManifestPath, "UTF-8")
						if RegExMatch(MC, "name\s*=\s*`"([^`"]+)`"", &MN)
							ExtName := MN[1]
					}
				}
				; Build the extension's submenu. menu.ahk must define a function
				; named BuildExtMenu(ExtMenu, ExtName) that populates the menu.
				; The file is sourced by the extension loader at startup via
				; #Include; here we just call the registered builder function.
				ExtMenu   := Menu()
				BuilderFn := "BuildExtMenu_" . StrReplace(ExtId, "-", "_")
				if IsSet(%BuilderFn%) and HasMethod(%BuilderFn%) {
					try {
						%BuilderFn%(ExtMenu, ExtName)
					} catch as Err {
						LoggerWarn("Extensions", "BuildExtMenu for '{1}' threw: {2}.", ExtId, Err.Message)
					}
				} else {
					LoggerWarn("Extensions", "No BuildExtMenu_{1} function found — menu.ahk not loaded?", StrReplace(ExtId, "-", "_"))
					NaLabel := t("menu.extensions.empty")
					ExtMenu.Add(NaLabel, (*) => NoAction())
					ExtMenu.Disable(NaLabel)
				}
				SubMenus["Shortcuts"].Add(ExtName, ExtMenu)
			}
		}
	}

	; ── 🌐 Disposition clavier — mirrors the HS layout submenu naming ──
	; Master gate (Phase 7.4): the parent menu checkmark and the master
	; toggle label both reflect IsCategoryGated, NOT a per-feature scan.
	; A flipped gate keeps individual per-feature toggles intact but
	; neutralises the whole category via the mirror in lib/v1_v2_mirror.ahk.
	LayoutMenu := Menu()
	LayoutGated := IsCategoryGated("Layout")
	AddCategoryToggleItem(LayoutMenu,
		t("menu.layout.on"),
		t("menu.layout.off"),
		LayoutGated,
		(*) => ToggleCategoryAllFeatures("Layout", !LayoutGated))
	for FeatureName in Features["Layout"]["__Order"] {
		MenuAddItem(LayoutMenu, "Layout", FeatureName)
	}
	LayoutMenuTitle := t("menu.layout.title")
	A_TrayMenu.Add(LayoutMenuTitle, LayoutMenu)
	if LayoutGated {
		A_TrayMenu.Check(LayoutMenuTitle)
	}

	; ── Hotstrings ⚡ — single submenu grouping all hotstring categories ──
	; Layout mirrors Hammerspoon builder.lua:
	;   1. Global toggle + separator
	;   2. Paramètres (config items) + separator
	;   3. "— Hotstrings communs —" header + common TOML groups + dynamic
	;   4. Separator + "— Hotstrings personnels —" header + personal TOML(s) + extensions
	HotstringsMenu := Menu()
	; Master gate (Phase 7.4): IsCategoryAllEnabled returns the gated
	; state (not a per-feature scan) so the master toggle and parent
	; menu checkmark reflect the user's master choice rather than the
	; aggregated state of every hotstring entry.
	HotstringsAllEnabled := IsCategoryGated("Hotstrings")
	AddCategoryToggleItem(HotstringsMenu,
		t("menu.hotstrings.on"),
		t("menu.hotstrings.off"),
		HotstringsAllEnabled,
		HotstringsAllEnabled ? ToggleAllHotstringsOff : ToggleAllHotstringsOn)

	; 1. Paramètres — mirrors HS "⚙️ Paramètres hotstrings" submenu
	ParamsMenu := Menu()
	ParamsMenu.Add(t("menu.hotstrings.delays_colors"),
		(*) => OpenHotstringsConfigWindow())
	ParamsMenu.Add(t("menu.hotstrings.magic_key_prefix") . ScriptInformation["MagicKey"], MagicKeyEditor)
	RepeatToggleLabel := t("menu.hotstrings.repeat_key_toggle")
	ParamsMenu.Add(RepeatToggleLabel, ToggleRepeatKeyEnabled)
	if HSE_RepeatEnabled {
		ParamsMenu.Check(RepeatToggleLabel)
	}
	HotstringsMenu.Add(t("menu.hotstrings.params"), ParamsMenu)
	HotstringsMenu.Add() ; Separator after paramètres block

	; 2a. Standard hotstring groups + dynamic — "Hotstrings communs" header
	StdTotal := 0
	for _CCat in HotstringCategoriesStd {
		StdTotal += CountTomlHotstrings(_CCat)
	}
	DynTotalStd := 0
	for _DSec in Features["DynamicHotstrings"]["__Order"] {
		if (_DSec != "-" and Features["DynamicHotstrings"].Has(_DSec)
		and Features["DynamicHotstrings"][_DSec].Enabled) {
			DynTotalStd += CountDynamicSection(_DSec)
		}
	}
	StdTotal += DynTotalStd
	StdHeader := MenuSectionTitle(t("menu.hotstrings.common_header") . (StdTotal > 0 ? " (" . FmtCount(StdTotal) . ")" : ""))
	HotstringsMenu.Add(StdHeader, (*) => NoAction())
	HotstringsMenu.Disable(StdHeader)
	for Category in HotstringCategoriesStd {
		if SubMenus.Has(Category) {
			Total := CountTomlHotstrings(Category)
			Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . FmtCount(Total) . ")" : "")
			HotstringsMenu.Add(Title, SubMenus[Category])
		}
	}
	; Dynamic hotstrings — date insertion and future rule-based expansions.
	if Features.Has("DynamicHotstrings") and SubMenus.Has("DynamicHotstrings") {
		DynMenu := SubMenus["DynamicHotstrings"]
		DynTotal := 0
		for _DSec in Features["DynamicHotstrings"]["__Order"] {
			if (_DSec != "-" and Features["DynamicHotstrings"].Has(_DSec)
			and Features["DynamicHotstrings"][_DSec].Enabled) {
				DynTotal += CountDynamicSection(_DSec)
			}
		}
		DynTitle := GetCategoryTitle("DynamicHotstrings")
		. (DynTotal > 0 ? " (" . FmtCount(DynTotal) . ")" : "")
		HotstringsMenu.Add(DynTitle, DynMenu)
	}

	; 2b. Ergopti-layout-specific groups — separated from the standard block
	HotstringsMenu.Add() ; Separator between communs and Ergopti blocks
	ErgoptiTotal := 0
	for _ECat in HotstringCategoriesErgopti {
		ErgoptiTotal += CountTomlHotstrings(_ECat)
	}
	ErgoptiHeader := MenuSectionTitle(t("menu.hotstrings.ergopti_header") . (ErgoptiTotal > 0 ? " (" . FmtCount(ErgoptiTotal) . ")" : ""))
	HotstringsMenu.Add(ErgoptiHeader, (*) => NoAction())
	HotstringsMenu.Disable(ErgoptiHeader)
	for Category in HotstringCategoriesErgopti {
		if SubMenus.Has(Category) {
			Total := CountTomlHotstrings(Category)
			Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . FmtCount(Total) . ")" : "")
			HotstringsMenu.Add(Title, SubMenus[Category])
		}
	}

	; CommonTotal = all groups (std + ergopti) used for GrandTotal
	CommonTotal := StdTotal + ErgoptiTotal

	; 3. Personal/custom hotstrings — separator + disabled header + entries
	; personal_hotstrings.toml first, then extra TOMLs from hotstrings\ folder alphabetically.
	TotalPersonal := 0
	if Features.Has("Personal") {
		; Read personal_hotstrings.toml once to get section order, descriptions, and counts
		TomlData := ReadPersonalToml()
		; Enrich Features["Personal"] descriptions with entry counts
		for _, SecName in TomlData["sections_order"] {
			SecData := TomlData["sections"][SecName]
			Count := SecData["entries"].Length
			BaseDesc := SecData["description"]
			for FeatKey in Features["Personal"] {
				if (FeatKey != "__Order" and StrLower(FeatKey) == SecName) {
					Features["Personal"][FeatKey].Description := BaseDesc . " (" . FmtCount(Count) . ")"
				}
			}
		}
		for _, SecData in TomlData["sections"] {
			TotalPersonal += SecData["entries"].Length
		}
	}
	; Count extra extension TOMLs
	ExtTomlFiles := []
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalHotstringsDir") {
		HsDir := ScriptInformation["PersonalHotstringsDir"]
		if DirExist(HsDir) {
			Loop Files HsDir . "*.toml" {
				if (A_LoopFileName != "personal_hotstrings.toml") {
					ExtTomlFiles.Push(A_LoopFileFullPath)
					for _, _ESec in _ParseExtTomlSections(A_LoopFileFullPath) {
						TotalPersonal += _ESec["count"]
					}
				}
			}
		}
	}
	HotstringsMenu.Add() ; Separator before personal group
	PersonalHeader := MenuSectionTitle(t("menu.hotstrings.personal_header") . (TotalPersonal > 0 ? " (" . FmtCount(TotalPersonal) . ")" : ""))
	HotstringsMenu.Add(PersonalHeader, (*) => NoAction())
	HotstringsMenu.Disable(PersonalHeader)
	if Features.Has("Personal") {
		; Build the unified personal submenu for personal_hotstrings.toml
		PersonalMenu := Menu()
		PersonalMenu.Add(t("menu.hotstrings.open_editor"), (*) => OpenPersonalEditor())
		; Shortcut item — not yet customisable from AHK (HS handles it on macOS)
		_ShortcutLabel := t("menu.hotstrings.shortcut_prefix") . ScriptInformation["MagicKey"]
		PersonalMenu.Add(_ShortcutLabel, (*) => NoAction())
		PersonalMenu.Disable(_ShortcutLabel)
		; Default section — submenu with "Aucune" + one item per TOML section
		CurDefaultSec := _EditorPrefGet("DefaultSection", "")
		DefaultSectionMenu := Menu()
		DefaultSectionMenu.Add(t("menu.hotstrings.default_none"), (*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData,
			DefaultSectionMenu))
		if (CurDefaultSec == "") {
			DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
		}
		DefaultSectionMenu.Add()
		for _, SecName in TomlData["sections_order"] {
			if (SecName == "-") {
				continue
			}
			SecData := TomlData["sections"][SecName]
			SecLabel := SecData["description"]
			DefaultSectionMenu.Add(SecLabel, _MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData,
				DefaultSectionMenu))
			if (CurDefaultSec == SecName) {
				DefaultSectionMenu.Check(SecLabel)
			}
		}
		CurDefaultLabel := (CurDefaultSec == "") ? t("menu.hotstrings.default_none")
			: (TomlData["sections"].Has(CurDefaultSec) ? TomlData["sections"][CurDefaultSec]["description"] :
				CurDefaultSec)
		global _PrevDefaultLabel := CurDefaultLabel
		_DefaultCatLabel := t("menu.hotstrings.default_category_prefix") . CurDefaultLabel
		PersonalMenu.Add(_DefaultCatLabel, DefaultSectionMenu)
		_CloseOnAddLabel := t("menu.hotstrings.close_on_add")
		PersonalMenu.Add(_CloseOnAddLabel, (*) => _TogglePersonalCloseOnAdd(PersonalMenu))
		if (_EditorPrefGet("CloseOnAdd", "1") == "1") {
			PersonalMenu.Check(_CloseOnAddLabel)
		}
		if (Features["Personal"].Has("__Order") and Features["Personal"]["__Order"].Length > 0) {
			PersonalMenu.Add()
			for FeatName in Features["Personal"]["__Order"] {
				if FeatName == "-" {
					PersonalMenu.Add()
				} else if Features["Personal"].Has(FeatName) {
					MenuAddItem(PersonalMenu, "Personal", FeatName)
				}
			}
		}
		PersonalCount := 0
		for _, SecData in TomlData["sections"] {
			PersonalCount += SecData["entries"].Length
		}
		PersonalTitle := GetCategoryTitle("Personal")
			. (PersonalCount > 0 ? " (" . FmtCount(PersonalCount) . ")" : "")
		HotstringsMenu.Add(PersonalTitle, PersonalMenu)
	}
	; Extension TOML files — one submenu entry per file, alphabetically sorted
	for _, ExtPath in ExtTomlFiles {
		SplitPath ExtPath, &ExtFileName, , , &ExtStem
		ExtSections := _ParseExtTomlSections(ExtPath)
		ExtCount := 0
		for _, _ES in ExtSections {
			ExtCount += _ES["count"]
		}
		ExtMenu := Menu()
		ExtMenu.Add(t("menu.hotstrings.open_file"), _MakeOpenFileFn(ExtPath))
		if (ExtSections.Length > 0) {
			ExtMenu.Add()
			for _, _ES in ExtSections {
				SecLabel := _ES["description"] . " (" . FmtCount(_ES["count"]) . ")"
				ExtMenu.Add(SecLabel, (*) => NoAction())
				ExtMenu.Disable(SecLabel)
			}
		}
		ExtTitle := ExtStem . (ExtCount > 0 ? " (" . FmtCount(ExtCount) . ")" : "")
		HotstringsMenu.Add(ExtTitle, ExtMenu)
	}
	; 4. Bundled Extensions — one submenu per extension folder, then one sub-submenu
	;    per TOML file inside that extension's hotstrings/ sub-folder.
	;    The extensions directory lives at static/extensions/ next to the drivers.
	global _StaticDir
	ExtensionsBaseDir := _StaticDir . "\extensions\"
	BundledExtensions := []   ; [{id, name, toml_files: [{path, stem, sections, count}]}]
	ExtTotal := 0
	if DirExist(ExtensionsBaseDir) {
		Loop Files ExtensionsBaseDir . "*", "D" {
			ExtId   := A_LoopFileName
			ExtDir  := A_LoopFileFullPath
			ManifestPath := ExtDir . "\manifest.toml"
			; Read extension display name from manifest (fall back to folder id)
			ExtDisplayName := ExtId
			if FileExist(ManifestPath) {
				try {
					ManifestContent := FileRead(ManifestPath, "UTF-8")
					if RegExMatch(ManifestContent, "name\s*=\s*`"([^`"]+)`"", &NM)
						ExtDisplayName := NM[1]
				}
			}
			HsDir := ExtDir . "\hotstrings\"
			TomlFiles := []
			if DirExist(HsDir) {
				Loop Files HsDir . "*.toml" {
					FileSections := _ParseExtTomlSections(A_LoopFileFullPath)
					FileCount := 0
					for _, _FS in FileSections
						FileCount += _FS["count"]
					ExtTotal += FileCount
					SplitPath A_LoopFileFullPath, , , , &FileStem
					TomlFiles.Push({ path: A_LoopFileFullPath, stem: FileStem
						, sections: FileSections, count: FileCount })
				}
			}
			BundledExtensions.Push({ id: ExtId, name: ExtDisplayName, toml_files: TomlFiles })
		}
	}

	HotstringsMenu.Add() ; Separator before Extensions block
	ExtHeader := MenuSectionTitle(t("menu.extensions.header") . (ExtTotal > 0 ? " (" . FmtCount(ExtTotal) . ")" : ""))
	HotstringsMenu.Add(ExtHeader, (*) => NoAction())
	HotstringsMenu.Disable(ExtHeader)
	if (BundledExtensions.Length == 0) {
		EmptyLabel := t("menu.extensions.empty")
		HotstringsMenu.Add(EmptyLabel, (*) => NoAction())
		HotstringsMenu.Disable(EmptyLabel)
	} else {
		for _, Ext in BundledExtensions {
			ExtHsMenu := Menu()
			ExtTotalForExt := 0
			for _, TF in Ext.toml_files
				ExtTotalForExt += TF.count
			if (Ext.toml_files.Length == 0) {
				NoHsLabel := t("menu.extensions.empty")
				ExtHsMenu.Add(NoHsLabel, (*) => NoAction())
				ExtHsMenu.Disable(NoHsLabel)
			} else {
				for _, TF in Ext.toml_files {
					TFMenu := Menu()
					if (TF.sections.Length == 0) {
						NoSecLabel := t("menu.extensions.empty")
						TFMenu.Add(NoSecLabel, (*) => NoAction())
						TFMenu.Disable(NoSecLabel)
					} else {
						for _, Sec in TF.sections {
							SecLabel := Sec["description"] . " (" . FmtCount(Sec["count"]) . ")"
							TFMenu.Add(SecLabel, (*) => NoAction())
							TFMenu.Disable(SecLabel)
						}
					}
					TFTitle := TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : "")
					ExtHsMenu.Add(TFTitle, TFMenu)
				}
			}
			ExtMenuTitle := Ext.name . (ExtTotalForExt > 0 ? " (" . FmtCount(ExtTotalForExt) . ")" : "")
			HotstringsMenu.Add(ExtMenuTitle, ExtHsMenu)
		}
	}

	; Compute grand total = common + personal + extensions
	GrandTotal := CommonTotal + TotalPersonal + ExtTotal
	HotstringsMenuTitle := t("menu.hotstrings.title") . (GrandTotal > 0 ? " (" . FmtCount(GrandTotal) . ")" : "")
	A_TrayMenu.Add(HotstringsMenuTitle, HotstringsMenu)
	if HotstringsAllEnabled {
		A_TrayMenu.Check(HotstringsMenuTitle)
	}

	; ── IA / LLM — sits right after Hotstrings, mirroring the Hammerspoon menu order ──
	; Build the LLM_Tray_Init payload by reading the v2 nested LLM map
	; populated by MirrorV1ToV2_LLM at boot (see lib/v1_v2_mirror.ahk § 5
	; for the v1-flat -> v2-nested mapping). The downstream LLM_Tray_Init
	; still expects a flat ``saved_opts`` Map with the legacy key names,
	; so we read from the nested v2 paths and flatten back here.
	; ``onboarding_seen`` and ``app_profile_overrides`` keep their direct
	; IniCacheGet reads — they are runtime state, not v2-declared features.
	_LlmSavedOpts := Map()
	_LlmSavedOpts["enabled"]                := FeaturesV2["llm"]["enabled"]
	_LlmSavedOpts["model"]                  := FeaturesV2["llm"]["models"]["ollama"]
	_LlmSavedOpts["profile_id"]             := FeaturesV2["llm"]["profiles"]["active"]
	_LlmSavedOpts["temperature"]            := FeaturesV2["llm"]["generation"]["temperature"]
	_LlmSavedOpts["n_predictions"]          := FeaturesV2["llm"]["profiles"]["num_predictions"]
	_LlmSavedOpts["min_words"]              := FeaturesV2["llm"]["generation"]["min_words"]
	_LlmSavedOpts["max_words"]              := FeaturesV2["llm"]["generation"]["max_words"]
	_LlmSavedOpts["debounce_ms"]            := FeaturesV2["llm"]["trigger"]["debounce_ms"]
	_LlmSavedOpts["ctx_chars"]              := FeaturesV2["llm"]["generation"]["context_length"]
	_LlmSavedOpts["instant_on_word_end"]    := FeaturesV2["llm"]["trigger"]["instant_on_word_end"]
	_LlmSavedOpts["auto_profile_for_model"] := FeaturesV2["llm"]["profiles"]["auto_profile_for_model"]
	_LlmSavedOpts["inline_autotype"]        := FeaturesV2["llm"]["trigger"]["inline_autotype"]

	; Per-app profile overrides — flat ``app=profile;app2=profile2``,
	; stored as a runtime state string in v1 ``[LLM] app_profile_overrides``.
	; The v2 manifest doesn't declare this; keep the direct IniCacheGet
	; path so the tray-menu populator stays self-contained.
	_LlmRawAppOverrides := IniCacheGet(_IniCache, "LLM", "app_profile_overrides")
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
	LLM_Tray_Init(_LlmSavedOpts)

	; ── 📊 Métriques — mirrors the HS Métriques submenu position exactly:
	; sits between Hotstrings + AI and the Shortcuts (Raccourcis) submenu.
	; The parent entry doubles as a
	; global ON/OFF toggle for the keylogger feature. OFF by default — it
	; *is* a keylogger — and only flips ON after the user explicitly
	; acknowledges the security warning. While OFF, the sub-items remain
	; visible but greyed out so the menu shape stays familiar.
	BuildMetricsMenu()
	if MetricsShortcuts.enabled {
		A_TrayMenu.Check(t("menu.metrics.title"))
	}

	; ── Raccourcis and Tap-Holds — standalone, like HS Raccourcis and Karabiner ──
	if SubMenus.Has("Shortcuts") {
		A_TrayMenu.Add(GetCategoryTitle("Shortcuts"), SubMenus["Shortcuts"])
		if ShortcutsGated {
			A_TrayMenu.Check(GetCategoryTitle("Shortcuts"))
		}
	}
	; TapHolds: prepend a global on/off toggle before adding to the tray.
	; Master gate (Phase 7.4) — see comment in the Layout block above.
	if SubMenus.Has("TapHolds") {
		TapHoldsAllEnabled := IsCategoryGated("TapHolds")
		AddCategoryToggleItem(SubMenus["TapHolds"],
			t("menu.tapholds.on"),
			t("menu.tapholds.off"),
			TapHoldsAllEnabled,
			(*) => ToggleCategoryAllFeatures("TapHolds", !TapHoldsAllEnabled))
		A_TrayMenu.Add(GetCategoryTitle("TapHolds"), SubMenus["TapHolds"])
		; Check the parent title when all tap-holds are enabled — mirrors HS checked submenu.
		if TapHoldsAllEnabled {
			A_TrayMenu.Check(GetCategoryTitle("TapHolds"))
		}
	}

	; ── Gestes — custom submenu mirroring Hammerspoon's gesture picker ──
	GesturesMenu := BuildGesturesMenu()
	A_TrayMenu.Add(GetCategoryTitle("Gestures"), GesturesMenu)
	if Features["Gestures"]["Enabled"].Enabled {
		A_TrayMenu.Check(GetCategoryTitle("Gestures"))
	}

	; ── Actions globales — last item of the features block (sits right above the
	; separator that closes the block), grouped with the other user-facing toggles
	; rather than with the version / channel / language items.
	GlobalActionsMenu := Menu()
	GlobalActionsMenu.Add(t("menu.global.enable_all"),  ToggleAllFeaturesOn)
	GlobalActionsMenu.Add(t("menu.global.disable_all"), ToggleAllFeaturesOff)
	GlobalActionsMenu.Add(t("menu.global.reset_defaults"), ReloadWithDefaultConfig)
	A_TrayMenu.Add(t("menu.global.title"), GlobalActionsMenu)

	A_TrayMenu.Add() ; Single separator between feature submenus and configuration items

	AboutMenu := Menu()
	Ver := Updater_CurrentVersion()
	VerLabel := "ErgoptiPlus " . Ver
	; First item: clicking the version label opens the release page DIRECTLY,
	; with no intermediate dialog. The URL is the build-stamped
	; BUNDLE_RELEASE_URL (deep-links to the exact running version) when
	; available, the channel "latest" page otherwise. In local-source mode
	; there is no meaningful release page (the running code is whatever the
	; dev tree happens to have on disk, not anything published) so the click
	; handler is a no-op and the item is greyed out to hint at that.
	if Updater_IsLocalSource() {
		AboutMenu.Add(VerLabel, (*) => NoAction())
		AboutMenu.Disable(VerLabel)
	} else {
		AboutMenu.Add(VerLabel, Updater_OpenCurrentRelease)
	}
	AboutMenu.Add() ; Separator
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INTERVAL_PRESETS
	global UPDATER_LATEST_RELEASE
	if Updater_IsLocalSource() {
		; Local source build — channel selection is meaningless, show a grayed info item.
		LocalSourceLabel := t("menu.about.channel_local_source")
		AboutMenu.Add(LocalSourceLabel, (*) => NoAction())
		AboutMenu.Disable(LocalSourceLabel)
	} else {
		; Update channel as a SUBMENU rather than two siblings with check marks.
		; Reduces vertical noise in the parent menu and groups the mutually-
		; exclusive choice under a single header.
		ChannelMenu := Menu()
		ChannelMenu.Add(t("menu.about.channel_main"), (*) => Updater_SetChannel("main"))
		ChannelMenu.Add(t("menu.about.channel_dev"),  (*) => Updater_SetChannel("dev"))
		ChannelMenu.Check((UPDATER_CHANNEL == "dev") ? t("menu.about.channel_dev") : t("menu.about.channel_main"))
		AboutMenu.Add(t("menu.about.channel_menu"), ChannelMenu)

		; Frequency submenu: 12 presets, current cadence pre-checked.
		; ``Updater_SetCheckInterval`` re-arms the background timer immediately
		; so the user feels the change without waiting for the next tick.
		FreqMenu := Menu()
		CurrentLabel := ""
		for Preset in UPDATER_INTERVAL_PRESETS {
			Label := t("menu.about.frequency." . Preset.Code)
			FreqMenu.Add(Label, _MakeFreqSetter(Preset.Seconds))
			if (Preset.Seconds == UPDATER_CHECK_INTERVAL)
				CurrentLabel := Label
		}
		if (CurrentLabel != "")
			FreqMenu.Check(CurrentLabel)
		AboutMenu.Add(t("menu.about.frequency_menu"), FreqMenu)
	}
	AboutMenu.Add() ; Separator
	; In local-source mode the user is running from a working copy; there are no
	; "release notes" to surface and update checks would be misleading. Skip
	; both rows entirely in that case — what is hidden cannot confuse.
	if !Updater_IsLocalSource() {
		AboutMenu.Add(t("menu.about.check_for_updates"), Updater_CheckForUpdate)
		AboutMenu.Add(t("menu.about.changelog"),         Updater_ShowChangelog)
		; "Install update" — visible only when the background poller has
		; detected a new version (cache populated). One click opens the
		; install prompt with release notes + the binary-swap button.
		if IsSet(UPDATER_LATEST_RELEASE) and Type(UPDATER_LATEST_RELEASE) == "Object" {
			AboutMenu.Add(t("menu.about.install_update"), Updater_ShowAvailableUpdate)
		}
	}
	AboutMenu.Add(t("menu.about.open_releases_page"), (*) => Run(Updater_ReleasesPageUrl()))
	A_TrayMenu.Add(t("menu.about.title"), AboutMenu)

	; "Setup wizard" sits first — it is the only way to re-trigger onboarding
	; and is also what users look for when something feels off, so it gets the
	; top slot. "Config folder" comes next (it answers the very next question
	; the user typically has: "where are my settings stored?"), and the
	; language picker sits underneath the config folder rather than between
	; the wizard and folder where it interrupted the natural reading flow.
	A_TrayMenu.Add(t("menu.global.setup_wizard"), Onboarding_ShowFromMenu)

	; ── Script management ──
	global MenuSuspend
	MenuSuspend := t("menu.global.suspend")
	A_TrayMenu.Add(t("menu.global.config_folder"), FilePathsEditor)

	LangMenu := Menu()
	I18nBuildLanguageMenu(LangMenu)
	A_TrayMenu.Add(t("menu.global.language"), LangMenu)
	A_TrayMenu.Add() ; Separator before lifecycle actions
	A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
	A_TrayMenu.Add(t("menu.global.reload"), ActivateReload)
	A_TrayMenu.Add(t("menu.global.quit"), ActivateExitApp)

	; ── Debug tools — grouped in a submenu to keep the top-level menu tidy.
	; Mirrors Hammerspoon's "⚠ Debug" entry (Console + log shortcuts);
	; Window Spy / List Vars / Key History are AutoHotkey-specific particulars. ──
	DebuggingMenu := Menu()
	DebuggingMenu.Add(t("menu.debug.window_spy"),    WindowSpy)
	DebuggingMenu.Add(t("menu.debug.list_vars"),     ActivateListVars)
	DebuggingMenu.Add(t("menu.debug.key_history"),   ActivateKeyHistory)
	DebuggingMenu.Add(t("menu.debug.open_logs"),     OpenLogsFolder)
	DebuggingMenu.Add(t("menu.debug.open_today_log"), OpenTodayLog)
	A_TrayMenu.Add(t("menu.debug.title"), DebuggingMenu)
}

; Returns a menu callback bound to a specific check interval (in seconds).
; Defined here rather than inline inside the menu builder so AHK captures the
; value at call time — fat-arrow closures defined inside the loop would all
; share the same loop-variable reference and persist only the last preset.
_MakeFreqSetter(Seconds) {
	return (*) => Updater_SetCheckInterval(Seconds)
}


; Opens personal_shortcuts.ahk in Notepad. Same function the gesture binding
; uses (modules/gestures.ahk:GestureEditPersonalShortcuts), but kept callable
; from the tray menu so the user has both entry points.
OpenPersonalShortcuts(*) {
	Path := ScriptInformation["PersonalAhkPath"]
	EnsurePersonalShortcutsFile(Path)
	Run('notepad.exe "' . Path . '"')
}

; Opens the per-user log directory (under <ConfigDir>/ahk/logs/) in Explorer.
; Creates it on first use so the user never sees an "introuvable" dialog
OpenLogsFolder(*) {
	LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
		? _ConfigDir . "ahk\logs\"
		: A_ScriptDir . "\logs\"
	if !DirExist(LogDir) {
		try DirCreate(LogDir)
	}
	Run('explorer.exe "' . LogDir . '"')
}

; Opens today's rolling log file in Notepad. LOGGER_LOG_PATH is refreshed by
; LoggerInit() at every menu rebuild, so the path follows day rollover.
OpenTodayLog(*) {
	global LOGGER_LOG_PATH
	Path := (IsSet(LOGGER_LOG_PATH) and LOGGER_LOG_PATH != "")
		? LOGGER_LOG_PATH
		: ""
	if Path = "" or !FileExist(Path) {
		; Fall back to the day-stamped path under <ConfigDir>/ahk/logs/ even if the
		; logger hasn't initialised yet (very early boot, edge case)
		LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
			? _ConfigDir . "ahk\logs\"
			: A_ScriptDir . "\logs\"
		Path := LogDir . "ErgoptiPlus_" . FormatTime(, "yyyy-MM-dd") . ".log"
	}
	Run('notepad.exe "' . Path . '"')
}

; Minimal template for personal_shortcuts.ahk — created on first launch so the
; user has a starter file with the canonical header. The header below is the
; same one the user is expected to keep at the top of their personal file, so
; both views stay perfectly aligned across ErgoptiPlus updates.
global PERSONAL_SHORTCUTS_TEMPLATE := "; personal_shortcuts.ahk`r`n"
	. ";`r`n"
	. "; ==============================================================================`r`n"
	. "; MODULE: Personal Shortcuts`r`n"
	. "; DESCRIPTION:`r`n"
	. "; User-defined hotkeys layered on top of the ErgoptiPlus driver. Loaded into`r`n"
	. "; the driver via a forwarding stub generated by EnsurePersonalShortcutsFile, so`r`n"
	. "; this file lives at <ConfigDirPath>/personal_shortcuts.ahk and survives`r`n"
	. "; ErgoptiPlus updates without any manual copying.`r`n"
	. ";`r`n"
	. "; FEATURES & RATIONALE:`r`n"
	. "; 1. Toggle-gated bindings — every binding is wrapped in`r`n"
	. ";    #HotIf PersonalFeatureEnabled(`"<Name>`") so the matching`r`n"
	. ";    tray-menu checkbox in « 🎯 Raccourcis » → « Raccourcis personnels » fully controls`r`n"
	. ";    whether the binding fires, with persistence in the configuration INI.`r`n"
	. "; 2. Two-section layout — every feature is registered in section 1 and bound`r`n"
	. ";    (along with any helper functions it needs) in section 2 with matching`r`n"
	. ";    subsection numbering. The at-a-glance roster of available toggles and the`r`n"
	. ";    wiring of each one are each easy to scan in isolation.`r`n"
	. "; 3. AHK input level 2 is already set by the parent driver before this file is`r`n"
	. ";    included, so personal hotkeys override the layout's remappings without`r`n"
	. ";    this file needing its own #InputLevel directives.`r`n"
	. ";`r`n"
	. "; ADDING A FEATURE — drop a RegisterPersonalFeature call into section 1 and`r`n"
	. "; the matching #HotIf-gated binding into section 2. The toggle then appears`r`n"
	. "; in the tray under « 🎯 Raccourcis » → « Raccourcis personnels ». Example:`r`n"
	. ";`r`n"
	. ";     RegisterPersonalFeature(`"LockScreen`", true,`r`n"
	. ";         `"Lock the workstation with Ctrl + Alt + L`")`r`n"
	. ";`r`n"
	. ";     #HotIf PersonalFeatureEnabled(`"LockScreen`")`r`n"
	. ";     ^!l:: DllCall(`"user32\LockWorkStation`")`r`n"
	. ";     #HotIf`r`n"
	. "; ==============================================================================`r`n"
	. "`r`n"
	. "#Requires AutoHotkey v2.0`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "; =======================================`r`n"
	. "; =======================================`r`n"
	. "; ======= 1/ Feature Registration =======`r`n"
	. "; =======================================`r`n"
	. "; =======================================`r`n"
	. "`r`n"
	. "; (Add RegisterPersonalFeature calls here — see the example in the header.)`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "`r`n"
	. "; ==================================`r`n"
	. "; ==================================`r`n"
	. "; ======= 2/ Hotkey Bindings =======`r`n"
	. "; ==================================`r`n"
	. "; ==================================`r`n"
	. "`r`n"
	. "; (Add #HotIf-gated hotkey blocks here — see the example in the header.)`r`n"
	. "`r`n"

; Reconstructs the tray menu in place without a full process restart.
; Suitable for lightweight UI-only toggles (WPM display, color themes) that
; do not require re-parsing config or rebinding hotkeys. State-changing
; toggles that write to TOML must still call Reload().
RebuildTrayMenu() {
	global SubMenus
	A_TrayMenu.Delete()
	SubMenus := Map()
	InitSubMenus()
	initMenu()
}
