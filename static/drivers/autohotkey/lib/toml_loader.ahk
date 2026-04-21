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




; ========================================================
; ========================================================
; ======= 1/ TOML string and metadata load helpers =======
; ========================================================
; ========================================================

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
    FilePath := A_ScriptDir . "\..\hotstrings\" . CategoryName . ".toml"
    if !FileExist(FilePath) {
        return
    }

    TimeActivationSeconds := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
    TargetSection := StrLower(SectionName)
    CurrentSection := ""

    ; Build once and reuse for every matching entry; individual fields are
    ; overridden per entry below when they differ from the section defaults.
    ; The trailing ``(?:,\s*is_case_sensitive_strict\s*=\s*(true|false)\s*)?``
    ; group makes the strict-case field optional — the generator only emits it
    ; when true, and a missing field must be treated as false by the loader.
    EntryPattern := "^`"((?:[^`"\\]|\\.)+)`"\s*=\s*\{\s*output\s*=\s*`"((?:[^`"\\]|\\.)*)`"\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)\s*(?:,\s*is_case_sensitive_strict\s*=\s*(true|false)\s*)?\}"

    Loop Read, FilePath {
        Line := Trim(A_LoopReadLine, " `t`r`n")
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

        if !RegExMatch(Line, EntryPattern, &Match) {
            continue
        }

        Trigger     := UnescapeTomlString(Match[1])
        Output      := UnescapeTomlString(Match[2])
        ; The TOML stores the magic key as the literal ``★`` character because
        ; that is the default; at runtime the user may have re-bound it via the
        ; tray menu, so translate it back to the current ``ScriptInformation``
        ; value before registering the hotstring.
        Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
        IsWord      := (Match[3] == "true")
        AutoExpand  := (Match[4] == "true")
        IsCaseSens  := (Match[5] == "true")
        FinalResult := (Match[6] == "true")
        ; RegExMatch leaves unmatched optional groups as an empty string in
        ; AHK v2, so compare against "true" — that correctly yields False when
        ; the field is absent from the TOML entry (the generator default).
        StrictCase  := (Match.Count() >= 7 and Match[7] == "true")

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

        if IsCaseSens {
            CreateHotstring(Flags, Trigger, Output, Options)
        } else {
            CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
        }
    }
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
ApplyTomlMetadataToFeatures(CategoryName) {
    FilePath := A_ScriptDir . "\..\hotstrings\" . StrLower(CategoryName) . ".toml"
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

    Loop Read, FilePath {
        Line := Trim(A_LoopReadLine, " `t`r`n")
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
                DescRaw  := UnescapeTomlString(DescMatch[2])
                DescRaw  := StrReplace(DescRaw, "★", ScriptInformation["MagicKey"])
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
        while (Pos <= StrLen(SectionsOrderRaw) and RegExMatch(SectionsOrderRaw, "`"([^`"]*)`"", &TokenMatch, Pos)) {
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
