; lib/v2_v1_mirror.ahk

; ==============================================================================
; MODULE: V2 to V1 Features reverse mirror
; DESCRIPTION:
; ``FeaturesV2`` is the canonical on-disk source: ``ApplyConfigTomlV2``
; hydrates the v2 Map from the user's ``config.toml``. The legacy
; ``Features`` Map still backs the tray-menu rendering
; (``GetFeatureByPath``, ``MenuAddItem`` checkmark logic), so this module
; pushes the v2 state onto v1 once per boot so the menu reflects the
; user's persisted choices.
;
; FEATURES & RATIONALE:
; 1. Single-direction sync v2 -> v1: writes flow v2 (tray-menu mutates
;    ``FeaturesV2`` + writes the v2 TOML section + Reload). The Reload then
;    re-runs this module which restores the v1 mirror — divergence impossible.
; 2. Master gate is NOT applied here: ``Features[X].Enabled`` always carries
;    the user's raw choice so the menu checkmarks match what they last
;    clicked, even when the master category gate is off. The gate is applied
;    separately by ``ApplyMasterGatesToFeaturesV2`` so #HotIf evaluations on
;    FeaturesV2 disable the behaviors without disturbing the menu state.
; 3. Per-section helpers stay explicit so each chunk has its own reviewable
;    diff — ``MirrorV2ToV1_<Section>``. They will all disappear together when
;    the v1 ``Features`` Map itself is finally retired (separate slice).
; ==============================================================================




; ==============================================================
; ==============================================================
; ======= 1/ Layout =======
; ==============================================================
; ==============================================================

MirrorV2ToV1_Layout() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Layout skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Layout") or !FeaturesV2.Has("layout") {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Layout skipped — section missing in v1 or v2.")
        return
    }

    Pairs := Map(
        "ergopti_base",        "ErgoptiBase",
        "direct_access_digits", "DirectAccessDigits",
        "ergopti_alt_gr",       "ErgoptiAltGr",
        "ergopti_plus",         "ErgoptiPlus",
    )

    Copied := 0
    for V2Id, V1Id in Pairs {
        if !FeaturesV2["layout"].Has(V2Id) {
            continue
        }
        V2Val := FeaturesV2["layout"][V2Id]
        if !Features["Layout"].Has(V1Id) {
            continue
        }
        V1Entry := Features["Layout"][V1Id]
        if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
            continue
        }
        V1Entry.Enabled := (V2Val = true)
        Copied += 1
    }

    try LoggerDebug("V2ToV1",
        "MirrorV2ToV1_Layout copied {1} entry(ies) v2 -> v1.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 2/ Gestures =======
; ==============================================================
; ==============================================================

; Mirrors ``FeaturesV2["gestures"]["enabled"]`` -> ``Features["Gestures"]["Enabled"].Enabled``.
; Gesture slot assignments (swipe_3_*, swipe_4_*, tap_3, tap_4) live in the
; separate ``GestureAssignments`` global populated by modules/gestures.ahk
; directly from the [ahk.gestures] section — not handled here.
MirrorV2ToV1_Gestures() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Gestures skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Gestures") or !FeaturesV2.Has("gestures") {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Gestures skipped — section missing in v1 or v2.")
        return
    }
    if !Features["Gestures"].Has("Enabled") or !FeaturesV2["gestures"].Has("enabled") {
        return
    }

    V1Entry := Features["Gestures"]["Enabled"]
    if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
        return
    }
    V1Entry.Enabled := (FeaturesV2["gestures"]["enabled"] = true)
    try LoggerDebug("V2ToV1", "MirrorV2ToV1_Gestures copied 1 entry v2 -> v1.")
}




; ==============================================================
; ==============================================================
; ======= 3/ Shortcuts =======
; ==============================================================
; ==============================================================

; Mirrors every v2 Shortcuts entry onto its v1 Features["Shortcuts"]
; counterpart so the tray-menu builder finds the right .Enabled value.
; Covers plain-bool entries, Modélisation α entries (gpt/search/take_note
; + letter pickers e_grave/e_circ/e_acute/a_grave), and sub-Map groups
; (alt_gr_caps_lock / alt_gr_lalt / lalt_caps_lock).
MirrorV2ToV1_Shortcuts() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Shortcuts skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Shortcuts") or !FeaturesV2.Has("shortcuts") {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Shortcuts skipped — section missing in v1 or v2.")
        return
    }

    BoolPairs := Map(
        "wrap_text_if_selected",     "WrapTextIfSelected",
        "get_hex_value",             "GetHexValue",
        "microsoft_bold",            "MicrosoftBold",
        "title_case",                "TitleCase",
        "uppercase",                 "Uppercase",
        "paste_without_formatting",  "PasteWithoutFormatting",
        "save",                      "Save",
        "select_line",               "SelectLine",
        "spotlight_mouse",           "SpotlightMouse",
        "surround_with_parentheses", "SurroundWithParentheses",
        "teleport_mouse",            "TeleportMouse",
        "ctrl_j",                    "CtrlJ",
        "open_downloads",            "OpenDownloads",
        "move",                      "Move",
        "screen",                    "Screen",
        "screen_instant",            "ScreenInstant",
        "win_caps_lock",             "WinCapsLock",
    )

    Copied := 0
    for V2Id, V1Id in BoolPairs {
        if !FeaturesV2["shortcuts"].Has(V2Id) {
            continue
        }
        if !Features["Shortcuts"].Has(V1Id) {
            continue
        }
        V1Entry := Features["Shortcuts"][V1Id]
        if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
            continue
        }
        V1Entry.Enabled := (FeaturesV2["shortcuts"][V2Id] = true)
        Copied += 1
    }

    ; Modélisation α — Map entries with extra named props.
    ; v2 shape: FeaturesV2["shortcuts"]["gpt"]["enabled"|"link"]
    ; v1 shape: Features["Shortcuts"]["GPT"].Enabled / .Link
    AlphaPairs := Map(
        "gpt",      Map("v1", "GPT",      "props", Map("enabled", "Enabled", "link", "Link")),
        "search",   Map("v1", "Search",   "props", Map("enabled", "Enabled",
                                                       "search_engine", "SearchEngine",
                                                       "search_engine_url_query", "SearchEngineURLQuery")),
        "take_note", Map("v1", "TakeNote", "props", Map("enabled", "Enabled",
                                                        "dated_notes", "DatedNotes",
                                                        "destination_folder", "DestinationFolder")),
        "e_grave",  Map("v1", "EGrave",   "props", Map("enabled", "Enabled", "letter", "Letter")),
        "e_circ",   Map("v1", "ECirc",    "props", Map("enabled", "Enabled", "letter", "Letter")),
        "e_acute",  Map("v1", "EAcute",   "props", Map("enabled", "Enabled", "letter", "Letter")),
        "a_grave",  Map("v1", "AGrave",   "props", Map("enabled", "Enabled", "letter", "Letter")),
    )

    for V2Id, Spec in AlphaPairs {
        if !FeaturesV2["shortcuts"].Has(V2Id) or !IsObject(FeaturesV2["shortcuts"][V2Id]) {
            continue
        }
        V1Id := Spec["v1"]
        if !Features["Shortcuts"].Has(V1Id) {
            continue
        }
        V1Entry := Features["Shortcuts"][V1Id]
        if !IsObject(V1Entry) {
            continue
        }
        for V2Key, V1Prop in Spec["props"] {
            if !FeaturesV2["shortcuts"][V2Id].Has(V2Key) {
                continue
            }
            if !V1Entry.HasOwnProp(V1Prop) {
                continue
            }
            V2Val := FeaturesV2["shortcuts"][V2Id][V2Key]
            if (V2Key == "enabled") {
                V1Entry.%V1Prop% := (V2Val = true)
            } else {
                V1Entry.%V1Prop% := V2Val
            }
            Copied += 1
        }
    }

    ; Sub-Maps — 10 entries per group, all bool.
    SubKeyMap := Map(
        "backspace",      "BackSpace",
        "caps_lock",      "CapsLock",
        "caps_word",      "CapsWord",
        "ctrl_backspace", "CtrlBackSpace",
        "ctrl_delete",    "CtrlDelete",
        "delete",         "Delete",
        "enter",          "Enter",
        "escape",         "Escape",
        "one_shot_shift", "OneShotShift",
        "tab",            "Tab",
    )
    SubMaps := Map(
        "alt_gr_caps_lock", "AltGrCapsLock",
        "alt_gr_lalt",      "AltGrLAlt",
        "lalt_caps_lock",   "LAltCapsLock",
    )
    for V2Group, V1Group in SubMaps {
        if !FeaturesV2["shortcuts"].Has(V2Group) or !IsObject(FeaturesV2["shortcuts"][V2Group]) {
            continue
        }
        if !Features["Shortcuts"].Has(V1Group) {
            continue
        }
        V1SubMap := Features["Shortcuts"][V1Group]
        if !IsObject(V1SubMap) {
            continue
        }
        for V2Key, V1Key in SubKeyMap {
            if !FeaturesV2["shortcuts"][V2Group].Has(V2Key) {
                continue
            }
            if !V1SubMap.Has(V1Key) {
                continue
            }
            V1Entry := V1SubMap[V1Key]
            if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
                continue
            }
            V1Entry.Enabled := (FeaturesV2["shortcuts"][V2Group][V2Key] = true)
            Copied += 1
        }
    }

    try LoggerDebug("V2ToV1",
        "MirrorV2ToV1_Shortcuts copied {1} entry(ies) v2 -> v1.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 4/ Hotstrings (all 6 categories) =======
; ==============================================================
; ==============================================================

; Mirrors every v2 hotstring category onto v1 Features. v2 nests them at
; FeaturesV2["hotstrings"][<cat>][<entry>]["enabled"]; v1 stores them as
; top-level Features[<v1_cat>][<v1_entry>].Enabled.
MirrorV2ToV1_Hotstrings() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Hotstrings skipped — Features or FeaturesV2 unset.")
        return
    }
    if !FeaturesV2.Has("hotstrings") {
        try LoggerWarn("V2ToV1",
            "MirrorV2ToV1_Hotstrings skipped — FeaturesV2['hotstrings'] missing.")
        return
    }

    ; Same mapping table as the forward mirror, reused inverted.
    Categories := Map(
        "autocorrection", Map(
            "_v1_cat", "Autocorrection",
            "typographic_apostrophe",     "TypographicApostrophe",
            "errors",                     "Errors",
            "suffixes_a_chaining",        "SuffixesAChaining",
            "accents",                    "Accents",
            "caps",                       "Caps",
            "names",                      "Names",
            "minus",                      "Minus",
            "minus_apostrophe",           "MinusApostrophe",
            "ou",                         "OU",
            "multiple_punctuation_marks", "MultiplePunctuationMarks",
        ),
        "distances_reduction", Map(
            "_v1_cat", "DistancesReduction",
            "qu",                   "QU",
            "suffixes_a",           "SuffixesA",
            "comma_j",              "CommaJ",
            "comma_far_letters",    "CommaFarLetters",
            "dead_key_e_circumflex", "DeadKeyECircumflex",
            "e_circumflex_e",       "ECircumflexE",
            "space_around_symbols", "SpaceAroundSymbols",
        ),
        "sfbs_reduction", Map(
            "_v1_cat", "SFBsReduction",
            "comma",     "Comma",
            "e_circ",    "ECirc",
            "e_grave",   "EGrave",
            "bu",        "BU",
            "i_e_acute", "IÉ",
        ),
        "rolls", Map(
            "_v1_cat", "Rolls",
            "hc",                       "HC",
            "sx",                       "SX",
            "cx",                       "CX",
            "english_negation",         "EnglishNegation",
            "ez",                       "EZ",
            "ct",                       "CT",
            "close_chevron_tag",        "CloseChevronTag",
            "chevron_less",             "ChevronLess",
            "chevron_greater",          "ChevronGreater",
            "chevron_equal",            "ChevronEqual",
            "comment_open",             "CommentOpen",
            "comment_close",            "CommentClose",
            "assign",                   "Assign",
            "not_equal",                "NotEqual",
            "paren_quote",              "ParenQuote",
            "bracket_quote",            "BracketQuote",
            "hashtag_parenthesis",      "HashtagParenthesis",
            "hashtag_open_bracket",     "HashtagOpenBracket",
            "hashtag_close_bracket",    "HashtagCloseBracket",
            "hashtag_quote",            "HashtagQuote",
            "equal_string",             "EqualString",
            "left_arrow",               "LeftArrow",
            "assign_arrow_equal_right", "AssignArrowEqualRight",
            "assign_arrow_equal_left",  "AssignArrowEqualLeft",
            "assign_arrow_minus_right", "AssignArrowMinusRight",
            "assign_arrow_minus_left",  "AssignArrowMinusLeft",
        ),
        "magic_key", Map(
            "_v1_cat", "MagicKey",
            "replace",                       "Replace",
            "repeat_corrections",            "RepeatCorrections",
            "text_expansion",                "TextExpansion",
            "text_expansion_auto",           "TextExpansionAuto",
            "text_expansion_emojis",         "TextExpansionEmojis",
            "text_expansion_symbols",        "TextExpansionSymbols",
            "text_expansion_symbols_typst",  "TextExpansionSymbolsTypst",
        ),
        "dynamic", Map(
            "_v1_cat", "DynamicHotstrings",
            "date",          "Date",
            "date_fr",       "DateFr",
            "date_long_fr",  "DateLongFr",
            "iban_prefixes", "IbanPrefixes",
            "phone_prefixes", "PhonePrefixes",
            "ssn_prefixes",  "SsnPrefixes",
            "text_expansion_personal_information", "TextExpansionPersonalInformation",
        ),
    )

    Copied := 0
    for V2Cat, IdMap in Categories {
        if !FeaturesV2["hotstrings"].Has(V2Cat) or !IsObject(FeaturesV2["hotstrings"][V2Cat]) {
            continue
        }
        V1Cat := IdMap["_v1_cat"]
        if !Features.Has(V1Cat) {
            continue
        }
        for V2Id, V1Id in IdMap {
            if (V2Id == "_v1_cat") {
                continue
            }
            if !FeaturesV2["hotstrings"][V2Cat].Has(V2Id)
                or !IsObject(FeaturesV2["hotstrings"][V2Cat][V2Id]) {
                continue
            }
            V2Entry := FeaturesV2["hotstrings"][V2Cat][V2Id]
            if !V2Entry.Has("enabled") {
                continue
            }
            if !Features[V1Cat].Has(V1Id) {
                continue
            }
            V1Entry := Features[V1Cat][V1Id]
            if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
                continue
            }
            V1Entry.Enabled := (V2Entry["enabled"] = true)
            ; Mirror back pattern_max_length (Dynamic text expansion only).
            if V2Entry.Has("pattern_max_length") and V1Entry.HasOwnProp("PatternMaxLength") {
                V1Entry.PatternMaxLength := V2Entry["pattern_max_length"]
            }
            Copied += 1
        }
    }

    try LoggerDebug("V2ToV1",
        "MirrorV2ToV1_Hotstrings copied {1} entry(ies) v2 -> v1.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 4bis/ Hotstrings Personal (runtime-discovered) =======
; ==============================================================
; ==============================================================

; Personal sections are user-defined at runtime — Features["Personal"] is
; populated by ``BootstrapPersonalFeatures`` from the user's personal_hotstrings
; ``.toml [_meta.sections]`` block, and the v2 entries under
; ``FeaturesV2["hotstrings"]["personal"]`` are seeded by the v2 reader from
; the user's overrides. This helper just flips the ``.Enabled`` flag for any
; v1 section that has a matching v2 entry (key match is on lowercase TOML
; section name = v1 ``.TomlSection`` property).
MirrorV2ToV1_HotstringsPersonal() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        return
    }
    if !Features.Has("Personal") {
        return
    }
    if !FeaturesV2.Has("hotstrings") or !FeaturesV2["hotstrings"].Has("personal") {
        return
    }

    Copied := 0
    for V1Key, V1Val in Features["Personal"] {
        if (V1Key == "__Order") {
            continue
        }
        if !IsObject(V1Val) or !V1Val.HasOwnProp("Enabled") {
            continue
        }
        V2Key := V1Val.HasOwnProp("TomlSection")
            ? V1Val.TomlSection
            : StrLower(V1Key)
        if !FeaturesV2["hotstrings"]["personal"].Has(V2Key) {
            continue
        }
        V2Entry := FeaturesV2["hotstrings"]["personal"][V2Key]
        if !IsObject(V2Entry) or !V2Entry.Has("enabled") {
            continue
        }
        V1Val.Enabled := (V2Entry["enabled"] = true)
        if V2Entry.Has("time_activation_seconds") and V1Val.HasOwnProp("TimeActivationSeconds") {
            V1Val.TimeActivationSeconds := V2Entry["time_activation_seconds"]
        }
        Copied += 1
    }
    try LoggerDebug("V2ToV1",
        "MirrorV2ToV1_HotstringsPersonal copied {1} section(s) v2 -> v1.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 5/ Master gate application =======
; ==============================================================
; ==============================================================

; When a master category gate is off, force every v2 feature in that
; category to ``false`` so #HotIf evaluations on FeaturesV2 short-circuit.
; The v1 Map is NOT touched here — the tray menu reads v1 to display the
; user's raw choices and uses ``IsCategoryGated`` separately to grey out
; the items.
;
; Called AFTER MirrorV2ToV1_<X> populates both Maps from the disk state;
; the gate transformation is destructive on FeaturesV2 but reversible by
; toggling the gate back on (which forces another Reload, re-reading the
; raw user state from disk).
ApplyMasterGatesToFeaturesV2() {
    global FeaturesV2

    if !IsSet(FeaturesV2) {
        return
    }

    ; Layout master
    if !IsCategoryGated("Layout") and FeaturesV2.Has("layout") {
        for V2Id, _ in FeaturesV2["layout"] {
            FeaturesV2["layout"][V2Id] := false
        }
    }

    ; Shortcuts master
    if !IsCategoryGated("Shortcuts") and FeaturesV2.Has("shortcuts") {
        for V2Id, V2Val in FeaturesV2["shortcuts"] {
            if (Type(V2Val) == "Map") {
                ; Modélisation α + sub-Maps — flip ``enabled`` if present,
                ; else flip every leaf bool entry.
                if V2Val.Has("enabled") {
                    V2Val["enabled"] := false
                } else {
                    for SubId, _ in V2Val {
                        V2Val[SubId] := false
                    }
                }
            } else if (Type(V2Val) == "Integer" or V2Val == true or V2Val == false) {
                FeaturesV2["shortcuts"][V2Id] := false
            }
        }
    }

    ; Hotstrings master (includes Personal sub-category)
    if !IsCategoryGated("Hotstrings") and FeaturesV2.Has("hotstrings") {
        for V2Cat, V2CatMap in FeaturesV2["hotstrings"] {
            if (Type(V2CatMap) != "Map") {
                continue
            }
            for V2Id, V2Val in V2CatMap {
                if (Type(V2Val) == "Map" and V2Val.Has("enabled")) {
                    V2Val["enabled"] := false
                }
            }
        }
    }

    ; TapHolds master — handled by tap_hold.toml loading; gating drops the
    ; TapHold["keys"] entries entirely so TapHoldIsConfigured returns false.
    if !IsCategoryGated("TapHolds") {
        global TapHold
        if IsSet(TapHold) and TapHold.Has("keys") {
            TapHold["keys"] := Map()
        }
    }

    try LoggerDebug("V2ToV1", "ApplyMasterGatesToFeaturesV2 done.")
}




; ==============================================================
; ==============================================================
; ======= 6/ Single entry point =======
; ==============================================================
; ==============================================================

; Run every reverse mirror in dependency order, then apply master gates.
; Called once at boot after the v2 reader populates FeaturesV2 from disk.
MirrorV2ToV1_All() {
    LoggerStart("V2ToV1", "Mirroring v2 state back to v1 Features Map…")
    MirrorV2ToV1_Layout()
    MirrorV2ToV1_Gestures()
    MirrorV2ToV1_Shortcuts()
    MirrorV2ToV1_Hotstrings()
    ; Personal is mirrored separately after BootstrapPersonalFeatures runs,
    ; same as the forward mirror used to do.
    ApplyMasterGatesToFeaturesV2()
    LoggerSuccess("V2ToV1", "v2 -> v1 mirror complete.")
}
