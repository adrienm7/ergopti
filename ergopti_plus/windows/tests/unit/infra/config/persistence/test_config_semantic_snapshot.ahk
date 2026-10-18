; tests/unit/infra/config/persistence/test_config_semantic_snapshot.ahk

; ==============================================================================
; MODULE: Semantic Configuration Snapshot
; DESCRIPTION:
; Each native case owns real source bytes: root and dotted settings reach
; the cache and the features, namespaces and generations stay distinct, read
; refusals stay session debt and a full save keeps outdated and unknown
; records.
; ==============================================================================

#Requires AutoHotkey v2.0





_FMS_WithSource(Tag, Source, Body) {
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots
	global _ConfigBootReadFailed, _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Path := _FM_WriteFixture("semantic_" . Tag . "_" . ProcessExist(), Source)
	OldRead := _ConfigBootReadFailed, OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	PriorRefusal := TOML_WriteRefusal(Path)
	try return Body.Call(Path)
	finally {
		_ConfigBootReadFailed := OldRead
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		if PriorRefusal == "" && _TOML_WriteRefusals().Has(_TOML_WriteRefusalKey(Path))
			_TOML_WriteRefusals().Delete(_TOML_WriteRefusalKey(Path))
		for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
			if Store.Has(Path)
				Store.Delete(Path)
		}
		try FileDelete(Path)
	}
}

_FMS_RootAndSectionRows(Path) {
	Cache := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
	AssertEqual(true, IniCacheGet(Cache, "category_enabled", "hotstrings"))
	AssertEqual("none", IniCacheGet(Cache, "shortcuts.keyboard", "win_space"))
	Target := ManifestBuildFeaturesMap()
	Target["hotstrings"]["autocorrection"]["names"]["enabled"] := false
	Assert(ApplyConfigToml(Target, Path) >= 1, "at least the actual known dotted feature must apply")
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(false, TOML_UnreadableFile(Path))
}
_FMS_RootSettingsAndDottedFeatureApply() {
	Source := 'hotstrings.trigger_char = "@"`ncategory_enabled.hotstrings = true`nshortcuts.keyboard.win_space = "none"`nhotstrings.autocorrection.names.enabled = true`n'
	_FMS_WithSource("root", Source, _FMS_RootAndSectionRows)
	Source := '[hotstrings]`ntrigger_char = "@"`nautocorrection.names.enabled = true`n[category_enabled]`nhotstrings = true`n[shortcuts]`nkeyboard.win_space = "none"`n'
	_FMS_WithSource("section", Source, _FMS_RootAndSectionRows)
}
Test("configuration snapshot: root and dotted settings reach cache and features (config-semantic-snapshot)",
	_FMS_RootSettingsAndDottedFeatureApply)

_FMS_LiteralAndNested(Path) {
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(false, IniCacheGet(Cache, "hotstrings", "autocorrection.names.enabled"))
	AssertEqual(true, IniCacheGet(Cache, "hotstrings.autocorrection.names", "enabled"))
	AssertEqual("literal", IniCacheGet(Cache, '"hotstrings.autocorrection.names"', "note"))
	AssertEqual("_", IniCacheGet(Cache, "hotstrings.autocorrection.names", "note"))
	Target := ManifestBuildFeaturesMap()
	Target["hotstrings"]["autocorrection"]["names"]["enabled"] := false
	ApplyConfigToml(Target, Path)
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"],
		"the quoted literal false leaf must never alias the actual nested true preference")
	AssertEqual(false, IniCacheGet(Cache, "hotstrings", "autocorrection.names.enabled"))
}
_FMS_LiteralDotsStayDistinct() {
	Source := '[hotstrings]`n"autocorrection.names.enabled" = false`nautocorrection.names.enabled = true`n["hotstrings.autocorrection.names"]`nnote = "literal"`n'
	_FMS_WithSource("literal", Source, _FMS_LiteralAndNested)
}
Test("configuration snapshot: literal dots never alias nested settings (config-semantic-snapshot)",
	_FMS_LiteralDotsStayDistinct)

_FMS_TypedModelsAndIsolation() {
	Snapshot := ConfigTomlDecodeSnapshot('[future]`ntruth = true`nzero = 0`ntext = "0"`nitems = [false, 1, "true"]`nvalue = { nested = { enabled = true } }`n')
	Cache := Snapshot.Cache["future"]
	AssertEqual("Integer", Type(Cache["truth"]))
	AssertTrue(Cache["truth"])
	AssertEqual("Integer", Type(Cache["zero"]))
	AssertEqual(0, Cache["zero"])
	AssertEqual("String", Type(Cache["text"]))
	AssertEqual("0", Cache["text"])
	AssertEqual(3, Cache["items"].Length)
	AssertEqual(false, Cache["items"][1])
	AssertEqual(1, Cache["items"][2])
	AssertEqual("true", Cache["items"][3])
	Cache["value"]["nested"]["enabled"] := false
	AssertTrue(Snapshot.Rows[5].Value["nested"]["enabled"], "feature values do not alias the cache")
	Assert(Snapshot.Document["future"]["value"]["nested"]["enabled"] is TOML_Bool,
		"the original typed source proof retains Boolean intent")
	AssertTrue(Snapshot.Document["future"]["value"]["nested"]["enabled"].Value)
	Assert(Snapshot.Rows[5].Typed["nested"]["enabled"] is TOML_Bool)
	Snapshot.Document["future"]["value"]["nested"]["enabled"].Value := false
	AssertTrue(Snapshot.Rows[5].Typed["nested"]["enabled"].Value, "typed row evidence is detached from the document")
	AssertEqual("true", Snapshot.Rows[5].ChildRaw["nested"]["enabled"], "the exact child raw token remains retained")
}
Test("configuration snapshot: nested native values are typed and detached (config-semantic-snapshot)",
	_FMS_TypedModelsAndIsolation)

_FMS_LegacyBooleans(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, &Migrated, &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Migrated, "bare zero/one preserve the installed legacy Boolean contract")
	AssertEqual(2, Outdated.Count, "quoted and out-of-range values remain obsolete")
	AssertTrue(Target["shortcuts"]["screen"])
	AssertFalse(Target["layout"]["ergopti_base"])
}
_FMS_LegacyBooleanCompatibility() {
	_FMS_WithSource("legacy", 'shortcuts.screen = 1`nlayout.ergopti_base = 0`nshortcuts.microsoft_bold = "true"`nshortcuts.title_case = 2`n',
		_FMS_LegacyBooleans)
}
Test("configuration snapshot: legacy Boolean intent and outdated values stay governed (config-semantic-snapshot)",
	_FMS_LegacyBooleanCompatibility)

_FMS_RefusesWholeNamespace(Path) {
	global _ConfigBootReadFailed, _ConfigBootRejectedOverrides
	Target := ManifestBuildFeaturesMap()
	Target["layout"]["ergopti_base"] := true
	_ConfigBootReadFailed := false
	_ConfigBootRejectedOverrides := 0
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(0, Cache.Count, "no incomplete cache may be published")
	AssertTrue(_ConfigBootReadFailed, "semantic boot refusal must remain session-blocking")
	AssertEqual(-1, ApplyBootConfigToml(Target, Path))
	AssertTrue(_ConfigBootRejectedOverrides > 0)
	AssertTrue(Target["layout"]["ergopti_base"], "the early valid leaf must not publish before duplicate admission")
	AssertFalse(ConfigFullStateCanPersist())
	Original := FSRead(Path)
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]))
	AssertEqual(Original, FSRead(Path))
	Repaired := '[layout]`nergopti_base = false`n'
	AssertTrue(FSWriteDurable(Path, Repaired))
	AssertFalse(IniCacheGet(ParseConfigTomlFile(Path), "layout", "ergopti_base"))
	AssertTrue(_ConfigBootReadFailed, "manual repair does not complete the prior boot generation")
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }]))
	AssertEqual(Repaired, FSRead(Path), "only a restart can reconsider the semantic boot write refusal")
}
_FMS_DuplicatesPublishNothing() {
	_FMS_WithSource("duplicate", 'layout.ergopti_base = false`n[layout]`nergopti_base = true`n',
		_FMS_RefusesWholeNamespace)
}
Test("configuration snapshot: duplicate namespaces refuse before cache or feature publication (config-semantic-snapshot)",
	_FMS_DuplicatesPublishNothing)

_FMS_TableArrayGenerationIsolation() {
	Snapshot := ConfigTomlDecodeSnapshot('[[future]]`nname = "one"`nvalue.enabled = true`n[[future]]`nname = "two"`nvalue.enabled = false`n[layout]`nergopti_base = false`n')
	AssertEqual(4, Snapshot.SkippedRecords)
	AssertFalse(Snapshot.Cache.Has("future"))
	AssertFalse(Snapshot.Cache.Has("future.value"))
	AssertEqual(1, Snapshot.Rows.Length)
	AssertEqual("one", Snapshot.Document["future"][1]["name"])
	AssertEqual("two", Snapshot.Document["future"][2]["name"])
	AssertTrue(Snapshot.Document["future"][1]["value"]["enabled"].Value)
	AssertFalse(Snapshot.Document["future"][2]["value"]["enabled"].Value)
}
Test("configuration snapshot: table-array generations cannot become last-wins settings (config-semantic-snapshot)",
	_FMS_TableArrayGenerationIsolation)

_FMS_SnapshotOwnsOneGeneration(Path) {
	global _ParseTomlCache
	Cache := ParseConfigTomlFile(Path)
	Source := FSReadUtf8Exact(Path)
	AssertTrue(Cache["layout"]["ergopti_base"])
	External := '[layout]`nergopti_base = false`n'
	FileDelete(Path)
	FileAppend(External, Path, "UTF-8")
	Target := ManifestBuildFeaturesMap()
	ApplyConfigToml(Target, Path)
	AssertTrue(Target["layout"]["ergopti_base"], "feature application consumes the same admitted boot generation")
	_ParseTomlCache.Delete(Path)
	NewCache := ParseConfigTomlFile(Path)
	AssertFalse(NewCache["layout"]["ergopti_base"])
	AssertTrue(Cache["layout"]["ergopti_base"], "retirement must not mutate a prior cache object")
	Assert(NewCache != Cache, "new source generation owns a new cache")
	ApplyConfigToml(Target, Path)
	AssertFalse(Target["layout"]["ergopti_base"])
	AssertFalse(_TOML_BatchWriteImpl(Path,
		[{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }],
		[], "write", Source, 1),
		"an old source image cannot acknowledge publication over the new generation")
	AssertEqual(External, FSRead(Path))
}
_FMS_OneAdmittedSourceGeneration() {
	_FMS_WithSource("generation", '[layout]`nergopti_base = true`n', _FMS_SnapshotOwnsOneGeneration)
}
Test("configuration snapshot: boot readers share one generation and invalidation retires identity (config-semantic-snapshot)",
	_FMS_OneAdmittedSourceGeneration)

_FMS_UnknownScalarsAndWriterPolicy(Path) {
	Original := FSRead(Path)
	Cache := ParseConfigTomlFile(Path)
	AssertEqual("retain", Cache["future"]["old"])
	ApplyConfigToml(ManifestBuildFeaturesMap(), Path)
	AssertTrue(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "@" }]))
	AssertEqual(Original, FSRead(Path), "loading/no-op publication does not clean unowned scalar records")
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }]))
	AssertEqual(Original, FSRead(Path), "semantic loading does not relax changed dotted-source writer refusal")
}
_FMS_UnknownScalarsStayUntilCleanup() {
	_FMS_WithSource("unknown", 'hotstrings.trigger_char = "@"`n[future]`nold = "retain" # user data`n',
		_FMS_UnknownScalarsAndWriterPolicy)
}
Test("configuration snapshot: unknown scalars survive and writer admission stays strict (config-semantic-snapshot)",
	_FMS_UnknownScalarsStayUntilCleanup)

_FMS_RepeatedFeatureValuesAreDetached(Path) {
	ParseConfigTomlFile(Path)
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path))
	Target["shortcuts"]["take_note"]["enabled"] := false
	Target["shortcuts"]["take_note"]["destination_folder"] := "changed by the first consumer"
	Second := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Second, Path))
	AssertTrue(Second["shortcuts"]["take_note"]["enabled"])
	AssertEqual("owned", Second["shortcuts"]["take_note"]["destination_folder"],
		"a feature consumer cannot rewrite the retained admitted source row")
}
_FMS_RepeatedFeatureReadUsesOriginalSource() {
	_FMS_WithSource("detached", '[shortcuts]`ntake_note = { enabled = true, dated_notes = false, destination_folder = "owned" }`n',
		_FMS_RepeatedFeatureValuesAreDetached)
}
Test("configuration snapshot: repeated feature reads detach their retained source values (config-semantic-snapshot)",
	_FMS_RepeatedFeatureReadUsesOriginalSource)

_FMS_NativeReadRefusalAndRecovery(Path) {
	global _ConfigBootReadFailed
	_ConfigBootReadFailed := false
	Before := FSReadUtf8Exact(Path)
	AssertTrue(Before is String, "the independent original source is physically readable before locking")
	Admission := ConfigMigrateBoot(Path, "capture_read")
	AssertTrue(HasMethod(Admission, "Call"), "the actual readonly source constructor admits the original native read")
	CanonicalSource := SubStr(Before, 1, 1) == Chr(0xFEFF) ? SubStr(Before, 2) : Before
	AssertTrue(Admission.Call(CanonicalSource, 1), "the genuine source receipt matches the exact original legacy bytes")
	AssertFalse(ConfigSchemaCanPrepareWrite(Path), "readonly corpus custody creates no write READY")
	Lock := FileOpen(Path, "r-rwd")
	Assert(IsObject(Lock), "the native read-refusal fixture must acquire its actual exclusive lock")
	try Cache := ParseConfigTomlFile(Path)
	finally Lock.Close()
	AssertEqual(0, Cache.Count)
	AssertTrue(TOML_UnreadableFile(Path))
	AssertTrue(_ConfigBootReadFailed)
	Recovered := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Recovered, "hotstrings", "trigger_char"))
	AssertFalse(TOML_UnreadableFile(Path), "a successful native read clears only the per-path read diagnostic")
	AssertTrue(_ConfigBootReadFailed, "a later successful read cannot rewrite the incomplete boot generation")
	AssertFalse(ConfigFullStateCanPersist())
}
_FMS_ReadFailureRemainsSessionDebt() {
	_FMS_WithSource("locked", 'hotstrings.trigger_char = "@"`n', _FMS_NativeReadRefusalAndRecovery)
}
Test("configuration snapshot: real native read refusal retains boot write protection after recovery (config-semantic-snapshot)",
	_FMS_ReadFailureRemainsSessionDebt)

_FMS_CaseAndEscapedNames() {
	Snapshot := ConfigTomlDecodeSnapshot('[hotstrings]`n"trigger\u005fchar" = "@"`n[Hotstrings]`ntrigger_char = "!"`n')
	AssertEqual("@", IniCacheGet(Snapshot.Cache, "hotstrings", "trigger_char"))
	AssertEqual("!", IniCacheGet(Snapshot.Cache, "Hotstrings", "trigger_char"))
	AssertThrows(_FMS_EscapedAlias,
		"semantic quoted/bare aliases must refuse before either projection is returned")
}
_FMS_EscapedAlias() {
	return ConfigTomlDecodeSnapshot('[hotstrings]`ntrigger_char = "@"`n"trigger\u005fchar" = "!"`n')
}
Test("configuration snapshot: escaped aliases refuse and case-distinct namespaces stay distinct (config-semantic-snapshot)",
	_FMS_CaseAndEscapedNames)

_FMS_GenericParserRemainsFlat(Path) {
	Cache := ParseTomlFile(Path)
	AssertFalse(Cache.Has("root"), "generic data-file parsing retains its historical root contract")
	AssertEqual(7, IniCacheGet(Cache, "settings", "nested.value"))
	AssertEqual("_", IniCacheGet(Cache, "settings.nested", "value"))
	Semantic := ConfigTomlDecodeSnapshot(FSRead(Path))
	AssertEqual(1, IniCacheGet(Semantic.Cache, "root", "value"))
	AssertEqual(7, IniCacheGet(Semantic.Cache, "settings.nested", "value"))
}
_FMS_GenericDataParserCompatibility() {
	_FMS_WithSource("generic", 'root.value = 1`n[settings]`nnested.value = 7`n', _FMS_GenericParserRemainsFlat)
}
Test("configuration snapshot: generic data-file parsing keeps its legacy contract (config-semantic-snapshot)",
	_FMS_GenericDataParserCompatibility)

; These complete native-cache goldens are handwritten from the independent
; semantic corpus, never emitted by the new projection implementation.
_FMS_IndependentDottedCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\toml\dotted_keys.json", "UTF-8"))
	AssertEqual(23, Corpus["documents"].Length, "every independent semantic vector remains registered")
	Caches := Map(
		"root bare dotted assignment", Map("a", Map("b", 1)),
		"siblings share one semantic owner", Map("a", Map("b", 1, "c", false)),
		"root literal and nested dots coexist", Map("", Map("a.b", 1), "a", Map("b", 2)),
		"section relative dotted assignment", Map("settings.ai", Map("enabled", true, "model", "001")),
		"array of table owner generations", Map(),
		"multiline dotted array", Map("a", Map("b", [1, 2])),
		"multiline dotted string", Map("a", Map("b", "first`nsecond")),
		"quoted Unicode assignment", Map('"é"', Map("ключ", true)),
		"root quoted escaped path", Map('a."b.c"', Map("d", 2)),
		"inline dotted values inside array", Map("", Map("items", [Map("a", Map("b", 1, "c", false))])),
		"dotted namespace child header", Map("a", Map("b", 1), "a.c", Map("v", 2)),
		"implicit header parent admits new dotted child", Map("a.b.c", Map("x", 1), "a.b", Map("d", 2)))
	Valid := 0
	for Row in Corpus["documents"] {
		if !Row["valid"] {
			AssertThrows(ConfigTomlDecodeSnapshot.Bind(Row["source"]), Row["name"])
			continue
		}
		Valid += 1
		AssertTrue(Caches.Has(Row["name"]), "each valid source owns an independent native-cache golden")
		Snapshot := ConfigTomlDecodeSnapshot(Row["source"])
		_TIT_DottedAssert(Row["expected"], Snapshot.Document)
		_TIT_DottedAssert(Caches[Row["name"]], Snapshot.Cache)
	}
	AssertEqual(12, Valid)
}
Test("configuration snapshot: independent dotted corpus pins complete native projection (config-semantic-snapshot)",
	_FMS_IndependentDottedCorpus)

_FMS_MissingSourceIsNotFailure(Path) {
	global _ConfigBootReadFailed
	FileDelete(Path)
	_ConfigBootReadFailed := false
	AssertEqual(0, ParseConfigTomlFile(Path).Count)
	AssertFalse(_ConfigBootReadFailed, "first use has a genuinely absent source, not incomplete boot data")
	AssertFalse(TOML_UnreadableFile(Path))
	AssertEqual("", TOML_WriteRefusal(Path))
	AssertTrue(TOML_BatchWrite(Path, [{ Section: "script", Key: "locale", Value: "en" }]))
	AssertEqual("en", IniCacheGet(ParseConfigTomlFile(Path), "script", "locale"))
}
_FMS_MissingSourceAllowsFirstUse() {
	_FMS_WithSource("missing", "", _FMS_MissingSourceIsNotFailure)
}
Test("configuration snapshot: an absent source still permits first-use settings (config-semantic-snapshot)",
	_FMS_MissingSourceAllowsFirstUse)

_FMS_FullSavePreservesOutdatedAndUnknown(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _LOGGER_TEST_SINK
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	PriorSink := _LOGGER_TEST_SINK
	Observed := { collector_entered: 0, collector_completed: 0, phase: "unobserved" }
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		Cache := ParseConfigTomlFile(Path)
		ApplyBootConfigToml(Target, Path)
		AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
		AssertTrue(_ConfigBootOutdatedEntries.Has("shortcuts`nscreen"))
		AssertEqual(0, _ConfigBootRejectedOverrides)
		Collect() {
			Observed.collector_entered := 1
			Updates := [
				{ Section: "hotstrings", Key: "trigger_char", Value: IniCacheGet(Cache, "hotstrings", "trigger_char") },
				{ Section: "shortcuts", Key: "screen", Value: Target["shortcuts"]["screen"] }]
			Observed.collector_completed := 1
			return Updates
		}
		ObservePhase(Line) {
			; Classify fixed existing messages only; never emit paths, source,
			; credentials or the original formatted logger line.
			if !(Line is String)
				return
			for Phase in ["source", "collector", "writer"]
				if InStr(Line, "The full configuration " . Phase . " raised an error:")
					Observed.phase := Phase
			if InStr(Line, "Refusing semantic configuration write for")
				Observed.phase := "candidate"
			if InStr(Line, "Write-through atomic replace of")
				Observed.phase := "native_replace"
			if InStr(Line, "Refusing configuration writer: genuine source schema admission was not captured.")
				Observed.phase := "schema_capture"
			if InStr(Line, "Refusing unchanged-source acknowledgment: genuine native admission was withdrawn.")
				Observed.phase := "native_ack_noop"
			if InStr(Line, "Refusing unchanged-image acknowledgment: genuine native admission was withdrawn.")
				Observed.phase := "native_ack_image"
		}
		LoggerSetTestSink(ObservePhase)
		SaveResult := SaveFullConfig(0, (*) => true, true, 0, Collect)
		LoggerSetTestSink(PriorSink)
		if SaveResult != CONFIG_SAVE_OK
			_FMS_TraceClosedFullSaveRefusal(Path, SaveResult, Observed, Original)
		AssertEqual(CONFIG_SAVE_OK, SaveResult,
			"the actual full-save owner and writer must acknowledge the semantic no-op")
		AssertEqual(Original, FSRead(Path), "full save must preserve obsolete scalar and unowned source bytes")
		AssertEqual(_ConfigFullSaveCoordinator().requested_generation,
			_ConfigFullSaveCoordinator().committed_generation,
			"successful publication, not a deferred timer, owns this generation")
	} finally {
		LoggerSetTestSink(PriorSink)
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_FullSaveUsesSemanticReadWithoutCleanup() {
	_FMS_WithSource("fullsave", '_meta.schema_version = 12`nhotstrings.trigger_char = "@"`n[shortcuts]`nscreen = 2 # outdated, retained`n[future]`nold = "retain" # user data`n',
		_FMS_FullSavePreservesOutdatedAndUnknown)
}
Test("configuration snapshot: actual full save retains outdated and unknown scalar records (config-semantic-snapshot)",
	_FMS_FullSaveUsesSemanticReadWithoutCleanup)
