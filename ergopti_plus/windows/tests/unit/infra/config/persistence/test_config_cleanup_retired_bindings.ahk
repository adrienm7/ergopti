; tests/unit/infra/config/persistence/test_config_cleanup_retired_bindings.ahk

; ==============================================================================
; MODULE: Config Cleanup of Retired Bindings
; DESCRIPTION:
; Retired gesture, script and tap parameters share boot and cleanup
; ownership and survive reload, edits and full saves until an explicit
; cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0





_CUK_RetiredGestureBindingOwnership() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "gesture__removed_gesture_slot__open_url", &Owner))
	AssertEqual("", Owner, "retirement never gets a foreign ownership exemption")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("gesture__removed_gesture_slot__open_url"))
	for Slot in GestureSlotIds() {
		Key := GestureBindingId("gesture", Slot) . "__open_url"
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("gesture__TAP_3__open_url"))
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Gesture__tap_3__open_url"))
}
Test("config: retired native gesture parameters share boot and cleanup ownership (gesture-binding-identity-ownership)",
	_CUK_RetiredGestureBindingOwnership)

_CUK_RetiredGestureWarningOwnership() {
	Dir := _CUK_NewDir()
	try {
		Path := Dir . "\config.toml"
		Key := "gesture__removed_gesture_slot__open_url"
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, Key), "first report uses the config.toml owner")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Key), "duplicate boot/reload report is suppressed")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "gesture__another_removed_slot__open_url"), "another retired row is independently named")
	} finally DirDelete(Dir, true)
}
Test("config: retired gesture warnings deduplicate in the config.toml owner (gesture-binding-identity-warning)",
	_CUK_RetiredGestureWarningOwnership)

_CUK_RetiredGestureBindingsPreserveWholeSource() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "gesture__tap_3__open_url"
	Twin := "Gesture__tap_3__open_url"
	Retired := "gesture__removed_gesture_slot__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("gesture__tap_3", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("gesture__tap_3", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("gesture__tap_3", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("gesture__removed_gesture_slot", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000176")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired gesture source survives native reload, ordinary edit and full save until explicit cleanup (gesture-binding-identity-preservation)",
	_CUK_RetiredGestureBindingsPreserveWholeSource)

; Case twins survive canonicalization; count and uniqueness remain assertions.
_CUK_CanonicalIdentityControls() {
	Upper := Map("section", "Layout", "key", "stale", "kind", "section")
	Lower := Map("section", "layout", "key", "stale", "kind", "section")
	_CUK_AssertIds("layout.stale=section|Layout.stale=section", [Upper, Lower])
	_CUK_AssertIds("layout.stale=section|Layout.stale=section", [Lower, Upper])
	AssertEqual(2, _CUK_CanonicalIds(["Layout.stale=section", "layout.stale=section"]).Length,
		"a case twin is a distinct source identity")
	AssertThrows(_CUK_CanonicalIds.Bind(["layout.stale=section", "layout.stale=section"]),
		"canonicalization must refuse duplicates instead of hiding them")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section", []),
		"an empty actual preview cannot satisfy a nonempty independent expectation")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section", [Upper]),
		"a case near-miss cannot satisfy the expectation")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section|Layout.stale=section", [Lower, Lower]),
		"the right row count cannot conceal a duplicate and missing case twin")
	AssertEqual(ObjPtr(Upper), ObjPtr(_CUK_RequireId([Lower, Upper], "Layout.stale=section")),
		"marker checks select the unique semantic source identity")
	AssertThrows(_CUK_RequireId.Bind([], "Layout.stale=section"),
		"a marker lookup must refuse an absent identity")
	AssertThrows(_CUK_RequireId.Bind([Upper, Upper], "Layout.stale=section"),
		"a marker lookup must refuse ambiguous duplicates")
}
Test("config cleanup fixture: canonical identities keep case twins and reject missing or duplicate rows "
	. "(config-unused-keys-identity-controls)", _CUK_CanonicalIdentityControls)


_CUK_RetiredScriptBindingsPreserveWholeSource() {
	_GSBP_WithPublication(_CUK_RetiredScriptBindingsPreserveWholeSourceBody)
}
_CUK_RetiredScriptBindingsPreserveWholeSourceBody() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "script__script_altgr_enter__open_url"
	Twin := "Script__script_altgr_enter__open_url"
	Retired := "script__removed_script_slot__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("script__script_altgr_enter", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "script__another_retired_slot__open_url"), "each retired script key has a separate warning identity")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("script__script_altgr_enter", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("script__script_altgr_enter", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("script__removed_script_slot", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000276")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired script parameters survive actual reload, edit and full save until cleanup (script-binding-identity)",
	_CUK_RetiredScriptBindingsPreserveWholeSource)

_CUK_RetiredScriptBindingOwnership() {
	_GSBP_WithPublication(_CUK_RetiredScriptBindingOwnershipBody)
}
_CUK_RetiredScriptBindingOwnershipBody() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "script__removed_script_slot__open_url", &Owner))
	AssertEqual("", Owner, "obsolete script parameters stay unread")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("script__removed_script_slot__open_url"))
	for Slot in ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"] {
		Key := GestureBindingId("script", Slot) . "__open_url"
		AssertEqual("current", TomlConfigActionParameterBindingStatus(Key), Slot)
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Script__script_altgr_enter__open_url"))
	; The keyboard owner publishes its own complete slot domain (keyboard-slot-publication).
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("keyboard__removed_slot__open_url"))
}
Test("config: script boot and cleanup consume the same complete published domain (script-binding-identity)",
	_CUK_RetiredScriptBindingOwnership)

_CUK_RetiredTapBindingsPreserveWholeSource() {
	_GTKP_WithPublication(_CUK_RetiredTapBindingsPreserveWholeSourceBody)
}
_CUK_RetiredTapBindingsPreserveWholeSourceBody() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "tap_key__number_row_left__open_url"
	Twin := "Tap_key__number_row_left__open_url"
	Retired := "tap_key__removed_tap_key__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("tap_key__number_row_left", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "tap_key__another_retired_slot__open_url"), "each retired tap key has a separate warning identity")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("tap_key__number_row_left", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("tap_key__number_row_left", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("tap_key__removed_tap_key", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000276")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired tap parameters survive actual reload, edit and full save until cleanup (tap-binding-identity)",
	_CUK_RetiredTapBindingsPreserveWholeSource)

_CUK_RetiredTapBindingOwnership() {
	_GTKP_WithPublication(_CUK_RetiredTapBindingOwnershipBody)
}
_CUK_RetiredTapBindingOwnershipBody() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "tap_key__removed_tap_key__open_url", &Owner))
	AssertEqual("", Owner, "obsolete script parameters stay unread")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("tap_key__removed_tap_key__open_url"))
	global TAP_KEY_ORDER
	for Slot in TAP_KEY_ORDER {
		Key := GestureBindingId("tap_key", Slot) . "__open_url"
		AssertEqual("current", TomlConfigActionParameterBindingStatus(Key), Slot)
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Tap_key__number_row_left__open_url"))
	; The keyboard owner publishes its own complete slot domain (keyboard-slot-publication).
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("keyboard__removed_slot__open_url"))
}
Test("config: tap boot and cleanup consume the same complete published domain (tap-binding-identity)",
	_CUK_RetiredTapBindingOwnership)

_CUK_RetiredTapWarningReason() {
	Dir := _CUK_NewDir()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Path := Dir . "\config.toml"
		Key := "tap_key__removed_tap_key__open_url"
		Source := '[action_parameters]`n' . Key . ' = "https://obsolete.example"`n'
		AssertTrue(FSWriteDurable(Path, Source))
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, Key))
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Key), "boot and reload share the same tap warning identity")
		Warnings := 0, Errors := 0
		for Line in Lines {
			if InStr(Line, "[ERROR]")
				Errors += 1
			if InStr(Line, "[WARNING]") && InStr(Line, "[TomlConfigLoader]") && InStr(Line, Key) {
				Warnings += 1
				AssertTrue(InStr(Line, ConfigBindingIdentityTapRetiredReason()) > 0, "the actual native logger names the tap-key domain")
				AssertFalse(InStr(Line, "no gesture slot of this build has this name") > 0)
				AssertTrue(InStr(Line, "explicit cleanup") > 0)
			}
		}
		AssertEqual(1, Warnings, "the actual warning route must execute exactly once")
		AssertEqual(0, Errors)
		AssertEqual(Source, FSReadUtf8Exact(Path), "warning policy never edits the retired source")
	} finally {
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("config: retired tap warnings name the actual number-row domain (tap-binding-identity-warning)",
	_CUK_RetiredTapWarningReason)
