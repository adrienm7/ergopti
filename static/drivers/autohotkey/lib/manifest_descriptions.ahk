; lib/manifest_descriptions.ahk

; ==============================================================================
; MODULE: Manifest Descriptions
; DESCRIPTION:
; Resolves the localised label of a feature declared in the manifest
; (``static/drivers/_shared/features/manifest.toml``) by trying its
; ``description_key`` against the current i18n locale, then falling back
; through a derived chain of legacy keys when the canonical key is not in the
; locale JSON yet. The output is the string the tray menu should display,
; with the ``★`` placeholder substituted for the user's configured MagicKey.
;
; FEATURES & RATIONALE:
; 1. The manifest's ``description_key`` (e.g. ``menu.layout.ergopti_base``)
;    aims to be a single canonical i18n key. Many of those keys do not yet
;    exist in the locale JSON files, which use the legacy folded form
;    (``layout.ergoptibase``). This module bridges both formats so the menu
;    builder can read from the manifest without first migrating every
;    locale JSON entry.
; 2. Resolution order (first match wins):
;      a. Direct ``t(description_key)`` lookup.
;      b. Strip the ``menu.`` prefix; try again.
;      c. Same as (b) with underscores removed from each segment.
;      d. Same as (b) but with the ``hotstrings.`` segment dropped (hotstring
;         category entries live at ``<category>.<entry>`` in the JSON).
;      e. (d) with underscores removed.
;      f. Return the raw last segment of the path as a last-resort fallback.
; 3. ``★`` substitution happens after resolution so any locale value that
;    embeds the magic-key placeholder renders the user's actual character.
; ==============================================================================




; ==============================================================
; ==============================================================
; ======= 1/ Resolve description by manifest entry =======
; ==============================================================
; ==============================================================

; Resolve the localised label for a manifest entry (a Map carrying
; ``description_key`` and ``path``). Returns a string ready for the menu.
; ``MenuLabelFromManifestEntry``     -- preferred entry point.
MenuLabelFromManifestEntry(Entry) {
    if !IsObject(Entry) {
        return ""
    }
    DescKey := Entry.Has("description_key") ? Entry["description_key"] : ""
    Path    := Entry.Has("path")            ? Entry["path"]            : ""
    ; The legacy locale JSON files key features by the folded v1 PascalCase
    ; path (``dynamichotstrings.datefr``) — pass it explicitly so the
    ; candidate generator can emit that variant too. V1Path may be empty
    ; when the v2 path doesn't map to a v1 equivalent.
    V1Path := (Path == "") ? "" : V2PathToV1Path(Path)
    return MenuLabelFromDescriptionKey(DescKey, Path, V1Path)
}

; Resolve a localised label given the manifest ``description_key``, the
; canonical v2 ``path``, and the legacy v1 PascalCase path. Each argument
; can be empty — when none of them resolves, the function returns the last
; segment of the path (or the key itself as a last-resort sentinel).
MenuLabelFromDescriptionKey(DescKey, Path := "", V1Path := "") {
    global ScriptInformation

    Candidates := _MenuLabelCandidateKeys(DescKey, Path, V1Path)
    Label := ""
    for Cand in Candidates {
        if (Cand == "") {
            continue
        }
        Resolved := t(Cand)
        if (Resolved != "" and Resolved != Cand) {
            Label := Resolved
            break
        }
    }

    if (Label == "") {
        ; Last-resort fallback: the v2 path's tail segment, or the raw key.
        if (Path != "") {
            Parts := StrSplit(Path, ".")
            Label := Parts[Parts.Length]
        } else {
            Label := DescKey
        }
    }

    if (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
        Label := StrReplace(Label, "★", ScriptInformation["MagicKey"])
    }
    return Label
}




; ==============================================================
; ==============================================================
; ======= 2/ Candidate key generator =======
; ==============================================================
; ==============================================================

; Build the ordered list of i18n keys to try, derived from the manifest
; description_key, the canonical v2 path, and the legacy v1 PascalCase
; path. The legacy locale JSON files use a folded-PascalCase convention:
;   manifest:   ``menu.layout.ergopti_base``
;   locale:     ``layout.ergoptibase``
;   manifest:   ``menu.hotstrings.dynamic.date_fr``
;   locale:     ``dynamichotstrings.datefr``  (v1 category merged + folded)
; so the candidate chain produces all four formats (manifest, v2, v2 +
; folding, v1 + folding) and the first hit wins.
_MenuLabelCandidateKeys(DescKey, Path, V1Path := "") {
    Out := []
    if (DescKey != "") {
        Out.Push(DescKey)
    }

    ; ``menu.X.Y`` -> ``X.Y``
    if (StrLen(DescKey) > 5 and SubStr(DescKey, 1, 5) == "menu.") {
        NoMenu := SubStr(DescKey, 6)
        Out.Push(NoMenu)
        Out.Push(_StripUnderscores(NoMenu))
        ; ``hotstrings.X.Y`` -> ``X.Y``
        if (StrLen(NoMenu) > 11 and SubStr(NoMenu, 1, 11) == "hotstrings.") {
            NoHs := SubStr(NoMenu, 12)
            Out.Push(NoHs)
            Out.Push(_StripUnderscores(NoHs))
        }
    }

    ; Same transformations starting from the v2 path (for entries whose
    ; description_key is missing or non-canonical).
    if (Path != "" and Path != DescKey) {
        Out.Push(Path)
        ; Strip ``ahk.`` prefix.
        Trimmed := Path
        if (StrLen(Trimmed) > 4 and SubStr(Trimmed, 1, 4) == "ahk.") {
            Trimmed := SubStr(Trimmed, 5)
            Out.Push(Trimmed)
        }
        ; ``hotstrings.X.Y`` -> ``X.Y``.
        if (StrLen(Trimmed) > 11 and SubStr(Trimmed, 1, 11) == "hotstrings.") {
            Trimmed := SubStr(Trimmed, 12)
            Out.Push(Trimmed)
        }
        Out.Push(_StripUnderscores(Trimmed))
    }

    ; The legacy v1 PascalCase path folded to lowercase no-underscore is
    ; how the existing locale JSON entries are keyed for most features:
    ;   ``Layout.ErgoptiBase``  -> ``layout.ergoptibase``
    ;   ``DynamicHotstrings.DateFr`` -> ``dynamichotstrings.datefr``
    ;   ``Shortcuts.AltGrLAlt.BackSpace`` -> ``shortcuts.altgrlalt.backspace``
    if (V1Path != "") {
        Out.Push(StrLower(StrReplace(V1Path, "_", "")))
    }

    return Out
}

; Remove underscores from every segment of a dotted key while keeping the
; dots in place. ``layout.ergopti_base`` -> ``layout.ergoptibase``.
_StripUnderscores(Key) {
    return StrReplace(Key, "_", "")
}
