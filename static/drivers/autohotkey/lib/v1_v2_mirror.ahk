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
        FeaturesV2["layout"][V2Id] := (V1Val.Enabled = true)
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
; directly. The ``RunFirstSimpleAction`` / ``HasAnyEnabled`` dispatchers in
; lib/dispatchers.ahk still iterate v1-shaped ``{Cfg.Enabled}`` objects, so
; the dispatcher call sites (``RunFirstSimpleAction(Features["Shortcuts"]
; ["LAltCapsLock"])`` and friends) keep passing v1 sub-Maps until those
; helpers are widened or replaced. ``AltGrCapsLock`` has no individual
; reads (only dispatcher calls) so we skip its mirror this phase.
;   AltGrLAlt   — 10 entries, individually read in modules/shortcuts.ahk
;   LAltCapsLock — 10 entries, individually read in modules/tap_holds.ahk
;
; INTENTIONALLY NOT migrated yet (kept on v1):
;   - Personal sub-Map: boot-path dependency on RegisterPersonalFeature.
;   - Letter pickers (EGrave/ECirc/EAcute/AGrave): consumed by
;     lib/layout/layout_ergopti.ahk via .Letter lookups; touches the
;     base-layer registration so deferring.
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
        FeaturesV2["shortcuts"][V2Id] := (V1Val.Enabled = true)
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
    )
    AlphaPairsV2 := Map(
        "GPT",      "gpt",
        "Search",   "search",
        "TakeNote", "take_note",
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
                FeaturesV2["shortcuts"][V2Id][V2Key] := (PropVal = true)
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
        "AltGrLAlt",    "alt_gr_lalt",
        "LAltCapsLock", "lalt_caps_lock",
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
            FeaturesV2["shortcuts"][V2Group][V2Key] := (V1Entry.Enabled = true)
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
            FeaturesV2["hotstrings"][V2Cat][V2Id]["enabled"] := (V1Val.Enabled = true)
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
