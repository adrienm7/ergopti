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





; =============================================
; =============================================
; ======= 1/ ApplyMasterGatesToFeatures =======
; =============================================
; =============================================

; When a master category gate is off, force every v2 feature in that
; category to ``false`` so #HotIf evaluations on Features short-circuit.
; The on-disk persistence is untouched — flipping the master back on +
; Reload restores the per-feature state from config.toml.
ApplyMasterGatesToFeatures(FeaturesTarget, TapHoldTarget, CategoryGateFn, LogDebugFn := 0) {
		if !(FeaturesTarget is Map)
				throw Error("ApplyMasterGatesToFeatures requires a Features Map target.")
		if !(TapHoldTarget is Map)
				throw Error("ApplyMasterGatesToFeatures requires a TapHold Map target.")
		if !HasMethod(CategoryGateFn, "Call")
				throw Error("ApplyMasterGatesToFeatures requires a category-gate callback.")
		; Validate the canonical manifest before touching either candidate.  A
		; malformed/missing manifest is a startup configuration error, not a reason
		; to silently run an unreviewed duplicate gate table.
		SubGates := _MG_LoadSubCategories()

		; Layout master
		if !CategoryGateFn.Call("Layout") and FeaturesTarget.Has("layout") {
				for V2Id, _ in FeaturesTarget["layout"] {
						FeaturesTarget["layout"][V2Id] := false
				}
		}

		; Shortcuts master
		if !CategoryGateFn.Call("Shortcuts") and FeaturesTarget.Has("shortcuts") {
				for V2Id, V2Val in FeaturesTarget["shortcuts"] {
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
								FeaturesTarget["shortcuts"][V2Id] := false
						}
				}
		}

		; Hotstrings master (includes Personal sub-category).
		if !CategoryGateFn.Call("Hotstrings") and FeaturesTarget.Has("hotstrings") {
				for V2Cat, V2CatMap in FeaturesTarget["hotstrings"] {
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
		;
		; **Sub-category mapping is single-sourced from menu_manifest.json
		; master_gates.sub_categories (MG-3).**
		if CategoryGateFn.Call("Hotstrings") and FeaturesTarget.Has("hotstrings") {
				for SubV1, SubV2 in SubGates {
						; Skip a sub-gate whose feature-group id has no matching key under
						; Features["hotstrings"] BEFORE probing the category gate. A manifest
						; sub-gate that drifted from the Features tree (e.g. dynamic_hotstrings,
						; which intentionally follows the Hotstrings master rather than a standalone
						; CategoryEnabled entry) is inert either way; probing it first calls
						; IsCategoryGated on an unknown category, which logged a spurious
						; "unknown category" WARNING on every single boot.
						if !FeaturesTarget["hotstrings"].Has(SubV2)
								continue
						if !CategoryGateFn.Call(SubV1) {
								for V2Id, V2Val in FeaturesTarget["hotstrings"][SubV2] {
										if (Type(V2Val) == "Map" and V2Val.Has("enabled")) {
												V2Val["enabled"] := false
										}
								}
						}
				}
		}

		; TapHolds master — handled by tap_hold.toml loading; gating drops the
		; TapHold["keys"] entries entirely so TapHoldIsConfigured returns false.
		if !CategoryGateFn.Call("TapHolds") {
				if TapHoldTarget.Has("keys") {
						TapHoldTarget["keys"] := Map()
				}
		}

		if HasMethod(LogDebugFn, "Call")
				try LogDebugFn.Call("MasterGates", "ApplyMasterGatesToFeatures done.")
}





; =============================================================
; =============================================================
; ======= 2/ Manifest-driven Sub-Category Loader (MG-3) =======
; =============================================================
; =============================================================

; Reads and validates hotstring_category_keys from menu_manifest.json.
; The manifest is the sole behavioral definition: failure is explicit so a
; candidate state can never be partially gated by a stale fallback table.
_MG_LoadSubCategories(ManifestPath := "") {
		global _SharedDir
		; NOT memoized, deliberately. Caching the parsed manifest was tried and
		; reverted: it defeats the fail-fast contract that an invalid canonical
		; manifest must throw on EVERY call, which
		; tests/unit/test_master_gates.ahk pins. The re-read was only harmful because
		; ToggleCategoryAllFeatures ran this under Critical; that Critical span was
		; removed (F-01), so a few ms of FileRead + JsonParse per live category toggle
		; no longer sits on the keyboard-hook starvation path and is not worth trading
		; a fail-fast guarantee for.
		FilePath := ManifestPath != "" ? ManifestPath : _SharedDir . "\modules\menu\menu_manifest.json"
		if !FileExist(FilePath) {
				throw Error("Master gate manifest is missing: " . FilePath)
		}
		try Content := FileRead(FilePath, "UTF-8")
		catch as Err
				throw Error("Master gate manifest cannot be read: " . Err.Message)
		if (StrLen(Content) && Ord(SubStr(Content, 1, 1)) = 0xFEFF)
				Content := SubStr(Content, 2)
		if (Content == "") {
				throw Error("Master gate manifest is empty: " . FilePath)
		}
		try Root := JsonParse(Content)
		catch as Err
				throw Error("Master gate manifest is invalid JSON: " . Err.Message)
		if !(Root is Map) or !Root.Has("hotstring_category_keys") {
				throw Error("Master gate manifest lacks hotstring_category_keys.")
		}
		; The generated manifest maps feature group → category label.  Gate
		; application needs the inverse label → feature group relation.
		SourceCats := Root["hotstring_category_keys"]
		if !(SourceCats is Map) {
				throw Error("Master gate manifest has invalid hotstring_category_keys.")
		}
		SubCats := Map()
		for FeatureGroup, GateName in SourceCats
				SubCats[GateName] := FeatureGroup
		if !(SubCats is Map) or SubCats.Count == 0 {
				throw Error("Master gate manifest has no hotstring category keys.")
		}
		for GateName, FeatureGroup in SubCats {
				if (Type(GateName) != "String" || GateName == "" || Type(FeatureGroup) != "String" || FeatureGroup == "")
						throw Error("Master gate manifest contains an invalid sub-category entry.")
		}
		return SubCats
}
