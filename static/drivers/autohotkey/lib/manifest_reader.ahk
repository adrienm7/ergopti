; drivers/autohotkey/lib/manifest_reader.ahk

; ==============================================================================
; MODULE: Features Manifest Reader
; DESCRIPTION:
; Thin runtime API on top of the codegen'd ``_generated/features_manifest.ahk``,
; which is produced by ``npm run build:manifest`` from the single source of
; truth at ``_shared/features/manifest.toml``.
;
; FEATURES & RATIONALE:
; 1. Optional include: the generated manifest is gitignored — a fresh clone has
;    no manifest until the user runs ``npm run build:manifest``. The ``*i``
;    flag lets the driver load anyway; every public accessor guards on
;    ``ManifestEnsureLoaded()`` and fails loudly when the manifest is missing.
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
; ``scripts/build-features-manifest.js`` with UTF-8 BOM + CRLF — both are
; required. AHK v2 silently aborts mid-file parsing on encoding drift
; (LF-only, missing BOM, or LF mixed into a CRLF file), which surfaces as
; mysterious partial test registration with no error message. If the
; manifest looks loaded but ``ManifestFeatures()`` returns a short array,
; check the generated file's encoding before debugging the codegen logic.
; ==============================================================================

; Optional include — file is produced by ``npm run build:manifest`` and is
; gitignored. Missing manifest is surfaced by ManifestEnsureLoaded() instead of
; crashing at parse time.
#Include *i ..\_generated\features_manifest.ahk




; ==============================================================
; ==============================================================
; ======= 1. Load guard =======
; ==============================================================
; ==============================================================

; Returns true when ``FEATURES_MANIFEST`` is defined; logs an ERROR and returns
; false otherwise. Public accessors below all call this guard before reading
; the global.
ManifestEnsureLoaded() {
	if !IsSet(FEATURES_MANIFEST) {
		try LoggerError("Manifest",
			"FEATURES_MANIFEST not loaded — run ``npm run build:manifest`` "
			"and reload the driver.")
		return false
	}
	return true
}




; ==============================================================
; ==============================================================
; ======= 2. Public accessors =======
; ==============================================================
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




; ==============================================================
; ==============================================================
; ======= 3. Features Map builder =======
; ==============================================================
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

	Features := Map()
	Features["section_order"] := FEATURES_MANIFEST["section_order"]

	for Entry in FEATURES_MANIFEST["features"] {
		SectionPath := Entry["section"]

		; Strip the ``ahk.`` prefix so call sites use a single nesting level
		; (Features["layout"] rather than Features["ahk"]["layout"]).
		if (StrLen(SectionPath) >= 4 and SubStr(SectionPath, 1, 4) == "ahk.") {
			SectionPath := SubStr(SectionPath, 5)
		}

		; Walk the section path, creating intermediate Maps as needed.
		Cursor := Features
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

	return Features
}
