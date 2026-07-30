; tests/unit/test_marker_substituted_in_replacement.ahk

; ==============================================================================
; MODULE: Regression — the magic-key marker must be substituted in the OUTPUT
; DESCRIPTION:
; Hotstring corpora store the magic key as a fixed U+2605 marker, and every
; loader replaces that marker with the user's configured key before handing the
; pair to the engine. The substitution reached the TRIGGER at every registration
; site but the REPLACEMENT at only one of them.
;
; ROOT CAUSE ENCODED:
; The marker is a placeholder on BOTH sides of an entry — the shipped corpus
; contains entries whose output IS the magic key. Substituting the trigger only
; means the engine emits a literal U+2605 the user never typed and cannot
; produce, while both preview-index builders (hotstring_registry.ahk) substitute
; the marker on both sides. Preview and engine therefore disagree on exactly the
; entries the substitution did not reach, and nothing throws: StrReplace on a
; string with no marker is a no-op, and a replacement containing U+2605 is a
; perfectly valid string to send.
;
; The shipped guard for the first fix was scoped to lib/hotstrings and anchored
; on the cache registrar's own call-site text, so it could only ever police that
; one site — the class of loaders was never covered.
;
; NOTE ON SCOPE: this file covers the loaders in lib/toml/toml_loader.ahk plus
; the cache registrar. The live personal-editor reload path
; (ReloadPersonalSection, lib/hotstrings/personal_toml_io.ahk) is the same class
; and is tracked separately.
; ==============================================================================

#Requires AutoHotkey v2.0

; The corpus marker, written as a codepoint so this test file stays ASCII.
global _MSR_MARKER := Chr(0x2605)
; A user-chosen magic key that is NOT the marker, so a missing substitution is
; observable rather than accidentally correct.
global _MSR_USER_KEY := Chr(0x00F9)   ; "u" with grave accent





; ==========================================================
; ==========================================================
; ======= 1/ Behavioural: what the engine will emit ========
; ==========================================================
; ==========================================================

_MSR_ReplacementCarriesTheUsersMagicKey() {
	global ScriptInformation, HSE_RegistryByGroup, HotstringGroupConfig
	TmpPath := A_Temp . "\ergopti_marker_repl_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldKey  := ScriptInformation["MagicKey"]
	; A section name of its own so the registrations land in a private HSE group
	; and neither disturb nor depend on any other case in the suite.
	Section := "markerrepl"
	Group   := "personal." . Section
	try {
		Content := "[[" . Section . "]]`r`n"
			. '"pv' . _MSR_MARKER . '" = { output = "prevu' . _MSR_MARKER
			. '", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`r`n'
		FileAppend(Content, TmpPath, "UTF-8")

		ScriptInformation["PersonalTomlPath"] := TmpPath
		ScriptInformation["MagicKey"] := _MSR_USER_KEY
		ResetHotstringRecorders()
		LoadHotstringsSection("personal", Section, { TimeActivationSeconds: 0 })

		AssertEqual(1, _Stub_HotstringRegistrations.Length,
			"exactly one entry must register from the synthetic personal TOML")
		Assert(HSE_RegistryByGroup.Has(Group),
			"the entry must land in its own HSE group so its dispatch metadata can be inspected")
		Spec := HSE_RegistryByGroup[Group][1]

		; Control: the trigger side has always been substituted. If this fails the
		; test is not exercising what it thinks it is.
		Assert(InStr(Spec.Trigger, _MSR_USER_KEY) > 0,
			"the TRIGGER must carry the user's magic key — this is the long-standing behaviour the replacement side has to match")

		Assert(InStr(Spec.Replacement, _MSR_USER_KEY) > 0,
			"the REPLACEMENT must carry the user's magic key: the preview index substitutes the marker on both sides, so leaving the output raw makes the tooltip promise one string while the engine types another")
		Assert(InStr(Spec.Replacement, _MSR_MARKER) == 0,
			"no corpus marker may survive into the emitted replacement — it is a U+2605 the user never typed and cannot produce")
	} finally {
		ScriptInformation["PersonalTomlPath"] := OldPath
		ScriptInformation["MagicKey"] := OldKey
		if HSE_RegistryByGroup.Has(Group)
			HSE_RegistryByGroup.Delete(Group)
		; The resolve cascade memoises the personal group's [_meta] under the
		; category key; drop it so the next case does not inherit a config parsed
		; from this throwaway file.
		if HotstringGroupConfig.Has("personal")
			HotstringGroupConfig.Delete("personal")
		if HotstringGroupConfig.Has(TmpPath)
			HotstringGroupConfig.Delete(TmpPath)
		try HotstringsResolveBumpGen()
		try FileDelete(TmpPath)
	}
}





; ============================================================
; ============================================================
; ======= 2/ Structural: the whole class, not one site ========
; ============================================================
; ============================================================

; The dominant failure mode here was "fixed at one site, three siblings
; forgotten". Every function that hands a (Trigger, Output) pair to
; HSE_RegisterFromTomlFlags must normalise BOTH, so the class is asserted
; together rather than one member at a time.
_MSR_EveryTomlLoaderSubstitutesBothSides() {
	for Fn in ["LoadHotstringsSection", "LoadExtTomlFile", "_HsCacheRegisterSection"] {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() must exist in the driver source")
		Assert(InStr(Body, "HSE_RegisterFromTomlFlags") > 0 or InStr(Body, "CreateCaseSensitiveHotstrings") > 0,
			Fn . " must still be a registration site — if it stopped registering, this guard silently stopped guarding anything")
		Assert(RegExMatch(Body, "Trigger\s*:=\s*StrReplace"),
			Fn . " must substitute the corpus marker in the TRIGGER")
		Assert(RegExMatch(Body, "Output\s*:=\s*StrReplace"),
			Fn . " must substitute the corpus marker in the REPLACEMENT too, not only in the trigger — the preview index already does both, and a one-sided substitution makes the tooltip and the engine disagree")
	}
}


Test("hotstrings: a personal entry's replacement carries the user's magic key, not the marker",
	_MSR_ReplacementCarriesTheUsersMagicKey)
Test("hotstrings: every TOML loader substitutes the marker on both trigger and replacement",
	_MSR_EveryTomlLoaderSubstitutesBothSides)
