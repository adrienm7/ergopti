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
