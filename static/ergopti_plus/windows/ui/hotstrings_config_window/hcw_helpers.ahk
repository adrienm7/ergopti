; ui/hotstrings_config_window/hcw_helpers.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window — Helpers
; DESCRIPTION:
; Read-only helpers and UI builders for the hotstrings config window. Contains
; globals, locale string initialisation, category/group list builders, sort and
; format utilities, the public window entry point, change handlers that only
; read and dispatch, selection getters, section scanner, status path builder,
; TOML default and user-override readers, and color dropdown helpers.
;
; RATIONALE:
; Extracted from init.ahk so the read path (querying, formatting, populating
; controls) stays separate from the write path (mutations live in
; hcw_mutations.ahk). Callers that only need to inspect state import only this
; file; the thin shim (init.ahk) includes both.
; ==============================================================================

global _HCWGui      := 0
global _HCWWidgets  := 0

; Debounce window for the numeric Edit fields (delay / priority). Their "Change"
; event fires on every keystroke, but persisting on every digit rewrites the
; override file (and, for personal entries, re-reads + re-serialises the whole
; TOML) per character. We coalesce a burst of edits into a single write fired
; once the user pauses typing. Negative value = one-shot SetTimer.
global _HCW_NUMERIC_DEBOUNCE_MS := 250
; Pending debounced numeric write captured at arm time:
; { Field, Entry, Sec, Value }. Each keystroke re-arms it with the latest
; widget value AND the still-current selection, so the final value lands on the
; entry the user was actually editing even if they switch selection or close the
; window before the timer fires. 0 when no write is pending.
global _HCW_PendingNumericWrite := 0

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
	; Prefer the shared WebView2 frontend (identical UI to macOS). It falls back
	; to the native Gui below only when the WebView2 runtime is unavailable.
	if _HCWWeb_TryOpen()
		return
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

	; ----- Priority row ----------------------------------------------------
	; Higher priority wins a same-trigger collision (cascade: individual >
	; section > file > source default 10/30/50). Editing here writes the
	; section/file override to the shared override file (or personal [_meta]),
	; and the empty w24 spacer keeps the default hint aligned with the delay row.
	G.Add("Text", "xm y+10 w70 h20", t("hs_config.label_priority"))
	PriorityEdit := G.Add("Edit", "x+6 yp-3 w80 Number +Limit3")
	PriorityUpDown := G.Add("UpDown", "Range0-100", 0)
	G.Add("Text", "x+4 yp+3 w24", "")
	PriorityDefault := G.Add("Text", "x+6 yp w300 Right", "")
	PriorityReset := G.Add("Button", "x512 yp-3 w28 h24", "↺")

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

	G.Add("Text", "xm y+14 w526 h1 0x10")   ; horizontal rule before the close button

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
		PriorityEdit:    PriorityEdit,
		PriorityReset:   PriorityReset,
		PriorityDefault: PriorityDefault,
		ColorDD:      ColorDD,
		ColorSwatch:  ColorSwatch,
		ColorReset:   ColorReset,
		ColorDefault: ColorDefault,
		TooltipChk:   TooltipChk,
		TooltipReset: TooltipReset,
		Status:       Status,
	}

	GroupDD.Choose(1)

	GroupDD.OnEvent("Change",   (*) => _HCW_OnGroupChanged())
	FileDD.OnEvent("Change",    (*) => _HCW_OnFileChanged())
	SecDD.OnEvent("Change",     (*) => _HCW_OnSectionChanged())
	DelayEdit.OnEvent("Change", (*) => _HCW_OnDelayChanged())
	DelayReset.OnEvent("Click", (*) => _HCW_ClearField("delay"))
	PriorityEdit.OnEvent("Change", (*) => _HCW_OnPriorityChanged())
	PriorityReset.OnEvent("Click", (*) => _HCW_ClearField("priority"))
	ColorDD.OnEvent("Change",      (*) => _HCW_OnColorChanged())
	ColorReset.OnEvent("Click",    (*) => _HCW_ClearField("color"))
	TooltipChk.OnEvent("Click",    (*) => _HCW_OnTooltipChanged())
	TooltipReset.OnEvent("Click",  (*) => _HCW_ClearField("show_tooltip"))
	G.OnEvent("Close",             (*) => _HCW_OnClose())

	_HCW_OnGroupChanged()    ; populate file + section dropdowns and first load

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
	; Persist any pending numeric edit before the selection moves, otherwise the
	; debounced write would target the previous entry or be silently dropped.
	_HCW_FlushNumericWrite()
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
	; Commit any pending numeric edit to its captured entry before re-selecting.
	_HCW_FlushNumericWrite()
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

; Refresh the controls when the section selection changes. Commits any pending
; numeric edit to its captured entry first so a debounced write is never lost
; when the user jumps to another section before the timer fires.
_HCW_OnSectionChanged() {
	_HCW_FlushNumericWrite()
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

	; Priority — the resolver always returns a non-empty value (it folds in the
	; source default), so the edit shows the effective priority. The default hint
	; falls back to the source tier when neither TOML nor override sets one.
	PrioDefVal := (Defaults.HasOwnProp("Priority") and Defaults.Priority != "")
		? Defaults.Priority
		: _HCW_FallbackPriority(Entry)
	PrioVal := (Resolved.HasOwnProp("Priority") and Resolved.Priority != "")
		? Resolved.Priority
		: PrioDefVal
	PrioOverridden := (Override.HasOwnProp("Priority") and Override.Priority != "")

	_HCWWidgets.PriorityEdit.Value := PrioVal

	PrioHint := t("hs_config.default_prefix") . PrioDefVal
	if PrioOverridden {
		PrioHint .= "    •  " . t("hs_config.override_active")
		_HCWWidgets.PriorityReset.Enabled := true
	} else {
		_HCWWidgets.PriorityReset.Enabled := false
	}
	_HCWWidgets.PriorityDefault.Value := PrioHint

	; Color — find the preset whose hex matches, or inject the current hex on top.
	; Rebuild the dropdown first, then re-query the index so the position is
	; always derived from the current option list rather than a pre-rebuild snapshot.
	ColorHex := Resolved.Color
	if (ColorHex != "" and !_HCW_HexInPresets(ColorHex))
		_HCW_RebuildColorDropdown(ColorHex)
	else
		_HCW_RebuildColorDropdown("")
	Idx := _HCW_ColorIndexFor(ColorHex)
	if (Idx == 0)
		Idx := 1
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
; ======= 3/ Selection helpers ===============================
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
			Path := _SharedDir . "\modules\hotstrings\" . StrLower(Cat) . ".toml"
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
		Rel := "modules/hotstrings/" . StrLower(Entry.Key) . ".toml"
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




; ============================================================
; ============================================================
; ======= 4/ Color dropdown helpers ==========================
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
