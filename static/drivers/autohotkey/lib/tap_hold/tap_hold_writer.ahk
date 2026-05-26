; lib/tap_hold/tap_hold_writer.ahk

; ==============================================================================
; MODULE: Tap-Hold Writer
; DESCRIPTION:
; Persists user tray-menu choices for TapHolds variants to the v2
; ``tap_hold.toml`` file. The v1 schema represents the (tap_action,
; hold_modifier/hold_layer) tuple as a *variant name* under each physical
; key (``"AltGr.Tab"`` = tap on Tab + hold on AltGr, etc.); the v2 schema
; stores the resolved tuple directly under
; ``[tap_hold.keys.<key_id>]``. This module bridges the two: it parses
; the v1 path produced by ``ToggleMenuVariableByPath``, looks up the
; matching v2 tuple, mutates the ``TapHold`` global, and rewrites the
; canonical TOML file from scratch.
;
; FEATURES & RATIONALE:
; 1. Single source of truth for variant ⇄ v2 tuples — the same tables
;    used by the legacy MirrorV1ToV2_TapHold (deleted in slice 3) but
;    surfaced as a runtime writer instead of a boot-time mirror.
; 2. Mutually-exclusive groups: ToggleMenuVariableByPath pushes
;    ``Enabled=false`` for every sibling variant and ``Enabled=NewValue``
;    for the clicked one. The writer picks the (last) variant set to
;    ``true`` per key as the active tuple; if no variant ends up true,
;    the key is removed from TapHold["keys"] entirely.
; 3. Flat keys (``LShiftCopy``, ``LCtrlPaste``, ``TabAlt``) are not
;    sub-Maps in the v1 schema. They use ``Parts.Length == 2`` instead
;    of ``Parts.Length == 3`` and have a hardcoded (tap, hold_mod)
;    pair per id.
; 4. Preserves per-key ``time_activation_seconds`` already in TapHold —
;    the tray menu doesn't currently let the user customise it, but
;    hand-editing tap_hold.toml is supported.
; ==============================================================================





; =================================
; =================================
; ======= 1/ Variant tables =======
; =================================
; =================================

; v1 PascalCase TapHolds key id -> v2 snake_case key id.
global _TH_V1KeyIdToV2 := Map(
    "CapsLock",   "caps_lock",
    "LAlt",       "left_alt",
    "AltGr",      "alt_gr",
    "RCtrl",      "right_ctrl",
    "Space",      "space",
    "LShiftCopy", "left_shift",
    "LCtrlPaste", "left_ctrl",
    "TabAlt",     "tab",
)

; Per-sub-Map variant tables. Each maps the v1 PascalCase variant name to
; ``Map("tap" => v2_tap_action, "hold_mod" => v2_modifier)`` or
; ``Map("tap" => ..., "hold_layer" => layer_id)``. A variant whose mapping
; carries neither hold_mod nor hold_layer encodes a tap-only behaviour
; (no modifier change on hold) — e.g. ``CapsLock.BackSpace`` is just a
; remap to BackSpace, no Ctrl-on-hold.
global _TH_CapsLockVariants := Map(
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
global _TH_LAltVariants := Map(
    "AltTabMonitor",  Map("tap", "alt_tab_monitor", "hold_mod", "alt"),
    "BackSpace",      Map("tap", "backspace"),
    "BackSpaceLayer", Map("tap", "backspace",       "hold_layer", "nav"),
    "OneShotShift",   Map("tap", "one_shot_shift",  "hold_mod", "alt"),
    "TabLayer",       Map("tap", "tab",             "hold_layer", "nav"),
)
global _TH_AltGrVariants := Map(
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
global _TH_RCtrlVariants := Map(
    "BackSpace",    Map("tap", "backspace",      "hold_mod", "ctrl"),
    "Tab",          Map("tap", "tab",            "hold_mod", "ctrl"),
    "OneShotShift", Map("tap", "one_shot_shift", "hold_mod", "ctrl"),
)
global _TH_SpaceVariants := Map(
    "Ctrl",  Map("tap", "space", "hold_mod", "ctrl"),
    "Layer", Map("tap", "space", "hold_layer", "nav"),
    "Shift", Map("tap", "space", "hold_mod", "shift"),
)

; Flat keys — v1 path is ``TapHolds.<KeyId>`` (no variant). Each has a
; single hardcoded (tap, hold_mod) pair.
global _TH_FlatKeyTuples := Map(
    "LShiftCopy", Map("tap", "copy",             "hold_mod", "shift"),
    "LCtrlPaste", Map("tap", "paste",            "hold_mod", "ctrl"),
    "TabAlt",     Map("tap", "alt_tab_monitor",  "hold_mod", "alt"),
)

; Display order for the tap-hold tray submenu — mirrors the v1 ``__Order``
; list from ``tap_hold_config.ahk`` (now deleted). Controls both the key
; group ordering and which entries are flat vs sub-Map.
global _TH_GroupOrder := ["CapsLock", "LShiftCopy", "LCtrlPaste", "LAlt",
    "Space", "AltGr", "RCtrl", "TabAlt"]

; i18n keys for each key group (flat and sub-Map alike). Resolved at render
; time via ``t()`` so labels honour the user's locale.
global _TH_KeyI18nKeys := Map(
    "CapsLock",   "tap_hold.group.caps_lock",
    "LShiftCopy", "tap_hold.group.left_shift_copy",
    "LCtrlPaste", "tap_hold.group.left_ctrl_paste",
    "LAlt",       "tap_hold.group.left_alt",
    "Space",      "tap_hold.group.space",
    "AltGr",      "tap_hold.group.alt_gr",
    "RCtrl",      "tap_hold.group.right_ctrl",
    "TabAlt",     "tap_hold.group.tab_alt",
)

; Variant labels are derived at render time from the variant's (tap, hold) tuple
; via ``TapHoldVariantLabel`` — no per-variant string table needed. The tuple
; already contains the action and modifier ids, which are looked up in the
; ``tap_hold.action.*`` and ``tap_hold.modifier.*`` / ``tap_hold.layer.*``
; i18n keys and assembled with the ``tap_hold.template.*`` templates.





; ==================================
; ==================================
; ======= 2/ Variants lookup =======
; ==================================
; ==================================

; Resolve the variants table for a given v1 sub-Map key id. Returns ``false``
; when the key is a flat entry (or unknown).
_TH_VariantsForV1Key(V1KeyId) {
    global _TH_CapsLockVariants, _TH_LAltVariants, _TH_AltGrVariants
    global _TH_RCtrlVariants, _TH_SpaceVariants
    switch V1KeyId {
        case "CapsLock": return _TH_CapsLockVariants
        case "LAlt":     return _TH_LAltVariants
        case "AltGr":    return _TH_AltGrVariants
        case "RCtrl":    return _TH_RCtrlVariants
        case "Space":    return _TH_SpaceVariants
    }
    return false
}





; ==============================
; ==============================
; ======= 3/ Menu labels =======
; ==============================
; ==============================

; Return the i18n-resolved display label for a tap-hold key group (used as
; the parent submenu title for sub-Map keys, or the single menu item label
; for flat keys). Falls back to the raw ``V1KeyId`` when no i18n key exists.
TapHoldGroupLabel(V1KeyId) {
    global _TH_KeyI18nKeys
    if _TH_KeyI18nKeys.Has(V1KeyId) {
        return t(_TH_KeyI18nKeys[V1KeyId])
    }
    return V1KeyId
}

; Return the i18n-resolved display label for a tap-hold variant. Builds the
; label dynamically from the variant's (tap_action, hold_modifier / hold_layer)
; tuple and the generic ``tap_hold.template.*`` / ``tap_hold.action.*`` /
; ``tap_hold.modifier.*`` / ``tap_hold.layer.*`` i18n keys. Falls back to the
; raw ``"V1KeyId.Variant"`` string when the tuple cannot be resolved.
TapHoldVariantLabel(V1KeyId, Variant) {
    Tuple := _TH_ResolveTuple(V1KeyId, Variant)
    if (Tuple == false) {
        return V1KeyId . "." . Variant
    }
    GroupLabel := TapHoldGroupLabel(V1KeyId)
    TapLabel   := t("tap_hold.action." . Tuple["tap"])
    if Tuple.Has("hold_mod") {
        ModLabel := t("tap_hold.modifier." . Tuple["hold_mod"])
        return Format(t("tap_hold.template.tap_hold_mod"), GroupLabel, TapLabel, ModLabel)
    }
    if Tuple.Has("hold_layer") {
        LayerLabel := t("tap_hold.layer." . Tuple["hold_layer"])
        return Format(t("tap_hold.template.tap_hold_layer"), GroupLabel, TapLabel, LayerLabel)
    }
    ; Tap-only variant.
    return Format(t("tap_hold.template.tap_only"), GroupLabel, TapLabel)
}

; Return true when ``V1KeyId`` is a sub-Map group (has variant entries), false
; for flat keys. Used by the tray-menu builder to decide whether to create a
; child submenu or a single toggle item.
TapHoldIsSubMapGroup(V1KeyId) {
    return (_TH_VariantsForV1Key(V1KeyId) != false)
}

; Return an ordered array of [VariantName, ...] for a sub-Map group.
; Returns an empty array for flat keys.
TapHoldVariantNames(V1KeyId) {
    Variants := _TH_VariantsForV1Key(V1KeyId)
    if (Variants == false) {
        return []
    }
    Names := []
    for Name, _ in Variants {
        Names.Push(Name)
    }
    return Names
}

; Return the ordered array of v1 key ids for the tap-hold tray submenu.
TapHoldGroupOrder() {
    global _TH_GroupOrder
    return _TH_GroupOrder
}





; ===============================
; ===============================
; ======= 4/ Batch writer =======
; ===============================
; ===============================

; Accept a sequence of ``Map("v1_path" => "TapHolds.<id>(.<variant>).Enabled",
; "value" => bool)`` entries and apply them to TapHold + tap_hold.toml.
; Returns the number of v2 key entries mutated.
WriteTapHoldBatch(BatchEntries) {
    global TapHold, _TH_V1KeyIdToV2, _TH_FlatKeyTuples

    if !IsSet(TapHold) {
        try LoggerWarn("TapHoldWriter", "TapHold global unset — skipping batch.")
        return 0
    }
    if !TapHold.Has("keys") {
        TapHold["keys"] := Map()
    }

    ; Group entries by V1 KeyId. For each key, track the per-variant value
    ; (last write wins for a given variant). Flat keys use "" as variant.
    PerKey := Map()
    for Entry in BatchEntries {
        Path := Entry["v1_path"]
        Value := Entry["value"]
        Parts := StrSplit(Path, ".")
        if (Parts.Length >= 1 and Parts[Parts.Length] == "Enabled") {
            Parts.Pop()
        }
        if (Parts.Length < 2 or Parts[1] != "TapHolds") {
            continue
        }
        V1KeyId := Parts[2]
        Variant := (Parts.Length >= 3) ? Parts[3] : ""
        if !PerKey.Has(V1KeyId) {
            PerKey[V1KeyId] := Map()
        }
        PerKey[V1KeyId][Variant] := (Value = true)
    }

    Mutated := 0
    for V1KeyId, VariantValues in PerKey {
        if !_TH_V1KeyIdToV2.Has(V1KeyId) {
            try LoggerWarn("TapHoldWriter", "Unknown TapHolds key '{1}' — skipped.", V1KeyId)
            continue
        }
        V2KeyId := _TH_V1KeyIdToV2[V1KeyId]

        ; Find which variant ends up active. For flat keys, the only entry
        ; is the empty-string variant; for sub-Map keys, scan for the
        ; variant whose final value is true.
        ; ``ActiveVariant`` starts as false (unset sentinel) so it can be
        ; distinguished from the empty-string variant used by flat keys.
        ActiveVariant := false
        for V, Val in VariantValues {
            if Val {
                ActiveVariant := V
                ; Don't break — last true write wins (insertion order is
                ; preserved per AHK v2 Map docs).
            }
        }

        if (ActiveVariant == false) {
            ; No variant active for this key — remove the entry entirely.
            if TapHold["keys"].Has(V2KeyId) {
                TapHold["keys"].Delete(V2KeyId)
                Mutated++
            }
            continue
        }

        ; Resolve the v2 tuple for the active variant.
        Tuple := _TH_ResolveTuple(V1KeyId, ActiveVariant)
        if (Tuple == false) {
            try LoggerWarn("TapHoldWriter",
                "Unknown variant '{1}.{2}' — skipped.", V1KeyId, ActiveVariant)
            continue
        }

        ; Build the new entry. Preserve TimeActivationSeconds from the
        ; existing key entry when present.
        NewEntry := Map("tap_action", Tuple["tap"])
        if Tuple.Has("hold_mod") {
            NewEntry["hold_modifier"] := Tuple["hold_mod"]
        } else if Tuple.Has("hold_layer") {
            NewEntry["hold_layer"] := Tuple["hold_layer"]
        }
        if (TapHold["keys"].Has(V2KeyId)
            and IsObject(TapHold["keys"][V2KeyId])
            and TapHold["keys"][V2KeyId].Has("time_activation_seconds")) {
            NewEntry["time_activation_seconds"] := TapHold["keys"][V2KeyId]["time_activation_seconds"]
        }
        TapHold["keys"][V2KeyId] := NewEntry
        Mutated++
    }

    if (Mutated > 0) {
        _TH_WriteTapHoldToml()
    }
    return Mutated
}

; Resolve the (tap, hold_mod|hold_layer) tuple for a (V1KeyId, Variant)
; pair. Flat keys ignore the Variant argument.
_TH_ResolveTuple(V1KeyId, Variant) {
    global _TH_FlatKeyTuples
    if _TH_FlatKeyTuples.Has(V1KeyId) {
        return _TH_FlatKeyTuples[V1KeyId]
    }
    Variants := _TH_VariantsForV1Key(V1KeyId)
    if (Variants == false) {
        return false
    }
    if !Variants.Has(Variant) {
        return false
    }
    return Variants[Variant]
}





; ====================================
; ====================================
; ======= 5/ Variant read-back =======
; ====================================
; ====================================

; Return true when the v1 TapHolds variant path corresponds to the tuple
; currently stored in ``TapHold["keys"][V2KeyId]``. Used by the tray menu
; to draw a checkmark next to the active variant — the v1 Features Map is
; rebuilt from static defaults on every Reload, so it cannot reflect the
; user's persisted choice. ``TapHold`` itself IS loaded from tap_hold.toml
; at boot, so it is the authoritative source of "what is currently active".
;
; Accepts paths in either ``TapHolds.<Key>.<Variant>`` (sub-Map) or
; ``TapHolds.<FlatKey>`` (no variant) shape, with or without a trailing
; ``.Enabled`` suffix.
IsTapHoldVariantActive(V1Path) {
    global TapHold, _TH_V1KeyIdToV2

    if !IsSet(TapHold) {
        return false
    }
    Parts := StrSplit(V1Path, ".")
    if (Parts.Length >= 1 and Parts[Parts.Length] == "Enabled") {
        Parts.Pop()
    }
    if (Parts.Length < 2 or Parts[1] != "TapHolds") {
        return false
    }
    V1KeyId := Parts[2]
    Variant := (Parts.Length >= 3) ? Parts[3] : ""

    if !_TH_V1KeyIdToV2.Has(V1KeyId) {
        return false
    }
    V2KeyId := _TH_V1KeyIdToV2[V1KeyId]

    if !TapHold.Has("keys") or !TapHold["keys"].Has(V2KeyId) {
        return false
    }
    Entry := TapHold["keys"][V2KeyId]
    if !(IsObject(Entry) and Type(Entry) == "Map") {
        return false
    }

    Tuple := _TH_ResolveTuple(V1KeyId, Variant)
    if (Tuple == false) {
        return false
    }

    ; Compare tap_action first — every tuple has a "tap" key.
    if !Entry.Has("tap_action") {
        return false
    }
    if (Entry["tap_action"] != Tuple["tap"]) {
        return false
    }

    ; Then compare the hold side. The tuple has either "hold_mod"
    ; (-> hold_modifier in the v2 entry), "hold_layer" (-> hold_layer),
    ; or neither (tap-only variant — entry must also lack both for a match).
    if Tuple.Has("hold_mod") {
        return Entry.Has("hold_modifier") and (Entry["hold_modifier"] = Tuple["hold_mod"])
    }
    if Tuple.Has("hold_layer") {
        return Entry.Has("hold_layer") and (Entry["hold_layer"] = Tuple["hold_layer"])
    }
    ; Tap-only variant — the entry must not declare any hold side.
    return !Entry.Has("hold_modifier") and !Entry.Has("hold_layer")
}





; =======================================
; =======================================
; ======= 6/ tap_hold.toml writer =======
; =======================================
; =======================================

; Rewrite ``<config>/ahk/tap_hold.toml`` from scratch from the current
; in-memory ``TapHold`` global. Preserves the ``layers`` block verbatim
; so any user-customised layer mappings survive a key-section write.
_TH_WriteTapHoldToml() {
    global TapHold, _ConfigDir
    if !IsSet(_ConfigDir) {
        try LoggerWarn("TapHoldWriter", "_ConfigDir unset — cannot persist tap_hold.toml.")
        return
    }
    Path := _ConfigDir . "ahk\tap_hold.toml"

    Lines := []
    Lines.Push("# Auto-generated by Ergopti+ tray-menu writes — hand edits stay safe outside")
    Lines.Push("# the [tap_hold.keys.*] blocks (which get rewritten from scratch on every")
    Lines.Push("# toggle). The [tap_hold.layers.*] sections are emitted verbatim from the")
    Lines.Push("# in-memory state, so customisations made via direct editing round-trip.")
    Lines.Push("")

    ; Keys section.
    if TapHold.Has("keys") {
        for KeyId, Entry in TapHold["keys"] {
            if !(IsObject(Entry) and Type(Entry) == "Map") {
                continue
            }
            Lines.Push("[tap_hold.keys." . KeyId . "]")
            for K, V in Entry {
                Lines.Push(_TH_TomlFormatLine(K, V))
            }
            Lines.Push("")
        }
    }

    ; Layers section — emitted verbatim.
    if TapHold.Has("layers") {
        for LayerId, LayerData in TapHold["layers"] {
            if !(IsObject(LayerData) and Type(LayerData) == "Map") {
                continue
            }
            Lines.Push("[tap_hold.layers." . LayerId . "]")
            ; Top-level layer metadata (description_key etc.).
            for K, V in LayerData {
                if (K == "mappings") {
                    continue  ; mappings emitted as a sub-section below
                }
                Lines.Push(_TH_TomlFormatLine(K, V))
            }
            Lines.Push("")
            if LayerData.Has("mappings") and IsObject(LayerData["mappings"]) {
                Lines.Push("[tap_hold.layers." . LayerId . ".mappings]")
                for K, V in LayerData["mappings"] {
                    Lines.Push(_TH_TomlFormatLine(K, V))
                }
                Lines.Push("")
            }
        }
    }

    Content := ""
    for L in Lines {
        Content .= L . "`r`n"
    }

    try {
        if FileExist(Path) {
            FileDelete(Path)
        }
        FileAppend(Content, Path, "UTF-8-RAW")
        try LoggerDebug("TapHoldWriter", "tap_hold.toml rewritten ({1} key(s)).",
            TapHold.Has("keys") ? TapHold["keys"].Count : 0)
    } catch as Err {
        try LoggerError("TapHoldWriter", "Could not write tap_hold.toml: {1}.", Err.Message)
    }
}

; Format a single ``key = value`` line for tap_hold.toml. Handles strings
; (quoted), booleans, and numbers; arrays and nested tables are not used
; in this schema.
_TH_TomlFormatLine(Key, Value) {
    if (Value = true) {
        return Key . " = true"
    }
    if (Value = false) {
        return Key . " = false"
    }
    if (Type(Value) == "Integer" or Type(Value) == "Float") {
        return Key . " = " . Value
    }
    ; String — quote, escape backslashes and quotes.
    S := String(Value)
    S := StrReplace(S, "\", "\\")
    S := StrReplace(S, '"', '\"')
    return Key . " = `"" . S . "`""
}
