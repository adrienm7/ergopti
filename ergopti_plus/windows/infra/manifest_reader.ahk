; infra/manifest_reader.ahk

; ==============================================================================
; MODULE: Features Manifest Reader
; DESCRIPTION:
; Thin runtime API on top of the codegen'd ``_generated/features_manifest.ahk``,
; which is produced by ``npm run build:manifest`` from the single source of
; truth at ``_shared/modules/features/manifest.toml``.
;
; FEATURES & RATIONALE:
; 1. Defensive optional include: the generated manifest is committed and
;    drift-gated (``build:domain`` compares it against HEAD), so a normal clone
;    already has it. The ``*i`` flag is a safety net — if the file is ever
;    deleted or not yet regenerated, every public accessor guards on
;    ``ManifestEnsureLoaded()`` and fails loudly instead of crashing at parse.
; 2. Hierarchical Map builder: ``ManifestBuildFeaturesMap`` rebuilds the legacy
;    ``Features`` Map shape from the flat entry list — same nesting semantics
;    as the old hardcoded literal in ``features_config.ahk``, but with v2
;    snake_case keys throughout. A manifest section path is used verbatim: a
;    feature is filed under what it configures (``Features["layout"]``), never
;    under the driver that implements it.
; 3. No namespace translation: until Lot 4 the manifest filed AHK features under
;    an ``ahk.`` silo and this module stripped that prefix on the way in, so
;    several accessors had to accept both the prefixed and stripped spelling and
;    every TOML write had to re-derive which of the two a leaf came from. The
;    silos are gone — one path, one spelling, no translation layer.
;
; NOTE on AHK source encoding (discovered while writing the v2 test suite,
; 2026-05-22): the generated ``features_manifest.ahk`` is emitted by
; ``tools/build/build-features-manifest.js`` with UTF-8 BOM + LF — both are
; required. AHK v2 silently aborts mid-file parsing on encoding drift
; (missing BOM or mixed line endings), which surfaces as
; mysterious partial test registration with no error message. If the
; manifest looks loaded but ``ManifestFeatures()`` returns a short array,
; check the generated file's encoding before debugging the codegen logic.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\personal_file_descriptors.ahk

; Defensive optional include — file is produced by ``npm run build:manifest``,
; committed, and drift-gated. The ``*i`` flag means a missing manifest (deleted
; or not yet regenerated) is surfaced by ManifestEnsureLoaded() instead of
; crashing at parse time.
#Include *i ..\_generated\features_manifest.ahk

; Cached indices for fast O(1) lookup
global _MANIFEST_SECTION_INDEX := Map()
global _MANIFEST_PATH_INDEX    := Map()





; =============================
; =============================
; ======= 1. Load guard =======
; =============================
; =============================

; Returns true when ``FEATURES_MANIFEST`` is defined; logs an ERROR and returns
; false otherwise. Public accessors below all call this guard before reading
; the global.
ManifestEnsureLoaded() {
	global FEATURES_MANIFEST, _MANIFEST_SECTION_INDEX, _MANIFEST_PATH_INDEX
	if !IsSet(FEATURES_MANIFEST) {
		try LoggerError("Manifest",
			"FEATURES_MANIFEST not loaded — run ``npm run build:manifest`` "
			"and reload the driver.")
		return false
	}
	
	; Build indices on first call
	if (_MANIFEST_PATH_INDEX.Count == 0) {
		for _, Entry in FEATURES_MANIFEST["features"] {
			Path := Entry["path"]
			Sec  := Entry["section"]
			_MANIFEST_PATH_INDEX[Path] := Entry
			if !_MANIFEST_SECTION_INDEX.Has(Sec)
				_MANIFEST_SECTION_INDEX[Sec] := []
			_MANIFEST_SECTION_INDEX[Sec].Push(Entry)
		}
	}
	
	return true
}





; ===================================
; ===================================
; ======= 2. Public accessors =======
; ===================================
; ===================================

; Manifest format version string (e.g. "2.0.0").
ManifestVersion() {
	if !ManifestEnsureLoaded() {
		return ""
	}
	global FEATURES_MANIFEST
	return FEATURES_MANIFEST["version"]
}

; Ordered list of top-level section names (drives menu and config.toml order).
ManifestSectionOrder() {
	if !ManifestEnsureLoaded() {
		return []
	}
	global FEATURES_MANIFEST
	return FEATURES_MANIFEST["section_order"]
}

; Map of section path → { description_key, platforms, subsections }.
ManifestSections() {
	if !ManifestEnsureLoaded() {
		return Map()
	}
	global FEATURES_MANIFEST
	return FEATURES_MANIFEST["sections"]
}

; Flat array of feature entries. Each entry is a Map with keys: path, id,
; section, default, type, description_key, platforms (and enum_values when
; type = "enum").
ManifestFeatures() {
	if !ManifestEnsureLoaded() {
		return []
	}
	global FEATURES_MANIFEST
	return FEATURES_MANIFEST["features"]
}

; Return the manifest entries whose ``section`` exactly matches ``SectionPath``
; — e.g. "layout" returns the four Layout features in their declared
; order. The array order in the source manifest is preserved by the codegen
; emitter, so callers can use this directly as the render order.
ManifestFeaturesForSection(SectionPath) {
	if !ManifestEnsureLoaded() {
		return []
	}
	global _MANIFEST_SECTION_INDEX
	return _MANIFEST_SECTION_INDEX.Has(SectionPath) ? _MANIFEST_SECTION_INDEX[SectionPath] : []
}

; Return the manifest entry whose canonical ``path`` matches ``V2Path``.
; Returns ``false`` when no entry matches; callers fall back to whatever
; default they had before (e.g. Features.Description).
ManifestFindEntryByPath(V2Path) {
	if !ManifestEnsureLoaded() {
		return false
	}
	global _MANIFEST_PATH_INDEX
	return _MANIFEST_PATH_INDEX.Has(V2Path) ? _MANIFEST_PATH_INDEX[V2Path] : false
}

; Detached values keep mutable runtime state from changing neutral absence.
ManifestCloneValue(Value) {
	if IsSet(TOML_Bool) && (Value is TOML_Bool)
		return TOML_Bool(Value.Value)
	if Value is Map {
		Copy := Map()
		Copy.CaseSense := Value.CaseSense
		for Key, Child in Value
			Copy[Key] := ManifestCloneValue(Child)
		return Copy
	}
	if Value is Array {
		Copy := []
		for Child in Value
			Copy.Push(ManifestCloneValue(Child))
		return Copy
	}
	return Value
}

; Resolve a whole feature or one of its typed child values.
ManifestValueFor(V2Path, Field) {
	if !ManifestEnsureLoaded()
		throw Error("Configuration manifest is unavailable.")
	Prefix := V2Path
	Suffix := []
	while !(Entry := ManifestFindEntryByPath(Prefix)) {
		Dot := InStr(Prefix, ".", true, -1)
		if !Dot {
			Dynamic := ManifestDynamicEntry(V2Path)
			if Dynamic is Map
				return ManifestCloneValue(Dynamic[Field])
			throw Error("Unknown configuration path: " . V2Path)
		}
		Suffix.InsertAt(1, SubStr(Prefix, Dot + 1))
		Prefix := SubStr(Prefix, 1, Dot - 1)
	}
	Value := Entry[Field]
	for Key in Suffix {
		if !(Value is Map) || !Value.Has(Key)
			throw Error("Unknown configuration path: " . V2Path)
		Value := Value[Key]
	}
	return ManifestCloneValue(Value)
}

; Dynamic user-authored sections have a declared neutral leaf shape.
ManifestDynamicEntry(V2Path, SemanticParts := unset) {
	global FEATURES_MANIFEST
	Prefix := V2Path
	Loop {
		if ManifestFindEntryByPath(Prefix)
			return false
		Dot := InStr(Prefix, ".", true, -1)
		if !Dot
			break
		Prefix := SubStr(Prefix, 1, Dot - 1)
	}
	for _, Scope in FEATURES_MANIFEST["scopes"] {
		for Definition in Scope.Get("dynamic_defaults", []) {
			if IsSet(SemanticParts) {
				PrefixParts := StrSplit(Definition["prefix"], ".")
				if SemanticParts.Length != PrefixParts.Length + Definition["depth"]
					continue
				Matches := true
				for Index, Part in PrefixParts {
					if StrCompare(SemanticParts[Index], Part, true) != 0 {
						Matches := false
						break
					}
				}
				if !Matches
					continue
				Parts := []
				loop Definition["depth"]
					Parts.Push(SemanticParts[PrefixParts.Length + A_Index])
			} else {
				Prefix := Definition["prefix"] . "."
				if SubStr(V2Path, 1, StrLen(Prefix)) != Prefix
					continue
				Tail := SubStr(V2Path, StrLen(Prefix) + 1)
				Parts := StrSplit(Tail, ".")
				if InStr(Tail, "..") || SubStr(Tail, 1, 1) == "." || SubStr(Tail, -1) == "."
					continue
			}
			if Parts.Length != Definition["depth"]
				continue
			if Definition.Has("suffix") && Parts[-1] != Definition["suffix"]
				continue
			return Definition
		}
	}
	return false
}

; The neutral value is the sole interpretation of an absent setting.
ManifestDefaultFor(V2Path) {
	AdditionalDefault := PersonalFilePreferenceDefault(V2Path)
	return AdditionalDefault is Integer ? AdditionalDefault : ManifestValueFor(V2Path, "default")
}

; Recommendations are imported only by an explicit configuration action.
ManifestRecommendedFor(V2Path) => ManifestValueFor(V2Path, "recommended")

; Compare typed nested values before deciding whether a key belongs on disk.
ManifestValuesEqual(Left, Right) {
	if Type(Left) != Type(Right)
		return false
	if Left is Map || Left is Array {
		if (Left is Map ? Left.Count : Left.Length) != (Right is Map ? Right.Count : Right.Length)
			return false
		for Key, Value in Left {
			if !Right.Has(Key) || !ManifestValuesEqual(Value, Right[Key])
				return false
		}
		return true
	}
	return Left == Right
}

; Create one native TOML batch row with explicit deletion intent.
ManifestConfigRow(V2Path, Value := unset, Delete := false) {
	if PersonalFilePreferenceDefault(V2Path) is Integer {
		Parts := TOML_ParseKeyPath(V2Path, true)
		Key := Parts.Pop(), Section := ""
		for Part in Parts
			Section .= (Section == "" ? "" : ".") . TOML_RenderKey(Part)
		Row := { Section: Section, Key: Key }
		if Delete
			Row.Delete := 1
		else
			Row.Value := ManifestCloneValue(Value)
		return Row
	}
	Dot := InStr(V2Path, ".", true, -1)
	if !Dot
		throw Error("Configuration paths require a section and key.")
	Section := ""
	for Part in StrSplit(SubStr(V2Path, 1, Dot - 1), ".") {
		if Part == ""
			throw ValueError("Configuration paths require nonempty segments.")
		Section .= (Section == "" ? "" : ".") . TOML_RenderKey(Part)
	}
	Row := { Section: Section, Key: SubStr(V2Path, Dot + 1) }
	if Delete
		Row.Delete := 1
	else
		Row.Value := ManifestCloneValue(Value)
	return Row
}

; Persist only desired differences from the neutral baseline.
ManifestSparseOperation(V2Path, Value) {
	return ManifestConfigRow(V2Path, Value, ManifestValuesEqual(Value, ManifestDefaultFor(V2Path)))
}

/**
 * Prepares one configuration row without flattening its semantic section names.
 * @param {String} Section Existing TOML section spelling, including quoted names.
 * @param {String} Key Literal leaf identity, separate from section path grammar.
 * @param {Any} Value Native desired value before Boolean serialization.
 * @returns {Object} Native row with explicit neutral deletion or detached value.
 */
ManifestConfigSparseOperation(Section, Key, Value) {
	if !(Section is String) || !(Key is String)
		throw TypeError("Configuration rows require String section and key identities.")
	Parts := Section == "" ? [] : TOML_ParseKeyPath(Section, true)
	Parts.Push(Key)
	Path := ""
	for Part in Parts
		Path .= (Path == "" ? "" : ".") . TOML_RenderKey(Part)
	Dynamic := ManifestDynamicEntry(Path, Parts)
	Default := Dynamic is Map ? ManifestCloneValue(Dynamic["default"]) : ManifestDefaultFor(Path)
	Row := { Section: Section, Key: Key }
	if ManifestValuesEqual(Value, Default)
		Row.Delete := 1
	else
		Row.Value := ManifestCloneValue(Value)
	return Row
}

; Match complete path segments, never adjacent names with a common prefix.
ManifestPathBelongs(Path, Prefix) {
	return Path == Prefix || SubStr(Path, 1, StrLen(Prefix) + 1) == Prefix . "."
}

; Collect a scope and its named children while rejecting registry cycles.
; Excluded receives the paths a restore leaves alone, Kept those a clear does.
ManifestCollectScope(ScopeId, Prefixes, Excluded, Visiting, Definitions := unset, Presets := unset, ParameterDomains := unset, Kept := unset) {
	if !IsSet(Kept)
		Kept := []
	if !IsSet(Definitions)
		Definitions := Map()
	if !IsSet(Presets)
		Presets := Map()
	if !IsSet(ParameterDomains)
		ParameterDomains := Map()
	global FEATURES_MANIFEST
	Scopes := FEATURES_MANIFEST["scopes"]
	if !Scopes.Has(ScopeId) || Visiting.Has(ScopeId)
		throw Error("Unknown or cyclic configuration scope: " . ScopeId)
	Visiting[ScopeId] := true
	Scope := Scopes[ScopeId]
	if Scope.Has("action_parameters") {
		BindingScope := Scope["action_parameters"]
		if BindingScope["restore"] != "remove"
			throw ValueError("Unsupported action parameter restoration policy.")
		for Domain in BindingScope["domains"]
			ParameterDomains[Domain] := true
	}
	for Definition in Scope.Get("dynamic_defaults", [])
		Definitions[Definition] := true
	if Scope.Has("preset") {
		if !(Scope["preset"] is String) || Scope["preset"] == ""
			throw TypeError("Invalid configuration preset owner.")
		Presets[ScopeId] := Scope["preset"]
	}
	for Prefix in Scope["prefixes"]
		Prefixes.Push(Prefix)
	for Path in Scope["restore_exclude"]
		Excluded.Push(Path)
	for Path in Scope.Get("clear_exclude", [])
		Kept.Push(Path)
	for Child in Scope.Get("includes", [])
		ManifestCollectScope(Child, Prefixes, Excluded, Visiting, Definitions, Presets, ParameterDomains, Kept)
	Visiting.Delete(ScopeId)
}

; Produce canonical rows for a selected preset or clear operation.
ManifestScopeOperations(ScopeId, Mode, OwnedPaths := unset, Owners := unset) {
	if !IsSet(Owners)
		Owners := Map()
	if !IsSet(OwnedPaths)
		OwnedPaths := []
	if !(OwnedPaths is Array)
		throw TypeError("Owned scope paths must be an Array.")
	if !ManifestEnsureLoaded() || !(Mode == "recommended" || Mode == "clear")
		throw Error("Invalid configuration scope operation.")
	Prefixes := [], Excluded := [], Kept := [], Rows := []
	Definitions := Map(), ParameterDomains := Map()
	ManifestCollectScope(ScopeId, Prefixes, Excluded, Map(), Definitions, Map(), ParameterDomains, Kept)
	; A restore leaves `restore_exclude` alone and a clear `clear_exclude`:
	; no row is planned, so the stored value stays whatever it is.
	Untouched := Mode == "recommended" ? Excluded : Kept
	for Entry in ManifestFeatures() {
		Selected := false
		for Prefix in Prefixes
			Selected := Selected || ManifestPathBelongs(Entry["path"], Prefix)
		if Mode == "clear" {
			for Prefix in Kept
				Selected := Selected && !ManifestPathBelongs(Entry["path"], Prefix)
		}
		if !Selected
			continue
		; An entry active by default restores its preset when its key is
		; deleted, so the system's behaviour is its off value, written.
		if Mode == "clear" && Entry.Has("cleared") {
			Rows.Push(ManifestConfigRow(Entry["path"], Entry["cleared"]))
			continue
		}
		Values := Map(Entry["path"], Entry["recommended"])
		if Entry["type"] == "feature" {
			Values := Map()
			for Key, Value in Entry["recommended"]
				Values[Entry["path"] . "." . Key] := Value
		}
		for Path, Value in Values {
			Skip := false
			for Prefix in Untouched
				Skip := Skip || ManifestPathBelongs(Path, Prefix)
			if !Skip
				Rows.Push(Mode == "clear" ? ManifestConfigRow(Path, Value, true) : ManifestSparseOperation(Path, Value))
		}
	}
	Emitted := Map()
	for Path in OwnedPaths {
		if !(Path is String)
			throw TypeError("Owned configuration paths must be strings.")
		Definition := ManifestDynamicEntry(Path)
		if !(Definition is Map) {
			Domain := ManifestScopeParameterDomain(Path, Owners)
			if Domain == ""
				throw ValueError("Dynamic scope path is not declared: " . Path)
			if ParameterDomains.Has(Domain) && !Emitted.Has(Path)
				Rows.Push(ManifestConfigRow(Path, , true))
			Emitted[Path] := true
			continue
		}
		if !Definitions.Has(Definition) || Emitted.Has(Path)
			continue
		Skip := false
		for Prefix in Untouched
			Skip := Skip || ManifestPathBelongs(Path, Prefix)
		if !Skip
			Rows.Push(Mode == "clear" ? ManifestConfigRow(Path, , true)
				: ManifestSparseOperation(Path, Definition["recommended"]))
		Emitted[Path] := true
	}
	return Rows
}





; Collect dynamic identities from explicit runtime owners, never user-file keys.
ManifestScopeInventory(ScopeId, Providers, Owners := unset) {
	if !IsSet(Owners)
		Owners := Map()
	if !ManifestEnsureLoaded() || !(Providers is Map)
		throw TypeError("Scope inventory requires named runtime owners.")
	Definitions := Map(), ParameterDomains := Map()
	ManifestCollectScope(ScopeId, [], [], Map(), Definitions, Map(), ParameterDomains)
	Found := Map(), Paths := []
	for Name, Provider in Providers {
		if !(Name is String) || Name == "" || !HasMethod(Provider, "Call")
			throw TypeError("Invalid scope inventory owner.")
		Owned := Provider.Call()
		if !(Owned is Array)
			throw TypeError("Runtime inventory is unavailable: " . Name)
		Loop Owned.Length {
			if !Owned.Has(A_Index) || !(Owned[A_Index] is String)
				throw TypeError("Runtime inventory requires a dense array of paths: " . Name)
			Path := Owned[A_Index]
			Definition := ManifestDynamicEntry(Path)
			; Resolve every supplied path, including paths outside this scope.
			; Unknown owner output must never become permission to remove data.
			Domain := ManifestScopeParameterDomain(Path, Owners)
			if Domain == ""
				ManifestDefaultFor(Path)
			Selected := (Definition is Map && Definitions.Has(Definition)) || ParameterDomains.Has(Domain)
			if Selected && !Found.Has(Path) {
				Found[Path] := true
				Position := 1
				while Position <= Paths.Length && StrCompare(Paths[Position], Path, true) < 0
					Position += 1
				Paths.InsertAt(Position, Path)
			}
		}
	}
	return Paths
}

; Host action owners validate their actual store and return the binding domain.
ManifestScopeParameterDomain(Path, Owners) {
	if !(Owners is Map)
		throw TypeError("Scope parameter ownership requires a Map.")
	if !Owners.Has("action_parameter_domain")
		return ""
	Owner := Owners["action_parameter_domain"]
	if !HasMethod(Owner, "Call")
		throw TypeError("Action parameter ownership is unavailable.")
	Domain := Owner.Call(Path)
	if (Domain is Integer) && Domain == 0
		return ""
	if !(Domain is String)
		throw TypeError("Invalid action parameter domain result.")
	return Domain
}

; Preserve separate-file ownership requests instead of silently applying half a scope.
ManifestScopePlan(ScopeId, Mode, OwnedPaths := unset, Owners := unset) {
	if !IsSet(Owners)
		Owners := Map()
	Operations := ManifestScopeOperations(ScopeId, Mode, IsSet(OwnedPaths) ? OwnedPaths : [], Owners)
	Presets := Map(), Requests := []
	ManifestCollectScope(ScopeId, [], [], Map(), Map(), Presets)
	for Id, Preset in Presets
		Requests.Push({ scope: Id, preset: Preset, mode: Mode })
	return { scope: ScopeId, mode: Mode, operations: Operations, presets: Requests }
}





; =======================================
; =======================================
; ======= 3. Features Map builder =======
; =======================================
; =======================================

; Build a hierarchical Features Map from the flat manifest entries. The output
; mirrors the shape of the legacy ``Features := Map(...)`` literal in
; ``features_config.ahk``, but with v2 snake_case keys. Section paths are used
; verbatim — the Features nesting and the TOML section are the same string, which
; is what lets a write re-derive its section by walking the tree alone.
;
; Example: a manifest entry
;   { path: "layout.ergopti_base", id: "ergopti_base", section: "layout",
;     default: true, ... }
; lands in the returned Map at
;   Features["layout"]["ergopti_base"]  →  true
;
; Table-shaped defaults (e.g. { enabled = true, time_activation_seconds = 0.5 })
; are stored verbatim as nested Maps, mirroring the legacy inline-object shape
; that downstream sites expect.
ManifestBuildFeaturesMap() {
	if !ManifestEnsureLoaded() {
		return Map()
	}
	global FEATURES_MANIFEST

	FeaturesMap := Map()
	FeaturesMap["section_order"] := FEATURES_MANIFEST["section_order"]

	for Entry in FEATURES_MANIFEST["features"] {
		SectionPath := Entry["section"]

		; Walk the section path, creating intermediate Maps as needed.
		Cursor := FeaturesMap
		Parts  := StrSplit(SectionPath, ".")
		for Part in Parts {
			if (Part == "") {
				continue
			}
			if !Cursor.Has(Part) {
				Cursor[Part] := Map()
			}
			Cursor := Cursor[Part]
		}

		; Insert the feature value at its id. Default may be a primitive or a
		; nested Map — both are stored as-is for downstream consumption.
		Cursor[Entry["id"]] := ManifestCloneValue(Entry["default"])
	}

	return FeaturesMap
}
