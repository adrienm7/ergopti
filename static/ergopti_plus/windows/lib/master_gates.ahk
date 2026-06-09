; lib/master_gates.ahk

; ==============================================================================
; MODULE: Master Gates application
; DESCRIPTION:
; Applies the per-category master-toggle gating (``CategoryEnabled`` Map) onto
; ``Features`` at boot, so every #HotIf evaluation reading ``Features["…"]``
; short-circuits to false while the category is master-disabled. The per-feature
; state persisted on disk is NOT touched — it stays in the user's config.toml
; and is restored at next Reload after the master toggle flips back on.
;
; FEATURES & RATIONALE:
; 1. Single source of truth for runtime gating. The tray menu greys out items
;    via ``IsCategoryGated`` (which reads CategoryEnabled directly); this
;    helper neutralises the underlying behaviour by zeroing Features entries
;    so the hotkey path doesn't have to consult two flags.
; 2. TapHolds gets the same treatment via ``TapHold["keys"]`` — disabling
;    that master clears the keys Map so ``TapHoldIsConfigured`` returns false
;    for every physical key.
; ==============================================================================





; ==============================================================
; =============================================
; ======= 1/ ApplyMasterGatesToFeatures =======
; =============================================
; ==============================================================

; When a master category gate is off, force every v2 feature in that
; category to ``false`` so #HotIf evaluations on Features short-circuit.
; The on-disk persistence is untouched — flipping the master back on +
; Reload restores the per-feature state from config.toml.
ApplyMasterGatesToFeatures() {
    global Features

    if !IsSet(Features) {
        return
    }

    ; Layout master
    if !IsCategoryGated("Layout") and Features.Has("layout") {
        for V2Id, _ in Features["layout"] {
            Features["layout"][V2Id] := false
        }
    }

    ; Shortcuts master
    if !IsCategoryGated("Shortcuts") and Features.Has("shortcuts") {
        for V2Id, V2Val in Features["shortcuts"] {
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
                Features["shortcuts"][V2Id] := false
            }
        }
    }

    ; Hotstrings master (includes Personal sub-category).
    if !IsCategoryGated("Hotstrings") and Features.Has("hotstrings") {
        for V2Cat, V2CatMap in Features["hotstrings"] {
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

    ; Per-TOML-file hotstring sub-category gates. Independent of the top
    ; Hotstrings master above: when the top gate is on but a sub-category gate
    ; is off, force ONLY that sub-category's features to false so its sections
    ; neither fire nor preview, while the rest of the hotstrings stay live. The
    ; per-section choices on disk are preserved for when the gate flips back on.
    ; Skipped when the top gate is off (everything was already zeroed above).
    if IsCategoryGated("Hotstrings") and Features.Has("hotstrings") {
        SubGates := Map(
            "Autocorrection",     "autocorrection",
            "DistancesReduction", "distances_reduction",
            "SFBsReduction",      "sfbs_reduction",
            "Rolls",              "rolls",
            "MagicKey",           "magic_key"
        )
        for SubV1, SubV2 in SubGates {
            if !IsCategoryGated(SubV1) and Features["hotstrings"].Has(SubV2) {
                for V2Id, V2Val in Features["hotstrings"][SubV2] {
                    if (Type(V2Val) == "Map" and V2Val.Has("enabled")) {
                        V2Val["enabled"] := false
                    }
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

    try LoggerDebug("MasterGates", "ApplyMasterGatesToFeatures done.")
}
