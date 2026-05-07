; drivers/autohotkey/lib/hotstrings_config.ahk

; ==============================================================================
; MODULE: Hotstrings Config
; DESCRIPTION:
; Resolves the effective delay (in seconds) and tooltip color for any
; hotstring group/section by merging three layers, in order of decreasing
; precedence:
;   1. User overrides — ``%USERPROFILE%\.config\ergopti_plus\hotstrings_config.toml``,
;      shared with the Hammerspoon driver so changes from either menu apply
;      to both at next reload.
;   2. TOML metadata — ``delay`` / ``color`` declared in each category TOML
;      under ``[_meta]`` (file scope) or ``[_meta.sections.<name>]`` (section).
;   3. Hard fallback (``GLOBAL_DEFAULT_DELAY``, no color).
;
; FEATURES & RATIONALE:
; 1. Single source of truth shared with HS — the override file format and
;    the TOML metadata schema are identical across drivers.
; 2. Lazy parsing — TOML metadata is fetched through ``ParseTomlGroupConfig``
;    (already cached in ``HotstringGroupConfig``); the override file is
;    parsed once per session and cached in ``_HotstringsOverrides``.
; 3. Personal hotstrings supported — passing CategoryName "personal" routes
;    the TOML lookup through ``ScriptInformation["PersonalTomlPath"]``.
; ==============================================================================

; Ultimate fallback when neither a user override nor a TOML default is set.
; Mirrors the HS module so behaviour is identical across drivers.
global GLOBAL_DEFAULT_DELAY := 0.75

; Absolute path of the user override file (set by HotstringsConfigInit).
global _HotstringsOverridesPath := ""

; In-memory cache of the override file content. Shape mirrors the HS module:
;   Map(category -> { Delay: Number|"", Color: String|"", Sections: Map(name -> { Delay, Color }) })
global _HotstringsOverrides := Map()


; ============================================================
; ============================================================
; ======= 1/ Override file I/O ==============================
; ============================================================
; ============================================================

; Initialise the module. Must be called before any Resolve/Set call.
; The path is shared with Hammerspoon so both drivers can read each other's
; edits after a reload.
HotstringsConfigInit(OverridePath) {
    global _HotstringsOverridesPath, _HotstringsOverrides
    _HotstringsOverridesPath := OverridePath
    _HotstringsOverrides := _ParseOverrides(OverridePath)
    try LoggerInfo("HotstringsConfig", "Initialized (override file: '{1}').", OverridePath)
}

; Parse the override TOML file. Returns an empty Map when the file is missing.
; Recognises ``[category]`` and ``[category.section]`` headers, plus
; ``delay = <number>`` and ``color = "<hex>"`` body lines. Anything else is
; silently ignored — the file is mostly machine-written.
_ParseOverrides(Path) {
    Result := Map()
    if (Path == "" or !FileExist(Path)) {
        return Result
    }

    Content := FileRead(Path, "UTF-8")
    CurrentCat := ""
    CurrentSec := ""

    loop parse, Content, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
            CurrentCat := StrLower(SecMatch[1])
            CurrentSec := StrLower(SecMatch[2])
            if !Result.Has(CurrentCat) {
                Result[CurrentCat] := { Delay: "", Color: "", Sections: Map() }
            }
            if !Result[CurrentCat].Sections.Has(CurrentSec) {
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "" }
            }
            continue
        }

        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\]$", &CatMatch) {
            CurrentCat := StrLower(CatMatch[1])
            CurrentSec := ""
            if !Result.Has(CurrentCat) {
                Result[CurrentCat] := { Delay: "", Color: "", Sections: Map() }
            }
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
        } else if RegExMatch(Line, "^color\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$", &ColMatch) {
            Target.Color := UnescapeTomlString(ColMatch[1])
        }
    }

    return Result
}

; Serialise the in-memory override Map back to TOML and write it to disk.
; Stable ordering: alphabetical category, alphabetical section.
_SaveOverrides() {
    global _HotstringsOverrides, _HotstringsOverridesPath
    if (_HotstringsOverridesPath == "") {
        return false
    }

    Out := "# Hotstrings — overrides utilisateur`n"
        . "# Édité depuis la fenêtre « Délais & couleurs hotstrings ».`n"
        . "# Ne pas mélanger les sections : chaque [category] et [category.section]`n"
        . "# ne doit apparaître qu'une seule fois.`n`n"

    Cats := []
    for Cat, _ in _HotstringsOverrides {
        Cats.Push(Cat)
    }
    _SortStringsInPlace(Cats)

    for _, Cat in Cats {
        Entry := _HotstringsOverrides[Cat]
        if (Entry.Delay != "" or Entry.Color != "") {
            Out .= "[" . Cat . "]`n"
            if (Entry.Delay != "") {
                Out .= "delay = " . Entry.Delay . "`n"
            }
            if (Entry.Color != "") {
                Out .= "color = `"" . Entry.Color . "`"`n"
            }
            Out .= "`n"
        }

        Secs := []
        for Sec, _ in Entry.Sections {
            Secs.Push(Sec)
        }
        _SortStringsInPlace(Secs)
        for _, Sec in Secs {
            S := Entry.Sections[Sec]
            if (S.Delay != "" or S.Color != "") {
                Out .= "[" . Cat . "." . Sec . "]`n"
                if (S.Delay != "") {
                    Out .= "delay = " . S.Delay . "`n"
                }
                if (S.Color != "") {
                    Out .= "color = `"" . S.Color . "`"`n"
                }
                Out .= "`n"
            }
        }
    }

    try {
        File := FileOpen(_HotstringsOverridesPath, "w", "UTF-8")
        File.Write(Out)
        File.Close()
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


; ============================================================
; ============================================================
; ======= 2/ Public API =====================================
; ============================================================
; ============================================================

; Resolve the effective delay (seconds) and color (hex string, may be empty)
; for a given (category, section) pair. ``Section`` may be empty for the
; file-level lookup. The returned object always exposes both fields.
;
; Resolution order — first non-empty wins:
;   1. user_override.section
;   2. user_override.file
;   3. toml.section
;   4. toml.file
;   5. GLOBAL_DEFAULT_DELAY (delay only); color stays empty.
HotstringsResolve(CategoryName, SectionName := "") {
    global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
    Cat := StrLower(CategoryName)
    ; Section names in features_config use PascalCase that may contain French
    ; letters (``IÉ``, ``ÊCirc``…). The TOML keeps the ASCII-folded lowercase
    ; form (``ie``, ``ecirc``…), so fold on the way in to keep call-sites
    ; ergonomic — they can pass the same string they already use elsewhere.
    Sec := SectionName != "" ? FoldAsciiLower(SectionName) : ""

    UserCat := _HotstringsOverrides.Has(Cat) ? _HotstringsOverrides[Cat] : ""
    UserSec := (UserCat != "" and Sec != "" and UserCat.Sections.Has(Sec))
        ? UserCat.Sections[Sec]
        : ""

    TomlCfg := ParseTomlGroupConfig(Cat)
    TomlSec := (Sec != "" and TomlCfg.Sections.Has(Sec))
        ? TomlCfg.Sections[Sec]
        : ""

    Delay := ""
    if (UserSec != "" and UserSec.Delay != "") {
        Delay := UserSec.Delay
    } else if (UserCat != "" and UserCat.Delay != "") {
        Delay := UserCat.Delay
    } else if (TomlSec != "" and TomlSec.Delay != "") {
        Delay := TomlSec.Delay
    } else if (TomlCfg.Delay != "") {
        Delay := TomlCfg.Delay
    } else {
        Delay := GLOBAL_DEFAULT_DELAY
    }

    Color := ""
    if (UserSec != "" and UserSec.Color != "") {
        Color := UserSec.Color
    } else if (UserCat != "" and UserCat.Color != "") {
        Color := UserCat.Color
    } else if (TomlSec != "" and TomlSec.Color != "") {
        Color := TomlSec.Color
    } else if (TomlCfg.Color != "") {
        Color := TomlCfg.Color
    }

    HasOverride := false
    if (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "")) {
        HasOverride := true
    } else if (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "")) {
        HasOverride := true
    }

    return { Delay: Delay, Color: Color, HasOverride: HasOverride }
}

; Set a single override field for (category, section). Pass SectionName as ""
; to set the file-level override. ``Field`` must be "delay" or "color".
; Persists immediately and refreshes the in-memory cache.
HotstringsSetOverride(CategoryName, SectionName, Field, Value) {
    global _HotstringsOverrides
    if (Field != "delay" and Field != "color") {
        try LoggerError("HotstringsConfig", "SetOverride: field must be 'delay' or 'color', got '{1}'.", Field)
        return false
    }
    Cat := StrLower(CategoryName)
    Sec := StrLower(SectionName)

    if !_HotstringsOverrides.Has(Cat) {
        _HotstringsOverrides[Cat] := { Delay: "", Color: "", Sections: Map() }
    }
    Entry := _HotstringsOverrides[Cat]

    if (Sec != "") {
        if !Entry.Sections.Has(Sec) {
            Entry.Sections[Sec] := { Delay: "", Color: "" }
        }
        Target := Entry.Sections[Sec]
    } else {
        Target := Entry
    }

    if (Field == "delay") {
        Target.Delay := Value
    } else {
        Target.Color := Value
    }

    try LoggerDebug("HotstringsConfig", "Override set: {1}{2}.{3} = {4}.",
        Cat, (Sec != "") ? "." . Sec : "", Field, Value)
    return _SaveOverrides()
}

; Remove a single override field, or both fields when Field is empty.
; Reverts the resolution to the TOML default (or global fallback).
HotstringsClearOverride(CategoryName, SectionName, Field := "") {
    global _HotstringsOverrides
    Cat := StrLower(CategoryName)
    Sec := StrLower(SectionName)

    if !_HotstringsOverrides.Has(Cat) {
        return true
    }
    Entry := _HotstringsOverrides[Cat]

    if (Sec != "") {
        if !Entry.Sections.Has(Sec) {
            return true
        }
        Target := Entry.Sections[Sec]
    } else {
        Target := Entry
    }

    if (Field == "" or Field == "delay") {
        Target.Delay := ""
    }
    if (Field == "" or Field == "color") {
        Target.Color := ""
    }

    try LoggerDebug("HotstringsConfig", "Override cleared: {1}{2}{3}.",
        Cat,
        (Sec != "") ? "." . Sec : "",
        (Field != "") ? "." . Field : "")
    return _SaveOverrides()
}

; Reload the override file from disk — useful after Hammerspoon has written
; to it while AHK was running. AHK is single-process so we don't need locks.
HotstringsConfigReload() {
    global _HotstringsOverridesPath, _HotstringsOverrides
    if (_HotstringsOverridesPath == "") {
        return false
    }
    _HotstringsOverrides := _ParseOverrides(_HotstringsOverridesPath)
    try LoggerDebug("HotstringsConfig", "Overrides reloaded from disk.")
    return true
}

; Return the absolute path of the override file (for diagnostics / UI).
HotstringsConfigPath() {
    global _HotstringsOverridesPath
    return _HotstringsOverridesPath
}
