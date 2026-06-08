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

; Add a clickable menu item driven entirely by a manifest feature entry —
; no Features v1 lookup. Used by the menu builder for categories that have
; been migrated to consume the manifest directly (Layout first).
;
; ``ManifestEntry`` is a Map from ``ManifestFeaturesForSection`` carrying
; ``path`` (canonical v2), ``id``, ``description_key``, etc.
; ``V1CategoryPath`` is the dotted v1 prefix used by the tray-write
; callbacks (``Layout``, ``Shortcuts``, ``Autocorrection``, …); the v1 id
; comes from the inverse rename table via ``ManifestPathToLegacyPath``.
MenuAddItemFromManifest(MenuParent, ManifestEntry, V1CategoryPath) {
	V2Path := ManifestEntry["path"]
	V1Path := ManifestPathToLegacyPath(V2Path)
	if (V1Path == "") {
		try LoggerWarn("Menu", "MenuAddItemFromManifest: no v1 path for '{1}' — skipping.", V2Path)
		return
	}
	MenuTitle := MenuLabelFromManifestEntry(ManifestEntry)
	; Apply the same runtime substitutions ``GetMenuTitleByPath`` does for
	; the legacy path (count suffix " (N)" for hotstring categories, the
	; live ``{date}`` for DynamicHotstrings entries) so the manifest-driven
	; render is visually identical to the v1 Features-driven render.
	MenuTitle := _ApplyMenuLabelDynamicSubstitutions(MenuTitle, V1Path)
	RegisterMenuItem(MenuParent, MenuTitle, (*) => ToggleMenuVariableByPath(V1Path))

	State := GetFeatureState(V1Path)
	IsEnabled := State.Has("Enabled") and State["Enabled"]
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	; Master-gate greying — same logic as MenuAddItem.
	if !IsCategoryGated(_MasterCategoryFor(V1CategoryPath)) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Add a clickable menu item with a pre-resolved label — bypasses the
; manifest+i18n lookup chain in GetMenuTitleByPath. Used by render paths
; that already hold the label string (e.g. personal hotstring sections
; whose descriptions come from the user's personal_hotstrings.toml).
;
; ``MasterCategory`` is the v1 PascalCase top-level category whose
; master-gate state controls greying for this item (``Hotstrings``,
; ``Shortcuts``, ``Layout``, ``TapHolds``).
MenuAddItemWithLabel(MenuParent, V1Path, MenuTitle, MasterCategory) {
	RegisterMenuItem(MenuParent, MenuTitle, (*) => ToggleMenuVariableByPath(V1Path))

	IsEnabled := _ResolveMenuItemEnabled(V1Path)
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	if !IsCategoryGated(MasterCategory) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Resolve the .Enabled state of a v1-path feature. TapHolds variants are
; not in the manifest (their v2 schema condenses mutually-exclusive variant
; groups into a single resolved tuple), so they are resolved by comparing
; the variant's (tap, hold) tuple against TapHold["keys"][V2KeyId] via
; IsTapHoldVariantActive. Everything else is read from Features.
_ResolveMenuItemEnabled(V1Path) {
	if (StrLen(V1Path) >= 9 and SubStr(V1Path, 1, 9) == "TapHolds.") {
		return IsTapHoldVariantActive(V1Path)
	}
	State := GetFeatureState(V1Path)
	if State.Has("Enabled") {
		return (State["Enabled"] = true)
	}
	return false
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

	; Runtime state — read Features via the path translator first; for
	; features outside the manifest (TapHolds variants) fall back to the
	; legacy ``Features[X].Enabled`` value which is still kept in sync by
	; ToggleMenuVariableByPath's mutually-exclusive sub-Map handling.
	IsEnabled := _ResolveMenuItemEnabled(FullPath)
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	; Phase 7.5 (UX): grey out the item when its master category gate is
	; off. The toggle is still visible (so the user can see what would be
	; available if they re-enabled the master) but clicking it does
	; nothing — ApplyMasterGatesToFeatures forces every feature in the
	; category to false in Features, so the HotIf evaluations all
	; short-circuit regardless of the persisted per-feature state.
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
	for _, HotsCat in ["Autocorrection", "DistancesReduction", "SFBsReduction",
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
	MenuTitle := GetMenuTitleByPath(FullPath)
	State := GetFeatureState(FullPath)
	IsEnabled := _ResolveMenuItemEnabled(FullPath)
	CurrentLetter := State.Has("Letter") ? StrLower(State["Letter"]) : ""

	LetterMenu := Menu()

	; Entry that disables the remap without touching Letter
	DisabledLabel := t("common.disabled")
	RegisterMenuItem(LetterMenu, DisabledLabel, ((p) => (*) => SetFeatureLetterOff(p))(FullPath))
	if !IsEnabled {
		LetterMenu.Check(DisabledLabel)
	}

	LetterMenu.Add() ; Separator

	; 26 letters a-z, displayed uppercase for menu legibility.
	; RegisterMenuItem (instead of LetterMenu.Add) installs the OnMessage
	; dispatcher bypass so clicks survive the AHK 2.0 menu-callback drop.
	loop 26 {
		L := Chr(Ord("a") + A_Index - 1)
		UpperL := StrUpper(L)
		RegisterMenuItem(LetterMenu, UpperL,
			((p, l) => (*) => SetFeatureLetter(p, l))(FullPath, L))
		if IsEnabled and CurrentLetter == L {
			LetterMenu.Check(UpperL)
		}
	}

	MenuParent.Add(MenuTitle, LetterMenu)
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	}

	; Phase 7.5 (UX): grey out the picker when its master category gate
	; is off — same rationale as MenuAddItem above.
	if !IsCategoryGated(_MasterCategoryFor(FeatureCategoryPath)) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Sets the remap target letter on a feature and enables it. Persists both
; flags via the v1->v2 path translator so the change survives reload, then
; reloads to wire the new shortcut at the layer level. The Reload runs
; the boot pipeline which re-derives the v1 Features Map from Features
; via lib/master_gates.ahk — no need to mutate v1 in-place.
SetFeatureLetter(FullPath, Letter) {
	WriteFeatureBatch([
		Map("v1_path", FullPath . ".Enabled", "value", true),
		Map("v1_path", FullPath . ".Letter",  "value", Letter),
	])
	Reload
}

; Disables a letter-picker feature without touching its Letter, so the
; previously-selected mapping is restored on the next picker selection.
SetFeatureLetterOff(FullPath) {
	WriteFeatureUpdate(FullPath . ".Enabled", false)
	Reload
}

; Retrieve a feature title by its path. The label is sourced from the
; canonical manifest entry's ``description_key`` (resolved against the
; current i18n locale via ``MenuLabelFromManifestEntry``) whenever a
; matching entry exists. Non-manifest features fall through to dedicated
; handlers: Personal shortcuts use _PersonalShortcutsRegistry descriptions;
; TapHolds variants use TapHoldVariantLabel (dynamically built from the v2
; tuple and locale-aware i18n keys). The live ``Letter``
; suffix appended for letter pickers is always read from Features so
; the title reflects the user's persisted choice immediately after a Reload.
;
; Two runtime substitutions are layered on top of the i18n value so the
; menu reflects live data:
;   - ``{date}`` placeholders in DynamicHotstrings entries are replaced
;     with the current date in the per-feature format.
;   - Hotstring categories with a non-zero entry count get a ``" (N)"``
;     suffix mirroring the legacy ``EnrichSectionDescriptionsWithCounts``
;     behaviour.
GetMenuTitleByPath(FullPath) {
	; Try the manifest+i18n first — single source of truth for declared
	; features. Non-manifest paths fall through to per-subsystem handlers:
	; Personal shortcuts use _PersonalShortcutsRegistry; TapHolds variants
	; use TapHoldVariantLabel.
	V2Path := LegacyPathToManifestPath(FullPath)
	Entry := false
	if (V2Path != "") {
		Entry := ManifestFindEntryByPath(V2Path)
		; Letter pickers (Modélisation α with split schema) have no bare
		; section entry — only ``<section>.enabled`` and ``<section>.letter``
		; children, with the picker's description_key carried by ``.enabled``.
		; Bare-α features (GPT, Search, TakeNote) DO have a bare section
		; entry and resolve on the first lookup; only the split variant
		; needs this fallback. Without it, GetMenuTitleByPath falls all the
		; way through to the raw FullPath sentinel and the menu shows
		; "Shortcuts.EGrave" / "Shortcuts.AGrave" / etc.
		if (Entry == false) {
			Entry := ManifestFindEntryByPath(V2Path . ".enabled")
		}
	}
	if (Entry != false) {
		Label := TryMenuLabelFromManifestEntry(Entry)
		if (Label != "") {
			Label := _ApplyMenuLabelDynamicSubstitutions(Label, FullPath)
			if _ManifestEntryHasLetter(Entry) {
				State := GetFeatureState(FullPath)
				if (State.Has("Letter") and State["Letter"] != "") {
					Label := Label StrUpper(State["Letter"])
				}
			}
			return Label
		}
	}

	; Personal shortcuts: description is stored in _PersonalShortcutsRegistry,
	; not the manifest.
	Parts := StrSplit(FullPath, ".")
	if (Parts.Length == 3 and Parts[1] == "Shortcuts" and Parts[2] == "Personal") {
		global _PersonalShortcutsRegistry
		Name := Parts[3]
		if _PersonalShortcutsRegistry.Has(Name) {
			Desc := _PersonalShortcutsRegistry[Name]
			return (Desc != "") ? Desc : Name
		}
		return Name
	}

	; TapHolds variants: labels are built dynamically from the (tap_action,
	; hold_modifier / hold_layer) tuple via TapHoldVariantLabel so they
	; honour the active locale without a per-variant string table.
	if (Parts[1] == "TapHolds") {
		if Parts.Length == 2 {
			return TapHoldGroupLabel(Parts[2])
		}
		if Parts.Length == 3 {
			return TapHoldVariantLabel(Parts[2], Parts[3])
		}
	}

	return FullPath
}

; Detect whether a manifest entry corresponds to a letter-remap feature —
; used to decide whether to append the live letter suffix to the menu
; title. Two schemas to recognise:
;
;   - Bare-α (default is a Map carrying the ``letter`` key directly).
;   - Split-α / letter pickers (the entry IS the section's ``.enabled``
;     child, and the letter lives in a sibling ``.letter`` entry). The
;     resolver retrieves the sibling via ``ManifestFindEntryByPath``
;     keyed on ``<section>.letter``; if it exists this is a letter
;     picker and the suffix should be appended.
_ManifestEntryHasLetter(Entry) {
	if !(IsObject(Entry) and Entry.Has("default")) {
		return false
	}
	Def := Entry["default"]
	if (Type(Def) == "Map" and Def.Has("letter")) {
		return true
	}
	if (Entry.Has("section") and Entry["section"] != "") {
		Sibling := ManifestFindEntryByPath(Entry["section"] . ".letter")
		if (Sibling != false) {
			return true
		}
	}
	return false
}

; Apply runtime substitutions to a menu label fresh out of i18n. Handles
; the DynamicHotstrings ``{date}`` placeholders and appends a ``" (N)"``
; suffix to hotstring category entries that have a non-zero count.
_ApplyMenuLabelDynamicSubstitutions(Label, V1Path) {
	; {date} substitution for the three DynamicHotstrings date entries.
	if (InStr(Label, "{date}")) {
		switch V1Path {
			case "DynamicHotstrings.DateFr":
				Label := StrReplace(Label, "{date}", FormatTime(, "dd/MM/yyyy"))
			case "DynamicHotstrings.DateLongFr":
				_Days   := ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
				_Months := ["janvier", "février", "mars", "avril", "mai", "juin",
				            "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
				_Long := _Days[A_WDay] . " " . FormatTime(, "d") . " " . _Months[FormatTime(, "M") + 0] . " " . FormatTime(, "yyyy")
				Label := StrReplace(Label, "{date}", _Long)
			case "DynamicHotstrings.Date":
				Label := StrReplace(Label, "{date}", FormatTime(, "yyyy_MM_dd"))
		}
	}
	; Append hotstring entry counts for the TOML-backed categories.
	; CountTomlSection expects the TOML section name, which is now the
	; v2 snake_case id — resolve it from the manifest path.
	Parts := StrSplit(V1Path, ".")
	if (Parts.Length == 2) {
		switch Parts[1] {
			case "Autocorrection", "DistancesReduction", "MagicKey", "Rolls", "SFBsReduction":
				V2FullPath := LegacyPathToManifestPath(V1Path)
				if (V2FullPath != "") {
					V2Parts := StrSplit(V2FullPath, ".")
					V2SecId := V2Parts[V2Parts.Length]
					N := CountTomlSection(Parts[1], V2SecId)
					if (N > 0) {
						Label := Label . " (" . N . ")"
					}
				}
			case "DynamicHotstrings":
				N := CountDynamicSection(Parts[2])
				if (N > 0) {
					Label := Label . " (" . N . ")"
				}
		}
	}
	return Label
}

ToggleMenuVariableByPath(FullPath) {
	; Resolve current state via Features first, falling back to Features
	; v1 for non-manifest features (TapHolds variants especially). Without
	; the fallback, the FIRST click on a TapHolds variant would always see
	; CurrentEnabled=false and try to "enable" what's already active.
	CurrentEnabled := _ResolveMenuItemEnabled(FullPath)
	NewValue := !CurrentEnabled

	; Mutually-exclusive groups (Shortcuts sub-Maps: AltGrLAlt, AltGrCapsLock,
	; LAltCapsLock) require every sibling to be set to false in the same
	; atomic batch so the on-disk write reflects the picked variant alone.
	; ``_MutexSiblingPathsFor(FullPath)`` returns the sibling v1 paths for
	; the cases that need it; TapHolds mutex resolution is handled inside
	; ``WriteTapHoldBatch`` itself (last true wins per V1 key) so the writer
	; doesn't need an enumeration here. Everything else returns an empty
	; list — toggles are independent.
	Batch := []
	for _, SiblingPath in _MutexSiblingPathsFor(FullPath) {
		Batch.Push(Map("v1_path", SiblingPath . ".Enabled", "value", false))
	}
	Batch.Push(Map("v1_path", FullPath . ".Enabled", "value", NewValue))
	WriteFeatureBatch(Batch)
	Reload
}

; Return the list of sibling v1 feature paths that must be force-set to false
; when the user toggles ``FullPath`` to true. Empty list means no mutex
; semantics — each toggle in the group is independent.
_MutexSiblingPathsFor(FullPath) {
	global _LegacyShortcutsSubMapGroupMap, _LegacyShortcutsSubMapKeyMap
	Parts := StrSplit(FullPath, ".")

	; Shortcuts sub-Map groups (AltGrLAlt / AltGrCapsLock / LAltCapsLock):
	; true mutex — only one variant can be active. Siblings come from the
	; canonical rename table (the v2 schema is authoritative for which keys
	; the group accepts).
	if (Parts.Length == 3 and Parts[1] == "Shortcuts"
		and _LegacyShortcutsSubMapGroupMap.Has(Parts[2])) {
		Siblings := []
		for V1Key, _V2Key in _LegacyShortcutsSubMapKeyMap {
			if (V1Key != Parts[3]) {
				Siblings.Push(Parts[1] . "." . Parts[2] . "." . V1Key)
			}
		}
		return Siblings
	}

	; TapHolds variant toggles do not need a sibling-false batch: the v2
	; schema condenses the mutually-exclusive variants into a single
	; ``[tap_hold.keys.<id>]`` block, and ``WriteTapHoldBatch`` resolves
	; which variant is active by picking the last true entry per V1 key.
	; Sending just the single ``{variant: NewValue}`` entry is enough.
	;
	; Every other path is independent — return [].
	return []
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
	global Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	DynHandlers := Map(
		"auto_configure",     (M, C) => _GES_AutoConfigure(M, C),
		"manual_tutorial",    (M, C) => _GES_ManualTutorial(M, C),
		"gesture_slots_ahk",  (M, C) => _GES_SlotsAhk(M, C),
		"gesture_slots_2",    (M, C) => _GES_Slots2(M, C),
		"gesture_slots_3",    (M, C) => _GES_Slots3(M, C),
		"gesture_slots_4",    (M, C) => _GES_Slots4(M, C),
		"gesture_slots_5",    (M, C) => _GES_Slots5(M, C),
	)
	GMenu := MenuRenderer_Build("gestures_menu", "Gestures", DynHandlers)
	; Gestures toggle uses a dedicated fn (writes Features.Enabled + Reload)
	; rather than the generic ToggleCategoryAllFeatures used by other menus.
	AddCategoryToggleItem(GMenu,
		t("menu.gestures.on"), t("menu.gestures.off"),
		GestEnabled, (*) => ToggleGesturesEnabled())
	return GMenu
}

; Dynamic handler: auto-configure button.
_GES_AutoConfigure(M, _Cat) {
	RegisterMenuItem(M, t("menu.gestures.auto_configure"), (*) => GestureAutoConfigureAction())
}

; Dynamic handler: manual tutorial button.
_GES_ManualTutorial(M, _Cat) {
	RegisterMenuItem(M, t("menu.gestures.manual_tutorial"), (*) => GestureShowManualTutorialDialog())
}

; Dynamic handler: flat slot list for AHK (mirrors pre-refactor BuildGesturesMenu).
; Iterates GESTURE_SLOTS in order, inserting a separator before tap_4 as before.
_GES_SlotsAhk(M, _Cat) {
	global GestureAssignments, GESTURE_ACTIONS, GESTURE_SLOTS, Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	for _, Slot in GESTURE_SLOTS {
		if (Slot == "tap_4")
			M.Add()
		SlotLabel     := t("gesture.slots." . Slot)
		CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
		CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction)
			? _GestureActionLabel(CurrentAction)
			: t("dialog.action_picker.disabled")
		EntryLabel := SlotLabel . " : " . CurrentLabel
		RegisterMenuItem(M, EntryLabel, ((_s, _l) => (*) => ShowActionPicker(_l,
			GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none",
			(Id) => SetGestureSlotAction(_s, Id)))(Slot, SlotLabel))
		if !GestEnabled
			M.Disable(EntryLabel)
	}
}

; Dynamic handlers for HS finger groups (unused on AHK — manifest filters them out).
_GES_Slots2(M, _Cat) {
	return
}
_GES_Slots3(M, _Cat) {
	return
}
_GES_Slots4(M, _Cat) {
	return
}
_GES_Slots5(M, _Cat) {
	return
}

; Applies a new action to a gesture slot and reloads.
SetGestureSlotAction(Slot, ActionName) {
	GestureSaveAssignment(Slot, ActionName)
	Reload
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
	global Features
	NewVal := !(Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true)
	WriteFeatureUpdate("Gestures.Enabled", NewVal)
	Reload
}





; ====================================
; =====================================
; ======= 1.X / Category toggle =======
; =====================================
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
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
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
	enabled := MetricsShortcuts.enabled

	; Dynamic handlers — each populates the MetricsMenu in place.
	; Closures over ``enabled`` and the label locals below capture the state
	; at build time, matching the previous per-item Disable() calls.

	DynHandlers := Map(
		"show_typing",        (M, C) => _MET_ShowTyping(M, C),
		"shortcut_typing",    (M, C) => _MET_ShortcutTyping(M, C),
		"show_apps",          (M, C) => _MET_ShowApps(M, C),
		"shortcut_apps",      (M, C) => _MET_ShortcutApps(M, C),
		"filter_private",     (M, C) => _MET_FilterPrivate(M, C),
		"filter_secure",      (M, C) => _MET_FilterSecure(M, C),
		"filter_sysauth",     (M, C) => _MET_FilterSysauth(M, C),
		"exclude_apps",       (M, C) => _MET_ExcludeApps(M, C),
		"wpm_widget",         (M, C) => _MET_WpmWidget(M, C),
		"widget_colors",      (M, C) => _MET_WpmWidgetColors(M, C),
		"include_realtime",   (M, C) => _MET_WpmWidgetGraph(M, C),
		"reset_wpm_position", (M, C) => _MET_WpmWidgetReset(M, C),
	)

	MetricsMenu := MenuRenderer_Build("metrics_menu", "Metrics", DynHandlers)
	A_TrayMenu.Add(t("menu.metrics.title"), MetricsMenu)
}

; Dynamic handler: Show Typing button.
_MET_ShowTyping(M, _Cat) {
	Label := t("menu.metrics.show_typing")
	RegisterMenuItem(M, Label, (*) => KLUI_ToggleTyping())
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Typing shortcut picker (label with ZWS to avoid duplicate key clash).
_MET_ShortcutTyping(M, _Cat) {
	Label := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("typing")
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Show Apps button.
_MET_ShowApps(M, _Cat) {
	Label := t("menu.metrics.show_apps")
	RegisterMenuItem(M, Label, (*) => KLUI_ToggleApps())
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Apps shortcut picker (ZWS differentiates from typing sc label).
_MET_ShortcutApps(M, _Cat) {
	Label := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("apps") . Chr(0x200B)
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter private browsing toggle.
_MET_FilterPrivate(M, _Cat) {
	Label := t("menu.metrics.filter_private")
	RegisterMenuItem(M, Label, ToggleFilterPrivate)
	if MetricsFilters.private_browsing
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter secure field toggle.
_MET_FilterSecure(M, _Cat) {
	Label := t("menu.metrics.filter_secure")
	RegisterMenuItem(M, Label, ToggleFilterSecureField)
	if MetricsFilters.secure_field
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter system auth toggle.
_MET_FilterSysauth(M, _Cat) {
	Label := t("menu.metrics.filter_sysauth")
	RegisterMenuItem(M, Label, ToggleFilterSystemAuth)
	if MetricsFilters.system_auth
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: App exclusion — label reflects current count.
_MET_ExcludeApps(M, _Cat) {
	n := MF_DisabledCount()
	Label := (n > 0)
		? StrReplace(StrReplace(t("menu.metrics.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		: t("menu.metrics.exclude_apps")
	RegisterMenuItem(M, Label, OpenMetricsAppPicker)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: WPM floating widget toggle.
_MET_WpmWidget(M, _Cat) {
	Label := t("menu.metrics.show_wpm_widget")
	ColorsLabel := t("menu.metrics.colors_by_source")
	GraphLabel  := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidget(M, Label, ColorsLabel, GraphLabel))
	if WPMWidget.visible
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Widget colors-by-source sub-option.
_MET_WpmWidgetColors(M, _Cat) {
	Label := t("menu.metrics.colors_by_source")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetColors(M, Label))
	if WPMWidget.visible && WPMWidget.use_colors
		M.Check(Label)
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Include realtime graph sub-option.
_MET_WpmWidgetGraph(M, _Cat) {
	Label := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetGraph(M, Label))
	if WPMWidget.visible && WPMWidget.show_graph
		M.Check(Label)
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Reset WPM widget position.
_MET_WpmWidgetReset(M, _Cat) {
	Label := t("menu.metrics.reset_wpm_position")
	RegisterMenuItem(M, Label, (*) => WPMWidget_ResetPosition())
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; ── Layout dynamic handlers ────────────────────────────────────────────────────

; Dynamic handler: Ergopti base-layer feature only (ergopti_base).
_LAY_LayoutFeaturesBase(M, _Cat) {
	for _, LayoutEntry in ManifestFeaturesForSection("ahk.layout") {
		if (LayoutEntry["id"] == "ergopti_base") {
			MenuAddItemFromManifest(M, LayoutEntry, "Layout")
		}
	}
}

; Dynamic handler: AltGr / digit-shift features (direct_access_digits,
; ergopti_alt_gr, ergopti_plus) — usable without the Ergopti base layer.
_LAY_LayoutFeaturesAltGr(M, _Cat) {
	for _, LayoutEntry in ManifestFeaturesForSection("ahk.layout") {
		if (LayoutEntry["id"] != "ergopti_base") {
			MenuAddItemFromManifest(M, LayoutEntry, "Layout")
		}
	}
}


; ── Hotstrings dynamic handlers ────────────────────────────────────────────────

; Compute the grand total count used in the tray menu title label.
; Sums enabled standard, ergopti, dynamic, personal and extension entries.
_HS_ComputeGrandTotal() {
global Features, HotstringCategoriesStd, HotstringCategoriesErgopti
global ScriptInformation, _ExtTotalPersonalCounterGlobal
IsGated := IsCategoryGated("Hotstrings")
CountFn := IsGated ? _CountEnabledForCategory : _CountAllForCategory
Total := 0
for _, Cat in HotstringCategoriesStd
	Total += CountFn(Cat)
for _, Cat in HotstringCategoriesErgopti
	Total += CountFn(Cat)
if Features.Has("hotstrings") and Features["hotstrings"].Has("dynamic") {
	for DKey, DCfg in Features["hotstrings"]["dynamic"] {
		if IsGated {
			if (IsObject(DCfg) and DCfg.Has("enabled") and DCfg["enabled"])
				Total += CountDynamicSection(DKey)
		} else {
			if IsObject(DCfg)
				Total += CountDynamicSection(DKey)
		}
	}
}
; ── Personal hotstrings (standard file + extensions)
PersonalActiveCount := 0
PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
	PersonalTomlData := ReadPersonalToml()
	for _, SecName2 in PersonalTomlData["sections_order"] {
		if (SecName2 == "-" or !PersonalTomlData["sections"].Has(SecName2))
			continue
		PV2Id    := StrLower(SecName2)
		PEnabled := Features["hotstrings"].Has("personal")
			and Features["hotstrings"]["personal"].Has(PV2Id)
			and Features["hotstrings"]["personal"][PV2Id]["enabled"]
		if PEnabled
			PersonalActiveCount += PersonalTomlData["sections"][SecName2]["entries"].Length
	}
}
Total += PersonalActiveCount
Total += IsObject(_ExtTotalPersonalCounterGlobal) ? _ExtTotalPersonalCounterGlobal.value : 0
return Total
}

; Dynamic handler: magic key config entry (prefix + current char + editor).
_HS_MagicKeyConfig(M, _Cat) {
	RegisterMenuItem(M, t("menu.hotstrings.magic_key_prefix") . ScriptInformation["MagicKey"], MagicKeyEditor)
}

; Dynamic handler: repeat-key toggle (★ as repeat key).
_HS_RepeatKey(M, _Cat) {
	global HSE_RepeatEnabled
	Label := t("menu.hotstrings.repeat_key_toggle")
	RegisterMenuItem(M, Label, ToggleRepeatKeyEnabled)
	if HSE_RepeatEnabled {
		M.Check(Label)
	}
}

; Dynamic handler: delays & colours sub-menu. Mirrors the Hammerspoon "delays"
; submenu — the per-category config window, then quick-access per-delay items
; grouped by a separator, exactly like the HS make_delay_item rows: the base
; default expansion delay, then the ★ magic-key and autocorrection per-category
; delays (settable straight from the menu, not only buried in the config window).
_HS_DelaysColors(M, _Cat) {
	global UI_LLM_TIMEOUT_SEC, DYN_HOTSTRINGS_DEFAULT_DELAY
	Sub := Menu()
	RegisterMenuItem(Sub, t("menu.hotstrings.config_item"), (*) => OpenHotstringsConfigWindow())
	Sub.Add()
	RegisterMenuItem(Sub, _HS_DefaultDelayLabel(), (*) => _HS_PromptDefaultDelay())
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("magickey", "menu.hotstrings.delay_magic_key"), (*) => _HS_PromptCategoryDelay("magickey", "menu.hotstrings.delay_magic_key"))
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("autocorrection", "menu.hotstrings.delay_autocorrection"), (*) => _HS_PromptCategoryDelay("autocorrection", "menu.hotstrings.delay_autocorrection"))
	; AI prediction tooltip auto-dismiss timeout — mirrors the HS "Délai
	; d'acceptation IA" item. No TOML [_meta] delay backs the "llm_prediction"
	; key, so its no-override default is the UI constant (20 s); the live tooltip
	; timer reads the same override (lib/tooltip.ahk).
	Sub.Add()
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC), (*) => _HS_PromptCategoryDelay("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC))
	; Dynamic hotstrings (dates, phone/SSN/IBAN prefixes) activation delay —
	; mirrors the HS "Délai autocomplétion" item. Backed by the "dynamichotstrings"
	; override; the no-override default is DYN_HOTSTRINGS_DEFAULT_DELAY (2 s).
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY), (*) => _HS_PromptCategoryDelay("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY))
	M.Add(t("menu.hotstrings.delays_colors"), Sub)
}

; Label for the "default expansion delay" item: "Default : <ms>[ (default)]". The
; "(default)" marker shows when no global override is set — the effective value
; is then the built-in GLOBAL_DEFAULT_DELAY fallback.
_HS_DefaultDelayLabel() {
	global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
	HasGlobal := _HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != ""
	Seconds   := HasGlobal ? _HotstringsOverrides["_global"].Delay : GLOBAL_DEFAULT_DELAY
	Ms        := Round(Seconds * 1000)
	Display   := (Ms == 0) ? t("menu.hotstrings.infinite") : (Ms . " ms")
	; menu.settings.default_indicator already carries a leading space.
	return t("menu.hotstrings.tooltip_default") . " : " . Display . (HasGlobal ? "" : t("menu.settings.default_indicator"))
}

; Prompt for and persist the global default expansion delay (entered in ms),
; mirroring the Hammerspoon make_delay_item prompt. Reuses HotstringsSetOverride
; with the reserved "_global" key, which HotstringsResolve consults as the
; lowest-priority user value, just above the hardcoded GLOBAL_DEFAULT_DELAY.
_HS_PromptDefaultDelay() {
	global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
	HasGlobal := _HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != ""
	CurMs     := Round((HasGlobal ? _HotstringsOverrides["_global"].Delay : GLOBAL_DEFAULT_DELAY) * 1000)
	IB := InputBox(t("menu.hotstrings.delay_prompt"), t("menu.hotstrings.tooltip_default"), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	HotstringsSetOverride("_global", "", "delay", (Val + 0) / 1000)
}

; Label for a per-category default-delay item ("<name> : <ms>[ (default)]").
; Reads the EFFECTIVE delay via HotstringsResolve so it reflects the category's
; TOML [_meta] delay and any user override — the same value the config window
; shows — and marks "(default)" when the user has set no override of their own.
_HS_CategoryDelayLabel(Cat, I18nKey, DefaultSec := "") {
	R       := HotstringsResolve(Cat, "")
	; Categories with no TOML [_meta] delay (llm_prediction, dynamichotstrings)
	; pass an explicit DefaultSec; the TOML-backed ones (magickey, autocorrection)
	; leave it blank and use the resolved category default directly.
	Sec     := R.HasOverride ? R.Delay : ((DefaultSec != "") ? DefaultSec : R.Delay)
	Ms      := Round(Sec * 1000)
	Display := (Ms == 0) ? t("menu.hotstrings.infinite") : (Ms . " ms")
	; menu.settings.default_indicator already carries a leading space.
	return t(I18nKey) . " : " . Display . (R.HasOverride ? "" : t("menu.settings.default_indicator"))
}

; Prompt for and persist a per-category default expansion delay (entered in ms),
; reusing HotstringsSetOverride so the value lands in the same user-override store
; the config window writes to — both UIs therefore stay in sync.
_HS_PromptCategoryDelay(Cat, I18nKey, DefaultSec := "") {
	R     := HotstringsResolve(Cat, "")
	Sec   := R.HasOverride ? R.Delay : ((DefaultSec != "") ? DefaultSec : R.Delay)
	CurMs := Round(Sec * 1000)
	IB := InputBox(t("menu.hotstrings.delay_prompt"), t(I18nKey), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	HotstringsSetOverride(Cat, "", "delay", (Val + 0) / 1000)
}

; Dynamic handler: word-expanders sub-menu, mirroring the terminators sub-menu.
; Built-ins are declared inline (manifest access is not available from tray context);
; custom ones are any chars in the effective string that are not in the built-in list.
_HS_WordExpanders(M, _Cat) {
	Sub := _HS_BuildDelimiterSubMenu()
	M.Add(t("menu.hotstrings.word_expanders"), Sub)
}

; Build the delimiter sub-menu fresh each time so checkbox states are always current.
_HS_BuildDelimiterSubMenu() {
	global HSE_Terminators
	Current      := HotstringsGetWordDelimiters()
	Consumed     := HotstringsGetConsumedDelimiters()
	Defs         := HSE_Terminators.all()
	BuiltinChars := HSE_TerminatorBuiltinChars()

	Sub := Menu()

	; ── Bulk actions ─────────────────────────────────────────────────────────
	RegisterMenuItem(Sub, t("menu.hotstrings.check_all"),      (*) => _HS_DelimSetAll(true))
	RegisterMenuItem(Sub, t("menu.hotstrings.uncheck_all"),    (*) => _HS_DelimSetAll(false))
	RegisterMenuItem(Sub, t("menu.global.reset_defaults"),     (*) => _HS_DelimReset())
	Sub.Add()

	; ── Built-in catalogue entries — rendered in catalogue order with the same
	;    separators as the macOS word-expander menu (single shared source). ──
	for _, D in Defs {
		if (D.Has("type") and D["type"] == "separator") {
			Sub.Add()  ; "-" divider
			continue
		}
		Chars := D["chars"]
		Lbl   := D["label"]
		; The "(consumed)" suffix reflects the actual consumed set — on Windows
		; consumption is opt-in via consumed_delimiters, not the catalogue flag.
		if HSE_TerminatorAnyCharIn(Chars, Consumed)
			Lbl .= " " . t("menu.hotstrings.consumed_suffix")
		; Actionable toggle — route through the dispatcher so AHK 2.0 never
		; silently drops the click (see lib/menu_dispatcher.ahk).
		RegisterMenuItem(Sub, Lbl, ((CharsArr) => (*) => _HS_DelimToggleEntry(CharsArr))(Chars))
		if HSE_TerminatorEntryEnabled(Chars, Current)
			Sub.Check(Lbl)
	}
	Sub.Add()

	; ── Custom delimiters (chars in the active string not owned by any built-in
	;    catalogue entry). Structural CR/LF belong to the "enter" entry. ──
	Loop Parse, Current {
		Ch := A_LoopField
		if (Ch == "`r" or Ch == "`n" or InStr(BuiltinChars, Ch))
			continue
		IsConsumed  := InStr(Consumed, Ch) > 0
		ConsumedSfx := IsConsumed ? (" " . t("menu.hotstrings.consumed_suffix")) : ""
		Lbl   := Ch . " : " . t("menu.hotstrings.custom_label") . ConsumedSfx
		CtSub := Menu()
		RegisterMenuItem(CtSub, t("menu.hotstrings.delete_delimiter"), ((C) => (*) => _HS_DelimRemoveCustom(C))(Ch))
		Sub.Add(Lbl, CtSub)
		; Custom delimiters are always active — they are present in the string
		Sub.Check(Lbl)
	}

	; ── Add custom delimiter button ───────────────────────────────────────────
	RegisterMenuItem(Sub, t("menu.hotstrings.add_delimiter"), (*) => _HS_DelimAddCustom())

	return Sub
}

; Toggle a whole catalogue entry (all of its chars) on/off and persist. The
; toggle logic lives in HSE_TerminatorToggleString (lib/hotstrings_config.ahk)
; so it is shared with the config window and unit-tested.
_HS_DelimToggleEntry(CharsArr) {
	HotstringsSetWordDelimiters(HSE_TerminatorToggleString(HotstringsGetWordDelimiters(), CharsArr))
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Set every built-in catalogue entry on (true) or off (false), preserving any
; user-defined custom chars. Delegates to the shared, tested pure function.
_HS_DelimSetAll(Enable) {
	HotstringsSetWordDelimiters(HSE_TerminatorSetAllString(HotstringsGetWordDelimiters(), Enable))
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Reset all delimiters to the built-in defaults.
_HS_DelimReset() {
	global HOTSTRINGS_DEFAULT_WORD_DELIMITERS
	HotstringsSetWordDelimiters(HOTSTRINGS_DEFAULT_WORD_DELIMITERS)
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Mini GUI: one-shot dialog to pick a delimiter character and its consume mode.
; Returns "" on cancel, or triggers the add immediately.
_HS_DelimAddCustom() {
	G := Gui("+AlwaysOnTop +Owner", t("dialog.hotstrings.new_delimiter_title"))
	G.SetFont("s10", "Segoe UI")
	G.Add("Text", "xm y10 w300", t("dialog.hotstrings.new_delimiter_prompt"))
	EditCtrl := G.Add("Edit", "xm y+6 w60 Limit1")
	ChkCtrl  := G.Add("Checkbox", "xm y+10 w300", t("dialog.hotstrings.consume_checkbox"))
	G.Add("Text", "xm y+14 w300 h1 0x10")  ; horizontal rule
	BtnOK := G.Add("Button", "xm y+10 w80 Default", t("button.ok"))

	; Result holder — set by OK handler, read after WaitClose
	Result := { Char: "", Consume: false, OK: false }

	BtnOK.OnEvent("Click", (*) => _HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result))
	G.OnEvent("Close", (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())

	G.Show("Center AutoSize")
	; Block until the GUI is closed (OK or Cancel)
	WinWaitClose("ahk_id " . G.Hwnd)

	if (!Result.OK or Result.Char == "") {
		return
	}
	Ch      := Result.Char
	Current := HotstringsGetWordDelimiters()
	if (InStr(Current, Ch) > 0) {
		return  ; Already present — silently ignore
	}
	HotstringsSetWordDelimiters(Current . Ch)
	if (Result.Consume) {
		Consumed := HotstringsGetConsumedDelimiters()
		if (!InStr(Consumed, Ch)) {
			HotstringsSetConsumedDelimiters(Consumed . Ch)
		}
	}
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Called by the OK button of the add-delimiter GUI.
_HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result) {
	Ch := EditCtrl.Value
	if (StrLen(Ch) != 1) {
		MsgBox(t("dialog.hotstrings.invalid_body"), t("dialog.hotstrings.invalid_title"), "Icon!")
		return
	}
	Result.Char    := Ch
	Result.Consume := (ChkCtrl.Value == 1)
	Result.OK      := true
	G.Destroy()
}

; Confirm then remove a custom delimiter character (and its consume flag if set).
_HS_DelimRemoveCustom(Char) {
	Res := MsgBox(t("dialog.hotstrings.delete_delimiter_body"), t("dialog.hotstrings.delete_delimiter_title"), "YesNo")
	if (Res != "Yes") {
		return
	}
	HotstringsSetWordDelimiters(StrReplace(HotstringsGetWordDelimiters(), Char, ""))
	Consumed := HotstringsGetConsumedDelimiters()
	if (InStr(Consumed, Char)) {
		HotstringsSetConsumedDelimiters(StrReplace(Consumed, Char, ""))
	}
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Dynamic handler: standard hotstring categories.
_HS_CategoriesStandard(M, _Cat) {
	global HotstringCategoriesStd, SubMenus, Features
	IsGated := IsCategoryGated("Hotstrings")
	CountFn := IsGated ? _CountEnabledForCategory : _CountAllForCategory
	StdTotal := 0
	for _, Cat in HotstringCategoriesStd
		StdTotal += CountFn(Cat)
	DynTotal := 0
	if Features.Has("hotstrings") and Features["hotstrings"].Has("dynamic") {
		for DKey, DCfg in Features["hotstrings"]["dynamic"] {
			if IsGated {
				if (IsObject(DCfg) and DCfg.Has("enabled") and DCfg["enabled"])
					DynTotal += CountDynamicSection(DKey)
			} else {
				if IsObject(DCfg)
					DynTotal += CountDynamicSection(DKey)
			}
		}
	}
	StdTotal += DynTotal
	; Section header is rendered by the manifest (section_header type), so
	; we only need to add the actual category submenus here.
	for _, Category in HotstringCategoriesStd {
		if !SubMenus.Has(Category)
			continue
		Total := CountFn(Category)
		Title := GetCategoryTitle(Category) . " (" . FmtCount(Total) . ")"
		M.Add(Title, SubMenus[Category])
		if IsGated and _IsCategoryFullyEnabled(Category)
			M.Check(Title)
	}
}

; Dynamic handler: dynamic hotstrings category.
_HS_CategoriesDynamic(M, _Cat) {
	global SubMenus, Features
	if !Features.Has("hotstrings") or !Features["hotstrings"].Has("dynamic")
		return
	if !SubMenus.Has("DynamicHotstrings")
		return
	IsGated := IsCategoryGated("Hotstrings")
	DynMenu := SubMenus["DynamicHotstrings"]
	DynTotal := 0
	for DKey, DCfg in Features["hotstrings"]["dynamic"] {
		if IsGated {
			if (IsObject(DCfg) and DCfg.Has("enabled") and DCfg["enabled"])
				DynTotal += CountDynamicSection(DKey)
		} else {
			if IsObject(DCfg)
				DynTotal += CountDynamicSection(DKey)
		}
	}
	DynTitle := GetCategoryTitle("DynamicHotstrings") . " (" . FmtCount(DynTotal) . ")"
	M.Add(DynTitle, DynMenu)
	DynAllEnabled := true
	DynCount := 0
	for _, DCfg2 in Features["hotstrings"]["dynamic"] {
		DynCount++
		if (IsObject(DCfg2) and DCfg2.Has("enabled") and !DCfg2["enabled"])
			DynAllEnabled := false
	}
	if IsGated and DynAllEnabled and DynCount > 0
		M.Check(DynTitle)
}

; Dynamic handler: Ergopti-specific hotstring categories.
_HS_CategoriesErgopti(M, _Cat) {
	global HotstringCategoriesErgopti, SubMenus
	IsGated := IsCategoryGated("Hotstrings")
	CountFn := IsGated ? _CountEnabledForCategory : _CountAllForCategory
	for _, Category in HotstringCategoriesErgopti {
		if !SubMenus.Has(Category)
			continue
		Total := CountFn(Category)
		Title := GetCategoryTitle(Category) . " (" . FmtCount(Total) . ")"
		M.Add(Title, SubMenus[Category])
		if IsGated and _IsCategoryFullyEnabled(Category)
			M.Check(Title)
	}
}

; Dynamic handler: personal hotstrings (personal_hotstrings.toml + ext tree).
global _PersonalExtTree := Map()
global _ExtTotalPersonalCounterGlobal := { value: 0 }

; Pre-scans the personal hotstrings directory to build the tree and sum counts
; so they are available for menu labels and the grand total at build time.
_HS_PreScanPersonal() {
	global ScriptInformation, _PersonalExtTree, _ExtTotalPersonalCounterGlobal
	_PersonalExtTree := Map()
	_ExtTotalPersonalCounterGlobal.value := 0

	if !IsSet(ScriptInformation) or !ScriptInformation.Has("PersonalHotstringsDir")
		return

	HsDir := ScriptInformation["PersonalHotstringsDir"]
	if !DirExist(HsDir)
		return

	_HS_ScanExt(CurrentDir, PathParts) {
		Loop Files CurrentDir . "\*", "DF" {
			if (A_LoopFileAttrib ~= "D") {
				NewParts := PathParts.Clone()
				NewParts.Push(A_LoopFileName)
				_HS_ScanExt(A_LoopFileFullPath, NewParts)
			} else if (A_LoopFileName ~= "i)\.toml$") {
				if (PathParts.Length == 0 and A_LoopFileName == "personal_hotstrings.toml")
					continue
				SplitPath A_LoopFileFullPath, , , , &ExtStem
				FileSections := _ParseExtTomlSections(A_LoopFileFullPath)
				FileCount := 0
				for _, FS in FileSections
					FileCount += FS["count"]
				Node := _HS_GetOrCreateNode(_PersonalExtTree, PathParts)
				Node["tomls"].Push({ path: A_LoopFileFullPath, stem: ExtStem, sections: FileSections, count: FileCount })
				_ExtTotalPersonalCounterGlobal.value += FileCount
			}
		}
	}
	_HS_ScanExt(RegExReplace(HsDir, "[/\\]+$"), [])
}

_HS_GetOrCreateNode(Root, PathParts) {
	Tree := Root
	Node := false
	for _, Part in PathParts {
		if !Tree.Has(Part)
			Tree[Part] := Map("subfolders", Map(), "tomls", [])
		Node := Tree[Part]
		Tree := Node["subfolders"]
	}
	if (Node == false) {
		if !Root.Has("")
			Root[""] := Map("subfolders", Map(), "tomls", [])
		return Root[""]
	}
	return Node
}

; Dynamic handler: personal hotstrings (personal_hotstrings.toml + pre-scanned ext tree).
_HS_Personal(M, _Cat) {
	global ScriptInformation, Features, _PersonalExtTree
	IsGated := IsCategoryGated("Hotstrings")
	PersonalTomlData := false
	PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
	if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
		PersonalTomlData := ReadPersonalToml()
	}

	if (PersonalTomlData != false) {
		TomlData := PersonalTomlData
		PersonalMenu := Menu()
		RegisterMenuItem(PersonalMenu, t("menu.hotstrings.open_editor"), (*) => OpenPersonalEditor())
		RegisterMenuItem(PersonalMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(PersonalTomlPath))
		PersonalMenu.Add()
		ShortcutLabel := t("menu.hotstrings.shortcut_prefix") . ScriptInformation["MagicKey"]
		PersonalMenu.Add(ShortcutLabel, (*) => NoAction())
		PersonalMenu.Disable(ShortcutLabel)
		CurDefaultSec := _EditorPrefGet("DefaultSection", "")
		DefaultSectionMenu := Menu()
		RegisterMenuItem(DefaultSectionMenu, t("menu.hotstrings.default_none"),
			(*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData, DefaultSectionMenu))
		if (CurDefaultSec == "")
			DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
		DefaultSectionMenu.Add()
		for _, SecName in TomlData["sections_order"] {
			if (SecName == "-")
				continue
			SecData  := TomlData["sections"][SecName]
			SecLabel := SecData["description"]
			RegisterMenuItem(DefaultSectionMenu, SecLabel,
				_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu))
			if (CurDefaultSec == SecName)
				DefaultSectionMenu.Check(SecLabel)
		}
		CurDefaultLabel := (CurDefaultSec == "") ? t("menu.hotstrings.default_none")
			: (TomlData["sections"].Has(CurDefaultSec) ? TomlData["sections"][CurDefaultSec]["description"] : CurDefaultSec)
		global _PrevDefaultLabel := CurDefaultLabel
		PersonalMenu.Add(t("menu.hotstrings.default_category_prefix") . CurDefaultLabel, DefaultSectionMenu)
		CloseOnAddLabel := t("menu.hotstrings.close_on_add")
		RegisterMenuItem(PersonalMenu, CloseOnAddLabel, (*) => _TogglePersonalCloseOnAdd(PersonalMenu))
		if (_EditorPrefGet("CloseOnAdd", "1") == "1")
			PersonalMenu.Check(CloseOnAddLabel)
		if (TomlData["sections_order"].Length > 0) {
			PersonalMenu.Add()
			for _, SecName in TomlData["sections_order"] {
				if (SecName == "-") {
					PersonalMenu.Add()
					continue
				}
				if !TomlData["sections"].Has(SecName)
					continue
				SecData  := TomlData["sections"][SecName]
				SecLabel := SecData["description"] . " (" . FmtCount(SecData["entries"].Length) . ")"
				MenuAddItemWithLabel(PersonalMenu, "Personal." . SecName, SecLabel, "Hotstrings")
			}
		}
		PersonalActiveCount := 0
		PersonalAllEnabled  := true
		PersonalSectionCount := 0
		for _, SecName2 in TomlData["sections_order"] {
			if (SecName2 == "-" or !TomlData["sections"].Has(SecName2))
				continue
			PersonalSectionCount++
			PV2Id    := StrLower(SecName2)
			PEnabled := Features["hotstrings"].Has("personal")
				and Features["hotstrings"]["personal"].Has(PV2Id)
				and Features["hotstrings"]["personal"][PV2Id]["enabled"]
			if PEnabled
				PersonalActiveCount += TomlData["sections"][SecName2]["entries"].Length
			else
				PersonalAllEnabled := false
		}
		PersonalTitle := GetCategoryTitle("Personal") . " (" . FmtCount(PersonalActiveCount) . ")"
		M.Add(PersonalTitle, PersonalMenu)
		if IsGated and PersonalAllEnabled and PersonalSectionCount > 0
			M.Check(PersonalTitle)
	}

	RootNode := false
	TreeCopy := _PersonalExtTree.Clone()
	if TreeCopy.Has("") {
		RootNode := TreeCopy[""]
		TreeCopy.Delete("")
	}
	_HS_RenderTree(TreeCopy, M)
	if (RootNode != false) {
		FileNodeList := RootNode["tomls"]
		loop FileNodeList.Length {
			i := A_Index
			loop FileNodeList.Length - i {
				j := A_Index
				if (StrCompare(FileNodeList[j].stem, FileNodeList[j+1].stem) > 0) {
					tmp := FileNodeList[j]
					FileNodeList[j] := FileNodeList[j+1]
					FileNodeList[j+1] := tmp
				}
			}
		}
		for _, TF in FileNodeList {
			TFMenu := Menu()
			RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
			if (TF.sections.Length > 0) {
				TFMenu.Add()
				for _, ES in TF.sections {
					SecLabel := ES["description"] . " (" . FmtCount(ES["count"]) . ")"
					TFMenu.Add(SecLabel, (*) => NoAction())
					TFMenu.Disable(SecLabel)
				}
			}
			M.Add(TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : ""), TFMenu)
		}
	}
}

; Sum all hotstring counts inside a node and its sub-nodes recursively.
_HS_NodeTotal(Node) {
	Total := 0
	for _, TF in Node["tomls"]
		Total += TF.count
	for _, Sub in Node["subfolders"]
		Total += _HS_NodeTotal(Sub)
	return Total
}

; Render recursive ext tree (nested folder structure)
_HS_RenderTree(Tree, ParentMenu) {
	FolderNames := []
	for FolderName in Tree
		FolderNames.Push(FolderName)
	loop FolderNames.Length {
		i := A_Index
		loop FolderNames.Length - i {
			j := A_Index
			if (StrCompare(FolderNames[j], FolderNames[j+1]) > 0) {
				tmp := FolderNames[j]
				FolderNames[j] := FolderNames[j+1]
				FolderNames[j+1] := tmp
			}
		}
	}
	for _, FolderName in FolderNames {
		Node := Tree[FolderName]
		FolderMenu := Menu()
		FileNodeList := Node["tomls"]
		loop FileNodeList.Length {
			i := A_Index
			loop FileNodeList.Length - i {
				j := A_Index
				if (StrCompare(FileNodeList[j].stem, FileNodeList[j+1].stem) > 0) {
					tmp := FileNodeList[j]
					FileNodeList[j] := FileNodeList[j+1]
					FileNodeList[j+1] := tmp
				}
			}
		}
		if (Node["subfolders"].Count > 0)
			_HS_RenderTree(Node["subfolders"], FolderMenu)
		if (Node["subfolders"].Count > 0 and FileNodeList.Length > 0)
			FolderMenu.Add()
		for _, TF in FileNodeList {
			TFMenu := Menu()
			RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
			if (TF.sections.Length > 0) {
				TFMenu.Add()
				for _, ES in TF.sections {
					SecLabel := ES["description"] . " (" . FmtCount(ES["count"]) . ")"
					TFMenu.Add(SecLabel, (*) => NoAction())
					TFMenu.Disable(SecLabel)
				}
			}
			FolderMenu.Add(TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : ""), TFMenu)
		}
		FolderTotal := _HS_NodeTotal(Node)
		FolderLabel := FolderName . (FolderTotal > 0 ? " (" . FmtCount(FolderTotal) . ")" : "")
		ParentMenu.Add(FolderLabel, FolderMenu)
	}
}

; Dynamic handler: bundled extension hotstrings.
_HS_Extensions(M, _Cat) {
	global _StaticDir
	ExtensionsBaseDir := _StaticDir . "\extensions\"
	BundledExtensions := []
	ExtTotal := 0
	if DirExist(ExtensionsBaseDir) {
		Loop Files ExtensionsBaseDir . "*", "D" {
			ExtId          := A_LoopFileName
			ExtDir         := A_LoopFileFullPath
			ManifestPath   := ExtDir . "\manifest.toml"
			ExtDisplayName := ExtId
			if FileExist(ManifestPath) {
				try {
					MC := FileRead(ManifestPath, "UTF-8")
					if RegExMatch(MC, "name\s*=\s*`"([^`"]+)`"", &NM)
						ExtDisplayName := NM[1]
				}
			}
			HsDir     := ExtDir . "\hotstrings\"
			TomlFiles := []
			if DirExist(HsDir) {
				Loop Files HsDir . "*.toml" {
					FileSections := _ParseExtTomlSections(A_LoopFileFullPath)
					FileCount := 0
					for _, FS in FileSections
						FileCount += FS["count"]
					ExtTotal += FileCount
					SplitPath A_LoopFileFullPath, , , , &FileStem
					TomlFiles.Push({ path: A_LoopFileFullPath, stem: FileStem
						, sections: FileSections, count: FileCount })
				}
			}
			BundledExtensions.Push({ id: ExtId, name: ExtDisplayName, toml_files: TomlFiles })
		}
	}
	if (BundledExtensions.Length == 0) {
		EmptyLabel := t("menu.extensions.empty")
		M.Add(EmptyLabel, (*) => NoAction())
		M.Disable(EmptyLabel)
	} else {
		for _, Ext in BundledExtensions {
			ExtHsMenu    := Menu()
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
					RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
					if (TF.sections.Length == 0) {
						TFMenu.Add()
						NoSecLabel := t("menu.extensions.empty")
						TFMenu.Add(NoSecLabel, (*) => NoAction())
						TFMenu.Disable(NoSecLabel)
					} else {
						TFMenu.Add()
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
			M.Add(Ext.name . (ExtTotalForExt > 0 ? " (" . FmtCount(ExtTotalForExt) . ")" : ""), ExtHsMenu)
		}
	}
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
	WpmWidget.pos_x := -1
	WpmWidget.pos_y := -1
	WPMWidget_SaveConfig()
	try menu.ToggleCheck(label)
	if was_visible
		WPMWidget_Show()
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
	for _, proc in selected
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

; Runs the auto-configure — success is already indicated by the green status label in the UI,
; so only failures surface a blocking dialog (the user must know something went wrong).
GestureAutoConfigureAction() {
	Success := GestureAutoConfigureRegistry()
	if (!Success) {
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

; v1 category names for the flat hotstring categories that have a 1:1
; mapping to a manifest section — each rendered as a flat list of
; toggles by InitSubMenus.
global _FLAT_HOTSTRING_V1_CATS := ["Autocorrection", "DistancesReduction",
	"SFBsReduction", "Rolls", "MagicKey"]

; v1 -> v2 category name map used by _CountEnabledForCategory
global _V1CatToV2CatMap := Map(
	"Autocorrection",     "autocorrection",
	"DistancesReduction", "distances_reduction",
	"SFBsReduction",      "sfbs_reduction",
	"Rolls",              "rolls",
	"MagicKey",           "magic_key",
)

; Per-category inverse maps (v2 snake_case id -> v1 PascalCase) so that
; _CountEnabledForCategory can resolve the TOML section name via FoldAsciiLower(v1).
global _V1CatToInverseKeyMap := Map(
	"Autocorrection",     _ManifestToLegacyAutocorrectionKeyMap,
	"DistancesReduction", _ManifestToLegacyDistancesReductionKeyMap,
	"SFBsReduction",      _ManifestToLegacySFBsReductionKeyMap,
	"Rolls",              _ManifestToLegacyRollsKeyMap,
	"MagicKey",           _ManifestToLegacyMagicKeyKeyMap,
)

; Custom render order for the ``DynamicHotstrings`` submenu — the manifest
; doesn't yet model menu order or separators, so the curated UX layout is
; pinned here as a sidecar. Each entry is either a v1 PascalCase feature id
; or ``"-"`` (separator). When the manifest grows ``menu_order`` /
; ``menu_separator`` metadata this constant can move into the codegen.
global _DYNAMIC_HOTSTRINGS_ORDER := ["DateLongFr", "DateFr", "Date",
	"PhonePrefixes", "SsnPrefixes", "IbanPrefixes", "-",
	"TextExpansionPersonalInformation"]

; Build every consumed SubMenus[X] entry explicitly. The legacy
; ``for Category, Items in Features`` loop that fell back to
; CreateSubMenusRecursive for any category not yet migrated is gone —
; every consumer of SubMenus (the hotstring rendering block in
; initMenu, the Shortcuts + TapHolds tray inserts) reads one of the
; entries built here. Gestures has its own builder (BuildGesturesMenu)
; called directly from initMenu and never touches SubMenus, so it is
; intentionally absent. Layout is built straight into A_TrayMenu by
; initMenu's manifest iteration and also doesn't need a SubMenus slot.
InitSubMenus() {
	global SubMenus, _FLAT_HOTSTRING_V1_CATS, _LegacyTopCategoryMap, _SharedDir
	_HS_PreScanPersonal()
	SubMenus := Map()

	; Flat hotstring categories — order = sections_order from the TOML (which
	; includes "-" separators); falls back to manifest declaration order when
	; the TOML has no sections_order.
	for _, V1Cat in _FLAT_HOTSTRING_V1_CATS {
		SubMenu := Menu()
		TomlPath := _SharedDir . "\hotstrings\" . StrLower(V1Cat) . ".toml"
		if FileExist(TomlPath) {
			RegisterMenuItem(SubMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TomlPath))
			SubMenu.Add()
		}
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		if (V2Section != "") {
			Entries := ManifestFeaturesForSection(V2Section)
			; Build a map from the section-name part of the v2 path to its entry
			; so we can look up entries by TOML section name while iterating
			; sections_order (which preserves visual separators).
			EntryBySectionId := Map()
			for _, Entry in Entries {
				; path looks like "hotstrings.rolls.hc" — last segment is the id
				Parts := StrSplit(Entry["path"], ".")
				EntryBySectionId[Parts[Parts.Length]] := Entry
			}
			SectionsOrder := ReadTomlSectionsOrder(V1Cat, TomlPath)
			if (SectionsOrder.Length > 0) {
				; Render following TOML sections_order, honouring "-" separators.
				; "replace" (J→★ key remapping) is shown in Disposition Ergopti instead.
				_PrevWasSep := true ; Treat start as a virtual separator to suppress a leading "--"
				for _, SecId in SectionsOrder {
					if (SecId == "-") {
						if !_PrevWasSep {
							SubMenu.Add()
							_PrevWasSep := true
						}
						continue
					}
					if (V1Cat == "MagicKey" and SecId == "replace") {
						continue
					}
					if EntryBySectionId.Has(SecId) {
						MenuAddItemFromManifest(SubMenu, EntryBySectionId[SecId], V1Cat)
						_PrevWasSep := false
					}
				}
			} else {
				; No sections_order in TOML — fall back to manifest order.
				; Still skip "replace" for MagicKey (shown in Disposition Ergopti).
				for _, Entry in Entries {
					Parts := StrSplit(Entry["path"], ".")
					if (V1Cat == "MagicKey" and Parts[Parts.Length] == "replace") {
						continue
					}
					MenuAddItemFromManifest(SubMenu, Entry, V1Cat)
				}
			}
		}
		SubMenus[V1Cat] := SubMenu
	}

	; DynamicHotstrings — custom-ordered, with separator + injected editor.
	SubMenus["DynamicHotstrings"] := _BuildDynamicHotstringsSubmenu()

	; Shortcuts — Accents + WrapTextIfSelected + Modifier combos + transitional Personal.
	SubMenus["Shortcuts"] := _BuildShortcutsSubmenu()

	; TapHolds — built from the v2 variant tables in tap_hold_writer.ahk.
	SubMenus["TapHolds"] := _BuildTapHoldsSubmenu()
}

; Build the DynamicHotstrings submenu directly from the manifest, honouring
; the curated render order in ``_DYNAMIC_HOTSTRINGS_ORDER`` and injecting
; the personal-info editor entry right after the text-expansion item.
_BuildDynamicHotstringsSubmenu() {
	global _LegacyDynamicHotstringsKeyMap, _DYNAMIC_HOTSTRINGS_ORDER
	SubMenu := Menu()
	for _, V1Id in _DYNAMIC_HOTSTRINGS_ORDER {
		if (V1Id == "-") {
			SubMenu.Add()
			continue
		}
		if !_LegacyDynamicHotstringsKeyMap.Has(V1Id) {
			try LoggerWarn("Menu",
				"DynamicHotstrings: no v2 id for '{1}' — skipped.", V1Id)
			continue
		}
		V2Id := _LegacyDynamicHotstringsKeyMap[V1Id]
		Entry := ManifestFindEntryByPath("hotstrings.dynamic." . V2Id)
		if (Entry == false) {
			try LoggerWarn("Menu",
				"DynamicHotstrings: no manifest entry for '{1}' — skipped.", V1Id)
			continue
		}
		MenuAddItemFromManifest(SubMenu, Entry, "DynamicHotstrings")
		if (V1Id == "TextExpansionPersonalInformation") {
			RegisterMenuItem(SubMenu,
				t("menu.shortcuts.edit_personal_info"), PersonalInformationEditor)
		}
	}
	return SubMenu
}

; Returns true when every section in the flat category has its feature enabled.
; Used to drive the checkmark on the category sub-menu entry.
_IsCategoryFullyEnabled(V1Cat) {
	global Features, _V1CatToV2CatMap
	if !_V1CatToV2CatMap.Has(V1Cat) {
		return false
	}
	V2Cat := _V1CatToV2CatMap[V1Cat]
	if !Features["hotstrings"].Has(V2Cat) {
		return false
	}
	for _, FNode in Features["hotstrings"][V2Cat] {
		if (IsObject(FNode) and FNode.Has("enabled") and !FNode["enabled"]) {
			return false
		}
	}
	return Features["hotstrings"][V2Cat].Count > 0
}


; Sum hotstring entries for a flat category (Autocorrection, Rolls, …)
; counting only the sections whose feature toggle is enabled in Features.
; Uses CountTomlSection per v2 section id so disabled sections contribute 0.
_CountEnabledForCategory(V1Cat) {
	global Features, _V1CatToV2CatMap, _V1CatToInverseKeyMap
	if !_V1CatToV2CatMap.Has(V1Cat) {
		return 0
	}
	V2Cat := _V1CatToV2CatMap[V1Cat]
	if !Features["hotstrings"].Has(V2Cat) {
		return 0
	}
	Total := 0
	for V2SecId, FNode in Features["hotstrings"][V2Cat] {
		if (IsObject(FNode) and FNode.Has("enabled") and FNode["enabled"]) {
			Total += CountTomlSection(V1Cat, V2SecId)
		}
	}
	return Total
}

; Sum ALL hotstring entries for a flat category regardless of the per-section
; enabled flag. Used when the Hotstrings master gate is off: ApplyMasterGatesToFeatures
; zeroes Features in memory so _CountEnabledForCategory would return 0, but the menu
; should still display the persisted counts so the user knows what will reactivate.
_CountAllForCategory(V1Cat) {
	global Features, _V1CatToV2CatMap
	if !_V1CatToV2CatMap.Has(V1Cat) {
		return 0
	}
	V2Cat := _V1CatToV2CatMap[V1Cat]
	if !Features["hotstrings"].Has(V2Cat) {
		return 0
	}
	Total := 0
	for V2SecId, FNode in Features["hotstrings"][V2Cat] {
		if IsObject(FNode) {
			Total += CountTomlSection(V1Cat, V2SecId)
		}
	}
	return Total
}


; Collect every v1 feature path that belongs to the Hotstrings category:
; flat TOML categories (Autocorrection, DistancesReduction, …), dynamic
; hotstrings, and personal TOML sections. Used by ToggleAllHotstrings to
; activate every individual feature when the user clicks "tout activer".
_CollectAllHotstringsV1Paths() {
	global _FLAT_HOTSTRING_V1_CATS, _LegacyTopCategoryMap
	global _LegacyDynamicHotstringsKeyMap
	Paths := []

	; Flat categories — read entries from the manifest
	for _, V1Cat in _FLAT_HOTSTRING_V1_CATS {
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		if (V2Section == "") {
			continue
		}
		for _, Entry in ManifestFeaturesForSection(V2Section) {
			V1Path := ManifestPathToLegacyPath(Entry["path"])
			if (V1Path != "") {
				Paths.Push(V1Path)
			}
		}
	}

	; Dynamic hotstrings — one toggle per entry in the key map
	for V1Id, _V2Id in _LegacyDynamicHotstringsKeyMap {
		Paths.Push("DynamicHotstrings." . V1Id)
	}

	; Personal TOML sections
	PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
	if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
		PersonalTomlData := ReadPersonalToml()
		for _, SecName in PersonalTomlData["sections_order"] {
			if (SecName != "-") {
				Paths.Push("Personal." . SecName)
			}
		}
	}

	return Paths
}


; v1 group id -> v2 manifest section path for the three Shortcuts sub-Maps
; (AltGrLAlt / AltGrCapsLock / LAltCapsLock). Each sub-Map renders as a
; sub-submenu of 10 plain-bool toggles. The label of each sub-submenu in
; the legacy render was the raw v1 key (e.g. "AltGrLAlt") because the
; sub-Maps carried no ``__Label`` metadata — preserved verbatim here so
; the manifest path is visually identical.
global _SHORTCUTS_SUBMAP_V1V2 := Map(
	"AltGrLAlt",     "ahk.shortcuts.alt_gr_lalt",
	"AltGrCapsLock", "ahk.shortcuts.alt_gr_caps_lock",
	"LAltCapsLock",  "ahk.shortcuts.lalt_caps_lock",
)

; Build the Shortcuts submenu from the manifest-driven renderer.
; Dynamic handlers supply the platform-specific blocks (personal shortcuts,
; script control, extensions, edit action) that cannot be described in JSON.
_BuildShortcutsSubmenu() {
	DynHandlers := Map(
		"personal_shortcuts",         (M, C) => _SC_Personal(M, C),
		"script_control_shortcuts",   (M, C) => _SC_ScriptControl(M, C),
		"extensions_shortcuts",       (M, C) => _SC_Extensions(M, C),
		"edit_shortcuts",             (M, C) => _SC_EditAction(M, C),
	)

	return MenuRenderer_Build("shortcuts_menu", "Shortcuts", DynHandlers)
}

; Dynamic handler: personal shortcuts submenu (if any registered).
; Emits its own leading separator when items are present, matching pre-refactor behaviour.
_SC_Personal(SubMenu, _Cat) {
	_AppendPersonalShortcutsSubmenuIfAny(SubMenu)
}

; Dynamic handler: script control shortcuts submenu.
_SC_ScriptControl(SubMenu, _Cat) {
	SubMenu.Add(t("menu.shortcuts.script_shortcuts"), BuildScriptShortcutsMenu())
}

; Dynamic handler: extensions shortcuts submenus.
_SC_Extensions(SubMenu, _Cat) {
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
	if !HasExtShortcuts {
		return false
	}
	SubMenu.Add()
	ExtShortcutsHeader := MenuSectionTitle(t("menu.extensions.header"))
	SubMenu.Add(ExtShortcutsHeader, (*) => NoAction())
	SubMenu.Disable(ExtShortcutsHeader)
	Loop Files ExtShortcutsBaseDir . "*", "D" {
		ExtId       := A_LoopFileName
		ExtDir      := A_LoopFileFullPath
		MenuAhkPath := ExtDir . "\shortcuts\menu.ahk"
		if !FileExist(MenuAhkPath)
			continue
		ExtName      := ExtId
		ManifestPath := ExtDir . "\manifest.toml"
		if FileExist(ManifestPath) {
			try {
				MC := FileRead(ManifestPath, "UTF-8")
				if RegExMatch(MC, "name\s*=\s*`"([^`"]+)`"", &NM)
					ExtName := NM[1]
			}
		}
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
		SubMenu.Add(ExtName, ExtMenu)
	}
}

; Dynamic handler: edit personal shortcuts action button.
_SC_EditAction(SubMenu, _Cat) {
	RegisterMenuItem(SubMenu, t("menu.global.edit_shortcuts"), OpenPersonalShortcuts)
}

; Build the TapHolds submenu — one entry per physical key, each with a
; tap picker (modal GUI, same UI as gesture/shortcut pickers) and a hold
; picker submenu, mirroring the macOS Karabiner menu design.
;
; Render shape:
;
;   ☰ Tap-Hold
;     ↳ Réinitialiser les valeurs par défaut
;     ↳ Tout désactiver
;     ↳ ---
;     ↳ Tab  :  Alt-Tab / Alt          [checkmark when configured]
;       ↳ Rien (désactiver)
;       ↳ ---
;       ↳ Tap  → "Alt-Tab"             [opens modal action picker GUI]
;       ↳ Hold → "Alt"                 [opens hold picker submenu]
;     ↳ CapsLock  :  Entrée / Ctrl
;     ↳ …
;
; Tap picker: full GESTURE_ACTIONS list in the searchable modal GUI (ShowActionPicker).
; Hold picker: fixed set from _TH_HoldOptions (modifiers + nav layer + none).
; Both pickers persist immediately via WriteTapHoldTap / WriteTapHoldHold and
; reload the script to refresh the menu.
_BuildTapHoldsSubmenu() {
	DynHandlers := Map(
		"reset_defaults", (M, C) => _TH_DynResetDefaults(M, C),
		"disable_all",    (M, C) => _TH_DynDisableAll(M, C),
		"tap_hold_keys",  (M, C) => _TH_DynKeys(M, C),
	)
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", DynHandlers)
}

; Dynamic handler: reset-defaults action button.
_TH_DynResetDefaults(M, _Cat) {
	M.Add(t("tap_hold.reset_defaults"), _TH_ResetAllToDefaults)
}

; Dynamic handler: disable-all action button.
_TH_DynDisableAll(M, _Cat) {
	M.Add(t("tap_hold.disable_all"), _TH_DisableAll)
}

; Dynamic handler: per-key tap/hold entries.
_TH_DynKeys(M, _Cat) {
	global TapHold
	for _, KeyDef in TapHoldKeyDefs() {
		KeyId    := KeyDef["id"]
		KeyLabel := t(KeyDef["i18n"])
		TapLbl   := TapHoldCurrentTapLabel(KeyId)
		HoldLbl  := TapHoldCurrentHoldLabel(KeyId)

		IsConfigured := IsSet(TapHold) and TapHoldIsConfigured(TapHold, KeyId)

		NoneLabel  := t("tap_hold.tap.none")
		NoneHold   := t("tap_hold.hold.none")
		ComboLabel := (TapLbl == NoneLabel and HoldLbl == NoneHold)
			? "—"
			: (TapLbl . "  /  " . HoldLbl)
		ParentLabel := KeyLabel . "  :  " . ComboLabel

		KeyMenu := Menu()

		DisableLabel := t("tap_hold.action.disable")
		KeyMenu.Add(DisableLabel, _TH_MakeDisableFn(KeyId))
		if !IsConfigured
			KeyMenu.Disable(DisableLabel)

		KeyMenu.Add()

		TapPickerLabel := StrReplace(t("tap_hold.picker.tap"), "%s", TapLbl)
		KeyMenu.Add(TapPickerLabel, _TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl))

		HoldPickerLabel := StrReplace(t("tap_hold.picker.hold"), "%s", HoldLbl)
		HoldPickerMenu  := _BuildHoldPickerSubmenu(KeyId)
		KeyMenu.Add(HoldPickerLabel, HoldPickerMenu)

		M.Add(ParentLabel, KeyMenu)
		if IsConfigured
			M.Check(ParentLabel)
	}
}

; Return the "none" hold option map (first entry in _TH_HoldOptions).
_TH_NoneHoldOpt() {
	global _TH_HoldOptions
	return _TH_HoldOptions[1]
}

; ---- Global tap-hold actions --------------------------------------------------

; Reset all configured keys back to factory defaults by deleting the user
; tap_hold.toml (the loader will fall back to defaults.toml on next reload).
_TH_ResetAllToDefaults(*) {
	global _ConfigDir, _AhkSubDir
	Path := _ConfigDir . _AhkSubDir . "tap_hold.toml"
	try {
		if FileExist(Path) {
			FileDelete(Path)
		}
	} catch as Err {
		try LoggerError("TapHoldMenu", "Could not delete tap_hold.toml: {1}.", Err.Message)
	}
	Reload
}

; Clear every configured key so all physical keys revert to their native OS
; behaviour (no tap remapping, no hold remapping).
_TH_DisableAll(*) {
	if IsSet(_TH_WriteTapHoldDisabled) {
		try _TH_WriteTapHoldDisabled()
	}
	Reload()
}

; ---- Callback classes ---------------------------------------------------------
; AHK v2 fat-arrow closures cannot contain multiple statements. These classes
; capture (KeyId, HoldOpt) by value and expose a Call() method bound via
; ObjBindMethod so AHK's Menu.Add() receives a valid callable.

class _TH_DisableFnObj {
	KeyId := ""
	Call(*) {
		WriteTapHoldTap(this.KeyId, "")
		WriteTapHoldHold(this.KeyId, _TH_NoneHoldOpt())
		Reload
	}
}

class _TH_TapPickerFnObj {
	KeyId     := ""
	KeyLabel  := ""
	Call(*) {
		global TapHold
		; Current tap action at call time (not at menu-build time).
		; "" means native (unconfigured) — pass as-is; ShowNative:=true adds the entry.
		Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, this.KeyId) : ""
		Title := t("tap_hold.picker.title_prefix") . this.KeyLabel
		_KeyId := this.KeyId
		ShowActionPicker(Title, Current, (Id) => _TH_ApplyTap(_KeyId, Id), true)
	}
}

class _TH_HoldFnObj {
	KeyId   := ""
	HoldOpt := ""
	Call(*) {
		WriteTapHoldHold(this.KeyId, this.HoldOpt)
		Reload
	}
}

; Build a bound callback that clears both tap and hold for a key.
_TH_MakeDisableFn(KeyId) {
	obj := _TH_DisableFnObj()
	obj.KeyId := KeyId
	return ObjBindMethod(obj, "Call")
}

; Build a bound callback that opens the action picker modal for the tap slot.
_TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl) {
	obj := _TH_TapPickerFnObj()
	obj.KeyId    := KeyId
	obj.KeyLabel := KeyLabel
	return ObjBindMethod(obj, "Call")
}

; Apply a tap action chosen from the modal picker.
; ActionId="" (from the "Natif" sentinel) clears the slot so the key passes through natively.
; ActionId="none" sets the absorb no-op action.
_TH_ApplyTap(KeyId, ActionId) {
	WriteTapHoldTap(KeyId, ActionId)
	Reload
}

; Build the hold picker submenu for a given key. Shows the fixed hold options
; from _TH_HoldOptions; current selection is checked.
_BuildHoldPickerSubmenu(KeyId) {
	global _TH_HoldOptions
	PickerMenu := Menu()
	for _, HoldOpt in _TH_HoldOptions {
		Label    := t(HoldOpt["i18n"])
		IsActive := IsTapHoldHoldActive(KeyId, HoldOpt)
		PickerMenu.Add(Label, _TH_MakeHoldFn(KeyId, HoldOpt))
		if IsActive {
			PickerMenu.Check(Label)
		}
	}
	return PickerMenu
}

; Build a bound callback that writes a hold option for a key, then reloads.
_TH_MakeHoldFn(KeyId, HoldOpt) {
	obj := _TH_HoldFnObj()
	obj.KeyId   := KeyId
	obj.HoldOpt := HoldOpt
	return ObjBindMethod(obj, "Call")
}

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
		MenuAddItem(PersonalMenu, "Shortcuts.Personal", Name)
	}
	ShortcutsMenu.Add()
	ShortcutsMenu.Add(t("menu.shortcuts.personal"), PersonalMenu)
}


initMenu() {
	global SubMenus, A_TrayMenu, HotstringCategories

	A_TrayMenu.Delete()

	; Shortcuts submenu — built by MenuRenderer_Build("shortcuts_menu", …).
	; The renderer handles the category toggle, feature toggles, separator
	; placement, modifier-combos group, and dynamic blocks (personal
	; shortcuts, script control, extensions, edit action) via the handler
	; Map injected by _BuildShortcutsSubmenu's dynamic handlers.
	; InsertKeyboardShortcutGroups still splices the Alt/Ctrl/Win groups
	; in before the modifier-combos anchor after the renderer runs.
	ShortcutsGated := IsCategoryGated("Shortcuts")
	if SubMenus.Has("Shortcuts") {
		InsertKeyboardShortcutGroups(SubMenus["Shortcuts"], t("menu.shortcuts.group_modifiers"))
	}

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
	A_TrayMenu.Add(LayoutMenuTitle, LayoutMenu)
	if LayoutGated {
		A_TrayMenu.Check(LayoutMenuTitle)
	}

	; ── Hotstrings ⚡ — built from manifest via MenuRenderer_Build.
	; Dynamic handlers supply the runtime-dependent blocks (params, categories,
	; personal tree, extensions). The toggle is rendered by the manifest toggle
	; type entry but uses the ToggleAllHostrings* pattern for hotstrings.
	HotstringsAllEnabled := IsCategoryGated("Hotstrings")
	_CountFn := HotstringsAllEnabled ? _CountEnabledForCategory : _CountAllForCategory

	_HotDynHandlers := Map(
		"hotstring_categories_standard", (M, C) => _HS_CategoriesStandard(M, C),
		"hotstring_categories_dynamic",  (M, C) => _HS_CategoriesDynamic(M, C),
		"hotstring_categories_ergopti",  (M, C) => _HS_CategoriesErgopti(M, C),
		"hotstring_personal",            (M, C) => _HS_Personal(M, C),
		"hotstring_extensions",          (M, C) => _HS_Extensions(M, C),
		"magic_key_config",              (M, C) => _HS_MagicKeyConfig(M, C),
		"repeat_key",                    (M, C) => _HS_RepeatKey(M, C),
		"delays_colors",                 (M, C) => _HS_DelaysColors(M, C),
		"word_expanders",                (M, C) => _HS_WordExpanders(M, C),
	)

	_HotGroupBuilders := Map(
		"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers),
	)
	HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders)

	HotstringsMenuTitle := t("menu.hotstrings.title") . " (" . FmtCount(_HS_ComputeGrandTotal()) . ")"
	A_TrayMenu.Add(HotstringsMenuTitle, HotstringsMenu)
	if HotstringsAllEnabled {
		A_TrayMenu.Check(HotstringsMenuTitle)
	}

	global _LLM_Tray_InTray
	_LLM_Tray_InTray := false
	_LlmSavedOpts := LLM_Tray_BuildSavedOpts(_IniCache)

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
	LLM_Tray_Init(_LlmSavedOpts)

	BuildMetricsMenu()
	if MetricsShortcuts.enabled {
		A_TrayMenu.Check(t("menu.metrics.title"))
	}

	if SubMenus.Has("Shortcuts") {
		A_TrayMenu.Add(GetCategoryTitle("Shortcuts"), SubMenus["Shortcuts"])
		if ShortcutsGated {
			A_TrayMenu.Check(GetCategoryTitle("Shortcuts"))
		}
	}
	if SubMenus.Has("TapHolds") {
		A_TrayMenu.Add(GetCategoryTitle("TapHolds"), SubMenus["TapHolds"])
		if IsCategoryGated("TapHolds") {
			A_TrayMenu.Check(GetCategoryTitle("TapHolds"))
		}
	}

	GesturesMenu := BuildGesturesMenu()
	A_TrayMenu.Add(GetCategoryTitle("Gestures"), GesturesMenu)
	if Features["gestures"]["enabled"] {
		A_TrayMenu.Check(GetCategoryTitle("Gestures"))
	}

	GlobalActionsMenu := Menu()
	RegisterMenuItem(GlobalActionsMenu, t("menu.global.enable_all"),  ToggleAllFeaturesOn)
	RegisterMenuItem(GlobalActionsMenu, t("menu.global.disable_all"), ToggleAllFeaturesOff)
	RegisterMenuItem(GlobalActionsMenu, t("menu.global.reset_defaults"), ReloadWithDefaultConfig)
	A_TrayMenu.Add(t("menu.global.title"), GlobalActionsMenu)

	A_TrayMenu.Add()

	AboutMenu := Menu()
	Ver := Updater_CurrentVersion()
	VerLabel := "ErgoptiPlus " . Ver
	if Updater_IsLocalSource() {
		AboutMenu.Add(VerLabel, (*) => NoAction())
		AboutMenu.Disable(VerLabel)
	} else {
		RegisterMenuItem(AboutMenu, VerLabel, Updater_OpenCurrentRelease)
	}
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INTERVAL_PRESETS
	global UPDATER_LATEST_RELEASE
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
	A_TrayMenu.Add(t("menu.about.title"), AboutMenu)

	RegisterMenuItem(A_TrayMenu, t("menu.global.setup_wizard"), Onboarding_ShowFromMenu)

	global MenuSuspend
	MenuSuspend := t("menu.global.suspend")
	RegisterMenuItem(A_TrayMenu, t("menu.global.config_folder"), FilePathsEditor)

	LangMenu := Menu()
	I18nBuildLanguageMenu(LangMenu)
	A_TrayMenu.Add(t("menu.global.language"), LangMenu)
	A_TrayMenu.Add()
	RegisterMenuItem(A_TrayMenu, MenuSuspend, ToggleSuspend)
	RegisterMenuItem(A_TrayMenu, t("menu.global.reload"), ActivateReload)
	RegisterMenuItem(A_TrayMenu, t("menu.global.quit"), ActivateExitApp)

	DebuggingMenu := Menu()
	DebugOrder    := MenuManifest_LoadDebugMenu()
	for _, Entry in DebugOrder {
		Id := Entry["id"]
		if Id == "---" {
			DebuggingMenu.Add()
		} else if Id == "window_spy" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.window_spy"),    WindowSpy)
		} else if Id == "list_vars" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.list_vars"),     ActivateListVars)
		} else if Id == "key_history" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.key_history"),   ActivateKeyHistory)
		} else if Id == "log_level" {
			DebuggingMenu.Add(_LogLevelMenuLabel(), _BuildLogLevelMenu())
		} else if Id == "open_logs" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_logs"),     OpenLogsFolder)
		} else if Id == "open_today_log" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_today_log"), OpenTodayLog)
		} else if Id == "open_error_log" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.open_error_log"), OpenErrorLog)
		} else if Id == "healthcheck" {
			RegisterMenuItem(DebuggingMenu, t("menu.debug.healthcheck"),   ShowHealthCheck)
		}
	}
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

; Opens the per-user log directory (under <ConfigDir>/autohotkey/logs/) in Explorer.
; Creates it on first use so the user never sees an "introuvable" dialog
OpenLogsFolder(*) {
	global _AhkSubDir
	LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
		? _ConfigDir . _AhkSubDir . "logs\"
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
		; Fall back to the day-stamped path under <ConfigDir>/autohotkey/logs/ when the
		; logger hasn't initialised yet (very early boot, edge case)
		LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
			? _ConfigDir . _AhkSubDir . "logs\"
			: A_ScriptDir . "\logs\"
		Path := LogDir . "ErgoptiPlus_" . FormatTime(, "yyyy-MM-dd") . ".log"
	}
	Run('notepad.exe "' . Path . '"')
}

; Opens today's errors-only log (WARNING + ERROR lines) in Notepad.
; LOGGER_ERRORS_LOG_PATH is maintained by the logger (daily, driver-scoped).
; Falls back to computing the path under the logs dir if the global is not set yet.
OpenErrorLog(*) {
	global LOGGER_ERRORS_LOG_PATH, _AhkSubDir
	Path := (IsSet(LOGGER_ERRORS_LOG_PATH) and LOGGER_ERRORS_LOG_PATH != "")
		? LOGGER_ERRORS_LOG_PATH
		: ""
	if Path = "" or !FileExist(Path) {
		LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
			? _ConfigDir . _AhkSubDir . "logs\"
			: A_ScriptDir . "\logs\"
		Path := LogDir . "ErgoptiPlus_errors_" . FormatTime(, "yyyy-MM-dd") . ".log"
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
	. ";     RegisterPersonalFeature(`"lock_screen`", true,`r`n"
	. ";         `"Lock the workstation with Ctrl + Alt + L`")`r`n"
	. ";`r`n"
	. ";     #HotIf PersonalFeatureEnabled(`"lock_screen`")`r`n"
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

; Sets the active log level at runtime without a full script restart.
; Mutates LOGGER_MIN_LEVEL, refreshes the cached fast-path flags, and
; persists the choice under [Script] LogLevel in the user's config.toml
; so the level is restored on the next boot.
LoggerSetLevel(Level) {
	global LOGGER_MIN_LEVEL, LOGGER_SEVERITY, ConfigurationFile
	if !LOGGER_SEVERITY.Has(Level) {
		try LoggerWarn("Menu", "LoggerSetLevel: unknown level '{1}' — ignoring.", Level)
		return
	}
	LOGGER_MIN_LEVEL := Level
	_LoggerRefreshFastFlags()
	try TOML_Write(Level, ConfigurationFile, "script", "log_level")
	try LoggerInfo("Menu", "Log level set to {1}.", Level)
	RebuildTrayMenu()
}

; Returns the label shown for the log-level submenu entry, including the
; active level so the user can see the current setting without opening the submenu.
_LogLevelMenuLabel() {
	global LOGGER_MIN_LEVEL
	return t("menu.debug.log_level") . " : " . _LogLevelEmoji(LOGGER_MIN_LEVEL) . " " . LOGGER_MIN_LEVEL
}

; Build the log level submenu for the Debug entry. Returns a Menu object
; with one item per severity level (DEBUG / INFO / WARNING / ERROR),
; the currently active level pre-checked.
_BuildLogLevelMenu() {
	global LOGGER_MIN_LEVEL
	LevelMenu := Menu()
	for _, Level in ["DEBUG", "INFO", "WARNING", "ERROR"] {
		; Capture loop variable for the callback closure
		_Lvl := Level
		Label := _LogLevelEmoji(Level) . " " . Level
		RegisterMenuItem(LevelMenu, Label, ((_l) => (*) => LoggerSetLevel(_l))(Level))
		if (LOGGER_MIN_LEVEL == Level) {
			LevelMenu.Check(Label)
		}
	}
	return LevelMenu
}

_LogLevelEmoji(Level) {
	switch Level {
		case "DEBUG":   return "🐛"
		case "INFO":    return "ℹ️"
		case "WARNING": return "⚠️"
		case "ERROR":   return "❌"
		default:        return "📝"
	}
}
