; drivers/autohotkey/lib/hotstrings/hotstrings_config_window.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window
; DESCRIPTION:
; Native Gui v2 editor for the per-group expansion delay and tooltip color of
; every hotstring category and section. The data layer lives in
; lib\hotstrings_config.ahk for common categories; for personal TOML files the
; overrides are written directly to [_meta] / [_meta.sections.*] inside the
; target file so the file stays self-contained.
;
; FEATURES & RATIONALE:
; 1. Three-tier group selector — "Commun" / "Personnel" / one entry per
;    bundled extension — narrows the file dropdown to the selected group,
;    matching the tray menu hierarchy the user already navigates.
; 2. File dropdown — lists TOML files within the selected group so the user
;    can jump between files without leaving the window.
; 3. Source-aware mutations — the window checks whether the selected entry is
;    a common category, a personal file, or an extension and dispatches the
;    write accordingly: common → hotstrings_config.toml via HotstringsSetOverride;
;    personal → [_meta] in the TOML file via _HCW_PatchTomlMeta;
;    extension → hotstrings_config.toml under key "ext.<id>" via HotstringsSetOverride.
; 4. Delay default fix — when no TOML [_meta] delay is set the hint falls back
;    to GLOBAL_DEFAULT_DELAY (never shows "0 ms").
; 5. Thousands separator — delay values are formatted "2 000 ms" / "750 ms".
; 6. Singleton window — calling OpenHotstringsConfigWindow twice brings the
;    existing window forward instead of stacking duplicates.
; ==============================================================================

global _HCWGui      := 0
global _HCWWidgets  := 0

; Unified entry list — rebuilt each time the window opens.
; Shape: { Key, Label, Path, IsPersonal, IsExtension, ExtId, ExtName, Group }
global _HCW_CATEGORY_LIST := []

; Group list — derived from _HCW_CATEGORY_LIST.
; Shape: { Key, Label }
global _HCW_GROUP_LIST := []

; The bundled common categories (always present, in display order).
global _HCW_COMMON_CATS := [
	"magickey", "autocorrection", "rolls",
	"sfbsreduction", "distancesreduction"
]

; Override-only categories (no TOML file) — colour / delay live in
; hotstrings_config.toml under the category key (e.g. llm_prediction).
global _HCW_VIRTUAL_CATS := ["llm_prediction"]

; Locale-dependent labels — populated lazily at window-open time.
global _HCW_CATEGORY_LABELS := Map()
global _HCW_COLOR_PRESETS   := []
global _HCW_FILE_LEVEL_LABEL := ""

; Populate all locale-dependent labels. Called at window-open time so that
; i18n is fully initialised and the correct locale is active.
_HCW_InitLocaleStrings() {
	global _HCW_CATEGORY_LABELS, _HCW_COLOR_PRESETS, _HCW_FILE_LEVEL_LABEL
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
	; (warm → cool → neutral) so the picker reads naturally.
	_HCW_COLOR_PRESETS := [
		Map("Label", t("hs_config.color_inherit"),   "Hex", ""),
		Map("Label", t("hs_config.color_red"),       "Hex", "#e53935"),
		Map("Label", t("hs_config.color_pink"),      "Hex", "#e91e63"),
		Map("Label", t("hs_config.color_purple"),    "Hex", "#8e44ad"),
		Map("Label", t("menu.hotstrings.tooltip_ai"), "Hex", "#AD61FF"),
		Map("Label", t("hs_config.color_indigo"),    "Hex", "#3f51b5"),
		Map("Label", t("hs_config.color_blue"),      "Hex", "#1e88e5"),
		Map("Label", t("hs_config.color_cyan"),      "Hex", "#00838f"),
		Map("Label", t("hs_config.color_turquoise"), "Hex", "#009688"),
		Map("Label", t("hs_config.color_green"),     "Hex", "#43a047"),
		Map("Label", t("hs_config.color_lime"),      "Hex", "#9e9d24"),
		Map("Label", t("hs_config.color_yellow"),    "Hex", "#fdd835"),
		Map("Label", t("hs_config.color_orange"),    "Hex", "#fb8c00"),
		Map("Label", t("hs_config.color_brown"),     "Hex", "#8d6e63"),
		Map("Label", t("hs_config.color_gray"),      "Hex", "#6e6e73"),
	]
	_HCW_FILE_LEVEL_LABEL := t("hs_config.file_level")
}

; Build the unified category list:
; 1. Common categories (Group: "common")
; 2. Personal TOML files discovered from PersonalHotstringsDir (Group: "personal")
; 3. Extension TOML files discovered from the extensions root (Group: "ext:<id>")
_HCW_BuildCategoryList() {
	global _HCW_CATEGORY_LIST, _HCW_COMMON_CATS, _HCW_CATEGORY_LABELS
	List := []

	; --- Common categories ---
	for _, Cat in _HCW_COMMON_CATS {
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
				if (SubStr(Stem, 1, 1) == "_") {
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
	; Resolve extensions root relative to the driver's static/ ancestor
	SplitPath(A_ScriptDir, , &DriversDir)
	SplitPath(DriversDir, , &StaticDir)
	ExtRoot := StaticDir . "\extensions\"
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

	_HCW_CATEGORY_LIST := List
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

; Format a millisecond count with a space thousands separator, e.g. "2 000 ms".
_HCW_FmtMs(Ms) {
	Str := Format("{:d}", Round(Ms))
	Out := ""
	Count := 0
	Pos := StrLen(Str)
	while Pos >= 1 {
		if (Count > 0 and Mod(Count, 3) == 0) {
			Out := " " . Out
		}
		Out := SubStr(Str, Pos, 1) . Out
		Pos--
		Count++
	}
	return Out . " ms"
}





; ============================================================
; ============================================================
; ======= 1/ Public entry point ==============================
; ============================================================
; ============================================================

OpenHotstringsConfigWindow() {
	global _HCWGui, _HCWWidgets
	_HCW_InitLocaleStrings()
	_HCW_BuildCategoryList()
	_HCW_BuildGroupList()
	if _HCWGui {
		try _HCWGui.Show()
		return
	}

	G := Gui_Create("+Resize +MinSize580x320", t("hs_config.window_title"))
	G.SetFont("s10", "Segoe UI")
	G.MarginX := 14
	G.MarginY := 12

	; ----- Top action row (reset all first, then grey, no close here) ------
	; Auto-sized + harmonised so both buttons share the widest label — keeps
	; the pair aligned across locales whose verbs vary (e.g. German "Alles
	; zurücksetzen" is much wider than English "Reset all").
	BtnReset := G.Add("Button", "h28",         t("hs_config.btn_reset_all"))
	BtnGrey  := G.Add("Button", "x+6 yp h28",  t("hs_config.btn_all_gray"))
	Gui_HarmoniseButtonWidths([BtnReset, BtnGrey])
	BtnReset.OnEvent("Click", (*) => _HCW_ResetAll())
	BtnGrey.OnEvent("Click",  (*) => _HCW_SetAllGrey())

	G.Add("Text", "xm y+14 w526 h1 0x10")   ; horizontal rule (SS_SUNKEN)

	; ----- Group selector (full-width row) ---------------------------------
	G.Add("Text", "xm y+14 w70 h20", t("hs_config.label_group"))
	GroupDD := G.Add("DropDownList", "x+6 yp-3 w450 r14", _HCW_GroupItems())

	; ----- File selector (full-width row) ----------------------------------
	G.Add("Text", "xm y+10 w70 h20", t("hs_config.label_file"))
	FileDD := G.Add("DropDownList", "x+6 yp-3 w450 r14", [])

	; ----- Section selector (full-width row) -------------------------------
	G.Add("Text", "xm y+10 w70 h20", t("hs_config.label_section"))
	SecDD := G.Add("DropDownList", "x+6 yp-3 w450 r14", [])

	; ----- Current path hint (below selectors) ----------------------------
	Status := G.Add("Text", "xm y+6 w526 h18 cGray", "")

	G.Add("Text", "xm y+14 w526 h1 0x10")   ; horizontal rule (SS_SUNKEN)

	; ----- Delay row -------------------------------------------------------
	G.Add("Text", "xm y+14 w70 h20", t("hs_config.label_delay"))
	DelayEdit := G.Add("Edit", "x+6 yp-3 w80 Number")
	DelayUpDown := G.Add("UpDown", "Range0-10000", 0)
	G.Add("Text", "x+4 yp+3 w24", "ms")
	DelayDefault := G.Add("Text", "x+6 yp w300 Right", "")
	DelayReset := G.Add("Button", "x512 yp-3 w28 h24", "↺")

	; ----- Color row -------------------------------------------------------
	; The swatch is a filled Progress at value=100 — the BAR fills the whole
	; rectangle, so we set its bar color (cXXXXXX) AND background to the same
	; hex. Setting only Background, as we used to, left the bar painted in
	; the OS default tint (system blue) regardless of what the user picked.
	G.Add("Text", "xm y+10 w70 h20", t("hs_config.label_color"))
	ColorDD := G.Add("DropDownList", "x+6 yp-3 w180", _HCW_ColorLabels())
	InitSwatchHex := _HCW_HexNoHash(GLOBAL_DEFAULT_COLOR)
	ColorSwatch := G.Add("Progress",
		"x+8 yp+1 w22 h22 c" . InitSwatchHex . " Background" . InitSwatchHex,
		100)
	ColorDefault := G.Add("Text", "x+10 yp+2 w194 Right", "")
	ColorReset := G.Add("Button", "x512 yp-2 w28 h24", "↺")

	; ----- Tooltip toggle row (same group as delay/color, no HR before) ---
	TooltipChk := G.Add("Checkbox", "xm y+10", t("hs_config.label_tooltip"))
	TooltipReset := G.Add("Button", "x512 yp-2 w28 h24", "↺")

	G.Add("Text", "xm y+14 w526 h1 0x10")   ; section separator

	; ----- Word delimiters section -----------------------------------------
	G.Add("Text", "xm y+12 w526 h18", t("hs_config.label_delimiters"))
	G.Add("Text", "xm y+4 w526 h16 cGray", t("hs_config.delimiters_hint"))

	; Two rows of checkboxes, 8 per row, evenly spaced across the 526 px column.
	; Each checkbox captures its char via a closure over (Char).
	DelimChks := _HCW_BuildDelimiterCheckboxes(G)
	BtnDelimReset := G.Add("Button", "xm y+10 h24", t("hs_config.delimiters_reset"))
	Gui_HarmoniseButtonWidths([BtnDelimReset])
	BtnDelimReset.OnEvent("Click", (*) => _HCW_ResetDelimiters(DelimChks))

	G.Add("Text", "xm y+14 w526 h1 0x10")   ; horizontal rule aligned to x=540

	; ----- Close button (bottom, after HR) --------------------------------
	; Auto-sized to the localised label (with the 90 px floor) then centred
	; horizontally inside the 526 px content column. Computing X after the
	; harmonise step ensures the button stays centred regardless of locale.
	BtnClose := G.Add("Button", "xm y+14 h28", t("hs_config.btn_close"))
	Gui_HarmoniseButtonWidths([BtnClose])
	BtnClose.GetPos(, , &_closeW, )
	BtnClose.Move(14 + (526 - _closeW) // 2)
	BtnClose.OnEvent("Click", (*) => _HCWGui.Hide())

	_HCWWidgets := {
		Gui:          G,
		GroupDD:      GroupDD,
		FileDD:       FileDD,
		SecDD:        SecDD,
		DelayEdit:    DelayEdit,
		DelayReset:   DelayReset,
		DelayDefault: DelayDefault,
		ColorDD:      ColorDD,
		ColorSwatch:  ColorSwatch,
		ColorReset:   ColorReset,
		ColorDefault: ColorDefault,
		TooltipChk:   TooltipChk,
		TooltipReset: TooltipReset,
		Status:       Status,
		DelimChks:    DelimChks,
	}

	GroupDD.Choose(1)

	GroupDD.OnEvent("Change",   (*) => _HCW_OnGroupChanged())
	FileDD.OnEvent("Change",    (*) => _HCW_OnFileChanged())
	SecDD.OnEvent("Change",     (*) => _HCW_LoadCurrent())
	DelayEdit.OnEvent("Change", (*) => _HCW_OnDelayChanged())
	DelayReset.OnEvent("Click", (*) => _HCW_ClearField("delay"))
	ColorDD.OnEvent("Change",      (*) => _HCW_OnColorChanged())
	ColorReset.OnEvent("Click",    (*) => _HCW_ClearField("color"))
	TooltipChk.OnEvent("Click",    (*) => _HCW_OnTooltipChanged())
	TooltipReset.OnEvent("Click",  (*) => _HCW_ClearField("show_tooltip"))
	G.OnEvent("Close",             (*) => _HCW_OnClose())

	_HCW_OnGroupChanged()    ; populate file + section dropdowns and first load
	_HCW_LoadDelimiterCheckboxes(DelimChks)   ; tick boxes for current delimiters

	G.Show()
	_HCWGui := G
}





; ============================================================
; ============================================================
; ======= 2/ Change handlers =================================
; ============================================================
; ============================================================

; Rebuild the file dropdown whenever the group selection changes.
_HCW_OnGroupChanged() {
	global _HCWWidgets
	GroupKey := _HCW_SelectedGroupKey()
	Files := _HCW_FilesForGroup(GroupKey)
	Items := []
	for _, E in Files {
		Items.Push(E.Label)
	}
	_HCWWidgets.FileDD.Delete()
	_HCWWidgets.FileDD.Add(Items)
	if Items.Length > 0 {
		_HCWWidgets.FileDD.Choose(1)
	}
	_HCW_OnFileChanged()
}

; Rebuild the section dropdown whenever the file selection changes.
_HCW_OnFileChanged() {
	global _HCWWidgets, _HCW_FILE_LEVEL_LABEL
	Entry := _HCW_SelectedEntry()
	Items := [_HCW_FILE_LEVEL_LABEL]
	Sections := _HCW_GetSections(Entry)
	for _, Sec in Sections {
		Items.Push(Sec.Title . "  —  " . Sec.Name)
	}
	_HCWWidgets.SecDD.Delete()
	_HCWWidgets.SecDD.Add(Items)
	_HCWWidgets.SecDD.Choose(1)
	_HCW_LoadCurrent()
}

; Pull the current selection and refresh the delay/color controls.
_HCW_LoadCurrent() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Resolved := _HCW_Resolve(Entry, Sec)
	Defaults := _HCW_TomlDefaults(Entry, Sec)
	Override := _HCW_UserOverride(Entry, Sec)

	FallbackDelayMs := _HCW_FallbackDelayMs(Entry)
	DelayMs := (Resolved.Delay != "") ? Round(Resolved.Delay * 1000) : FallbackDelayMs

	; Fall back to the category baseline when the TOML has no [_meta] delay,
	; so the hint never shows "0 ms".
	DelayDefMs := (Defaults.Delay != "") ? Round(Defaults.Delay * 1000) : FallbackDelayMs
	DelayOverridden := (Override.HasOwnProp("Delay") and Override.Delay != "")

	_HCWWidgets.DelayEdit.Value := DelayMs

	DefHint := t("hs_config.default_prefix") . _HCW_FmtMs(DelayDefMs)
	if DelayOverridden {
		DefHint .= "    •  " . t("hs_config.override_active")
		_HCWWidgets.DelayReset.Enabled := true
	} else {
		_HCWWidgets.DelayReset.Enabled := false
	}
	_HCWWidgets.DelayDefault.Value := DefHint

	; Color — find the preset whose hex matches, or inject the current hex on top.
	ColorHex := Resolved.Color
	Idx := _HCW_ColorIndexFor(ColorHex)
	if (Idx == 0 and ColorHex != "") {
		_HCW_RebuildColorDropdown(ColorHex)
		Idx := 1
	} else if (Idx == 0) {
		_HCW_RebuildColorDropdown("")
		Idx := 1
	} else {
		_HCW_RebuildColorDropdown("")
	}
	_HCWWidgets.ColorDD.Choose(Idx)
	; ``Resolved.Color`` is now guaranteed non-empty by the resolver — when
	; nothing is set anywhere, it returns the global default. Repaint BOTH
	; the bar (cXXXXXX) and the background so the swatch fills with the
	; selected color end-to-end.
	SwatchHex := _HCW_HexNoHash(ColorHex)
	_HCWWidgets.ColorSwatch.Opt("+c" . SwatchHex . " +Background" . SwatchHex)

	ColorOverridden := (Override.HasOwnProp("Color") and Override.Color != "")
	DefColor := (Defaults.Color != "") ? Defaults.Color : t("hs_config.none")
	Hint := t("hs_config.default_prefix") . DefColor
	if ColorOverridden {
		Hint .= "    •  " . t("hs_config.override_active")
		_HCWWidgets.ColorReset.Enabled := true
	} else {
		_HCWWidgets.ColorReset.Enabled := false
	}
	_HCWWidgets.ColorDefault.Value := Hint

	; Tooltip toggle — resolved ShowTooltip (true = checked).
	TooltipResolved := Resolved.HasOwnProp("ShowTooltip") ? Resolved.ShowTooltip : true
	_HCWWidgets.TooltipChk.Value := TooltipResolved ? 1 : 0
	TooltipOverridden := (Override.HasOwnProp("ShowTooltip") and Override.ShowTooltip != "")
	_HCWWidgets.TooltipReset.Enabled := TooltipOverridden

	_HCWWidgets.Status.Value := _HCW_StatusPath(Entry, Sec)
}





; ============================================================
; ============================================================
; ======= 3/ Mutations =======================================
; ============================================================
; ============================================================

_HCW_OnDelayChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Ms := _HCWWidgets.DelayEdit.Value + 0
	if (Ms < 0) {
		Ms := 0
	}
	_HCW_SetOverride(Entry, Sec, "delay", Ms / 1000)
	_HCW_LoadCurrent()
}

_HCW_OnColorChanged() {
	global _HCWWidgets, _HCW_CurrentColorOptions
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Idx := _HCWWidgets.ColorDD.Value
	if (Idx < 1) {
		return
	}
	Hex := _HCW_CurrentColorOptions[Idx].Hex
	if (Hex == "") {
		_HCW_ClearOverride(Entry, Sec, "color")
	} else {
		_HCW_SetOverride(Entry, Sec, "color", Hex)
	}
	_HCW_LoadCurrent()
}

_HCW_OnTooltipChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Val := (_HCWWidgets.TooltipChk.Value == 1)
	_HCW_SetOverride(Entry, Sec, "show_tooltip", Val)
	_HCW_LoadCurrent()
}

_HCW_ClearField(Field) {
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	_HCW_ClearOverride(Entry, Sec, Field)
	_HCW_LoadCurrent()
}

_HCW_ResetAll() {
	global _HCW_CATEGORY_LIST, _HCWGui
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "delay", "")
			_HCW_PatchTomlMeta(E.Path, "", "color", "")
			for _, Sec in _HCW_GetSections(E) {
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "delay", "")
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
			}
		} else if E.IsExtension {
			HotstringsClearOverride("ext." . E.ExtId, "", "")
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "")
			}
		} else {
			HotstringsClearOverride(E.Key, "", "")
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride(E.Key, Sec.Name, "")
			}
		}
	}
	if (_HCWGui != 0) {
		_HCWGui.Destroy()
	}
	TrayTip(t("hs_config.notify_reset_all"), t("hs_config.btn_reset_all"), "Iconi Mute")
}

; Force every category/extension to grey at file level; clear per-section colour
; overrides for a consistent cascade. Personal file TOMLs are patched in-place.
_HCW_SetAllGrey() {
	global _HCW_CATEGORY_LIST
	Grey := "#6e6e73"
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
			}
		} else if E.IsExtension {
			HotstringsSetOverride("ext." . E.ExtId, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "color")
			}
		} else {
			HotstringsSetOverride(E.Key, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride(E.Key, Sec.Name, "color")
			}
		}
	}
	_HCW_LoadCurrent()
}

_HCW_OnClose() {
	global _HCWGui, _HCWWidgets
	_HCWGui := 0
	_HCWWidgets := 0
}


; Configurable delimiter entries, sourced from the shared terminator catalogue
; (HSE_Terminators) so the config window and the tray submenu never drift from
; each other or from macOS. Separator markers are skipped — the checkbox grid
; has no dividers. Each entry carries its full chars array (e.g. Entrée = CR+LF)
; so a multi-char slot toggles as a single unit.
_HCW_DELIMITER_DEFS() {
	global HSE_Terminators
	Defs := []
	for D in HSE_Terminators.all() {
		if (D.Has("type") and D["type"] == "separator")
			continue
		Defs.Push({ Chars: D["chars"], Label: D["label"] })
	}
	return Defs
}

; Build a grid of checkboxes (4 per row) for each configurable delimiter.
; Returns an Array of { Chars, Chk } so callers can read/set .Value.
_HCW_BuildDelimiterCheckboxes(G) {
	Defs := _HCW_DELIMITER_DEFS()
	Chks := []
	ColW := 120    ; px per column (526 / 4 ≈ 131, leaving a small margin)
	Cols := 4
	for Idx, D in Defs {
		Col := Mod(Idx - 1, Cols)
		if (Col == 0) {
			Opt := (Idx == 1) ? ("xm y+8 w" . ColW) : ("xm y+6 w" . ColW)
		} else {
			Opt := "x+4 yp w" . ColW
		}
		Chk := G.Add("Checkbox", Opt, D.Label)
		Chk.OnEvent("Click", (*) => _HCW_OnDelimiterChanged())
		Chks.Push({ Chars: D.Chars, Chk: Chk })
	}
	return Chks
}

; Tick/untick the delimiter checkboxes to match the current effective string —
; a box is ticked when every char of its catalogue entry is active.
_HCW_LoadDelimiterCheckboxes(DelimChks) {
	Current := HotstringsGetWordDelimiters()
	for _, Entry in DelimChks {
		Entry.Chk.Value := HSE_TerminatorEntryEnabled(Entry.Chars, Current) ? 1 : 0
	}
}

; Called when any delimiter checkbox is clicked — rebuild the string from all
; checkbox states (preserving any custom chars added via the tray menu) and
; persist it.
_HCW_OnDelimiterChanged() {
	global _HCWWidgets
	if !IsObject(_HCWWidgets) or !_HCWWidgets.HasOwnProp("DelimChks") {
		return
	}
	; Chars owned by the catalogue — used to tell custom chars apart.
	BuiltinChars := HSE_TerminatorBuiltinChars()
	New := ""
	for _, Entry in _HCWWidgets.DelimChks {
		if (Entry.Chk.Value == 1) {
			for Ch in Entry.Chars {
				if !InStr(New, Ch)
					New .= Ch
			}
		}
	}
	; Preserve custom chars: present in the active string, owned by no catalogue
	; entry, and not the structural CR/LF that belong to the Entrée entry.
	Current := HotstringsGetWordDelimiters()
	Loop Parse, Current {
		Ch := A_LoopField
		if (Ch != "`r" and Ch != "`n" and !InStr(BuiltinChars, Ch) and !InStr(New, Ch))
			New .= Ch
	}
	HotstringsSetWordDelimiters(New)
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Reset all delimiter checkboxes to the built-in defaults.
_HCW_ResetDelimiters(DelimChks) {
	global HOTSTRINGS_DEFAULT_WORD_DELIMITERS
	HotstringsSetWordDelimiters(HOTSTRINGS_DEFAULT_WORD_DELIMITERS)
	_HCW_LoadDelimiterCheckboxes(DelimChks)
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}





; ============================================================
; ============================================================
; ======= 4/ Source-aware read/write dispatch ================
; ============================================================
; ============================================================

; Write an override to the correct backend:
; - personal  → [_meta] in the TOML file
; - extension → hotstrings_config.toml under key "ext.<id>"
; - common    → hotstrings_config.toml under the category key
_HCW_SetOverride(Entry, Sec, Field, Value) {
	if Entry.IsPersonal {
		_HCW_PatchTomlMeta(Entry.Path, Sec, Field, Value)
	} else if Entry.IsExtension {
		HotstringsSetOverride("ext." . Entry.ExtId, Sec, Field, Value)
	} else {
		HotstringsSetOverride(Entry.Key, Sec, Field, Value)
	}
}

_HCW_ClearOverride(Entry, Sec, Field) {
	if Entry.IsPersonal {
		_HCW_PatchTomlMeta(Entry.Path, Sec, Field, "")
	} else if Entry.IsExtension {
		HotstringsClearOverride("ext." . Entry.ExtId, Sec, Field)
	} else {
		HotstringsClearOverride(Entry.Key, Sec, Field)
	}
}

; Resolve the effective delay, color, and show_tooltip for the current entry.
_HCW_Resolve(Entry, Sec) {
	if Entry.IsPersonal {
		return _HCW_ReadTomlMeta(Entry.Path, Sec)
	}
	if Entry.IsExtension {
		R := HotstringsResolveExt(Entry.ExtId, Entry.Path, Sec)
		return { Delay: R.Delay, Color: R.Color, ShowTooltip: R.ShowTooltip }
	}
	return HotstringsResolve(Entry.Key, Sec)
}

; Read effective delay, color, and show_tooltip from [_meta] of a personal TOML file,
; applying the cascade: section → file → default (true for ShowTooltip).
_HCW_ReadTomlMeta(Path, Sec) {
	FileCfg := ParseTomlGroupConfig("__personal__", Path)
	Result := { Delay: FileCfg.Delay, Color: FileCfg.Color, ShowTooltip: FileCfg.ShowTooltip != "" ? FileCfg.ShowTooltip : true }
	if (Sec != "" and FileCfg.Sections.Has(StrLower(Sec))) {
		SecCfg := FileCfg.Sections[StrLower(Sec)]
		if (SecCfg.Delay != "") {
			Result.Delay := SecCfg.Delay
		}
		if (SecCfg.Color != "") {
			Result.Color := SecCfg.Color
		}
		if (SecCfg.ShowTooltip != "") {
			Result.ShowTooltip := SecCfg.ShowTooltip
		}
	}
	return Result
}





; ============================================================
; ============================================================
; ======= 5/ Helpers =========================================
; ============================================================
; ============================================================

; Returns the key string of the currently selected group.
_HCW_SelectedGroupKey() {
	global _HCWWidgets, _HCW_GROUP_LIST
	Idx := _HCWWidgets.GroupDD.Value
	if (Idx < 1 or Idx > _HCW_GROUP_LIST.Length) {
		return "common"
	}
	return _HCW_GROUP_LIST[Idx].Key
}

; Returns the subset of _HCW_CATEGORY_LIST matching the given group key.
_HCW_FilesForGroup(GroupKey) {
	global _HCW_CATEGORY_LIST
	Out := []
	for _, E in _HCW_CATEGORY_LIST {
		if (E.Group == GroupKey) {
			Out.Push(E)
		}
	}
	return Out
}

; Returns the full entry object for the currently selected group + file pair.
_HCW_SelectedEntry() {
	GroupKey := _HCW_SelectedGroupKey()
	Files := _HCW_FilesForGroup(GroupKey)
	Idx := _HCWWidgets.FileDD.Value
	if (Idx < 1 or Idx > Files.Length) {
		if Files.Length > 0 {
			return Files[1]
		}
		return { Key: "", Label: "", Path: "", IsPersonal: false, IsExtension: false, ExtId: "", ExtName: "", Group: "" }
	}
	return Files[Idx]
}

_HCW_SelectedSection(Entry) {
	global _HCWWidgets
	Idx := _HCWWidgets.SecDD.Value
	if (Idx <= 1) {
		return ""
	}
	Sections := _HCW_GetSections(Entry)
	if (Idx - 1 > Sections.Length) {
		return ""
	}
	return Sections[Idx - 1].Name
}

_HCW_GroupItems() {
	global _HCW_GROUP_LIST
	Out := []
	for _, G in _HCW_GROUP_LIST {
		Out.Push(G.Label)
	}
	return Out
}

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
_HCW_GetSections(Entry) {
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
			Path := _SharedDir . "\hotstrings\" . StrLower(Cat) . ".toml"
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
	FileContent := ReadTomlFile(Path)
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

	Order := []
	if (SectionsOrderRaw != "") {
		Pos := 1
		while (RegExMatch(SectionsOrderRaw, '"([^"]*)"', &Tok, Pos)) {
			T := StrLower(Tok[1])
			if (T != "-" and Seen.Has(T)) {
				Order.Push(T)
			}
			Pos := Tok.Pos + Tok.Len
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

; Build the repo-relative path string shown in the status bar.
; For common categories: hotstrings/<name>.toml
; For personal files: path relative to the repo root (PersonalHotstringsDir ancestor)
; For extensions: extensions/<ext_id>/hotstrings/<stem>.toml
; A section name is appended when one is selected.
_HCW_StatusPath(Entry, Sec) {
	if Entry.IsPersonal {
		; Make path relative to the repo root by stripping the static/ ancestor prefix
		Path := Entry.Path
		SplitPath(A_ScriptDir, , &DriversDir)
		SplitPath(DriversDir, , &StaticDir)
		SplitPath(StaticDir, , &RepoDir)
		Rel := StrReplace(Path, RepoDir . "\", "")
		Rel := StrReplace(Rel, "\", "/")
	} else if Entry.IsExtension {
		SplitPath(Entry.Path, &FileName)
		Stem := RegExReplace(FileName, "\.toml$", "")
		Rel := "extensions/" . Entry.ExtId . "/hotstrings/" . Stem . ".toml"
	} else {
		Rel := "hotstrings/" . StrLower(Entry.Key) . ".toml"
	}
	if (Sec != "") {
		Rel .= "  [" . Sec . "]"
	}
	return Rel
}


_HCW_FallbackDelayMs(Entry) {
	global GLOBAL_DEFAULT_DELAY, UI_LLM_TIMEOUT_SEC
	if (Entry.Key = "llm_prediction")
		return Round(UI_LLM_TIMEOUT_SEC * 1000)
	return Round(GLOBAL_DEFAULT_DELAY * 1000)
}

_HCW_TomlDefaults(Entry, Section) {
	if (Entry.HasOwnProp("IsVirtual") and Entry.IsVirtual) {
		if (Entry.Key = "llm_prediction") {
			global HOTSTRINGS_CATEGORY_DEFAULT_COLORS, UI_LLM_TIMEOUT_SEC
			return {
				Delay: UI_LLM_TIMEOUT_SEC,
				Color: HOTSTRINGS_CATEGORY_DEFAULT_COLORS.Has("llm_prediction")
					? HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] : ""
			}
		}
		return { Delay: "", Color: "" }
	}
	if Entry.IsPersonal {
		Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
	} else if Entry.IsExtension {
		Cfg := ParseTomlGroupConfig("__ext__", Entry.Path)
	} else {
		Cfg := ParseTomlGroupConfig(Entry.Key)
	}
	Default := { Delay: Cfg.Delay, Color: Cfg.Color }
	if (Section != "" and Cfg.Sections.Has(StrLower(Section))) {
		Sec := Cfg.Sections[StrLower(Section)]
		if (Sec.Delay != "") {
			Default.Delay := Sec.Delay
		}
		if (Sec.Color != "") {
			Default.Color := Sec.Color
		}
	}
	return Default
}

_HCW_UserOverride(Entry, Section) {
	global _HotstringsOverrides
	Out := { Delay: "", Color: "", ShowTooltip: "" }
	if Entry.IsPersonal {
		; The stored value IS the override — re-read [_meta] to find what is actually stored
		Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
		if (Section == "") {
			Out.Delay := Cfg.Delay
			Out.Color := Cfg.Color
			Out.ShowTooltip := Cfg.ShowTooltip
		} else {
			Sec := StrLower(Section)
			if Cfg.Sections.Has(Sec) {
				S := Cfg.Sections[Sec]
				Out.Delay := S.Delay
				Out.Color := S.Color
				Out.ShowTooltip := S.ShowTooltip
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
	} else {
		Sec := StrLower(Section)
		if Override.Sections.Has(Sec) {
			S := Override.Sections[Sec]
			Out.Delay := S.Delay
			Out.Color := S.Color
			Out.ShowTooltip := S.ShowTooltip
		}
	}
	return Out
}





; ============================================================
; ============================================================
; ======= 6/ Personal TOML [_meta] patcher ==================
; ============================================================
; ============================================================

; Patch or clear a single field (delay or color) in [_meta] or
; [_meta.sections.<sec>] of a personal TOML file. When Value is "" the key
; is removed. The file is rewritten in-place; all other content is preserved.
;
; Strategy: scan lines once, track which "zone" we are in, emit each line
; unchanged except for the target zone where the field is added or removed.
; If the target header was never found, append it at the end.
_HCW_PatchTomlMeta(Path, Sec, Field, Value) {
	if !FileExist(Path) {
		return
	}

	FileContent := ReadTomlFile(Path)
	Lines := StrSplit(FileContent, "`n", "`r")
	Field := StrLower(Field)
	Sec   := StrLower(Sec)

	TargetHeader := (Sec == "") ? "[_meta]" : "[_meta.sections." . Sec . "]"

	InTarget  := false
	Found     := false
	FieldDone := false
	Out       := []

	for _, RawLine in Lines {
		Line := Trim(RawLine, " `t`r")

		if RegExMatch(Line, "^\[") {
			if InTarget and !FieldDone and Value != "" {
				Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
				FieldDone := true
			}
			InTarget := (Line == TargetHeader)
			if InTarget {
				Found := true
				FieldDone := false
			}
			Out.Push(RawLine)
			continue
		}

		if InTarget {
			if RegExMatch(Line, "^" . Field . "\s*=", &_) {
				if Value != "" and !FieldDone {
					Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
					FieldDone := true
				}
				continue
			}
		}

		Out.Push(RawLine)
	}

	if InTarget and !FieldDone and Value != "" {
		Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
	}

	if !Found and Value != "" {
		Out.Push("")
		Out.Push(TargetHeader)
		Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
	}

	_ParseTomlGroupConfig_InvalidatePath(Path)

	NewContent := ""
	for I, L in Out {
		NewContent .= L
		if (I < Out.Length) {
			NewContent .= "`n"
		}
	}
	try FileOpen(Path, "w", "UTF-8").Write(NewContent)
}

; Format a value for TOML output.
; delay → bare float (seconds); show_tooltip → bare boolean; color → quoted string.
_HCW_TomlValue(Field, Value) {
	if (Field == "delay") {
		Num := Value + 0
		return Format("{:.3f}", Num)
	}
	if (Field == "show_tooltip") {
		return Value ? "true" : "false"
	}
	Escaped := StrReplace(Value, "\", "\\")
	Escaped := StrReplace(Escaped, '"', '\"')
	return '"' . Escaped . '"'
}





; ============================================================
; ============================================================
; ======= 7/ Color dropdown helpers ==========================
; ============================================================
; ============================================================

global _HCW_CurrentColorOptions := []

_HCW_ColorLabels() {
	global _HCW_COLOR_PRESETS
	Out := []
	for _, P in _HCW_COLOR_PRESETS {
		Out.Push(P["Label"])
	}
	return Out
}

; Rebuild the color dropdown items, optionally injecting an extra "current"
; entry on top when the active hex is not already part of the preset list.
_HCW_RebuildColorDropdown(InjectHex) {
	global _HCWWidgets, _HCW_COLOR_PRESETS, _HCW_CurrentColorOptions
	Options := []
	if (InjectHex != "" and !_HCW_HexInPresets(InjectHex)) {
		Options.Push({ Label: InjectHex, Hex: InjectHex })
	}
	for _, P in _HCW_COLOR_PRESETS {
		Options.Push({ Label: P["Label"], Hex: P["Hex"] })
	}
	_HCW_CurrentColorOptions := Options

	Items := []
	for _, O in Options {
		Items.Push(O.Label)
	}
	_HCWWidgets.ColorDD.Delete()
	_HCWWidgets.ColorDD.Add(Items)
}

_HCW_ColorIndexFor(Hex) {
	global _HCW_CurrentColorOptions
	if !IsObject(_HCW_CurrentColorOptions) {
		return 0
	}
	Lower := StrLower(Hex)
	for Idx, O in _HCW_CurrentColorOptions {
		if (StrLower(O.Hex) == Lower) {
			return Idx
		}
	}
	return 0
}

_HCW_HexInPresets(Hex) {
	global _HCW_COLOR_PRESETS
	Lower := StrLower(Hex)
	for _, P in _HCW_COLOR_PRESETS {
		if (StrLower(P["Hex"]) == Lower) {
			return true
		}
	}
	return false
}

_HCW_HexNoHash(Hex) {
	if (Hex == "") {
		return "CCCCCC"
	}
	if (SubStr(Hex, 1, 1) == "#") {
		return SubStr(Hex, 2)
	}
	return Hex
}
