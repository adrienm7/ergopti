; lib/v1_v2_mirror.ahk

; ==============================================================================
; MODULE: V1 to V2 Features mirror (transitional)
; DESCRIPTION:
; Sliced cut-over helper bridging the legacy ``Features`` Map (v1 PascalCase
; with ``.Enabled`` object sub-properties) to the new ``FeaturesV2`` Map
; (v2 snake_case with plain booleans). One ``MirrorV1ToV2_<Section>`` per
; migrating section is added as a phase lands, and the entire module is
; deleted in the final cut-over together with ``Features``,
; ``features_config.ahk`` and ``ApplyConfigTomlOverrides``.
;
; FEATURES & RATIONALE:
; 1. Single-direction sync v1 → v2: writes still flow through the v1 path
;    (tray-menu ``ToggleMenuVariableByPath`` mutates ``Features[X].Enabled``,
;    writes the v1 TOML key, and calls ``Reload``). Reload re-executes the
;    boot path which calls this mirror again, so v2 reads always observe
;    the freshest v1 state without any tray-menu code changes.
; 2. Pure derived view: there is exactly one source of truth during the
;    slice (``Features[X].Enabled``). The mirror is rebuilt from scratch
;    on every boot, so divergence is impossible.
; 3. Manifest-default fallback: ``FeaturesV2[section]`` is pre-populated
;    by ``ManifestBuildFeaturesMap()`` with the declared defaults. When
;    ``Features`` lacks an entry (early boot, missing section, unfamiliar
;    feature id), the v2 default stands — the mirror never deletes keys
;    it only knows how to overwrite.
;
; NOTE on naming: per-section helpers stay explicit (``MirrorV1ToV2_Layout``,
; ``MirrorV1ToV2_Shortcuts``, ...) rather than a single data-driven loop, so
; each migration phase has its own reviewable diff and its own removable
; chunk at cut-over time.
; ==============================================================================




; ==============================================================
; ==============================================================
; ======= 1/ Layout =======
; ==============================================================
; ==============================================================

; Copy the four ``Features["Layout"][X].Enabled`` flags into
; ``FeaturesV2["layout"][<snake_case>]``. Called at boot after the v1
; ``ApplyConfigTomlOverrides`` populates ``Features["Layout"]`` from the
; user's v1-shaped ``config.toml``.
;
; v1 id              -> v2 id
; ErgoptiBase        -> ergopti_base
; DirectAccessDigits -> direct_access_digits
; ErgoptiAltGr       -> ergopti_alt_gr
; ErgoptiPlus        -> ergopti_plus
MirrorV1ToV2_Layout() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Layout skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Layout") or !FeaturesV2.Has("layout") {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Layout skipped — section missing in v1 or v2.")
        return
    }

    ; Master category gate (Phase 7.4): when the user toggles the master
    ; "Disposition" off in the tray menu, IsCategoryGated returns false
    ; and every layout feature propagates as false here regardless of its
    ; individual .Enabled state. Per-feature choices are preserved in v1
    ; Features for when the user re-enables the master.
    Gated := IsCategoryGated("Layout")

    Pairs := Map(
        "ErgoptiBase",        "ergopti_base",
        "DirectAccessDigits", "direct_access_digits",
        "ErgoptiAltGr",       "ergopti_alt_gr",
        "ErgoptiPlus",        "ergopti_plus",
    )

    Copied := 0
    for V1Id, V2Id in Pairs {
        if !Features["Layout"].Has(V1Id) {
            continue
        }
        V1Val := Features["Layout"][V1Id]
        ; v1 layout entries are objects with an ``Enabled`` property — guard
        ; against shape drift in case a feature row is ever flattened.
        if !IsObject(V1Val) or !V1Val.HasOwnProp("Enabled") {
            continue
        }
        FeaturesV2["layout"][V2Id] := Gated and (V1Val.Enabled = true)
        Copied += 1
    }

    try LoggerDebug("V1ToV2",
        "MirrorV1ToV2_Layout copied {1} entry(ies) v1 -> v2.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 2/ Gestures =======
; ==============================================================
; ==============================================================

; Single-flag mirror: ``Features["Gestures"]["Enabled"].Enabled`` ->
; ``FeaturesV2["gestures"]["enabled"]``. The other Gestures keys (slot
; assignments swipe_3_*, swipe_4_*, tap_3, tap_4) are not held in the
; legacy v1 Features Map at all — they live in ``GestureAssignments``
; (populated by ``modules/gestures.ahk`` from the [Gestures] TOML section
; directly). So this mirror only carries the master toggle.
MirrorV1ToV2_Gestures() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Gestures skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Gestures") or !FeaturesV2.Has("gestures") {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Gestures skipped — section missing in v1 or v2.")
        return
    }
    if !Features["Gestures"].Has("Enabled") {
        return
    }

    V1Val := Features["Gestures"]["Enabled"]
    if !IsObject(V1Val) or !V1Val.HasOwnProp("Enabled") {
        return
    }
    FeaturesV2["gestures"]["enabled"] := (V1Val.Enabled = true)
    try LoggerDebug("V1ToV2", "MirrorV1ToV2_Gestures copied 1 entry v1 -> v2.")
}




; ==============================================================
; ==============================================================
; ======= 3/ Shortcuts =======
; ==============================================================
; ==============================================================

; Mirrors the subset of v1 ``Features["Shortcuts"][X].(Enabled|Letter|Link|...)``
; entries that the migrated read sites in modules/shortcuts.ahk and
; modules/layout.ahk now consult through ``FeaturesV2["shortcuts"][snake][...]``.
;
; Plain-bool entries (v2 stores the raw bool, no enabled sub-key):
;   WrapTextIfSelected, GetHexValue, MicrosoftBold, TitleCase, Uppercase,
;   PasteWithoutFormatting, Save, SelectLine, SpotlightMouse,
;   SurroundWithParentheses, TeleportMouse, CtrlJ, OpenDownloads, Move,
;   Screen, ScreenInstant, WinCapsLock
;
; Modélisation α entries (v2 stores { enabled, <prop>... } as a Map):
;   GPT (enabled + link)
;   Search (enabled + search_engine + search_engine_url_query)
;   TakeNote (enabled + dated_notes + destination_folder)
;
; Sub-Map entries (10 per group, all bools) — migrated in Phase 4 so the
; individual ``.Enabled`` reads in modules/shortcuts.ahk and
; modules/tap_holds.ahk can consult ``FeaturesV2["shortcuts"][<group>][<key>]``
; directly. Phase 10 deleted the v1 ``RunFirstSimpleAction`` / ``HasAnyEnabled``
; dispatchers (lib/dispatchers.ahk) by inlining each shortcut handler with a
; v2 if/else cascade, so every sub-Map is now read individually through
; ``FeaturesV2["shortcuts"][<group>][<key>]``.
;   AltGrCapsLock — 10 entries, read by AltGrCapsLockShortcut
;   AltGrLAlt     — 10 entries, read by AltGrLAltShortcut
;   LAltCapsLock  — 10 entries, read by LAltCapsLockShortcut
;
; INTENTIONALLY NOT migrated yet (kept on v1):
;   - Personal sub-Map: boot-path dependency on RegisterPersonalFeature.
;   - tray_menu.ahk reads: the write path stays v1 until cut-over.
MirrorV1ToV2_Shortcuts() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Shortcuts skipped — Features or FeaturesV2 unset.")
        return
    }
    if !Features.Has("Shortcuts") or !FeaturesV2.Has("shortcuts") {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Shortcuts skipped — section missing in v1 or v2.")
        return
    }

    ; Master category gate (Phase 7.4) — see MirrorV1ToV2_Layout.
    Gated := IsCategoryGated("Shortcuts")

    BoolPairs := Map(
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

    Copied := 0
    for V1Id, V2Id in BoolPairs {
        if !Features["Shortcuts"].Has(V1Id) {
            continue
        }
        V1Val := Features["Shortcuts"][V1Id]
        if !IsObject(V1Val) or !V1Val.HasOwnProp("Enabled") {
            continue
        }
        FeaturesV2["shortcuts"][V2Id] := Gated and (V1Val.Enabled = true)
        Copied += 1
    }

    ; Modélisation α — copy Enabled + named extra props into the v2 Map.
    ; v2 shape: FeaturesV2["shortcuts"]["gpt"]["enabled"|"link"].
    ; PropMap maps v2 snake_case key -> v1 PascalCase property name.
    AlphaPairs := Map(
        "GPT",      Map("enabled", "Enabled", "link", "Link"),
        "Search",   Map("enabled", "Enabled",
                        "search_engine", "SearchEngine",
                        "search_engine_url_query", "SearchEngineURLQuery"),
        "TakeNote", Map("enabled", "Enabled",
                        "dated_notes", "DatedNotes",
                        "destination_folder", "DestinationFolder"),
        ; Letter pickers (phase 11) — accented base-layer keys whose target
        ; latin letter is user-configurable via tray menu. Read by
        ; lib/layout/layout_ergopti.ahk's ErgoptiBaseMapping at boot.
        "EGrave",   Map("enabled", "Enabled", "letter", "Letter"),
        "ECirc",    Map("enabled", "Enabled", "letter", "Letter"),
        "EAcute",   Map("enabled", "Enabled", "letter", "Letter"),
        "AGrave",   Map("enabled", "Enabled", "letter", "Letter"),
    )
    AlphaPairsV2 := Map(
        "GPT",      "gpt",
        "Search",   "search",
        "TakeNote", "take_note",
        "EGrave",   "e_grave",
        "ECirc",    "e_circ",
        "EAcute",   "e_acute",
        "AGrave",   "a_grave",
    )

    for V1Id, PropMap in AlphaPairs {
        if !Features["Shortcuts"].Has(V1Id) {
            continue
        }
        V1Val := Features["Shortcuts"][V1Id]
        if !IsObject(V1Val) {
            continue
        }
        V2Id := AlphaPairsV2[V1Id]
        if !FeaturesV2["shortcuts"].Has(V2Id) or !IsObject(FeaturesV2["shortcuts"][V2Id]) {
            ; v2 entry expected to be a Map (modélisation α default = { enabled = ..., ... })
            continue
        }
        for V2Key, V1Prop in PropMap {
            if !V1Val.HasOwnProp(V1Prop) {
                continue
            }
            PropVal := V1Val.%V1Prop%
            if (V2Key == "enabled") {
                FeaturesV2["shortcuts"][V2Id][V2Key] := Gated and (PropVal = true)
            } else {
                FeaturesV2["shortcuts"][V2Id][V2Key] := PropVal
            }
            Copied += 1
        }
    }

    ; Sub-Maps (Phase 4). Same snake_case key rename for every entry.
    ; v1 path: Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled
    ; v2 path: FeaturesV2["shortcuts"]["alt_gr_lalt"]["backspace"]
    SubKeyMap := Map(
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
    SubMaps := Map(
        "AltGrCapsLock", "alt_gr_caps_lock",
        "AltGrLAlt",     "alt_gr_lalt",
        "LAltCapsLock",  "lalt_caps_lock",
    )
    for V1Group, V2Group in SubMaps {
        if !Features["Shortcuts"].Has(V1Group) {
            continue
        }
        if !FeaturesV2["shortcuts"].Has(V2Group) or !IsObject(FeaturesV2["shortcuts"][V2Group]) {
            continue
        }
        V1SubMap := Features["Shortcuts"][V1Group]
        if !IsObject(V1SubMap) {
            continue
        }
        for V1Key, V2Key in SubKeyMap {
            if !V1SubMap.Has(V1Key) {
                continue
            }
            V1Entry := V1SubMap[V1Key]
            if !IsObject(V1Entry) or !V1Entry.HasOwnProp("Enabled") {
                continue
            }
            FeaturesV2["shortcuts"][V2Group][V2Key] := Gated and (V1Entry.Enabled = true)
            Copied += 1
        }
    }

    try LoggerDebug("V1ToV2",
        "MirrorV1ToV2_Shortcuts copied {1} entry(ies) v1 -> v2.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 4/ Hotstrings (all 6 categories) =======
; ==============================================================
; ==============================================================

; Mirrors every hotstring category from the legacy top-level v1 Maps
; (Features["Autocorrection"], ["DistancesReduction"], ["SFBsReduction"],
; ["Rolls"], ["MagicKey"], ["DynamicHotstrings"]) into the v2-shape nested
; container at FeaturesV2["hotstrings"][<category>][<entry>]["enabled"].
;
; The v2 manifest uses modélisation α: each entry is a Map with at least
; an "enabled" key and possibly extra props (time_activation_seconds,
; pattern_max_length, …). The defaults come from the manifest itself —
; the mirror only overwrites the .enabled flag from the user's v1 toggles.
; Extra props (TimeActivationSeconds, etc.) stay on the v1 object because
; LoadHotstringsSection in lib/toml/toml_loader.ahk still reads them via
; ``.PropertyName`` access — that helper will move with a future phase.
;
; The v1 id -> v2 id mapping has a few non-trivial renames worth flagging:
;   SFBsReduction.IÉ        -> sfbs_reduction.i_e_acute  (special chars folded)
;   MagicKey.RepeatCorrections -> magic_key.repeat_corrections
;   DynamicHotstrings.*     -> dynamic.*  (category renamed: "Hotstrings"
;                              suffix is redundant inside [hotstrings.*])
MirrorV1ToV2_Hotstrings() {
    global Features, FeaturesV2

    if !IsSet(Features) or !IsSet(FeaturesV2) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Hotstrings skipped — Features or FeaturesV2 unset.")
        return
    }
    if !FeaturesV2.Has("hotstrings") {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_Hotstrings skipped — FeaturesV2['hotstrings'] missing.")
        return
    }

    ; Master category gate (Phase 7.4) — see MirrorV1ToV2_Layout.
    Gated := IsCategoryGated("Hotstrings")

    ; Per-category v1->v2 mapping. Outer key = v1 top-level Features key,
    ; inner Map = { v2_category_name, entry_map(v1_id -> v2_id) }.
    Categories := Map(
        "Autocorrection", Map(
            "_v2_cat", "autocorrection",
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
        ),
        "DistancesReduction", Map(
            "_v2_cat", "distances_reduction",
            "QU",                  "qu",
            "SuffixesA",           "suffixes_a",
            "CommaJ",              "comma_j",
            "CommaFarLetters",     "comma_far_letters",
            "DeadKeyECircumflex",  "dead_key_e_circumflex",
            "ECircumflexE",        "e_circumflex_e",
            "SpaceAroundSymbols",  "space_around_symbols",
        ),
        "SFBsReduction", Map(
            "_v2_cat", "sfbs_reduction",
            "Comma",   "comma",
            "ECirc",   "e_circ",
            "EGrave",  "e_grave",
            "BU",      "bu",
            "IÉ",      "i_e_acute",
        ),
        "Rolls", Map(
            "_v2_cat", "rolls",
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
        ),
        "MagicKey", Map(
            "_v2_cat", "magic_key",
            "Replace",                    "replace",
            "RepeatCorrections",          "repeat_corrections",
            "TextExpansion",              "text_expansion",
            "TextExpansionAuto",          "text_expansion_auto",
            "TextExpansionEmojis",        "text_expansion_emojis",
            "TextExpansionSymbols",       "text_expansion_symbols",
            "TextExpansionSymbolsTypst",  "text_expansion_symbols_typst",
        ),
        "DynamicHotstrings", Map(
            "_v2_cat", "dynamic",
            "Date",                              "date",
            "DateFr",                            "date_fr",
            "DateLongFr",                        "date_long_fr",
            "IbanPrefixes",                      "iban_prefixes",
            "PhonePrefixes",                     "phone_prefixes",
            "SsnPrefixes",                       "ssn_prefixes",
            "TextExpansionPersonalInformation",  "text_expansion_personal_information",
        ),
    )

    Copied := 0
    for V1Cat, IdMap in Categories {
        if !Features.Has(V1Cat) {
            continue
        }
        V2Cat := IdMap["_v2_cat"]
        if !FeaturesV2["hotstrings"].Has(V2Cat) or !IsObject(FeaturesV2["hotstrings"][V2Cat]) {
            continue
        }
        for V1Id, V2Id in IdMap {
            if (V1Id == "_v2_cat") {
                continue
            }
            if !Features[V1Cat].Has(V1Id) {
                continue
            }
            V1Val := Features[V1Cat][V1Id]
            if !IsObject(V1Val) or !V1Val.HasOwnProp("Enabled") {
                continue
            }
            if !FeaturesV2["hotstrings"][V2Cat].Has(V2Id)
                or !IsObject(FeaturesV2["hotstrings"][V2Cat][V2Id]) {
                ; v2 entry expected to be a Map; skip if shape mismatch.
                continue
            }
            FeaturesV2["hotstrings"][V2Cat][V2Id]["enabled"] := Gated and (V1Val.Enabled = true)
            ; Mirror PatternMaxLength too — only DynamicHotstrings'
            ; TextExpansionPersonalInformation carries it in v1 today.
            if V1Val.HasOwnProp("PatternMaxLength") {
                FeaturesV2["hotstrings"][V2Cat][V2Id]["pattern_max_length"] := V1Val.PatternMaxLength
            }
            Copied += 1
        }
    }

    try LoggerDebug("V1ToV2",
        "MirrorV1ToV2_Hotstrings copied {1} entry(ies) v1 -> v2.", Copied)
}




; ==============================================================
; ==============================================================
; ======= 5/ LLM =======
; ==============================================================
; ==============================================================

; Mirrors the legacy flat ``[LLM]`` section in the user's v1 ``config.toml``
; into the v2 nested ``FeaturesV2["llm"]`` Map. Unlike the other mirror
; helpers, this one does NOT read from a top-level ``Features["LLM"]`` Map
; (LLM never had one in v1) — it reads directly from ``_IniCache`` (the
; raw TOML key/value cache populated by ``ParseTomlFile`` at boot). The
; values are then placed at their v2 nested paths per the migration map
; in ``_shared/features/_migration_v1_to_v2.md`` § 3.
;
; v1 key                        -> v2 path
; enabled                       -> llm.enabled
; model                         -> llm.models.ollama (+ llm.models.selected = "ollama")
; profile_id                    -> llm.profiles.active
; temperature                   -> llm.generation.temperature
; n_predictions                 -> llm.profiles.num_predictions
; min_words                     -> llm.generation.min_words
; max_words                     -> llm.generation.max_words
; debounce_ms                   -> llm.trigger.debounce_ms
; ctx_chars                     -> llm.generation.context_length (renamed)
; instant_on_word_end           -> llm.trigger.instant_on_word_end
; auto_profile_for_model        -> llm.profiles.auto_profile_for_model
; inline_autotype               -> llm.trigger.inline_autotype
;
; The ``onboarding_seen`` and ``app_profile_overrides`` v1 keys have no v2
; manifest counterpart — they are runtime state, not declared features.
; The tray-menu LLM init in ``ui/tray_menu.ahk`` still reads them via
; ``IniCacheGet`` directly.
MirrorV1ToV2_LLM() {
    global _IniCache, FeaturesV2

    if !IsSet(_IniCache) or !IsSet(FeaturesV2) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_LLM skipped — _IniCache or FeaturesV2 unset.")
        return
    }
    if !FeaturesV2.Has("llm") or !IsObject(FeaturesV2["llm"]) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_LLM skipped — FeaturesV2['llm'] missing.")
        return
    }

    Copied := 0

    ; Direct mappings: read v1 key, place at its v2 path. Coercion is
    ; done by ``_LlmCoerce<Bool|Num|Str>`` so the v2 Map ends up with
    ; the same value types the downstream readers (LLM_Tray_Init) expect.
    Direct := [
        { v1: "enabled",                category: "",          v2: "enabled",                coerce: "bool" },
        { v1: "temperature",            category: "generation", v2: "temperature",           coerce: "str"  },
        { v1: "min_words",              category: "generation", v2: "min_words",             coerce: "int"  },
        { v1: "max_words",              category: "generation", v2: "max_words",             coerce: "int"  },
        { v1: "ctx_chars",              category: "generation", v2: "context_length",        coerce: "int"  },
        { v1: "debounce_ms",            category: "trigger",    v2: "debounce_ms",           coerce: "int"  },
        { v1: "instant_on_word_end",    category: "trigger",    v2: "instant_on_word_end",   coerce: "bool" },
        { v1: "inline_autotype",        category: "trigger",    v2: "inline_autotype",       coerce: "bool" },
        { v1: "profile_id",             category: "profiles",   v2: "active",                coerce: "str"  },
        { v1: "n_predictions",          category: "profiles",   v2: "num_predictions",       coerce: "int"  },
        { v1: "auto_profile_for_model", category: "profiles",   v2: "auto_profile_for_model", coerce: "bool" },
    ]

    for Entry in Direct {
        Raw := IniCacheGet(_IniCache, "LLM", Entry.v1)
        if (Raw == "_") {
            continue  ; v1 key not present — keep manifest default in v2.
        }
        Coerced := _LlmCoerceValue(Raw, Entry.coerce)
        if (Entry.category == "") {
            FeaturesV2["llm"][Entry.v2] := Coerced
        } else {
            if !FeaturesV2["llm"].Has(Entry.category) or !IsObject(FeaturesV2["llm"][Entry.category]) {
                continue
            }
            FeaturesV2["llm"][Entry.category][Entry.v2] := Coerced
        }
        Copied += 1
    }

    ; ``model`` lands under the per-backend slot in v2. We assume the
    ; Ollama backend since that's the only one the v1 driver supports
    ; today; also set ``models.selected = "ollama"`` so consumers know
    ; which backend the model id belongs to.
    ModelRaw := IniCacheGet(_IniCache, "LLM", "model")
    if (ModelRaw != "_") {
        if FeaturesV2["llm"].Has("models") and IsObject(FeaturesV2["llm"]["models"]) {
            FeaturesV2["llm"]["models"]["ollama"]   := ModelRaw
            FeaturesV2["llm"]["models"]["selected"] := "ollama"
            Copied += 2
        }
    }

    try LoggerDebug("V1ToV2",
        "MirrorV1ToV2_LLM copied {1} entry(ies) v1 -> v2.", Copied)
}

; Coerce raw string values from _IniCache (which stores TOML-parsed
; primitives but returns them as the cache's stored type) into the
; concrete type expected by the v2 Map and its downstream readers.
_LlmCoerceValue(Raw, Kind) {
    switch Kind {
        case "bool":
            ; _IniCache returns AHK true/false for "true"/"false" TOML
            ; literals but legacy callers also stored "1"/"0" strings.
            if (Raw == true or Raw == 1 or Raw == "1" or Raw == "true") {
                return true
            }
            return false
        case "int":
            return Integer(Raw)
        case "str":
            return String(Raw)
    }
    return Raw
}




; ==============================================================
; ==============================================================
; ======= 6/ TapHolds (structural mirror v1 -> v2 TapHold) =======
; ==============================================================
; ==============================================================

; Translates the legacy multi-variant v1 ``Features["TapHolds"]`` structure
; into the new v2 single-action ``TapHold`` global (loaded from
; ``tap_hold.toml`` by lib/tap_hold/tap_hold_loader.ahk). Unlike the other
; mirror helpers, this is a **structural transform**, not a 1:1 key copy:
;
; - v1: each physical key (CapsLock / LAlt / AltGr / RCtrl / Space) carries
;   ~10 mutually-exclusive sub-variants, each {Enabled: bool}. Only one
;   variant should be Enabled at a time, and the variant name encodes both
;   the tap action and the hold modifier together (e.g. "EnterCtrl" =
;   tap_action=enter, hold_modifier=ctrl).
; - v2: each physical key has a single ``tap_action`` + ``hold_modifier``
;   (or ``hold_layer``) pair. The mirror scans the v1 variants, finds the
;   enabled one, and writes the equivalent v2 shape.
;
; Flat v1 entries (LShiftCopy / LCtrlPaste / TabAlt) become their own
; per-key v2 entries (left_shift / left_ctrl / tab).
;
; This mirror provides the FOUNDATION for a future migration of the ~70
; ``Features["TapHolds"][...]`` read sites in modules/tap_holds.ahk to
; consult ``TapHold`` instead. The read-site migration is deferred to a
; separate phase because the v1 branching ("which variant is enabled?")
; becomes a v2 switch on ``tap_action``, which is non-mechanical and
; deserves dedicated review.
MirrorV1ToV2_TapHold() {
    global Features, TapHold

    if !IsSet(Features) or !IsSet(TapHold) {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_TapHold skipped — Features or TapHold unset.")
        return
    }
    if !Features.Has("TapHolds") {
        try LoggerWarn("V1ToV2",
            "MirrorV1ToV2_TapHold skipped — Features['TapHolds'] missing.")
        return
    }
    if !TapHold.Has("keys") {
        TapHold["keys"] := Map()
    }

    ; Master category gate (Phase 7.4): when the user toggles "TapHolds"
    ; master off, leave TapHold["keys"] empty so TapHoldIsConfigured
    ; returns false for every key and the existing v1 read sites in
    ; modules/tap_holds.ahk (still reading Features["TapHolds"]) keep
    ; whatever per-feature .Enabled was, but the future v2 read path
    ; via TapHold sees nothing armed. Once the v1 reads migrate to v2,
    ; the master gate fully neutralises the category.
    if !IsCategoryGated("TapHolds") {
        try LoggerDebug("V1ToV2",
            "MirrorV1ToV2_TapHold skipped — TapHolds master gate is off.")
        return
    }

    Copied := 0

    ; ── Sub-Map keys: scan variants, pick the enabled one ──────────
    ; Each entry maps a v1 key group + variant name to (v2 key id,
    ; tap_action, hold_modifier|hold_layer). The "hold" column either
    ; sets ``hold_modifier`` (a modifier key) or ``hold_layer`` (a
    ; remap layer); never both.
    ; Format: variant_name -> Map("tap", "<v2_action>", "hold_mod", "<mod>" | "hold_layer", "<layer>")
    ; "BackSpace" variant is intentionally tap-only — the v1 *SC03A hotkey
    ; under this variant does NOT add Ctrl-on-hold (see modules/tap_holds.ahk
    ; line 61). Distinguishing it from "BackSpaceCtrl" requires the absence
    ; of a hold_modifier in v2.
    CapsLockVariants := Map(
        "BackSpace",          Map("tap", "backspace"),
        "BackSpaceCtrl",      Map("tap", "backspace",       "hold_mod", "ctrl"),
        "CapsLockCtrl",       Map("tap", "caps_lock",       "hold_mod", "ctrl"),
        "CapsWordCtrl",       Map("tap", "caps_word",       "hold_mod", "ctrl"),
        "CtrlBackSpaceCtrl",  Map("tap", "ctrl_backspace",  "hold_mod", "ctrl"),
        "CtrlDeleteCtrl",     Map("tap", "ctrl_delete",     "hold_mod", "ctrl"),
        "DeleteCtrl",         Map("tap", "delete",          "hold_mod", "ctrl"),
        "EnterCtrl",          Map("tap", "enter",           "hold_mod", "ctrl"),
        "EscapeCtrl",         Map("tap", "escape",          "hold_mod", "ctrl"),
        "OneShotShiftCtrl",   Map("tap", "one_shot_shift",  "hold_mod", "ctrl"),
        "TabCtrl",            Map("tap", "tab",             "hold_mod", "ctrl"),
    )
    ; "BackSpace" variant is tap-only key-repeat — the v1 *SC038 handler
    ; for this variant does NOT re-arm LAlt on hold (see modules/tap_holds.ahk
    ; line 261). Distinguished from BackSpaceLayer by the absence of hold_layer.
    LAltVariants := Map(
        "AltTabMonitor",   Map("tap", "alt_tab_monitor", "hold_mod", "alt"),
        "BackSpace",       Map("tap", "backspace"),
        "BackSpaceLayer",  Map("tap", "backspace",       "hold_layer", "nav"),
        "OneShotShift",    Map("tap", "one_shot_shift",  "hold_mod", "alt"),
        "TabLayer",        Map("tap", "tab",             "hold_layer", "nav"),
    )
    AltGrVariants := Map(
        "BackSpace",      Map("tap", "backspace",      "hold_mod", "alt_gr"),
        "CapsLock",       Map("tap", "caps_lock",      "hold_mod", "alt_gr"),
        "CapsWord",       Map("tap", "caps_word",      "hold_mod", "alt_gr"),
        "CtrlBackSpace",  Map("tap", "ctrl_backspace", "hold_mod", "alt_gr"),
        "CtrlDelete",     Map("tap", "ctrl_delete",    "hold_mod", "alt_gr"),
        "Delete",         Map("tap", "delete",         "hold_mod", "alt_gr"),
        "Enter",          Map("tap", "enter",          "hold_mod", "alt_gr"),
        "Escape",         Map("tap", "escape",         "hold_mod", "alt_gr"),
        "OneShotShift",   Map("tap", "one_shot_shift", "hold_mod", "alt_gr"),
        "Tab",            Map("tap", "tab",            "hold_mod", "alt_gr"),
    )
    RCtrlVariants := Map(
        "BackSpace",     Map("tap", "backspace",      "hold_mod", "ctrl"),
        "Tab",           Map("tap", "tab",            "hold_mod", "ctrl"),
        "OneShotShift",  Map("tap", "one_shot_shift", "hold_mod", "ctrl"),
    )
    SpaceVariants := Map(
        "Ctrl",   Map("tap", "space", "hold_mod", "ctrl"),
        "Layer",  Map("tap", "space", "hold_layer", "nav"),
        "Shift",  Map("tap", "space", "hold_mod", "shift"),
    )

    ; (v1 group name, v2 key id, variant table)
    SubMapKeys := [
        ["CapsLock", "caps_lock", CapsLockVariants],
        ["LAlt",     "left_alt",  LAltVariants],
        ["AltGr",    "alt_gr",    AltGrVariants],
        ["RCtrl",    "right_ctrl", RCtrlVariants],
        ["Space",    "space",     SpaceVariants],
    ]

    for Spec in SubMapKeys {
        V1Group  := Spec[1]
        V2KeyId  := Spec[2]
        Variants := Spec[3]
        if !Features["TapHolds"].Has(V1Group) {
            continue
        }
        V1SubMap := Features["TapHolds"][V1Group]
        if !IsObject(V1SubMap) {
            continue
        }
        ; Find the enabled variant. If none, skip — v2 leaves the key
        ; unconfigured (TapHoldIsConfigured returns false).
        ChosenVariant := ""
        for VarName, Mapping in Variants {
            if !V1SubMap.Has(VarName) {
                continue
            }
            VarEntry := V1SubMap[VarName]
            if !IsObject(VarEntry) or !VarEntry.HasOwnProp("Enabled") {
                continue
            }
            if (VarEntry.Enabled = true) {
                ChosenVariant := VarName
                break
            }
        }
        if (ChosenVariant == "") {
            ; No variant active for this key — leave TapHold["keys"] entry
            ; absent so callers see "not configured".
            continue
        }
        Mapping := Variants[ChosenVariant]
        Entry := Map("tap_action", Mapping["tap"])
        if Mapping.Has("hold_mod") {
            Entry["hold_modifier"] := Mapping["hold_mod"]
        } else if Mapping.Has("hold_layer") {
            Entry["hold_layer"] := Mapping["hold_layer"]
        }
        ; Carry per-variant TimeActivationSeconds when present, otherwise
        ; the per-key __Configuration default.
        Tas := 0
        if V1SubMap.Has(ChosenVariant)
            and IsObject(V1SubMap[ChosenVariant])
            and V1SubMap[ChosenVariant].HasOwnProp("TimeActivationSeconds") {
            Tas := V1SubMap[ChosenVariant].TimeActivationSeconds
        } else if V1SubMap.Has("__Configuration")
            and IsObject(V1SubMap["__Configuration"])
            and V1SubMap["__Configuration"].HasOwnProp("TimeActivationSeconds") {
            Tas := V1SubMap["__Configuration"].TimeActivationSeconds
        }
        if (Tas > 0) {
            Entry["time_activation_seconds"] := Tas
        }
        TapHold["keys"][V2KeyId] := Entry
        Copied += 1
    }

    ; ── Flat keys: LShiftCopy / LCtrlPaste / TabAlt ────────────────
    FlatKeys := [
        ["LShiftCopy", "left_shift", "copy",             "shift"],
        ["LCtrlPaste", "left_ctrl",  "paste",            "ctrl"],
        ["TabAlt",     "tab",        "alt_tab_monitor",  "alt"],
    ]
    for Spec in FlatKeys {
        V1Name   := Spec[1]
        V2KeyId  := Spec[2]
        TapAct   := Spec[3]
        HoldMod  := Spec[4]
        if !Features["TapHolds"].Has(V1Name) {
            continue
        }
        Entry := Features["TapHolds"][V1Name]
        if !IsObject(Entry) or !Entry.HasOwnProp("Enabled") {
            continue
        }
        if !(Entry.Enabled = true) {
            continue
        }
        V2Entry := Map(
            "tap_action",    TapAct,
            "hold_modifier", HoldMod,
        )
        if Entry.HasOwnProp("TimeActivationSeconds") {
            V2Entry["time_activation_seconds"] := Entry.TimeActivationSeconds
        }
        TapHold["keys"][V2KeyId] := V2Entry
        Copied += 1
    }

    try LoggerDebug("V1ToV2",
        "MirrorV1ToV2_TapHold copied {1} key(s) v1 -> v2.", Copied)
}
