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
