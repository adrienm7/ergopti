; hotstrings/ui/hotstrings_config_window/hcw_helpers.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window — Helpers
; DESCRIPTION:
; Read-only data layer of the hotstring settings window, whose only form is the
; shared WebView page (webview.ahk; maintainer decision 2026-11-21). Contains
; locale string initialisation, category/group list builders, the public window
; entry point, the section scanner, and the TOML default and user-override
; readers the page state is built from.
;
; RATIONALE:
; The read path stays separate from the write path (hcw_mutations.ahk); the thin
; shim (init.ahk) includes both.
; ==============================================================================

; Unified entry list — rebuilt each time the window opens.
; Shape: { Key, Label, Path, IsPersonal, IsExtension, ExtId, ExtName, Group }
global _HCW_CATEGORY_LIST := []

; Group list — derived from _HCW_CATEGORY_LIST.
; Shape: { Key, Label }
global _HCW_GROUP_LIST := []

#Include ../../../menu/engine/row_order.ahk

; The bundled common categories (always present), in the shared display order;
; "personal" closes that order but has its own group, built from the user's files.
_HCW_CommonCategories() {
	Common := []
	for Category in MenuRowOrderList("hotstring_config_categories")
		if (Category != "personal")
			Common.Push(Category)
	return Common
}

; Override-only categories (no TOML file) — colour / delay live in
; hotstrings_config.toml under the category key (e.g. llm_prediction).
global _HCW_VIRTUAL_CATS := ["llm_prediction"]

#Include ../../../_generated/native_theme.ahk

; Locale-dependent labels — populated lazily at window-open time.
global _HCW_CATEGORY_LABELS := Map()
global _HCW_COLOR_PRESETS   := []

; Populate all locale-dependent labels. Called at window-open time so that
; i18n is fully initialised and the correct locale is active.
_HCW_InitLocaleStrings() {
	global _HCW_CATEGORY_LABELS, _HCW_COLOR_PRESETS
	_HCW_CATEGORY_LABELS := Map(
		"magickey",           t("hs_config.cat_magickey"),
		"autocorrection",     t("hs_config.cat_autocorrection"),
		"rolls",              t("hs_config.cat_rolls"),
		"sfbsreduction",      t("hs_config.cat_sfbs"),
		"distancesreduction", t("hs_config.cat_distances"),
		"llm_prediction",     t("menu.hotstrings.tooltip_ai"),
	)
	; Color palette — labels intentionally carry NO category hint in parentheses;
	; mapping a colour to a meaning (e.g. "orange = rolls") is the user's job,
	; not the picker's, and a hint that was valid before
	; ``rolls/sfbs/distancesreduction`` lost their hardcoded orange would
	; now actively mislead. Colours are ordered along the standard hue wheel
	; (warm → cool → neutral) so the picker reads naturally. The colours come from
	; _shared/core/ui/data/native_theme.toml, the palette macOS and Linux read too.
	_HCW_COLOR_PRESETS := [Map("Label", t("hs_config.color_inherit"), "Hex", "")]
	for Row in NativeThemeHotstringPalette()
		_HCW_COLOR_PRESETS.Push(Map("Label", t(Row["I18n"]), "Hex", Row["Hex"]))
}

; One colour of the shared palette by its name; a missing name is a broken generator.
_HCW_PaletteHex(Name) {
	for Row in NativeThemeHotstringPalette()
		if Row["Name"] == Name
			return Row["Hex"]
	throw ValueError("The hotstring palette holds no colour named " . Name . ".")
}

; Build the unified category list:
; 1. Common categories (Group: "common")
; 2. Personal TOML files discovered from PersonalHotstringsDir (Group: "personal")
; 3. Extension TOML files discovered from the extensions root (Group: "ext:<id>")
_HCW_BuildCategoryList(Publish := true) {
	global _HCW_CATEGORY_LIST, _HCW_CATEGORY_LABELS
	List := []

	; --- Common categories ---
	for _, Cat in _HCW_CommonCategories() {
		Label := _HCW_CATEGORY_LABELS.Has(Cat) ? _HCW_CATEGORY_LABELS[Cat] : Cat
		List.Push({
			Key:         Cat,
			Label:       Label,
			Path:        "",
			IsPersonal:  false,
			IsExtension: false,
			IsVirtual:   false,
			ExtId:       "",
			ExtName:     "",
			Group:       "common",
		})
	}
	; Language packs: one entry per category file, labelled with the neutral
	; category's name and the language's native name ("Autocorrection — Français").
	for _, Pack in HotstringsLanguagePacks() {
		for _, Stem in Pack["categories"] {
			Cat := HotstringsLanguageGroupId(Pack["id"], Stem)
			Base := _HCW_CATEGORY_LABELS.Has(Stem) ? _HCW_CATEGORY_LABELS[Stem] : Stem
			List.Push({
				Key:         Cat,
				Label:       Base . " — " . HotstringsLanguageName(Pack["locale"]),
				Path:        "",
				IsPersonal:  false,
				IsExtension: false,
				IsVirtual:   false,
				ExtId:       "",
				ExtName:     "",
				Group:       "common",
			})
		}
	}
	for _, Cat in _HCW_VIRTUAL_CATS {
		Label := _HCW_CATEGORY_LABELS.Has(Cat) ? _HCW_CATEGORY_LABELS[Cat] : Cat
		List.Push({
			Key:         Cat,
			Label:       Label,
			Path:        "",
			IsPersonal:  false,
			IsExtension: false,
			IsVirtual:   true,
			ExtId:       "",
			ExtName:     "",
			Group:       "common",
		})
	}

	; --- Personal TOML files ---
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalHotstringsDir") {
		HsDir := ScriptInformation["PersonalHotstringsDir"]
		if DirExist(HsDir) {
			PersonalFiles := []
			Loop Files, HsDir . "*.toml" {
				Stem := RegExReplace(A_LoopFileName, "\.toml$", "")
				; A writer backup is not a source: listing it here also made the
				; scoped reset own it and back up the backup.
				if (SubStr(Stem, 1, 1) == "_") || PersonalFileIsBackup(A_LoopFileName) {
					continue
				}
				PersonalFiles.Push({ Stem: Stem, Path: A_LoopFileFullPath })
			}
			PersonalFiles := _HCW_SortByKey(PersonalFiles, "Stem")
			for _, F in PersonalFiles {
				List.Push({
					Key:         "personal:" . F.Stem,
					Label:       F.Stem,
					Path:        F.Path,
					IsPersonal:  true,
					IsExtension: false,
					ExtId:       "",
					ExtName:     "",
					Group:       "personal",
				})
			}
		}
	}

	; --- Extension TOML files ---
	; One resolver, set by the entry point. This site used to walk two levels up
	; from A_ScriptDir and land on static/, which has held no extensions/ since the
	; reorg; DirExist() then turned the miss into a silent no-op.
	global _ExtensionsDir
	ExtRoot := _ExtensionsDir . "\"
	if DirExist(ExtRoot) {
		ExtDirNames := []
		Loop Files, ExtRoot . "*", "D" {
			ExtDirNames.Push(A_LoopFileName)
		}
		ExtObjs := []
		for _, Name in ExtDirNames {
			ExtObjs.Push({ V: Name })
		}
		ExtObjs := _HCW_SortByKey(ExtObjs, "V")
		for _, Ed in ExtObjs {
			ExtId  := Ed.V
			ExtDir := ExtRoot . ExtId . "\"
			ExtName := ExtId

			ManifestPath := ExtDir . "manifest.toml"
			if FileExist(ManifestPath) {
				Loop Read, ManifestPath {
					if RegExMatch(A_LoopReadLine, '^name\s*=\s*"(.*)"', &M) {
						ExtName := M[1]
						break
					}
				}
			}

			HsExtDir := ExtDir . "hotstrings\"
			if !DirExist(HsExtDir) {
				continue
			}
			TomlFiles := []
			Loop Files, HsExtDir . "*.toml" {
				Stem := RegExReplace(A_LoopFileName, "\.toml$", "")
				if (SubStr(Stem, 1, 1) == "_") {
					continue
				}
				TomlFiles.Push({ Stem: Stem, Path: A_LoopFileFullPath })
			}
			TomlFiles := _HCW_SortByKey(TomlFiles, "Stem")
			for _, F in TomlFiles {
				List.Push({
					Key:         "ext:" . ExtId . ":" . F.Stem,
					Label:       F.Stem,
					Path:        F.Path,
					IsPersonal:  false,
					IsExtension: true,
					ExtId:       ExtId,
					ExtName:     ExtName,
					Group:       "ext:" . ExtId,
				})
			}
		}
	}

	if Publish
		_HCW_CATEGORY_LIST := List
	return List
}

; Build the group list from the category list.
; Groups: "common", "personal", one "ext:<id>" per distinct extension.
_HCW_BuildGroupList() {
	global _HCW_GROUP_LIST, _HCW_CATEGORY_LIST
	Groups := []
	SeenGroups := Map()

	Groups.Push({ Key: "common",   Label: t("hs_config.group_common")   })
	SeenGroups["common"]   := true
	Groups.Push({ Key: "personal", Label: t("hs_config.group_personal") })
	SeenGroups["personal"] := true

	for _, E in _HCW_CATEGORY_LIST {
		if E.IsExtension and !SeenGroups.Has(E.Group) {
			SeenGroups[E.Group] := true
			Groups.Push({ Key: E.Group, Label: E.ExtName })
		}
	}

	_HCW_GROUP_LIST := Groups
}

; Stable insertion sort (AHK v2 has no built-in stable sort for objects).
_HCW_SortByKey(Arr, KeyName) {
	N := Arr.Length
	loop N - 1 {
		I := A_Index + 1
		while I > 1 and StrCompare(Arr[I - 1].%KeyName%, Arr[I].%KeyName%) > 0 {
			Tmp := Arr[I - 1]
			Arr[I - 1] := Arr[I]
			Arr[I] := Tmp
			I--
		}
	}
	return Arr
}




; ============================================================
; ============================================================
; ======= 1/ Public entry point ==============================
; ============================================================
; ============================================================

; Opens the hotstring settings window. The shared WebView page is its only form
; (maintainer decision 2026-11-21): without WebView2 the user is told once that
; WebView2 is required and nothing opens.
; @returns {Boolean} False when WebView2 refused the opening.
OpenHotstringsConfigWindow() {
	return _HCWWeb_TryOpen()
}




; ============================================================
; ============================================================
; ======= 2/ Section and override readers ====================
; ============================================================
; ============================================================

; Extract the locale-appropriate string from a TOML inline table body like:
;   fr = "texte", en = "text"
_HCW_LocaleFromInlineTable(body) {
	global _I18nLocale
	lang := (IsSet(_I18nLocale) && _I18nLocale != "") ? StrLower(_I18nLocale) : "en"
	for try_lang in [lang, "en", "fr"] {
		if RegExMatch(body, try_lang . '\s*=\s*"((?:[^"\\]|\\.)*)"', &M)
			return UnescapeTomlString(M[1])
	}
	if RegExMatch(body, '"((?:[^"\\]|\\.)*)"', &M)
		return UnescapeTomlString(M[1])
	return Trim(body)
}

; Scan a TOML file to list its [[section]] blocks with titles/descriptions.
_HCW_GetSections(Entry, ReadFn := ReadTomlFile) {
	global ScriptInformation, _StaticDir
	if Entry.IsPersonal or Entry.IsExtension {
		Path := Entry.Path
	} else {
		Cat := Entry.Key
		if (StrLower(Cat) == "personal"
				and IsSet(ScriptInformation)
				and ScriptInformation.Has("PersonalTomlPath")) {
			Path := ScriptInformation["PersonalTomlPath"]
		} else {
			Path := HotstringsBundledTomlPath(Cat)
		}
	}
	Sections := []
	Seen := Map()
	Descs := Map()
	SectionsOrder := []

	if !FileExist(Path) {
		return Sections
	}

	InMeta := false
	InMetaSections := false
	InMetaSecBlock := ""
	SectionsOrderRaw := ""
	FileContent := ReadFn.Call(Path)
	loop parse, FileContent, "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		if RegExMatch(Line, "^\[\[(.+)\]\]$", &SecMatch) {
			Name := StrLower(SecMatch[1])
			if !Seen.Has(Name) {
				Seen[Name] := true
				SectionsOrder.Push(Name)
			}
			InMeta := false
			InMetaSections := false
			InMetaSecBlock := ""
			continue
		}
		if RegExMatch(Line, "^\[_meta\.sections\.([A-Za-z0-9_\-]+)\]$", &SubSecMatch) {
			InMeta := false
			InMetaSections := false
			InMetaSecBlock := StrLower(SubSecMatch[1])
			continue
		}
		if (Line == "[_meta.sections]") {
			InMeta := false
			InMetaSections := true
			InMetaSecBlock := ""
			continue
		}
		if (Line == "[_meta]") {
			InMeta := true
			InMetaSections := false
			InMetaSecBlock := ""
			continue
		}
		if (SubStr(Line, 1, 1) == "[") {
			InMeta := false
			InMetaSections := false
			InMetaSecBlock := ""
			continue
		}

		if InMeta {
			if RegExMatch(Line, "^sections_order\s*=\s*\[(.*)\]\s*$", &OrderMatch) {
				SectionsOrderRaw := OrderMatch[1]
			}
		} else if InMetaSections {
			if RegExMatch(Line, "^([A-Za-z0-9_\-]+)\s*=\s*\{([^}]+)\}\s*$", &DM) {
				Descs[StrLower(DM[1])] := _HCW_LocaleFromInlineTable(DM[2])
			} else if RegExMatch(Line, '^([A-Za-z0-9_\-]+)\s*=\s*"((?:[^"\\]|\\.)*)"' . '\s*$', &DM) {
				Descs[StrLower(DM[1])] := UnescapeTomlString(DM[2])
			}
		} else if (InMetaSecBlock != "") {
			if RegExMatch(Line, '^description\s*=\s*"((?:[^"\\]|\\.)*)"' . '\s*$', &DM) {
				Descs[InMetaSecBlock] := UnescapeTomlString(DM[1])
			}
		}
	}

	; A section a layout extension binds into this category (the magic key's
	; repeat corrections on Ergopti) lives in the extension's file with its
	; description: list it from there, as LoadHotstringsSection loads it, so its
	; row and the « reset all » scope keep addressing its preference.
	Bound := (Entry.IsPersonal or Entry.IsExtension) ? Map() : HotstringsBoundSections(Entry.Key)
	for Section, BoundPath in Bound {
		for _, BoundSection in _HCW_GetSections({ Path: BoundPath, IsPersonal: false, IsExtension: true }, ReadFn) {
			if (BoundSection.Name != Section)
				continue
			if !Seen.Has(Section) {
				Seen[Section] := true
				SectionsOrder.Push(Section)
			}
			Descs[Section] := BoundSection.Title
		}
	}

	Order := []
	if (SectionsOrderRaw != "") {
		Ordered := Map()
		Pos := 1
		while (RegExMatch(SectionsOrderRaw, '"([^"]*)"', &Tok, Pos)) {
			TokenLower := StrLower(Tok[1])
			if (TokenLower != "-" and Seen.Has(TokenLower)) {
				Order.Push(TokenLower)
				Ordered[TokenLower] := true
			}
			Pos := Tok.Pos + Tok.Len
		}
		; A bound section the category's own order does not name goes last.
		for Section, _ in Bound {
			if Seen.Has(Section) and !Ordered.Has(Section)
				Order.Push(Section)
		}
	}
	if (Order.Length == 0) {
		Order := SectionsOrder
	}
	for _, Name in Order {
		Title := Descs.Has(Name) ? Descs[Name] : Name
		Sections.Push({ Name: Name, Title: Title })
	}
	return Sections
}


_HCW_FallbackDelayMs(Entry) {
	global UI_LLM_TIMEOUT_SEC
	if (Entry.Key = "llm_prediction")
		return Round(UI_LLM_TIMEOUT_SEC * 1000)
	return Round(HotstringsBaseDelay() * 1000)
}

; Source-default collision priority for the current entry's group — personal 50,
; extension 30, common 10 — matching the engine's _HSE_SourcePriority tiers. Shown
; as the priority hint when neither the TOML nor a user override sets one.
_HCW_FallbackPriority(Entry) {
	if Entry.IsPersonal {
		return _HSE_SourcePriority("personal")
	}
	if Entry.IsExtension {
		return _HSE_SourcePriority("ext." . StrLower(Entry.ExtId))
	}
	return _HSE_SourcePriority(Entry.Key)
}

_HCW_TomlDefaults(Entry, Section) {
	if (Entry.HasOwnProp("IsVirtual") and Entry.IsVirtual) {
		if (Entry.Key = "llm_prediction") {
			global HOTSTRINGS_CATEGORY_DEFAULT_COLORS, UI_LLM_TIMEOUT_SEC
			return {
				Delay: UI_LLM_TIMEOUT_SEC,
				Color: HOTSTRINGS_CATEGORY_DEFAULT_COLORS.Has("llm_prediction")
					? HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] : "",
				Priority: ""
			}
		}
		return { Delay: "", Color: "", Priority: "" }
	}
	if Entry.IsPersonal {
		Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
	} else if Entry.IsExtension {
		Cfg := ParseTomlGroupConfig("__ext__", Entry.Path)
	} else {
		Cfg := ParseTomlGroupConfig(Entry.Key)
	}
	Default := { Delay: Cfg.Delay, Color: Cfg.Color, Priority: (Cfg.HasOwnProp("Priority") ? Cfg.Priority : "") }
	if (Section != "" and Cfg.Sections.Has(StrLower(Section))) {
		Sec := Cfg.Sections[StrLower(Section)]
		if (Sec.Delay != "") {
			Default.Delay := Sec.Delay
		}
		if (Sec.Color != "") {
			Default.Color := Sec.Color
		}
		if (Sec.HasOwnProp("Priority") and Sec.Priority != "") {
			Default.Priority := Sec.Priority
		}
	}
	return Default
}

_HCW_UserOverride(Entry, Section) {
	global _HotstringsOverrides
	Out := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
	if Entry.IsPersonal {
		; The stored value IS the override — re-read [_meta] to find what is actually stored
		Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
		if (Section == "") {
			Out.Delay := Cfg.Delay
			Out.Color := Cfg.Color
			Out.ShowTooltip := Cfg.ShowTooltip
			Out.Priority := (Cfg.HasOwnProp("Priority") ? Cfg.Priority : "")
		} else {
			Sec := StrLower(Section)
			if Cfg.Sections.Has(Sec) {
				S := Cfg.Sections[Sec]
				Out.Delay := S.Delay
				Out.Color := S.Color
				Out.ShowTooltip := S.ShowTooltip
				Out.Priority := (S.HasOwnProp("Priority") ? S.Priority : "")
			}
		}
		return Out
	}

	; Extension and common categories both use _HotstringsOverrides
	OverrideKey := Entry.IsExtension ? ("ext." . Entry.ExtId) : StrLower(Entry.Key)
	if !_HotstringsOverrides.Has(OverrideKey) {
		return Out
	}
	Override := _HotstringsOverrides[OverrideKey]
	if (Section == "") {
		Out.Delay := Override.Delay
		Out.Color := Override.Color
		Out.ShowTooltip := Override.ShowTooltip
		Out.Priority := (Override.HasOwnProp("Priority") ? Override.Priority : "")
	} else {
		Sec := StrLower(Section)
		if Override.Sections.Has(Sec) {
			S := Override.Sections[Sec]
			Out.Delay := S.Delay
			Out.Color := S.Color
			Out.ShowTooltip := S.ShowTooltip
			Out.Priority := (S.HasOwnProp("Priority") ? S.Priority : "")
		}
	}
	return Out
}
