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
