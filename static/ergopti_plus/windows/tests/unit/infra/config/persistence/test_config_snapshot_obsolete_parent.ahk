; tests/unit/infra/config/persistence/test_config_snapshot_obsolete_parent.ahk

; ==============================================================================
; MODULE: Configuration Snapshot Obsolete Parents
; DESCRIPTION:
; A full snapshot keeps an obsolete parent namespace and its source,
; refuses fresh invalid stamps before collection, and keeps personal file
; owners and logical refusals exact.
; ==============================================================================

#Requires AutoHotkey v2.0





; The whole native collector remains real: isolate its unrelated runtime owners
; at their published neutral values, then preserve one actual accepted change.
; Scenario "layout-array" puts a foreign table-array generation inside the
; [layout] namespace the full save writes, between its owned leaf and the next
; table (full-snapshot-layout-table-array).
_FMS_FullSnapshotParentSource(Literal, Scenario := "complete") {
	LayoutArray := Scenario == "layout-array"
		? '[[layout."future.rows"]]`nvalue = "first" # kept`n[[layout."future.rows"]]`nvalue = "second"`n' : ""
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[hotstrings]`nautocorrection = ' . Literal . ' # retained until explicit cleanup`n'
		. '[layout]`nergopti_variant = "ergopti"`n' . LayoutArray
		. '[private]`n"literal.dot" = { keep = [1, "x"], date = 1979-05-27, count = 9223372036854775807 } # future source`n'
		. '[[private."future.rows"]]`nvalue = "first"`n[[private."future.rows"]]`nvalue = "second"`n'
}

_FMS_FullSnapshotParent(Path, Literal, Scenario := "complete") {
	global _I18nLocale, LOGGER_MIN_LEVEL, ScriptInformation
	global ConfigurationFile
	global ScriptShortcutAssignments, KeyboardShortcutAssignments, GestureAssignments
	global CategoryEnabled, UPDATER_CHECK_INTERVAL, UPDATER_CHANNEL, _IniCache
	global KEYBOARD_SHORTCUT_DEFAULTS
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, Features
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots, _LOGGER_TEST_SINK
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	State := MasterGateState(), PriorState := State.Clone()
	SavedI18nLocale := IsSet(_I18nLocale) ? _I18nLocale : unset
	SavedLOGGERMINLEVEL := IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : unset
	SavedScriptInformation := IsSet(ScriptInformation) ? ScriptInformation : unset
	SavedScriptShortcutAssignments := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedKeyboardShortcutAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedKeyboardDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	SavedGestureAssignments := IsSet(GestureAssignments) ? GestureAssignments : unset
	SavedCategoryEnabled := IsSet(CategoryEnabled) ? CategoryEnabled : unset
	SavedUPDATERCHECKINTERVAL := IsSet(UPDATER_CHECK_INTERVAL) ? UPDATER_CHECK_INTERVAL : unset
	SavedUPDATERCHANNEL := IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : unset
	SavedIniCache := IsSet(_IniCache) ? _IniCache : unset
	Fields := [
		{ target: MetricsShortcuts, key: "enabled", path: "metrics.enabled" },
		{ target: MetricsFilters, key: "private_browsing", path: "metrics.private_filter_enabled" },
		{ target: MetricsFilters, key: "secure_field", path: "metrics.secure_filter_enabled" },
		{ target: MetricsFilters, key: "system_auth", path: "metrics.system_auth_filter_enabled" },
		{ target: MetricsFilters, key: "encrypt", path: "metrics.encrypt" },
		{ target: WPMWidget, key: "visible", path: "metrics.wpm_widget_visible" },
		{ target: WPMWidget, key: "use_colors", path: "metrics.wpm_widget_colors" },
		{ target: WPMWidget, key: "show_graph", path: "metrics.wpm_widget_graph" }]
	PriorFields := [], PriorApps := MetricsFilters.disabled_apps
	Original := FSReadUtf8Exact(Path), Target := ManifestBuildFeaturesMap()
	BeforeFeatures := _HSDeepCloneMap(Features), Borrowed := 0, Collected := 0
	Foreign := Original . "# external generation during actual collection`n"
	Expected := StrReplace(Original, 'ergopti_variant = "ergopti"`n', 'ergopti_variant = "ergopti_plus"`n')
	FreshAbsentPath := ""
	Collect() {
		Collected += 1
		Rows := _ConfigCollectFullSaveUpdates(Target, false)
		Repeated := 0
		for Row in Rows {
			if Row.Section == "script" && Row.Key == "locale"
				Repeated += 1
		}
		Assert(Repeated >= 2, "the actual whole-state producer has intentional repeated runtime-owner rows")
		if Scenario == "late-neutral"
			Rows.Push({ Section: "hotstrings.autocorrection.names", Key: "enabled", Delete: 1 })
		if Scenario == "source" || Scenario == "absent"
			Assert(FSWriteDurable(Path, Foreign), "the external successor must reach the real filesystem")
		return Rows
	}
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		ApplyBootConfigToml(Target, Path)
		AssertEqual(0, _ConfigBootRejectedOverrides)
		Assert(_ConfigBootOutdatedEntries.Has("hotstrings`nautocorrection"), "the actual loader owns the obsolete parent classification")
		AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
		Target["layout"]["ergopti_variant"] := "ergopti_plus"
		if Scenario == "nonneutral" || Scenario == "late-neutral"
			Target["hotstrings"]["autocorrection"]["names"]["enabled"] := true
		_I18nLocale := "fr", LOGGER_MIN_LEVEL := "INFO"
		ScriptInformation := Map("MagicKey", "★")
		ScriptShortcutAssignments := Map(), KeyboardShortcutAssignments := Map()
		; The headless runner omits feature_state; use its exact manifest default projection.
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KEYBOARD_SHORTCUT_DEFAULTS[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		Assert(KEYBOARD_SHORTCUT_DEFAULTS.Count > 0, "the real collector receives the native manifest-derived keyboard defaults")
		GestureAssignments := Map(), CategoryEnabled := Map(), _IniCache := Map()
		UPDATER_CHECK_INTERVAL := unset, UPDATER_CHANNEL := unset
		MetricsFilters.disabled_apps := Map()
		for Field in Fields {
			PriorFields.Push({ target: Field.target, key: Field.key, value: Field.target.%Field.key% })
			Field.target.%Field.key% := ManifestDefaultFor(Field.path)
		}
		State["initialized"] := false
		if Scenario == "repair" {
			Repair := StrReplace(Original, 'autocorrection = ' . Literal . ' # retained until explicit cleanup`n',
				'[hotstrings.autocorrection.names]`nenabled = true`n')
			Assert(FSWriteDurable(Path, Repair))
			Expected := StrReplace(Repair, 'ergopti_variant = "ergopti"`n', 'ergopti_variant = "ergopti_plus"`n')
			Expected := StrReplace(Expected, "enabled = true`n", "")
			Assert(_ConfigBootOutdatedEntries.Has("hotstrings`nautocorrection"), "the stale warning is deliberately retained")
		}
		if Scenario == "absent" {
			Assert(FSDelete(Path))
			AssertFalse(FileExist(Path), "source admission must observe genuine absence")
			AssertFalse(ConfigSchemaCanPrepareWrite(Path),
				"deleting a booted current source never grants fresh-missing write authority")
			; A distinct exact destination owns the genuine absent-source startup.
			; The original loaded obsolete-parent assertions remain above this transition.
			FreshAbsentPath := Path . ".fresh-absent.toml"
			AssertFalse(FSStrictExists(FreshAbsentPath), "the fresh absent destination is exclusively owned")
			AssertFalse(ConfigMigrateBoot(FreshAbsentPath, "known"), "no old journal identity is reused")
			PreparedAbsent := ConfigSchemaPrepareSource(FreshAbsentPath)
			Assert(PreparedAbsent is Map, "the actual readonly absent constructor must return its result")
			AssertEqual("fresh-missing", PreparedAbsent["status"])
			AssertEqual(1, PreparedAbsent["read_only"])
			AssertFalse(ConfigSchemaCanPrepareWrite(FreshAbsentPath), "readonly absence does not manufacture READY")
			BootAbsent := ConfigMigrateBoot(FreshAbsentPath)
			Assert(BootAbsent is Map, "the same genuine absent source completes actual default Boot")
			AssertEqual("absent", BootAbsent["status"])
			AssertEqual(0, BootAbsent["read_only"])
			AssertTrue(ConfigSchemaCanPrepareWrite(FreshAbsentPath))
			AssertFalse(FSStrictExists(FreshAbsentPath), "absent Boot creates no physical source")
			AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation,
				"source construction and native Boot never invent requested intent")
			ConfigurationFile := FreshAbsentPath
			Path := FreshAbsentPath
			AssertEqual(Path, ConfigurationFile, "collection and the current destination share the exact fresh identity")
		}
		StampRefused := SubStr(Scenario, 1, 6) == "stamp-"
		if StampRefused {
			Registry := ConfigMigrateShippedRegistry()
			Stamp := Scenario == "stamp-invalid" ? '"invalid"'
				: Scenario == "stamp-newer" ? String(Registry["current"] + 1)
				: Scenario == "stamp-older" ? String(Registry["unstamped"])
				: Scenario == "stamp-boolean" ? "true"
				: Scenario == "stamp-fractional" ? String(Registry["current"] + 0.5) : ""
			ChangedSource := Scenario == "stamp-parent"
				? StrReplace(Original, '[_meta]`nschema_version = ' . Registry["current"] . '`n', '_meta = false`n')
				: StrReplace(Original, "schema_version = " . Registry["current"], "schema_version = " . Stamp)
			AssertFalse(ChangedSource == Original, "the actual post-boot schema edit must change physical source")
			Assert(FSWriteDurable(Path, ChangedSource))
			Original := ChangedSource
			AssertEqual("", TOML_WriteRefusal(Path), "fresh admission must not borrow a pre-existing session refusal")
		}
		if Scenario == "schema"
			TOML_RefuseWrites(Path, "invalid schema stamp")
		if Scenario == "borrowed" {
			Borrowed := _ConfigWriteLeaseTryAcquire(Path, "full-parent-test")
			Assert(Borrowed is Object)
		}
		Requested := 0
		NativeLog := [], PriorLogSink := _LOGGER_TEST_SINK
		try {
			LoggerSetTestSink((Line) => NativeLog.Push(Line))
			Result := SaveFullConfig(0, (*) => true, true, Borrowed, Collect, &Requested)
		} finally {
			_LOGGER_TEST_SINK := PriorLogSink
		}
		Trace := ""
		for Line in NativeLog
			Trace .= (Trace != "" ? "`n" : "") . Line
		Diagnostic := " | scenario=" . Scenario . " collected=" . Collected
			. " native_log=" . JsonStringLiteral(Trace)
		if Scenario == "absent" {
			Assert(Requested > 0, "the genuine fresh destination accepted its own exact request")
			AssertEqual(FreshAbsentPath, _ConfigFullSaveBoundPath())
			AssertEqual(FreshAbsentPath, ConfigurationFile)
		}
		if StampRefused || Scenario == "nonneutral" || Scenario == "late-neutral" || Scenario == "source" || Scenario == "absent" || Scenario == "schema" {
			AssertEqual(CONFIG_SAVE_FAILED, Result, "a nonneutral collision or withdrawn source never receives a successful full-save ACK" . Diagnostic)
			ActualSource := FSReadUtf8Exact(Path)
			ExpectedSource := Scenario == "source" || Scenario == "absent" ? Foreign : Original
			AssertEqual(ExpectedSource, ActualSource,
				"the complete retained or external source survives refusal" . Diagnostic
					. " expected=" . JsonStringLiteral(String(ExpectedSource))
					. " actual=" . JsonStringLiteral(String(ActualSource)))
			AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
			if Scenario == "schema" {
				AssertEqual(0, Collected, "the strict session fence precedes the real collector")
				AssertEqual("invalid schema stamp", TOML_WriteRefusal(Path))
			} else if StampRefused {
				AssertEqual(0, Collected, "the current physical schema stamp is admitted before invoking any collector")
				Assert(Requested > 0 && _ConfigFullSaveHasPending(), "fresh schema refusal retains the exact outstanding request")
				AssertEqual(0, _ConfigFullSaveCoordinator().settled_generation)
				AssertEqual("", TOML_WriteRefusal(Path), "fresh snapshot refusal does not invent a session migration result")
				AssertFalse(FileExist(Path . ".bak"), "refused source admission does not create a backup")
			} else {
				AssertEqual(1, Collected)
				Assert(_ConfigFullSaveHasPending(), "failure retains the exact outstanding request")
			}
		} else {
			AssertEqual(CONFIG_SAVE_OK, Result, "unrelated real snapshot changes can commit while obsolete parents remain" . Diagnostic)
			AssertEqual(1, Collected)
			AssertEqual(Expected, FSReadUtf8Exact(Path), "the complete handwritten physical image changes only admitted owned fields")
			AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
			AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
			AssertFalse(_ConfigFullSaveHasPending())
			Doc := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual("ergopti_plus", Doc["layout"]["ergopti_variant"])
			if Scenario == "repair"
				Assert(Doc["hotstrings"]["autocorrection"]["names"] is Map && Doc["hotstrings"]["autocorrection"]["names"].Count == 0)
			else
				Assert(TOML_SameValue(TOML_ParseDocument(Original)["hotstrings"], Doc["hotstrings"]), "the obsolete raw model is retained without normalization")
			Assert(TOML_SameValue(TOML_ParseDocument(Original)["private"], Doc["private"]), "quoted future fields, dates, maximum integers and table-array generations remain unchanged")
			if Scenario == "layout-array"
				Assert(TOML_SameValue(TOML_ParseDocument(Original)["layout"]["future.rows"], Doc["layout"]["future.rows"]),
					"a table array inside a written namespace keeps every generation")
			Restart := Path . ".restart.toml"
			try {
				Assert(FSWriteCreateDurable(Restart, Expected))
				; A fresh process first gives this exact source to the genuine
				; readonly journal. Reading alone never creates writer readiness.
				PreparedRestart := ConfigSchemaPrepareSource(Restart)
				AssertEqual("current", PreparedRestart["status"])
				AssertEqual(1, PreparedRestart["read_only"])
				AssertTrue(FSUtf8ExactMatches(Restart, Expected), "readonly restart construction preserves the complete independent source image")
				AssertFalse(ConfigSchemaCanPrepareWrite(Restart), "the native restart reader does not manufacture completed Boot")
				Reloaded := ManifestBuildFeaturesMap()
				ApplyConfigToml(Reloaded, Restart, &Rejected, , &Outdated)
				AssertEqual(0, Rejected)
				AssertEqual("ergopti_plus", Reloaded["layout"]["ergopti_variant"])
				AssertFalse(Reloaded["hotstrings"]["autocorrection"]["names"]["enabled"])
				if Scenario != "repair"
					Assert(Outdated.Has("hotstrings`nautocorrection"))
				AssertEqual(Expected, FSReadUtf8Exact(Restart))
			} finally {
				for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
					if Store.Has(Restart)
						Store.Delete(Restart)
				}
				if FileExist(Restart)
					FSDelete(Restart)
			}
		}
		_FMS_AssertExactTree(BeforeFeatures, Features)
		if Borrowed is Object {
			Assert(_ConfigWriteLeaseOwns(Borrowed, Path), "a full save never releases its borrowed owner")
			AssertFalse(_ConfigWriteLeaseTryAcquire(Path, "intruder"))
		}
	} finally {
		if Borrowed is Object
			_ConfigWriteLeaseRelease(Borrowed)
		for Field in PriorFields
			Field.target.%Field.key% := Field.value
		MetricsFilters.disabled_apps := PriorApps
		_I18nLocale := IsSet(SavedI18nLocale) ? SavedI18nLocale : unset
		LOGGER_MIN_LEVEL := IsSet(SavedLOGGERMINLEVEL) ? SavedLOGGERMINLEVEL : unset
		ScriptInformation := IsSet(SavedScriptInformation) ? SavedScriptInformation : unset
		ScriptShortcutAssignments := IsSet(SavedScriptShortcutAssignments) ? SavedScriptShortcutAssignments : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboardShortcutAssignments) ? SavedKeyboardShortcutAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedKeyboardDefaults) ? SavedKeyboardDefaults : unset
		GestureAssignments := IsSet(SavedGestureAssignments) ? SavedGestureAssignments : unset
		CategoryEnabled := IsSet(SavedCategoryEnabled) ? SavedCategoryEnabled : unset
		UPDATER_CHECK_INTERVAL := IsSet(SavedUPDATERCHECKINTERVAL) ? SavedUPDATERCHECKINTERVAL : unset
		UPDATER_CHANNEL := IsSet(SavedUPDATERCHANNEL) ? SavedUPDATERCHANNEL : unset
		_IniCache := IsSet(SavedIniCache) ? SavedIniCache : unset
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		if FreshAbsentPath != "" {
			; Retire only this fixture's extra physical file and ordinary parse caches.
			; The native journal row and accepted-intent stores are never cleared.
			for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
				if Store.Has(FreshAbsentPath)
					Store.Delete(FreshAbsentPath)
			}
			if FileExist(FreshAbsentPath)
				FSDelete(FreshAbsentPath)
		}
	}
}

_FMS_FullSnapshotParentCase(Literal, Scenario := "complete") {
	_FMS_WithSource("full_parent_" . Scenario . "_" . A_TickCount, _FMS_FullSnapshotParentSource(Literal, Scenario),
		_FMS_FullSnapshotParent.Bind(, Literal, Scenario))
}
Test("full-snapshot-obsolete-parent: actual scalar namespace retains source and unrelated state", _FMS_FullSnapshotParentCase.Bind('false'))
Test("full-snapshot-obsolete-parent: actual string namespace retains source", _FMS_FullSnapshotParentCase.Bind('"old-shape"'))
Test("full-snapshot-obsolete-parent: actual integer namespace retains source", _FMS_FullSnapshotParentCase.Bind('2'))
Test("full-snapshot-obsolete-parent: actual float namespace retains source", _FMS_FullSnapshotParentCase.Bind('2.0'))
Test("full-snapshot-obsolete-parent: actual array namespace retains source", _FMS_FullSnapshotParentCase.Bind('[1, "x"]'))
Test("full-snapshot-obsolete-parent: actual borrowed lease remains owned", _FMS_FullSnapshotParentCase.Bind('false', "borrowed"))
Test("full-snapshot-obsolete-parent: actual nonneutral child refuses complete source", _FMS_FullSnapshotParentCase.Bind('false', "nonneutral"))
Test("full-snapshot-obsolete-parent: later neutral repetition cannot hide a nonneutral child", _FMS_FullSnapshotParentCase.Bind('false', "late-neutral"))
Test("full-snapshot-obsolete-parent: actual collection cannot adopt an external generation", _FMS_FullSnapshotParentCase.Bind('false', "source"))
Test("full-snapshot-obsolete-parent: admitted absence cannot adopt an external creation", _FMS_FullSnapshotParentCase.Bind('false', "absent"))
Test("full-snapshot-obsolete-parent: actual schema fence precedes collection", _FMS_FullSnapshotParentCase.Bind('false', "schema"))
Test("full-snapshot-obsolete-parent: actual repair supersedes stale boot warning", _FMS_FullSnapshotParentCase.Bind('false', "repair"))
Test("full-snapshot-obsolete-parent: fresh invalid string stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-invalid"))
Test("full-snapshot-obsolete-parent: fresh newer stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-newer"))
Test("full-snapshot-obsolete-parent: fresh older migration-eligible stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-older"))
Test("full-snapshot-obsolete-parent: fresh Boolean stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-boolean"))
Test("full-snapshot-obsolete-parent: fresh fractional stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-fractional"))
Test("full-snapshot-obsolete-parent: fresh scalar metadata-parent stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-parent"))
Test("full-snapshot-obsolete-parent: a table array inside the written [layout] namespace survives "
	. "(full-snapshot-layout-table-array)", _FMS_FullSnapshotParentCase.Bind('false', "layout-array"))

_FMS_FullSnapshotScopeAndIndividualStayStrict() {
	Source := '[hotstrings]`nautocorrection = false # retained`n'
	AssertEqual(0, ConfigFullSnapshotCaptureObsoleteSource("").Length, "genuine absence retains the existing unstamped admission contract")
	AssertEqual(1, ConfigFullSnapshotCaptureObsoleteSource(Source).Length, "unstamped source is classified without inventing a migration")
	Delete := { Section: "hotstrings.autocorrection.names", Key: "enabled", Delete: 1 }
	Repeated := [Delete, Delete.Clone()]
	AssertThrows(ConfigScopePreserveObsoleteSource.Bind(Source, Repeated), "ordinary scope batches still refuse duplicate effects")
	AssertEqual(0, ConfigFullSnapshotPreserveObsoleteSource(ConfigFullSnapshotCaptureObsoleteSource(Source), Repeated).Length, "every repeated neutral descendant retains the same obsolete parent")
	Changed := [{ Section: Delete.Section, Key: Delete.Key, Value: true }, Delete]
	AssertThrows(ConfigFullSnapshotPreserveObsoleteSource.Bind(ConfigFullSnapshotCaptureObsoleteSource(Source), Changed), "a later neutral effect cannot hide earlier nonneutral replacement")
	Path := _FM_WriteFixture("full_snapshot_individual_strict", Source)
	Original := FSReadUtf8Exact(Path)
	try {
		AssertFalse(TOML_ConfigBatchWrite(Path, [Delete]), "individual typed writes do not gain full-snapshot preservation semantics")
		AssertEqual(Original, FSReadUtf8Exact(Path))
	} finally {
		if FileExist(Path)
			FSDelete(Path)
	}
}
Test("full-snapshot-obsolete-parent: scope duplicates and individual writer refusal stay strict", _FMS_FullSnapshotScopeAndIndividualStayStrict)

; A file-backed personal category owns its canonical lowercase identity before
; configuration boot. Exact TOML names do not grant a different alias its intent.
_FMS_PersonalFileCaseAliasSource(Name) {
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[hotstrings.personal.' . Name . ']`nenabled = true # exact source owner`n'
		. '[future]`n"literal.dot" = { count = 9223372036854775807, date = 1979-05-27 } # retained`n'
}

_FMS_PersonalFileCaseAlias(Path, Name) {
	global _I18nLocale, LOGGER_MIN_LEVEL, ScriptInformation
	global ScriptShortcutAssignments, KeyboardShortcutAssignments, GestureAssignments
	global KEYBOARD_SHORTCUT_DEFAULTS
	global CategoryEnabled, UPDATER_CHECK_INTERVAL, UPDATER_CHANNEL, _IniCache
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, Features
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots, _ReadPersonalTomlCache
	global _TomlUnreadableFiles, _TomlReadFailures
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	State := MasterGateState(), PriorState := State.Clone()
	SavedI18nLocale := IsSet(_I18nLocale) ? _I18nLocale : unset
	SavedLOGGERMINLEVEL := IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : unset
	SavedScriptInformation := IsSet(ScriptInformation) ? ScriptInformation : unset
	SavedScriptShortcutAssignments := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedKeyboardShortcutAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedKeyboardDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	SavedGestureAssignments := IsSet(GestureAssignments) ? GestureAssignments : unset
	SavedCategoryEnabled := IsSet(CategoryEnabled) ? CategoryEnabled : unset
	SavedUPDATERCHECKINTERVAL := IsSet(UPDATER_CHECK_INTERVAL) ? UPDATER_CHECK_INTERVAL : unset
	SavedUPDATERCHANNEL := IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : unset
	SavedIniCache := IsSet(_IniCache) ? _IniCache : unset
	Fields := [
		{ target: MetricsShortcuts, key: "enabled", path: "metrics.enabled" },
		{ target: MetricsFilters, key: "private_browsing", path: "metrics.private_filter_enabled" },
		{ target: MetricsFilters, key: "secure_field", path: "metrics.secure_filter_enabled" },
		{ target: MetricsFilters, key: "system_auth", path: "metrics.system_auth_filter_enabled" },
		{ target: MetricsFilters, key: "encrypt", path: "metrics.encrypt" },
		{ target: WPMWidget, key: "visible", path: "metrics.wpm_widget_visible" },
		{ target: WPMWidget, key: "use_colors", path: "metrics.wpm_widget_colors" },
		{ target: WPMWidget, key: "show_graph", path: "metrics.wpm_widget_graph" }]
	PriorFields := [], PriorApps := MetricsFilters.disabled_apps
	SavedFeatures := Features
	SavedPersonalCache := _ReadPersonalTomlCache
	PersonalPath := Path . ".personal_hotstrings.toml", Restart := Path . ".restart.toml"
	; Retain only diagnostics belonging to these two newly owned paths. Store
	; the actual prior value reference, including false or object sentinels.
	OwnedDiagnostics := []
	for Extra in [Restart, PersonalPath] {
		for Store in [_TomlUnreadableFiles, _TomlReadFailures] {
			Present := Store.Has(Extra)
			OwnedDiagnostics.Push({ store: Store, key: Extra, present: Present,
				value: Present ? Store[Extra] : false })
		}
		Store := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Extra)
		Present := Store.Has(Key)
		OwnedDiagnostics.Push({ store: Store, key: Key, present: Present,
			value: Present ? Store[Key] : false })
	}
	PersonalSource := Chr(0xFEFF) . '[_meta]`nsections_order = ["owned"]`n'
		. '[[owned]]`n"zz_owned_probe" = { output = "PRIVATE", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
	Original := FSReadUtf8Exact(Path)
	Canonical := StrCompare(Name, "owned", true) == 0
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		_I18nLocale := "fr", LOGGER_MIN_LEVEL := "INFO"
		ScriptInformation := Map("MagicKey", "★")
		ScriptShortcutAssignments := Map(), KeyboardShortcutAssignments := Map()
		; The headless runner omits feature_state; use its exact manifest default projection.
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KEYBOARD_SHORTCUT_DEFAULTS[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		Assert(KEYBOARD_SHORTCUT_DEFAULTS.Count > 0, "the real alias collector receives the native manifest-derived keyboard defaults")
		GestureAssignments := Map(), CategoryEnabled := Map(), _IniCache := Map()
		UPDATER_CHECK_INTERVAL := unset, UPDATER_CHANNEL := unset
		MetricsFilters.disabled_apps := Map()
		for Field in Fields {
			PriorFields.Push({ target: Field.target, key: Field.key, value: Field.target.%Field.key% })
			Field.target.%Field.key% := ManifestDefaultFor(Field.path)
		}
		State["initialized"] := false
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		Assert(FSWriteCreateDurable(PersonalPath, PersonalSource), "the actual personal owner must exist on disk")
		_ReadPersonalTomlCache := false
		Features := ManifestBuildFeaturesMap()
		AssertFalse(Features["hotstrings"]["personal"].Has("owned"), "the category must be discovered from the real personal file")
		Model := ReadPersonalToml(true)
		AssertEqual(1, Model["sections_order"].Length)
		AssertEqual("owned", Model["sections_order"][1])
		AssertEqual(1, Model["sections"]["owned"]["entries"].Length)
		AssertEqual("zz_owned_probe", Model["sections"]["owned"]["entries"][1]["trigger"])
		AssertEqual("PRIVATE", Model["sections"]["owned"]["entries"][1]["output"])
		Assert(_PersonalTomlCanonicalSectionOrder(Model, &Detail) is Array,
			"the genuine personal file passes the actual canonical owner contract")
		UpperModel := _HSDeepCloneMap(Model)
		UpperModel["sections"] := Map("Owned", UpperModel["sections"]["owned"])
		UpperModel["sections_order"] := ["Owned"]
		AssertFalse(_PersonalTomlCanonicalSectionOrder(UpperModel, &UpperDetail),
			"a distinct uppercase personal owner is outside the actual canonical file contract")
		Assert(InStr(UpperDetail, "lowercase", true) > 0)
		for Section in Model["sections_order"] {
			if Section != "-"
				EnsurePersonalHotstringFeature(Section)
		}
		ActualNames := []
		for Key in Features["hotstrings"]["personal"] {
			if StrCompare(Key, "owned", true) == 0
				ActualNames.Push(Key)
		}
		AssertEqual(1, ActualNames.Length, "the real boot owner seeds exactly the stored lowercase category")
		AssertFalse(Features["hotstrings"]["personal"]["owned"]["enabled"])
		Snapshot := ConfigTomlReadSnapshot(Path)
		Exact := Snapshot.Document["hotstrings"]["personal"]
		AssertEqual("On", Exact.CaseSense)
		AssertTrue(Exact.Has(Name))
		AssertFalse(Exact.Has(Canonical ? "Owned" : "owned"), "the typed source must not collapse aliases")
		AssertEqual("On", Snapshot.Cache.CaseSense)
		AssertTrue(Snapshot.Cache.Has("hotstrings.personal." . Name))
		AssertFalse(Snapshot.Cache.Has("hotstrings.personal." . (Canonical ? "Owned" : "owned")))
		Assert(ApplyBootConfigToml(Features, Path) >= 0, "the real configured boot reader must admit the complete source")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(Original, FSReadUtf8Exact(Path), "boot must preserve the exact case-distinct physical source")
		AssertEqual(Canonical, Features["hotstrings"]["personal"]["owned"]["enabled"],
			"only the canonical file-backed owner may receive the persisted enabled intent")
		Collect() => _ConfigCollectFullSaveUpdates(Features, false)
		Requested := 0
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested),
			"the actual whole-state collector and native writer must acknowledge an ordinary save")
		AssertEqual(Original, FSReadUtf8Exact(Path), "ordinary save retains the exact original source without normalizing the alias")
		AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath), "configuration save must not rewrite the actual personal owner")
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		Assert(FSWriteCreateDurable(Restart, Original))
		; Restart reads this new exact destination through its genuine readonly owner.
		AssertFalse(ConfigMigrateBoot(Restart, "known"), "restart owns a fresh journal identity")
		PreparedRestart := ConfigSchemaPrepareSource(Restart)
		Assert(PreparedRestart is Map, "the real readonly restart constructor returns its result")
		AssertEqual("current", PreparedRestart["status"])
		AssertEqual(1, PreparedRestart["read_only"])
		AssertTrue(FSUtf8ExactMatches(Restart, Original), "readonly restart construction preserves all independent bytes")
		AssertFalse(ConfigSchemaCanPrepareWrite(Restart), "the restart reader never manufactures completed writer Boot")
		Features := ManifestBuildFeaturesMap()
		_ReadPersonalTomlCache := false
		ReloadedModel := ReadPersonalToml(true)
		for Section in ReloadedModel["sections_order"] {
			if Section != "-"
				EnsurePersonalHotstringFeature(Section)
		}
		AssertFalse(Features["hotstrings"]["personal"]["owned"]["enabled"])
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		Assert(ApplyBootConfigToml(Features, Restart) >= 0, "restart uses a fresh native configuration source identity")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(Canonical, Features["hotstrings"]["personal"]["owned"]["enabled"],
			"the same actual file-backed owner retains the case-sensitive intent boundary after restart")
		AssertEqual(Original, FSReadUtf8Exact(Restart))
		AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath))
	} finally {
		; Native read refusal and migration debt must not outlive this fixture.
		; Restore presence as well as exact prior values; unrelated entries stay.
		for Diagnostic in OwnedDiagnostics {
			if Diagnostic.present
				Diagnostic.store[Diagnostic.key] := Diagnostic.value
			else if Diagnostic.store.Has(Diagnostic.key)
				Diagnostic.store.Delete(Diagnostic.key)
		}
		Features := SavedFeatures
		_ReadPersonalTomlCache := SavedPersonalCache
		for Extra in [Restart, PersonalPath] {
			for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
				if Store.Has(Extra)
					Store.Delete(Extra)
			}
			if FileExist(Extra)
				FSDelete(Extra)
		}
		for Field in PriorFields
			Field.target.%Field.key% := Field.value
		MetricsFilters.disabled_apps := PriorApps
		_I18nLocale := IsSet(SavedI18nLocale) ? SavedI18nLocale : unset
		LOGGER_MIN_LEVEL := IsSet(SavedLOGGERMINLEVEL) ? SavedLOGGERMINLEVEL : unset
		ScriptInformation := IsSet(SavedScriptInformation) ? SavedScriptInformation : unset
		ScriptShortcutAssignments := IsSet(SavedScriptShortcutAssignments) ? SavedScriptShortcutAssignments : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboardShortcutAssignments) ? SavedKeyboardShortcutAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedKeyboardDefaults) ? SavedKeyboardDefaults : unset
		GestureAssignments := IsSet(SavedGestureAssignments) ? SavedGestureAssignments : unset
		CategoryEnabled := IsSet(SavedCategoryEnabled) ? SavedCategoryEnabled : unset
		UPDATER_CHECK_INTERVAL := IsSet(SavedUPDATERCHECKINTERVAL) ? SavedUPDATERCHECKINTERVAL : unset
		UPDATER_CHANNEL := IsSet(SavedUPDATERCHANNEL) ? SavedUPDATERCHANNEL : unset
		_IniCache := IsSet(SavedIniCache) ? SavedIniCache : unset
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}

_FMS_PersonalFileCaseAliases() {
	for Name in ["owned", "Owned"]
		_FMS_WithSource("personal_case_alias_" . Name, _FMS_PersonalFileCaseAliasSource(Name),
			_FMS_PersonalFileCaseAlias.Bind(, Name))
}
Test("configuration snapshot: genuine personal file owner does not transfer case-distinct config intent (config-personal-file-case-alias)",
	_FMS_PersonalFileCaseAliases)

; A real private constructor refusal must not masquerade as physical unreadability.
_FMS_LogicalRegistryRefusalHasNoPhysicalDiagnostic(Path) {
	global _ConfigBootReadFailed
	Before := FSReadUtf8Exact(Path)
	Admission := ConfigMigrateBoot(Path, "capture_read")
	AssertTrue(HasMethod(Admission, "Call"), "the actual original readonly constructor is available before withdrawal")
	CanonicalSource := SubStr(Before, 1, 1) == Chr(0xFEFF) ? SubStr(Before, 2) : Before
	AssertTrue(Admission.Call(CanonicalSource, 1))
	Registry := ConfigMigrateShippedRegistry(), Calls := { foreign: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(Registry, "__Enum"))
	try {
		Registry.DefineProp("__Enum", { Call: (This, Arity) =>
			(Calls.foreign += 1, Map.Prototype.__Enum.Call(This, Arity)) })
		Cache := ParseConfigTomlFile(Path)
		AssertEqual(0, Cache.Count, "the genuine schema owner withdrawal still refuses the real reader")
		AssertEqual(0, Calls.foreign, "no revoked registry observer executes before diagnostic refusal")
		AssertFalse(TOML_UnreadableFile(Path), "logical native-owner refusal issues no physical read diagnostic")
		AssertEqual(0, ConfigMigrateBoot(Path, "consume_read_failure"), "public queries cannot mint an observed native failure")
		AssertTrue(_ConfigBootReadFailed)
		AssertFalse(ConfigFullStateCanPersist())
		AssertTrue(FSUtf8ExactMatches(Path, Before))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Registry, "__Enum")
			Registry.DeleteProp("__Enum")
	}
	Repaired := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Repaired, "hotstrings", "trigger_char"))
	AssertFalse(TOML_UnreadableFile(Path))
	AssertEqual(0, Calls.foreign, "exact original registry repair executes no rejected observer")
	AssertTrue(FSUtf8ExactMatches(Path, Before), "legacy source bytes remain independent and unchanged")
}
_FMS_LogicalRegistryRefusalDiagnostic() {
	_FMS_WithSource("logical_refusal_diagnostic", 'hotstrings.trigger_char = "@"`n',
		_FMS_LogicalRegistryRefusalHasNoPhysicalDiagnostic)
}
Test("configuration snapshot: genuine logical owner refusal never issues physical unreadability", _FMS_LogicalRegistryRefusalDiagnostic)


; Observes only the completed actual result. No extra save, native ACK,
; schema constructor, lease acquisition or owner repair runs for diagnosis.
_FMS_TraceClosedFullSaveRefusal(Path, SaveResult, Observed, Original) {
	global TEST_RESULTS_FILE
	Status := (SaveResult is Integer) ? SaveResult : "noninteger"
	Phase := Observed.phase
	if !(Phase is String) || !InStr("|unobserved|source|collector|writer|candidate|native_replace|schema_capture|native_ack_noop|native_ack_image|", "|" . Phase . "|")
		Phase := "noncanonical"
	CollectorEntered := Observed.collector_entered == 1 ? 1 : 0
	CollectorCompleted := Observed.collector_completed == 1 ? 1 : 0
	SchemaAdmitted := ConfigSchemaCanPrepareWrite(Path) ? 1 : 0
	ReadBusy := FileReadActivityBusy(Path) ? 1 : 0
	TerminalActive := _ConfigWriteTerminalIsActive() ? 1 : 0
	Unchanged := FSRead(Path) == Original ? 1 : 0
	; Only a closed message emitted after the actual native ACK refused can
	; establish refusal. Top-level result and source equality remain insufficient.
	NativeAck := (Phase == "native_ack_noop" || Phase == "native_ack_image") ? "0" : "unobserved"
	Line := "# group1-actual-fullsave-refusal: result=" . Status
		. ";phase=" . Phase . ";collector_entered=" . CollectorEntered
		. ";collector_completed=" . CollectorCompleted . ";schema_admitted=" . SchemaAdmitted
		. ";read_busy=" . ReadBusy . ";terminal_active=" . TerminalActive
		. ";source_text_unchanged=" . Unchanged . ";native_ack=" . NativeAck . "`r`n"
	try _TestResultsWrite(TEST_RESULTS_FILE, Line)
}
