; drivers/autohotkey/lib/toml_loader.ahk

; ==============================================================================
; MODULE: TOML Loader
; DESCRIPTION:
; Lightweight TOML reader used by ErgoptiPlus to load hotstring payloads and
; feature metadata from ``..\hotstrings\*.toml`` files, making the TOML the
; single source of truth for hotstrings, menu titles and submenu ordering.
;
; FEATURES & RATIONALE:
; 1. UnescapeTomlString: mirrors the Python generator that writes trigger /
;    output fields with ``\\``, ``\"``, ``\n``, ``\t``, ``\r`` escapes.
; 2. LoadHotstringsSection: replays every ``[[section]]`` entry through the
;    exact same ``CreateHotstring`` / ``CreateCaseSensitiveHotstrings`` calls
;    that were used before the TOML migration, preserving behavior 1:1.
; 3. ApplyTomlMetadataToFeatures: maps ``[_meta]`` / ``[_meta.sections]`` onto
;    the runtime ``Features`` Map so menu titles and submenu ordering are driven
;    by TOML files, with ``★`` substituted for the user's configured MagicKey.
; 4. FoldAsciiLower: accent-folding helper that reconciles PascalCase Features
;    keys containing French letters (e.g. ``IÉ``) with the lowercase TOML keys
;    (e.g. ``ie``) used in ``sections_order`` and ``[_meta.sections]``.
; ==============================================================================

; Holds the raw UTF-8 content of every TOML file that has been read this
; session, keyed by absolute file path. Both LoadHotstringsSection and
; ApplyTomlMetadataToFeatures resolve content through ReadTomlFile so that
; large category files (autocorrection.toml, magickey.toml) are read at most
; once even when many sections are loaded from the same file.
global _TomlFileCache := Map()

; Per-category hotstring group configuration (default delay + tooltip color),
; populated lazily by ParseTomlGroupConfig and consumed by the tooltip and
; per-group delay gating layers. Keyed by lowercase category name. Shape:
;   {
;       Delay:    Number | "",   ; file-level default delay in seconds
;       Color:    String | "",   ; file-level tooltip color (hex e.g. "#e53935")
;       Sections: Map(name -> { Delay, Color, Description })
;   }
global HotstringGroupConfig := Map()

; Pre-compiled regex for a full TOML hotstring entry line. Defined once at
; module level so AHK does not recompile this ~100-char pattern for every line
; scanned by LoadHotstringsSection (thousands of iterations at boot).
global _HOTSTRING_ENTRY_PATTERN :=
	'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?\s*\}'


; ========================================================
; ========================================================
; ======= 1/ TOML string and metadata load helpers =======
; ========================================================
; ========================================================

; Return the cached content of a TOML file, reading it from disk on first access.
ReadTomlFile(FilePath) {
    global _TomlFileCache
    if _TomlFileCache.Has(FilePath) {
        return _TomlFileCache[FilePath]
    }
    Content := FileRead(FilePath, "UTF-8")
    _TomlFileCache[FilePath] := Content
    return Content
}

; Unescape a TOML double-quoted string literal (\\, \", \n, \t, \r).
; The generator at static/drivers/hotstrings/0_generate_hotstrings.py writes
; trigger/output with these escapes, so we mirror the inverse transform here.
UnescapeTomlString(s) {
    Result := ""
    i := 1
    n := StrLen(s)
    while i <= n {
        c := SubStr(s, i, 1)
        if (c == "\" and i < n) {
            NextChar := SubStr(s, i + 1, 1)
            if (NextChar == "\") {
                Result .= "\"
            } else if (NextChar == "`"") {
                Result .= "`""
            } else if (NextChar == "n") {
                Result .= "`n"
            } else if (NextChar == "t") {
                Result .= "`t"
            } else if (NextChar == "r") {
                Result .= "`r"
            } else {
                Result .= NextChar
            }
            i += 2
        } else {
            Result .= c
            i += 1
        }
    }
    return Result
}

; Register every hotstring of a given [[section]] defined inside a TOML file
; located under ..\hotstrings\<CategoryName>.toml (relative to the script).
; Hotstrings flagged as commented-out in TOML (line starting with "#") are
; skipped, mirroring AHK source lines starting with ";". The loader reproduces
; the exact behavior of CreateHotstring / CreateCaseSensitiveHotstrings: the
; Python generator writes `is_case_sensitive = not case_sensitive`, so the
; mapping back is:
;   TOML is_case_sensitive = true  ➜ original call was CreateHotstring
;   TOML is_case_sensitive = false ➜ original call was CreateCaseSensitiveHotstrings
LoadHotstringsSection(CategoryName, SectionName, FeatureConfig, ExtraOptions := Map()) {
    global ScriptInformation, _GENERATED_HOTSTRINGS

    ; Per-group delay gating — override the per-feature TimeActivationSeconds
    ; with the value resolved from the TOML metadata + user override file.
    ; This makes the gating identical across drivers without having to keep
    ; a separate config table per feature. The same FeatureConfig field is
    ; consumed by both the regex fallback below and the generated fast path.
    try {
        Resolved := HotstringsResolve(CategoryName, SectionName)
        if (Resolved.Delay != "") {
            FeatureConfig.TimeActivationSeconds := Resolved.Delay
        }
    }

    ; Fast path — bundled categories were pre-compiled to literal AHK calls by
    ; ``tools/compile_hotstrings.py``. The generated loader registers the
    ; hotstrings directly without touching the TOML file or regex parser.
    ; ``personal`` is deliberately excluded: it can live outside the repo.
    LoaderKey := StrLower(CategoryName) . "." . StrLower(SectionName)
    if (IsSet(_GENERATED_HOTSTRINGS)
            and StrLower(CategoryName) != "personal"
            and _GENERATED_HOTSTRINGS.Has(LoaderKey)) {
        try LoggerTrace("TomlLoader", "Using generated loader for [{1}.{2}].",
            CategoryName, SectionName)
        GeneratedFn := _GENERATED_HOTSTRINGS[LoaderKey]
        GeneratedFn(FeatureConfig, ExtraOptions)
        return
    }

    ; For the personal category, honour the user-configured path so the file can
    ; live outside the Ergopti repository (e.g. in a private config folder).
    if (StrLower(CategoryName) == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        FilePath := ScriptInformation["PersonalTomlPath"]
    } else {
        FilePath := A_ScriptDir . "\..\hotstrings\" . CategoryName . ".toml"
    }
    if !FileExist(FilePath) {
        try LoggerWarn("TomlLoader", "Section [{1}.{2}]: file {3} not found.",
            CategoryName, SectionName, FilePath)
        return
    }
    try LoggerTrace("TomlLoader", "Loading section [{1}.{2}]…", CategoryName, SectionName)
    Loaded := 0

    TimeActivationSeconds := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds :
        0
    TargetSection := StrLower(SectionName)
    CurrentSection := ""

    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        if RegExMatch(Line, "^\[\[(.+)\]\]$", &SectionMatch) {
            CurrentSection := StrLower(SectionMatch[1])
            continue
        }

        ; Any other [xxx] header terminates the current section context
        if (SubStr(Line, 1, 1) == "[") {
            CurrentSection := ""
            continue
        }

        if (CurrentSection != TargetSection) {
            continue
        }

        if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match) {
            continue
        }

        Trigger := UnescapeTomlString(Match[1])
        Output := UnescapeTomlString(Match[2])
        ; The TOML stores the magic key as the literal ``★`` character because
        ; that is the default; at runtime the user may have re-bound it via the
        ; tray menu, so translate it back to the current ``ScriptInformation``
        ; value before registering the hotstring.
        Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
        IsWord := (Match[3] == "true")
        AutoExpand := (Match[4] == "true")
        IsCaseSens := (Match[5] == "true")
        FinalResult := (Match[6] == "true")
        ; RegExMatch leaves unmatched optional groups as an empty string in
        ; AHK v2, so compare against "true" — that correctly yields False when
        ; the field is absent from the TOML entry (the generator default).
        StrictCase := (Match[7] == "true")

        Flags := ""
        if AutoExpand {
            Flags .= "*"
        }
        if !IsWord {
            Flags .= "?"
        }
        ; Re-apply the original AHK ``C`` flag when the generator recorded a
        ; strict case-sensitive match. Without this, a trigger like ``OUi``
        ; would be matched case-insensitively at runtime and typing ``oui``
        ; would erroneously fire the replacement.
        if StrictCase {
            Flags .= "C"
        }

        Options := Map(
            "TimeActivationSeconds", TimeActivationSeconds,
            "FinalResult", FinalResult,
        )
        if ExtraOptions.Has("OnlyText") {
            Options["OnlyText"] := ExtraOptions["OnlyText"]
        }

        ; Counter-intuitive mapping — see header comment lines 87-90.
        ; The Python generator writes ``is_case_sensitive = not case_sensitive``
        ; so ``true`` here means we want the case-INSENSITIVE single-variant
        ; ``CreateHotstring``, while ``false`` means we want all uppercase /
        ; titlecase variants generated by ``CreateCaseSensitiveHotstrings``.
        if IsCaseSens {
            CreateHotstring(Flags, Trigger, Output, Options)
        } else {
            CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
        }
        Loaded += 1
    }
    try LoggerDone("TomlLoader", "Section [{1}.{2}]: {3} entry(ies) loaded.",
        CategoryName, SectionName, Loaded)
}

; Fold common French accented characters to their ASCII equivalent, then
; lowercase. Used to match the lowercase-only TOML metadata keys (e.g.
; ``ie``) against the PascalCase Features Map keys that may contain
; accents (e.g. ``IÉ`` in SFBsReduction).
FoldAsciiLower(Str) {
    Result := StrLower(Str)
    Result := StrReplace(Result, "à", "a")
    Result := StrReplace(Result, "â", "a")
    Result := StrReplace(Result, "ä", "a")
    Result := StrReplace(Result, "é", "e")
    Result := StrReplace(Result, "è", "e")
    Result := StrReplace(Result, "ê", "e")
    Result := StrReplace(Result, "ë", "e")
    Result := StrReplace(Result, "î", "i")
    Result := StrReplace(Result, "ï", "i")
    Result := StrReplace(Result, "ô", "o")
    Result := StrReplace(Result, "ö", "o")
    Result := StrReplace(Result, "ù", "u")
    Result := StrReplace(Result, "û", "u")
    Result := StrReplace(Result, "ü", "u")
    Result := StrReplace(Result, "ç", "c")
    return Result
}

; Apply ``[_meta]`` metadata — section ordering and section descriptions —
; from the category's TOML file onto the live Features Map, making the
; TOML the single source of truth for menu titles and submenu ordering.
; TOML keys are lowercase (and accent-stripped for French letters like
; ``IÉ`` -> ``ie``) so they are resolved back to the actual Features key
; by comparing their ``FoldAsciiLower`` form. The ``★`` placeholder in the
; TOML is swapped for the user's configured ``ScriptInformation["MagicKey"]``
; so that rebindings done via the tray menu are reflected in descriptions.
; Bootstrap Features["Personal"] from the [_meta.sections] block of
; personal_hotstrings.toml. Creates one feature entry per declared section,
; enabled by default. Subsequent ApplyTomlMetadataToFeatures("Personal") will
; then enrich those entries with descriptions and __Order from the same TOML.
; Returns the list of section keys (lowercase) that were registered.
BootstrapPersonalFeatures() {
    global Features, ScriptInformation
    Result := []
    if !(IsSet(ScriptInformation) and ScriptInformation.Has("PersonalTomlPath")) {
        return Result
    }
    FilePath := ScriptInformation["PersonalTomlPath"]
    if !FileExist(FilePath) {
        try LoggerInfo("TomlLoader", "Personal hotstrings file not found at '{1}' — skipping.",
            FilePath)
        return Result
    }

    if !Features.Has("Personal") {
        Features["Personal"] := Map()
    }

    InMetaSections := false
    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, "^\[([^\[\]]+)\]$", &HeaderMatch) {
            InMetaSections := (Trim(HeaderMatch[1]) == "_meta.sections")
            continue
        }
        if (SubStr(Line, 1, 2) == "[[") {
            break
        }
        if !InMetaSections {
            continue
        }
        if RegExMatch(Line, "^([A-Za-z0-9_]+)\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &SecMatch) {
            SectionKey := SecMatch[1]
            ; Use PascalCase for the Feature key (menu convention) but keep
            ; the lowercase TOML key for the loader call.
            FeatKey := StrUpper(SubStr(SectionKey, 1, 1)) . SubStr(SectionKey, 2)
            if !Features["Personal"].Has(FeatKey) {
                Features["Personal"][FeatKey] := { Enabled: true,
                    Description: UnescapeTomlString(SecMatch[2]),
                    TomlSection: StrLower(SectionKey) }
            }
            Result.Push(StrLower(SectionKey))
            try LoggerDebug("TomlLoader", "Personal section registered: '{1}'.", FeatKey)
        }
    }
    return Result
}

ApplyTomlMetadataToFeatures(CategoryName) {
    global ScriptInformation
    if (StrLower(CategoryName) == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        FilePath := ScriptInformation["PersonalTomlPath"]
    } else {
        FilePath := A_ScriptDir . "\..\hotstrings\" . StrLower(CategoryName) . ".toml"
    }
    if !FileExist(FilePath) {
        return
    }
    if !Features.Has(CategoryName) {
        return
    }

    ; Build a reverse lookup ``folded lowercase -> actual PascalCase key``
    ; from the existing Features Map, skipping the ``__Order`` sentinel.
    KeyByFolded := Map()
    for Key, Val in Features[CategoryName] {
        if Key == "__Order" {
            continue
        }
        KeyByFolded[FoldAsciiLower(Key)] := Key
    }

    InMeta := false
    InMetaSections := false
    SectionsOrderRaw := ""

    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        if RegExMatch(Line, "^\[([^\[\]]+)\]$", &HeaderMatch) {
            Header := Trim(HeaderMatch[1])
            InMeta := (Header == "_meta")
            InMetaSections := (Header == "_meta.sections")
            continue
        }

        ; Any ``[[…]]`` header closes the metadata zones and the reader can
        ; stop scanning, the rest of the file is pure hotstring payload.
        if (SubStr(Line, 1, 2) == "[[") {
            break
        }

        ; Inside ``[_meta]`` — extract the ``sections_order`` raw body.
        if (InMeta and SectionsOrderRaw == "") {
            if RegExMatch(Line, "^sections_order\s*=\s*\[(.*)\]\s*$", &OrderMatch) {
                SectionsOrderRaw := OrderMatch[1]
            }
            continue
        }

        ; Inside ``[_meta.sections]`` — ``key = "description"`` pairs.
        if InMetaSections {
            if RegExMatch(Line, "^([A-Za-z0-9_]+)\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &DescMatch) {
                LowerKey := StrLower(DescMatch[1])
                DescRaw := UnescapeTomlString(DescMatch[2])
                DescRaw := StrReplace(DescRaw, "★", ScriptInformation["MagicKey"])
                if KeyByFolded.Has(LowerKey) {
                    ActualKey := KeyByFolded[LowerKey]
                    FeatureObj := Features[CategoryName][ActualKey]
                    ; Menu titles are only read from plain object entries —
                    ; nested sub-maps have their own Description fields per
                    ; sub-feature and are outside the scope of this loader.
                    if IsObject(FeatureObj) and !(Type(FeatureObj) == "Map") {
                        FeatureObj.Description := DescRaw
                    }
                }
            }
        }
    }

    ; Rebuild ``__Order`` in the Features Map from the TOML sections_order,
    ; preserving the ``-`` separators and translating lowercase TOML keys
    ; back to the PascalCase keys used by the menu code. Entries with no
    ; matching Features key are skipped silently so that a TOML mention of
    ; an unimplemented feature cannot break menu creation.
    if SectionsOrderRaw != "" {
        NewOrder := []
        Pos := 1
        SectionsOrderRawLen := StrLen(SectionsOrderRaw)
        while (Pos <= SectionsOrderRawLen and RegExMatch(SectionsOrderRaw, "`"([^`"]*)`"", &TokenMatch, Pos)) {
            Token := StrLower(TokenMatch[1])
            if Token == "-" {
                NewOrder.Push("-")
            } else if KeyByFolded.Has(Token) {
                NewOrder.Push(KeyByFolded[Token])
            }
            Pos := TokenMatch.Pos + TokenMatch.Len
        }
        if NewOrder.Length > 0 {
            Features[CategoryName]["__Order"] := NewOrder
        }
    }
}

; Parse the ``[_meta]`` and ``[_meta.sections.<name>]`` blocks of a category
; TOML to extract the file-level and per-section default delay (seconds) and
; tooltip color (hex). The result is cached in ``HotstringGroupConfig`` keyed
; by lowercase category name so subsequent calls are free.
;
; Recognised keys:
;   [_meta]                       delay = <number>     color = "<hex>"
;   [_meta.sections.<name>]       delay = <number>     color = "<hex>"
;                                 description = "<...>"
;
; The legacy flat ``[_meta.sections]`` form (``key = "description"`` only) is
; left untouched here — ApplyTomlMetadataToFeatures already consumes it.
ParseTomlGroupConfig(CategoryName) {
    global ScriptInformation, HotstringGroupConfig
    LowerCat := StrLower(CategoryName)
    if HotstringGroupConfig.Has(LowerCat) {
        return HotstringGroupConfig[LowerCat]
    }

    if (LowerCat == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        FilePath := ScriptInformation["PersonalTomlPath"]
    } else {
        FilePath := A_ScriptDir . "\..\hotstrings\" . LowerCat . ".toml"
    }

    Config := { Delay: "", Color: "", Sections: Map() }
    if !FileExist(FilePath) {
        HotstringGroupConfig[LowerCat] := Config
        return Config
    }

    Mode := ""              ; "" | "meta" | "meta_section"
    CurrentSec := ""

    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        ; Stop scanning as soon as the first hotstring payload section starts —
        ; everything below is per-entry data, not metadata.
        if (SubStr(Line, 1, 2) == "[[") {
            break
        }

        if RegExMatch(Line, "^\[_meta\.sections\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
            Mode := "meta_section"
            CurrentSec := StrLower(SecMatch[1])
            if !Config.Sections.Has(CurrentSec) {
                Config.Sections[CurrentSec] := { Delay: "", Color: "", Description: "" }
            }
            continue
        }
        if (Line == "[_meta]") {
            Mode := "meta"
            continue
        }
        if RegExMatch(Line, "^\[([^\[\]]+)\]$", &HeaderMatch) {
            ; Any other [...] header (including [_meta.sections]) ends our scope.
            Mode := ""
            CurrentSec := ""
            continue
        }

        if (Mode == "meta") {
            if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
                Config.Delay := NumMatch[1] + 0
            } else if RegExMatch(Line, "^color\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &ColMatch) {
                Config.Color := UnescapeTomlString(ColMatch[1])
            }
        } else if (Mode == "meta_section" and CurrentSec != "") {
            Sec := Config.Sections[CurrentSec]
            if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
                Sec.Delay := NumMatch[1] + 0
            } else if RegExMatch(Line, "^color\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &ColMatch) {
                Sec.Color := UnescapeTomlString(ColMatch[1])
            } else if RegExMatch(Line, "^description\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &DescMatch) {
                Sec.Description := UnescapeTomlString(DescMatch[1])
            }
        }
    }

    HotstringGroupConfig[LowerCat] := Config
    return Config
}

; Count hotstring entries inside a specific [[section]] of a TOML category file.
; Returns 0 when the file or section does not exist.
; Uses the same ReadTomlFile cache to avoid redundant disk reads.
CountTomlSection(CategoryName, SectionName) {
    global ScriptInformation
    if (StrLower(CategoryName) == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        FilePath := ScriptInformation["PersonalTomlPath"]
    } else {
        FilePath := A_ScriptDir . "\..\hotstrings\" . StrLower(CategoryName) . ".toml"
    }
    if !FileExist(FilePath) {
        return 0
    }
    Count := 0
    Q := Chr(34)
    TargetSection := StrLower(SectionName)
    CurrentSection := ""
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, "^\[\[(.+)\]\]$", &SectionMatch) {
            CurrentSection := StrLower(SectionMatch[1])
            continue
        }
        if (SubStr(Line, 1, 1) == "[") {
            CurrentSection := ""
            continue
        }
        if (CurrentSection == TargetSection and SubStr(Line, 1, 1) == Q and InStr(Line, "output")) {
            Count++
        }
    }
    return Count
}

; Count all hotstring entries across every [[section]] in a TOML category file.
; Returns 0 when the file does not exist or contains no matching entries.
; Uses the same ReadTomlFile cache as the rest of the loader to avoid double I/O.
CountTomlHotstrings(CategoryName) {
    global ScriptInformation
    if (StrLower(CategoryName) == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        FilePath := ScriptInformation["PersonalTomlPath"]
    } else {
        FilePath := A_ScriptDir . "\..\hotstrings\" . StrLower(CategoryName) . ".toml"
    }
    if !FileExist(FilePath) {
        return 0
    }
    ; Count lines that look like a hotstring entry: start with a quoted trigger
    Count := 0
    Q := Chr(34)
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (SubStr(Line, 1, 1) == Q and InStr(Line, "output")) {
            Count++
        }
    }
    return Count
}




; ==========================================
; ==========================================
; ======= User config.toml overrides =======
; ==========================================
; ==========================================

; Coerce a raw TOML literal into the appropriate AHK type:
;   - "true" / "false"      → boolean (1 / 0, matching Features.Enabled style)
;   - bare integer / float  → number
;   - "..." quoted string   → unescaped string
;   - anything else         → raw literal as-is
TomlCoerceValue(Raw) {
    Trimmed := Trim(Raw, " `t")
    Lower := StrLower(Trimmed)
    if (Lower == "true") {
        return 1
    }
    if (Lower == "false") {
        return 0
    }
    if RegExMatch(Trimmed, "^-?\d+$") {
        return Integer(Trimmed)
    }
    if RegExMatch(Trimmed, "^-?\d+\.\d+$") {
        return Float(Trimmed)
    }
    Q := Chr(34)
    if (StrLen(Trimmed) >= 2 and SubStr(Trimmed, 1, 1) == Q
            and SubStr(Trimmed, StrLen(Trimmed), 1) == Q) {
        return UnescapeTomlString(SubStr(Trimmed, 2, StrLen(Trimmed) - 2))
    }
    return Trimmed
}

; Apply user-editable overrides from <config_dir>/config.toml on top of the
; INI-driven configuration. The TOML acts as an "expert" override layer:
;   [script]
;   LogLevel = "DEBUG"
;   MagicKey = "★"
;
;   [features]
;   "MagicKey.Repeat.Enabled" = false
;   "Personal.Code.Enabled"   = false
;
; The keys under [features] use dotted paths matching the Features Map layout.
; Missing file is silently ignored — TOML overrides are optional.
; Returns the number of overrides applied (mostly for diagnostics).
ApplyConfigTomlOverrides(FilePath) {
    global Features, ScriptInformation
    Applied := 0
    if !FileExist(FilePath) {
        try LoggerDebug("TomlLoader", "config.toml not found at '{1}' — skipping overrides.",
            FilePath)
        return Applied
    }
    try LoggerStart("TomlLoader", "Applying user overrides from '{1}'…", FilePath)

    CurrentSection := ""
    Q := Chr(34)
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, "^\[([^\[\]]+)\]$", &SecMatch) {
            CurrentSection := StrLower(Trim(SecMatch[1]))
            continue
        }
        ; Two key forms are accepted:
        ;   key = value
        ;   "dotted.path" = value
        ; Try quoted key first, then bare identifier key
        if RegExMatch(Line, "^`"([^`"\\]+)`"\s*=\s*(.+)$", &Match) {
            Key := Match[1]
            Value := TomlCoerceValue(Match[2])
        } else if RegExMatch(Line, "^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", &Match) {
            Key := Match[1]
            Value := TomlCoerceValue(Match[2])
        } else {
            continue
        }

        if (CurrentSection == "script") {
            if ScriptInformation.Has(Key) {
                ScriptInformation[Key] := Value
                Applied++
                try LoggerDebug("TomlLoader", "Override [script].{1} = {2}.", Key, Value)
            }
        } else if (CurrentSection == "features") {
            ; Walk the dotted path in Features and set Enabled (or the named
            ; property at the leaf if the key is e.g. "MagicKey.MagicKeyChar").
            Parts := StrSplit(Key, ".")
            Node := Features
            Failed := false
            Idx := 1
            while (Idx < Parts.Length) {
                Step := Parts[Idx]
                if (Type(Node) == "Map") {
                    if !Node.Has(Step) {
                        Failed := true
                        break
                    }
                    Node := Node[Step]
                } else if (IsObject(Node) and Node.HasOwnProp(Step)) {
                    Node := Node.%Step%
                } else {
                    Failed := true
                    break
                }
                Idx++
            }
            if Failed {
                try LoggerWarn("TomlLoader", "Override skipped — path not found: '{1}'.", Key)
                continue
            }
            Leaf := Parts[Parts.Length]
            try {
                if (Type(Node) == "Map" and Node.Has(Leaf)) {
                    Node[Leaf] := Value
                } else {
                    Node.%Leaf% := Value
                }
                Applied++
                try LoggerDebug("TomlLoader", "Override [features].{1} = {2}.", Key, Value)
            } catch as e {
                try LoggerWarn("TomlLoader", "Override failed for '{1}': {2}.", Key, e.Message)
            }
        }
    }
    try LoggerSuccess("TomlLoader", "User overrides applied ({1} value(s)).", Applied)
    return Applied
}
