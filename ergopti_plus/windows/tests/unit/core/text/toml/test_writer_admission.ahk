; tests/unit/core/text/toml/test_writer_admission.ahk

; ==============================================================================
; MODULE: TOML Config Writer Admission
; DESCRIPTION:
; A flat writer cannot own every valid document: the config document
; writer admits only sources whose namespaces, inline spans and comments it
; can keep, and its semantic reader reuses the canonical spans.
; ==============================================================================

#Requires AutoHotkey v2.0





; Handwritten physical sources prove that a flat writer cannot own every valid
; document. Their expected no-op images are the sources, not generated models.
_TBUI_NamespaceLossVectors() {
	return [
		{ Id: "dotted", Source: '# retain exact spelling`n[settings]`nnested.value = 1 # owned identity`n',
			Key: "nested.value", Value: 1 },
		{ Id: "root", Source: 'future.version = "001" # unknown root`n[settings]`nowned = 1`n',
			Key: "owned", Value: 1 },
		{ Id: "table-arrays", Source: '[[future]]`nname="first"`n[[future]]`nname="second"`n[settings]`nowned=1`n',
			Key: "owned", Value: 1, Preservable: true }
	]
}

_TBUI_LossSensitiveBuildPreservesSource() {
	for Vector in _TBUI_NamespaceLossVectors() {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			Candidate := TOML_BuildUpdatedContent(Path,
				[{ Section: "settings", Key: Vector.Key, Value: Vector.Value }])
			AssertEqual("ok", Candidate["status"], Vector.Id)
			Assert(StrCompare(Source, Candidate["content"], true) == 0,
				"a real no-op retains the complete loss-sensitive byte image: " . Vector.Id)
			AssertEqual(Source, Candidate["source_content"])
			AssertTrue(Cached == ParseTomlFile(Path), "detached admission never replaces the live cache")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: loss-sensitive detached no-ops retain original identities and bytes (toml-writer-document)",
	_TBUI_LossSensitiveBuildPreservesSource)

_TBUI_ChangedLossSensitiveBuildRefuses() {
	for Vector in _TBUI_NamespaceLossVectors() {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			for Update in [{ Section: "settings", Key: Vector.Key, Value: 2 },
				{ Section: "settings", Key: Vector.Key, Delete: 1 },
				{ Section: "settings", Key: "unrelated", Value: TOML_Bool(false) }] {
				Candidate := TOML_BuildUpdatedContent(Path, [Update])
				if Vector.HasOwnProp("Preservable") {
					AssertEqual("ok", Candidate["status"], "foreign arrays survive an independently owned sibling change")
					_TAOT_AssertFuture(Candidate["content"])
					_TAOT_AssertRequested(Candidate["content"], Update)
				} else {
					AssertEqual("error", Candidate["status"], "no unowned namespace may disappear: " . Vector.Id)
					AssertFalse(Candidate.Has("source_content"), "no refused candidate gains publication authority")
				}
				AssertTrue(FSUtf8ExactMatches(Path, Source))
				AssertTrue(Cached == ParseTomlFile(Path), "refusal leaves the live cache object intact")
			}
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: changed dotted leaves and unowned root/table-array loss refuse before candidate authority (toml-writer-document)",
	_TBUI_ChangedLossSensitiveBuildRefuses)

_TBUI_QuotedDotRemainsRepresentable() {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . '[settings]`n"nested.value" = 1 # canonical writer owns this leaf`n'
	Expected := Chr(0xFEFF) . '[settings]`n"nested.value" = 2`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Candidate := TOML_BuildUpdatedContent(Path,
			[{ Section: "settings", Key: "nested.value", Value: 2 }])
		AssertEqual("ok", Candidate["status"])
		Assert(StrCompare(Expected, Candidate["content"], true) == 0,
			"an independently quoted literal dot keeps the existing canonical contract")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "settings", Key: "nested.value", Value: 2 }]))
		AssertTrue(FSUtf8ExactMatches(Path, Expected))
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(2, Document["settings"]["nested.value"])
		AssertFalse(Document["settings"].Has("nested"))
	} finally FSDelete(Path)
}
Test("toml writer admission: literal quoted dots remain writable and canonical (toml-writer-document)",
	_TBUI_QuotedDotRemainsRepresentable)

; The actual value getter is a native controlled concurrent writer. Assertions
; stay outside rendering/catching callbacks; its observations cannot be swallowed.
class _TBUI_SourceMutatingBoolean extends TOML_Bool {
	__New(Path, Content) {
		this.Path := Path
		this.Content := Content
		this.Calls := 0
		this.WriteAccepted := false
	}
	__Get(Name, Parameters) {
		if Name != "Value"
			throw PropertyError("Unexpected controlled value property")
		this.Calls += 1
		if this.Calls == 1
			this.WriteAccepted := FSWriteDurable(this.Path, this.Content) == 1
		return true
	}
}

_TBUI_ConcurrentSourceRefusesCandidate() {
	for BuildOnly in [true, false] {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . '[settings]`nowned = false`n'
		Concurrent := Chr(0xFEFF) . '[settings]`nowned = false`nforeign = "concurrent authority"`n'
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			Value := _TBUI_SourceMutatingBoolean(Path, Concurrent)
			Update := { Section: "settings", Key: "owned", Value: Value }
			if BuildOnly {
				Result := TOML_BuildUpdatedContent(Path, [Update])
				AssertEqual("error", Result["status"])
			} else
				AssertFalse(TOML_BatchWrite(Path, [Update]))
			AssertTrue(Value.Calls > 0, "the real renderer must observe the controlled native value")
			AssertTrue(Value.WriteAccepted, "the concurrent source mutation must actually reach disk")
			AssertTrue(FSUtf8ExactMatches(Path, Concurrent), "fresh source authority cannot be overwritten or called a no-op")
			Current := ParseTomlFile(Path)
			if BuildOnly {
				AssertTrue(Cached == Current, "a refused detached build does not replace the live reader cache")
				AssertFalse(Current["settings"].Has("foreign"))
			} else {
				AssertFalse(Cached == Current, "an ordinary writer retires its actually stale reader snapshot")
				AssertEqual("concurrent authority", Current["settings"]["foreign"])
			}
			AssertFalse(Cached["settings"].Has("foreign"), "retirement never mutates the prior reader object")
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: actual concurrent mutation cannot gain detached or ordinary publication (toml-writer-document)",
	_TBUI_ConcurrentSourceRefusesCandidate)


_TBUI_SemanticDestinationsCannotHideEffects() {
	Path := _TBUI_NewPath()
	Source := Chr(0xFEFF) . 'future.root = 1 # old reader ignores this`n[settings]`npersonal.future.enabled = false`nowned=1`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Unchanged := { Section: "settings.personal.future", Key: "enabled", Value: TOML_Bool(false) }
		Candidate := TOML_BuildUpdatedContent(Path, [Unchanged])
		AssertEqual("ok", Candidate["status"], "a strict semantic destination already carries the desired value")
		Assert(StrCompare(Source, Candidate["content"], true) == 0)
		AssertTrue(TOML_BatchWrite(Path, [Unchanged]))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		for Update in [{ Section: "future", Key: "root", Delete: 1 },
			{ Section: "settings.personal.future", Key: "enabled", Delete: 1 },
			{ Section: "settings.personal.future", Key: "enabled", Value: TOML_Bool(true) }] {
			AssertEqual("error", TOML_BuildUpdatedContent(Path, [Update])["status"])
			AssertFalse(TOML_BatchWrite(Path, [Update]), "an unaddressable semantic change cannot be called a flat no-op")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		}
		AssertEqual("error", TOML_BuildUpdatedContent(Path, [], ["future"])["status"],
			"replacing an ignored root namespace is a real semantic deletion")
		AssertFalse(TOML_BatchWrite(Path, [], ["future"]))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally FSDelete(Path)
}
Test("toml writer admission: semantic no-ops do not hide ignored-root deletes or exact-subtree loss (toml-writer-document)",
	_TBUI_SemanticDestinationsCannotHideEffects)


; Independent complete images pin the configuration-only writer's new boundary.
; Descendant edits preserve unowned inline source tokens; explicit whole-cell
; updates retain the generic native Map rendering contract in _TIT_Render.
; The generic writer's historical namespace-loss refusals above remain intact.
_TBUI_ConfigDocumentVectors() {
	return [
		{ Id: "root dotted", Source: '# source anchor`nlayout.ergopti_base = true`nfuture.version = "001" # retained`n',
			Updates: [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }],
			Expected: '# source anchor`nlayout.ergopti_base = false`nfuture.version = "001" # retained`n' },
		{ Id: "relative dotted", Source: '[hotstrings]`nautocorrection.caps.enabled = true`ntrigger_char = "@" # retained`n',
			Updates: [{ Section: "hotstrings.autocorrection.caps", Key: "enabled", Value: TOML_Bool(false) }],
			Expected: '[hotstrings]`nautocorrection.caps.enabled = false`ntrigger_char = "@" # retained`n' },
		{ Id: "inline namespace", Source: 'layout = { ergopti_base = true, future = "001" }`n# retained after inline`n',
			Updates: [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }],
			Expected: 'layout = { ergopti_base = false, future = "001" }`n# retained after inline`n' },
		{ Id: "table array neighbors", Source: '[[future]]`nname="first" # generation one`n[[future]]`nname="second" # generation two`n[layout]`nergopti_base = true`n',
			Updates: [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }],
			Expected: '[[future]]`nname="first" # generation one`n[[future]]`nname="second" # generation two`n[layout]`nergopti_base = false`n' },
		{ Id: "literal versus nested dots", Source: 'layout.ergopti_base = true`n["layout.extra"]`n"literal.dot" = "001" # exact literal`n',
			Updates: [{ Section: '"layout.extra"', Key: "literal.dot", Value: "002" }],
			Expected: 'layout.ergopti_base = true`n["layout.extra"]`n"literal.dot" = "002"`n' },
		{ Id: "new namespace with native-readable header", Source: 'layout.ergopti_base = true`n[future]`nold = "001" # retained`n',
			Updates: [{ Section: "script", Key: "locale", Value: "fr" }],
			Expected: 'layout.ergopti_base = true`n[future]`nold = "001" # retained`n[script]`nlocale = "fr"`n' },
		{ Id: "new leaf in explicit owner", Source: 'future.version = "001"`n[layout]`nergopti_base = true`n[future.other]`nkeep = false # retained`n',
			Updates: [{ Section: "layout", Key: "ergopti_altgr", Value: TOML_Bool(false) }],
			Expected: 'future.version = "001"`n[layout]`nergopti_altgr = false`nergopti_base = true`n[future.other]`nkeep = false # retained`n' },
		{ Id: "semantic leaf deletion", Source: 'layout.ergopti_base = true`nlayout.ergopti_altgr = false # retained`n',
			Updates: [{ Section: "layout", Key: "ergopti_base", Delete: 1 }],
			Expected: 'layout.ergopti_altgr = false # retained`n' },
		{ Id: "inline leaf addition", Source: 'layout = { ergopti_base = true, future = "001" }`n',
			Updates: [{ Section: "layout", Key: "ergopti_altgr", Value: TOML_Bool(false) }],
			Expected: 'layout = { ergopti_base = true, future = "001",ergopti_altgr = false }`n' },
		{ Id: "exact Unicode quoted identities", Source: 'hotstrings.personal."é.Case".enabled = true`nhotstrings.personal."É.Case".enabled = false # distinct retained owner`n',
			Updates: [{ Section: 'hotstrings.personal."é.Case"', Key: "enabled", Value: TOML_Bool(false) }],
			Expected: 'hotstrings.personal."é.Case".enabled = false`nhotstrings.personal."É.Case".enabled = false # distinct retained owner`n' },
		{ Id: "empty quoted identity", Source: 'hotstrings.personal."".enabled = true`n[future]`nkeep = "001" # retained`n',
			Updates: [{ Section: 'hotstrings.personal.""', Key: "enabled", Value: TOML_Bool(false) }],
			Expected: 'hotstrings.personal."".enabled = false`n[future]`nkeep = "001" # retained`n' },
		{ Id: "typed multiline neighbor", Source: 'layout.ergopti_base = true`n[future]`ntext = ' . Chr(34) . Chr(34) . Chr(34) . 'first`nsecond' . Chr(34) . Chr(34) . Chr(34) . ' # retain multiline`nitems = [1, # retain array comment`n2]`n',
			Updates: [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }],
			Expected: 'layout.ergopti_base = false`n[future]`ntext = ' . Chr(34) . Chr(34) . Chr(34) . 'first`nsecond' . Chr(34) . Chr(34) . Chr(34) . ' # retain multiline`nitems = [1, # retain array comment`n2]`n' }
	]
}

_TBUI_ConfigDocumentVector(Vector) {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
	Expected := Chr(0xFEFF) . Vector.Expected
	Source := _CMJFixtureCurrentSource(Source)
	Expected := _CMJFixtureCurrentSource(Expected)
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"],
			"the native boot owner must admit the independent current fixture")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source),
			"current-schema admission preserves every independent source byte")
		Cached := ParseTomlFile(Path)
		Candidate := TOML_BuildConfigUpdatedContent(Path, Vector.Updates)
		AssertEqual("ok", Candidate["status"], Vector.Id)
		AssertEqual(Expected, Candidate["content"], "the complete independent physical image must match")
		AssertEqual(Source, Candidate["source_content"])
		AssertEqual(1, Candidate["source_present"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "detached semantic preparation never publishes")
		AssertTrue(Cached == ParseTomlFile(Path), "detached preparation retains live cache identity")
		AssertTrue(TOML_ConfigBatchWrite(Path, Vector.Updates), "the actual guarded writer must publish")
		AssertTrue(FSUtf8ExactMatches(Path, Expected), "native publication matches the independent full byte image")
		AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
	} finally FSDelete(Path)
}
for _TBUI_ConfigVector in _TBUI_ConfigDocumentVectors()
	Test("toml config document writer: " . _TBUI_ConfigVector.Id,
		_TBUI_ConfigDocumentVector.Bind(_TBUI_ConfigVector))

_TBUI_ConfigBlockedDestinations() {
	for Source in [
		'hotstrings.modules.magickey = true # retain obsolete scalar`n',
		'hotstrings.modules.magickey = ["retain"] # retain obsolete array`n',
		'[[hotstrings.modules.magickey]]`nenabled = true # retain generation`n'
	] {
		Path := _TBUI_NewPath(), Original := Chr(0xFEFF) . Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Original) == 1)
			Update := { Section: "hotstrings.modules.magickey", Key: "enabled", Value: TOML_Bool(false) }
			AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, [Update])["status"])
			AssertFalse(TOML_ConfigBatchWrite(Path, [Update]), "obsolete containers remain until explicit cleanup")
			AssertTrue(FSUtf8ExactMatches(Path, Original))
		} finally FSDelete(Path)
	}
}
Test("toml config document writer: scalar array and table-array collisions refuse", _TBUI_ConfigBlockedDestinations)

_TBUI_ConfigSourceMutationRefuses() {
	for BuildOnly in [true, false] {
		Path := _TBUI_NewPath(), Original := Chr(0xFEFF) . 'layout.ergopti_base = false`n'
		Foreign := Chr(0xFEFF) . 'layout.ergopti_base = false`nfuture.source = "concurrent"`n'
		Original := _CMJFixtureCurrentSource(Original)
		Foreign := _CMJFixtureCurrentSource(Foreign)
		try {
			AssertTrue(FSWriteCreateDurable(Path, Original) == 1)
			AssertEqual("current", ConfigMigrateBoot(Path)["status"],
				"the native boot owner must admit the independent current fixture")
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
			AssertTrue(FSUtf8ExactMatches(Path, Original),
				"current-schema admission preserves every independent source byte")
			Value := _TBUI_SourceMutatingBoolean(Path, Foreign)
			Updates := [{ Section: "layout", Key: "ergopti_base", Value: Value }]
			if BuildOnly
				AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, Updates)["status"])
			else
				AssertFalse(TOML_ConfigBatchWrite(Path, Updates))
			AssertTrue(Value.Calls > 0)
			AssertTrue(Value.WriteAccepted, "the controlled source mutation reached the real filesystem")
			AssertTrue(FSUtf8ExactMatches(Path, Foreign), "semantic rendering cannot overwrite a superseded source")
		} finally FSDelete(Path)
	}
}
Test("toml config document writer: actual source drift refuses detached and ordinary publication", _TBUI_ConfigSourceMutationRefuses)

_TBUI_ConfigDuplicateSourceRefuses() {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . 'layout.ergopti_base = true`n[layout]`nergopti_base = false`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Updates := [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]
		AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, Updates)["status"])
		AssertFalse(TOML_ConfigBatchWrite(Path, Updates))
		AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, [])["status"])
		AssertFalse(TOML_ConfigBatchWrite(Path, []), "even an empty semantic write must admit the complete source")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "semantic aliases do not gain staging authority")
	} finally FSDelete(Path)
}
Test("toml config document writer: duplicate semantic sources refuse", _TBUI_ConfigDuplicateSourceRefuses)

_TBUI_ConfigNoOpRetainsOwnedComments() {
	Path := _TBUI_NewPath()
	Source := Chr(0xFEFF) . '# user heading`n[layout] # layout owner`nergopti_base = true # owned preference`nfuture = "001" # future record`n'
	Source := _CMJFixtureCurrentSource(Source)
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"],
			"the native boot owner must admit the independent current fixture")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source),
			"current-schema admission preserves every independent source byte")
		Updates := [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }]
		Candidate := TOML_BuildConfigUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"])
		AssertEqual(Source, Candidate["content"], "owned unchanged comments remain exact configuration source")
		AssertTrue(TOML_ConfigBatchWrite(Path, Updates))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally FSDelete(Path)
}
Test("toml config document writer: unchanged owned comments remain byte stable", _TBUI_ConfigNoOpRetainsOwnedComments)

_TBUI_ConfigExplicitNamespaceReplacement() {
	Path := _TBUI_NewPath()
	Source := Chr(0xFEFF) . '# source anchor`nhotstrings.modules.magickey = true`n[future]`nold = "001" # retained`n'
	Expected := Chr(0xFEFF) . '# source anchor`n[future]`nold = "001" # retained`n[hotstrings.modules.magickey]`nenabled = false`n'
	Source := _CMJFixtureCurrentSource(Source)
	Expected := _CMJFixtureCurrentSource(Expected)
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"],
			"the native boot owner must admit the independent current fixture")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source),
			"current-schema admission preserves every independent source byte")
		Updates := [{ Section: "hotstrings.modules.magickey", Key: "enabled", Value: TOML_Bool(false) }]
		Prefixes := ["hotstrings.modules.magickey"]
		AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, Updates)["status"], "an ordinary save retains the obsolete scalar")
		Candidate := TOML_BuildConfigUpdatedContent(Path, Updates, Prefixes)
		AssertEqual("ok", Candidate["status"], "only explicit namespace ownership permits replacement")
		AssertEqual(Expected, Candidate["content"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "explicit preparation is still detached")
		AssertTrue(TOML_ConfigBatchWrite(Path, Updates, Prefixes))
		AssertTrue(FSUtf8ExactMatches(Path, Expected))
	} finally FSDelete(Path)
}
Test("toml config document writer: explicit namespace replacement alone releases retired scalar", _TBUI_ConfigExplicitNamespaceReplacement)

_TBUI_ConfigGatewayUsesSemanticWriter() {
	global ConfigurationFile
	HadPath := IsSet(ConfigurationFile), PreviousPath := HadPath ? ConfigurationFile : ""
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . 'layout.ergopti_base = true`nfuture.version = "001" # retained`n'
	Expected := Chr(0xFEFF) . 'layout.ergopti_base = false`nfuture.version = "001" # retained`n'
	Source := _CMJFixtureCurrentSource(Source)
	Expected := _CMJFixtureCurrentSource(Expected)
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"],
			"the native boot owner must admit the independent current fixture")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source),
			"current-schema admission preserves every independent source byte")
		ConfigurationFile := Path
		Updates := [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]
		AssertTrue(ConfigCommitUpdates(Path, Updates, "semantic config gateway fixture", 0, (*) => 0),
			"the real admitted config gateway must select the semantic writer")
		AssertTrue(FSUtf8ExactMatches(Path, Expected))
	} finally {
		ConfigurationFile := HadPath ? PreviousPath : unset
		FSDelete(Path)
	}
}
Test("toml config document writer: actual configuration gateway owns semantic publication", _TBUI_ConfigGatewayUsesSemanticWriter)


; This native probe preserves the existing full-save refusal and separately
; observes its actual filtered batch. No assertion runs inside a caught port.
_TBUI_ConfigInlineFullSaveAdmission(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Source := FSReadUtf8Exact(Path), Probe := { calls: 0, rows: [], image: Map() }
	Target := ManifestBuildFeaturesMap()
	Collect() {
		Updates := []
		_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Target["hotstrings"]["autocorrection"]["names"])
		return Updates
	}
	Writer(TargetPath, Rows) {
		Probe.calls += 1
		Probe.rows := Rows
		Probe.image := TOML_BuildConfigUpdatedContent(TargetPath, Rows)
		return TOML_BatchWrite(TargetPath, Rows)
	}
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		ParseConfigTomlFile(Path)
		AssertEqual(1, ApplyBootConfigToml(Target, Path))
		AssertTrue(_ConfigBootOutdatedEntries.Has("hotstrings.autocorrection.names`nenabled"))
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(Writer, (*) => true, true, 0, Collect),
			"the full-state publication owner retains its current strict admission")
		AssertEqual(1, Probe.calls, "the actual full-save writer port observes one filtered batch")
		AssertEqual(1, Probe.rows.Length)
		AssertEqual("hotstrings.autocorrection.names", Probe.rows[1].Section)
		AssertEqual("time_activation_seconds", Probe.rows[1].Key)
		AssertEqual(0.25, Probe.rows[1].Value)
		AssertFalse(Probe.rows[1].HasOwnProp("Delete"))
		AssertEqual("ok", Probe.image["status"])
		AssertEqual(Source, Probe.image["content"], "the separate semantic candidate preserves every obsolete and unknown source byte")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "the probe cannot publish or clean an obsolete child")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_TBUI_ConfigInlineFullSaveAdmissionProbe() {
	_FMS_WithSource("config_writer_inline_admission",
		_CMJFixtureCurrentSource('[hotstrings]`nautocorrection = { names = { enabled = "true", time_activation_seconds = 0.25, future = "retain" } } # preserve`n'),
		_TBUI_ConfigInlineFullSaveAdmission)
}
Test("toml config document writer: native full-save probe retains strict refusal and observes exact semantic no-op", _TBUI_ConfigInlineFullSaveAdmissionProbe)


; The native scope owner keeps a live flat reader until replacement boot. A new
; peer of an explicit dynamic section must therefore retain that physical shape.
_TBUI_ConfigNewSiblingRetainsNativeReadability() {
	for Parent in ["hotstrings.personal", "features.dynamic"] {
		Path := _TBUI_NewPath()
		Source := Chr(0xFEFF) . "[" . Parent . ".first]`nenabled = false # keep first`n"
			. '[private]`nfuture = "keep" # exact neighbor`n'
		Expected := Source . "[" . Parent . ".second]`nenabled = true`n"
		Source := _CMJFixtureCurrentSource(Source)
		Expected := _CMJFixtureCurrentSource(Expected)
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			AssertEqual("current", ConfigMigrateBoot(Path)["status"],
				"the native boot owner must admit the independent current fixture")
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
			AssertTrue(FSUtf8ExactMatches(Path, Source),
				"current-schema admission preserves every independent source byte")
			Cached := ParseTomlFile(Path)
			Updates := [{ Section: Parent . ".second", Key: "enabled", Value: TOML_Bool(true) }]
			Candidate := TOML_BuildConfigUpdatedContent(Path, Updates)
			AssertEqual("ok", Candidate["status"])
			AssertEqual(Expected, Candidate["content"], "new peers keep their explicit native section family")
			AssertTrue(Cached == ParseTomlFile(Path), "preparation cannot invalidate the live flat cache")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
			AssertTrue(TOML_ConfigBatchWrite(Path, Updates))
			AssertTrue(FSUtf8ExactMatches(Path, Expected))
			AssertEqual(1, TOML_Read(Path, Parent . ".second", "enabled", false),
				"the actual post-publication native reader sees the newly discovered section")
			AssertEqual(0, TOML_Read(Path, Parent . ".first", "enabled", true))
			AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
			AssertEqual(Expected, TOML_BuildConfigUpdatedContent(Path, Updates)["content"],
				"a subsequent semantic no-op retains the full byte image")
		} finally FSDelete(Path)
	}
}
Test("toml config document writer: new dynamic peer headers retain native readback (config-semantic-native-readback)",
	_TBUI_ConfigNewSiblingRetainsNativeReadability)

; Independent complete images cover first publication without a sibling header.
; Both the semantic document and the native flat reader must observe the value.
_TBUI_ConfigNewNamespaceRetainsNativeReadability() {
	for Section in ["script", "shortcuts.script_control", "hotstrings.personal.first"] {
		for Prefix in ["", '[private]`nfuture = "keep" # retained`n'] {
			Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Prefix
			Expected := Source . "[" . Section . "]`nenabled = false`n"
			Source := _CMJFixtureCurrentSource(Source)
			Expected := _CMJFixtureCurrentSource(Expected)
			try {
				AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
				AssertEqual("current", ConfigMigrateBoot(Path)["status"],
					"the native boot owner must admit the independent current fixture")
				AssertTrue(ConfigSchemaCanPrepareWrite(Path))
				AssertTrue(FSUtf8ExactMatches(Path, Source),
					"current-schema admission preserves every independent source byte")
				Updates := [{ Section: Section, Key: "enabled", Value: TOML_Bool(false) }]
				Candidate := TOML_BuildConfigUpdatedContent(Path, Updates)
				AssertEqual("ok", Candidate["status"])
				AssertEqual(Expected, Candidate["content"], "first publication uses the independently specified native section")
				AssertTrue(FSUtf8ExactMatches(Path, Source), "preparation preserves exact physical source")
				AssertTrue(TOML_ConfigBatchWrite(Path, Updates))
				AssertTrue(FSUtf8ExactMatches(Path, Expected))
				AssertEqual(0, TOML_Read(Path, Section, "enabled", "missing"),
					"the real fresh flat reader must distinguish false from a missing new namespace")
				AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
				AssertEqual(Expected, TOML_BuildConfigUpdatedContent(Path, Updates)["content"])
			} finally FSDelete(Path)
		}
	}
}
Test("toml config document writer: first namespace publication retains native readback (config-semantic-native-readback)",
	_TBUI_ConfigNewNamespaceRetainsNativeReadability)

; Explicit replacement releases its source declarations before header admission.
; These complete images are independent of the writer's rendered candidate.
_TBUI_ConfigReplacedNamespaceRetainsNativeReadability() {
	for OwnedSource in ['script = "obsolete"`n', '[script]`nlog_level = "INFO"`n', 'script = { log_level = "INFO" }`n'] {
		Path := _TBUI_NewPath()
		Source := Chr(0xFEFF) . "# source anchor`n" . OwnedSource . '[private]`nfuture = "keep" # retained`n'
		Expected := Chr(0xFEFF) . '# source anchor`n[private]`nfuture = "keep" # retained`n[script]`nlog_level = "ERROR"`n'
		Source := _CMJFixtureCurrentSource(Source)
		Expected := _CMJFixtureCurrentSource(Expected)
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			AssertEqual("current", ConfigMigrateBoot(Path)["status"],
				"the native boot owner must admit the independent current fixture")
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
			AssertTrue(FSUtf8ExactMatches(Path, Source),
				"current-schema admission preserves every independent source byte")
			Updates := [{ Section: "script", Key: "log_level", Value: "ERROR" }]
			Prefixes := ["script"]
			Candidate := TOML_BuildConfigUpdatedContent(Path, Updates, Prefixes)
			AssertEqual("ok", Candidate["status"])
			AssertEqual(Expected, Candidate["content"])
			AssertTrue(FSUtf8ExactMatches(Path, Source), "replacement preparation cannot publish")
			AssertTrue(TOML_ConfigBatchWrite(Path, Updates, Prefixes))
			AssertTrue(FSUtf8ExactMatches(Path, Expected))
			AssertEqual("ERROR", TOML_Read(Path, "script", "log_level", "missing"))
			AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
		} finally FSDelete(Path)
	}
}
Test("toml config document writer: explicit replacement releases native-readable headers (config-semantic-native-readback)",
	_TBUI_ConfigReplacedNamespaceRetainsNativeReadability)


; These complete images are hand-authored from the original source and explicit
; owned edits. Foreign token spellings, order and trivia never come from rendering.
_TBUI_ConfigInlineSpanVectors() {
	return [
		{ Id: 'actual names timing order', Source: 'hotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.25, future = "retain"}}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'hotstrings.autocorrection.names', Key: 'time_activation_seconds', Value: 0.75 }],
			Expected: 'hotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.75, future = "retain"}}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'API entry descendant tokens', Source: 'llm = {enabled = false, api_entry_id = "api_old", future = "retain"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'llm', Key: 'enabled', Value: TOML_Bool(true) }, { Section: 'llm', Key: 'api_entry_id', Value: 'api_new' }],
			Expected: 'llm = {enabled = true, api_entry_id = "api_new", future = "retain"}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'wizard locale descendant tokens', Source: 'script = {locale = "en", future = "retain"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'script', Key: 'locale', Value: 'fr' }],
			Expected: 'script = {locale = "fr", future = "retain"}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'assignment spaces and inline trivia', Source: '`tsettings`t=`t{  owned`t=`tfalse , foreign = "001"  } # exact tail`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: '`tsettings`t=`t{  owned`t=`ttrue , foreign = "001"  } # exact tail`n[future]`nold = "retain" # user data`n' },
		{ Id: 'quoted equals delimiter authority', Source: 'settings = { "a.b" = { "x=y,#}" = 1, future = `'001`' }, a = { b = { "x=y,#}" = 2 } } }`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings."a.b"', Key: 'x=y,#}', Value: 3 }],
			Expected: 'settings = { "a.b" = { "x=y,#}" = 3, future = `'001`' }, a = { b = { "x=y,#}" = 2 } } }`n[future]`nold = "retain" # user data`n' },
		{ Id: 'unknown exact numeric spellings', Source: 'settings = {owned=false, huge=9223372036854775807, tiny=1e-308, hex=0x0010, decimal=1_000.00, quoted="001"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings = {owned=true, huge=9223372036854775807, tiny=1e-308, hex=0x0010, decimal=1_000.00, quoted="001"}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'nested array future containers', Source: 'settings = {owned=false, future=[{id="a", enabled=false}, {id="b", payload=["x,}#=", {empty={}}]}]}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings = {owned=true, future=[{id="a", enabled=false}, {id="b", payload=["x,}#=", {empty={}}]}]}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'multiline basic string tokens', Source: 'settings = {owned=false, future=' . Chr(34) . Chr(34) . Chr(34) . 'first`nsecond,#=}`nthird' . Chr(34) . Chr(34) . Chr(34) . '}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings = {owned=true, future=' . Chr(34) . Chr(34) . Chr(34) . 'first`nsecond,#=}`nthird' . Chr(34) . Chr(34) . Chr(34) . '}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'multiline literal string tokens', Source: 'settings = {owned=false, future=`'`'`'first`nsecond,#=}`nthird`'`'`'}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings = {owned=true, future=`'`'`'first`nsecond,#=}`nthird`'`'`'}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'dotted inline destination', Source: 'settings = {a.b=1, a.c = 2, "a.b" = 7}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.a', Key: 'b', Value: 3 }],
			Expected: 'settings = {a.b=3, a.c = 2, "a.b" = 7}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'owned deletion retains neighbors', Source: 'settings={first=1,remove=2,last=3}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'remove', Delete: 1 }],
			Expected: 'settings={first=1,last=3}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'owned deletion retains unowned trivia', Source: 'settings={ first=1, remove=2, last=3 }`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'remove', Delete: 1 }],
			Expected: 'settings={ first=1, last=3 }`n[future]`nold = "retain" # user data`n' },
		{ Id: 'explicit whole cell stays canonical', Source: 'settings = {future="release by explicit ownership", owned=false}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: '', Key: 'settings', Value: Map('owned', TOML_Bool(true), 'first', 1) }],
			Expected: 'settings = {first = 1, owned = true}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'semantic no-op retains raw image', Source: 'settings = {owned=false, future = "001" } # exact no-op`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(false) }],
			Expected: 'settings = {owned=false, future = "001" } # exact no-op`n[future]`nold = "retain" # user data`n' },
		{ Id: 'empty inline insertion retains closing trivia', Source: 'settings = { }`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings = { owned = true}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'empty quoted nested identity', Source: 'settings={""={enabled=false, future="retain"}, other="unchanged"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.""', Key: 'enabled', Value: TOML_Bool(true) }],
			Expected: 'settings={""={enabled=true, future="retain"}, other="unchanged"}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'escaped quotes and unsafe delimiters', Source: 'settings={"a\"=b"={value="x,}#=\"y", future="001"}, stable=0}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings."a\"=b"', Key: 'value', Value: 'replacement' }],
			Expected: 'settings={"a\"=b"={value="replacement", future="001"}, stable=0}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'Unicode literal identity spans', Source: 'settings={"é.😀"={owned=false, future="é😀"}, stable="001"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings."é.😀"', Key: 'owned', Value: TOML_Bool(true) }],
			Expected: 'settings={"é.😀"={owned=true, future="é😀"}, stable="001"}`n[future]`nold = "retain" # user data`n' },
		{ Id: 'last dotted descendant deletion', Source: 'settings={a.b=1}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.a', Key: 'b', Delete: 1 }],
			Expected: 'settings={a = {}}`n[future]`nold = "retain" # user data`n' }
	]
}

_TBUI_ConfigInlineSpanVector(Vector) {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
	Expected := Chr(0xFEFF) . Vector.Expected
	Source := _CMJFixtureCurrentSource(Source)
	Expected := _CMJFixtureCurrentSource(Expected)
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"],
			"the native boot owner must admit the independent current fixture")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source),
			"current-schema admission preserves every independent source byte")
		FileSetTime("20000101000000", Path, "M")
		BeforeTime := FileGetTime(Path, "M")
		Cached := ParseTomlFile(Path)
		Candidate := TOML_BuildConfigUpdatedContent(Path, Vector.Updates)
		AssertEqual("ok", Candidate["status"], Vector.Id)
		AssertEqual(Expected, Candidate["content"], "only explicit owned source spans change")
		AssertEqual(Source, Candidate["source_content"])
		AssertEqual(1, Candidate["source_present"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "detached inline edits do not publish")
		AssertTrue(Cached == ParseTomlFile(Path), "detached inline preparation retains the cache identity")
		AssertTrue(TOML_ConfigBatchWrite(Path, Vector.Updates) == 1,
			"the actual native publisher strictly acknowledges the owned edit")
		AssertTrue(FSUtf8ExactMatches(Path, Expected), "native publication preserves every independent unowned byte")
		AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
		AssertEqual(Expected, TOML_BuildConfigUpdatedContent(Path, Vector.Updates)["content"],
			"subsequent semantic no-op retains the qualified complete image")
		if Source == Expected
			AssertEqual(BeforeTime, FileGetTime(Path, "M"), "a no-op retains the original modification time")
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "publication and no-op settle every owned stage")
	} finally FSDelete(Path)
}
for _TBUI_InlineSpanVector in _TBUI_ConfigInlineSpanVectors()
	Test("toml config inline source spans: " . _TBUI_InlineSpanVector.Id,
		_TBUI_ConfigInlineSpanVector.Bind(_TBUI_InlineSpanVector))

_TBUI_ConfigInlineSpanRefusalVectors() {
	return [
		{ Id: 'new member through a dotted parent', Source: 'settings = {a.b=1, a.c = 2, "a.b" = 7 }`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.a', Key: 'd', Value: 3 }] },
		{ Id: 'container over an inline member', Source: 'settings={ owned = {future="release explicitly", value=1}, neighbor="retain" }`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: Map('value', 2) }] },
		{ Id: 'case twin in an inline owner', Source: 'settings={A={enabled=false,keep="upper"}, a={enabled=true,keep="lower"}}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.A', Key: 'enabled', Value: TOML_Bool(true) }] },
		{ Id: 'retained scalar collision', Source: 'settings={blocked=1, future={keep="001"}}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.blocked', Key: 'leaf', Value: 2 }] },
		{ Id: 'retained array collision', Source: 'settings={blocked=[1,2], future={keep="001"}}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings.blocked', Key: 'leaf', Value: 2 }] },
		{ Id: 'duplicate inline semantic alias', Source: 'settings={owned=false, "owned"=true}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }] },
		{ Id: 'invalid quoted equals source', Source: 'settings={"bad=key=1, future="retain"}`n[future]`nold = "retain" # user data`n',
			Updates: [{ Section: 'settings', Key: 'owned', Value: TOML_Bool(true) }] }
	]
}

_TBUI_ConfigInlineSpanRefusal(Vector) {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		FileSetTime("20000101000000", Path, "M")
		BeforeTime := FileGetTime(Path, "M")
		AssertEqual("error", TOML_BuildConfigUpdatedContent(Path, Vector.Updates)["status"])
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		AssertFalse(TOML_ConfigBatchWrite(Path, Vector.Updates), "unprovable inline ownership cannot publish")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "refusal retains the exact complete source")
		AssertEqual(BeforeTime, FileGetTime(Path, "M"), "refusal retains the modification time")
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "refusal precedes all staging")
	} finally FSDelete(Path)
}
for _TBUI_InlineSpanRefusal in _TBUI_ConfigInlineSpanRefusalVectors()
	Test("toml config inline source spans refusal: " . _TBUI_InlineSpanRefusal.Id,
		_TBUI_ConfigInlineSpanRefusal.Bind(_TBUI_InlineSpanRefusal))

_TBUI_ConfigInlineTokenOffsets() {
	for Raw in ['  "x,}#=\"y"  # exact comment`n',
		'  ' . Chr(34) . Chr(34) . Chr(34) . 'first`nsecond,#=}' . Chr(34) . Chr(34) . Chr(34) . '  # exact multiline comment`n',
		"  " . Chr(39) . Chr(39) . Chr(39) . "first`nsecond,#=}"
			. Chr(39) . Chr(39) . Chr(39) . "  # exact literal comment`n"] {
		Position := 1
		Token := _TOML_DocumentToken(Raw, &Position, "", , &SpanStart, &SpanEnd)
		AssertEqual(Token, SubStr(Raw, SpanStart, SpanEnd - SpanStart + 1),
			"the actual canonical lexical owner reports the complete quoted token")
		AssertEqual(StrLen(Raw) + 1, Position)
		AssertEqual("  ", SubStr(Raw, 1, SpanStart - 1))
		AssertTrue(InStr(SubStr(Raw, SpanEnd + 1), "# exact") > 0)
	}
}
Test("toml config inline source spans: actual lexer reports escaped and multiline offsets", _TBUI_ConfigInlineTokenOffsets)


_TBUI_ConfigInlineCanonicalReader() {
	Literal := Chr(39) . Chr(39) . Chr(39)
	Raw := 'settings={owned=false, future=' . Literal . "first`nsecond,#=}`nthird" . Literal . "}`n"
	Document := TOML_ParseDocument(Raw)
	AssertTrue(TOML_SameValue(Document["settings"]["owned"], TOML_Bool(false)),
		"the actual semantic reader retains Boolean intent before any source edit")
	AssertEqual("first`nsecond,#=}`nthird", Document["settings"]["future"],
		"the canonical lexer protects every literal multiline structural character")
	Simple := '{a=false, b={future="001"}, c=[1,2]}'
	AssertTrue(TOML_SameValue(TOML_ParseInlineTable(Simple, _TOML_DocumentValue),
		TOML_ParseInlineTable(Simple, _TOML_DocumentValue, _TOML_DocumentSplit)),
		"ordinary generic caller behavior and semantic delegation agree")
	for Invalid in ['settings={a=1,}`n', 'settings={,a=1}`n', 'settings={a=1,,b=2}`n']
		AssertThrows(TOML_ParseDocument.Bind(Invalid),
			"canonical delegation cannot admit empty or trailing inline members")
}
Test("toml config inline source spans: semantic reader reuses the actual canonical multiline lexer",
	_TBUI_ConfigInlineCanonicalReader)

_TWSC_Units(Value) {
	Result := "length=" . StrLen(Value) . ":"
	Loop StrLen(Value)
		Result .= Format("{:04X}", NumGet(StrPtr(Value), (A_Index - 1) * 2, "UShort")) . ","
	return Result
}
_TWSC_Equal(Expected, Actual) {
	AssertTrue(Actual is String)
	AssertEqual(StrLen(Expected), StrLen(Actual), "roundtrip retains every original UTF-16 unit")
	Loop StrLen(Expected)
		AssertEqual(NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort"),
			NumGet(StrPtr(Actual), (A_Index - 1) * 2, "UShort"))
}
_TWSC_Value(Kind) {
	Encoded := Kind == "nul" ? 'A\u0000B' : Kind == "control" ? 'A\u0001B' : 'A\\u0000B'
	Payload := JsonParse('{"value":"' . Encoded . '"}')
	Value := Payload["value"]
	AssertTrue(Value is String)
	if Kind != "literal" {
		AssertEqual(3, StrLen(Value))
		AssertEqual(65, NumGet(StrPtr(Value), 0, "UShort"))
		AssertEqual(Kind == "nul" ? 0 : 1, NumGet(StrPtr(Value), 2, "UShort"))
		AssertEqual(66, NumGet(StrPtr(Value), 4, "UShort"))
	} else
		AssertEqual('A\u0000B', Value)
	return Value
}
_TWSC_Render(Kind) {
	Value := _TWSC_Value(Kind)
	Rendered := "", RenderError := 0, Accepted := false, Actual := ""
	try Rendered := TOML_RenderValue(Value)
	catch as Err
		RenderError := Err
	if !IsObject(RenderError) {
		try {
			Actual := TOML_ParseDocument("value = " . Rendered)["value"]
			Accepted := true
		}
	}
	_TestPrint("# toml-scalar-render kind=" . Kind . " requested=" . _TWSC_Units(Value)
		. " render-error=" . (IsObject(RenderError) ? Type(RenderError) : "none")
		. " decoded=" . Accepted . " actual=" . (Accepted ? _TWSC_Units(Actual) : "<refused>"))
	if Kind == "nul"
		AssertTrue(RenderError is ValueError, "the real public renderer must refuse a native unsupported scalar before producing another value")
	else {
		if IsObject(RenderError)
			throw RenderError
		AssertTrue(Accepted)
		_TWSC_Equal(Value, Actual)
	}
}
_TWSC_Write(Kind) {
	Value := _TWSC_Value(Kind)
	Root := A_Temp . "\ergopti_toml_scalar_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\values.toml", Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, '[owned]`nvalue = "Original"`n'))
		Before := FSReadBytesStrict(Path)
		Result := 0, WriteError := 0
		try Result := TOML_BatchWrite(Path, [{Section: "owned", Key: "value", Value: Value}])
		catch as Err
			WriteError := Err
		After := FSReadBytesStrict(Path)
		Accepted := false, Actual := ""
		try {
			Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))["owned"]["value"]
			Accepted := true
		}
		_TestPrint("# toml-scalar-write kind=" . Kind . " result=" . Result . " requested=" . _TWSC_Units(Value)
			. " decoded=" . Accepted . " actual=" . (Accepted ? _TWSC_Units(Actual) : "<refused>")
			. " write-error=" . (IsObject(WriteError) ? Type(WriteError) : "none")
			. " before-bytes=" . Before.Size . " after-bytes=" . After.Size)
		if Kind == "nul" {
			if IsObject(WriteError)
				AssertTrue(WriteError is ValueError, "invalid scalar validation may raise only its established ValueError contract")
			else
				AssertTrue(Result is Integer && Result == 0, "unsupported values cannot receive a malformed or successful native ACK")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "an unsupported value must preserve the complete original source")
			AssertTrue(Accepted)
			AssertEqual("Original", Actual)
		} else {
			if IsObject(WriteError)
				throw WriteError
			AssertTrue(Result)
			AssertTrue(Accepted)
			_TWSC_Equal(Value, Actual)
		}
	} finally {
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _TWSC_Kind in ["nul", "control", "literal"] {
	Test("TOML actual scalar render: " . _TWSC_Kind . " (toml-write-scalar)", _TWSC_Render.Bind(_TWSC_Kind))
	Test("TOML actual ordinary scalar write: " . _TWSC_Kind . " (toml-write-scalar)", _TWSC_Write.Bind(_TWSC_Kind))
}

_TUNS_Case(Kind, DocumentMode := false) {
	Payload := JsonParse(Kind == "section" ? '{"section":"owned\u0000foreign","key":"value"}'
		: Kind == "key" ? '{"section":"owned","key":"value\u0000foreign"}' : '{"section":"owned","key":"value"}')
	if Kind != "control" {
		Name := Payload[Kind == "section" ? "section" : "key"]
		AssertEqual(13, StrLen(Name), "the actual JSON name retains its complete prefix, NUL and suffix")
		AssertEqual(0, NumGet(StrPtr(Name), 10, "UShort"))
		AssertEqual(Ord("f"), NumGet(StrPtr(Name), 12, "UShort"))
	}
	Root := A_Temp . "\ergopti_toml_update_name_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\source.toml", Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		Source := '[owned]`nvalue = "Original"`n'
		if DocumentMode
			Source := _CMJFixtureCurrentSource(Source)
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		if DocumentMode {
			; A semantic native writer needs the real current-schema boot authority.
			AssertEqual("current", ConfigMigrateBoot(Path)["status"])
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		}
		Before := FSReadBytesStrict(Path)
		Result := 0, Failure := 0
		Writer := DocumentMode ? TOML_ConfigBatchWrite : TOML_BatchWrite
		try Result := Writer.Call(Path, [{Section: Payload["section"], Key: Payload["key"], Value: "Edited"}])
		catch as Err
			Failure := Err
		After := FSReadBytesStrict(Path)
		Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))["owned"]["value"]
		_TestPrint("# toml-update-name kind=" . Kind . " result=" . Result . " actual-neighbor=" . Actual
			. " exception=" . (IsObject(Failure) ? Type(Failure) : "none")
			. " before-bytes=" . Before.Size . " after-bytes=" . After.Size)
		if Kind == "control" {
			if IsObject(Failure)
				throw Failure
			AssertTrue(Result)
			AssertEqual("Edited", Actual)
		} else {
			if IsObject(Failure)
				AssertTrue(Failure is ValueError || Failure is TypeError, "invalid native identities may refuse at the typed admission boundary")
			else
				AssertTrue(Result is Integer && Result == 0, "an unsupported update name cannot receive a native write ACK")
			AssertEqual("Original", Actual, "a JSON name cannot borrow the distinct shorter native section or key")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"))
		}
	} finally {
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _TUNS_Kind in ["section", "key", "control"]
	Test("TOML actual update-name admission: " . _TUNS_Kind . " (toml-update-name-scalar)", _TUNS_Case.Bind(_TUNS_Kind))


for _TCUNS_Kind in ["section", "key", "control"]
	Test("TOML configuration update-name admission: " . _TCUNS_Kind . " (toml-config-update-name-scalar)",
		_TUNS_Case.Bind(_TCUNS_Kind, true))

_TUNS_PureOwners() {
	Payload := JsonParse('{"section":"owned\u0000foreign","key":"value\u0000foreign"}')
	for Name in [Payload["section"], Payload["key"]] {
		AssertEqual(13, StrLen(Name))
		Failure := 0
		try TOML_RenderKey(Name)
		catch as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "the renderer cannot turn a distinct original name into a shorter bare key")
	}
	for Kind in ["section", "key"] {
		Update := {Section: Kind == "section" ? Payload["section"] : "owned",
			Key: Kind == "key" ? Payload["key"] : "value", Value: "Edited"}
		Failure := 0
		try TOML_BuildConfigDocumentCandidate('[owned]`nvalue = "Original"`n', [Update], [])
		catch as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "direct configuration preparation cannot borrow a shorter native key identity")
	}
	Failure := 0
	try TOML_BuildUpdatedContent(A_Temp . "\ergopti-name-owner-" . A_ScriptHwnd . "-" . Random(100000, 999999) . ".toml", [], [Payload["section"]])
	catch as Err
		Failure := Err
	AssertTrue(Failure is ValueError, "namespace replacement must validate its original prefix before selecting owned sections")
	for CodeUnit in [0xD800, 0xDC00] {
		Invalid := "value" . Chr(CodeUnit)
		AssertEqual(6, StrLen(Invalid))
		AssertEqual(CodeUnit, NumGet(StrPtr(Invalid), 10, "UShort"), "the test retains an actual isolated UTF-16 surrogate")
		Failure := 0
		try TOML_BuildConfigDocumentCandidate('[owned]`nvalue = "Original"`n',
			[{Section: "owned", Key: Invalid, Value: "Edited"}], [])
		catch as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "unpaired original key units must refuse before native identity lookup")
	}
	Valid := TOML_BuildConfigDocumentCandidate('[owned]`nvalue = "Original"`n',
		[{Section: "owned", Key: "value😀", Value: "Edited"}], [])
	Actual := TOML_ParseDocument(Valid["content"])
	AssertEqual("Original", Actual["owned"]["value"])
	AssertEqual("Edited", Actual["owned"]["value😀"], "a valid non-BMP identity remains distinct and writable")
}
Test("TOML original names: render, document preparation and replacement prefixes refuse NUL aliases (toml-name-scalar-owners)",
	_TUNS_PureOwners)
