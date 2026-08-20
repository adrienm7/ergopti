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

	; Flat hotstring categories — order = sections_order from the TOML (which
	; includes "-" separators); falls back to manifest declaration order when
	; the TOML has no sections_order.
	for _, V1Cat in _FLAT_HOTSTRING_V1_CATS {
		; Rows first, in the order the user sees them, and the renderer draws them
		; at the end. This block used to append the open-file item and the sections
		; and THEN splice the category toggle and the two bulk actions on top with
		; RegisterMenuItemInsert("1&"/"2&"/"3&") — three inserts by position to
		; express « these three come first », which building the array in order says
		; on its own.
		Rows := []
		; THE ORDER BELOW IS THE SHARED ONE, and the three drivers had three of
		; them until 2026-08-07: this driver put the two bulk actions above
		; « ouvrir le fichier », Linux put them below it, and macOS had no category
		; gate row at all. Same submenu, same five categories, three layouts.
		;
		;   1. the category gate — everything under it is inert while it is off
		;   2. « ouvrir le fichier », when the category has one
		;   3. ─────────
		;   4. « tout activer »
		;   5. « tout désactiver »
		;   6. ─────────
		;   7. the sections
		;
		; Its state drives the parent menu checkmark (IsCategoryGated), independent
		; of how many individual sections are checked. Capture V1Cat by value so
		; each closure toggles its own category.
		Rows.Push(Map(
			"label",  IsCategoryGated(V1Cat)
				? t("menu.hotstrings.category_on")
				: t("menu.hotstrings.category_off"),
			"action", ((c) => (*) => ToggleCategoryAllFeatures(c, !IsCategoryGated(c)))(V1Cat)))

		TomlPath := _SharedDir . "\modules\hotstrings\" . StrLower(V1Cat) . ".toml"
		if FileExist(TomlPath) {
			Rows.Push(Map("label", t("menu.hotstrings.open_file"), "action", _MakeOpenFileFn(TomlPath)))
		}
		Rows.Push(Map("separator", true))
		; Section-level bulk actions for this category.
		Rows.Push(Map(
			"label",  t("menu.hotstrings.enable_all"),
			"action", ((c) => (*) => ToggleCategoryAllSections(c, true))(V1Cat)))
		Rows.Push(Map(
			"label",  t("menu.hotstrings.disable_all"),
			"action", ((c) => (*) => ToggleCategoryAllSections(c, false))(V1Cat)))
		Rows.Push(Map("separator", true))
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
							Rows.Push(Map("separator", true))
							_PrevWasSep := true
						}
						continue
					}
					if (V1Cat == "MagicKey" and SecId == "replace") {
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
				; Still skip "replace" for MagicKey (shown in Disposition Ergopti).
				for _, Entry in Entries {
					Parts := StrSplit(Entry["path"], ".")
					if (V1Cat == "MagicKey" and Parts[Parts.Length] == "replace") {
						continue
					}
					Row := MenuRowFromManifest(Entry, V1Cat)
					if (Row != "") {
						Rows.Push(Row)
					}
				}
			}
		}
		SubMenu := Menu()
		MenuRenderer_AppendRows(SubMenu, "hotstrings_menu", "hotstring_category_" . V1Cat, Rows)
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

; Build the DynamicHotstrings submenu directly from the manifest, honouring
; the curated render order in ``_DYNAMIC_HOTSTRINGS_ORDER`` and injecting
; the personal-info editor entry right after the text-expansion item.
_BuildDynamicHotstringsSubmenu() {
	global _LegacyDynamicHotstringsKeyMap, _DYNAMIC_HOTSTRINGS_ORDER
	Rows := []
	; Section-level bulk actions for the dynamic-hotstrings category.
	Rows.Push(Map(
		"label",  t("menu.hotstrings.enable_all"),
		"action", (*) => ToggleCategoryAllSections("DynamicHotstrings", true)))
	Rows.Push(Map(
		"label",  t("menu.hotstrings.disable_all"),
		"action", (*) => ToggleCategoryAllSections("DynamicHotstrings", false)))
	Rows.Push(Map("separator", true))
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
	SubMenu := Menu()
	MenuRenderer_AppendRows(SubMenu, "hotstrings_menu", "hotstring_category_DynamicHotstrings", Rows)
	return SubMenu
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
_CollectAllHotstringsV2Paths(FeaturesTarget) {
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
				_ConfigSeedPersonalHotstring(FeaturesTarget, SecName)
				Paths.Push("hotstrings.personal." . StrLower(SecName))
			}
		}
	}

	return Paths
}

