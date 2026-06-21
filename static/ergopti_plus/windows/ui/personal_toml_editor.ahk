; ui/personal_toml_editor.ahk

; ==============================================================================
; MODULE: Personal TOML Editor
; DESCRIPTION:
; Full-featured GUI for managing hotstrings stored in personal_hotstrings.toml.
; Mirrors the Hammerspoon hotstring editor feature set: section navigation,
; per-entry flags (is_word, auto_expand, is_case_sensitive, final_result),
; multiline output with {Token} alias support, inline editing, section
; creation/rename/delete, and persistent UI preferences.
;
; FEATURES & RATIONALE:
; 1. ReadPersonalToml: parses the full TOML structure (sections, entries, meta)
;    and returns a structured Map so the GUI can navigate by section.
; 2. WritePersonalToml: serialises the full structure back to disk, preserving
;    the [_meta] / [_meta.sections] / [[section]] format expected by the loader.
; 3. NormaliseOutput: mirrors HS normalise_output — converts bare line-breaks to
;    {Enter} and canonicalises {alias} tokens ({left} → {Left}, etc.).
; 4. OpenPersonalEditor: singleton GUI with section tabs, entry list,
;    add/edit/delete form, flag checkboxes, and preference persistence.
; 5. Section management: create, rename, and delete sections from the GUI.
; 6. Preference persistence: default section and close-on-add are stored in
;    the ini so they survive script reloads.
; ==============================================================================





; ==========================================================
; ==============================
; ======= 1/ Path helper =======
; ==============================
; ==========================================================

; Return the configured path to personal_hotstrings.toml.
PersonalTomlPath() {
    global ScriptInformation
    if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalTomlPath") {
        return ScriptInformation["PersonalTomlPath"]
    }
    return A_ScriptDir . "\..\hotstrings\personal_hotstrings.toml"
}

; Return the configured path to personal_info.toml.
PersonalInfoTomlPath() {
    global ScriptInformation
    if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalInfoTomlPath") {
        return ScriptInformation["PersonalInfoTomlPath"]
    }
    return A_ScriptDir . "\..\hotstrings\personal_info.toml"
}





; ==========================================================
; ==========================================
; ======= 2/ TOML read / write layer =======
; ==========================================
; ==========================================================

; Escape a raw string for a TOML double-quoted value field.
; Escape a value for inclusion inside a TOML double-quoted string. Newlines
; and tabs are normalised to {Enter} and {Tab} tokens (rather than the TOML
; escape sequences \n / \t) so that the saved file uses a single canonical
; representation matching what NormaliseOutput emits and what the runtime
; Send treats as a key press. This guarantees the on-disk format never
; mixes raw \n with {Enter} for the same kind of payload.
EscapeTomlValue(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r`n", "{Enter}")
    s := StrReplace(s, "`r", "{Enter}")
    s := StrReplace(s, "`n", "{Enter}")
    s := StrReplace(s, "`t", "{Tab}")
    return s
}

; Mirrors HS normalise_output: bare CRLF/LF become {Enter}, bare tabs become
; {Tab}, and {alias} tokens are canonicalised to their proper AHK {Token}
; form. Keeping newline/tab handling here as well as in EscapeTomlValue means
; outputs read from any source (textarea, legacy TOML, paste) end up with the
; same tokenised representation before serialisation.
NormaliseOutput(s) {
    s := StrReplace(s, "`r`n", "{Enter}")
    s := StrReplace(s, "`r", "{Enter}")
    s := StrReplace(s, "`n", "{Enter}")
    s := StrReplace(s, "`t", "{Tab}")

    Aliases := Map(
        "esc", "Escape", "escape", "Escape",
        "bs", "BackSpace", "backspace", "BackSpace",
        "del", "Delete", "delete", "Delete",
        "return", "Enter", "enter", "Enter",
        "left", "Left", "right", "Right",
        "up", "Up", "down", "Down",
        "home", "Home", "end", "End",
        "tab", "Tab", "pgup", "PgUp",
        "pgdn", "PgDn", "ins", "Insert",
        "insert", "Insert", "space", "Space",
    )

    Result := ""
    i := 1
    n := StrLen(s)
    while i <= n {
        c := SubStr(s, i, 1)
        if (c == "{") {
            ; Find closing brace
            j := InStr(s, "}", , i + 1)
            if j {
                Inner := SubStr(s, i + 1, j - i - 1)
                Lower := StrLower(Inner)
                if Aliases.Has(Lower) {
                    Result .= "{" . Aliases[Lower] . "}"
                } else {
                    ; Capitalise first letter for unknown tokens
                    Result .= "{" . StrUpper(SubStr(Inner, 1, 1)) . SubStr(Inner, 2) . "}"
                }
                i := j + 1
                continue
            }
        }
        Result .= c
        i++
    }
    return Result
}

global _ReadPersonalTomlCache := false

; Parse personal_hotstrings.toml into a structured object:
;   .sections_order  — Array of section names in meta order (or file order if no meta)
;   .sections        — Map(name → {description, entries[]})
;   .meta_description — string
ReadPersonalToml() {
    global _ReadPersonalTomlCache
    if (_ReadPersonalTomlCache != false)
        return _ReadPersonalTomlCache

    FilePath := PersonalTomlPath()
    Result := Map(
        "sections_order", [],
        "sections", Map(),
        "meta_description", t("editor.hotstrings.meta_desc"),
    )
    if !FileExist(FilePath) {
        _ReadPersonalTomlCache := Result
        return Result
    }

    Q := Chr(34)
    EntryPattern :=
        'i)^' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
        . '\s*=\s*\{\s*output\s*=\s*' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
        . '\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)'
        . '\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)'
        . '(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?'
        . '(?:\s*,\s*priority\s*=\s*([0-9]+))?\s*\}'

    ; Normalise to LF so every line ends cleanly — eliminates CRLF anchor bugs
    FileContent := StrReplace(FileRead(FilePath, "UTF-8"), "`r`n", "`n")
    FileContent := StrReplace(FileContent, "`r", "`n")

    ; ── Extract sections_order directly from raw content ──
    MetaOrder := []
    MetaDescriptions := Map()

    if RegExMatch(FileContent, "m)^sections_order\s*=\s*\[([^\]]+)\]", &OM) {
        for Token in StrSplit(OM[1], ",") {
            Token := Trim(Token, " `t`n" . Q)
            if (Token != "") {
                MetaOrder.Push(StrLower(Token))
            }
        }
    }

    if RegExMatch(FileContent, "m)^description\s*=\s*" . Q . "([^" . Q . "]*)" . Q, &DM) {
        Result["meta_description"] := DM[1]
    }

    ; ── Extract [_meta.sections] descriptions via multiline scan ──
    ; Locate the [_meta.sections] block and read until next [ header
    if RegExMatch(FileContent, "m)^\[_meta\.sections\]\n((?:(?!\[).+\n?)*)", &MS) {
        DescBlock := MS[1]
        Pos := 1
        KPat := "m)^([A-Za-z0-9_]+)\s*=\s*" . Q . "((?:[^" . Q . "\\]|\\.)*)" . Q
        while RegExMatch(DescBlock, KPat, &KM, Pos) {
            MetaDescriptions[StrLower(KM[1])] := UnescapeTomlString(KM[2])
            Pos := KM.Pos + KM.Len
        }
    }

    ; ── Single pass: collect [[section]] entries ──
    CurrentSection := ""
    LineIndex := 0
    FileSectionOrder := []

    loop parse, FileContent, "`n" {
        LineIndex++
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        ; [[section]] header
        if (SubStr(Line, 1, 2) == "[[" and SubStr(Line, -1) == "]") {
            CurrentSection := StrLower(SubStr(Line, 3, StrLen(Line) - 4))
            if !Result["sections"].Has(CurrentSection) {
                FileSectionOrder.Push(CurrentSection)
                Result["sections"][CurrentSection] := Map(
                    "description", MetaDescriptions.Has(CurrentSection)
                        ? MetaDescriptions[CurrentSection]
                        : CurrentSection,
                    "entries", [],
                    "line_start", LineIndex,
                )
            }
            continue
        }
        ; [simple] header — reset section context
        if (SubStr(Line, 1, 1) == "[") {
            CurrentSection := ""
            continue
        }
        if (CurrentSection == "") {
            continue
        }
        if !RegExMatch(Line, EntryPattern, &EM) {
            continue
        }
        Entry := Map(
            "trigger", UnescapeTomlString(EM[1]),
            "output", UnescapeTomlString(EM[2]),
            "is_word", (EM[3] == "true"),
            "auto_expand", (EM[4] == "true"),
            "is_case_sensitive", (EM[5] == "true"),
            "final_result", (EM[6] == "true"),
            "strict_case", (EM[7] == "true"),
            ; Empty string means "inherit the source default" (no per-entry key)
            "priority", (EM[8] != "" ? EM[8] + 0 : ""),
            "line_index", LineIndex,
        )
        Result["sections"][CurrentSection]["entries"].Push(Entry)
    }

    ; ── Build final sections_order: meta order first, then unlisted sections ──
    Seen := Map()
    for _, SecName in MetaOrder {
        if Result["sections"].Has(SecName) {
            Result["sections_order"].Push(SecName)
            Seen[SecName] := true
        }
    }
    for _, SecName in FileSectionOrder {
        if !Seen.Has(SecName) {
            Result["sections_order"].Push(SecName)
            Seen[SecName] := true
        }
    }
    _ReadPersonalTomlCache := Result
    return Result
}

; Serialise the full TOML structure back to disk.
; Writes [_meta], [_meta.sections], then all [[section]] blocks.
WritePersonalToml(Data) {
    global _ReadPersonalTomlCache, _HS_GrandTotalCache
    _ReadPersonalTomlCache := false ; Invalidate
    _HS_GrandTotalCache := -1
    FilePath := PersonalTomlPath()
    Q := Chr(34)
    ; ... rest of function ...
    Lines := []

    MetaDesc := Data.Has("meta_description") ? Data["meta_description"] : t("editor.hotstrings.meta_desc")
    Lines.Push("[_meta]")
    Lines.Push("description = " . Q . EscapeTomlValue(MetaDesc) . Q)

    ; Build sections_order as a TOML inline array
    OrderParts := []
    for SecName in Data["sections_order"] {
        OrderParts.Push(Q . EscapeTomlValue(SecName) . Q)
    }
    Lines.Push("sections_order = [" . ArrayJoin(OrderParts, ", ") . "]")

    Lines.Push("[_meta.sections]")
    for SecName in Data["sections_order"] {
        if Data["sections"].Has(SecName) {
            Desc := Data["sections"][SecName]["description"]
            Lines.Push(EscapeTomlValue(SecName) . " = " . Q . EscapeTomlValue(Desc) . Q)
        }
    }

    for SecName in Data["sections_order"] {
        if !Data["sections"].Has(SecName) {
            continue
        }
        Sec := Data["sections"][SecName]
        Lines.Push("[[" . SecName . "]]")
        for E in Sec["entries"] {
            IsWord := E["is_word"] ? "true" : "false"
            AutoExp := E["auto_expand"] ? "true" : "false"
            IsCaseSens := E["is_case_sensitive"] ? "true" : "false"
            Final := E["final_result"] ? "true" : "false"
            Line := Q . EscapeTomlValue(E["trigger"]) . Q
            . " = { output = " . Q . EscapeTomlValue(E["output"]) . Q
            . ", is_word = " . IsWord
            . ", auto_expand = " . AutoExp
            . ", is_case_sensitive = " . IsCaseSens
            . ", final_result = " . Final
            if E.Has("strict_case") and E["strict_case"] {
                Line .= ", is_case_sensitive_strict = true"
            }
            ; Individual collision-priority override — written only when set so
            ; entries that inherit the source default stay free of the key
            if E.Has("priority") and E["priority"] != "" {
                Line .= ", priority = " . E["priority"]
            }
            Line .= " }"
            Lines.Push(Line)
        }
    }

    Content := ""
    for i, L in Lines {
        Content .= L . "`r`n"
    }

    FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
    if !FileObj {
        return False
    }
    FileObj.Write(Content)
    FileObj.Close()

    return True
}

global _ReadPersonalInfoTomlCache := false

; Read personal_info.toml and populate the global PersonalInformation Map.
; Format:
;   [info]
;   FirstName = "Adrien"
;   …
;   [letters]
;   a = "StreetAddress"
;   …
; Missing file is silently skipped (defaults remain).
ReadPersonalInfoToml(FilePath) {
    global PersonalInformation, _ReadPersonalInfoTomlCache
    if (_ReadPersonalInfoTomlCache != false) {
        PersonalInformation := _ReadPersonalInfoTomlCache.Clone()
        return
    }

    if !FileExist(FilePath) {
        return
    }

    Q := Chr(34)
    FileContent := StrReplace(FileRead(FilePath, "UTF-8"), "`r`n", "`n")
    FileContent := StrReplace(FileContent, "`r", "`n")
    CurrentSection := ""

    loop parse, FileContent, "`n" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        ; Section header
        if RegExMatch(Line, "^\[([a-z_]+)\]$", &HM) {
            CurrentSection := HM[1]
            continue
        }
        ; Key = "value" pair
        if (CurrentSection == "info") and RegExMatch(Line, 'i)^(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
            Key := KM[1]
            Val := UnescapeTomlString(KM[2])
            if PersonalInformation.Has(Key) {
                PersonalInformation[Key] := Val
            }
        }
    }
    _ReadPersonalInfoTomlCache := PersonalInformation.Clone()
}

; Serialise PersonalInformation and PersonalInformationLetters to personal_info.toml.
WritePersonalInfoToml(FilePath) {
    global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
    _ReadPersonalInfoTomlCache := false ; Invalidate
    Q := Chr(34)
    Lines := []

    Lines.Push("[info]")
    for Key, Val in PersonalInformation {
        Lines.Push(Key . " = " . Q . EscapeTomlValue(Val) . Q)
    }

    Lines.Push("[letters]")
    for Letter, Key in PersonalInformationLetters {
        Lines.Push(Letter . " = " . Q . EscapeTomlValue(Key) . Q)
    }

    Content := ""
    for L in Lines {
        Content .= L . "`r`n"
    }

    FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
    if !FileObj {
        return False
    }
    FileObj.Write(Content)
    FileObj.Close()

    return True
}

; Make sure personal_info.toml exists at FilePath, materialising the in-memory
; defaults from PersonalInformation / PersonalInformationLetters when it does
; not. Called at script load so that renaming or deleting the file simply
; triggers a fresh re-creation on the next launch — same UX guarantee as
; EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk.
EnsurePersonalInfoTomlFile(FilePath) {
    if FileExist(FilePath) {
        return
    }
    try {
        Dir := RegExReplace(FilePath, "\\[^\\]+$", "")
        if (Dir != "" and !DirExist(Dir)) {
            DirCreate(Dir)
        }
        if WritePersonalInfoToml(FilePath) {
            try LoggerInfo("ErgoptiPlus", "Personal info file created from defaults at '{1}'.", FilePath)
        } else {
            try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}'.", FilePath)
        }
    } catch as e {
        try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}': {2}.",
            FilePath, e.Message)
    }
}

; Helper: join an Array of strings with a separator.
ArrayJoin(Arr, Sep) {
    Out := ""
    for i, v in Arr {
        Out .= (i > 1 ? Sep : "") . v
    }
    return Out
}

; Re-register all hotstrings in a given section from the current TOML data.
; Called after save so new/edited entries are immediately active.
ReloadPersonalSection(Data, SectionName, FeatureConfig) {
    if !Data["sections"].Has(SectionName) {
        return
    }
    for E in Data["sections"][SectionName]["entries"] {
        Trigger := StrReplace(E["trigger"], "★", ScriptInformation["MagicKey"])
        Output := E["output"]
        Flags := ""
        if E["auto_expand"] {
            Flags .= "*"
        }
        if !E["is_word"] {
            Flags .= "?"
        }
        if E.Has("strict_case") and E["strict_case"] {
            Flags .= "C"
        }
        ; Collision priority: the individual per-hotstring override when set,
        ; otherwise the personal source default (50). Passing Category + Priority
        ; mirrors the boot loader so a live editor reload registers personal
        ; hotstrings at the same tier they get at startup — without this they
        ; silently fell back to CreateHotstring's common default (10).
        EntryPriority := (E.Has("priority") and E["priority"] != "")
            ? E["priority"]
            : _HSE_SourcePriority("personal")
        Options := Map(
            "TimeActivationSeconds", 0,
            "FinalResult", E["final_result"],
            "Category", "personal",
            "Priority", EntryPriority,
        )
        if E["is_case_sensitive"] {
            CreateHotstring(Flags, Trigger, Output, Options)
        } else {
            CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
        }
    }
}





; ==========================================================
; =========================================
; ======= 3/ Preference persistence =======
; =========================================
; ==========================================================

; Keys under [ahk.personal_editor] in the v2 config TOML.
_EditorPrefGet(Key, Default) {
    global ConfigurationFile
    if !IsSet(ConfigurationFile) or !FileExist(ConfigurationFile) {
        return Default
    }
    Val := TOML_Read(ConfigurationFile, "ahk.personal_editor", Key, "_MISSING_")
    return (Val == "_MISSING_") ? Default : Val
}
_EditorPrefSet(Key, Value) {
    global ConfigurationFile
    if IsSet(ConfigurationFile) {
        TOML_Write(Value, ConfigurationFile, "ahk.personal_editor", Key)
    }
}





; ==========================================================
; ======================
; ======= 4/ GUI =======
; ======================
; ==========================================================

global _PersonalEditorGui := ""
global _PersonalEditorData := ""   ; last loaded TOML data (Map)
global _PersonalEditorSection := "" ; currently selected section name
; Priority Edit control. Held as a module global rather than threaded through the
; eight form helpers (which already pass the sibling checkboxes) because adding a
; ninth control to every signature and call site is far more error-prone than one
; reference read by _BuildEntry / _FillFormFromSelection / _ClearForm.
global _PersonalEditorPrioCtrl := ""

; Set an Edit control's grey cue-banner (placeholder) text. Shown while the field
; is empty; wParam 1 keeps it visible even when the control has focus.
_SetEditCueBanner(Ctrl, Text) {
    static EM_SETCUEBANNER := 0x1501
    CueStr := "" . Text
    try SendMessage(EM_SETCUEBANNER, 1, StrPtr(CueStr), Ctrl)
}

; Personal source-default priority read from the shared single source
; (_shared/modules/hotstrings/priority.json) so the editor never hardcodes it. Falls back
; to the engine constant — which the parity gate keeps identical to that file —
; if the shared file cannot be read.
_GetSharedPersonalDefault() {
    global _SharedDir
    try {
        if IsSet(_SharedDir) {
            Path := _SharedDir . "\modules\hotstrings\priority.json"
            if FileExist(Path) {
                Data := JsonParse(FileRead(Path, "UTF-8"))
                if (Data is Map and Data.Has("personal")) {
                    return Data["personal"]
                }
            }
        }
    }
    return _HSE_SourcePriority("personal")
}

; Open the editor, optionally jumping to a specific section.
; DefaultSection — if set, the editor pre-selects that section.
OpenPersonalEditor(DefaultSection := "") {
    global _PersonalEditorGui, _PersonalEditorData, _PersonalEditorSection

    ; Bring existing window to front
    if IsObject(_PersonalEditorGui) {
        try {
            _PersonalEditorGui.Show()
            ; If a section was requested, switch to it
            if (DefaultSection != "") {
                _SwitchEditorSection(DefaultSection)
            }
            return
        }
    }

    _PersonalEditorData := ReadPersonalToml()

    ; Resolve the section to open
    TargetSection := DefaultSection
    if (TargetSection == "") {
        TargetSection := _EditorPrefGet("DefaultSection", "")
    }
    if (TargetSection == "" and _PersonalEditorData["sections_order"].Length > 0) {
        TargetSection := _PersonalEditorData["sections_order"][1]
    }
    _PersonalEditorSection := TargetSection

    W := Gui_Create("+Resize +MinSize700x610", t("editor.hotstrings.window_title"))
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 10

    ; ── Top bar: section selector + section management buttons ──
    W.Add("Text", "xm y12 w70 h24 +0x200", t("editor.hotstrings.label_section"))
    SectionDrop := W.Add("DropDownList", "x+6 yp w360", _BuildSectionList(_PersonalEditorData))
    BtnNewSec    := W.Add("Button", "x+8 yp w110 h24", t("editor.hotstrings.btn_new"))
    BtnRenameSec := W.Add("Button", "x+4 yp w110 h24", t("editor.hotstrings.btn_rename"))
    BtnDelSec    := W.Add("Button", "x+4 yp w110 h24", t("editor.hotstrings.btn_delete"))

    _SelectDropDown(SectionDrop, _PersonalEditorSection)

    ; ── Entry list ──
    LV := W.Add("ListView",
        "xm y+10 w860 r12 -Multi +LV0x10000",
        [t("editor.hotstrings.col_trigger"), t("editor.hotstrings.col_result"), t("editor.hotstrings.col_word"), t("editor.hotstrings.col_auto"), t("editor.hotstrings.col_case"), t("editor.hotstrings.col_final"), t("editor.hotstrings.col_priority")])
    LV.ModifyCol(1, 160)
    LV.ModifyCol(2, 445)
    LV.ModifyCol(3, 45)
    LV.ModifyCol(4, 45)
    LV.ModifyCol(5, 50)
    LV.ModifyCol(6, 45)
    LV.ModifyCol(7, 45)

    _PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)

    ; ── Separator ──
    W.Add("Text", "xm y+8 w860 h1 +0x10")   ; horizontal rule

    ; ── Form layout ──
    ; Left col : Déclencheur (h22) then Résultat (h62), total left height ≈ 22+6+22+62 = 112
    ; Right col: 4 checkboxes h≈20 each with 4px gap = 4*20+3*4 = 92px
    ; Add left col first, then place flags with yp pointing back to TriggerEdit top.
    ; OutputEdit h=62, flags block h=92 → flags start at TriggerEdit top = OutputEdit top - 28.
    ; In AHK v2 yp after OutputEdit = OutputEdit top, so flags at yp-28 = TriggerEdit top.

    W.Add("Text", "xm y+10 w90 h22 +0x200", t("editor.hotstrings.label_trigger"))
    TriggerEdit := W.Add("Edit", "x108 yp w520 h22")
    W.Add("Text", "xm y+6  w90 h22 +0x200", t("editor.hotstrings.label_result"))
    OutputEdit := W.Add("Edit", "x108 yp w520 h62 +Multi +WantReturn")

    ; Flags — placed to the right of TriggerEdit, anchored at TriggerEdit top via yp
    TriggerEdit.GetPos(, &TrigY)
    ChkIsWord := W.Add("CheckBox", "x644 y" . TrigY . " w180", t("editor.hotstrings.chk_word"))
    ChkAutoExp := W.Add("CheckBox", "x644 y+11 w180", "Auto-expand")
    ChkCaseSens := W.Add("CheckBox", "x644 y+11 w180", t("editor.hotstrings.chk_case"))
    ChkFinal := W.Add("CheckBox", "x644 y+11 w180", t("editor.hotstrings.chk_final"))
    ChkAutoExp.Value := 1

    ; ── Per-hotstring collision priority — own full-width row below the form ──
    ; Empty Edit means "inherit the personal source default" (no key written); a
    ; number 0-100 overrides it (higher wins). The UpDown gives 0-100 spin arrows;
    ; the default shown as a cue banner is read from the engine (the single source
    ; kept in sync with priority.json), never hardcoded here. The row sits below
    ; both the output box and the checkbox stack so it can never overlap them.
    OutputEdit.GetPos(, &OutY, , &OutH)
    ChkFinal.GetPos(, &ChkFinalY, , &ChkFinalH)
    PrioRowY := Max(OutY + OutH, ChkFinalY + ChkFinalH) + 12
    W.Add("Text", "xm y" . PrioRowY . " w90 h22 +0x200", t("editor.hotstrings.priority_label"))
    PrioEdit := W.Add("Edit", "x108 y" . PrioRowY . " w64 h22 +Number +Limit3")
    W.Add("UpDown", "Range0-100")
    W.Add("Text", "x190 y" . (PrioRowY + 3) . " w480 h22 cGray", t("editor.hotstrings.priority_hint"))
    ; The UpDown seeds the buddy Edit with its low bound — clear it so the field
    ; starts blank (= inherit) and the cue banner shows the inherited default.
    PrioEdit.Value := ""
    _SetEditCueBanner(PrioEdit, _GetSharedPersonalDefault())
    global _PersonalEditorPrioCtrl := PrioEdit

    ; ── Add button + checkbox aligned, before the separator ──
    PrioEdit.GetPos(, &PrioY, , &PrioH)
    BtnAdd := W.Add("Button", "xm y" . (PrioY + PrioH + 12) . " w110 h26", t("editor.hotstrings.btn_add"))
    CloseOnAddChk := W.Add("CheckBox", "x+10 yp+5 w120", t("editor.hotstrings.chk_close_after"))
    CloseOnAddChk.Value := (_EditorPrefGet("CloseOnAdd", "0") == "1") ? 1 : 0

    ; Token help — to the right of the Add button, vertically centered
    BtnAdd.GetPos(, &BtnAddY, , &BtnAddH)
    TokenHelp := W.Add("Text", "x" . (W.MarginX + 260) . " y" . (BtnAddY + 6) . " w590 h26 cGray",
    "{Enter}  {Tab}  {Left}  {Right}  {Up}  {Down}  {BackSpace}  {Delete}  {Escape}  {Home}  {End}")

    ; ── Separator ──
    BtnAdd.GetPos(, , , &BtnAddH2)
    SepCtrl := W.Add("Text", "xm y" . (BtnAddY + BtnAddH2 + 8) . " w860 h1 +0x10")
    SepCtrl.GetPos(, &SepY, , &SepH)
    RowY := SepY + SepH + 8

    GB2 := W.Add("GroupBox", "xm y" . RowY . " w240 h54", t("editor.hotstrings.group_selected"))
    GB2.GetPos(&GB2X, &GB2Y)
    BtnSave := W.Add("Button", "x" . (GB2X + 10) . " y" . (GB2Y + 22) . " w106 h26", t("editor.hotstrings.btn_edit"))
    BtnDel := W.Add("Button", "x" . (GB2X + 122) . " y" . (GB2Y + 22) . " w106 h26", t("editor.hotstrings.btn_delete_entry"))

    ; ── Status bar ──
    StatusText := W.Add("Text", "xm y+10 w860 h20 cGray", "")

    ; ── Wiring ──
    ; Section management — wired here (not inline at creation) so LV and all
    ; form controls are already declared and in scope at the time of the call.
    BtnNewSec.OnEvent("Click", (*) => _NewSection(W, SectionDrop, LV,
        TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))
    BtnRenameSec.OnEvent("Click", (*) => _RenameSection(W, SectionDrop))
    BtnDelSec.OnEvent("Click", (*) => _DeleteSection(W, SectionDrop, LV,
        TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))

    BtnAdd.OnEvent("Click", (*) => _AddEntry(W, LV, TriggerEdit, OutputEdit,
        ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, CloseOnAddChk, StatusText))
    BtnSave.OnEvent("Click", (*) => _SaveEntry(W, LV, TriggerEdit, OutputEdit,
        ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))
    BtnDel.OnEvent("Click", (*) => _DeleteEntry(W, LV, StatusText))

    LV.OnEvent("ItemSelect", (*) => _FillFormFromSelection(LV, TriggerEdit, OutputEdit,
        ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal))

    SectionDrop.OnEvent("Change", (*) => _OnSectionChange(SectionDrop, LV,
        TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))

    CloseOnAddChk.OnEvent("Click", (*) => _EditorPrefSet("CloseOnAdd",
        CloseOnAddChk.Value ? "1" : "0"))

    W.OnEvent("Close", (*) => _OnEditorClose())
    W.OnEvent("Size", (*) => _ResizeEditor(W, LV, OutputEdit, StatusText))

    _PersonalEditorGui := W
    W.Show("Center w900 h690")
}

; ─────────────────────────────────────────────────────
; Internal helpers
; ─────────────────────────────────────────────────────

; Returns display labels for all sections. Kept separate from key names so the
; DDL index always matches sections_order index 1:1.
_BuildSectionList(Data) {
    List := []
    for _, SecName in Data["sections_order"] {
        Desc := Data["sections"].Has(SecName) ? Data["sections"][SecName]["description"] : SecName
        List.Push(Desc)
    }
    if List.Length == 0 {
        List.Push(t("editor.hotstrings.no_section"))
    }
    return List
}

; Rebuild a DropDownList from scratch.
_RebuildDropdown(DDL, Data) {
    DDL.Delete()
    DDL.Add(_BuildSectionList(Data))
}

; Select the DDL entry whose index matches SectionName in sections_order.
_SelectDropDown(DDL, SectionName) {
    global _PersonalEditorData
    if (SectionName == "") {
        DDL.Choose(1)
        return
    }
    for i, SecName in _PersonalEditorData["sections_order"] {
        if (StrLower(Trim(SecName)) == StrLower(Trim(SectionName))) {
            DDL.Choose(i)
            return
        }
    }
    ; Fallback: select first item if name not found
    if _PersonalEditorData["sections_order"].Length > 0 {
        DDL.Choose(1)
    }
}

_CurrentSectionFromDrop(DDL) {
    global _PersonalEditorData
    Idx := DDL.Value
    if (Idx < 1 or Idx > _PersonalEditorData["sections_order"].Length) {
        return ""
    }
    return _PersonalEditorData["sections_order"][Idx]
}

_PopulateList(LV, Data, SectionName) {
    LV.Delete()
    if (SectionName == "" or !Data["sections"].Has(SectionName)) {
        return
    }
    for _, E in Data["sections"][SectionName]["entries"] {
        LV.Add("",
            E["trigger"],
            StrReplace(E["output"], "`n", "↵"),
            E["is_word"] ? "✓" : "",
            E["auto_expand"] ? "✓" : "",
            E["is_case_sensitive"] ? "✓" : "",
            E["final_result"] ? "✓" : "",
            (E.Has("priority") and E["priority"] != "") ? E["priority"] : "")
    }
}

_FillFormFromSelection(LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
    global _PersonalEditorData, _PersonalEditorSection
    Row := LV.GetNext(0)
    if !Row {
        return
    }
    if !_PersonalEditorData["sections"].Has(_PersonalEditorSection) {
        return
    }
    Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
    if Row > Entries.Length {
        return
    }
    E := Entries[Row]
    TriggerEdit.Value := E["trigger"]
    OutputEdit.Value := E["output"]
    ChkIsWord.Value := E["is_word"] ? 1 : 0
    ChkAutoExp.Value := E["auto_expand"] ? 1 : 0
    ChkCaseSens.Value := E["is_case_sensitive"] ? 1 : 0
    ChkFinal.Value := E["final_result"] ? 1 : 0
    global _PersonalEditorPrioCtrl
    if IsObject(_PersonalEditorPrioCtrl) {
        _PersonalEditorPrioCtrl.Value := (E.Has("priority") and E["priority"] != "") ? E["priority"] : ""
    }
}

_ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
    TriggerEdit.Value := ""
    OutputEdit.Value := ""
    ChkIsWord.Value := 0
    ChkAutoExp.Value := 1
    ChkCaseSens.Value := 0
    ChkFinal.Value := 0
    global _PersonalEditorPrioCtrl
    if IsObject(_PersonalEditorPrioCtrl) {
        _PersonalEditorPrioCtrl.Value := ""
    }
}

_BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
    global _PersonalEditorPrioCtrl
    TriggerVal := Trim(TriggerEdit.Value)
    O := NormaliseOutput(OutputEdit.Value)
    ; Read the optional priority override; an empty field means "inherit".
    ; Clamp to the accepted 0-100 collision-priority range.
    PrioVal := ""
    if IsObject(_PersonalEditorPrioCtrl) {
        Raw := Trim(_PersonalEditorPrioCtrl.Value)
        if (Raw != "") {
            PrioVal := Raw + 0
            if (PrioVal < 0) {
                PrioVal := 0
            } else if (PrioVal > 100) {
                PrioVal := 100
            }
        }
    }
    return Map(
        "trigger", TriggerVal,
        "output", O,
        "is_word", ChkIsWord.Value == 1,
        "auto_expand", ChkAutoExp.Value == 1,
        "is_case_sensitive", ChkCaseSens.Value == 1,
        "final_result", ChkFinal.Value == 1,
        "strict_case", false,
        "priority", PrioVal,
        "line_index", 0,
    )
}

_SaveData(W, LV, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    if !WritePersonalToml(_PersonalEditorData) {
        StatusText.Value := t("editor.hotstrings.err_write")
        return false
    }
    ; Read autocorrection TimeActivationSeconds from the v2 hotstrings.personal
    ; sub-Map — hydrated at boot from the [hotstrings.personal.autocorrection]
    ; section of the user's config.toml by ApplyConfigToml.
    FeatureConfig := { TimeActivationSeconds: 0 }
    if (IsSet(Features)
        and Features.Has("hotstrings")
        and Features["hotstrings"].Has("personal")
        and Features["hotstrings"]["personal"].Has("autocorrection")) {
        FeatureConfig := Features["hotstrings"]["personal"]["autocorrection"]
    }
    ReloadPersonalSection(_PersonalEditorData, _PersonalEditorSection, FeatureConfig)
    _PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
    StatusText.Value := t("editor.hotstrings.saved_prefix") . A_Now
    return true
}

_AddEntry(W, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, CloseOnAddChk, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    TriggerVal := Trim(TriggerEdit.Value)
    O := Trim(OutputEdit.Value)
    if (TriggerVal == "" or O == "") {
        StatusText.Value := t("editor.hotstrings.err_trigger_required")
        return
    }
    if (_PersonalEditorSection == "") {
        StatusText.Value := t("editor.hotstrings.err_no_section")
        return
    }
    ; Check for duplicate trigger in this section
    for E in _PersonalEditorData["sections"][_PersonalEditorSection]["entries"] {
        if (E["trigger"] == TriggerVal) {
            StatusText.Value := t("editor.hotstrings.err_duplicate")
            return
        }
    }
    Entry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
    _PersonalEditorData["sections"][_PersonalEditorSection]["entries"].Push(Entry)
    if _SaveData(W, LV, StatusText) {
        _ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
        if CloseOnAddChk.Value {
            W.Destroy()
        }
    }
}

_SaveEntry(W, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    Row := LV.GetNext(0)
    if !Row {
        StatusText.Value := t("editor.hotstrings.err_select_to_edit")
        return
    }
    TriggerVal := Trim(TriggerEdit.Value)
    O := Trim(OutputEdit.Value)
    if (TriggerVal == "" or O == "") {
        StatusText.Value := t("editor.hotstrings.err_trigger_required")
        return
    }
    Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
    if Row > Entries.Length {
        return
    }
    Entry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
    Entry["line_index"] := Entries[Row]["line_index"]
    Entries[Row] := Entry
    _SaveData(W, LV, StatusText)
}

_DeleteEntry(W, LV, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    Row := LV.GetNext(0)
    if !Row {
        StatusText.Value := t("editor.hotstrings.err_select_to_delete")
        return
    }
    Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
    if Row > Entries.Length {
        return
    }
    E := Entries[Row]
    Confirm := MsgBox(
        t("editor.hotstrings.btn_delete") . ' "' . E["trigger"] . '" → "' . E["output"] . '" ?',
        t("editor.hotstrings.title_confirm"), "YesNo Icon?"
    )
    if Confirm != "Yes" {
        return
    }
    Entries.RemoveAt(Row)
    _SaveData(W, LV, StatusText)
}

_OnSectionChange(SectionDrop, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
    global _PersonalEditorSection
    _PersonalEditorSection := _CurrentSectionFromDrop(SectionDrop)
    _EditorPrefSet("DefaultSection", _PersonalEditorSection)
    global _PersonalEditorData
    _PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
    _ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
    StatusText.Value := ""
}

_NewSection(W, SectionDrop, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    Res := InputBox(t("editor.hotstrings.new_section_prompt"), t("editor.hotstrings.new_section_title"), "w300 h120")
    if Res.Result != "OK" or Trim(Res.Value) == "" {
        return
    }
    SecName := StrLower(Trim(Res.Value))
    SecName := RegExReplace(SecName, "[^a-z0-9_]", "_")
    if _PersonalEditorData["sections"].Has(SecName) {
        MsgBox(t("editor.hotstrings.err_section_exists"), t("editor.hotstrings.title_error"), "Icon!")
        return
    }
    Res2 := InputBox(t("editor.hotstrings.desc_prompt"), t("editor.hotstrings.desc_title"), "w300 h120", SecName)
    if Res2.Result != "OK" {
        return
    }
    Desc := Trim(Res2.Value)
    if (Desc == "") {
        Desc := SecName
    }
    _PersonalEditorData["sections_order"].Push(SecName)
    _PersonalEditorData["sections"][SecName] := Map(
        "description", Desc,
        "entries", [],
        "line_start", 0,
    )
    ; Persist and rebuild dropdown
    WritePersonalToml(_PersonalEditorData)
    _RebuildDropdown(SectionDrop, _PersonalEditorData)
    _SelectDropDown(SectionDrop, SecName)
    _PersonalEditorSection := SecName
    _EditorPrefSet("DefaultSection", SecName)
    ; Refresh the list and form to reflect the (empty) new section —
    ; without this the ListView keeps showing the previous section's entries
    _PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
    _ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
    StatusText.Value := ""
}

_RenameSection(W, SectionDrop) {
    global _PersonalEditorData, _PersonalEditorSection
    if (_PersonalEditorSection == "") {
        MsgBox(t("editor.hotstrings.err_no_section_selected"), t("editor.hotstrings.title_error"), "Icon!")
        return
    }
    OldDesc := _PersonalEditorData["sections"].Has(_PersonalEditorSection)
        ? _PersonalEditorData["sections"][_PersonalEditorSection]["description"]
        : _PersonalEditorSection
    Res := InputBox(Format(t("editor.hotstrings.rename_desc_prompt"), _PersonalEditorSection), t("editor.hotstrings.rename_title"),
        "w300 h120", OldDesc)
    if Res.Result != "OK" or Trim(Res.Value) == "" {
        return
    }
    _PersonalEditorData["sections"][_PersonalEditorSection]["description"] := Trim(Res.Value)
    WritePersonalToml(_PersonalEditorData)
    _RebuildDropdown(SectionDrop, _PersonalEditorData)
    _SelectDropDown(SectionDrop, _PersonalEditorSection)
}

_DeleteSection(W, SectionDrop, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
    global _PersonalEditorData, _PersonalEditorSection
    if (_PersonalEditorSection == "") {
        MsgBox(t("editor.hotstrings.err_no_section_selected"), t("editor.hotstrings.title_error"), "Icon!")
        return
    }
    EntryCount := _PersonalEditorData["sections"].Has(_PersonalEditorSection)
        ? _PersonalEditorData["sections"][_PersonalEditorSection]["entries"].Length
        : 0
    Confirm := MsgBox(
        t("editor.hotstrings.btn_delete") . ' "' . _PersonalEditorSection . '" (' . EntryCount . ') ?',
        t("editor.hotstrings.title_confirm"), "YesNo Icon?"
    )
    if Confirm != "Yes" {
        return
    }
    ; Remove from order array
    NewOrder := []
    for SecName in _PersonalEditorData["sections_order"] {
        if (SecName != _PersonalEditorSection) {
            NewOrder.Push(SecName)
        }
    }
    _PersonalEditorData["sections_order"] := NewOrder
    _PersonalEditorData["sections"].Delete(_PersonalEditorSection)
    WritePersonalToml(_PersonalEditorData)
    _PersonalEditorSection := NewOrder.Length > 0 ? NewOrder[1] : ""
    _RebuildDropdown(SectionDrop, _PersonalEditorData)
    if (_PersonalEditorSection != "") {
        _SelectDropDown(SectionDrop, _PersonalEditorSection)
    }
    ; Refresh list and form to reflect the newly active section (or empty state)
    _PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
    _ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
    StatusText.Value := ""
}

; Switch the open editor to a different section (called when reopening with a target).
_SwitchEditorSection(SectionName) {
    global _PersonalEditorGui, _PersonalEditorData, _PersonalEditorSection
    if !IsObject(_PersonalEditorGui) {
        return
    }
    _PersonalEditorSection := SectionName
    ; The ListView and dropdown are stored as named controls — rebuild via a fresh open
    ; is the simplest approach for AHK (no handle cache needed).
    _PersonalEditorData := ReadPersonalToml()
    _PersonalEditorGui.Destroy()
    _PersonalEditorGui := ""
    OpenPersonalEditor(SectionName)
}

_OnEditorClose() {
    global _PersonalEditorGui, _PersonalEditorPrioCtrl
    _PersonalEditorGui := ""
    ; Drop the reference to the now-destroyed control so no form helper touches it
    _PersonalEditorPrioCtrl := ""
}

_ResizeEditor(W, LV, OutputEdit, StatusText) {
    W.GetClientPos(, , &CW, &CH)
    LV.Move(, , CW - 24,)
    StatusText.Move(, CH - 26, CW - 24,)
}
