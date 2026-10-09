; infra/master_gates.ahk

; ==============================================================================
; MODULE: Master Gates application
; DESCRIPTION:
; Retains configuration intent before projecting category gates onto the runtime
; Features and TapHold maps. Input hooks read the effective projection; editors,
; checkmarks, and persistence read the retained choices even while masters are off.
;
; FEATURES & RATIONALE:
; 1. Switches become inactive while pure parameters retain their values. Child
;    editing remains independent of the category master and of the pause fence.
; 2. TapHolds gets the same treatment via ``TapHold["keys"]`` — disabling
;    that master clears the keys Map so ``TapHoldIsConfigured`` returns false
;    for every physical key.
; 3. A registry layout the driver emulates (``Features["layout"]["emulated_layout"]``,
;    modules/keymap/keylayout/) replaces the Ergopti emulation, so the features
;    the manifest declares with superseded_reason_key are turned off the same
;    way: here, on every path that rebuilds Features, and never in the saved
;    configuration. The menu greys their rows with that reason.
; 4. Geometry hotstrings remain an explicit user choice on every layout.
;    Selecting a registry layout never changes their enabled state.
; ============================================================================== 





; =============================================
; =============================================
; ======= 1/ ApplyMasterGatesToFeatures =======
; =============================================
; =============================================

; Holds the configuration intent separately from the maps read by input hooks.
MasterGateState() {
	static State := Map("initialized", false, "features", Map(), "tap_hold", Map())
	return State
}

; Boot owns the sole initialization, after configuration and personal entries load.
MasterGateInitialize(FeaturesTarget, TapHoldTarget, CategoryGateFn, LogDebugFn := 0) {
	State := MasterGateState()
	if State["initialized"]
		throw Error("Master gate desired state is already initialized.")
	DesiredFeatures := _HSDeepCloneMap(FeaturesTarget)
	DesiredTapHold := _HSDeepCloneMap(TapHoldTarget)
	ApplyMasterGatesToFeatures(FeaturesTarget, TapHoldTarget, CategoryGateFn, LogDebugFn)
	State["features"] := DesiredFeatures
	State["tap_hold"] := DesiredTapHold
	State["initialized"] := true
	return true
}

; Ungated domains keep their existing owners; only gated roots need an intent view.
MasterGateDesiredFeatures(FeaturesSource) {
	State := MasterGateState()
	if !State["initialized"]
		return FeaturesSource
	View := FeaturesSource.Clone()
	for Root in ["layout", "shortcuts", "hotstrings"] {
		if State["features"].Has(Root)
			View[Root] := State["features"][Root]
	}
	return View
}

; Tap-hold writers and menu labels consume the retained configuration, not empty runtime keys.
MasterGateDesiredTapHold(TapHoldSource) {
	State := MasterGateState()
	return State["initialized"] ? State["tap_hold"] : TapHoldSource
}

; Only declared switches and alpha activation flags are runtime gates. Parameters
; retain their types and values, including numbers, strings, and alpha options.
_MG_DisableFeatureNode(Node, Prefix) {
	if InStr(Prefix, ".") && Node.Has("enabled") {
		Node["enabled"] := false
		return
	}
	for Key, Value in Node {
		Path := Prefix . "." . Key
		if Value is Map {
			_MG_DisableFeatureNode(Value, Path)
			continue
		}
		Entry := ManifestFindEntryByPath(Path)
		if Path == "layout.ergopti_variant"
			Node[Key] := "ergopti"
		else if (Entry is Map) && Entry.Get("type", "") == "boolean"
			Node[Key] := false
		else if Prefix == "shortcuts.personal" && (Value is Integer) && (Value == 0 || Value == 1)
			Node[Key] := false
	}
}

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
				_MG_DisableFeatureNode(FeaturesTarget["layout"], "layout")
		}

		; A selected registry layout supersedes the Ergopti emulation. After the
		; Layout master: a disabled category has already turned the selection off.
		_MG_SupersedeForEmulatedLayout(FeaturesTarget)

		; Shortcuts master. The key combinations are not among its switches: their
		; slots hold actions, read from config.toml by infra/key_combinations.ahk,
		; and only their own gate (KeyCombinations) governs them, as on macOS.
		if !CategoryGateFn.Call("Shortcuts") and FeaturesTarget.Has("shortcuts") {
				_MG_DisableFeatureNode(FeaturesTarget["shortcuts"], "shortcuts")
		}

		; Hotstrings master (includes Personal sub-category).
		if !CategoryGateFn.Call("Hotstrings") and FeaturesTarget.Has("hotstrings") {
				_MG_DisableFeatureNode(FeaturesTarget["hotstrings"], "hotstrings")
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

; Manifest features an emulated registry layout supersedes: the ones declaring
; superseded_reason_key. The direct-digit override remains independent despite
; its historical declaration; registry layers explicitly yield its owned keys.
; @returns {Array} Their manifest entries.
LayoutSupersededFeatures() {
		Entries := []
		for Entry in ManifestFeatures() {
				if (Entry.Get("superseded_reason_key", "") != "")
						Entries.Push(Entry)
		}
		return Entries
}

; Why the menu greys a feature's row: its superseded_reason_key while a registry
; layout is emulated, "" otherwise.
; @param {Map} ManifestEntry - The feature's manifest entry.
; @param {Map} FeaturesSource - Features Map to read; the live one by default.
; @returns {string} Locale key of the reason, or "".
LayoutSupersededReason(ManifestEntry, FeaturesSource := unset) {
		; These switches choose registry layers too; only Ergopti-specific
		; overlays become unavailable when another source is selected.
		if ManifestEntry["section"] == "layout" && ManifestEntry["id"] != "ergopti_variant"
				return ""
		Reason := ManifestEntry.Get("superseded_reason_key", "")
		if (Reason == "")
				return ""
		Selected := IsSet(FeaturesSource) ? KeylayoutEmulation_SelectedId(FeaturesSource) : KeylayoutEmulation_SelectedId()
		return (Selected != "") ? Reason : ""
}

; Turns the superseded features off in ``FeaturesTarget`` when a registry layout
; is selected there (a non-empty ``emulated_layout`` string).
; @param {Map} FeaturesTarget - The Features Map to update.
; @param {Array} Entries - Manifest entries to supersede (LayoutSupersededFeatures by default).
; @returns {Integer} Number of features turned off.
_MG_SupersedeForEmulatedLayout(FeaturesTarget, Entries := unset) {
		if (KeylayoutEmulation_SelectedId(FeaturesTarget) == "")
				return 0
		if !IsSet(Entries)
				Entries := LayoutSupersededFeatures()
		Count := 0
		for Entry in Entries {
				; The direct-digit override is independent of the selected source.
				if Entry["section"] == "layout" && Entry["id"] == "direct_access_digits"
						continue
				Node := FeaturesTarget
				for Part in StrSplit(Entry["section"], ".") {
						if !(Node is Map) or !Node.Has(Part) {
								Node := 0
								break
						}
						Node := Node[Part]
				}
				Id := Entry["id"]
				if Entry["section"] == "layout" && Id == "ergopti_variant" && (Node is Map) && Node.Get(Id, "ergopti") == "ergopti"
						continue
				if (Node is Map) and Node.Has(Id) and Node[Id] {
						Node[Id] := Entry["section"] == "layout" && Id == "ergopti_variant" ? "ergopti" : false
						Count += 1
				}
		}
		return Count
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
