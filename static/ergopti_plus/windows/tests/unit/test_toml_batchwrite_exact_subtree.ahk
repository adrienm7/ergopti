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
		Body := "[llm]`n" . 'trigger_shortcut = "Ctrl+L"' . "`n"
		FileAppend(Body, Path, "UTF-8-RAW")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "llm",
			Key: "trigger_shortcut", Value: "_DELETE_" }]))
		AssertEqual("_DELETE_", TOML_Read(Path, "llm", "trigger_shortcut", ""),
			"ordinary values must never be interpreted as deletion commands")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "llm",
			Key: "trigger_shortcut", Delete: true }]))
		AssertEqual("missing", TOML_Read(Path, "llm", "trigger_shortcut", "missing"),
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
