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
; LOADED AT BOOT from the shared cross-driver canon
; (shared/hotstrings/defaults.toml) by HotstringsConfigLoadSharedDefaults() —
; the SINGLE source shared verbatim with the Hammerspoon driver. They start
; empty so a missing file/key fails fast (rule 5.3) rather than masking driver
; drift behind a hardcoded literal (rules 5.2 / 5.4). ``GLOBAL_DEFAULT_COLOR``
; remains the single source of truth for "no color set" — every per-category
; lookup that finds nothing else lands here.
global GLOBAL_DEFAULT_DELAY := ""
global GLOBAL_DEFAULT_COLOR := ""

; Default activation delay (seconds) for the dynamic hotstrings (dates, phone /
; SSN / IBAN prefixes). Mirrors the macOS DELAYS_DEFAULT.dynamichotstrings value.
; Defined HERE — in the early-loaded config layer — rather than in
; modules/hotstrings.ahk, because the tray "Delays" submenu reads it while
; building the menu at startup (initMenu), before the feature module's top-level
; code has run; a definition in the late module leaves it unassigned and crashes
; menu construction. The user's "dynamichotstrings" delay override takes priority.
global DYN_HOTSTRINGS_DEFAULT_DELAY := 2.0

; Per-category baseline that overrides ``GLOBAL_DEFAULT_COLOR`` only when no
; TOML _meta or user override sets a color. Both baselines load at boot from the
; shared canon — "personal" from shared/hotstrings/defaults.toml via
; HotstringsConfigLoadSharedDefaults() (kept in lock-step with macOS), and
; "llm_prediction" from the canonical AI loading hex
; (shared/tooltip/constants.toml [accent_colors] ai_loading_hex, exposed as
; UI_AI_LOADING_HEX) via HotstringsConfigLoadLlmPredictionColor(). They start
; empty so a missing load fails fast (rule 5.3) rather than masking drift behind
; a re-typed literal (rules 5.2 / 5.4).
global HOTSTRINGS_CATEGORY_DEFAULT_COLORS := Map(
    "llm_prediction", "",
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

; Memoisation for HotstringsResolve — the resolved {delay, color, show_tooltip}
; for a (category, section) pair is static between config changes, yet the prefix
; watcher resolves it per candidate on every keystroke while a tooltip is
; eligible. Results are cached and invalidated by bumping a generation counter on
; any override or group-config change; stale entries are ignored and overwritten,
; so the map stays bounded to the live keys.
global _HSResolveCache := Map()
global _HSResolveGen := 0





; ============================================================
; ============================================================
; ======= 1/ Override file I/O ==============================
; ============================================================
; ============================================================

; Load the cross-driver hotstring resolution defaults — the global default
; expansion delay, the global default tooltip color, and the per-category
; "personal" baseline color — from the shared canon
; (shared/hotstrings/defaults.toml), the SINGLE source shared verbatim with the
; Hammerspoon driver. Must run once at boot BEFORE the tray menu is built (it
; reads GLOBAL_DEFAULT_DELAY) and before any HotstringsResolve.
;
; A missing file or key THROWS — in production the unhandled error surfaces the
; fatal dialog and the script exits (fail fast, rule 5.3); in the headless test
; runner run_all.ahk's OnError handler turns it into a "not ok 0" line instead
; of hanging on a modal. There is no compile-time fallback (rules 5.2 / 5.4).
; @param SharedDir Optional shared/ root; defaults to the global ``_SharedDir``.
HotstringsConfigLoadSharedDefaults(SharedDir := "") {
    global _SharedDir, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR
    global HOTSTRINGS_CATEGORY_DEFAULT_COLORS
    Dir  := (SharedDir != "") ? SharedDir : (IsSet(_SharedDir) ? _SharedDir : "")
    Path := Dir . "\hotstrings\defaults.toml"
    c    := ParseTomlFile(Path)
    if !c.Count {
        throw Error("shared/hotstrings/defaults.toml introuvable ou vide : " . Path)
    }

    GLOBAL_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "default_sec", Path))
    GLOBAL_DEFAULT_COLOR := _HSDefaultsRequireHex(c, "colors", "global_default", Path)
    HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"] := _HSDefaultsRequireHex(c, "colors", "personal", Path)

    try LoggerInfo("HotstringsConfig", "Shared defaults loaded (delay={1}s color={2} personal={3}).",
        GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"])
}

; Source the llm_prediction baseline tint from the canonical AI loading hex
; (UI_AI_LOADING_HEX, loaded by UiStyle_LoadSharedConst() from
; shared/tooltip/constants.toml [accent_colors] ai_loading_hex) so the AI tint
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
        throw Error(Format("shared/hotstrings/defaults.toml — clé manquante : [{1}] {2} ({3})", Section, Key, Path))
    }
    return Val
}

; Like _HSDefaultsRequire but validates a "#RRGGBB" (or "RRGGBB") hex color and
; returns it normalised WITH the leading "#" (the form every consumer expects).
_HSDefaultsRequireHex(c, Section, Key, Path) {
    Val := _HSDefaultsRequire(c, Section, Key, Path)
    Hex := (SubStr(Val, 1, 1) == "#") ? SubStr(Val, 2) : Val
    if (StrLen(Hex) != 6) {
        throw Error(Format("shared/hotstrings/defaults.toml — couleur hex invalide : [{1}] {2} = {3}", Section, Key, Val))
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

; Persist a new word-delimiter string to the [__global__] section of the
; override file and propagate it immediately into the live engine variable
; HSE_WORD_TERMINATORS so the change takes effect without a Reload.
HotstringsSetWordDelimiters(Delimiters) {
    global _HotstringsOverridesPath, _HotstringsWordDelimiters, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
    global HSE_WORD_TERMINATORS
    _HotstringsWordDelimiters := Delimiters
    ; Mirror the live engine variable so the next keystroke already uses the
    ; updated set — mirrors the pattern used by HotstringsSetConsumedDelimiters.
    HSE_WORD_TERMINATORS := HotstringsGetWordDelimiters()
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
    try FileOpen(Path, "w", "UTF-8").Write(NewContent)
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
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            if !Result[CurrentCat].Sections.Has(CurrentSec)
                Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
            continue
        }

        ; Extension file header: [ext.name] — 2 dotted segments starting with "ext."
        if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\]$", &ExtMatch) {
            CurrentCat := "ext." . StrLower(ExtMatch[1])
            CurrentSec := ""
            if !Result.Has(CurrentCat)
                Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
            continue
        }

        ; Standard section header: [category.section]
        if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
            CurrentCat := StrLower(SecMatch[1])
            CurrentSec := StrLower(SecMatch[2])
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

    for _, Cat in Cats {
        Entry := _HotstringsOverrides[Cat]
        ; Extension keys are stored as "ext.name" — the header must be written
        ; as [ext.name] (2 segments), not [ext.name] which would be ambiguous
        ; when parsed back. Section headers for ext keys: [ext.name.section].
        IsExt := SubStr(Cat, 1, 4) == "ext."

        EntryPrio := Entry.HasOwnProp("Priority") ? Entry.Priority : ""
        if (Entry.Delay != "" or Entry.Color != "" or Entry.ShowTooltip != "" or EntryPrio != "") {
            Out .= "[" . Cat . "]`n"
            if (Entry.Delay != "") {
                Out .= "delay = " . Entry.Delay . "`n"
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
                    Out .= "delay = " . S.Delay . "`n"
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
    global _HSResolveCache, _HSResolveGen
    Key := StrLower(CategoryName) . "|" . (SectionName != "" ? FoldAsciiLower(SectionName) : "")
    if (_HSResolveCache.Has(Key)) {
        Cached := _HSResolveCache[Key]
        if (Cached.gen == _HSResolveGen)
            return Cached.val
    }
    Result := _HotstringsResolveUncached(CategoryName, SectionName)
    _HSResolveCache[Key] := { gen: _HSResolveGen, val: Result }
    return Result
}

; Invalidate every memoised HotstringsResolve result. Called from each override
; mutation and from the TOML group-config invalidation in toml_loader.ahk.
HotstringsResolveBumpGen() {
    global _HSResolveGen
    _HSResolveGen += 1
}

; Internal resolution logic (uncached); HotstringsResolve above memoises it.
_HotstringsResolveUncached(CategoryName, SectionName := "") {
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

    ; Priority — same cascade as Delay (section > category override, then TOML
    ; section > category default), falling back to the source default (personal
    ; 50 > package 30 > common 10) so a resolved priority is never empty. The
    ; individual per-hotstring level sits ABOVE this, applied in the TOML loader.
    ; HasOwnProp guards the TOML-config structs, which may predate the field.
    ; HasOwnProp guards every level: Priority is the newest override field, so a
    ; struct built before it existed (or a hand-rolled test mock) may lack it.
    Priority := ""
    if (UserSec != "" and UserSec.HasOwnProp("Priority") and UserSec.Priority != "") {
        Priority := UserSec.Priority
    } else if (UserCat != "" and UserCat.HasOwnProp("Priority") and UserCat.Priority != "") {
        Priority := UserCat.Priority
    } else if (TomlSec != "" and TomlSec.HasOwnProp("Priority") and TomlSec.Priority != "") {
        Priority := TomlSec.Priority
    } else if (TomlCfg.HasOwnProp("Priority") and TomlCfg.Priority != "") {
        Priority := TomlCfg.Priority
    } else {
        Priority := _HSE_SourcePriority(CategoryName)
    }

    HasOverride := false
    if (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != "" or (UserSec.HasOwnProp("Priority") and UserSec.Priority != ""))) {
        HasOverride := true
    } else if (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != "" or (UserCat.HasOwnProp("Priority") and UserCat.Priority != ""))) {
        HasOverride := true
    }

    return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, Priority: Priority, HasOverride: HasOverride }
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

    ; Priority — same cascade as Delay, with the extension source default
    ; (package tier 30) as the final fallback so a resolved priority is never
    ; empty. HasOwnProp guards structs (TOML config / test mocks) predating the
    ; field. The individual per-hotstring level sits above this, in the loader.
    Priority := ""
    if (UserSec != "" and UserSec.HasOwnProp("Priority") and UserSec.Priority != "") {
        Priority := UserSec.Priority
    } else if (UserCat != "" and UserCat.HasOwnProp("Priority") and UserCat.Priority != "") {
        Priority := UserCat.Priority
    } else if (TomlSec != "" and TomlSec.HasOwnProp("Priority") and TomlSec.Priority != "") {
        Priority := TomlSec.Priority
    } else if (TomlCfg.HasOwnProp("Priority") and TomlCfg.Priority != "") {
        Priority := TomlCfg.Priority
    } else {
        Priority := _HSE_SourcePriority("ext." . StrLower(ExtId))
    }

    HasOverride := (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != "" or (UserSec.HasOwnProp("Priority") and UserSec.Priority != "")))
        or  (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != "" or (UserCat.HasOwnProp("Priority") and UserCat.Priority != "")))
    return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, Priority: Priority, HasOverride: HasOverride }
}


; Set a single override field for (category, section). Pass SectionName as ""
; to set the file-level override. ``Field`` must be "delay" or "color".
; Persists immediately and refreshes the in-memory cache.
HotstringsSetOverride(CategoryName, SectionName, Field, Value) {
    global _HotstringsOverrides
    if (Field != "delay" and Field != "color" and Field != "show_tooltip" and Field != "priority") {
        try LoggerError("HotstringsConfig", "SetOverride: field must be 'delay', 'color', 'show_tooltip', or 'priority', got '{1}'.", Field)
        return false
    }
    Cat := StrLower(CategoryName)
    Sec := StrLower(SectionName)

    if !_HotstringsOverrides.Has(Cat) {
        _HotstringsOverrides[Cat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
    }
    Entry := _HotstringsOverrides[Cat]

    if (Sec != "") {
        if !Entry.Sections.Has(Sec) {
            Entry.Sections[Sec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
        }
        Target := Entry.Sections[Sec]
    } else {
        Target := Entry
    }

    if (Field == "delay") {
        Target.Delay := Value
    } else if (Field == "color") {
        Target.Color := Value
    } else if (Field == "priority") {
        Target.Priority := Value
    } else {
        Target.ShowTooltip := Value
    }

    try LoggerDebug("HotstringsConfig", "Override set: {1}{2}.{3} = {4}.",
        Cat, (Sec != "") ? "." . Sec : "", Field, Value)
    HotstringsResolveBumpGen()
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
    if (Field == "" or Field == "priority") {
        Target.Priority := ""
    }

    try LoggerDebug("HotstringsConfig", "Override cleared: {1}{2}{3}.",
        Cat,
        (Sec != "") ? "." . Sec : "",
        (Field != "") ? "." . Field : "")
    HotstringsResolveBumpGen()
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
    HotstringsResolveBumpGen()
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
    for _, D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        if !D["default_enabled"]
            continue
        for _, Ch in D["chars"]
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
    for _, D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        if !(D["default_enabled"] and D["consume"])
            continue
        for _, Ch in D["chars"]
            Out .= Ch
    }
    return Out
}

; Concatenated chars of every built-in (non-separator) catalogue entry. Used to
; tell user-defined custom delimiters apart from catalogue ones.
HSE_TerminatorBuiltinChars() {
    global HSE_Terminators
    Out := ""
    for _, D in HSE_Terminators.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        for _, Ch in D["chars"]
            Out .= Ch
    }
    return Out
}

; True when EVERY char of a catalogue entry is present in the delimiter string
; (an entry such as "enter" owns both CR and LF and toggles as one unit).
HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
    if (CharsArr.Length == 0)
        return false
    for _, Ch in CharsArr {
        if !InStr(WordStr, Ch)
            return false
    }
    return true
}

; True when any of the entry's chars appears in the given string (used to render
; the "(consumed)" suffix from the actual consumed-delimiter set).
HSE_TerminatorAnyCharIn(CharsArr, Hay) {
    for _, Ch in CharsArr {
        if InStr(Hay, Ch)
            return true
    }
    return false
}

; Pure: return WordStr with the entry's chars toggled — all removed when the
; entry is currently enabled, all added otherwise.
HSE_TerminatorToggleString(WordStr, CharsArr) {
    if HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
        for _, Ch in CharsArr
            WordStr := StrReplace(WordStr, Ch, "")
    } else {
        for _, Ch in CharsArr {
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
        for _, D in HSE_Terminators.all() {
            if (D.Has("type") and D["type"] == "separator")
                continue
            for _, Ch in D["chars"] {
                if !InStr(Kept, Ch)
                    Kept .= Ch
            }
        }
    }
    return Kept
}
