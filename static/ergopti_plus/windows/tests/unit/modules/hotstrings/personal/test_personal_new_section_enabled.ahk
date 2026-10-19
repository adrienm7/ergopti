; tests/unit/modules/hotstrings/personal/test_personal_new_section_enabled.ahk

; ==============================================================================
; MODULE: New Personal Section Enabled
; DESCRIPTION:
; Issue #96: a category created in the hotstrings editor stayed neutral-off,
; so its hotstrings never loaded and a bundled autocorrection kept firing over
; them ("sru" -> "sur"). Creating a section is the user's choice to use it: the
; editor saves enable exactly the sections they add, through the same durable
; selection owner as the tray, and leave every other section untouched.
; ==============================================================================

#Requires AutoHotkey v2.0





_PNSE_Added() {
	AssertEqual('["metiers"]', KL_JsonEncode(HS_PersonalSectionsAdded(["alpha"], ["alpha", "metiers"])))
	AssertEqual('[]', KL_JsonEncode(HS_PersonalSectionsAdded(["alpha", "Metiers"], ["metiers", "alpha"])),
		"a renamed case or a reorder creates no section")
	AssertEqual('["b","c"]', KL_JsonEncode(HS_PersonalSectionsAdded([], ["-", "b", "c", "b"])),
		"separators and repeats are not sections")
}
Test("personal new section: the save names only the sections it adds (personal-new-section-enabled)", _PNSE_Added)

; The real config writer, personal file reader and Features owner, on fixtures.
_PNSE_Case(Kind) {
	global ScriptInformation, ConfigurationFile, Features, _ReadPersonalTomlCache
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	Saved := { Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile, Features: Features,
		Cache: _ReadPersonalTomlCache, Desired: MasterGateState()["features"],
		Critical: A_IsCritical, Suspended: A_IsSuspended }
	Fixture := _ScopeOwnerFixture()
	PersonalPath := Fixture.directory . "\personal.toml"
	Source := '[_meta]`nsections_order = ["alpha", "metiers"]`n'
		. '[_meta.sections.alpha]`ndescription = "Alpha"`n[_meta.sections.metiers]`ndescription = "Metiers"`n'
		. '[[alpha]]`n"private_alpha" = { output = "Alpha output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[[metiers]]`n"sru" = { output = "SRU", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	Lives := 0
	Live(*) {
		Lives += 1
		return true
	}
	try {
		Critical("Off"), Suspend(false)
		ConfigurationFile := Fixture.path
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		Features := _PersonalTomlCloneDetached(Saved.Features)
		MasterGateState()["features"] := _PersonalTomlCloneDetached(Saved.Desired)
		for Name in ["alpha", "metiers"] {
			if Features["hotstrings"].Has("personal") && Features["hotstrings"]["personal"].Has(Name)
				Features["hotstrings"]["personal"].Delete(Name)
		}
		AssertTrue(FSWriteDurable(PersonalPath, Source))
		_PersonalTomlInvalidateCaches(PersonalPath)
		if Kind == "unknown" {
			; The config owner turns the builder's refusal into a false receipt.
			Refused := false
			try Refused := !HS_EnableNewPersonalSections(["absent"], Map("live", Live))
			catch
				Refused := true
			AssertTrue(Refused, "a section absent from the file is refused, not invented")
			AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "a refusal writes nothing")
			AssertEqual(0, Lives)
			return
		}
		AssertTrue(HS_EnableNewPersonalSections(["metiers"], Map("live", Live)))
		AssertEqual(1, Lives, "the new section applies in-process, like its tray checkbox")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		AssertTrue(Parsed.Has("hotstrings.personal.metiers"), "the choice is durable")
		AssertEqual(true, Parsed["hotstrings.personal.metiers"]["enabled"])
		AssertFalse(Parsed.Has("hotstrings.personal.alpha"), "an existing section keeps its own state")
		AssertTrue(Features["hotstrings"]["personal"]["metiers"]["enabled"], "the live menu and loader see it enabled")
		AssertFalse(Features["hotstrings"]["personal"].Has("alpha") && Features["hotstrings"]["personal"]["alpha"]["enabled"],
			"the untouched section stays as it was")
	} finally {
		ScriptInformation["PersonalTomlPath"] := Saved.Path, ConfigurationFile := Saved.Config
		Features := Saved.Features, MasterGateState()["features"] := Saved.Desired
		_PersonalTomlInvalidateCaches(PersonalPath)
		_ReadPersonalTomlCache := Saved.Cache
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		}
		_ScopeOwnerCleanup(Fixture)
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}
for _PNSE_Kind in ["enable", "unknown"]
	Test("personal new section: " . _PNSE_Kind . " (personal-new-section-enabled)", _PNSE_Case.Bind(_PNSE_Kind))

; Both editors route the sections they create to that owner.
_PNSE_EditorsEnable() {
	Web := _DriverFuncBody("_HsEdWeb_Save")
	AssertContains(Web, "HS_PersonalSectionsAdded(ReadPersonalToml(true)[" . '"sections_order"' . "], order)")
	AssertContains(_DriverFuncBody("_HsEdWeb_EnableAdded"), "HS_EnableNewPersonalSections(Added)")
	AssertContains(_DriverFuncBody("_HsEdWeb_DeferredSaveCompleted"), "_HsEdWeb_EnableAdded(Added)")
	AssertContains(_DriverFuncBody("_NewSection"), "HS_EnableNewPersonalSections([SecName])")
}
Test("personal new section: both editors enable what they create (personal-new-section-enabled)", _PNSE_EditorsEnable)
