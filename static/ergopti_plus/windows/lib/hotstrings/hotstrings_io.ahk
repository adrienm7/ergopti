; lib/hotstrings/hotstrings_io.ahk

; ==============================================================================
; MODULE: Hotstrings Config — Override File I/O
; DESCRIPTION:
; Reads and writes the hotstrings override file
; (%USERPROFILE%\.config\ergopti_plus\hotstrings_config.toml) that stores
; per-category/section delay, color, show_tooltip, and priority overrides
; shared between the AHK and Hammerspoon drivers.
;
; FEATURES & RATIONALE:
; 1. Cross-driver shared canon — the override file format is identical for both
;    drivers; any change from either menu takes effect on the other at reload.
; 2. Boot-time defaults loaded from _shared/modules/hotstrings/defaults.toml so
;    the AHK and macOS fallback values can never drift behind a re-typed literal.
; 3. Stable on-disk serialisation via _SaveOverrides: alphabetical category and
;    section order, HOTSTRINGS_DELAY_DECIMALS decimal places for delay values.
;
; Included by lib/hotstrings/hotstrings_config.ahk.
; ==============================================================================




; ============================================================
; ============================================================
; ======= 1/ Override file I/O ==============================
; ============================================================
; ============================================================

; Load the cross-driver hotstring resolution defaults — the global default
; expansion delay, the global default tooltip color, and the per-category
; "personal" baseline color — from the shared canon
; (_shared/modules/hotstrings/defaults.toml), the SINGLE source shared verbatim with the
; Hammerspoon driver. Must run once at boot BEFORE the tray menu is built (it
; reads GLOBAL_DEFAULT_DELAY) and before any HotstringsResolve.
;
; A missing file or key THROWS — in production the unhandled error surfaces the
; fatal dialog and the script exits (fail fast, rule 5.3); in the headless test
; runner run_all.ahk's OnError handler turns it into a "not ok 0" line instead
; of hanging on a modal. There is no compile-time fallback (rules 5.2 / 5.4).
; @param SharedDir Optional _shared/ root; defaults to the global ``_SharedDir``.
HotstringsConfigLoadSharedDefaults(SharedDir := "") {
    global _SharedDir, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, DYN_HOTSTRINGS_DEFAULT_DELAY
    global HOTSTRINGS_CATEGORY_DEFAULT_COLORS
    Dir  := (SharedDir != "") ? SharedDir : (IsSet(_SharedDir) ? _SharedDir : "")
    Path := Dir . "\modules\hotstrings\defaults.toml"
    c    := ParseTomlFile(Path)
    if !c.Count {
        throw Error("_shared/modules/hotstrings/defaults.toml introuvable ou vide : " . Path)
    }

    GLOBAL_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "default_sec", Path))
    DYN_HOTSTRINGS_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "dynamichotstrings_sec", Path))
    GLOBAL_DEFAULT_COLOR := _HSDefaultsRequireHex(c, "colors", "global_default", Path)
    HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"] := _HSDefaultsRequireHex(c, "colors", "personal", Path)

    try LoggerInfo("HotstringsConfig", "Shared defaults loaded (delay={1}s dyn={2}s color={3} personal={4}).",
        GLOBAL_DEFAULT_DELAY, DYN_HOTSTRINGS_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"])
}

; Source the llm_prediction baseline tint from the canonical AI loading hex
; (UI_AI_LOADING_HEX, loaded by UiStyle_LoadSharedConst() from
; _shared/modules/tooltip/constants.toml [accent_colors] ai_loading_hex) so the AI tint
; lives in ONE place instead of a re-typed literal. Must run AFTER
; UiStyle_LoadSharedConst() — UI_AI_LOADING_HEX is "" until then — and before the
; tray menu build / any resolve. A missing value THROWS (fail fast, no fallback).
HotstringsConfigLoadLlmPredictionColor() {
    global UI_AI_LOADING_HEX, HOTSTRINGS_CATEGORY_DEFAULT_COLORS
    Hex := IsSet(UI_AI_LOADING_HEX) ? UI_AI_LOADING_HEX : ""
    if (Hex == "") {
        throw Error("HotstringsConfigLoadLlmPredictionColor(): UI_AI_LOADING_HEX not loaded — must run after UiStyle_LoadSharedConst().")
    }
    HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] := Hex
}

; Fetch a required key from the parsed defaults cache, throwing on absence so a
; truncated/edited canon aborts loudly rather than resolving to "".
_HSDefaultsRequire(c, Section, Key, Path) {
    Val := IniCacheGet(c, Section, Key)
    if (Val == "_") {
        throw Error(Format("_shared/modules/hotstrings/defaults.toml — clé manquante : [{1}] {2} ({3})", Section, Key, Path))
    }
    return Val
}

; Like _HSDefaultsRequire but validates a "#RRGGBB" (or "RRGGBB") hex color and
; returns it normalised WITH the leading "#" (the form every consumer expects).
_HSDefaultsRequireHex(c, Section, Key, Path) {
    Val := _HSDefaultsRequire(c, Section, Key, Path)
    Hex := (SubStr(Val, 1, 1) == "#") ? SubStr(Val, 2) : Val
    if (StrLen(Hex) != 6) {
        throw Error(Format("_shared/modules/hotstrings/defaults.toml — couleur hex invalide : [{1}] {2} = {3}", Section, Key, Val))
    }
    return "#" . Hex
}

; Initialise the module. Must be called before any Resolve/Set call.
; The path is shared with Hammerspoon so both drivers can read each other's
; edits after a reload.
HotstringsConfigInit(OverridePath) {
    global _HotstringsOverridesPath, _HotstringsOverrides
    global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
    _HotstringsOverridesPath    := OverridePath
    _HotstringsOverrides        := _ParseOverrides(OverridePath)
    _HotstringsWordDelimiters   := _ParseGlobalKey(OverridePath, "word_delimiters")
    _HotstringsConsumedDelimiters := _ParseGlobalKey(OverridePath, "consumed_delimiters")
    HotstringsResolveBumpGen()
    try LoggerInfo("HotstringsConfig", "Initialized (override file: '{1}').", OverridePath)
}

; Read a quoted-string key from the ``[__global__]`` section of the override file.
; Returns "" when the file is missing or the key is absent.
_ParseGlobalKey(Path, KeyName) {
    if (Path == "" or !FileExist(Path)) {
        return ""
    }
    InGlobal := false
    Pattern  := "^" . KeyName . "\s*=\s*" . '"' . "((?:[^" . '"' . "\\]|\\.)*)" . '"' . "\s*$"
    loop read, Path {
        Line := Trim(A_LoopReadLine, " `t")
        if (Line == "[__global__]") {
            InGlobal := true
            continue
        }
        if (InGlobal and SubStr(Line, 1, 1) == "[") {
            break
        }
        if InGlobal and RegExMatch(Line, Pattern, &M) {
            return UnescapeTomlString(M[1])
        }
    }
    return ""
}

; Return the effective word-delimiter string: user override when present,
; otherwise the engine default ``HOTSTRINGS_DEFAULT_WORD_DELIMITERS``.
HotstringsGetWordDelimiters() {
    global _HotstringsWordDelimiters, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
    return (_HotstringsWordDelimiters != "") ? _HotstringsWordDelimiters : HOTSTRINGS_DEFAULT_WORD_DELIMITERS
}

; Extra boundaries the PREVIEW anchors on but the engine does not treat as
; hotstring terminators: a double quote can legitimately sit inside a trigger body.
global HOTSTRINGS_PREVIEW_EXTRA_BOUNDARIES := Chr(0x22) . Chr(0x201C) . Chr(0x201D)

; Recompute the prefix watcher's boundary set FROM the live engine terminator set.
; SINGLE SOURCE OF TRUTH — every writer of HSE_WORD_TERMINATORS must call this.
;
; _PREFIX_WORD_BOUNDARIES used to be a top-level global initialised by
; concatenating HSE_WORD_TERMINATORS at its own include position, i.e. a SNAPSHOT
; of the compile-time constant. lib/boot.ahk then replaced HSE_WORD_TERMINATORS
; with the catalogue-derived set and never recomputed the preview set, so the two
; silently diverged: the tooltip anchored on a set containing the apostrophe while
; the matcher did not, and every previewed apostrophe autocorrection (l'ame ->
; l'âme) rendered a suggestion that could never fire. Deriving instead of
; snapshotting removes the whole class.
HotstringsRefreshPrefixBoundaries() {
    global HSE_WORD_TERMINATORS, _PREFIX_WORD_BOUNDARIES, HOTSTRINGS_PREVIEW_EXTRA_BOUNDARIES
    ; The prefix watcher is not loaded under every harness; a missing target is
    ; not an error here, only a no-op.
    if !IsSet(_PREFIX_WORD_BOUNDARIES)
        return
    _PREFIX_WORD_BOUNDARIES := HSE_WORD_TERMINATORS . HOTSTRINGS_PREVIEW_EXTRA_BOUNDARIES
    try LoggerDebug("HotstringsConfig", "Preview boundaries refreshed ({1} char(s)).", StrLen(_PREFIX_WORD_BOUNDARIES))
}

; Persist a new word-delimiter string to the [__global__] section of the
; override file and propagate it immediately into the live engine variable
; HSE_WORD_TERMINATORS so the change takes effect without a Reload.
HotstringsSetWordDelimiters(Delimiters) {
    global _HotstringsOverridesPath, _HotstringsWordDelimiters, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
    global HSE_WORD_TERMINATORS, _PREFIX_WORD_BOUNDARIES
    _HotstringsWordDelimiters := Delimiters
    ; Mirror the live engine variable so the next keystroke already uses the
    ; updated set — mirrors the pattern used by HotstringsSetConsumedDelimiters.
    HSE_WORD_TERMINATORS := HotstringsGetWordDelimiters()

    HotstringsRefreshPrefixBoundaries()

    _SaveGlobalWordDelimiters(Delimiters)
}

; Return the effective consumed-delimiter string: user override when present,
; otherwise the catalogue-derived default (the magic key is consumed out of the
; box, matching macOS).
HotstringsGetConsumedDelimiters() {
    global _HotstringsConsumedDelimiters, HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
    return (_HotstringsConsumedDelimiters != "") ? _HotstringsConsumedDelimiters : HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
}

; Persist a new consumed-delimiter string to [__global__] and update in memory.
; Pass "" to fall back to the catalogue default (the magic key stays consumed).
HotstringsSetConsumedDelimiters(Consumed) {
    global _HotstringsConsumedDelimiters, HSE_CONSUMED_DELIMITERS
    _HotstringsConsumedDelimiters := Consumed
    HSE_CONSUMED_DELIMITERS       := Consumed
    _SaveGlobalKey("consumed_delimiters", Consumed, "")
}

; Write (or clear) the ``word_delimiters`` key in ``[__global__]``.
_SaveGlobalWordDelimiters(Delimiters) {
    global _HotstringsOverridesPath, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
    IsDefault := (Delimiters == HOTSTRINGS_DEFAULT_WORD_DELIMITERS or Delimiters == "")
    _SaveGlobalKey("word_delimiters", IsDefault ? "" : Delimiters, "")
}

; Generic writer for a quoted-string key inside [__global__].
; Writes KeyName = "Value" when Value is non-empty, removes the line otherwise.
; Creates the [__global__] section when it doesn't exist yet.
_SaveGlobalKey(KeyName, Value, _Unused := "") {
    global _HotstringsOverridesPath
    Path := _HotstringsOverridesPath
    if (Path == "") {
        return
    }

    if FileExist(Path) {
        Content := FileRead(Path, "UTF-8")
    } else {
        Content := "# Hotstrings — overrides utilisateur`n`n"
    }

    Lines     := StrSplit(Content, "`n", "`r")
    InGlobal  := false
    Found     := false
    FieldDone := false
    Out       := []
    IsEmpty   := (Value == "")
    Pattern   := "^" . KeyName . "\s*="

    for _i, RawLine in Lines {
        Line := Trim(RawLine, " `t`r")
        if (Line == "[__global__]") {
            InGlobal := true
            Found    := true
            Out.Push(RawLine)
            continue
        }
        if InGlobal and SubStr(Line, 1, 1) == "[" {
            if !FieldDone and !IsEmpty {
                Out.Push(KeyName . ' = "' . _EscapeTomlString(Value) . '"')
                FieldDone := true
            }
            InGlobal := false
        }
        if InGlobal and RegExMatch(Line, Pattern) {
            if !IsEmpty and !FieldDone {
                Out.Push(KeyName . ' = "' . _EscapeTomlString(Value) . '"')
                FieldDone := true
            }
            continue  ; Skip old line (drop it when IsEmpty)
        }
        Out.Push(RawLine)
    }

    if InGlobal and !FieldDone and !IsEmpty {
        Out.Push(KeyName . ' = "' . _EscapeTomlString(Value) . '"')
    }

    if !Found and !IsEmpty {
        if (Out.Length > 0 and Out[Out.Length] != "") {
            Out.Push("")
        }
        Out.Push("[__global__]")
        Out.Push(KeyName . ' = "' . _EscapeTomlString(Value) . '"')
    }

    while Out.Length > 1 and Out[Out.Length] == "" and Out[Out.Length - 1] == "" {
        Out.Pop()
    }

    NewContent := ""
    for I, L in Out {
        NewContent .= L
        if (I < Out.Length) {
            NewContent .= "`n"
        }
    }
    ; Mirror _SaveOverrides: explicit Close so the buffer is flushed before any
    ; reader sees the file, and a LOGGED failure with a boolean return so a
    ; read-only or cloud-locked config cannot look like a successful save. The
    ; in-memory value has already changed by the time we get here, so a bare
    ; `try` with no catch (the previous form) meant every observable signal in the
    ; session said "saved" while the setting silently reverted at next boot.
    try {
        FileHandle := FileOpen(Path, "w", "UTF-8")
        if !IsObject(FileHandle)
            throw Error("FileOpen returned no handle.")
        FileHandle.Write(NewContent)
        FileHandle.Close()
    } catch as Err {
        try LoggerError("HotstringsConfig",
            "Failed to write [__global__] {1} to '{2}': {3}.", KeyName, Path, Err.Message)
        return false
    }
    try LoggerDebug("HotstringsConfig", "[__global__] {1} written to '{2}'.", KeyName, Path)
    return true
}

_EscapeTomlString(S) {
    S := StrReplace(S, "\", "\\")
    S := StrReplace(S, '"', '\"')
    S := StrReplace(S, "`t", "\t")
    S := StrReplace(S, "`r", "\r")
    S := StrReplace(S, "`n", "\n")
    return S
}

; Parse the override TOML file. Returns an empty Map when the file is missing.
; Recognises the following header forms:
;   [category]                       — standard category (e.g. [magickey])
;   [category.section]               — section override (e.g. [magickey.repeat])
;   [ext.ext-name]                   — extension file-level override
;   [ext.ext-name.section]           — extension section override
; The full dotted key is used as the Map key for ext.* entries so it never
; collides with a bare single-word category (e.g. "ext.ergopti-demo").
_ParseOverrides(Path) {
    Result := Map()
    if (Path == "" or !FileExist(Path)) {
        return Result
    }

    Content := FileRead(Path, "UTF-8")
    CurrentCat := ""
    CurrentSec := ""
    ; Tracks every section key already seen to detect duplicates
    SeenSections := Map()

    loop parse, Content, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        ; Extension section header: [ext.name.section] — 3 dotted segments
        if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &ExtSecMatch) {
            CurrentCat := "ext." . StrLower(ExtSecMatch[1])
            CurrentSec := StrLower(ExtSecMatch[2])
            SectionName := CurrentCat . "." . CurrentSec
            if SeenSections.Has(SectionName)
                try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
            SeenSections[SectionName] := true
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            if !Result[CurrentCat].Sections.Has(CurrentSec)
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
            continue
        }

        ; Extension file header: [ext.name] — 2 dotted segments starting with "ext."
        if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\]$", &ExtMatch) {
            CurrentCat := "ext." . StrLower(ExtMatch[1])
            CurrentSec := ""
            SectionName := CurrentCat
            if SeenSections.Has(SectionName)
                try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
            SeenSections[SectionName] := true
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            continue
        }

        ; Standard section header: [category.section]
        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
            CurrentCat := StrLower(SecMatch[1])
            CurrentSec := StrLower(SecMatch[2])
            SectionName := CurrentCat . "." . CurrentSec
            if SeenSections.Has(SectionName)
                try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
            SeenSections[SectionName] := true
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            if !Result[CurrentCat].Sections.Has(CurrentSec)
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
            continue
        }

        ; Standard category header: [category]
        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\]$", &CatMatch) {
            CurrentCat := StrLower(CatMatch[1])
            CurrentSec := ""
            SectionName := CurrentCat
            if SeenSections.Has(SectionName)
                try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
            SeenSections[SectionName] := true
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            continue
        }

        if (CurrentCat == "") {
            continue
        }

        Target := (CurrentSec != "")
            ? Result[CurrentCat].Sections[CurrentSec]
            : Result[CurrentCat]

        if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
            Target.Delay := NumMatch[1] + 0
        } else if RegExMatch(Line, "^color\s*=\s*" . '"' . "((?:[^" . '"' . "\\]|\\.)*)" . '"' . "\s*$", &ColMatch) {
            Target.Color := UnescapeTomlString(ColMatch[1])
        } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
            Target.ShowTooltip := (BoolMatch[1] == "true")
        } else if RegExMatch(Line, "^priority\s*=\s*([0-9]+)\s*$", &PrioMatch) {
            Target.Priority := PrioMatch[1] + 0
        }
    }

    return Result
}

; Single source of truth for serialising a delay (in seconds) to its on-disk
; TOML numeric string. Both backends MUST route through this so the shared
; override file and a personal file's [_meta] never diverge for the same value:
; previously the override store wrote the raw number while the config window's
; _HCW_TomlValue quantised to 3 decimals, so the same logical delay could land
; as two different strings (UI/engine drift). Delays are millisecond-quantised
; everywhere — 3 decimal places of a second == whole milliseconds.
global HOTSTRINGS_DELAY_DECIMALS := 3
HotstringsSerialiseDelay(Value) {
    global HOTSTRINGS_DELAY_DECIMALS
    Num := Value + 0
    return Format("{:." . HOTSTRINGS_DELAY_DECIMALS . "f}", Num)
}

; Serialise the in-memory override Map back to TOML and write it to disk.
; Stable ordering: alphabetical category, alphabetical section.
_SaveOverrides() {
    global _HotstringsOverrides, _HotstringsOverridesPath
    global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
    if (_HotstringsOverridesPath == "") {
        return false
    }

    Out := "# Hotstrings — overrides utilisateur`n"
        . "# Édité depuis la fenêtre « Délais & couleurs hotstrings ».`n"
        . "# Ne pas mélanger les sections : chaque [category] et [category.section]`n"
        . "# ne doit apparaître qu'une seule fois.`n`n"

    ; Re-emit [__global__] so a category/section edit never erases the
    ; cross-driver word/consumed delimiter customisation.
    if (_HotstringsWordDelimiters != "" or _HotstringsConsumedDelimiters != "") {
        Out .= "[__global__]`n"
        ; Escape exactly like _SaveGlobalKey does: these are the SAME [__global__]
        ; keys written by two different writers, and concatenating raw here meant a
        ; delimiter containing a quote or backslash produced malformed TOML — the next
        ; read then silently reverted the user's whole delimiter set.
        if (_HotstringsWordDelimiters != "")
            Out .= 'word_delimiters = "' . _EscapeTomlString(_HotstringsWordDelimiters) . '"`n'
        if (_HotstringsConsumedDelimiters != "")
            Out .= 'consumed_delimiters = "' . _EscapeTomlString(_HotstringsConsumedDelimiters) . '"`n'
        Out .= "`n"
    }

    Cats := []
    for Cat in _HotstringsOverrides {
        Cats.Push(Cat)
    }
    _SortStringsInPlace(Cats)

    for _, Cat in Cats {
        if (Cat == "__global__")   ; reserved — handled above
            continue
        Entry := _HotstringsOverrides[Cat]
        ; Extension keys are stored as "ext.name" — the header must be written
        ; as [ext.name] (2 segments), not [ext.name] which would be ambiguous
        ; when parsed back. Section headers for ext keys: [ext.name.section].
        IsExt := SubStr(Cat, 1, 4) == "ext."

        EntryPrio := Entry.HasOwnProp("Priority") ? Entry.Priority : ""
        if (Entry.Delay != "" or Entry.Color != "" or Entry.ShowTooltip != "" or EntryPrio != "") {
            Out .= "[" . Cat . "]`n"
            if (Entry.Delay != "") {
                Out .= "delay = " . HotstringsSerialiseDelay(Entry.Delay) . "`n"
            }
            if (Entry.Color != "") {
                Out .= 'color = "' . Entry.Color . '"' . "`n"
            }
            if (Entry.ShowTooltip != "") {
                Out .= "show_tooltip = " . (Entry.ShowTooltip ? "true" : "false") . "`n"
            }
            if (EntryPrio != "") {
                Out .= "priority = " . EntryPrio . "`n"
            }
            Out .= "`n"
        }

        Secs := []
        for Sec in Entry.Sections {
            Secs.Push(Sec)
        }
        _SortStringsInPlace(Secs)
        for _, Sec in Secs {
            S := Entry.Sections[Sec]
            SPrio := S.HasOwnProp("Priority") ? S.Priority : ""
            if (S.Delay != "" or S.Color != "" or S.ShowTooltip != "" or SPrio != "") {
                ; Extension: [ext.name.section] — Cat already contains the dot
                Out .= "[" . Cat . "." . Sec . "]`n"
                if (S.Delay != "") {
                    Out .= "delay = " . HotstringsSerialiseDelay(S.Delay) . "`n"
                }
                if (S.Color != "") {
                    Out .= 'color = "' . S.Color . '"' . "`n"
                }
                if (S.ShowTooltip != "") {
                    Out .= "show_tooltip = " . (S.ShowTooltip ? "true" : "false") . "`n"
                }
                if (SPrio != "") {
                    Out .= "priority = " . SPrio . "`n"
                }
                Out .= "`n"
            }
        }
    }

    try {
        FileHandle := FileOpen(_HotstringsOverridesPath, "w", "UTF-8")
        FileHandle.Write(Out)
        FileHandle.Close()
        try LoggerDebug("HotstringsConfig", "Override file written: '{1}'.", _HotstringsOverridesPath)
        return true
    } catch as Err {
        try LoggerError("HotstringsConfig", "Failed to write override file: {1}.", Err.Message)
        return false
    }
}

; In-place ascending sort of a string array (AHK v2 has no built-in for this).
_SortStringsInPlace(Arr) {
    n := Arr.Length
    i := 2
    while (i <= n) {
        Pivot := Arr[i]
        j := i - 1
        while (j >= 1 and StrCompare(Arr[j], Pivot) > 0) {
            Arr[j + 1] := Arr[j]
            j -= 1
        }
        Arr[j + 1] := Pivot
        i += 1
    }
}
