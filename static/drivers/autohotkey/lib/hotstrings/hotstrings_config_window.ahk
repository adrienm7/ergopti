; drivers/autohotkey/lib/hotstrings_config_window.ahk

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
; 1. Unified category list — common categories (magickey, autocorrection, …)
;    and personal TOML files appear in one dropdown, giving one coherent UI.
; 2. Source-aware mutations — the window checks whether the selected entry is
;    a common category or a personal file and dispatches the write accordingly:
;    common → hotstrings_config.toml via HotstringsSetOverride;
;    personal → [_meta] in the TOML file via _HCW_PatchTomlMeta.
; 3. "Niveau fichier" virtual section — picking it lets the user edit the
;    file-level [_meta] defaults without dropping into a leaf section.
; 4. Singleton window — calling OpenHotstringsConfigWindow twice brings the
;    existing window forward instead of stacking duplicates.
; 5. Quick presets — "Tout en gris" overrides every file-level colour and
;    clears section-level overrides so the grey cascade is uniform; "Tout
;    réinitialiser" wipes the override file entirely.
; ==============================================================================

global _HCWGui      := 0
global _HCWWidgets  := 0

; Ordered list for the category dropdown — rebuilt each time the window opens.
; Each entry: { Key, Label, Path, IsPersonal }
; Common categories use their TOML name as Key.
; Personal files use "personal:<stem>" as Key and carry Path to the TOML.
global _HCW_CATEGORY_LIST := []

; The six bundled common categories (always present, in display order).
global _HCW_COMMON_CATS := [
    "magickey", "autocorrection", "rolls",
    "sfbsreduction", "distancesreduction"
]

; Populated lazily in _HCW_InitLocaleStrings() — not at include time,
; because i18n is not yet loaded when this file is included.
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
    )
    ; First six entries mirror the bootstrap defaults shipped in the category
    ; TOMLs; the four following ones are fillers offered for variety.
    _HCW_COLOR_PRESETS := [
        Map("Label", t("hs_config.color_inherit"), "Hex", ""),
        Map("Label", t("hs_config.color_red"),     "Hex", "#e53935"),
        Map("Label", t("hs_config.color_green"),   "Hex", "#43a047"),
        Map("Label", t("hs_config.color_orange"),  "Hex", "#fb8c00"),
        Map("Label", t("hs_config.color_blue"),    "Hex", "#1e88e5"),
        Map("Label", t("hs_config.color_purple"),  "Hex", "#8e44ad"),
        Map("Label", t("hs_config.color_cyan"),    "Hex", "#00838f"),
        Map("Label", t("hs_config.color_yellow"),  "Hex", "#fdd835"),
        Map("Label", t("hs_config.color_gray"),    "Hex", "#6e6e73"),
    ]
    _HCW_FILE_LEVEL_LABEL := t("hs_config.file_level")
}

; Build the unified category list from the common categories + personal TOMLs.
; Personal TOML files are discovered from PersonalHotstringsDir and appended
; after the common categories.
_HCW_BuildCategoryList() {
    global _HCW_CATEGORY_LIST, _HCW_COMMON_CATS, _HCW_CATEGORY_LABELS
    List := []

    for _, Cat in _HCW_COMMON_CATS {
        Label := _HCW_CATEGORY_LABELS.Has(Cat) ? _HCW_CATEGORY_LABELS[Cat] : Cat
        List.Push({ Key: Cat, Label: Label, Path: "", IsPersonal: false })
    }

    ; Discover personal TOML files
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
            ; Sort alphabetically by stem so the order is deterministic
            PersonalFiles := _HCW_SortByKey(PersonalFiles, "Stem")
            for _, F in PersonalFiles {
                List.Push({
                    Key:        "personal:" . F.Stem,
                    Label:      F.Stem,
                    Path:       F.Path,
                    IsPersonal: true,
                })
            }
        }
    }

    _HCW_CATEGORY_LIST := List
}

; Stable insertion sort (AHK v2 has no built-in stable sort for objects).
_HCW_SortByKey(Arr, KeyName) {
    N := Arr.Length
    loop N - 1 {
        I := A_Index + 1
        while I > 1 and Arr[I - 1][KeyName] > Arr[I][KeyName] {
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
; ======= 1/ Public entry point =============================
; ============================================================
; ============================================================

OpenHotstringsConfigWindow() {
    global _HCWGui, _HCWWidgets
    _HCW_InitLocaleStrings()
    _HCW_BuildCategoryList()
    if _HCWGui {
        try _HCWGui.Show()
        return
    }

    G := Gui("+Resize +MinSize560x260", t("hs_config.window_title"))
    G.SetFont("s10", "Segoe UI")
    G.MarginX := 14
    G.MarginY := 12

    ; ----- Top action row --------------------------------------------------
    BtnGrey := G.Add("Button", "w120 h28",  t("hs_config.btn_all_gray"))
    BtnReset := G.Add("Button", "x+6 yp w160 h28", t("hs_config.btn_reset_all"))
    BtnClose := G.Add("Button", "x+6 yp w90 h28",  t("hs_config.btn_close"))
    BtnGrey.OnEvent("Click",  (*) => _HCW_SetAllGrey())
    BtnReset.OnEvent("Click", (*) => _HCW_ResetAll())
    BtnClose.OnEvent("Click", (*) => _HCWGui.Hide())

    ; ----- Selectors -------------------------------------------------------
    G.Add("Text", "xm y+18 w80", t("hs_config.label_category"))
    CatDD := G.Add("DropDownList", "x+6 yp-3 w200", _HCW_CategoryItems())
    G.Add("Text", "x+12 yp+3 w70", t("hs_config.label_section"))
    SecDD := G.Add("DropDownList", "x+6 yp-3 w260 r14", [])

    ; ----- Delay row -------------------------------------------------------
    G.Add("Text", "xm y+18 w80", t("hs_config.label_delay"))
    DelayEdit := G.Add("Edit", "x+6 yp-3 w90 Number")
    DelayUpDown := G.Add("UpDown", "Range0-10000", 0)
    DelayReset := G.Add("Button", "x+6 yp w28 h24", "↺")
    DelayDefault := G.Add("Text", "x+8 yp+3 w260", "")

    ; ----- Color row -------------------------------------------------------
    G.Add("Text", "xm y+10 w80", t("hs_config.label_color"))
    ColorDD := G.Add("DropDownList", "x+6 yp-3 w200", _HCW_ColorLabels())
    ColorSwatch := G.Add("Progress", "x+8 yp+1 w22 h22 BackgroundCCCCCC", 100)
    ColorReset := G.Add("Button", "x+8 yp-1 w28 h24", "↺")
    ColorDefault := G.Add("Text", "x+8 yp+3 w220", "")

    ; ----- Status / hint ---------------------------------------------------
    Status := G.Add("Text", "xm y+16 w560 h20 cGray", "")

    _HCWWidgets := {
        Gui:           G,
        CatDD:         CatDD,
        SecDD:         SecDD,
        DelayEdit:     DelayEdit,
        DelayReset:    DelayReset,
        DelayDefault:  DelayDefault,
        ColorDD:       ColorDD,
        ColorSwatch:   ColorSwatch,
        ColorReset:    ColorReset,
        ColorDefault:  ColorDefault,
        Status:        Status,
    }

    CatDD.Choose(1)

    CatDD.OnEvent("Change",     (*) => _HCW_OnCategoryChanged())
    SecDD.OnEvent("Change",     (*) => _HCW_LoadCurrent())
    DelayEdit.OnEvent("Change", (*) => _HCW_OnDelayChanged())
    DelayReset.OnEvent("Click", (*) => _HCW_ClearField("delay"))
    ColorDD.OnEvent("Change",   (*) => _HCW_OnColorChanged())
    ColorReset.OnEvent("Click", (*) => _HCW_ClearField("color"))
    G.OnEvent("Close",          (*) => _HCW_OnClose())

    _HCW_OnCategoryChanged()    ; populate sections + first load

    G.Show()
    _HCWGui := G
}


; ============================================================
; ============================================================
; ======= 2/ Category / section change handlers =============
; ============================================================
; ============================================================

; Refresh the sections dropdown for the currently selected category and
; refresh the form to display the file-level values for that category.
_HCW_OnCategoryChanged() {
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

; Read the current selection (category + section) and pull the delay / color
; effective values + defaults from HotstringsResolve / get_*. Writes the
; UI without firing any setter so this can be called any time the form
; needs to be refreshed.
_HCW_LoadCurrent() {
    global _HCWWidgets
    Entry := _HCW_SelectedEntry()
    Sec := _HCW_SelectedSection(Entry)
    Resolved := _HCW_Resolve(Entry, Sec)
    Defaults := _HCW_TomlDefaults(Entry, Sec)
    Override := _HCW_UserOverride(Entry, Sec)

    DelayMs := (Resolved.Delay != "") ? Round(Resolved.Delay * 1000) : 0
    DelayDefMs := (Defaults.Delay != "") ? Round(Defaults.Delay * 1000) : 0
    DelayOverridden := (Override.HasOwnProp("Delay") and Override.Delay != "")

    ; Set the Edit value without re-triggering the Change event. AHK's
    ; ``DDL.Value :=`` does fire Change; for Edit setting Text directly
    ; is silent.
    _HCWWidgets.DelayEdit.Value := DelayMs

    DefHint := t("hs_config.default_prefix") . DelayDefMs . " ms"
    if DelayOverridden {
        DefHint .= "    •  " . t("hs_config.override_active")
        _HCWWidgets.DelayReset.Enabled := true
    } else {
        _HCWWidgets.DelayReset.Enabled := false
    }
    _HCWWidgets.DelayDefault.Value := DefHint

    ; Color dropdown — find the preset whose hex matches; otherwise inject
    ; the current hex on top so the user always sees what is selected.
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
    _HCWWidgets.ColorSwatch.Opt("Background" . _HCW_HexNoHash(ColorHex))

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
    _HCWWidgets.Status.Value := t("hs_config.category_prefix") . Entry.Key . "    " . t("hs_config.section_prefix") . (Sec ? Sec : t("hs_config.file_level_short"))
}


; ============================================================
; ============================================================
; ======= 3/ Mutations ======================================
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
        ; "— hérite du défaut —" — same effect as the reset button.
        _HCW_ClearOverride(Entry, Sec, "color")
    } else {
        _HCW_SetOverride(Entry, Sec, "color", Hex)
    }
    _HCW_LoadCurrent()
}

_HCW_ClearField(Field) {
    Entry := _HCW_SelectedEntry()
    Sec := _HCW_SelectedSection(Entry)
    _HCW_ClearOverride(Entry, Sec, Field)
    _HCW_LoadCurrent()
}

_HCW_ResetAll() {
    global _HCW_CATEGORY_LIST
    for _, E in _HCW_CATEGORY_LIST {
        if E.IsPersonal {
            _HCW_PatchTomlMeta(E.Path, "", "delay", "")
            _HCW_PatchTomlMeta(E.Path, "", "color", "")
            for _, Sec in _HCW_GetSections(E) {
                _HCW_PatchTomlMeta(E.Path, Sec.Name, "delay", "")
                _HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
            }
        } else {
            HotstringsClearOverride(E.Key, "", "")
            for _, Sec in _HCW_GetSections(E) {
                HotstringsClearOverride(E.Key, Sec.Name, "")
            }
        }
    }
    _HCW_LoadCurrent()
}

; Force every category to the neutral grey while clearing per-section colour
; overrides so the cascade stays consistent. Delays are intentionally left
; alone — the user might still want differentiated timings.
_HCW_SetAllGrey() {
    global _HCW_CATEGORY_LIST
    Grey := "#6e6e73"
    for _, E in _HCW_CATEGORY_LIST {
        if E.IsPersonal {
            _HCW_PatchTomlMeta(E.Path, "", "color", Grey)
            for _, Sec in _HCW_GetSections(E) {
                _HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
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


; ============================================================
; ============================================================
; ======= 4/ Source-aware read/write dispatch ===============
; ============================================================
; ============================================================

; Dispatch a set-override to the right backend.
; For common categories: writes to hotstrings_config.toml via HotstringsSetOverride.
; For personal files:    patches [_meta] / [_meta.sections.*] in the TOML itself.
_HCW_SetOverride(Entry, Sec, Field, Value) {
    if Entry.IsPersonal {
        _HCW_PatchTomlMeta(Entry.Path, Sec, Field, Value)
    } else {
        HotstringsSetOverride(Entry.Key, Sec, Field, Value)
    }
}

; Dispatch a clear-override to the right backend.
_HCW_ClearOverride(Entry, Sec, Field) {
    if Entry.IsPersonal {
        _HCW_PatchTomlMeta(Entry.Path, Sec, Field, "")
    } else {
        HotstringsClearOverride(Entry.Key, Sec, Field)
    }
}

; Dispatch a resolve call to get the effective delay + color.
; For personal files the override IS the [_meta] value, so we read directly.
_HCW_Resolve(Entry, Sec) {
    if Entry.IsPersonal {
        return _HCW_ReadTomlMeta(Entry.Path, Sec)
    }
    return HotstringsResolve(Entry.Key, Sec)
}

; Read the effective delay + color from [_meta] / [_meta.sections.*] in a
; personal TOML file, applying the cascade: section → file → empty.
_HCW_ReadTomlMeta(Path, Sec) {
    FileCfg := ParseTomlGroupConfig("__personal__", Path)
    Result := { Delay: FileCfg.Delay, Color: FileCfg.Color }
    if (Sec != "" and FileCfg.Sections.Has(StrLower(Sec))) {
        SecCfg := FileCfg.Sections[StrLower(Sec)]
        if (SecCfg.Delay != "") {
            Result.Delay := SecCfg.Delay
        }
        if (SecCfg.Color != "") {
            Result.Color := SecCfg.Color
        }
    }
    return Result
}


; ============================================================
; ============================================================
; ======= 5/ Helpers ========================================
; ============================================================
; ============================================================

_HCW_CategoryItems() {
    global _HCW_CATEGORY_LIST
    Out := []
    for _, E in _HCW_CATEGORY_LIST {
        Out.Push(E.Label . "  —  " . E.Key)
    }
    return Out
}

; Returns the full entry object for the currently selected category dropdown index.
_HCW_SelectedEntry() {
    global _HCWWidgets, _HCW_CATEGORY_LIST
    Idx := _HCWWidgets.CatDD.Value
    if (Idx < 1 or Idx > _HCW_CATEGORY_LIST.Length) {
        return _HCW_CATEGORY_LIST[1]
    }
    return _HCW_CATEGORY_LIST[Idx]
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

; Extract the locale-appropriate string from a TOML inline table body like:
;   fr = "texte", en = "text", de = "Text", es = "Texto", zh = "文本"
; Falls back to "en" then "fr" when the current locale has no entry.
_HCW_LocaleFromInlineTable(body) {
    global _I18nLocale
    lang := (IsSet(_I18nLocale) && _I18nLocale != "") ? StrLower(_I18nLocale) : "en"
    ; Try current locale, then English, then French as fallbacks.
    for try_lang in [lang, "en", "fr"] {
        if RegExMatch(body, try_lang . '\s*=\s*"((?:[^"\\]|\\.)*)"', &M)
            return UnescapeTomlString(M[1])
    }
    ; Last resort: return first quoted value found.
    if RegExMatch(body, '"((?:[^"\\]|\\.)*)"', &M)
        return UnescapeTomlString(M[1])
    return Trim(body)
}


; Lightweight TOML scan — re-parses the [_meta] / [[section]] headers to list
; the sections and their descriptions. Accepts a category entry object.
_HCW_GetSections(Entry) {
    global ScriptInformation
    if Entry.IsPersonal {
        Path := Entry.Path
    } else {
        Cat := Entry.Key
        if (StrLower(Cat) == "personal"
                and IsSet(ScriptInformation)
                and ScriptInformation.Has("PersonalTomlPath")) {
            Path := ScriptInformation["PersonalTomlPath"]
        } else {
            Path := A_ScriptDir . "\..\..\hotstrings\" . StrLower(Cat) . ".toml"
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
            ; Support both plain string and locale inline-table:
            ;   key = "text"
            ;   key = { fr = "texte", en = "text", de = "Text", … }
            if RegExMatch(Line, "^([A-Za-z0-9_\-]+)\s*=\s*\{([^}]+)\}\s*$", &DM) {
                Descs[StrLower(DM[1])] := _HCW_LocaleFromInlineTable(DM[2])
            } else if RegExMatch(Line, "^([A-Za-z0-9_\-]+)\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &DM) {
                Descs[StrLower(DM[1])] := UnescapeTomlString(DM[2])
            }
        } else if (InMetaSecBlock != "") {
            if RegExMatch(Line, "^description\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &DM) {
                Descs[InMetaSecBlock] := UnescapeTomlString(DM[1])
            }
        }
    }

    ; Prefer the [_meta] sections_order list when present; fall back to the
    ; raw [[section]] declaration order.
    Order := []
    if (SectionsOrderRaw != "") {
        Pos := 1
        while (RegExMatch(SectionsOrderRaw, "`"([^`"]*)`"", &Tok, Pos)) {
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

_HCW_TomlDefaults(Entry, Section) {
    if Entry.IsPersonal {
        Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
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
    Out := { Delay: "", Color: "" }
    if Entry.IsPersonal {
        ; For personal files the stored value IS the override (no separate
        ; overrides file). Re-read [_meta] to find what is actually stored.
        ; Compare against the raw file-level value: if non-empty it was set.
        Cfg := ParseTomlGroupConfig("__personal__", Entry.Path)
        if (Section == "") {
            Out.Delay := Cfg.Delay
            Out.Color := Cfg.Color
        } else {
            Sec := StrLower(Section)
            if Cfg.Sections.Has(Sec) {
                S := Cfg.Sections[Sec]
                Out.Delay := S.Delay
                Out.Color := S.Color
            }
        }
        return Out
    }
    Cat := StrLower(Entry.Key)
    if !_HotstringsOverrides.Has(Cat) {
        return Out
    }
    Override := _HotstringsOverrides[Cat]
    if (Section == "") {
        Out.Delay := Override.Delay
        Out.Color := Override.Color
    } else {
        Sec := StrLower(Section)
        if Override.Sections.Has(Sec) {
            S := Override.Sections[Sec]
            Out.Delay := S.Delay
            Out.Color := S.Color
        }
    }
    return Out
}


; ============================================================
; ============================================================
; ======= 6/ Personal TOML [_meta] patcher =================
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

    ; Determine which header we target.
    ; Section == "" → [_meta]; Section != "" → [_meta.sections.<sec>]
    TargetHeader := (Sec == "") ? "[_meta]" : "[_meta.sections." . Sec . "]"

    InTarget  := false
    Found     := false
    FieldDone := false
    Out       := []

    for _, RawLine in Lines {
        Line := Trim(RawLine, " `t`r")

        ; Detect header lines
        if RegExMatch(Line, "^\[") {
            ; Leaving the target zone — if the field was not yet written, write it now
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
            ; Check if this line is the field we want to write / remove
            if RegExMatch(Line, "^" . Field . "\s*=", &_) {
                ; Remove the line; if we are setting a value, replace it
                if Value != "" and !FieldDone {
                    Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
                    FieldDone := true
                }
                ; else: drop the line (clear)
                continue
            }
        }

        Out.Push(RawLine)
    }

    ; Handle end-of-file while still in the target zone
    if InTarget and !FieldDone and Value != "" {
        Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
    }

    ; If the header was never found and we need to add a value, append it
    if !Found and Value != "" {
        Out.Push("")
        Out.Push(TargetHeader)
        Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
    }

    ; Invalidate the ParseTomlGroupConfig cache for this path so the next
    ; resolve call picks up the freshly written values.
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
; delay → bare number (seconds as float); color → quoted string.
_HCW_TomlValue(Field, Value) {
    if (Field == "delay") {
        ; Write with one decimal place to avoid integer literals like "2"
        ; which ParseTomlGroupConfig already handles, but being explicit
        ; makes the TOML more readable.
        Num := Value + 0
        return Format("{:.3f}", Num)
    }
    ; color (or any other string field) — emit as a quoted TOML string
    Escaped := StrReplace(Value, "\", "\\")
    Escaped := StrReplace(Escaped, '"', '\"')
    return '"' . Escaped . '"'
}


; ============================================================
; ======= 5.1) Color dropdown helpers =======================
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
; Stores the resulting option list in _HCW_CurrentColorOptions so the change
; handler can map a selected index back to a hex value.
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
