; ui/menu/menu_engine.ahk

; ==============================================================================
; MODULE: Tray Menu / Generic Engine
; DESCRIPTION:
; Generic menu-item builders (manifest-driven and label-driven), letter pickers, dynamic title resolution and the path-based toggle dispatcher shared by every menu category.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




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
	; Skip an item whose feature does not resolve in the live Features Map — it
	; could not be toggled. Features is manifest-derived, so this only trips on a
	; malformed or partial manifest entry.
	if (FeatureLocateV2(V2Path) == false) {
		try LoggerWarn("Menu", "MenuAddItemFromManifest: '{1}' does not resolve in Features — skipping.", V2Path)
		return
	}
	MenuTitle := MenuLabelFromManifestEntry(ManifestEntry)
	; Apply the same runtime substitutions ``GetMenuTitleByPath`` does (count
	; suffix " (N)" for hotstring categories, the live ``{date}`` for dynamic
	; hotstrings entries) so the manifest-driven render is visually identical.
	MenuTitle := _ApplyMenuLabelDynamicSubstitutions(MenuTitle, V2Path)
	RegisterMenuItem(MenuParent, MenuTitle, (*) => ToggleFeatureV2(V2Path))

	State := ReadFeatureStateV2(V2Path)
	IsEnabled := State.Has("enabled") and State["enabled"]
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	; Greying — off when the master category gate is off OR the per-file
	; sub-category gate is off. The sub-category gate lets a single hotstring
	; TOML file be switched off while the rest stay live; greying its sections
	; keeps them from being live-toggled back on while the file is off.
	; _MasterCategoryFor maps hotstring sub-categories to the Hotstrings master;
	; the first path segment is the sub-category itself (a no-op extra check for
	; non-hotstring categories, whose first segment IS their master gate).
	if !IsCategoryGated(_MasterCategoryFor(V1CategoryPath))
		or !IsCategoryGated(StrSplit(V1CategoryPath, ".")[1]) {
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

global _TrayTitleCache := Map()

; Retrieve a feature title by its path. The label is sourced from the
; canonical manifest entry's ``description_key`` (resolved against the
; current i18n locale via ``MenuLabelFromManifestEntry``) whenever a
; matching entry exists. Non-manifest features fall through to dedicated
; handlers.
GetMenuTitleByPath(FullPath) {
	global _TrayTitleCache
	if _TrayTitleCache.Has(FullPath)
		return _TrayTitleCache[FullPath]

	; Try the manifest+i18n first
	V2Path := LegacyPathToManifestPath(FullPath)
	Entry := false
	Label := ""
	if (V2Path != "") {
		Entry := ManifestFindEntryByPath(V2Path)
		if (Entry == false) {
			Entry := ManifestFindEntryByPath(V2Path . ".enabled")
		}
	}
	if (Entry != false) {
		Label := TryMenuLabelFromManifestEntry(Entry)
		if (Label != "") {
			Label := _ApplyMenuLabelDynamicSubstitutions(Label, V2Path)
			if _ManifestEntryHasLetter(Entry) {
				State := ReadFeatureStateV2(V2Path)
				if (State.Has("letter") and State["letter"] != "") {
					Label := Label StrUpper(State["letter"])
				}
			}
		}
	}

	if (Label == "") {
		; Personal shortcuts
		Parts := StrSplit(FullPath, ".")
		if (Parts.Length == 3 and Parts[1] == "Shortcuts" and Parts[2] == "Personal") {
			global _PersonalShortcutsRegistry
			Name := Parts[3]
			if _PersonalShortcutsRegistry.Has(Name) {
				Desc := _PersonalShortcutsRegistry[Name]
				Label := (Desc != "") ? Desc : Name
			} else {
				Label := Name
			}
		} else if (Parts[1] == "TapHolds") {
			if Parts.Length == 2
				Label := TapHoldGroupLabel(Parts[2])
			else if Parts.Length == 3
				Label := TapHoldVariantLabel(Parts[2], Parts[3])
		}
	}

	if (Label == "")
		Label := FullPath

	_TrayTitleCache[FullPath] := Label
	return Label
}

; Detect whether a manifest entry corresponds to a letter-remap feature —
; used to decide whether to append the live letter suffix to the menu
; title. Two schemas to recognise:
;
;   - Bare-α (default is a Map carrying the ``letter`` key directly).
;   - Split-α / letter pickers (the entry IS the section's ``.enabled``
;     child, and the letter lives in a sibling ``.letter`` entry).
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

; Apply runtime substitutions to a menu label fresh out of i18n, keyed by the
; canonical v2 manifest path (e.g. "hotstrings.dynamic.date_fr",
; "hotstrings.autocorrection.accents").
_ApplyMenuLabelDynamicSubstitutions(Label, V2Path) {
	; {date} substitution — only the three dynamic-date entries carry it.
	if (InStr(Label, "{date}")) {
		switch V2Path {
			case "hotstrings.dynamic.date_fr":
				Label := StrReplace(Label, "{date}", FormatTime(, "dd/MM/yyyy"))
			case "hotstrings.dynamic.date_long_fr":
				static _Days   := ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
				static _Months := ["janvier", "février", "mars", "avril", "mai", "juin",
				            "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
				_Long := _Days[A_WDay] . " " . FormatTime(, "d") . " " . _Months[FormatTime(, "M") + 0] . " " . FormatTime(, "yyyy")
				Label := StrReplace(Label, "{date}", _Long)
			case "hotstrings.dynamic.date":
				Label := StrReplace(Label, "{date}", FormatTime(, "yyyy_MM_dd"))
		}
	}
	; Append hotstring entry counts. Bundled hotstring features are
	; "hotstrings.<cat>.<id>"; the TOML loader category drops the underscores
	; from the v2 category (distances_reduction -> distancesreduction).
	Parts := StrSplit(V2Path, ".")
	if (Parts.Length == 3 and Parts[1] == "hotstrings") {
		V2Cat := Parts[2]
		V2SecId := Parts[3]
		switch V2Cat {
			case "autocorrection", "distances_reduction", "magic_key", "rolls", "sfbs_reduction":
				N := CountTomlSection(StrReplace(V2Cat, "_", ""), V2SecId)
				if (N > 0)
					Label := Label . " (" . N . ")"
			case "dynamic":
				N := CountDynamicSection(V2SecId)
				if (N > 0)
					Label := Label . " (" . N . ")"
		}
	}
	return Label
}

ToggleMenuVariableByPath(FullPath) {
	; Fast path: pure hotstring section toggles flip their HSE group live, with
	; no script Reload (the menu rebuilds in-process). _HS_TryLiveToggle returns
	; false for anything not on the live whitelist (inline-generated sections,
	; cross-dependent features, layout / tap-holds / shortcuts), which then take
	; the persist-and-Reload path below — unchanged.
	if _HS_TryLiveToggle(FullPath) {
		return
	}

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

; v2-native toggle dispatcher — the no-translation replacement for
; ToggleMenuVariableByPath, driven by a canonical v2 manifest path. Mirrors the
; v1 dispatcher exactly: a live-eligible hotstring section flips its registration
; in-process (no Reload); a Shortcuts modifier-combo sub-Map key forces its
; siblings off in the same atomic batch (mutual exclusion); everything else
; persists the flip and Reloads. Reads + writes go through lib/feature_io.ahk, so
; no v1 PascalCase path or rename table is consulted.
ToggleFeatureV2(V2Path) {
	; Fast path: live hotstring section toggle, no Reload (see _HS_TryLiveToggleV2).
	if _HS_TryLiveToggleV2(V2Path) {
		return
	}

	CurrentState := ReadFeatureStateV2(V2Path)
	CurrentEnabled := CurrentState.Has("enabled") and CurrentState["enabled"]
	NewValue := !CurrentEnabled

	; Force every mutex sibling false in the same write so the persisted state
	; reflects the picked variant alone (empty for independent toggles).
	Batch := []
	for _, SiblingPath in _MutexSiblingPathsForV2(V2Path) {
		Batch.Push(Map("path", SiblingPath, "value", false))
	}
	Batch.Push(Map("path", V2Path, "value", NewValue))
	WriteFeatureBatchV2(Batch)
	Reload
}

; v2-native live-toggle classifier + applier — the no-translation counterpart of
; _HS_TryLiveToggle. Returns true when V2Path is a live-eligible bundled hotstring
; section (flag persisted, registration rebuilt in-process); false when it is not
; a hotstring section or is reload-only, so the caller takes the persist-and-Reload
; path. Bundled hotstring entries are bare "hotstrings.<cat>.<id>" (no ahk. prefix);
; personal sections never reach here (they keep the v1 MenuAddItemWithLabel path).
_HS_TryLiveToggleV2(V2Path) {
	V2Parts := StrSplit(V2Path, ".")
	if (V2Parts.Length != 3 or V2Parts[1] != "hotstrings") {
		try LoggerDebug("Menu", "Live-toggle (v2): '{1}' is not a hotstring section → Reload.", V2Path)
		return false
	}
	Group := _HS_DeriveLiveToggleGroup(V2Parts[2], V2Parts[3])
	if _HS_IsReloadOnlyGroup(Group) {
		try LoggerDebug("Menu", "Live-toggle (v2): '{1}' is reload-only → Reload.", Group)
		return false
	}
	State := ReadFeatureStateV2(V2Path)
	NewEnabled := !(State.Has("enabled") and State["enabled"])
	; WriteFeatureV2 mutates the in-memory Features node AND persists to disk, so
	; the rebuild below re-reads the new value with no Reload.
	WriteFeatureV2(V2Path, NewEnabled)
	RebuildHotstringsLive()
	return true
}

; Attempt to apply a hotstring section toggle LIVE, without a script Reload.
; Returns true when the toggle was fully handled (flag persisted, registration
; rebuilt in-process); false when FullPath is not a live-eligible hotstring
; section — the caller then takes the persist-and-Reload path.
;
; Since RegisterAllHotstrings() is re-runnable, a live toggle no longer splices a
; single HSE group: it flips the feature flag and rebuilds the entire hotstring
; registration in-process (RebuildHotstringsLive). Re-running re-evaluates every
; Features guard, so cross-dependent and inline-generated sections all resolve
; with no special cases. Only the reload-only groups (the two native-engine
; sections and the layout-backed magic_key.replace) stay on Reload — see
; lib/hotstrings/hotstring_live_toggle.ahk.
_HS_TryLiveToggle(FullPath) {
	; Personal sections ("Personal.<id>") are always HSE-backed → live.
	if _HS_IsPersonalLiveToggle(FullPath) {
		return _HS_ApplyLiveToggle(FullPath)
	}
	; Bundled sections: translate to the v2 manifest path. Anything without a
	; manifest counterpart (TapHolds, runtime Personal) or outside "hotstrings.*"
	; is not a hotstring section → let the caller Reload.
	V2Path := LegacyPathToManifestPath(FullPath)
	if (V2Path == "") {
		try LoggerDebug("Menu", "Live-toggle: '{1}' has no manifest path → Reload.", FullPath)
		return false
	}
	V2Parts := StrSplit(V2Path, ".")
	if (V2Parts.Length != 3 or V2Parts[1] != "hotstrings") {
		try LoggerDebug("Menu", "Live-toggle: '{1}' is not a hotstring section → Reload.", V2Path)
		return false
	}
	; A few "hotstrings.*" paths are not applied by the live rebuild (the native
	; deadkey / "…" engines, and magic_key.replace which is a layout remap), so an
	; in-process rebuild would not apply them — they degrade to the Reload path.
	Group := _HS_DeriveLiveToggleGroup(V2Parts[2], V2Parts[3])
	if _HS_IsReloadOnlyGroup(Group) {
		try LoggerDebug("Menu", "Live-toggle: '{1}' is reload-only → Reload.", Group)
		return false
	}
	return _HS_ApplyLiveToggle(FullPath)
}

; Persist the flip and rebuild the whole hotstring registration in-process.
; Always returns true — the toggle is fully handled with no Reload.
_HS_ApplyLiveToggle(FullPath) {
	NewEnabled := !_ResolveMenuItemEnabled(FullPath)
	; WriteFeatureUpdate mutates the in-memory Features Map AND persists to disk,
	; so the rebuild below re-reads the new value with no Reload.
	WriteFeatureUpdate(FullPath . ".Enabled", NewEnabled)
	RebuildHotstringsLive()
	return true
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

