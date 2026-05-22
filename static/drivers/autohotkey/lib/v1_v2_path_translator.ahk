; lib/v1_v2_path_translator.ahk

; ==============================================================================
; MODULE: V1 to V2 Path Translator
; DESCRIPTION:
; Converts the v1 PascalCase feature paths used by the tray menu
; (``Features["Shortcuts"]["MicrosoftBold"]``, ``Features["Hotstrings.Autocorrection"]
; ["Accents"]``) into the v2 snake_case nested paths persisted to ``config.toml``
; (``[shortcuts] microsoft_bold = …`` / ``[hotstrings.autocorrection.accents]
; enabled = …``). Used by every tray write site so a click toggles the in-memory
; ``FeaturesV2`` state AND emits the canonical v2 TOML key in one call.
;
; FEATURES & RATIONALE:
; 1. Single mapping table per feature category — easy to extend when a new
;    feature is added. Manifest-aligned: every key here matches a manifest
;    entry under ``static/drivers/_shared/features/manifest.toml``.
; 2. ``TranslateV1ToV2(V1Path)`` returns a {section, key, v2_node, ...} struct
;    so callers can write to TOML and mutate ``FeaturesV2`` in lock-step.
; 3. Modélisation α support — entries like Shortcuts.GPT decompose into a v2
;    sub-table (``[shortcuts.gpt]`` with ``enabled`` and ``link``). The
;    translator returns the v2 sub-section path and the leaf key separately.
; ==============================================================================




; ==============================================================
; ==============================================================
; ======= 1/ Mapping tables =======
; ==============================================================
; ==============================================================

; Top-level v1 category -> v2 section path (without the ``ahk.`` prefix; the
; ApplyConfigTomlV2 reader strips it for AHK-only sections).
;
; Hotstrings sub-categories land under ``[hotstrings.<cat>.<entry>]`` and
; emit ``enabled = bool`` as their leaf. Shortcuts sub-Maps land under
; ``[ahk.shortcuts.<group>]`` with the per-key bool as the leaf.

; Map a top-level v1 category name to the corresponding v2 section path
; (used as the section header when emitting individual features that don't
; further nest). Hotstrings sub-categories ("Autocorrection") use a
; per-category table below since their v2 path nests one more level.
global _V1V2_TopCategoryMap := Map(
    "Layout",            "ahk.layout",
    "Gestures",          "ahk.gestures",
    "Shortcuts",         "shortcuts",
    "Autocorrection",    "hotstrings.autocorrection",
    "DistancesReduction", "hotstrings.distances_reduction",
    "SFBsReduction",     "hotstrings.sfbs_reduction",
    "Rolls",             "hotstrings.rolls",
    "MagicKey",          "hotstrings.magic_key",
    "DynamicHotstrings", "hotstrings.dynamic",
    "Personal",          "hotstrings.personal",
)

; Per-category leaf-key rename tables — v1 PascalCase id -> v2 snake_case id.
; Each table is consulted when translating a path like
; ``<TopCategory>.<EntryName>`` (no further nesting).
global _V1V2_LayoutKeyMap := Map(
    "ErgoptiBase",        "ergopti_base",
    "DirectAccessDigits", "direct_access_digits",
    "ErgoptiAltGr",       "ergopti_alt_gr",
    "ErgoptiPlus",        "ergopti_plus",
)

global _V1V2_ShortcutsBoolKeyMap := Map(
    "WrapTextIfSelected",      "wrap_text_if_selected",
    "GetHexValue",             "get_hex_value",
    "MicrosoftBold",           "microsoft_bold",
    "TitleCase",               "title_case",
    "Uppercase",               "uppercase",
    "PasteWithoutFormatting",  "paste_without_formatting",
    "Save",                    "save",
    "SelectLine",              "select_line",
    "SpotlightMouse",          "spotlight_mouse",
    "SurroundWithParentheses", "surround_with_parentheses",
    "TeleportMouse",           "teleport_mouse",
    "CtrlJ",                   "ctrl_j",
    "OpenDownloads",           "open_downloads",
    "Move",                    "move",
    "Screen",                  "screen",
    "ScreenInstant",           "screen_instant",
    "WinCapsLock",             "win_caps_lock",
)

; Modélisation α — v1 PascalCase id -> v2 snake_case id. These entries are
; Map sub-tables in v2 (e.g. ``[shortcuts.gpt] enabled = true; link = "…"``).
global _V1V2_ShortcutsAlphaKeyMap := Map(
    "GPT",      "gpt",
    "Search",   "search",
    "TakeNote", "take_note",
    "EGrave",   "e_grave",
    "ECirc",    "e_circ",
    "EAcute",   "e_acute",
    "AGrave",   "a_grave",
)

; Modélisation α property rename — v1 PascalCase prop -> v2 snake_case key.
global _V1V2_ShortcutsAlphaPropMap := Map(
    "Enabled",              "enabled",
    "Link",                 "link",
    "Letter",               "letter",
    "SearchEngine",         "search_engine",
    "SearchEngineURLQuery", "search_engine_url_query",
    "DatedNotes",           "dated_notes",
    "DestinationFolder",    "destination_folder",
)

; Sub-Map groups under Shortcuts (AltGrLAlt, AltGrCapsLock, LAltCapsLock) —
; each is a 10-key block of plain booleans, persisted at
; ``[ahk.shortcuts.<v2_group>]``.
global _V1V2_ShortcutsSubMapGroupMap := Map(
    "AltGrCapsLock", "ahk.shortcuts.alt_gr_caps_lock",
    "AltGrLAlt",     "ahk.shortcuts.alt_gr_lalt",
    "LAltCapsLock",  "ahk.shortcuts.lalt_caps_lock",
)
global _V1V2_ShortcutsSubMapKeyMap := Map(
    "BackSpace",     "backspace",
    "CapsLock",      "caps_lock",
    "CapsWord",      "caps_word",
    "CtrlBackSpace", "ctrl_backspace",
    "CtrlDelete",    "ctrl_delete",
    "Delete",        "delete",
    "Enter",         "enter",
    "Escape",        "escape",
    "OneShotShift",  "one_shot_shift",
    "Tab",           "tab",
)

global _V1V2_AutocorrectionKeyMap := Map(
    "TypographicApostrophe",     "typographic_apostrophe",
    "Errors",                    "errors",
    "SuffixesAChaining",         "suffixes_a_chaining",
    "Accents",                   "accents",
    "Caps",                      "caps",
    "Names",                     "names",
    "Minus",                     "minus",
    "MinusApostrophe",           "minus_apostrophe",
    "OU",                        "ou",
    "MultiplePunctuationMarks",  "multiple_punctuation_marks",
)

global _V1V2_DistancesReductionKeyMap := Map(
    "QU",                  "qu",
    "SuffixesA",           "suffixes_a",
    "CommaJ",              "comma_j",
    "CommaFarLetters",     "comma_far_letters",
    "DeadKeyECircumflex",  "dead_key_e_circumflex",
    "ECircumflexE",        "e_circumflex_e",
    "SpaceAroundSymbols",  "space_around_symbols",
)

global _V1V2_SFBsReductionKeyMap := Map(
    "Comma",   "comma",
    "ECirc",   "e_circ",
    "EGrave",  "e_grave",
    "BU",      "bu",
    "IÉ",      "i_e_acute",
)

global _V1V2_RollsKeyMap := Map(
    "HC",                     "hc",
    "SX",                     "sx",
    "CX",                     "cx",
    "EnglishNegation",        "english_negation",
    "EZ",                     "ez",
    "CT",                     "ct",
    "CloseChevronTag",        "close_chevron_tag",
    "ChevronLess",            "chevron_less",
    "ChevronGreater",         "chevron_greater",
    "ChevronEqual",           "chevron_equal",
    "CommentOpen",            "comment_open",
    "CommentClose",           "comment_close",
    "Assign",                 "assign",
    "NotEqual",               "not_equal",
    "ParenQuote",             "paren_quote",
    "BracketQuote",           "bracket_quote",
    "HashtagParenthesis",     "hashtag_parenthesis",
    "HashtagOpenBracket",     "hashtag_open_bracket",
    "HashtagCloseBracket",    "hashtag_close_bracket",
    "HashtagQuote",           "hashtag_quote",
    "EqualString",            "equal_string",
    "LeftArrow",              "left_arrow",
    "AssignArrowEqualRight",  "assign_arrow_equal_right",
    "AssignArrowEqualLeft",   "assign_arrow_equal_left",
    "AssignArrowMinusRight",  "assign_arrow_minus_right",
    "AssignArrowMinusLeft",   "assign_arrow_minus_left",
)

global _V1V2_MagicKeyKeyMap := Map(
    "Replace",                    "replace",
    "RepeatCorrections",          "repeat_corrections",
    "TextExpansion",              "text_expansion",
    "TextExpansionAuto",          "text_expansion_auto",
    "TextExpansionEmojis",        "text_expansion_emojis",
    "TextExpansionSymbols",       "text_expansion_symbols",
    "TextExpansionSymbolsTypst",  "text_expansion_symbols_typst",
)

global _V1V2_DynamicHotstringsKeyMap := Map(
    "Date",                              "date",
    "DateFr",                            "date_fr",
    "DateLongFr",                        "date_long_fr",
    "IbanPrefixes",                      "iban_prefixes",
    "PhonePrefixes",                     "phone_prefixes",
    "SsnPrefixes",                       "ssn_prefixes",
    "TextExpansionPersonalInformation",  "text_expansion_personal_information",
)




; ==============================================================
; ==============================================================
; ======= 1bis/ Inverse lookup helpers =======
; ==============================================================
; ==============================================================

; Build the inverse of a v1->v2 rename Map by swapping keys and values once at
; load time. The menu builder consumes the inverse direction to translate
; manifest entries (snake_case v2 ids) back to the v1 PascalCase paths still
; used as identifiers in tray-write callbacks.
_BuildInverseRenameMap(Forward) {
    Out := Map()
    for K, V in Forward {
        Out[V] := K
    }
    return Out
}

global _V2V1_LayoutKeyMap                := _BuildInverseRenameMap(_V1V2_LayoutKeyMap)
global _V2V1_ShortcutsBoolKeyMap         := _BuildInverseRenameMap(_V1V2_ShortcutsBoolKeyMap)
global _V2V1_ShortcutsAlphaKeyMap        := _BuildInverseRenameMap(_V1V2_ShortcutsAlphaKeyMap)
global _V2V1_ShortcutsSubMapGroupMap     := _BuildInverseRenameMap(_V1V2_ShortcutsSubMapGroupMap)
global _V2V1_ShortcutsSubMapKeyMap       := _BuildInverseRenameMap(_V1V2_ShortcutsSubMapKeyMap)
global _V2V1_AutocorrectionKeyMap        := _BuildInverseRenameMap(_V1V2_AutocorrectionKeyMap)
global _V2V1_DistancesReductionKeyMap    := _BuildInverseRenameMap(_V1V2_DistancesReductionKeyMap)
global _V2V1_SFBsReductionKeyMap         := _BuildInverseRenameMap(_V1V2_SFBsReductionKeyMap)
global _V2V1_RollsKeyMap                 := _BuildInverseRenameMap(_V1V2_RollsKeyMap)
global _V2V1_MagicKeyKeyMap              := _BuildInverseRenameMap(_V1V2_MagicKeyKeyMap)
global _V2V1_DynamicHotstringsKeyMap     := _BuildInverseRenameMap(_V1V2_DynamicHotstringsKeyMap)

; Translate a v1 dotted feature path (e.g. ``Layout.ErgoptiBase``,
; ``Shortcuts.MicrosoftBold``, ``Shortcuts.AltGrLAlt.BackSpace``) into the
; canonical v2 manifest path (``ahk.layout.ergopti_base``, ``shortcuts.microsoft_bold``,
; ``ahk.shortcuts.alt_gr_lalt.backspace``). Used by the menu builder to
; locate the corresponding manifest entry (for description_key resolution)
; without going through the full TranslateV1ToV2 dispatcher which is
; tailored for write ops.
;
; Returns "" when the v1 path has no manifest counterpart (e.g. TapHolds
; or runtime-discovered Personal entries).
V1PathToV2ManifestPath(V1Path) {
    Loc := TranslateV1ToV2(V1Path . ".Enabled")
    if (Loc == false) {
        return ""
    }
    Section := Loc["section"]
    K := Loc["key"]
    if Loc["is_alpha"] {
        ; Modélisation α — the section path already encodes the entry id.
        return Section
    }
    ; Plain bool / sub-Map leaf — append the leaf key.
    return Section . "." . K
}

; Translate the v2 manifest path of a feature entry (e.g. ``ahk.layout.ergopti_base``,
; ``shortcuts.microsoft_bold``, ``hotstrings.autocorrection.accents``) into the
; v1 dotted feature path the tray-write callbacks expect
; (``Layout.ErgoptiBase``, ``Shortcuts.MicrosoftBold``, ``Autocorrection.Accents``).
;
; Returns "" when the v2 path does not have a v1 counterpart in the rename
; tables (e.g. runtime-discovered Personal entries — those keep their
; lowercase id verbatim under ``Personal.<id>`` already).
V2PathToV1Path(V2Path) {
    global _V2V1_LayoutKeyMap, _V2V1_ShortcutsBoolKeyMap
    global _V2V1_ShortcutsAlphaKeyMap, _V2V1_ShortcutsSubMapGroupMap
    global _V2V1_ShortcutsSubMapKeyMap, _V2V1_AutocorrectionKeyMap
    global _V2V1_DistancesReductionKeyMap, _V2V1_SFBsReductionKeyMap
    global _V2V1_RollsKeyMap, _V2V1_MagicKeyKeyMap, _V2V1_DynamicHotstringsKeyMap

    Parts := StrSplit(V2Path, ".")
    if (Parts.Length < 2) {
        return ""
    }

    ; Strip leading ``ahk.`` so the dispatch below works on both bare
    ; ``layout.x`` and ``ahk.layout.x`` shapes.
    if (Parts[1] == "ahk") {
        NewParts := []
        Loop Parts.Length - 1 {
            NewParts.Push(Parts[A_Index + 1])
        }
        Parts := NewParts
    }
    if (Parts.Length < 2) {
        return ""
    }

    Top := Parts[1]

    ; ── Layout ────────────────────────────────────────────────
    if (Top == "layout" and Parts.Length == 2 and _V2V1_LayoutKeyMap.Has(Parts[2])) {
        return "Layout." . _V2V1_LayoutKeyMap[Parts[2]]
    }

    ; ── Gestures master toggle ────────────────────────────────
    if (Top == "gestures" and Parts.Length == 2 and Parts[2] == "enabled") {
        return "Gestures.Enabled"
    }

    ; ── Shortcuts ────────────────────────────────────────────
    if (Top == "shortcuts") {
        ; Plain bool: shortcuts.<id>
        if (Parts.Length == 2 and _V2V1_ShortcutsBoolKeyMap.Has(Parts[2])) {
            return "Shortcuts." . _V2V1_ShortcutsBoolKeyMap[Parts[2]]
        }
        ; Modélisation α: shortcuts.<alpha> (legacy callbacks toggle .Enabled)
        if (Parts.Length == 2 and _V2V1_ShortcutsAlphaKeyMap.Has(Parts[2])) {
            return "Shortcuts." . _V2V1_ShortcutsAlphaKeyMap[Parts[2]]
        }
        ; Sub-Map group: shortcuts.<group>.<key>
        if (Parts.Length == 3 and _V2V1_ShortcutsSubMapGroupMap.Has(Parts[2])
            and _V2V1_ShortcutsSubMapKeyMap.Has(Parts[3])) {
            return "Shortcuts." . _V2V1_ShortcutsSubMapGroupMap[Parts[2]]
                . "." . _V2V1_ShortcutsSubMapKeyMap[Parts[3]]
        }
        return ""
    }

    ; ── Hotstrings categories ────────────────────────────────
    if (Top == "hotstrings" and Parts.Length == 3) {
        V2Cat := Parts[2]
        V2Id  := Parts[3]
        switch V2Cat {
            case "autocorrection":
                if _V2V1_AutocorrectionKeyMap.Has(V2Id)
                    return "Autocorrection." . _V2V1_AutocorrectionKeyMap[V2Id]
            case "distances_reduction":
                if _V2V1_DistancesReductionKeyMap.Has(V2Id)
                    return "DistancesReduction." . _V2V1_DistancesReductionKeyMap[V2Id]
            case "sfbs_reduction":
                if _V2V1_SFBsReductionKeyMap.Has(V2Id)
                    return "SFBsReduction." . _V2V1_SFBsReductionKeyMap[V2Id]
            case "rolls":
                if _V2V1_RollsKeyMap.Has(V2Id)
                    return "Rolls." . _V2V1_RollsKeyMap[V2Id]
            case "magic_key":
                if _V2V1_MagicKeyKeyMap.Has(V2Id)
                    return "MagicKey." . _V2V1_MagicKeyKeyMap[V2Id]
            case "dynamic":
                if _V2V1_DynamicHotstringsKeyMap.Has(V2Id)
                    return "DynamicHotstrings." . _V2V1_DynamicHotstringsKeyMap[V2Id]
            case "personal":
                ; Runtime-discovered — the v2 id IS the v1 PascalCase tail
                ; lowercased; keep it verbatim. The menu walker handles
                ; runtime-only paths separately via ``Features["Personal"]``
                ; for now.
                return "Personal." . V2Id
        }
    }

    return ""
}




; ==============================================================
; ==============================================================
; ======= 2/ TranslateV1ToV2 =======
; ==============================================================
; ==============================================================

; Translate a dotted v1 path (as used by ``GetFeatureByPath`` in
; ui/tray_menu.ahk) into the v2 location info needed to mutate FeaturesV2
; and emit the canonical v2 TOML section.
;
; Returns a Map with:
;   "section"  -> v2 section header, e.g. "shortcuts" or "ahk.shortcuts.alt_gr_lalt"
;                  or "hotstrings.autocorrection.accents"
;   "key"      -> v2 leaf key, e.g. "microsoft_bold", "backspace", "enabled"
;   "v2_node"  -> FeaturesV2 sub-Map containing the leaf (for in-memory mutation)
;   "is_alpha" -> true if the v2 entry is a Map (Modélisation α with .enabled
;                  sub-key); false if the leaf is a plain bool at section level.
;
; Returns ``false`` when the v1 path doesn't have a known v2 equivalent.
TranslateV1ToV2(V1Path) {
    global FeaturesV2
    global _V1V2_TopCategoryMap, _V1V2_LayoutKeyMap
    global _V1V2_ShortcutsBoolKeyMap, _V1V2_ShortcutsAlphaKeyMap
    global _V1V2_ShortcutsSubMapGroupMap, _V1V2_ShortcutsSubMapKeyMap
    global _V1V2_AutocorrectionKeyMap, _V1V2_DistancesReductionKeyMap
    global _V1V2_SFBsReductionKeyMap, _V1V2_RollsKeyMap
    global _V1V2_MagicKeyKeyMap, _V1V2_DynamicHotstringsKeyMap

    if !IsSet(FeaturesV2) {
        return false
    }

    Parts := StrSplit(V1Path, ".")
    ; Strip an implicit trailing ``.Enabled`` — the v1 tray-write call sites
    ; append ``.Enabled`` to every path uniformly, but plain-bool features
    ; (Shortcuts.MicrosoftBold), Layout flags and sub-Map leaves
    ; (Shortcuts.AltGrLAlt.BackSpace) treat it as a no-op suffix in v1's
    ; flattened schema. Strip it here so the per-category branches below
    ; can match on the natural path length.
    ;
    ; Length-3 minimum guard: don't strip on "Gestures.Enabled" or any other
    ; "<Category>.Enabled" path where "Enabled" IS the leaf feature id
    ; (Gestures.Enabled is the master gate in v1 Features). Only strip when
    ; the residual still has 2+ segments after the strip, i.e. the original
    ; had 3+ parts.
    if (Parts.Length >= 3 and Parts[Parts.Length] == "Enabled") {
        Parts.RemoveAt(Parts.Length)
    }
    if (Parts.Length < 2) {
        return false
    }
    Top := Parts[1]

    ; ── Layout (flat) ─────────────────────────────────────────
    if (Top == "Layout") {
        V1Key := Parts[2]
        if !_V1V2_LayoutKeyMap.Has(V1Key) {
            return false
        }
        V2Key := _V1V2_LayoutKeyMap[V1Key]
        if !FeaturesV2.Has("layout") {
            return false
        }
        return Map(
            "section", "ahk.layout",
            "key",     V2Key,
            "v2_node", FeaturesV2["layout"],
            "is_alpha", false,
        )
    }

    ; ── Gestures master toggle ────────────────────────────────
    if (Top == "Gestures") {
        V1Key := Parts[2]
        if (V1Key == "Enabled") {
            if !FeaturesV2.Has("gestures") {
                return false
            }
            return Map(
                "section", "ahk.gestures",
                "key",     "enabled",
                "v2_node", FeaturesV2["gestures"],
                "is_alpha", false,
            )
        }
        return false
    }

    ; ── Shortcuts (mix of plain bools, Modélisation α and sub-Maps) ──
    if (Top == "Shortcuts") {
        if !FeaturesV2.Has("shortcuts") {
            return false
        }
        V1Key := Parts[2]

        ; Personal sub-Map: user-defined hotkeys registered via
        ; RegisterPersonalFeature. Their ids are user-controlled so we
        ; preserve them verbatim under [ahk.shortcuts.personal].
        if (V1Key == "Personal" and Parts.Length >= 3) {
            if !FeaturesV2["shortcuts"].Has("personal") or !IsObject(FeaturesV2["shortcuts"]["personal"]) {
                FeaturesV2["shortcuts"]["personal"] := Map()
            }
            UserName := Parts[3]
            if !FeaturesV2["shortcuts"]["personal"].Has(UserName) {
                FeaturesV2["shortcuts"]["personal"][UserName] := false
            }
            return Map(
                "section", "ahk.shortcuts.personal",
                "key",     UserName,
                "v2_node", FeaturesV2["shortcuts"]["personal"],
                "is_alpha", false,
            )
        }

        ; Sub-Map case: Shortcuts.<Group>.<Key>
        if (Parts.Length == 3 and _V1V2_ShortcutsSubMapGroupMap.Has(V1Key)) {
            V2Section := _V1V2_ShortcutsSubMapGroupMap[V1Key]
            V1SubKey := Parts[3]
            if !_V1V2_ShortcutsSubMapKeyMap.Has(V1SubKey) {
                return false
            }
            V2Key := _V1V2_ShortcutsSubMapKeyMap[V1SubKey]
            ; Walk to FeaturesV2["shortcuts"][<v2_group>]
            V2GroupKey := StrSplit(V2Section, ".")[3]   ; "alt_gr_caps_lock" / ...
            if !FeaturesV2["shortcuts"].Has(V2GroupKey) {
                return false
            }
            return Map(
                "section", V2Section,
                "key",     V2Key,
                "v2_node", FeaturesV2["shortcuts"][V2GroupKey],
                "is_alpha", false,
            )
        }

        ; Modélisation α case: Shortcuts.<Alpha>.<Prop> or Shortcuts.<Alpha>
        if _V1V2_ShortcutsAlphaKeyMap.Has(V1Key) {
            V2Sub := _V1V2_ShortcutsAlphaKeyMap[V1Key]
            if !FeaturesV2["shortcuts"].Has(V2Sub) {
                return false
            }
            ; Path is Shortcuts.<Alpha> alone — points at the .enabled flag
            ; (the tray "ToggleMenuVariableByPath" mutates .Enabled for these
            ; whole-feature toggles).
            if (Parts.Length == 2) {
                return Map(
                    "section", "shortcuts." V2Sub,
                    "key",     "enabled",
                    "v2_node", FeaturesV2["shortcuts"][V2Sub],
                    "is_alpha", true,
                )
            }
            ; Path is Shortcuts.<Alpha>.<Prop> — explicit property mutation.
            V1Prop := Parts[3]
            if !_V1V2_ShortcutsAlphaPropMap.Has(V1Prop) {
                return false
            }
            V2Prop := _V1V2_ShortcutsAlphaPropMap[V1Prop]
            return Map(
                "section", "shortcuts." V2Sub,
                "key",     V2Prop,
                "v2_node", FeaturesV2["shortcuts"][V2Sub],
                "is_alpha", true,
            )
        }

        ; Plain bool: Shortcuts.<V1Key>
        if _V1V2_ShortcutsBoolKeyMap.Has(V1Key) {
            V2Key := _V1V2_ShortcutsBoolKeyMap[V1Key]
            return Map(
                "section", "shortcuts",
                "key",     V2Key,
                "v2_node", FeaturesV2["shortcuts"],
                "is_alpha", false,
            )
        }

        return false
    }

    ; ── Hotstrings categories ─────────────────────────────────
    if !FeaturesV2.Has("hotstrings") {
        return false
    }
    V1Cat := Top
    KeyMap := false
    V2Cat := false
    switch V1Cat {
        case "Autocorrection":
            KeyMap := _V1V2_AutocorrectionKeyMap
            V2Cat := "autocorrection"
        case "DistancesReduction":
            KeyMap := _V1V2_DistancesReductionKeyMap
            V2Cat := "distances_reduction"
        case "SFBsReduction":
            KeyMap := _V1V2_SFBsReductionKeyMap
            V2Cat := "sfbs_reduction"
        case "Rolls":
            KeyMap := _V1V2_RollsKeyMap
            V2Cat := "rolls"
        case "MagicKey":
            KeyMap := _V1V2_MagicKeyKeyMap
            V2Cat := "magic_key"
        case "DynamicHotstrings":
            KeyMap := _V1V2_DynamicHotstringsKeyMap
            V2Cat := "dynamic"
    }
    if (KeyMap != false) {
        V1Key := Parts[2]
        if !KeyMap.Has(V1Key) {
            return false
        }
        V2Id := KeyMap[V1Key]
        if !FeaturesV2["hotstrings"].Has(V2Cat) {
            return false
        }
        if !FeaturesV2["hotstrings"][V2Cat].Has(V2Id) {
            return false
        }
        ; Each hotstring entry is a Map with .enabled — Modélisation α.
        return Map(
            "section", "hotstrings." V2Cat "." V2Id,
            "key",     "enabled",
            "v2_node", FeaturesV2["hotstrings"][V2Cat][V2Id],
            "is_alpha", true,
        )
    }

    ; ── Personal (runtime-discovered hotstrings sections) ────
    if (V1Cat == "Personal") {
        if !FeaturesV2["hotstrings"].Has("personal") {
            return false
        }
        ; V1Key is the PascalCase section name; the v2 key is the lowercase
        ; TOML section name. Try .TomlSection from the Features v1 entry
        ; first; fall back to lowercased PascalCase.
        global Features
        V1Key := Parts[2]
        V2Id := StrLower(V1Key)
        if IsSet(Features) and Features.Has("Personal")
            and Features["Personal"].Has(V1Key) {
            V1Val := Features["Personal"][V1Key]
            if IsObject(V1Val) and V1Val.HasOwnProp("TomlSection") {
                V2Id := V1Val.TomlSection
            }
        }
        if !FeaturesV2["hotstrings"]["personal"].Has(V2Id) {
            ; Lazily seed the v2 personal entry so the first toggle on a
            ; runtime-discovered section can persist.
            FeaturesV2["hotstrings"]["personal"][V2Id] := Map("enabled", true)
        }
        return Map(
            "section", "hotstrings.personal." V2Id,
            "key",     "enabled",
            "v2_node", FeaturesV2["hotstrings"]["personal"][V2Id],
            "is_alpha", true,
        )
    }

    return false
}




; ==============================================================
; ==============================================================
; ======= 3/ WriteV2Update / WriteV2BatchFromV1Paths =======
; ==============================================================
; ==============================================================

; Apply a single v1-path mutation to both the in-memory FeaturesV2 Map and
; the on-disk config.toml. Returns true on success.
;
; ``V1Path``  — dotted v1 feature path (e.g. "Shortcuts.MicrosoftBold").
; ``Value``   — the new value (typically a bool, sometimes a string for
;                ``letter`` / ``link`` / etc.).
WriteV2Update(V1Path, Value) {
    global ConfigurationFile
    Loc := TranslateV1ToV2(V1Path)
    if (Loc == false) {
        try LoggerWarn("V1V2Translator",
            "WriteV2Update: no v2 equivalent for '{1}' — skipped.", V1Path)
        return false
    }
    ; Mutate FeaturesV2 in memory.
    V2Node := Loc["v2_node"]
    K := Loc["key"]
    if (Type(V2Node) == "Map") {
        V2Node[K] := Value
    } else if IsObject(V2Node) {
        try V2Node.%K% := Value
    }
    ; Persist to disk.
    TOML_Write(Value, ConfigurationFile, Loc["section"], K)
    return true
}

; Read the runtime state of a feature from FeaturesV2 via the path translator.
; Returns a Map keyed by v1 PascalCase property names (Enabled, Letter, Link,
; SearchEngine, DatedNotes, …) — only keys present in the v2 node are populated,
; so callers can use ``State.Has("Letter")`` exactly like the legacy
; ``Feature.HasOwnProp("Letter")`` check on the v1 Features Map.
;
; Returns an empty Map when the v1 path has no v2 equivalent (e.g. TapHolds or
; runtime-discovered Personal entries). Callers must fall back to whatever
; default makes sense for that case.
GetFeatureV2State(V1Path) {
    State := Map()
    Loc := TranslateV1ToV2(V1Path . ".Enabled")
    if (Loc == false) {
        return State
    }
    V2Node := Loc["v2_node"]
    if !IsObject(V2Node) {
        return State
    }

    if Loc["is_alpha"] {
        ; Modélisation α — v2 node is a Map with named keys.
        if (V2Node.Has("enabled")) {
            State["Enabled"] := (V2Node["enabled"] = true)
        }
        if (V2Node.Has("letter")) {
            State["Letter"] := V2Node["letter"]
        }
        if (V2Node.Has("link")) {
            State["Link"] := V2Node["link"]
        }
        if (V2Node.Has("search_engine")) {
            State["SearchEngine"] := V2Node["search_engine"]
        }
        if (V2Node.Has("search_engine_url_query")) {
            State["SearchEngineURLQuery"] := V2Node["search_engine_url_query"]
        }
        if (V2Node.Has("dated_notes")) {
            State["DatedNotes"] := (V2Node["dated_notes"] = true)
        }
        if (V2Node.Has("destination_folder")) {
            State["DestinationFolder"] := V2Node["destination_folder"]
        }
        if (V2Node.Has("pattern_max_length")) {
            State["PatternMaxLength"] := V2Node["pattern_max_length"]
        }
    } else {
        ; Plain bool or sub-Map leaf — Enabled is the value at the leaf key.
        K := Loc["key"]
        if (Type(V2Node) == "Map" and V2Node.Has(K)) {
            State["Enabled"] := (V2Node[K] = true)
        }
    }
    return State
}

; Apply a batch of v1-path mutations atomically (single TOML_BatchWrite).
; Each entry is a Map("v1_path"=>"…", "value"=>…).
WriteV2Batch(Entries) {
    global ConfigurationFile
    Updates := []
    for Entry in Entries {
        Loc := TranslateV1ToV2(Entry["v1_path"])
        if (Loc == false) {
            try LoggerWarn("V1V2Translator",
                "WriteV2Batch: no v2 equivalent for '{1}' — skipped.", Entry["v1_path"])
            continue
        }
        V2Node := Loc["v2_node"]
        K := Loc["key"]
        Val := Entry["value"]
        if (Type(V2Node) == "Map") {
            V2Node[K] := Val
        } else if IsObject(V2Node) {
            try V2Node.%K% := Val
        }
        Updates.Push({ Section: Loc["section"], Key: K, Value: Val })
    }
    if (Updates.Length > 0) {
        TOML_BatchWrite(ConfigurationFile, Updates)
    }
    return Updates.Length
}
