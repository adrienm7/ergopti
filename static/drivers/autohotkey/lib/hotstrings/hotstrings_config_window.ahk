; drivers/autohotkey/lib/hotstrings_config_window.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window
; DESCRIPTION:
; Native Gui v2 editor for the per-group expansion delay and tooltip color of
; every hotstring category and section. The data layer lives in
; lib\hotstrings_config.ahk; this module only renders / dispatches mutations.
;
; FEATURES & RATIONALE:
; 1. Compact selector form — a (category, section) pair drives the two
;    edit rows, mirroring HS's webview without the rendering overhead of a
;    full tree control. The user picks what they want to tune; the form
;    reads / writes that single (category, section) at a time.
; 2. "Niveau fichier" virtual section — picking it lets the user edit the
;    file-level [_meta] defaults without dropping into a leaf section.
; 3. Singleton window — calling OpenHotstringsConfigWindow twice brings the
;    existing window forward instead of stacking duplicates.
; 4. Quick presets — "Tout en gris" overrides every file-level colour and
;    clears section-level overrides so the grey cascade is uniform; "Tout
;    réinitialiser" wipes the override file entirely.
; ==============================================================================

global _HCWGui      := 0
global _HCWWidgets  := 0
global _HCW_CATEGORY_ORDER := [
    "magickey", "autocorrection", "rolls",
    "sfbsreduction", "distancesreduction", "personal"
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
        "personal",           t("hs_config.cat_personal"),
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


; ============================================================
; ============================================================
; ======= 1/ Public entry point =============================
; ============================================================
; ============================================================

OpenHotstringsConfigWindow() {
    global _HCWGui, _HCWWidgets
    _HCW_InitLocaleStrings()
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
    global _HCWWidgets, _HCW_CATEGORY_ORDER, _HCW_FILE_LEVEL_LABEL
    Cat := _HCW_SelectedCategory()
    Items := [_HCW_FILE_LEVEL_LABEL]
    Sections := _HCW_GetSections(Cat)
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
    Cat := _HCW_SelectedCategory()
    Sec := _HCW_SelectedSection()
    Resolved := HotstringsResolve(Cat, Sec)
    Defaults := _HCW_TomlDefaults(Cat, Sec)
    Override := _HCW_UserOverride(Cat, Sec)

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
    _HCWWidgets.Status.Value := t("hs_config.category_prefix") . Cat . "    " . t("hs_config.section_prefix") . (Sec ? Sec : t("hs_config.file_level_short"))
}


; ============================================================
; ============================================================
; ======= 3/ Mutations ======================================
; ============================================================
; ============================================================

_HCW_OnDelayChanged() {
    global _HCWWidgets
    Cat := _HCW_SelectedCategory()
    Sec := _HCW_SelectedSection()
    Ms := _HCWWidgets.DelayEdit.Value + 0
    if (Ms < 0) {
        Ms := 0
    }
    HotstringsSetOverride(Cat, Sec, "delay", Ms / 1000)
    _HCW_LoadCurrent()
}

_HCW_OnColorChanged() {
    global _HCWWidgets, _HCW_CurrentColorOptions
    Cat := _HCW_SelectedCategory()
    Sec := _HCW_SelectedSection()
    Idx := _HCWWidgets.ColorDD.Value
    if (Idx < 1) {
        return
    }
    Hex := _HCW_CurrentColorOptions[Idx].Hex
    if (Hex == "") {
        ; "— hérite du défaut —" — same effect as the reset button.
        HotstringsClearOverride(Cat, Sec, "color")
    } else {
        HotstringsSetOverride(Cat, Sec, "color", Hex)
    }
    _HCW_LoadCurrent()
}

_HCW_ClearField(Field) {
    Cat := _HCW_SelectedCategory()
    Sec := _HCW_SelectedSection()
    HotstringsClearOverride(Cat, Sec, Field)
    _HCW_LoadCurrent()
}

_HCW_ResetAll() {
    global _HCW_CATEGORY_ORDER
    for _, Cat in _HCW_CATEGORY_ORDER {
        HotstringsClearOverride(Cat, "", "")
        for _, Sec in _HCW_GetSections(Cat) {
            HotstringsClearOverride(Cat, Sec.Name, "")
        }
    }
    _HCW_LoadCurrent()
}

; Force every category to the neutral grey while clearing per-section colour
; overrides so the cascade stays consistent. Delays are intentionally left
; alone — the user might still want differentiated timings.
_HCW_SetAllGrey() {
    global _HCW_CATEGORY_ORDER
    Grey := "#6e6e73"
    for _, Cat in _HCW_CATEGORY_ORDER {
        HotstringsSetOverride(Cat, "", "color", Grey)
        for _, Sec in _HCW_GetSections(Cat) {
            HotstringsClearOverride(Cat, Sec.Name, "color")
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
; ======= 4/ Helpers ========================================
; ============================================================
; ============================================================

_HCW_CategoryItems() {
    global _HCW_CATEGORY_ORDER, _HCW_CATEGORY_LABELS
    Out := []
    for _, Cat in _HCW_CATEGORY_ORDER {
        Out.Push(_HCW_CATEGORY_LABELS[Cat] . "  —  " . Cat)
    }
    return Out
}

_HCW_SelectedCategory() {
    global _HCWWidgets, _HCW_CATEGORY_ORDER
    Idx := _HCWWidgets.CatDD.Value
    if (Idx < 1 or Idx > _HCW_CATEGORY_ORDER.Length) {
        return _HCW_CATEGORY_ORDER[1]
    }
    return _HCW_CATEGORY_ORDER[Idx]
}

_HCW_SelectedSection() {
    global _HCWWidgets
    Idx := _HCWWidgets.SecDD.Value
    if (Idx <= 1) {
        return ""
    }
    Sections := _HCW_GetSections(_HCW_SelectedCategory())
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
; the sections and their descriptions. We could share with toml_loader but
; the scope here is small enough that duplicating is cheaper than coupling.
_HCW_GetSections(Category) {
    global ScriptInformation
    if (StrLower(Category) == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        Path := ScriptInformation["PersonalTomlPath"]
    } else {
        Path := A_ScriptDir . "\..\..\hotstrings\" . StrLower(Category) . ".toml"
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

_HCW_TomlDefaults(Category, Section) {
    Cfg := ParseTomlGroupConfig(Category)
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

_HCW_UserOverride(Category, Section) {
    global _HotstringsOverrides
    Out := { Delay: "", Color: "" }
    Cat := StrLower(Category)
    if !_HotstringsOverrides.Has(Cat) {
        return Out
    }
    Entry := _HotstringsOverrides[Cat]
    if (Section == "") {
        Out.Delay := Entry.Delay
        Out.Color := Entry.Color
    } else {
        Sec := StrLower(Section)
        if Entry.Sections.Has(Sec) {
            S := Entry.Sections[Sec]
            Out.Delay := S.Delay
            Out.Color := S.Color
        }
    }
    return Out
}


; ============================================================
; ======= 4.1) Color dropdown helpers =======================
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
