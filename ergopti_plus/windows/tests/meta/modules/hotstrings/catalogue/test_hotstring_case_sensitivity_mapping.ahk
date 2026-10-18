; tests/meta/modules/hotstrings/catalogue/test_hotstring_case_sensitivity_mapping.ahk

; ==============================================================================
; MODULE: Hotstring Loader Case-Sensitivity Mapping
; DESCRIPTION:
; Every hotstring loader reads the TOML is_case_sensitive flag through one
; mapping, so boot, the live editors and the preview index register the same
; casing family for an entry.
; ==============================================================================

#Requires AutoHotkey v2.0

; F-03  The TOML `is_case_sensitive` flag was interpreted in OPPOSITE directions
; by two groups of loaders. Generator semantics, documented at
; hotstring_registry.ahk:132, are `is_case_sensitive = not case_sensitive`:
; TRUE registers the literal trigger only, FALSE registers the cased family.
; hotstrings_cache and personal_toml_io had it right; LoadHotstringsSection
; and LoadExtTomlFile were inverted. Bundled categories short-circuit into
; the cache registrar, so only personal + extension entries were affected —
; the two paths with no corpus coverage. Symptom: the same entry registered
; a different casing family depending on whether it came from boot or from
; Class-wide: no loader may open-code the branch again. This is the assertion
; that would have caught the original inversion, which a per-site test could not.
_A0720HS_AllLoadersShareTheCaseMapping() {
	Helper := _DriverFuncBody("HSE_RegisterFromTomlFlags")
	Assert(Helper != "",
		"HSE_RegisterFromTomlFlags must exist as the single source of truth for the is_case_sensitive -> registrar mapping")

	; TRUE must mean literal-only; FALSE must mean the cased family. Assert the
	; helper's own branch direction, since every loader now inherits it.
	TruePos := InStr(Helper, "CreateHotstring(")
	FalsePos := InStr(Helper, "CreateCaseSensitiveHotstrings(")
	Assert(TruePos > 0 and FalsePos > 0, "the helper must reference both registrars")
	Assert(TruePos < FalsePos,
		"HSE_RegisterFromTomlFlags must map is_case_sensitive=TRUE to CreateHotstring (literal trigger only) and FALSE to CreateCaseSensitiveHotstrings (cased family) — the generator convention is `is_case_sensitive = not case_sensitive`, documented at hotstring_registry.ahk:132")

	; No loader may BRANCH on the flag to pick a registrar — that branch is what
	; drifted. A flagless default is fine: LoadExtTomlFile's simple-entry form
	; (a bare trigger-equals-output pair, no is_case_sensitive field) legitimately registers
	; the cased family unconditionally, so this asserts the absence of the BRANCH,
	; not the absence of the registrar call.
	for _, Fn in ["LoadHotstringsSection", "LoadExtTomlFile", "_HsCacheRegisterSection", "ReloadPersonalSection"] {
		Body := _DriverFuncBody(Fn)
		if (Body == "")
			continue
		Assert(RegExMatch(Body, "if\s+IsCaseSens\b") = 0,
			Fn . " must not branch on IsCaseSens to choose a registrar — route through HSE_RegisterFromTomlFlags. Two of the four open-coded copies had drifted into opposite meanings, so the same entry registered a different casing family depending on which loader ran")
		Assert(RegExMatch(Body, 'if\s+E\["is_case_sensitive"\]') = 0,
			Fn . " must not branch on the entry is_case_sensitive key to choose a registrar — route through HSE_RegisterFromTomlFlags")
	}
}
Test("hotstrings: every loader shares one is_case_sensitive mapping (F-03)",
	_A0720HS_AllLoadersShareTheCaseMapping)
