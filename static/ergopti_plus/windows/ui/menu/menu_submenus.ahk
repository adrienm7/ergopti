; ui/menu/menu_submenus.ahk

; ==============================================================================
; MODULE: Tray Menu / Submenu Assembly
; DESCRIPTION:
; InitSubMenus and the dynamic-hotstrings submenu builder plus the per-category enabled/total counters that feed the menu title suffixes.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




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
	BootProfile_Mark("MENU/InitSub: prescan personal")
	SubMenus := Map()
	_HS_RegisterLanguageMenuCategories()

	; Flat hotstring categories — order = sections_order from the TOML (which
	; includes "-" separators); falls back to manifest declaration order when
	; the TOML has no sections_order.
	for _, V1Cat in _FLAT_HOTSTRING_V1_CATS {
		; Native section data keeps the file's order; the shared declaration adds
		; the explicit category commands and optional source-file row.
		TomlPath := HotstringsBundledTomlPath(V1Cat)
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		Rows := []
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
				; Extension-owned leaves, including the native replacement choice,
				; are listed under their supplying Hotstrings extension.
				_PrevWasSep := true ; Treat start as a virtual separator to suppress a leading "--"
				for _, SecId in SectionsOrder {
					if (SecId == "-") {
						if !_PrevWasSep {
							Rows.Push(Map("separator", true))
							_PrevWasSep := true
						}
						continue
					}
					; A section an extension binds (Ergopti's repeat corrections) is
					; drawn in that extension's « Hotstrings <name> » submenu instead.
					if HotstringsBoundSections(V1Cat).Has(StrLower(SecId)) {
						continue
					}
					if EntryBySectionId.Has(SecId) {
						Row := MenuRowFromManifest(EntryBySectionId[SecId], V1Cat)
						if (Row != "") {
							Rows.Push(Row)
							_PrevWasSep := false
						}
					}
				}
			} else {
				; No sections_order in TOML — fall back to manifest order.
				; Apply the same extension ownership rule when source order is absent.
				for _, Entry in Entries {
					Parts := StrSplit(Entry["path"], ".")
					if HotstringsBoundSections(V1Cat).Has(StrLower(Parts[Parts.Length])) {
						continue
					}
					Row := MenuRowFromManifest(Entry, V1Cat)
					if (Row != "") {
						Rows.Push(Row)
					}
				}
			}
		}
		SubMenu := _HS_CategoryMenu(V1Cat, TomlPath, Rows)
		SubMenus[V1Cat] := SubMenu
		; Per-category attribution. This loop is the largest post-ready boot
		; segment by a wide margin — 1094 ms of a 3406 ms warm boot on 2026-07-30,
		; four times the next one — and it is repaid in FULL on every live tray
		; rebuild via RebuildTrayMenu. Its cost is also wildly variable: 31 ms to
		; 1672 ms across boots that shared a commit, which is an I/O or scheduling
		; signature rather than a CPU one. One aggregate mark cannot tell which
		; category or which phase owns the second, so any optimisation chosen from
		; it would be a guess. Marking each category is the cheap step that turns
		; the next boot log into an answer.
		BootProfile_Mark("MENU/InitSub: flat cat " . V1Cat)
	}
	BootProfile_Mark("MENU/InitSub: flat hotstring submenus")

	; DynamicHotstrings — custom-ordered, with separator + injected editor.
	SubMenus["DynamicHotstrings"] := _BuildDynamicHotstringsSubmenu()
	BootProfile_Mark("MENU/InitSub: dynamic submenu")

	; Shortcuts — Accents + WrapTextIfSelected + Modifier combos + transitional Personal.
	SubMenus["Shortcuts"] := _BuildShortcutsSubmenu()
	BootProfile_Mark("MENU/InitSub: shortcuts submenu")

	; TapHolds — built from the v2 variant tables in tap_hold_writer.ahk.
	SubMenus["TapHolds"] := _BuildTapHoldsSubmenu()
	BootProfile_Mark("MENU/InitSub: tapholds submenu")
}

; Add every language-pack category to the flat category tables the submenu
; builder, the counters and the bulk actions walk. The neutral five are listed in
; tray_menu.ahk; the language ones come from the shared hotstring index, so a new
; language needs no entry here. Idempotent: a tray rebuild calls it again.
_HS_RegisterLanguageMenuCategories() {
	global _FLAT_HOTSTRING_V1_CATS, _V1CatToV2CatMap, _LegacyTopCategoryMap
	for _, Pack in HotstringsLanguageCategories() {
		for _, Cat in Pack["categories"] {
			if _V1CatToV2CatMap.Has(Cat["v1"])
				continue
			_FLAT_HOTSTRING_V1_CATS.Push(Cat["v1"])
			_V1CatToV2CatMap[Cat["v1"]] := Cat["v2"]
			_LegacyTopCategoryMap[Cat["v1"]] := "hotstrings." . Cat["v2"]
		}
	}
}

; The whole tree's « all sections » checkbox, at the top of the Hotstrings menu:
; ticked when the Hotstrings master is on and every hotstring section is, which
; is exactly the state ToggleAllHotstrings(true) establishes.
_HS_AllHotstringsOn() {
	global Features
	; Menu enumeration discovers paths without seeding or copying configuration.
	return _HS_PathsAllEnabled(_CollectAllHotstringsV2Paths(Features, false))
}

; List provider: one row per language pack, labelled with the language's native
; name, opening a submenu with one « all sections » checkbox for the whole
; language followed by that language's category submenus (built by InitSubMenus
; exactly like the neutral categories).
_HS_LanguageRows() {
	global SubMenus
	Rows := []
	IsGated := IsCategoryGated("Hotstrings")
	for _, Pack in HotstringsLanguageCategories() {
		Items := []
		Items.Push(_HS_LanguageSwitchRow(Pack))
		Items.Push(Map("separator", true))
		LanguageTotal := 0
		for _, Cat in Pack["categories"] {
			V1Cat := Cat["v1"]
			if !SubMenus.Has(V1Cat)
				continue
			Total := _HS_GatedCount(IsGated and IsCategoryGated(V1Cat), _CountEnabledForCategory(V1Cat))
			LanguageTotal += Total
			Items.Push(Map(
				"label",   GetCategoryTitle(V1Cat) . " (" . FmtCount(Total) . ")",
				"checked", IsCategoryGated(V1Cat) ? true : false,
				"submenu", SubMenus[V1Cat]))
		}
		; The flag is an icon here, as in the language selector: Win32 menus
		; cannot render the flag emoji the Lua drivers put in the label.
		Rows.Push(Map(
			"label", HotstringsLanguageName(Pack["locale"]) . " (" . FmtCount(LanguageTotal) . ")",
			"icon",  I18nFlagIconPath(Pack["locale"]),
			"items", Items))
	}
	return Rows
}

; Build the DynamicHotstrings submenu directly from the manifest, honouring
; the curated render order in ``_DYNAMIC_HOTSTRINGS_ORDER`` and injecting
; the personal-info editor entry right after the text-expansion item.
_BuildDynamicHotstringsSubmenu(Options := unset) {
	if !IsSet(Options)
		Options := Map()
	global _LegacyDynamicHotstringsKeyMap, _DYNAMIC_HOTSTRINGS_ORDER
	; The tray module owns these declarations before it includes this builder.
	; A direct caller must supply the same initialized boot model, never an
	; invented order or a private copy of the manifest inventory.
	if !IsSet(_LegacyDynamicHotstringsKeyMap) || !(_LegacyDynamicHotstringsKeyMap is Map)
			|| !IsSet(_DYNAMIC_HOTSTRINGS_ORDER) || !(_DYNAMIC_HOTSTRINGS_ORDER is Array)
		throw Error("Dynamic hotstring menu requires its initialized tray boot model.")
	Rows := []
	for _, V1Id in _DYNAMIC_HOTSTRINGS_ORDER {
		if (V1Id == "-") {
			Rows.Push(Map("separator", true))
			continue
		}
		if !_LegacyDynamicHotstringsKeyMap.Has(V1Id) {
			try LoggerWarn("Menu",
				"DynamicHotstrings: no v2 id for '{1}' — skipped.", V1Id)
			continue
		}
		V2Id := _LegacyDynamicHotstringsKeyMap[V1Id]
		if V2Id == "user_code" {
			for UserRow in _HS_ProgrammableHotstringRows()
				Rows.Push(UserRow)
			continue
		}
		Entry := ManifestFindEntryByPath("hotstrings.dynamic." . V2Id)
		if (Entry == false) {
			try LoggerWarn("Menu",
				"DynamicHotstrings: no manifest entry for '{1}' — skipped.", V1Id)
			continue
		}
		Row := MenuRowFromManifest(Entry, "DynamicHotstrings")
		if (Row != "") {
			Rows.Push(Row)
		}
		if (V1Id == "TextExpansionPersonalInformation") {
			Rows.Push(Map(
				"label",  t("menu.shortcuts.edit_personal_info"),
				"action", PersonalInformationEditor))
		}
	}
	return _HS_CategoryMenu("DynamicHotstrings", "", Rows,
		(_Targets, Enabled) => HotstringsDynamicScopeApply(Enabled, Options))
}

; Sum hotstring entries for a flat category (Autocorrection, Rolls, …)
; counting only the sections whose feature toggle is enabled in Features.
; Uses CountTomlSection per v2 section id so disabled sections contribute 0.
_CountEnabledForCategory(V1Cat) {
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
		if (IsObject(FNode) and FNode.Has("enabled") and FNode["enabled"]) {
			Total += CountTomlSection(V1Cat, V2SecId)
		}
	}
	return Total
}


; Collect every canonical v2 feature path that belongs to the Hotstrings
; category: flat TOML categories (autocorrection, distances_reduction, …),
; dynamic hotstrings, and personal TOML sections. Runtime-discovered personal
; nodes are seeded only in the caller's detached candidate, never in live state
; before persistence succeeds.
_CollectAllHotstringsV2Paths(FeaturesTarget, SeedPersonal := true) {
	global _FLAT_HOTSTRING_V1_CATS, _LegacyTopCategoryMap
	Paths := []

	; Flat categories — the manifest entry path IS the canonical v2 path.
	for _, V1Cat in _FLAT_HOTSTRING_V1_CATS {
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		if (V2Section == "") {
			continue
		}
		for _, Entry in ManifestFeaturesForSection(V2Section) {
			Paths.Push(Entry["path"])
		}
	}

	; Dynamic hotstrings — read straight from the manifest section.
	for _, Entry in ManifestFeaturesForSection("hotstrings.dynamic") {
		Paths.Push(Entry["path"])
	}

	; Personal TOML sections — the Features node + config section key the
	; lowercased TOML section name.
	PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
	if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
		PersonalTomlData := ReadPersonalToml()
		for _, SecName in PersonalTomlData["sections_order"] {
			if (SecName != "-") {
				if SeedPersonal
					_ConfigSeedPersonalHotstring(FeaturesTarget, SecName)
				Paths.Push("hotstrings.personal." . StrLower(SecName))
			}
		}
	}

	return Paths
}
