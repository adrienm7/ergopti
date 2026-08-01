; ui/menu/menu_engine.ahk

; ==============================================================================
; MODULE: Tray Menu / Generic Engine
; DESCRIPTION:
; Generic menu-item builders (manifest-driven and label-driven), letter pickers, dynamic title resolution and the path-based toggle dispatcher shared by every menu category.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Add a clickable menu item driven entirely by a manifest feature entry —
; no Features v1 lookup. Used by the menu builder for categories that have
; been migrated to consume the manifest directly (Layout first).
;
; ``ManifestEntry`` is a Map from ``ManifestFeaturesForSection`` carrying
; ``path`` (canonical v2), ``id``, ``description_key``, etc. The toggle, state
; read and label are all driven by that v2 path through infra/feature_io.ahk.
; ``V1CategoryPath`` is the PascalCase top-level category (``Layout``,
; ``Shortcuts``, ``Autocorrection``, …) used only for the master-gate greying.
MenuAddItemFromManifest(MenuParent, ManifestEntry, V1CategoryPath) {
	global Features
	V2Path := ManifestEntry["path"]
	; Skip an item whose feature does not resolve in the live Features Map — it
	; could not be toggled. Features is manifest-derived, so this only trips on a
	; malformed or partial manifest entry.
	if (FeatureLocateV2(Features, V2Path) == false) {
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
	;
	; DynamicHotstrings is excluded from that second check: unlike its five
	; siblings (Autocorrection/DistancesReduction/SFBsReduction/Rolls/MagicKey),
	; it has no independent per-file CategoryEnabled entry -- it follows the
	; Hotstrings master directly (see menu_hotstrings.ahk's _HS_CategoriesDynamic
	; comment). IsCategoryGated("DynamicHotstrings") would log a spurious
	; "unknown category" warning on every menu build for no behavioral gain --
	; the first check above already covers it via _MasterCategoryFor.
	SubCategory := StrSplit(V1CategoryPath, ".")[1]
	if !IsCategoryGated(_MasterCategoryFor(V1CategoryPath))
		or (SubCategory != "DynamicHotstrings" and !IsCategoryGated(SubCategory)) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Add a clickable menu item with a pre-resolved label and a canonical v2 path —
; bypasses the manifest+i18n lookup chain in GetMenuTitleByPath. Used by render
; paths that already hold the label string (e.g. personal hotstring sections
; whose descriptions come from the user's personal_hotstrings.toml, and personal
; shortcuts whose descriptions come from _PersonalShortcutsRegistry).
;
; ``V2Path`` is the canonical v2 path of the feature (e.g.
; "hotstrings.personal.<id>", "ahk.shortcuts.personal.<name>"); toggles and state
; reads go through infra/feature_io.ahk. ``MasterCategory`` is the v1 PascalCase
; top-level category whose master-gate state controls greying (``Hotstrings``,
; ``Shortcuts``).
MenuAddItemWithLabel(MenuParent, V2Path, MenuTitle, MasterCategory) {
	global Features
	; Mirror MenuAddItemFromManifest's guard: skip an item whose feature does not
	; resolve in the live Features Map instead of wiring a toggle/Check call that
	; can silently no-op forever (personal-hotstring-live-toggle-seed). This is a
	; defensive backstop — the normal path always seeds the Features node first
	; (see EnsurePersonalHotstringFeature / RegisterPersonalFeature).
	if (FeatureLocateV2(Features, V2Path) == false) {
		try LoggerWarn("Menu", "MenuAddItemWithLabel: '{1}' does not resolve in Features — skipping.", V2Path)
		return
	}
	RegisterMenuItem(MenuParent, MenuTitle, (*) => ToggleFeatureV2(V2Path))

	State := ReadFeatureStateV2(V2Path)
	IsEnabled := State.Has("enabled") and State["enabled"]
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	} else {
		MenuParent.Uncheck(MenuTitle)
	}

	if !IsCategoryGated(MasterCategory) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Reads master_gates.hotstring_sub_categories from menu_manifest.json (MG-3).
; Returns the hardcoded defaults when the manifest declares no such override.
_MG_LoadHotstringSubCategories() {
	Default := ["Autocorrection", "DistancesReduction", "SFBsReduction",
		"Rolls", "MagicKey", "DynamicHotstrings", "Personal"]
	; Reuse the menu subsystem's already-parsed, already-cached manifest root
	; instead of decoding the file again. _MasterCategoryFor calls this once per
	; menu item — around a hundred times per build — and a single decode of the
	; 12.5 KB manifest benches at ~44 ms, so this was ~4 s of pure redundant work
	; on every boot and every live menu rebuild.
	;
	; A failed load returns false and has ALREADY been logged as a WARNING by the
	; accessor itself, so the guard below doubles as the read-failure fallback
	; without swallowing the diagnostic. Failures are deliberately not cached
	; there, so a transient error stays retryable. Do NOT log here: this runs
	; ~100 times per build and would emit ~100 identical lines.
	Root := _MR_GetManifestRoot()
	if !(Root is Map) or !Root.Has("master_gates") {
		return Default
	}
	Gates := Root["master_gates"]
	if !(Gates is Map) or !Gates.Has("hotstring_sub_categories") {
		return Default
	}
	Arr := Gates["hotstring_sub_categories"]
	if !(Arr is Array) or Arr.Length == 0 {
		return Default
	}
	return Arr
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
	; **Category list is single-sourced from menu_manifest.json
	; master_gates.hotstring_sub_categories (MG-3).**
	for _, HotsCat in _MG_LoadHotstringSubCategories() {
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
MenuAddLetterPicker(MenuParent, V2Path, MasterCategory) {
	global Features
	; Everything — label, state read, letter writes — is driven by the canonical
	; v2 alpha path (e.g. "shortcuts.e_grave"). MasterCategory is the PascalCase
	; gate category used only for greying.
	if (FeatureLocateV2(Features, V2Path) == false) {
		try LoggerWarn("Menu", "MenuAddLetterPicker: '{1}' does not resolve in Features — skipping.", V2Path)
		return
	}
	MenuTitle := GetMenuTitleByPath(V2Path)
	State := ReadFeatureStateV2(V2Path)
	IsEnabled := State.Has("enabled") and State["enabled"]
	CurrentLetter := State.Has("letter") ? StrLower(State["letter"]) : ""

	LetterMenu := Menu()

	; Entry that disables the remap without touching letter
	DisabledLabel := t("common.disabled")
	RegisterMenuItem(LetterMenu, DisabledLabel, ((p) => (*) => SetFeatureLetterOff(p))(V2Path))
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
			((p, l) => (*) => SetFeatureLetter(p, l))(V2Path, L))
		if IsEnabled and CurrentLetter == L {
			LetterMenu.Check(UpperL)
		}
	}

	MenuParent.Add(MenuTitle, LetterMenu)
	if IsEnabled {
		MenuParent.Check(MenuTitle)
	}

	; Grey out the picker when its master category gate is off (UX affordance).
	if !IsCategoryGated(MasterCategory) {
		try MenuParent.Disable(MenuTitle)
	}
}

; Sets the remap target letter on a feature and enables it. Persists both the
; enabled flag and the letter to config.toml via infra/feature_io.ahk so the
; change survives reload, then reloads to wire the new shortcut at the layer
; level. The Reload runs the boot pipeline which re-derives the v1 Features Map
; from Features via infra/master_gates.ahk — no need to mutate v1 in-place.
; @param V2Path  Canonical v2 alpha path (e.g. "shortcuts.e_grave").
SetFeatureLetter(V2Path, Letter) {
	global Features
	WriteFeatureBatchV2(Features, [
		Map("path", V2Path, "value", true),
		Map("path", V2Path, "value", Letter, "prop", "letter"),
	])
	ReloadPreservingSuspend()
}

; Disables a letter-picker feature without touching its letter, so the
; previously-selected mapping is restored on the next picker selection.
; @param V2Path  Canonical v2 alpha path (e.g. "shortcuts.e_grave").
SetFeatureLetterOff(V2Path) {
	global Features
	WriteFeatureV2(Features, V2Path, false)
	ReloadPreservingSuspend()
}

global _TrayTitleCache := Map()

; Retrieve a feature title by its canonical v2 path. The label is sourced from
; the manifest entry's ``description_key`` (resolved against the current i18n
; locale via ``TryMenuLabelFromManifestEntry``), with the live letter suffix
; appended for letter-remap features. Only the letter pickers call this now, so
; an unresolved path simply falls back to the path itself.
GetMenuTitleByPath(V2Path) {
	global _TrayTitleCache
	if _TrayTitleCache.Has(V2Path)
		return _TrayTitleCache[V2Path]

	Entry := ManifestFindEntryByPath(V2Path)
	if (Entry == false) {
		Entry := ManifestFindEntryByPath(V2Path . ".enabled")
	}
	Label := ""
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

	if (Label == "")
		Label := V2Path

	_TrayTitleCache[V2Path] := Label
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

; v2-native toggle dispatcher — driven by a canonical v2 manifest path. Mirrors the
; v1 dispatcher exactly: a live-eligible hotstring section flips its registration
; in-process (no Reload); a Shortcuts modifier-combo sub-Map key forces its
; siblings off in the same atomic batch (mutual exclusion); everything else
; persists the flip and Reloads. Reads + writes go through infra/feature_io.ahk, so
; no v1 PascalCase path or rename table is consulted.
ToggleFeatureV2(V2Path) {
	global Features
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
	WriteFeatureBatchV2(Features, Batch)
	ReloadPreservingSuspend()
}

; v2-native live-toggle classifier + applier — the no-translation counterpart of
; _HS_TryLiveToggle. Returns true when V2Path is a live-eligible bundled hotstring
; section (flag persisted, registration rebuilt in-process); false when it is not
; a hotstring section or is reload-only, so the caller takes the persist-and-Reload
; path. Bundled hotstring entries are bare "hotstrings.<cat>.<id>" (no ahk. prefix);
; personal sections never reach here (they keep the v1 MenuAddItemWithLabel path).
_HS_TryLiveToggleV2(V2Path) {
	global Features
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
	;
	; Returning false on a failed persist hands the toggle back to the caller's
	; Reload path, which re-reads the truth from disk. Ignoring the result made
	; this the only toggle family that could no-op in silence: the bulk siblings
	; report their write result, and the ~1.3 s engine rebuild below was paid in
	; full for a change that never left memory.
	if !WriteFeatureV2(Features, V2Path, NewEnabled) {
		try LoggerError("Menu", "Live-toggle (v2) for '{1}' could not be persisted — falling back to a reload so the menu and the engine match what is actually on disk.", V2Path)
		return false
	}
	RebuildHotstringsLive()
	return true
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

