; tests/unit/test_personal_reload_bakes_resolved_delay.ahk

; ==============================================================================
; MODULE: Regression — the personal live reload bakes the resolved expansion
;         delay (personal-reload-hardcodes-zero-time-activation)
; DESCRIPTION:
; Four loaders must register a spec identically: LoadHotstringsSection,
; LoadExtTomlFile, _HsCacheRegisterSection and ReloadPersonalSection. The first
; three take TimeActivationSeconds from the resolved cascade
; (HotstringsResolve(...).Delay, which falls back to the 0.75 s global default).
;
; ROOT CAUSE ENCODED: ReloadPersonalSection open-coded its own Options Map and
; pinned that field to the literal 0. Zero is a legal value that DISABLES the
; time gate, so saving anything from the personal-hotstring editor silently
; removed the expansion window every personal spec is registered with at boot —
; for the rest of the session, with no error and no log line. The tooltip kept
; dequeueing its row at the resolved delay while the engine had stopped
; enforcing it, so the preview and the engine permanently disagreed about how
; long the expansion stays armed. The same function had already been patched
; twice to mirror the boot loader (Category, then Priority); this was the
; sibling missed in both passes.
; ==============================================================================

#Requires AutoHotkey v2.0






; ==========================================================
; ==========================================================
; ======= 1/ The reload registers the resolved delay =======
; ==========================================================
; ==========================================================

_PRBD_ReloadBakesTheResolvedDelay() {
	global Features, ScriptInformation
	global _HotstringsOverrides, _HotstringsOverridesPath, HSE_RegistryByGroup
	Section := "reloadtest"
	Group := "personal." . Section

	SavedFeatures := IsSet(Features) ? Features : ""
	SavedOverrides := _HotstringsOverrides
	SavedOverridesPath := _HotstringsOverridesPath
	HSE_RegistryClear()
	; Persistence off: the override setter would otherwise write the developer's
	; real hotstrings config from a test run.
	_HotstringsOverridesPath := ""
	_HotstringsOverrides := Map()
	Features := Map("hotstrings", Map("personal", Map(Section, Map("enabled", true))))
	HotstringsResolveBumpGen()
	try {
		HotstringsSetOverride("personal", Section, "delay", 1.5)
		Data := Map("sections", Map(Section, Map("entries", [
			Map("trigger", "zzq", "output", "AVANT", "is_word", true, "auto_expand", false,
				"is_case_sensitive", false, "final_result", false, "strict_case", false, "priority", "")
		])))

		ReloadPersonalSection(Data, Section, {})

		Assert(HSE_RegistryByGroup.Has(Group),
			"the reload must register into the section's own group")
		Specs := HSE_RegistryByGroup[Group]
		; One trigger can register several specs: _AddTriggerVariants emits a case
		; variant per spelling. Assert the DELAY on every one of them rather than
		; pinning a count — a count is incidental, and the guarantee is that no
		; variant escapes the time gate.
		Assert(Specs.Length >= 1, "the reload must register at least one spec for the trigger")
		for , Spec in Specs {
			Assert(Spec.HasOwnProp("TimeActivationSeconds"),
				"every registered spec must carry a time-activation field at all")
			AssertEqual(1.5, Spec.TimeActivationSeconds,
				"ReloadPersonalSection must bake the RESOLVED expansion delay exactly as the boot loader does. Hardcoding 0 removes the time gate after every editor save — a legal value that fires more often rather than erroring — so the tooltip stops describing the window the engine enforces")
		}
	} finally {
		HSE_RegistryClear()
		_HotstringsOverrides := SavedOverrides
		_HotstringsOverridesPath := SavedOverridesPath
		if (SavedFeatures != "")
			Features := SavedFeatures
		HotstringsResolveBumpGen()
	}
}
Test("personal TOML: the live reload bakes the resolved expansion delay (personal-reload-hardcodes-zero-time-activation)",
	_PRBD_ReloadBakesTheResolvedDelay)






; ======================================================================
; ======================================================================
; ======= 2/ The reload resolves the delay instead of pinning it =======
; ======================================================================
; ======================================================================

; The source half. The behavioural case above can only fail once; this states
; the rule it encodes, so a future rewrite of the Options Map cannot quietly
; reintroduce the literal.
;
; Deliberately scoped to ReloadPersonalSection. LoadExtTomlFile
; (lib/toml/toml_loader.ahk) still pins the same literal zero for extension
; packs — the same class, a different owner, and outside this change.
_PRBD_ReloadResolvesRatherThanPins() {
	Body := _DriverFuncBody("ReloadPersonalSection")
	Assert(Body != "", "ReloadPersonalSection() must exist in the driver source")
	Assert(RegExMatch(Body, 'i)"TimeActivationSeconds"\s*,\s*0\s*[,)]') == 0,
		"ReloadPersonalSection must not pin TimeActivationSeconds to a literal 0 — zero silently DISABLES the expansion time gate, so the divergence from the boot loader shows up as a hotstring that fires MORE often, never as an error")
	Assert(InStr(Body, "HotstringsResolve") > 0,
		"it must read the delay from the same override cascade the boot loader uses, so a section registered live and a section registered at boot enforce the same window")
}
Test("meta hotstrings: the personal live reload resolves its expansion delay",
	_PRBD_ReloadResolvesRatherThanPins)
