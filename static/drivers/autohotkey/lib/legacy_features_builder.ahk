; lib/legacy_features_builder.ahk

; ==============================================================================
; MODULE: Legacy Features Builder
; DESCRIPTION:
; Synthesises the v1-shape ``Features`` Map (PascalCase ids, ``.Enabled`` /
; ``.Letter`` / ``.Link`` properties, ``__Order`` arrays) directly from the
; canonical feature manifest (``_shared/features/manifest.toml`` →
; ``_generated/features_manifest.ahk``). Replaces the 385-line hardcoded
; literal that used to live in ``features_config.ahk`` so the manifest is
; the single source of truth for both the v2 schema and the v1 menu
; structure that the tray builder still walks.
;
; FEATURES & RATIONALE:
; 1. Runtime state on ``Features[X].Enabled / .Letter / ...`` is no
;    longer consulted by the menu builder (slice 6 cut those reads over
;    to FeaturesV2 via GetFeatureV2State). The defaults emitted here are
;    only there to preserve the Map shape for the few helpers that still
;    walk the v1 tree (the personal-feature register, the manifest-
;    miss fallbacks inside GetMenuTitleByPath / _ResolveMenuItemEnabled
;    for runtime Personal entries, RegisterPersonalFeature's mutation of
;    Features["Shortcuts"]["Personal"]). Any deviation between these
;    defaults and FeaturesV2's manifest defaults is harmless — only the
;    structure matters.
; 2. ``__Order`` arrays + ``__Label`` keys are hardcoded here because the
;    manifest doesn't model them. The menu builder's manifest-driven
;    helpers (``_BuildShortcutsSubmenu`` / ``_BuildTapHoldsSubmenu`` /
;    ``_BuildDynamicHotstringsSubmenu``) carry the curated render order
;    as their own sidecar constants now, so these ``__Order`` arrays are
;    only retained for the runtime Personal sub-Map registration code
;    that still consults them.
; 3. ``TapHolds`` is consumed verbatim from ``tap_hold_config.ahk``'s
;    ``_TapHoldsConfig`` literal — that subsystem isn't covered by the
;    manifest at all and keeps its own dedicated module.
; ==============================================================================




; ==============================================================
; ==============================================================
; ======= 1/ Public entry point =======
; ==============================================================
; ==============================================================

; Build the v1-shape Features Map from the canonical manifest. Called once
; at boot to populate the ``Features`` global; the result has the exact
; structural shape the legacy menu walker + tray-write helpers expect.
BuildLegacyFeaturesFromManifest() {
    global _TapHoldsConfig

    Features := Map(
        "__Order", ["Layout", "DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey",
            "DynamicHotstrings", "Shortcuts", "TapHolds", "Gestures"],
    )
    Features["Layout"]              := _LFB_BuildLayout()
    Features["DistancesReduction"]  := _LFB_BuildHotstringCategory("distances_reduction")
    Features["SFBsReduction"]       := _LFB_BuildHotstringCategory("sfbs_reduction")
    Features["Rolls"]               := _LFB_BuildHotstringCategory("rolls")
    Features["Autocorrection"]      := _LFB_BuildHotstringCategory("autocorrection")
    Features["MagicKey"]            := _LFB_BuildHotstringCategory("magic_key")
    Features["DynamicHotstrings"]   := _LFB_BuildDynamicHotstrings()
    Features["Shortcuts"]           := _LFB_BuildShortcuts()
    Features["TapHolds"]            := _TapHoldsConfig
    Features["Gestures"]            := _LFB_BuildGestures()
    return Features
}




; ==============================================================
; ==============================================================
; ======= 2/ Per-category builders =======
; ==============================================================
; ==============================================================

_LFB_BuildLayout() {
    global _V2V1_LayoutKeyMap
    L := Map(
        "__Order", ["ErgoptiBase", "DirectAccessDigits", "ErgoptiAltGr", "ErgoptiPlus"],
    )
    for Entry in ManifestFeaturesForSection("ahk.layout") {
        V2Id := Entry["id"]
        if !_V2V1_LayoutKeyMap.Has(V2Id) {
            continue
        }
        L[_V2V1_LayoutKeyMap[V2Id]] := { Enabled: Entry["default"] }
    }
    return L
}

_LFB_BuildHotstringCategory(V2CatName) {
    global _V2V1_AutocorrectionKeyMap, _V2V1_DistancesReductionKeyMap
    global _V2V1_SFBsReductionKeyMap, _V2V1_RollsKeyMap, _V2V1_MagicKeyKeyMap
    KeyMap := false
    switch V2CatName {
        case "autocorrection":      KeyMap := _V2V1_AutocorrectionKeyMap
        case "distances_reduction": KeyMap := _V2V1_DistancesReductionKeyMap
        case "sfbs_reduction":      KeyMap := _V2V1_SFBsReductionKeyMap
        case "rolls":               KeyMap := _V2V1_RollsKeyMap
        case "magic_key":           KeyMap := _V2V1_MagicKeyKeyMap
    }
    Cat := Map()
    if (KeyMap == false) {
        return Cat
    }
    for Entry in ManifestFeaturesForSection("hotstrings." . V2CatName) {
        V2Id := Entry["id"]
        if !KeyMap.Has(V2Id) {
            continue
        }
        Default := Entry["default"]
        EnabledVal := (Type(Default) == "Map" and Default.Has("enabled")) ? Default["enabled"] : Default
        Cat[KeyMap[V2Id]] := { Enabled: EnabledVal }
    }
    return Cat
}

_LFB_BuildDynamicHotstrings() {
    global _V2V1_DynamicHotstringsKeyMap
    D := Map(
        "__Order", ["DateLongFr", "DateFr", "Date", "PhonePrefixes", "SsnPrefixes",
            "IbanPrefixes", "-", "TextExpansionPersonalInformation"],
    )
    for Entry in ManifestFeaturesForSection("hotstrings.dynamic") {
        V2Id := Entry["id"]
        if !_V2V1_DynamicHotstringsKeyMap.Has(V2Id) {
            continue
        }
        V1Id := _V2V1_DynamicHotstringsKeyMap[V2Id]
        Default := Entry["default"]
        EnabledVal := (Type(Default) == "Map" and Default.Has("enabled")) ? Default["enabled"] : Default
        Obj := { Enabled: EnabledVal }
        if (Type(Default) == "Map" and Default.Has("pattern_max_length")) {
            Obj.PatternMaxLength := Default["pattern_max_length"]
        }
        D[V1Id] := Obj
    }
    return D
}

_LFB_BuildGestures() {
    ; Only the master ``Enabled`` toggle is exposed on v1 Features for
    ; the menu — slot assignments live on ``GestureAssignments``.
    G := Map()
    for Entry in ManifestFeaturesForSection("ahk.gestures") {
        if (Entry["id"] == "enabled") {
            G["Enabled"] := { Enabled: Entry["default"] }
            break
        }
    }
    if !G.Has("Enabled") {
        G["Enabled"] := { Enabled: false }
    }
    return G
}




; ==============================================================
; ==============================================================
; ======= 3/ Shortcuts (most complex section) =======
; ==============================================================
; ==============================================================

; The Shortcuts section combines four manifest groups:
;   - ``shortcuts``           : cross-platform plain bools + Modélisation α
;   - ``ahk.shortcuts``       : AHK-only plain bools (open_downloads, …)
;   - ``shortcuts.<letter>``  : split letter-picker entries (enabled + letter)
;   - ``ahk.shortcuts.<group>`` : sub-Map groups (alt_gr_lalt etc.)
;
; The hardcoded ``__Order`` with virtual headers / separators isn't in the
; manifest yet — it lives here as the curated UX ordering shown in the
; tray-menu walker.
_LFB_BuildShortcuts() {
    global _V2V1_ShortcutsBoolKeyMap, _V2V1_ShortcutsAlphaKeyMap

    Sc := Map(
        "__Order", [
            ">menu.shortcuts.group_accented",
            "EGrave", "ECirc", "EAcute", "AGrave",
            "<",
            "WrapTextIfSelected",
            ">menu.shortcuts.group_modifiers",
            "AltGrLAlt", "AltGrCapsLock", "LAltCapsLock",
            "<",
        ],
    )

    ; Cross-platform shortcuts (plain bools + Modélisation α with table default).
    for Entry in ManifestFeaturesForSection("shortcuts") {
        V2Id := Entry["id"]
        Default := Entry["default"]
        if _V2V1_ShortcutsAlphaKeyMap.Has(V2Id) {
            ; gpt / search / take_note — table default, copy named props.
            Sc[_V2V1_ShortcutsAlphaKeyMap[V2Id]] := _LFB_ShortcutAlphaObject(Default)
        } else if _V2V1_ShortcutsBoolKeyMap.Has(V2Id) {
            Sc[_V2V1_ShortcutsBoolKeyMap[V2Id]] := { Enabled: Default }
        }
        ; Everything else (chatgpt_url, hs-only ``enabled``) is dropped — not
        ; an AHK feature.
    }

    ; AHK-only shortcuts (plain bools).
    for Entry in ManifestFeaturesForSection("ahk.shortcuts") {
        V2Id := Entry["id"]
        if _V2V1_ShortcutsBoolKeyMap.Has(V2Id) {
            Sc[_V2V1_ShortcutsBoolKeyMap[V2Id]] := { Enabled: Entry["default"] }
        }
    }

    ; Letter pickers — section ``shortcuts.<letter_picker>`` with two entries
    ; (enabled / letter). Combine them into a single v1 object.
    for V2LetterId, V1LetterId in _V2V1_ShortcutsAlphaKeyMap {
        ; Only the four letter pickers have a dedicated section; gpt /
        ; search / take_note already emitted via the loop above.
        if (V2LetterId != "a_grave" and V2LetterId != "e_acute"
            and V2LetterId != "e_circ" and V2LetterId != "e_grave") {
            continue
        }
        Obj := { Enabled: true, Letter: "" }
        for Entry in ManifestFeaturesForSection("shortcuts." . V2LetterId) {
            switch Entry["id"] {
                case "enabled":
                    Obj.Enabled := Entry["default"]
                case "letter":
                    Obj.Letter := Entry["default"]
            }
        }
        Sc[V1LetterId] := Obj
    }

    ; Sub-Map groups (10 plain bools each).
    Sc["AltGrLAlt"]     := _LFB_BuildShortcutsSubMap("ahk.shortcuts.alt_gr_lalt")
    Sc["AltGrCapsLock"] := _LFB_BuildShortcutsSubMap("ahk.shortcuts.alt_gr_caps_lock")
    Sc["LAltCapsLock"]  := _LFB_BuildShortcutsSubMap("ahk.shortcuts.lalt_caps_lock")

    return Sc
}

_LFB_ShortcutAlphaObject(Default) {
    Obj := { Enabled: (Type(Default) == "Map" and Default.Has("enabled")) ? Default["enabled"] : true }
    if (Type(Default) != "Map") {
        return Obj
    }
    if Default.Has("link") {
        Obj.Link := Default["link"]
    }
    if Default.Has("letter") {
        Obj.Letter := Default["letter"]
    }
    if Default.Has("search_engine") {
        Obj.SearchEngine := Default["search_engine"]
    }
    if Default.Has("search_engine_url_query") {
        Obj.SearchEngineURLQuery := Default["search_engine_url_query"]
    }
    if Default.Has("dated_notes") {
        Obj.DatedNotes := Default["dated_notes"]
    }
    if Default.Has("destination_folder") {
        Obj.DestinationFolder := Default["destination_folder"]
    }
    return Obj
}

_LFB_BuildShortcutsSubMap(V2Section) {
    global _V2V1_ShortcutsSubMapKeyMap
    M := Map()
    for Entry in ManifestFeaturesForSection(V2Section) {
        V2Id := Entry["id"]
        if _V2V1_ShortcutsSubMapKeyMap.Has(V2Id) {
            M[_V2V1_ShortcutsSubMapKeyMap[V2Id]] := { Enabled: Entry["default"] }
        }
    }
    return M
}
