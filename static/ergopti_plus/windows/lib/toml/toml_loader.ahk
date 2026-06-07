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
; 3. ParseTomlGroupConfig: reads ``[_meta]`` and ``[_meta.sections.*]`` blocks
;    for per-group delay, tooltip color and description.
; 4. FoldAsciiLower: accent-folding helper that reconciles identifiers
;    containing French letters (e.g. ``IÉ``) with lowercase TOML keys.
; ==============================================================================

; Holds the raw UTF-8 content of every TOML file that has been read this
; session, keyed by absolute file path. Large category files (autocorrection.toml,
; magickey.toml) are read at most once even when many sections are loaded.
global _TomlFileCache    := Map()
global _TomlCountCache   := Map()   ; key = CategoryName|SectionName → count

; Per-category hotstring group configuration (default delay + tooltip color),
; populated lazily by ParseTomlGroupConfig and consumed by the tooltip and
; per-group delay gating layers. Keyed by lowercase category name. Shape:
;   {
;       Delay:       Number | "",   ; file-level default delay in seconds
;       Color:       String | "",   ; file-level tooltip color (hex e.g. "#e53935")
;       ShowTooltip: true|"",       ; "" means unset (inherits default = true)
;       Sections:    Map(name -> { Delay, Color, ShowTooltip, Description })
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

; Evict all cache entries for a given file path so that the next call to
; ParseTomlGroupConfig or ReadTomlFile re-reads from disk. Called after
; _HCW_PatchTomlMeta writes changes to a personal TOML file.
_ParseTomlGroupConfig_InvalidatePath(FilePath) {
    global _TomlFileCache, HotstringGroupConfig
    if _TomlFileCache.Has(FilePath) {
        _TomlFileCache.Delete(FilePath)
    }
    if HotstringGroupConfig.Has(FilePath) {
        HotstringGroupConfig.Delete(FilePath)
    }
}

; Unescape a TOML double-quoted string literal (\\, \", \n, \t, \r).
; The generator at static/hotstrings/0_generate_hotstrings.py writes
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
    global ScriptInformation, _GENERATED_HOTSTRINGS, _StaticDir

    ; Accept either shape transparently — Phase 5/7 of the sliced v2
    ; cut-over migrated the if-gate reads to Features["hotstrings"]
    ; [<cat>][<entry>] (v2 Maps) but the LoadHotstringsSection / generated
    ; fast-path readers below were authored against the v1 object shape
    ; ({Enabled, TimeActivationSeconds, ...}). Convert a v2 Map to an
    ; equivalent v1-shape object right at the boundary so the rest of
    ; the function (and the codegen'd fast paths in
    ; lib/hotstrings/hotstrings_generated.ahk) keeps reading
    ; ``FeatureConfig.PropertyName`` without modification. The generator
    ; itself stays unchanged.
    if (IsObject(FeatureConfig) and Type(FeatureConfig) == "Map") {
        _V1Compat := { Enabled: false }
        if FeatureConfig.Has("enabled") {
            _V1Compat.Enabled := FeatureConfig["enabled"]
        }
        if FeatureConfig.Has("time_activation_seconds") {
            _V1Compat.TimeActivationSeconds := FeatureConfig["time_activation_seconds"]
        }
        if FeatureConfig.Has("pattern_max_length") {
            _V1Compat.PatternMaxLength := FeatureConfig["pattern_max_length"]
        }
        FeatureConfig := _V1Compat
    }

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
        FilePath := _SharedDir . "\hotstrings\" . CategoryName . ".toml"
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

        ; Match [[section]] or [section]
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SectionMatch) {
            CurrentSection := StrLower(Trim(SectionMatch[1]))
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
            "Category", CategoryName,
            "Section", SectionName,
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

; Load all hotstring entries from every [[section]] in an arbitrary TOML file.
; Used for personal extension packs dropped in the hotstrings\ folder.
; All sections are loaded unconditionally (no per-section enable/disable toggle).
LoadExtTomlFile(FilePath, CategoryLabel) {
    global ScriptInformation, _HOTSTRING_ENTRY_PATTERN
    if !FileExist(FilePath) {
        try LoggerWarn("TomlLoader", "Extension TOML '{1}' not found — skipped.", FilePath)
        return
    }
    try LoggerStart("TomlLoader", "Loading extension TOML '{1}'…", FilePath)
    TotalLoaded := 0
    CurrentSection := ""
    SplitPath FilePath, , , , &CategoryName
    FeatConf := { Enabled: true, TimeActivationSeconds: 0 }
    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        ; Match [[section]] or [section]
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SecM) {
            CurrentSection := StrLower(Trim(SecM[1]))
            continue
        }
        if (CurrentSection == "") {
            continue
        }
        ; Match hotstring entry: key = value or key = { ... }
        if !RegExMatch(Line, "^(?:`"[^`"]+`"|[A-Za-z0-9_.-]+)\s*=") {
            continue
        }
        if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match) {
            ; Simple format: "trigger" = "replacement" (not supported by full regex)
            ; Try to extract just trigger and output for simple entries
            if RegExMatch(Line, "i)^(?:`"([^`"]+)`"|([A-Za-z0-9_.-]+))\s*=\s*`"([^`"]+)`\"", &SimpleM) {
                Trigger := (SimpleM[1] != "") ? SimpleM[1] : SimpleM[2]
                Output  := SimpleM[3]
                Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
                Options := Map("TimeActivationSeconds", 0, "FinalResult", true)
                CreateCaseSensitiveHotstrings("", Trigger, Output, Options)
                TotalLoaded += 1
            }
            continue
        }
        Trigger    := UnescapeTomlString(Match[1])
        Output     := UnescapeTomlString(Match[2])
        Trigger    := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
        IsWord     := (Match[3] == "true")
        AutoExpand := (Match[4] == "true")
        IsCaseSens := (Match[5] == "true")
        FinalResult := (Match[6] == "true")
        StrictCase := (Match[7] == "true")
        Flags := ""
        if AutoExpand {
            Flags .= "*"
        }
        if !IsWord {
            Flags .= "?"
        }
        if StrictCase {
            Flags .= "C"
        }
        ; Only flag as repeat when the trigger contains the magic-key marker — plain
        ; text corrections in repeatcorrections (e.g. "ccê" → "ccu") must bypass
        ; the repeat-specific word-position check that blocks 1st-letter firing.
        SectionName := CurrentSection
        IsRepeat := (StrLower(CategoryName) == "magickey" and SectionName == "repeatcorrections"
            and InStr(Trigger, ScriptInformation["MagicKey"]) > 0)
        Options := Map("TimeActivationSeconds", 0, "FinalResult", FinalResult, "IsRepeat", IsRepeat)
        if IsCaseSens {
            CreateHotstring(Flags, Trigger, Output, Options)
        } else {
            CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
        }
        TotalLoaded += 1
    }
    try LoggerSuccess("TomlLoader", "Extension TOML '{1}': {2} entry(ies) loaded.", CategoryLabel, TotalLoaded)
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



; Parse the ``[_meta]`` and ``[_meta.sections.<name>]`` blocks of a category
; TOML to extract the file-level and per-section default delay (seconds) and
; tooltip color (hex). The result is cached in ``HotstringGroupConfig``.
;
; When FilePath is provided the file is loaded directly from that path and
; cached by the absolute path — this supports extension TOMLs and any
; personal hotstring file without requiring a category name. When FilePath is
; empty the path is resolved from CategoryName as before.
;
; Recognised keys:
;   [_meta]                       delay = <number>     color = "<hex>"
;   [_meta.sections.<name>]       delay = <number>     color = "<hex>"
;                                 description = "<...>"
;
ParseTomlGroupConfig(CategoryName, FilePath := "") {
    global ScriptInformation, HotstringGroupConfig, _StaticDir
    LowerCat := StrLower(CategoryName)

    ; When a direct path is given, use it as the cache key so different files
    ; with the same category name (e.g. multiple personal TOML files) are kept
    ; separately.
    CacheKey := (FilePath != "") ? FilePath : LowerCat
    if HotstringGroupConfig.Has(CacheKey) {
        return HotstringGroupConfig[CacheKey]
    }

    if (FilePath == "") {
        if (LowerCat == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
            FilePath := ScriptInformation["PersonalTomlPath"]
        } else {
            FilePath := _SharedDir . "\hotstrings\" . LowerCat . ".toml"
        }
    }

    Config := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
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
                Config.Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Description: "" }
            }
            continue
        }
        if RegExMatch(Line, "^\[_meta\.section_delays\]$") {
            Mode := "meta_section_delays"
            CurrentSec := ""
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
            } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
                Config.ShowTooltip := (BoolMatch[1] == "true")
            }
        } else if (Mode == "meta_section" and CurrentSec != "") {
            Sec := Config.Sections[CurrentSec]
            if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
                Sec.Delay := NumMatch[1] + 0
            } else if RegExMatch(Line, "^color\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &ColMatch) {
                Sec.Color := UnescapeTomlString(ColMatch[1])
            } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
                Sec.ShowTooltip := (BoolMatch[1] == "true")
            } else if RegExMatch(Line, "^description\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &DescMatch) {
                Sec.Description := UnescapeTomlString(DescMatch[1])
            }
        } else if (Mode == "meta_section_delays") {
            ; [_meta.section_delays] — each ``section = <seconds>`` line sets that
            ; section's delay override, read into the same Sections map that
            ; HotstringsResolve consults via TomlSec.Delay (precedence: user >
            ; section > group > global default).
            if RegExMatch(Line, "^([A-Za-z0-9_\-]+)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &SDMatch) {
                SDKey := StrLower(SDMatch[1])
                if !Config.Sections.Has(SDKey) {
                    Config.Sections[SDKey] := { Delay: "", Color: "", ShowTooltip: "", Description: "" }
                }
                Config.Sections[SDKey].Delay := SDMatch[2] + 0
            }
        }
    }

    HotstringGroupConfig[CacheKey] := Config
    return Config
}

; Count hotstring entries inside a specific [[section]] of a TOML category file.
; Returns 0 when the file or section does not exist.
; Uses the same ReadTomlFile cache to avoid redundant disk reads.
; When FilePath is provided the file is loaded directly (for extensions or
; multi-file personal hotstrings); CategoryName is used only for cache keying
; when FilePath is empty.
CountTomlSection(CategoryName, SectionName, FilePath := "") {
    global ScriptInformation, _TomlCountCache, _StaticDir
    CacheKey := (FilePath != "" ? FilePath : StrLower(CategoryName)) . "|" . StrLower(SectionName)
    if _TomlCountCache.Has(CacheKey)
        return _TomlCountCache[CacheKey]
    if (FilePath == "") {
        if (StrLower(CategoryName) == "personal"
        and IsSet(ScriptInformation)
        and ScriptInformation.Has("PersonalTomlPath")) {
            FilePath := ScriptInformation["PersonalTomlPath"]
        } else {
            FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
        }
    }
    if !FileExist(FilePath) {
        _TomlCountCache[CacheKey] := 0
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
        ; Match [[section]] or [section]
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SectionMatch) {
            CurrentSection := StrLower(Trim(SectionMatch[1]))
            continue
        }
        if (SubStr(Line, 1, 1) == "[") {
            CurrentSection := ""
            continue
        }
        if (CurrentSection == TargetSection) {
            ; Match hotstring entry: key = value or key = { ... }
            if RegExMatch(Line, "^(?:`"[^`"]+`"|[A-Za-z0-9_.-]+)\s*=") {
                Count++
            }
        }
    }
    _TomlCountCache[CacheKey] := Count
    return Count
}

; Count all hotstring entries across every [[section]] in a TOML category file.
; Returns 0 when the file does not exist or contains no matching entries.
; Uses the same ReadTomlFile cache as the rest of the loader to avoid double I/O.
; When FilePath is provided the file is loaded directly (for extensions or
; multi-file personal hotstrings); CategoryName is used only for cache keying
; when FilePath is empty.
CountTomlHotstrings(CategoryName, FilePath := "") {
    global ScriptInformation, _TomlCountCache, _StaticDir
    CacheKey := (FilePath != "" ? FilePath : StrLower(CategoryName)) . "|*"
    if _TomlCountCache.Has(CacheKey)
        return _TomlCountCache[CacheKey]
    if (FilePath == "") {
        if (StrLower(CategoryName) == "personal"
        and IsSet(ScriptInformation)
        and ScriptInformation.Has("PersonalTomlPath")) {
            FilePath := ScriptInformation["PersonalTomlPath"]
        } else {
            FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
        }
    }
    if !FileExist(FilePath) {
        _TomlCountCache[CacheKey] := 0
        return 0
    }
    Count := 0
    Q := Chr(34)
    InSec := false
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        ; Match [[section]] or [section]
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SectionMatch) {
            SecName := StrLower(Trim(SectionMatch[1]))
            InSec := (SecName != "_meta" and SecName != "_meta.sections" and SecName != "_meta.section_delays")
            continue
        }
        if (InSec) {
            ; Match hotstring entry: key = value or key = { ... }
            if RegExMatch(Line, "^(?:`"[^`"]+`"|[A-Za-z0-9_.-]+)\s*=") {
                Count++
            }
        }
    }
    _TomlCountCache[CacheKey] := Count
    return Count
}





; Read the sections_order array from the [_meta] block of a shared hotstrings
; TOML file (e.g. rolls.toml).  Returns an Array whose elements are either a
; section-name string or the sentinel string "-" (visual separator).
; Returns an empty Array when the file does not exist or has no sections_order.
; Uses the ReadTomlFile cache to avoid double I/O.
ReadTomlSectionsOrder(CategoryName, FilePath := "") {
    global _SharedDir
    if (FilePath == "") {
        FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
    }
    if !FileExist(FilePath) {
        return []
    }
    InMeta := false
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        ; Enter / leave the [_meta] block
        if (Line == "[_meta]") {
            InMeta := true
            continue
        }
        if (InMeta and SubStr(Line, 1, 1) == "[") {
            break  ; Left _meta block — sections_order not found
        }
        if !InMeta {
            continue
        }
        ; Match: sections_order = ["a", "b", "-", "c"]
        if !RegExMatch(Line, "^sections_order\s*=\s*\[(.+)\]", &M) {
            continue
        }
        Out := []
        loop parse, M[1], "," {
            Token := Trim(A_LoopField, " `t" Chr(34))
            if (Token != "") {
                Out.Push(Token)
            }
        }
        return Out
    }
    return []
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

