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

; Map of FilePath → Map(SectionId → Count)
global _TomlFileSectionCounts := Map()

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

; Extract an individual per-hotstring priority from a TOML entry line, or return
; Fallback when the entry carries no `priority = N` key. The key must be preceded
; by `{` or `,` so it is matched only as a real inline-table key and can never
; collide with the word "priority" appearing inside the output string. This is
; the top level of the priority cascade (individual > section > file > source).
_ParseEntryPriority(Line, Fallback) {
    if RegExMatch(Line, "i)[,{]\s*priority\s*=\s*([0-9]+)", &PrioM) {
        return PrioM[1] + 0
    }
    return Fallback
}

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

; Helper to warm the section counts cache for a specific file.
_TomlWarmFileCounts(FilePath) {
    global _TomlFileSectionCounts
    if _TomlFileSectionCounts.Has(FilePath)
        return _TomlFileSectionCounts[FilePath]

    Counts := Map()
    if !FileExist(FilePath) {
        _TomlFileSectionCounts[FilePath] := Counts
        return Counts
    }

    CurrentSec := ""
    loop parse, ReadTomlFile(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#")
            continue
            
        ; [[section]] or [section] header
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SectionMatch) {
            CurrentSec := StrLower(Trim(SectionMatch[1]))
            if !Counts.Has(CurrentSec)
                Counts[CurrentSec] := 0
            continue
        }
        
        ; Match hotstring entry: key = value or key = { ... }
        if (CurrentSec != "" and CurrentSec != "_meta" and CurrentSec != "_meta.sections") {
            if RegExMatch(Line, '^(?:"[^"]+"|[A-Za-z0-9_.-]+)\s*=') {
                Counts[CurrentSec] := Counts[CurrentSec] + 1
            }
        }
    }

    _TomlFileSectionCounts[FilePath] := Counts
    return Counts
}

; Count hotstring entries inside a specific [[section]] of a TOML category file.
; Returns 0 when the file or section does not exist.
; Optimized to parse each file only ONCE and cache all section counts.
CountTomlSection(CategoryName, SectionName, FilePath := "") {
    global ScriptInformation, _SharedDir
    if (FilePath == "") {
        if (StrLower(CategoryName) == "personal"
        and IsSet(ScriptInformation)
        and ScriptInformation.Has("PersonalTomlPath")) {
            FilePath := ScriptInformation["PersonalTomlPath"]
        } else {
            FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
        }
    }
    
    Counts := _TomlWarmFileCounts(FilePath)
    SName := StrLower(SectionName)
    return Counts.Has(SName) ? Counts[SName] : 0
}

; Count all hotstring entries across every [[section]] in a TOML category file.
; Returns 0 when the file does not exist or contains no matching entries.
CountTomlHotstrings(CategoryName, FilePath := "") {
    global ScriptInformation, _SharedDir
    if (FilePath == "") {
        if (StrLower(CategoryName) == "personal"
        and IsSet(ScriptInformation)
        and ScriptInformation.Has("PersonalTomlPath")) {
            FilePath := ScriptInformation["PersonalTomlPath"]
        } else {
            FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
        }
    }
    
    Counts := _TomlWarmFileCounts(FilePath)
    Total := 0
    for _, Count in Counts {
        Total += Count
    }
    return Total
}

; Evict all cache entries for a given file path so that the next call to
; ParseTomlGroupConfig or ReadTomlFile re-reads from disk. Called after
; _HCW_PatchTomlMeta writes changes to a personal TOML file.
_ParseTomlGroupConfig_InvalidatePath(FilePath) {
    global _TomlFileCache, HotstringGroupConfig, _TomlCountCache, _TomlFileSectionCounts
    if _TomlFileCache.Has(FilePath) {
        _TomlFileCache.Delete(FilePath)
    }
    if HotstringGroupConfig.Has(FilePath) {
        HotstringGroupConfig.Delete(FilePath)
    }
    ; The resolved hotstring delay/color for this group may now differ, so drop
    ; the memoised HotstringsResolve results too (defined in hotstrings_config.ahk).
    try HotstringsResolveBumpGen()
    ; Also invalidate the section counts cache for this file
    if _TomlFileSectionCounts.Has(FilePath) {
        _TomlFileSectionCounts.Delete(FilePath)
    }
    ; Legacy count cache invalidation
    for Key, _ in _TomlCountCache.Clone() {
        if InStr(Key, FilePath) {
            _TomlCountCache.Delete(Key)
        }
    }
}

; Unescape a TOML double-quoted string literal (\\, \", \n, \t, \r).
; The generator at static/hotstrings/0_generate_hotstrings.py writes
; trigger/output with these escapes, so we mirror the inverse transform here.
UnescapeTomlString(s) {
    ; Fast-path: the overwhelming majority of trigger/output values carry no
    ; escape sequence at all. A single InStr lets us skip the O(n^2) per-char
    ; rebuild and return the input verbatim — this runs thousands of times at
    ; boot (twice per non-generated hotstring entry), so the shortcut matters
    if !InStr(s, "\")
        return s
    Result := ""
    i := 1
    n := StrLen(s)
    while i <= n {
        c := SubStr(s, i, 1)
        if (c == "\" and i < n) {
            NextChar := SubStr(s, i + 1, 1)
            if (NextChar == "\") {
                Result .= "\"
            } else if (NextChar == '"') {
                Result .= '"'
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





; =======================================================
; =======================================================
; ======= 2/ High-level hotstring section loading =======
; =======================================================
; =======================================================

; Register every hotstring of a given [[section]] defined inside a TOML file
; located under ..\hotstrings\<CategoryName>.toml (relative to the script).
; Hotstrings flagged as commented-out in TOML (line starting with "#") are
; skipped, mirroring AHK source lines starting with ";".
LoadHotstringsSection(CategoryName, SectionName, FeatureConfig, ExtraOptions := Map()) {
    global ScriptInformation, _GENERATED_HOTSTRINGS, _SharedDir
    global HSE_PRIORITY_COMMON, HSE_PRIORITY_PERSONAL

    ; Accept either shape transparently
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
        ; Section-level priority override (cascade step above the source default).
        if FeatureConfig.Has("priority") {
            _V1Compat.Priority := FeatureConfig["priority"]
        }
        FeatureConfig := _V1Compat
    }

    ; Source default: the user's personal hotstrings outrank bundled "common"
    ; ones of equal length. A section-level priority (if set) overrides it.
    SourcePriority := (StrLower(CategoryName) == "personal") ? HSE_PRIORITY_PERSONAL : HSE_PRIORITY_COMMON
    SectionPriority := (IsObject(FeatureConfig) and FeatureConfig.HasOwnProp("Priority")) ? FeatureConfig.Priority : ""
    ResolvedPriority := (SectionPriority != "") ? SectionPriority : SourcePriority

    ; Per-group delay gating
    try {
        Resolved := HotstringsResolve(CategoryName, SectionName)
        if (Resolved.Delay != "") {
            FeatureConfig.TimeActivationSeconds := Resolved.Delay
        }
    }

    ; Fast path — bundled categories pre-compiled to literal AHK calls
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

    TimeActivationSeconds := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
    TargetSection := StrLower(SectionName)
    CurrentSection := ""

    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
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
        Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
        IsWord := (Match[3] == "true")
        AutoExpand := (Match[4] == "true")
        IsCaseSens := (Match[5] == "true")
        FinalResult := (Match[6] == "true")
        StrictCase := (Match[7] == "true")

        Flags := ""
        if AutoExpand
            Flags .= "*"
        if !IsWord
            Flags .= "?"
        if StrictCase
            Flags .= "C"

        ; Individual per-hotstring priority — the top of the cascade
        ; (individual > section > file > source default). Falls back to the
        ; resolved section/source value when the entry has no `priority` key.
        EntryPriority := _ParseEntryPriority(Line, ResolvedPriority)

        Options := Map(
            "TimeActivationSeconds", TimeActivationSeconds,
            "FinalResult", FinalResult,
            "Category", CategoryName,
            "Section", SectionName,
            "Priority", EntryPriority,
        )
        if ExtraOptions.Has("OnlyText") {
            Options["OnlyText"] := ExtraOptions["OnlyText"]
        }

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
LoadExtTomlFile(FilePath, CategoryLabel) {
    global ScriptInformation, _HOTSTRING_ENTRY_PATTERN, HSE_PRIORITY_PACKAGE
    if !FileExist(FilePath) {
        try LoggerWarn("TomlLoader", "Extension TOML '{1}' not found — skipped.", FilePath)
        return
    }
    try LoggerStart("TomlLoader", "Loading extension TOML '{1}'…", FilePath)
    TotalLoaded := 0
    CurrentSection := ""
    SplitPath FilePath, , , , &CategoryName
    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &SecM) {
            CurrentSection := StrLower(Trim(SecM[1]))
            continue
        }
        if (CurrentSection == "") {
            continue
        }
        if !RegExMatch(Line, '^(?:"[^"]+"|[A-Za-z0-9_.-]+)\s*=') {
            continue
        }
        if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match) {
            if RegExMatch(Line, 'i)^(?:"([^"]+)"|([A-Za-z0-9_.-]+))\s*=\s*"([^"]+)"', &SimpleM) {
                Trigger := (SimpleM[1] != "") ? SimpleM[1] : SimpleM[2]
                Output  := SimpleM[3]
                Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
                Options := Map("TimeActivationSeconds", 0, "FinalResult", true, "Priority", HSE_PRIORITY_PACKAGE)
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
        if AutoExpand
            Flags .= "*"
        if !IsWord
            Flags .= "?"
        if StrictCase
            Flags .= "C"

        SectionName := CurrentSection
        IsRepeat := (StrLower(CategoryName) == "magickey" and SectionName == "repeatcorrections"
            and InStr(Trigger, ScriptInformation["MagicKey"]) > 0)
        EntryPriority := _ParseEntryPriority(Line, HSE_PRIORITY_PACKAGE)
        Options := Map("TimeActivationSeconds", 0, "FinalResult", FinalResult, "IsRepeat", IsRepeat, "Priority", EntryPriority)
        if IsCaseSens {
            CreateHotstring(Flags, Trigger, Output, Options)
        } else {
            CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
        }
        TotalLoaded += 1
    }
    try LoggerSuccess("TomlLoader", "Extension TOML '{1}': {2} entry(ies) loaded.", CategoryLabel, TotalLoaded)
}

; Fold common French accented characters to their ASCII equivalent.
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



; Parse the ``[_meta]`` and ``[_meta.sections.<name>]`` blocks of a category TOML.
global HotstringGroupConfig := Map()

ParseTomlGroupConfig(CategoryName, FilePath := "") {
    global ScriptInformation, HotstringGroupConfig, _SharedDir
    LowerCat := StrLower(CategoryName)
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

    Mode := ""
    CurrentSec := ""

    FileContent := ReadTomlFile(FilePath)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
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
            Mode := ""
            CurrentSec := ""
            continue
        }

        if (Mode == "meta") {
            if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
                Config.Delay := NumMatch[1] + 0
            } else if RegExMatch(Line, '^color\s*=\s*"((?:[^"\\]|\\.)*)"$', &ColMatch) {
                Config.Color := UnescapeTomlString(ColMatch[1])
            } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
                Config.ShowTooltip := (BoolMatch[1] == "true")
            }
        } else if (Mode == "meta_section" and CurrentSec != "") {
            Sec := Config.Sections[CurrentSec]
            if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
                Sec.Delay := NumMatch[1] + 0
            } else if RegExMatch(Line, '^color\s*=\s*"((?:[^"\\]|\\.)*)"$', &ColMatch) {
                Sec.Color := UnescapeTomlString(ColMatch[1])
            } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
                Sec.ShowTooltip := (BoolMatch[1] == "true")
            } else if RegExMatch(Line, '^description\s*=\s*"((?:[^"\\]|\\.)*)"$', &DescMatch) {
                Sec.Description := UnescapeTomlString(DescMatch[1])
            }
        } else if (Mode == "meta_section_delays") {
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

; Read sections_order array from [_meta] block.
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
        if (Line == "[_meta]") {
            InMeta := true
            continue
        }
        if (InMeta and SubStr(Line, 1, 1) == "[") {
            break
        }
        if !InMeta {
            continue
        }
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

; Coerce raw TOML literal into appropriate AHK type.
TomlCoerceValue(Raw) {
    Trimmed := Trim(Raw, " `t")
    Lower := StrLower(Trimmed)
    if (Lower == "true")
        return 1
    if (Lower == "false")
        return 0
    if RegExMatch(Trimmed, "^-?\d+$")
        return Integer(Trimmed)
    if RegExMatch(Trimmed, "^-?\d+\.\d+$")
        return Float(Trimmed)
    Q := Chr(34)
    if (StrLen(Trimmed) >= 2 and SubStr(Trimmed, 1, 1) == Q
    and SubStr(Trimmed, StrLen(Trimmed), 1) == Q) {
        return UnescapeTomlString(SubStr(Trimmed, 2, StrLen(Trimmed) - 2))
    }
    return Trimmed
}
