; tests/unit/infra/config/persistence/test_config_snapshot_inline_records.ahk

; ==============================================================================
; MODULE: Configuration Snapshot Inline Records
; DESCRIPTION:
; Inline owned and foreign namespaces keep their record identity, defaults
; and physical child typing, a full save of an inline leaf survives a fresh
; bootstrap, and the full-state collectors keep exact semantic names.
; ==============================================================================

#Requires AutoHotkey v2.0





; Complete hand-authored models distinguish native values from typed sentinels.
_FMS_AssertExactTree(Expected, Actual) {
	if Expected is TOML_Bool {
		Assert(Actual is TOML_Bool, "typed Boolean source intent remains distinct")
		AssertEqual(Expected.Value, Actual.Value)
	} else if Expected is Map {
		Assert(Actual is Map)
		AssertEqual(Expected.Count, Actual.Count, "the complete independent model retains every member")
		for Key, Child in Expected {
			Assert(Actual.Has(Key), "the exact independent semantic identity exists: " . Key)
			_FMS_AssertExactTree(Child, Actual[Key])
		}
	} else if Expected is Array {
		Assert(Actual is Array)
		AssertEqual(Expected.Length, Actual.Length)
		for Index, Child in Expected
			_FMS_AssertExactTree(Child, Actual[Index])
	} else {
		AssertEqual(Type(Expected), Type(Actual), "native scalar kinds cannot alias one another")
		AssertEqual(Expected, Actual)
	}
}

_FMS_InlineOwnedNamespaces(Path) {
	Snapshot := ConfigTomlReadSnapshot(Path)
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("trigger_char", "@", "autocorrection", Map("names", Map("enabled", TOML_Bool(true)))),
		"category_enabled", Map("hotstrings", TOML_Bool(true))), Snapshot.Document)
	_FMS_AssertExactTree(Map("hotstrings", Map("trigger_char", "@"), "hotstrings.autocorrection", Map("names", Map("enabled", true)),
		"category_enabled", Map("hotstrings", true)), Cache)
	AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
	AssertTrue(IniCacheGet(Cache, "category_enabled", "hotstrings"))
	Assert(Cache["hotstrings.autocorrection"]["names"] is Map,
		"inline feature records retain a native owned-record identity")
	Target := ManifestBuildFeaturesMap()
	AssertEqual(3, ApplyConfigToml(Target, Path, &Rejected, , &Outdated),
		"two owned primitive leaves and one successfully merged feature record apply")
	AssertEqual(0, Rejected)
	AssertEqual(0, Outdated.Count)
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(0.5, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"],
		"an omitted feature child retains its independent shipped default")
	Assert(Target["hotstrings"].Has("french_autocorrection"),
		"an inline namespace cannot replace unrelated seeded siblings")
	AssertFalse(Target["hotstrings"]["autocorrection"].Has("accents"),
		"the actual current manifest has no accents owner in this namespace")
	AssertTrue(Snapshot.Document["hotstrings"]["autocorrection"]["names"]["enabled"].Value)
}
_FMS_InlineNamespaceSpellingsKeepDefaults() {
	_FMS_WithSource("inline_root", 'hotstrings = { trigger_char = "@", autocorrection = { names = { enabled = true } } }`ncategory_enabled = { hotstrings = true }`n',
		_FMS_InlineOwnedNamespaces)
	_FMS_WithSource("inline_section", '[hotstrings]`ntrigger_char = "@"`nautocorrection = { names = { enabled = true } }`n[category_enabled]`nhotstrings = true`n',
		_FMS_InlineOwnedNamespaces)
}
Test("configuration snapshot: inline owned namespaces retain record identity and defaults (config-semantic-snapshot)",
	_FMS_InlineNamespaceSpellingsKeepDefaults)

_FMS_InlineRecordAndPhysicalChildren() {
	Inline := ConfigTomlDecodeSnapshot('shortcuts = { take_note = { enabled = true } }`n')
	Assert(Inline.Cache["shortcuts"]["take_note"] is Map)
	AssertEqual(1, Inline.Rows.Length, "the record must not be flattened into an alternative cache layout")
	AssertEqual("shortcuts", Inline.Rows[1].Section)
	AssertEqual("take_note", Inline.Rows[1].Key)
	AssertTrue(Inline.Cache["shortcuts"]["take_note"]["enabled"])
	Source := '[shortcuts]`ntake_note = { enabled = true }`n'
	_FMS_WithSource("inline_record", Source, _FMS_AssertRecordDefaults)
	Source := '[shortcuts.take_note]`nenabled = true`n'
	_FMS_WithSource("physical_record", Source, _FMS_AssertRecordDefaults)
}
_FMS_AssertRecordDefaults(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path))
	AssertTrue(Target["shortcuts"]["take_note"]["enabled"])
	AssertFalse(Target["shortcuts"]["take_note"]["dated_notes"])
	AssertEqual("D:\Bureau", Target["shortcuts"]["take_note"]["destination_folder"])
}
Test("configuration snapshot: owned inline records match physical child settings without dropping defaults (config-semantic-snapshot)",
	_FMS_InlineRecordAndPhysicalChildren)

_FMS_ChildPoliciesAndFullSave(Path, ExpectedSave) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path, true, false, false)
		ConfigMigrateBoot(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		ParseConfigTomlFile(Path)
		AssertEqual(1, ApplyBootConfigToml(Target, Path), "only the valid timing child applies")
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertFalse(Names["enabled"], "an invalid known Boolean child cannot become truthy")
		AssertEqual(0.25, Names["time_activation_seconds"])
		AssertFalse(Names.Has("future"), "unowned fields are ignored in runtime, retained on disk")
		AssertTrue(_ConfigBootOutdatedEntries.Has("hotstrings.autocorrection.names`nenabled"),
			"the exact child identity, not the parent record, owns neutral-save preservation")
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		BeforeRequested := _ConfigFullSaveCoordinator().requested_generation
		BeforeCommitted := _ConfigFullSaveCoordinator().committed_generation
		AssertEqual(BeforeRequested, BeforeCommitted, "the fixture starts with no uncommitted generation")
		Requested := 0
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue(Result is Integer, "the full-save capability preserves its strict native status type")
		AssertEqual(ExpectedSave, Result,
			"the actual full-save owner acknowledges preserved inline and physical semantic no-ops")
		AssertEqual(BeforeRequested + 1, Requested, "one real request owns one new generation")
		AssertEqual(Requested, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Original, FSRead(Path), "neither outcome may erase the invalid or unowned source child")
		if ExpectedSave == CONFIG_SAVE_OK {
			AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
			AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
			AssertFalse(_ConfigFullSaveHasPending(), "the successful no-op settles exactly its request")
		}
		else
			Assert(_ConfigFullSaveCoordinator().committed_generation < _ConfigFullSaveCoordinator().requested_generation,
				"an inline writer refusal must not acknowledge the requested generation")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_InlineChildRefusalAndPhysicalPreservation() {
	_FMS_WithSource("inline_child", _CMJFixtureCurrentSource('[hotstrings]`nautocorrection = { names = { enabled = "true", time_activation_seconds = 0.25, future = "retain" } } # preserve`n'),
		_FMS_ChildPoliciesAndFullSave.Bind(, CONFIG_SAVE_OK))
	_FMS_WithSource("physical_child", _CMJFixtureCurrentSource('[hotstrings.autocorrection.names]`nenabled = "true" # outdated`ntime_activation_seconds = 0.25`nfuture = "retain" # unknown`n'),
		_FMS_ChildPoliciesAndFullSave.Bind(, CONFIG_SAVE_OK))
}
Test("configuration snapshot: inline child policy and actual full-save fences retain obsolete data (config-semantic-snapshot)",
	_FMS_InlineChildRefusalAndPhysicalPreservation)

_FMS_EmptyNamespaceCannotBorrowRoot(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map('"".layout', Map("ergopti_base", false), 'layout.""', Map("ergopti_base", false),
		'"layout.extra"', Map("ergopti_base", false)), Cache)
	_FMS_AssertExactTree(Map("", Map("layout", Map("ergopti_base", TOML_Bool(false))),
		"layout", Map("", Map("ergopti_base", TOML_Bool(false))), "layout.extra", Map("ergopti_base", TOML_Bool(false))),
		ConfigTomlReadSnapshot(Path).Document)
	AssertFalse(IniCacheGet(Cache, '"".layout', "ergopti_base"))
	AssertFalse(IniCacheGet(Cache, 'layout.""', "ergopti_base"))
	AssertFalse(IniCacheGet(Cache, '"layout.extra"', "ergopti_base"))
	AssertEqual("_", IniCacheGet(Cache, "layout", "ergopti_base"))
	Target := ManifestBuildFeaturesMap()
	Target["layout"]["ergopti_base"] := true
	AssertEqual(0, ApplyConfigToml(Target, Path))
	AssertTrue(Target["layout"]["ergopti_base"], "empty and literal dotted names must never borrow a root owner")
	AssertEqual("section", TomlConfigUnknownKind(Target, '"".layout', "ergopti_base"))
	AssertEqual("", TomlConfigManifestPath('"".layout'))
	AssertEqual("", TomlConfigManifestPath('"layout.extra"'))
	AssertEqual(0, Target["layout"].Has(""))
}
_FMS_EmptyAndLiteralNamespacesStayForeign() {
	_FMS_WithSource("empty_namespace", '["".layout]`nergopti_base = false`n[layout.""]`nergopti_base = false`n["layout.extra"]`nergopti_base = false`n',
		_FMS_EmptyNamespaceCannotBorrowRoot)
}
Test("configuration snapshot: quoted empty and literal namespaces cannot alias root settings (config-semantic-snapshot)",
	_FMS_EmptyAndLiteralNamespacesStayForeign)

_FMS_DeletedSourceKeepsAdmittedBootGeneration(Path) {
	global _ParseTomlCache
	Cache := ParseConfigTomlFile(Path)
	AssertTrue(IniCacheGet(Cache, "layout", "ergopti_base"))
	Snapshot := ConfigTomlReadSnapshot(Path)
	AssertTrue(Snapshot.Present, "presence belongs to the successful admitted read")
	FileDelete(Path)
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path), "external deletion cannot bypass the retained boot generation")
	AssertTrue(Target["layout"]["ergopti_base"])
	Assert(ParseConfigTomlFile(Path) == Cache, "publication must use admitted presence, not a later FileExist shortcut")
	_ParseTomlCache.Delete(Path)
	Fresh := ConfigTomlReadSnapshot(Path)
	AssertFalse(Fresh.Present, "retirement permits a new genuinely absent generation")
	AssertEqual(0, Fresh.Rows.Length)
	AssertEqual(0, ApplyConfigToml(ManifestBuildFeaturesMap(), Path))
}
_FMS_DeletionBetweenConsumersKeepsOneGeneration() {
	_FMS_WithSource("deleted_generation", '[layout]`nergopti_base = true`n', _FMS_DeletedSourceKeepsAdmittedBootGeneration)
}
Test("configuration snapshot: external deletion cannot split bootstrap consumer generations (config-semantic-snapshot)",
	_FMS_DeletionBetweenConsumersKeepsOneGeneration)

_FMS_ForeignInlineNamespacesRemainOwned(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("personal_editor", Map("close_on_add", false, "future", "retained"),
		"llm", Map("api_entry_id", "42")), Cache)
	_FMS_AssertExactTree(Map("personal_editor", Map("close_on_add", TOML_Bool(false), "future", "retained"),
		"llm", Map("api_entry_id", "42")), ConfigTomlReadSnapshot(Path).Document)
	AssertFalse(IniCacheGet(Cache, "personal_editor", "close_on_add"))
	AssertEqual("retained", IniCacheGet(Cache, "personal_editor", "future"))
	AssertEqual("42", IniCacheGet(Cache, "llm", "api_entry_id"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(0, ApplyConfigToml(Target, Path), "foreign and unknown children cannot enter the feature tree")
	AssertFalse(Target.Has("personal_editor"))
}
_FMS_RegisteredForeignNamespaceProjection() {
	_FMS_WithSource("foreign_inline", 'personal_editor = { close_on_add = false, future = "retained" }`nllm = { api_entry_id = "42" }`n',
		_FMS_ForeignInlineNamespacesRemainOwned)
}
Test("configuration snapshot: inline foreign bootstrap namespaces reuse their exact registry owner (config-semantic-snapshot)",
	_FMS_RegisteredForeignNamespaceProjection)

_FMS_DynamicLiteralNamesKeepChildDomains(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("personal", Map("work.notes", Map("enabled", "false", "time_activation_seconds", -1),
		"", Map("enabled", 2, "time_activation_seconds", TOML_Bool(true)),
		"literal.ok", Map("enabled", TOML_Bool(true), "time_activation_seconds", 0.125)))), ConfigTomlReadSnapshot(Path).Document)
	_FMS_AssertExactTree(Map('hotstrings.personal."work.notes"', Map("enabled", "false", "time_activation_seconds", -1),
		'hotstrings.personal.""', Map("enabled", 2, "time_activation_seconds", true),
		'hotstrings.personal."literal.ok"', Map("enabled", true, "time_activation_seconds", 0.125)), Cache)
	AssertEqual("false", IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "enabled"))
	AssertEqual(-1, IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "time_activation_seconds"))
	AssertEqual(2, IniCacheGet(Cache, 'hotstrings.personal.""', "enabled"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, , &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(4, Outdated.Count, "quoted dots and empty names retain Boolean and timing domains")
	AssertTrue(Outdated.Has('hotstrings.personal."work.notes"' . "`nenabled"))
	AssertTrue(Outdated.Has('hotstrings.personal.""' . "`ntime_activation_seconds"))
	AssertFalse(Target["hotstrings"]["personal"].Has("work.notes"))
	AssertFalse(Target["hotstrings"]["personal"].Has(""))
	AssertTrue(Target["hotstrings"]["personal"]["literal.ok"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["personal"]["literal.ok"]["time_activation_seconds"])
	AssertFalse(Target["hotstrings"]["personal"].Has("literal"), "a literal user name never creates nested category ownership")
}
_FMS_DynamicEmptyNameIsDistinct(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path))
	AssertFalse(Target["hotstrings"]["personal"][""]["enabled"])
	AssertEqual(0, Target["hotstrings"]["personal"][""]["time_activation_seconds"])
	AssertFalse(Target["layout"]["ergopti_base"], "the empty personal name remains inside its declared dynamic owner")
}
_FMS_DynamicQuotedNamesDoNotBorrowStaticPaths() {
	_FMS_WithSource("dynamic_literals", '[hotstrings.personal."work.notes"]`nenabled = "false"`ntime_activation_seconds = -1`n[hotstrings.personal.""]`nenabled = 2`ntime_activation_seconds = true`n[hotstrings.personal."literal.ok"]`nenabled = true`ntime_activation_seconds = 0.125`n',
		_FMS_DynamicLiteralNamesKeepChildDomains)
	_FMS_WithSource("dynamic_empty_valid", '[hotstrings.personal.""]`nenabled = false`ntime_activation_seconds = 0`n',
		_FMS_DynamicEmptyNameIsDistinct)
}
Test("configuration snapshot: dynamic quoted names retain typed domains and exact identities (config-semantic-snapshot)",
	_FMS_DynamicQuotedNamesDoNotBorrowStaticPaths)

_FMS_DynamicInlineMapsUseChildDomains(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("personal", Map("work.notes", Map("enabled", "false", "time_activation_seconds", -1),
		"literal.ok", Map("enabled", TOML_Bool(true), "time_activation_seconds", 0.125)))), ConfigTomlReadSnapshot(Path).Document)
	_FMS_AssertExactTree(Map('hotstrings.personal."work.notes"', Map("enabled", "false", "time_activation_seconds", -1),
		'hotstrings.personal."literal.ok"', Map("enabled", true, "time_activation_seconds", 0.125)), Cache)
	AssertEqual("false", IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "enabled"))
	AssertEqual(-1, IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "time_activation_seconds"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, , &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Outdated.Count)
	AssertFalse(Target["hotstrings"]["personal"].Has("work.notes"))
	AssertTrue(Target["hotstrings"]["personal"]["literal.ok"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["personal"]["literal.ok"]["time_activation_seconds"])
}
_FMS_InlineDynamicNamespacesMatchPhysicalPolicy() {
	_FMS_WithSource("inline_dynamic_root", 'hotstrings = { personal = { "work.notes" = { enabled = "false", time_activation_seconds = -1 }, "literal.ok" = { enabled = true, time_activation_seconds = 0.125 } } }`n',
		_FMS_DynamicInlineMapsUseChildDomains)
	_FMS_WithSource("inline_dynamic_section", '[hotstrings.personal]`n"work.notes" = { enabled = "false", time_activation_seconds = -1 }`n"literal.ok" = { enabled = true, time_activation_seconds = 0.125 }`n',
		_FMS_DynamicInlineMapsUseChildDomains)
}
Test("configuration snapshot: inline dynamic namespaces retain physical child typing (config-semantic-snapshot)",
	_FMS_InlineDynamicNamespacesMatchPhysicalPolicy)

_FMS_AbsentGenerationCannotConsumeExternalCreation(Path) {
	global _ParseTomlCache
	FileDelete(Path)
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(0, Cache.Count)
	AssertFalse(ConfigTomlReadSnapshot(Path).Present)
	FileAppend('[layout]`nergopti_base = true`n', Path, "UTF-8")
	Target := ManifestBuildFeaturesMap()
	AssertEqual(0, ApplyConfigToml(Target, Path), "external creation cannot replace admitted absence between boot consumers")
	AssertFalse(Target["layout"]["ergopti_base"])
	Assert(ParseConfigTomlFile(Path) == Cache)
	_ParseTomlCache.Delete(Path)
	Fresh := ParseConfigTomlFile(Path)
	AssertTrue(IniCacheGet(Fresh, "layout", "ergopti_base"))
	AssertTrue(ConfigTomlReadSnapshot(Path).Present)
	AssertEqual(1, ApplyConfigToml(Target, Path))
	AssertTrue(Target["layout"]["ergopti_base"])
}
_FMS_ExternalCreationCannotSplitAbsentBoot() {
	_FMS_WithSource("absent_created", "", _FMS_AbsentGenerationCannotConsumeExternalCreation)
}
Test("configuration snapshot: admitted absence survives external creation until owner retirement (config-semantic-snapshot)",
	_FMS_ExternalCreationCannotSplitAbsentBoot)

_FMS_BootPublicationUsesAdmittedPresence() {
	Body := _DriverFuncBody("ParseConfigTomlFile")
	Assert(Body != "", "the actual configuration cache owner must be readable")
	Assert(!InStr(Body, "FileExist("), "a post-read existence check cannot decide which admitted generation to publish")
	Assert(InStr(Body, "_ParseTomlCache[Path] := Snapshot.Cache") > 0,
		"both admitted presence and admitted absence must retain the actual cache identity")
	Assert(InStr(Body, "_ConfigTomlSnapshots[Path] := Snapshot") > 0,
		"both states must retain the exact source rows for the next boot consumer")
}
Test("configuration snapshot: source guard retains observed generation without post-read shortcuts (config-semantic-snapshot)",
	_FMS_BootPublicationUsesAdmittedPresence)

_FMS_InlineLiteralSpellingsKeepBooleanIntent(Path) {
	Snapshot := ConfigTomlReadSnapshot(Path)
	_FMS_AssertExactTree(Map("shortcuts", Map("screen", 0, "microsoft_bold", 0, "title_case", 1),
		"hotstrings", Map("autocorrection", Map("names", Map("enabled", 0, "time_activation_seconds", 0.125)),
		"french_autocorrection", Map("accents", Map("enabled", 1)))), Snapshot.Document)
	_FMS_AssertExactTree(Map("shortcuts", Map("screen", 0, "microsoft_bold", 0, "title_case", 1),
		"hotstrings.autocorrection", Map("names", Map("enabled", 0, "time_activation_seconds", 0.125)),
		"hotstrings.french_autocorrection", Map("accents", Map("enabled", 1))), Snapshot.Cache)
	Rows := Map()
	for Row in Snapshot.Rows
		Rows[Row.Section . "`n" . Row.Key] := Row
	AssertEqual(5, Rows.Count)
	AssertEqual("-0", Rows["shortcuts`nscreen"].Raw)
	AssertEqual("-0", Rows["shortcuts`nmicrosoft_bold"].Raw)
	AssertEqual("1", Rows["shortcuts`ntitle_case"].Raw)
	AssertEqual("-0", Rows["hotstrings.autocorrection`nnames"].ChildRaw["enabled"])
	AssertEqual("1", Rows["hotstrings.french_autocorrection`naccents"].ChildRaw["enabled"])
	Target := ManifestBuildFeaturesMap()
	AssertEqual(3, ApplyConfigToml(Target, Path, &Rejected, &Migrated, &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Migrated, "only actual bare one leaves carry legacy Boolean intent")
	AssertEqual(3, Outdated.Count, "signed-zero integers cannot invent legacy Boolean intent")
	AssertFalse(Target["shortcuts"]["screen"])
	AssertFalse(Target["shortcuts"]["microsoft_bold"])
	AssertTrue(Target["shortcuts"]["title_case"])
	AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
	AssertTrue(Target["hotstrings"]["french_autocorrection"]["accents"]["enabled"])
}
_FMS_InlineRawTokensNeverInventMigrationIntent() {
	_FMS_WithSource("inline_spelling", 'shortcuts = { screen = -0, microsoft_bold = -0, title_case = 1 }`nhotstrings = { autocorrection = { names = { enabled = -0, time_activation_seconds = 0.125 } }, french_autocorrection = { accents = { enabled = 1 } } }`n',
		_FMS_InlineLiteralSpellingsKeepBooleanIntent)
}
Test("configuration snapshot: exact inline child spellings retain legacy Boolean admission (config-semantic-snapshot)",
	_FMS_InlineRawTokensNeverInventMigrationIntent)

_FMS_RepeatedArrayOwnerCannotRewriteRows(Path) {
	ParseConfigTomlFile(Path)
	First := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(First, Path))
	First["llm"]["navigation"]["val_modifiers"].Push("ctrl")
	Second := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Second, Path))
	AssertEqual(1, Second["llm"]["navigation"]["val_modifiers"].Length)
	AssertEqual("alt", Second["llm"]["navigation"]["val_modifiers"][1])
}
_FMS_RepeatedArrayReadUsesRetainedSource() {
	_FMS_WithSource("detached_array", '[llm.navigation]`nval_modifiers = ["alt"]`n', _FMS_RepeatedArrayOwnerCannotRewriteRows)
}
Test("configuration snapshot: repeated array consumers cannot mutate retained source rows (config-semantic-snapshot)",
	_FMS_RepeatedArrayReadUsesRetainedSource)

; Actual publication is followed by a fresh native bootstrap reader process.
; The complete expected image is authored here, independently of the renderer.
_FMS_FullSaveChangedInlineSource(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Target := ManifestBuildFeaturesMap()
	; A nondefault target exercises a durable leaf; the default 0.5 is sparse.
	Expected := Chr(0xFEFF) . '_meta.schema_version = 12`nhotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.75, future = "retain"}}`n[future]`nold = "retain" # user data`n'
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		ParseConfigTomlFile(Path)
		AssertEqual(2, ApplyBootConfigToml(Target, Path), "the supported trigger scalar and valid timing record both apply")
		AssertEqual("@", Target["hotstrings"]["trigger_char"], "the independently supplied trigger leaf also reaches Features")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertTrue(_ConfigBootOutdatedEntries.Has("hotstrings.autocorrection.names`nenabled"))
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertFalse(Names["enabled"])
		AssertEqual(0.25, Names["time_activation_seconds"], "the real boot loader supplies the original valid timing")
		Names["time_activation_seconds"] := 0.75
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		Before := FSReadUtf8Exact(Path)
		Requested := 0
		AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue((Result is Integer) && Result == CONFIG_SAVE_OK, "only the strict durable status acknowledges the real feature")
		AssertEqual(1, Requested)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		Assert(Before != Expected, "the actual feature changes a valid owned timing leaf")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the complete image retains obsolete and foreign values")
		Harness := A_ScriptDir . "\support\feature_state_boot_smoke.ahk"
		Command := '"' . A_AhkPath . '" /ErrorStdOut "' . Harness . '" persisted_semantic "' . Path . '"'
		AssertEqual(0, RunWait(Command, A_ScriptDir, "Hide"), "a new native process reads the durable semantic source")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the fresh bootstrap reader cannot normalize or clean the source")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_FullSaveChangedInlineAndRestart() {
	_FMS_WithSource("fullsave_inline_changed", '_meta.schema_version = 12`nhotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.25, future = "retain"}}`n[future]`nold = "retain" # user data`n',
		_FMS_FullSaveChangedInlineSource)
}
Test("configuration snapshot: actual full save changes an inline leaf and survives fresh native bootstrap (config-full-semantic-successor)",
	_FMS_FullSaveChangedInlineAndRestart)

; A removed feature stays source data until the existing explicit cleanup owner
; removes its exact offered keys. Ordinary publication owns only current names.
_FMS_RemovedCapsPreservedUntilCleanup(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	BackupPath := ""
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		Original := FSReadUtf8Exact(Path)
		AssertTrue(Target["hotstrings"]["autocorrection"].Has("names"), "the positive control has a published feature owner")
		AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"), "the removed feature cannot be restored as a fixture shortcut")
		AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
		AssertEqual(0.5, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
		ParseConfigTomlFile(Path)
		AssertEqual(2, ApplyBootConfigToml(Target, Path), "only the two actual known names children apply")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(0, _ConfigBootOutdatedEntries.Count, "removed paths are unused, not invalid known values")
		AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"), "source parsing cannot manufacture removed runtime ownership")
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertTrue(Names["enabled"])
		AssertEqual(0.25, Names["time_activation_seconds"])
		Names["time_activation_seconds"] := 0.75
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		Requested := 0
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue((Result is Integer) && Result == CONFIG_SAVE_OK)
		AssertEqual(1, Requested)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		Expected := StrReplace(Original, "time_activation_seconds = 0.25", "time_activation_seconds = 0.75")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "an unrelated admitted save retains the entire removed source namespace")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertTrue(Document["hotstrings"]["autocorrection"]["caps"]["enabled"].Value)
		AssertEqual(0.125, Document["hotstrings"]["autocorrection"]["caps"]["time_activation_seconds"])
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		AssertEqual(2, Scan["keys"].Length, "only the two removed source children are offered")
		Identities := Map()
		for Entry in Scan["keys"] {
			AssertEqual("hotstrings.autocorrection.caps", Entry["section"])
			Identities[Entry["key"]] := true
		}
		AssertTrue(Identities.Has("enabled"))
		AssertTrue(Identities.Has("time_activation_seconds"))
		Stamp := "20990101-000312-" . ProcessExist() . "-" . A_TickCount
		CandidateBackup := ConfigUnusedKeysBackupPath(Path, Stamp)
		AssertFalse(FileExist(CandidateBackup), "the explicit cleanup fixture owns a fresh backup path")
		Removal := ConfigUnusedKeysRemove(Path, Scan["keys"], Stamp, 0, 0, Expected)
		AssertEqual("removed", Removal["status"])
		BackupPath := Removal["backup"]
		AssertEqual(CandidateBackup, BackupPath)
		AssertEqual(2, Removal["removed"])
		AssertEqual(Expected, FSReadUtf8Exact(Removal["backup"]), "cleanup backs up the exact admitted source first")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document["hotstrings"]["autocorrection"].Has("caps"))
		AssertTrue(Document["hotstrings"]["autocorrection"]["names"]["enabled"].Value)
		AssertEqual(0.75, Document["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally {
		if BackupPath != ""
			try FileDelete(BackupPath)
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_RemovedCapsDoNotAcquireKnownOwnership() {
	_FMS_WithSource("removed_caps", '_meta.schema_version = 12`n[hotstrings.autocorrection.names]`nenabled = true`ntime_activation_seconds = 0.25`n[hotstrings.autocorrection.caps]`nenabled = true`ntime_activation_seconds = 0.125`n',
		_FMS_RemovedCapsPreservedUntilCleanup)
}
Test("configuration snapshot: removed caps stays runtime unread and is preserved until explicit cleanup (config-current-feature-owner)",
	_FMS_RemovedCapsDoNotAcquireKnownOwnership)

; Retired family source remains readable without becoming a current feature.
_FMS_RetiredCorrectionFamily(Path) {
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	Assert(ManifestFindEntryByPath("hotstrings.autocorrection.names") is Map,
		"the replacement fixture must exercise a current canonical feature")
	AssertFalse(ManifestFindEntryByPath("hotstrings.autocorrection.caps"))
	AssertEqual(true, IniCacheGet(ParseConfigTomlFile(Path), "hotstrings.autocorrection.caps", "enabled"))
	AssertEqual(0, ApplyConfigToml(Target, Path), "a retired family cannot apply as a current feature")
	AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"))
	AssertEqual(Original, FSRead(Path), "loading must preserve the retired user source bytes")
}
_FMS_RetiredCorrectionFamilyRemainsSourceOnly() {
	_FMS_WithSource("retired_correction", "[hotstrings.autocorrection.caps]`nenabled = true`n",
		_FMS_RetiredCorrectionFamily)
}
Test("configuration snapshot: retired correction family stays source-only (config-semantic-snapshot)",
	_FMS_RetiredCorrectionFamilyRemainsSourceOnly)

; A genuine loader owns exact user names; full-state traversal must not flatten them.
_FMS_ConfigExactNameFixtures() {
	return [
		{ name: "literal.ok", header: '[hotstrings.personal."literal.ok"]' },
		{ name: "", header: '[hotstrings.personal.""]' },
		{ name: Chr(0x1F680), header: '[hotstrings.personal."' . Chr(0x1F680) . '"]' },
		{ name: "Twin", header: '[hotstrings.personal."Twin"]' },
		{ name: "twin", header: '[hotstrings.personal."twin"]' }]
}

_FMS_ConfigExactNameSource(Fixture) {
	return "# private exact-name source`n" . Fixture.header . "`n"
		. "enabled = true # current choice`ntime_activation_seconds = 0.125`n"
		. '# keep source trivia`n[future]`n"literal.dot" = { rows = [[1, "x"]], count = 9223372036854775807 }`n'
}

_FMS_ConfigExactWholeCollector(Path, Fixture) {
	global _LLM_Menu
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path), "the real reader admits both dynamic typed fields")
	AssertTrue(Target["hotstrings"]["personal"].Has(Fixture.name))
	Menu := _HSDeepCloneMap(_LLM_Menu)
	Menu["onboarding_seen"] := false
	Menu["app_profile_overrides"] := Map()
	Menu["user_profiles"] := []
	State := MasterGateState(), PriorState := State.Clone()
	try {
		State["initialized"] := false
		Updates := _ConfigCollectFullSaveUpdates(Target, Menu)
		Found := 0
		for Update in Updates {
			Parts := TOML_ParseKeyPath(Update.Section, true)
			if !_FMS_ConfigExactPersonalRow(Parts, Fixture.name)
				continue
			AssertEqual(Fixture.name, Parts[3], "the real full-state collector retains the exact admitted name")
			AssertTrue(Update.Key == "enabled" || Update.Key == "time_activation_seconds")
			AssertFalse(Update.HasOwnProp("Delete"), "both explicit choices differ from their published defaults")
			AssertEqual(Update.Key == "enabled" ? true : 0.125, Update.Value)
			Found += 1
		}
		AssertEqual(2, Found, "the genuine whole collector must include both exact dynamic rows")
	} finally {
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
	}
}
_FMS_ConfigWholeCollectorsKeepExactNames() {
	for Index, Fixture in _FMS_ConfigExactNameFixtures()
		_FMS_WithSource("fullcollector_name_" . Index, _FMS_ConfigExactNameSource(Fixture),
			_FMS_ConfigExactWholeCollector.Bind(, Fixture))
}
Test("configuration snapshot: actual whole full-state collector retains exact semantic names (config-full-state-exact-path)",
	_FMS_ConfigWholeCollectorsKeepExactNames)

; The same recursive collector and sparse adapter feed the real durable full-save owner.
_FMS_ConfigExactCollectedSubtree(Target) {
	Updates := []
	_CollectFeatureUpdates(Updates, "hotstrings.personal", Target["hotstrings"]["personal"])
	return _ConfigSparseUpdates(Updates)
}

_FMS_ConfigExactNameFullSave(Path, Fixture) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := '_meta.schema_version = 12`n' . _FMS_ConfigExactNameSource(Fixture)
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertEqual(2, ApplyBootConfigToml(Target, Path))
		AssertEqual(Original, FSRead(Path))
		Collector := _FMS_ConfigExactCollectedSubtree.Bind(Target)
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collector))
		AssertEqual(Original, FSRead(Path), "a collected semantic no-op retains the complete handwritten source")
		Target["hotstrings"]["personal"][Fixture.name]["enabled"] := false
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collector))
		ExpectedSource := "_meta.schema_version = 12`n# private exact-name source`n" . Fixture.header . "`n"
			. "time_activation_seconds = 0.125`n"
			. '# keep source trivia`n[future]`n"literal.dot" = { rows = [[1, "x"]], count = 9223372036854775807 }`n'
		AssertEqual(ExpectedSource, FSRead(Path), "only the explicitly cleared leaf is removed")
		Personal := Map()
		Personal.CaseSense := "On"
		Personal[Fixture.name] := Map("time_activation_seconds", 0.125)
		_FMS_AssertExactTree(Map("hotstrings", Map("personal", Personal),
			"future", Map("literal.dot", Map("rows", [[1, "x"]], "count", 9223372036854775807)),
			"_meta", Map("schema_version", 12)),
			TOML_ParseDocument(FSRead(Path)))
		Reloaded := ManifestBuildFeaturesMap()
		AssertEqual(1, ApplyConfigToml(Reloaded, Path), "the genuine reload reader keeps the exact remaining owner")
		AssertTrue(Reloaded["hotstrings"]["personal"].Has(Fixture.name))
		AssertEqual(0.125, Reloaded["hotstrings"]["personal"][Fixture.name]["time_activation_seconds"])
		AssertEqual(_ConfigFullSaveCoordinator().requested_generation,
			_ConfigFullSaveCoordinator().committed_generation)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_ConfigFullSaveKeepsExactNames() {
	for Index, Fixture in _FMS_ConfigExactNameFixtures()
		_FMS_WithSource("fullsave_name_" . Index, '_meta.schema_version = 12`n' . _FMS_ConfigExactNameSource(Fixture),
			_FMS_ConfigExactNameFullSave.Bind(, Fixture))
}
Test("configuration snapshot: real full-save publication and reload preserve exact semantic names (config-full-state-exact-path)",
	_FMS_ConfigFullSaveKeepsExactNames)

_FMS_ConfigExactCaseTwins() {
	Personal := Map()
	Personal.CaseSense := "On"
	Personal["Twin"] := Map("enabled", true)
	Personal["twin"] := Map("enabled", true)
	Rows := _FMS_ConfigExactCollectedSubtree(Map("hotstrings", Map("personal", Personal)))
	AssertEqual(2, Rows.Length)
	Seen := Map()
	Seen.CaseSense := "On"
	for Row in Rows {
		Parts := TOML_ParseKeyPath(Row.Section, true)
		AssertEqual(3, Parts.Length)
		Seen[Parts[3]] := Row.Value
	}
	AssertEqual(2, Seen.Count, "a supplied exact native Map must not collapse case twins during collection")
	AssertTrue(Seen.Has("Twin"))
	AssertTrue(Seen.Has("twin"))
	Exact := ManifestConfigSparseOperation('hotstrings.personal."literal.ok"', "enabled", true)
	AssertEqual('hotstrings.personal."literal.ok"', Exact.Section)
	AssertEqual("enabled", Exact.Key)
	AssertEqual(true, Exact.Value)
	AssertFalse(Exact.HasOwnProp("Delete"))
	AssertTrue(ManifestDynamicEntry("hotstrings.personal.user.enabled") is Map)
	AssertFalse(ManifestDynamicEntry('hotstrings.personal."literal.ok".enabled'),
		"the generic path API retains its original lexical segment contract")
	AssertThrows(ManifestConfigSparseOperation.Bind('hotstrings.personal."literal.ok"', "typo", true),
		"an exact user name cannot invent a dynamic field")
	AssertThrows(ManifestConfigSparseOperation.Bind('hotstrings.personall."literal.ok"', "enabled", true),
		"an adjacent prefix cannot acquire dynamic ownership")
}
Test("configuration snapshot: config-row adapter preserves twins and unchanged generic domains (config-full-state-exact-path)",
	_FMS_ConfigExactCaseTwins)


; Full-save traverses initialized personal defaults too. Select the exact fixture
; identity without relying on Map iteration order or flattening semantic segments.
_FMS_ConfigExactPersonalRow(Parts, Name) {
	return Parts is Array && Parts.Length == 3
		&& StrCompare(Parts[1], "hotstrings", true) == 0
		&& StrCompare(Parts[2], "personal", true) == 0
		&& StrCompare(Parts[3], Name, true) == 0
}
_FMS_ConfigExactPersonalRowSelection() {
	for Fixture in _FMS_ConfigExactNameFixtures() {
		Parts := TOML_ParseKeyPath(SubStr(Fixture.header, 2, StrLen(Fixture.header) - 2), true)
		AssertTrue(_FMS_ConfigExactPersonalRow(Parts, Fixture.name),
			"the handwritten physical header resolves to the exact fixture identity")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", "autocorrection"], Fixture.name),
			"an initialized default sibling is not the fixture under test")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", Fixture.name, "child"], Fixture.name),
			"a descendant must not be mistaken for its literal parent name")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "Personal", Fixture.name], Fixture.name),
			"a case-distinct category cannot acquire the fixture identity")
	}
	AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", "Twin"], "twin"),
		"two actual admitted case twins remain distinct")
	AssertFalse(_FMS_ConfigExactPersonalRow(TOML_ParseKeyPath("hotstrings.personal.literal.ok", true), "literal.ok"),
		"nested syntax is not the admitted literal-dot name")
	Defaults := ManifestBuildFeaturesMap()
	AssertTrue(Defaults["hotstrings"]["personal"].Has("autocorrection"),
		"the real collector input contains the default sibling that exposed the old premise")
}
Test("configuration snapshot: exact fixture row selection rejects initialized siblings and semantic-name decoys",
	_FMS_ConfigExactPersonalRowSelection)
