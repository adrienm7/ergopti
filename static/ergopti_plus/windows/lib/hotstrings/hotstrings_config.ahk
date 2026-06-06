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
;   3. Hard fallback (``GLOBAL_DEFAULT_DELAY``, ``GLOBAL_DEFAULT_COLOR``).
;
; SUPPORTED CATEGORY NAMESPACES:
;   - Standard categories  : [magickey], [autocorrection], …
;   - Extension overrides  : [ext.nom-extension] / [ext.nom-extension.sections.xxx]
;     Written by the UI when the user customises a bundled extension's color or delay.
;     The full dotted key (e.g. "ext.ergopti-demo") is used as the map key so it
;     never collides with a bare category name.
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
; ``GLOBAL_DEFAULT_COLOR`` is the SINGLE source of truth for "no color set" —
; every per-category lookup that finds nothing else lands here.
global GLOBAL_DEFAULT_DELAY := 0.75
global GLOBAL_DEFAULT_COLOR := "#1e88e5"  ; Blue — global tooltip tint when nothing else is configured

; Default activation delay (seconds) for the dynamic hotstrings (dates, phone /
; SSN / IBAN prefixes). Mirrors the macOS DELAYS_DEFAULT.dynamichotstrings value.
; Defined HERE — in the early-loaded config layer — rather than in
; modules/hotstrings.ahk, because the tray "Delays" submenu reads it while
; building the menu at startup (initMenu), before the feature module's top-level
; code has run; a definition in the late module leaves it unassigned and crashes
; menu construction. The user's "dynamichotstrings" delay override takes priority.
global DYN_HOTSTRINGS_DEFAULT_DELAY := 2.0

; Per-category baseline that overrides ``GLOBAL_DEFAULT_COLOR`` only when no
; TOML _meta or user override sets a color. Lives next to the global default
; so all defaults are visible in one place.
global HOTSTRINGS_CATEGORY_DEFAULT_COLORS := Map(
    "personal",       "#6e6e73",  ; Gray — neutral baseline so user-added entries stand out only when the user picks a colour themselves
    "llm_prediction", "#AD61FF",  ; Violet — AI loading / in-flight tooltip (macOS ai_loading; overridable in hotstring settings)
)

; Shared terminator catalogue instance — the single source of truth for the
; word-expander LIST (labels, order, separators) AND the default-enabled set,
; generated from shared/domain/Terminators.spec.js and shared verbatim with
; macOS. Both the tray submenu and the config-window checkboxes render
; HSE_Terminators.all() so the catalogue can never drift between the two UIs or
; between drivers. Created once at load — before initMenu and before the default
; strings below read it — so nothing hits an unassigned global. Per-entry
; enabled state is persisted as the word-delimiter string (see
; HotstringsGetWordDelimiters); the catalogue supplies the items, the string
; supplies which are active.
global HSE_Terminators := Terminators()

; Default word-terminator and consumed-delimiter strings — the canonical
; fallbacks applied when no override is stored in hotstrings_config.toml. Both
; are DERIVED from the catalogue's default_enabled / consume flags so the AHK
; defaults are byte-identical to the macOS defaults (one source). Only the basic
; terminators ship on (whitespace + sentence punctuation + the magic key); every
; other slot is available but off by default. See Terminators.spec.js.
global HOTSTRINGS_DEFAULT_WORD_DELIMITERS     := HSE_TerminatorDefaultWordDelimiters()
global HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters()

; Absolute path of the user override file (set by HotstringsConfigInit).
global _HotstringsOverridesPath := ""

; User-overridden word-delimiter string read from [__global__] in the override
; file. Empty string means "use the engine default".
global _HotstringsWordDelimiters := ""

; Chars within the active word-delimiter set that are consumed (not re-injected)
; after an expansion fires. Stored in [__global__] consumed_delimiters in the
; override file. Empty string means "consume nothing" (default behaviour).
global _HotstringsConsumedDelimiters := ""

; In-memory cache of the override file content. Shape mirrors the HS module:
;   Map(category -> { Delay: Number|"", Color: String|"", ShowTooltip: true|"", Sections: Map(name -> { Delay, Color, ShowTooltip }) })
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
    global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
    _HotstringsOverridesPath    := OverridePath
    _HotstringsOverrides        := _ParseOverrides(OverridePath)
    _HotstringsWordDelimiters   := _ParseGlobalKey(OverridePath, "word_delimiters")
    _HotstringsConsumedDelimiters := _ParseGlobalKey(OverridePath, "consumed_delimiters")
    try LoggerInfo("HotstringsConfig", "Initialized (override file: '{1}').", OverridePath)
}

; Read a quoted-string key from the ``[__global__]`` section of the override file.
; Returns "" when the file is missing or the key is absent.
_ParseGlobalKey(Path, KeyName) {
    if (Path == "" or !FileExist(Path)) {
        return ""
    }
    InGlobal := false
    Pattern  := "^" . KeyName . "\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*$"
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

; Persist a new word-delimiter string to the [__global__] section of the
; override file, then trigger a Reload so the engine picks up the change.
HotstringsSetWordDelimiters(Delimiters) {
    global _HotstringsOverridesPath, _HotstringsWordDelimiters, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
    _HotstringsWordDelimiters := Delimiters
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
                Out.Push(KeyName . " = `"" . _EscapeTomlString(Value) . "`"")
                FieldDone := true
            }
            InGlobal := false
        }
        if InGlobal and RegExMatch(Line, Pattern) {
            if !IsEmpty and !FieldDone {
                Out.Push(KeyName . " = `"" . _EscapeTomlString(Value) . "`"")
                FieldDone := true
            }
            continue  ; Skip old line (drop it when IsEmpty)
        }
        Out.Push(RawLine)
    }

    if InGlobal and !FieldDone and !IsEmpty {
        Out.Push(KeyName . " = `"" . _EscapeTomlString(Value) . "`"")
    }

    if !Found and !IsEmpty {
        if (Out.Length > 0 and Out[Out.Length] != "") {
            Out.Push("")
        }
        Out.Push("[__global__]")
        Out.Push(KeyName . " = `"" . _EscapeTomlString(Value) . "`"")
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
    try FileOpen(Path, "w", "UTF-8").Write(NewContent)
}

_EscapeTomlString(S) {
    S := StrReplace(S, "\", "\\")
    S := StrReplace(S, '"', '`"')
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

    loop parse, Content, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }

        ; Extension section header: [ext.name.section] — 3 dotted segments
        if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &ExtSecMatch) {
            CurrentCat := "ext." . StrLower(ExtSecMatch[1])
            CurrentSec := StrLower(ExtSecMatch[2])
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
            if !Result[CurrentCat].Sections.Has(CurrentSec)
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "" }
            continue
        }

        ; Extension file header: [ext.name] — 2 dotted segments starting with "ext."
        if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\]$", &ExtMatch) {
            CurrentCat := "ext." . StrLower(ExtMatch[1])
            CurrentSec := ""
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
            continue
        }

        ; Standard section header: [category.section]
        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
            CurrentCat := StrLower(SecMatch[1])
            CurrentSec := StrLower(SecMatch[2])
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
            if !Result[CurrentCat].Sections.Has(CurrentSec)
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "" }
            continue
        }

        ; Standard category header: [category]
        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\]$", &CatMatch) {
            CurrentCat := StrLower(CatMatch[1])
            CurrentSec := ""
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
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
        } else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
            Target.ShowTooltip := (BoolMatch[1] == "true")
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
    for Cat in _HotstringsOverrides {
        Cats.Push(Cat)
    }
    _SortStringsInPlace(Cats)

    for Cat in Cats {
        Entry := _HotstringsOverrides[Cat]
        ; Extension keys are stored as "ext.name" — the header must be written
        ; as [ext.name] (2 segments), not [ext.name] which would be ambiguous
        ; when parsed back. Section headers for ext keys: [ext.name.section].
        IsExt := SubStr(Cat, 1, 4) == "ext."

        if (Entry.Delay != "" or Entry.Color != "" or Entry.ShowTooltip != "") {
            Out .= "[" . Cat . "]`n"
            if (Entry.Delay != "") {
                Out .= "delay = " . Entry.Delay . "`n"
            }
            if (Entry.Color != "") {
                Out .= "color = `"" . Entry.Color . "`"`n"
            }
            if (Entry.ShowTooltip != "") {
                Out .= "show_tooltip = " . (Entry.ShowTooltip ? "true" : "false") . "`n"
            }
            Out .= "`n"
        }

        Secs := []
        for Sec in Entry.Sections {
            Secs.Push(Sec)
        }
        _SortStringsInPlace(Secs)
        for Sec in Secs {
            S := Entry.Sections[Sec]
            if (S.Delay != "" or S.Color != "" or S.ShowTooltip != "") {
                ; Extension: [ext.name.section] — Cat already contains the dot
                Out .= "[" . Cat . "." . Sec . "]`n"
                if (S.Delay != "") {
                    Out .= "delay = " . S.Delay . "`n"
                }
                if (S.Color != "") {
                    Out .= "color = `"" . S.Color . "`"`n"
                }
                if (S.ShowTooltip != "") {
                    Out .= "show_tooltip = " . (S.ShowTooltip ? "true" : "false") . "`n"
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
    global GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS
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
    } else if (_HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != "") {
        ; Menu-set global default expansion delay — applied only when no user or
        ; TOML delay is defined for this category/section. It is the "default
        ; expansion delay" the user edits from the tray menu; the hardcoded
        ; GLOBAL_DEFAULT_DELAY below is the final fallback when even that is unset.
        Delay := _HotstringsOverrides["_global"].Delay
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
    } else {
        ; Nothing in user overrides or TOML _meta — fall back to the
        ; per-category default first (e.g. personal → orange) then to the
        ; single global default. ``HotstringsResolveExt`` already lands
        ; here; ``HotstringsResolve`` now matches so a resolved color is
        ; never empty, regardless of category.
        CatKey := StrLower(CategoryName)
        Color := HOTSTRINGS_CATEGORY_DEFAULT_COLORS.Has(CatKey)
            ? HOTSTRINGS_CATEGORY_DEFAULT_COLORS[CatKey]
            : GLOBAL_DEFAULT_COLOR
    }

    ; ShowTooltip — explicit false anywhere in the chain suppresses the tooltip.
    ; Default when unset at every level is true.
    ShowTooltip := true
    if (UserSec != "" and UserSec.ShowTooltip != "") {
        ShowTooltip := UserSec.ShowTooltip
    } else if (UserCat != "" and UserCat.ShowTooltip != "") {
        ShowTooltip := UserCat.ShowTooltip
    } else if (TomlSec != "" and TomlSec.ShowTooltip != "") {
        ShowTooltip := TomlSec.ShowTooltip
    } else if (TomlCfg.ShowTooltip != "") {
        ShowTooltip := TomlCfg.ShowTooltip
    }

    HasOverride := false
    if (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != "")) {
        HasOverride := true
    } else if (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != "")) {
        HasOverride := true
    }

    return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, HasOverride: HasOverride }
}

; Resolve the effective delay and color for an extension hotstring file.
; ExtId  — the extension id (e.g. "ergopti-demo").
; TomlPath — absolute path to the extension TOML file, used to read its [_meta].
; SectionName — optional section name within the file.
;
; Resolution order (first non-empty wins):
;   1. [ext.extid.section] in hotstrings_config.toml (user override, section level)
;   2. [ext.extid]         in hotstrings_config.toml (user override, file level)
;   3. [_meta.sections.*] in the extension TOML     (extension default, section)
;   4. [_meta]             in the extension TOML     (extension default, file)
;   5. GLOBAL_DEFAULT_DELAY / GLOBAL_DEFAULT_COLOR   (hard fallback)
HotstringsResolveExt(ExtId, TomlPath, SectionName := "") {
    global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR
    OverrideKey := "ext." . StrLower(ExtId)
    Sec := SectionName != "" ? StrLower(SectionName) : ""

    UserCat := _HotstringsOverrides.Has(OverrideKey) ? _HotstringsOverrides[OverrideKey] : ""
    UserSec := (UserCat != "" and Sec != "" and UserCat.Sections.Has(Sec))
        ? UserCat.Sections[Sec]
        : ""

    TomlCfg := ParseTomlGroupConfig("", TomlPath)
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
    } else if (_HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != "") {
        ; Menu-set global default expansion delay — applied only when no user or
        ; TOML delay is defined for this category/section. It is the "default
        ; expansion delay" the user edits from the tray menu; the hardcoded
        ; GLOBAL_DEFAULT_DELAY below is the final fallback when even that is unset.
        Delay := _HotstringsOverrides["_global"].Delay
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
    } else {
        Color := GLOBAL_DEFAULT_COLOR
    }

    ShowTooltip := true
    if (UserSec != "" and UserSec.ShowTooltip != "") {
        ShowTooltip := UserSec.ShowTooltip
    } else if (UserCat != "" and UserCat.ShowTooltip != "") {
        ShowTooltip := UserCat.ShowTooltip
    } else if (TomlSec != "" and TomlSec.ShowTooltip != "") {
        ShowTooltip := TomlSec.ShowTooltip
    } else if (TomlCfg.ShowTooltip != "") {
        ShowTooltip := TomlCfg.ShowTooltip
    }

    HasOverride := (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != ""))
        or  (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != ""))
    return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, HasOverride: HasOverride }
}


; Set a single override field for (category, section). Pass SectionName as ""
; to set the file-level override. ``Field`` must be "delay" or "color".
; Persists immediately and refreshes the in-memory cache.
HotstringsSetOverride(CategoryName, SectionName, Field, Value) {
    global _HotstringsOverrides
    if (Field != "delay" and Field != "color" and Field != "show_tooltip") {
        try LoggerError("HotstringsConfig", "SetOverride: field must be 'delay', 'color', or 'show_tooltip', got '{1}'.", Field)
        return false
    }
    Cat := StrLower(CategoryName)
    Sec := StrLower(SectionName)

    if !_HotstringsOverrides.Has(Cat) {
        _HotstringsOverrides[Cat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
    }
    Entry := _HotstringsOverrides[Cat]

    if (Sec != "") {
        if !Entry.Sections.Has(Sec) {
            Entry.Sections[Sec] := { Delay: "", Color: "", ShowTooltip: "" }
        }
        Target := Entry.Sections[Sec]
    } else {
        Target := Entry
    }

    if (Field == "delay") {
        Target.Delay := Value
    } else if (Field == "color") {
        Target.Color := Value
    } else {
        Target.ShowTooltip := Value
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
    if (Field == "" or Field == "show_tooltip") {
        Target.ShowTooltip := ""
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




; ============================================================
; ============================================================
; ======= 3/ Terminator catalogue helpers ===================
; ============================================================
; ============================================================

; Pure helpers shared by the tray word-expander submenu and the config-window
; checkbox grid so the per-entry enable/toggle logic lives in exactly one place
; (and is unit-tested via test_terminators.ahk). They operate on the active
; word-delimiter STRING — the persisted serialization of the catalogue's
; enabled state — and the generated HSE_Terminators catalogue. No I/O here;
; callers persist the returned string via HotstringsSetWordDelimiters.

; Default word-terminator string — the chars of every catalogue entry that is
; enabled by default. This is the single source for the AHK default set, kept in
; lock-step with macOS (both read the same catalogue). Separators are skipped.
HSE_TerminatorDefaultWordDelimiters() {
    global HSE_Terminators
    Out := ""
    for D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        if !D["default_enabled"]
            continue
        for Ch in D["chars"]
            Out .= Ch
    }
    return Out
}

; Default consumed-delimiter string — the chars of every catalogue entry that is
; both enabled by default AND marked consume (i.e. the magic key). Swallowed
; rather than re-injected after an expansion, matching macOS.
HSE_TerminatorDefaultConsumedDelimiters() {
    global HSE_Terminators
    Out := ""
    for D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        if !(D["default_enabled"] and D["consume"])
            continue
        for Ch in D["chars"]
            Out .= Ch
    }
    return Out
}

; Concatenated chars of every built-in (non-separator) catalogue entry. Used to
; tell user-defined custom delimiters apart from catalogue ones.
HSE_TerminatorBuiltinChars() {
    global HSE_Terminators
    Out := ""
    for D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        for Ch in D["chars"]
            Out .= Ch
    }
    return Out
}

; True when EVERY char of a catalogue entry is present in the delimiter string
; (an entry such as "enter" owns both CR and LF and toggles as one unit).
HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
    if (CharsArr.Length == 0)
        return false
    for Ch in CharsArr {
        if !InStr(WordStr, Ch)
            return false
    }
    return true
}

; True when any of the entry's chars appears in the given string (used to render
; the "(consumed)" suffix from the actual consumed-delimiter set).
HSE_TerminatorAnyCharIn(CharsArr, Hay) {
    for Ch in CharsArr {
        if InStr(Hay, Ch)
            return true
    }
    return false
}

; Pure: return WordStr with the entry's chars toggled — all removed when the
; entry is currently enabled, all added otherwise.
HSE_TerminatorToggleString(WordStr, CharsArr) {
    if HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
        for Ch in CharsArr
            WordStr := StrReplace(WordStr, Ch, "")
    } else {
        for Ch in CharsArr {
            if !InStr(WordStr, Ch)
                WordStr .= Ch
        }
    }
    return WordStr
}

; Pure: return WordStr with every built-in catalogue char enabled (Enable=true)
; or removed (Enable=false), always preserving user-defined custom chars (those
; owned by no catalogue entry). CR/LF belong to the "enter" entry and follow it.
HSE_TerminatorSetAllString(WordStr, Enable) {
    global HSE_Terminators
    BuiltinChars := HSE_TerminatorBuiltinChars()
    Kept := ""
    Loop Parse, WordStr {
        Ch := A_LoopField
        if (Ch != "`r" and Ch != "`n" and !InStr(BuiltinChars, Ch))
            Kept .= Ch
    }
    if Enable {
        for D in HSE_Terminators.all() {
            if (D.Has("type") and D["type"] == "separator")
                continue
            for Ch in D["chars"] {
                if !InStr(Kept, Ch)
                    Kept .= Ch
            }
        }
    }
    return Kept
}
