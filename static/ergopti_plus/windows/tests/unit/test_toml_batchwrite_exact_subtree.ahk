; tests/unit/test_toml_batchwrite_exact_subtree.ahk

; ==============================================================================
; MODULE: TOML exact-subtree replacement
; DESCRIPTION:
; Proves that dynamic records can replace one namespace exactly. A merge-only
; rewrite resurrects deleted records on the next parse, while a broad textual
; prefix can erase an unrelated sibling such as ``user_profiles_backup``.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBES_Seed(Path) {
	Body := "[llm.profiles.user_profiles]`n"
		. 'order = ["a", "b"]' . "`n`n"
		. "[llm.profiles.user_profiles.a]`n"
		. 'label = "A"' . "`n`n"
		. "[llm.profiles.user_profiles.b]`n"
		. 'label = "B"' . "`n`n"
		. "[llm.profiles.user_profiles_backup]`n"
		. "sentinel = true`n`n"
		. "[unrelated]`n"
		. "keep = 42`n"
	FileAppend(Body, Path, "UTF-8-RAW")
}

_TBES_ExactNamespaceDropsOnlyStaleRecords() {
	Prefix := "llm.profiles.user_profiles"
	Path := A_Temp . "\ergopti_toml_exact_" . A_ScriptHwnd . "_" . A_TickCount . ".toml"
	try {
		_TBES_Seed(Path)
		Updates := [
			{ Section: Prefix, Key: "order", Value: ["a"] },
			{ Section: Prefix . ".a", Key: "label", Value: "A2" }
		]
		AssertTrue(TOML_BatchWrite(Path, Updates, [Prefix]))
		Data := ParseTomlFile(Path)
		AssertTrue(Data.Has(Prefix))
		AssertTrue(Data.Has(Prefix . ".a"))
		AssertEqual("A2", Data[Prefix . ".a"]["label"])
		AssertFalse(Data.Has(Prefix . ".b"),
			"a removed dynamic record must not survive the exact rewrite")
		AssertTrue(Data.Has(Prefix . "_backup"),
			"a sibling sharing only the textual prefix must be preserved")
		AssertTrue(Data.Has("unrelated"))
		AssertEqual(42, Data["unrelated"]["keep"])

		AssertTrue(TOML_BatchWrite(Path, [], [Prefix]),
			"an empty replacement must still delete the exact dynamic namespace")
		Data := ParseTomlFile(Path)
		AssertFalse(Data.Has(Prefix))
		AssertFalse(Data.Has(Prefix . ".a"))
		AssertTrue(Data.Has(Prefix . "_backup"))
		AssertTrue(Data.Has("unrelated"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("TOML BatchWrite: exact-subtree replacement removes only stale records",
	_TBES_ExactNamespaceDropsOnlyStaleRecords)

_TBES_UnsafePrefixInputsFailBeforeIo() {
	Path := A_Temp . "\ergopti_toml_exact_invalid_" . A_ScriptHwnd . ".toml"
	AssertThrows(() => TOML_BatchWrite(Path, [], [""]),
		"an empty exact prefix must never mean every section")
	AssertThrows(() => TOML_BatchWrite(Path, [], Map()),
		"the exact-prefix contract must reject a non-Array collection")
	AssertFalse(FileExist(Path),
		"invalid exact-prefix input must fail before filesystem access")
}
Test("TOML BatchWrite: unsafe exact-subtree prefixes fail before I/O",
	_TBES_UnsafePrefixInputsFailBeforeIo)

_TBES_DeleteOperationIsTypedNotStringSentinel() {
	Path := A_Temp . "\ergopti_toml_typed_delete_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	try {
		Body := "[llm]`n" . 'model = "qwen"' . "`n"
		FileAppend(Body, Path, "UTF-8-RAW")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "llm",
			Key: "model", Value: "_DELETE_" }]))
		AssertEqual("_DELETE_", TOML_Read(Path, "llm", "model", ""),
			"ordinary values must never be interpreted as deletion commands")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "llm",
			Key: "model", Delete: true }]))
		AssertEqual("missing", TOML_Read(Path, "llm", "model", "missing"),
			"only the typed Delete operation may remove a key")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("TOML BatchWrite: deletion is typed and preserves sentinel-like values "
	. "(toml-typed-delete)",
	_TBES_DeleteOperationIsTypedNotStringSentinel)

_TBES_PartialStageRead(Path) {
	return "complete-but-truncated"
}

_TBES_StageVerificationRejectsPartialWrites() {
	AssertFalse(_TOML_StageMatches("memory://stage", "complete-image",
		_TBES_PartialStageRead),
		"a successful write status cannot authorize a truncated stage")
	AssertTrue(_TOML_StageMatches("memory://stage", "complete-but-truncated",
		_TBES_PartialStageRead),
		"an exact stage remains eligible for atomic publication")
}
Test("TOML BatchWrite: exact stage verification rejects partial writes "
	. "(toml-stage-readback)", _TBES_StageVerificationRejectsPartialWrites)

_TBES_NoOpVector(Vector) {
	Path := A_Temp . "\ergopti_toml_noop_" . A_ScriptHwnd . "_"
		. A_TickCount . "_" . Vector["id"] . ".toml"
	Source := Chr(0xFEFF) . Vector["input"]
	try {
		AssertTrue(FSWrite(Path, Source))
		FileSetTime("20000101000000", Path, "M")
		BeforeTime := FileGetTime(Path, "M")
		Update := { Section: Vector["section"], Key: Vector["key"] }
		if Vector.Has("delete")
			Update.Delete := true
		else
			Update.Value := Vector["kind"] == "boolean"
				? TOML_Bool(Vector["value"]) : Vector["value"]
		AssertTrue(TOML_BatchWrite(Path, [Update]))
		if Vector["writes"] == 0 {
			AssertEqual(Source, FSReadUtf8Exact(Path), "a no-op retains the complete byte image")
			AssertEqual(BeforeTime, FileGetTime(Path, "M"),
				"a no-op must retain the existing inode rather than replacing it")
		} else {
			AssertFalse(Source == FSReadUtf8Exact(Path), "changed values and types must publish")
			AssertFalse(BeforeTime == FileGetTime(Path, "M"), "a real change must replace the old image")
		}
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

_TBES_RegisterNoOpVectors() {
	global _SharedDir
	Fixture := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_noop\vectors.json", "UTF-8"))
	for Vector in Fixture["cases"]
		Test("toml-noop-parity " . Vector["id"], _TBES_NoOpVector.Bind(Vector))
}
_TBES_RegisterNoOpVectors()


_TBES_NamespaceAdmissionRetainsPhysicalSource() {
	for Vector in _TBUI_NamespaceLossVectors() {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			FileSetTime("20000101000000", Path, "M")
			BeforeTime := FileGetTime(Path, "M")
			AssertTrue(TOML_BatchWrite(Path,
				[{ Section: "settings", Key: Vector.Key, Value: Vector.Value }]))
			AssertTrue(FSUtf8ExactMatches(Path, Source), "ordinary no-op retains every byte: " . Vector.Id)
			AssertEqual(BeforeTime, FileGetTime(Path, "M"), "a source-retaining no-op performs no physical replacement")
			for Updates in [[{ Section: "settings", Key: Vector.Key, Value: 2 }],
				[{ Section: "settings", Key: Vector.Key, Delete: 1 }],
				[{ Section: "settings", Key: "other", Value: "unrelated" }]] {
				if Vector.HasOwnProp("Preservable") {
					AssertTrue(TOML_BatchWrite(Path, Updates), "a retained foreign array admits the exact sibling change")
					_TAOT_AssertFuture(FSReadUtf8Exact(Path))
					_TAOT_AssertRequested(FSReadUtf8Exact(Path), Updates[1])
				} else {
					AssertFalse(TOML_BatchWrite(Path, Updates), "refuse source identity loss: " . Vector.Id)
					AssertTrue(FSUtf8ExactMatches(Path, Source))
					AssertEqual(BeforeTime, FileGetTime(Path, "M"), "refusal precedes all publication")
				}
			}
			Stages := 0
			Loop Files, Path . ".*.tmp"
				Stages += 1
			AssertEqual(0, Stages, "refused changes own no staging file or cleanup debt")
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: native no-op inode and refusal publication preserve source namespaces (toml-writer-document)",
	_TBES_NamespaceAdmissionRetainsPhysicalSource)

_TBES_DuplicateSemanticSourceRefuses() {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . '[settings]`nowned=1`n[future]`na.b=1`na."b"=2`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertFalse(TOML_BatchWrite(Path, [{ Section: "settings", Key: "owned", Value: 2 }]))
		AssertTrue(FSUtf8ExactMatches(Path, Source), "an unrelated update cannot publish from an ambiguous source")
		AssertFalse(TOML_BatchWrite(Path, [{ Section: "settings", Key: "owned", Value: 1 }]),
			"equal flat cells are not proof of a valid semantic no-op")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally FSDelete(Path)
}
Test("toml writer admission: malformed semantic aliases refuse even a flat no-op (toml-writer-document)",
	_TBES_DuplicateSemanticSourceRefuses)


; These handwritten physical images distinguish declared tables from ancestry
; created only to reach an assignment or descendant header.
_TBES_ConfigDeletionAncestorVectors() {
	return [
		{ Id: 'implicit header parent', Source: '[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'explicit empty parent', Source: '[stale]`n[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '[stale]`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'multiple implicit ancestors', Source: '[stale.section.inner]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section.inner'],
			Expected: '[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'populated sibling', Source: '[stale.keep]`nflag=false # exact sibling`n[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '[stale.keep]`nflag=false # exact sibling`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'root dotted leaf', Source: 'stale.section.label="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [{ Section: 'stale.section', Key: 'label', Delete: 1 }], Prefixes: [],
			Expected: '[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'relative dotted leaf', Source: '[stale]`nsection.label="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [{ Section: 'stale.section', Key: 'label', Delete: 1 }], Prefixes: [],
			Expected: '[stale]`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'quoted literal twin', Source: '["stale.section"]`nkeep="literal" # exact quoted sibling`n[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '["stale.section"]`nkeep="literal" # exact quoted sibling`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'case twin', Source: '[Stale.section]`nkeep="case" # exact case sibling`n[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '[Stale.section]`nkeep="case" # exact case sibling`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'empty quoted segment', Source: '[stale.""]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.""'],
			Expected: '[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'inline explicit empty container', Source: 'stale = {section = {label = "old"}, empty = {}}`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [{ Section: 'stale.section', Key: 'label', Delete: 1 }], Prefixes: [],
			Expected: 'stale = {section = {}, empty = {}}`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'removed inline container parent', Source: 'stale = {section = {label = "old"}}`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: 'stale = {}`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'table array neighbor generations', Source: '[stale.section]`nlabel="old"`n[[future]]`nflag=false # first generation`n[[future]]`ntext="001" # second generation`n',
			Updates: [], Prefixes: ['stale.section'],
			Expected: '[[future]]`nflag=false # first generation`n[[future]]`ntext="001" # second generation`n' },
		{ Id: 'missing delete exact no-op', Source: '[stale]`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [{ Section: 'stale.missing', Key: 'label', Delete: 1 }], Prefixes: [],
			Expected: '[stale]`n[future]`ntext="001" # exact neighbor`nflag=false`n' },
		{ Id: 'replacement recreates implicit ancestry', Source: '[stale.section]`nlabel="old"`n[future]`ntext="001" # exact neighbor`nflag=false`n',
			Updates: [{ Section: 'stale.section', Key: 'label', Value: 'new' }], Prefixes: ['stale.section'],
			Expected: '[future]`ntext="001" # exact neighbor`nflag=false`n[stale.section]`nlabel = "new"`n' }
	]
}

_TBES_ConfigDeletionAncestorVector(Vector) {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
	Expected := Chr(0xFEFF) . Vector.Expected
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		FileSetTime("20000101000000", Path, "M")
		BeforeTime := FileGetTime(Path, "M")
		Cached := ParseTomlFile(Path)
		Candidate := TOML_BuildConfigUpdatedContent(Path, Vector.Updates, Vector.Prefixes)
		AssertEqual("ok", Candidate["status"], Vector.Id)
		AssertEqual(Expected, Candidate["content"], "the independent complete physical image matches")
		AssertEqual(Source, Candidate["source_content"])
		AssertEqual(1, Candidate["source_present"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "detached deletion never publishes")
		AssertTrue(Cached == ParseTomlFile(Path), "detached deletion retains the cache owner")
		AssertTrue(TOML_ConfigBatchWrite(Path, Vector.Updates, Vector.Prefixes) == 1,
			"the actual guarded configuration writer acknowledges deletion")
		AssertTrue(FSUtf8ExactMatches(Path, Expected), "publication retains the exact independent image")
		AssertTrue(TOML_SameValue(TOML_ParseDocument(Expected), TOML_ParseDocument(FSReadUtf8Exact(Path))))
		if Source == Expected
			AssertEqual(BeforeTime, FileGetTime(Path, "M"), "a missing deletion retains the physical inode")
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "the exact deletion leaves no owned staging file")
	} finally FSDelete(Path)
}
for _TBES_ConfigDeletionVector in _TBES_ConfigDeletionAncestorVectors()
	Test("toml config deletion ancestry: " . _TBES_ConfigDeletionVector.Id,
		_TBES_ConfigDeletionAncestorVector.Bind(_TBES_ConfigDeletionVector))
