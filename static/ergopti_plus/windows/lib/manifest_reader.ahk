; lib/manifest_reader.ahk

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
;    snake_case keys throughout and the ``ahk.`` prefix stripped so site code
;    keeps a single level of nesting (``Features["layout"]`` instead of
;    ``Features["ahk"]["layout"]``).
; 3. Dormant until cut-over: until ``features_config.ahk`` is replaced with a
;    call to ``ManifestBuildFeaturesMap``, this module is loaded but unused.
;    Adding it ahead of the cut-over keeps that PR small and reviewable.
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

; Defensive optional include — file is produced by ``npm run build:manifest``,
; committed, and drift-gated. The ``*i`` flag means a missing manifest (deleted
; or not yet regenerated) is surfaced by ManifestEnsureLoaded() instead of
; crashing at parse time.
#Include *i ..\_generated\features_manifest.ahk

; Cached indices for fast O(1) lookup
global _MANIFEST_SECTION_INDEX := Map()
global _MANIFEST_PATH_INDEX    := Map()





; ==============================================================
; =============================
; ======= 1. Load guard =======
; =============================
; ==============================================================

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





; ==============================================================
; ===================================
; ======= 2. Public accessors =======
; ===================================
; ==============================================================

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
; — e.g. "ahk.layout" returns the four Layout features in their declared
; order. The array order in the source manifest is preserved by the codegen
; emitter, so callers can use this directly as the render order.
ManifestFeaturesForSection(SectionPath) {
	if !ManifestEnsureLoaded() {
		return []
	}
	global _MANIFEST_SECTION_INDEX
	return _MANIFEST_SECTION_INDEX.Has(SectionPath) ? _MANIFEST_SECTION_INDEX[SectionPath] : []
}

; Return the manifest entry whose canonical ``path`` matches ``V2Path`` (or
; "ahk." . V2Path for AHK-only sections — the lookup accepts both
; shapes since the rest of the driver works with the stripped form).
; Returns ``false`` when no entry matches; callers fall back to whatever
; default they had before (e.g. Features.Description).
ManifestFindEntryByPath(V2Path) {
	if !ManifestEnsureLoaded() {
		return false
	}
	global _MANIFEST_PATH_INDEX
	if _MANIFEST_PATH_INDEX.Has(V2Path)
		return _MANIFEST_PATH_INDEX[V2Path]
	
	AhkVariant := "ahk." . V2Path
	if _MANIFEST_PATH_INDEX.Has(AhkVariant)
		return _MANIFEST_PATH_INDEX[AhkVariant]

	return false
}

; Resolve the correct (possibly ahk.-prefixed) TOML section for one leaf of the
; already ahk.-stripped in-memory Features tree. ManifestBuildFeaturesMap strips
; the ahk. driver namespace uniformly, so several top-level Features keys (e.g.
; "shortcuts", "metrics", "gestures") merge entries from both a shared
; (unprefixed) manifest section and an ahk.-only one -- walking the stripped
; tree alone cannot recover which namespace a given leaf came from. Looking the
; full leaf path up in the manifest's own path index is the single source of
; truth; every call site that flattens the Features tree into TOML writes
; (_CollectFeatureUpdates, _CollectFeatureFlipUpdates) must resolve through
; this helper instead of re-deriving the section from the stripped nesting.
; @param StrippedLeafPath  Dot path to the leaf as walked in the stripped
;                          Features tree (e.g. "shortcuts.personal.laptop_broken_key",
;                          "gestures.enabled").
; @param FallbackSection   Section to use when the leaf has no direct manifest
;                          entry -- true for every property nested under a
;                          single-entry (table-default) alpha feature (e.g.
;                          "shortcuts.gpt.enabled", "hotstrings.autocorrection.accents.enabled")
;                          since none of those ever carry an ahk. prefix, so the
;                          un-prefixed walked section is already correct.
; @return                  The resolved TOML section.
ManifestResolveFeatureSection(StrippedLeafPath, FallbackSection) {
	Entry := ManifestFindEntryByPath(StrippedLeafPath)
	return (Entry != false) ? Entry["section"] : FallbackSection
}





; ==============================================================
; =======================================
; ======= 3. Features Map builder =======
; =======================================
; ==============================================================

; Build a hierarchical Features Map from the flat manifest entries. The output
; mirrors the shape of the legacy ``Features := Map(...)`` literal in
; ``features_config.ahk``, but with v2 snake_case keys and the ``ahk.`` prefix
; stripped from section paths. Called by the cut-over commit to fully replace
; the hardcoded defaults.
;
; Example: a manifest entry
;   { path: "ahk.layout.ergopti_base", id: "ergopti_base", section: "ahk.layout",
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

		; Strip the ``ahk.`` prefix so call sites use a single nesting level
		; (FeaturesMap["layout"] rather than FeaturesMap["ahk"]["layout"]).
		if (StrLen(SectionPath) >= 4 and SubStr(SectionPath, 1, 4) == "ahk.") {
			SectionPath := SubStr(SectionPath, 5)
		}

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
		Cursor[Entry["id"]] := Entry["default"]
	}

	return FeaturesMap
}
