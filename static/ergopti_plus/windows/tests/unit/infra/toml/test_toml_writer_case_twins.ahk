; tests/unit/infra/toml/test_toml_writer_case_twins.ahk

; ==============================================================================
; MODULE: TOML Writer Case Twins And Unwritable Files
; DESCRIPTION:
; The shared writer refuses a row whose destination a case twin makes ambiguous.
; A real file must not become unwritable for that: a save carries every setting,
; so only a row that changes the twin's own value may be refused.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTWIN_Build(Source, Rows) => TOML_BuildConfigDocumentCandidate(Source, Rows, [])

_TTWIN_UntouchedTwinStaysWritable() {
	Source := "[Script]`nlevel = 1`n[script]`nlevel = 2`n[other]`nx = 1`n"
	Same := _TTWIN_Build(Source, [{ Section: "script", Key: "level", Value: 2 }])
	AssertTrue(Same["preserve_source"], "a row that changes nothing passes the twin untouched")
	Gone := _TTWIN_Build(Source, [{ Section: "script", Key: "absent", Delete: 1 }])
	AssertTrue(Gone["preserve_source"], "deleting what is absent passes the twin untouched")
	Other := _TTWIN_Build(Source, [{ Section: "other", Key: "x", Value: 3 }])
	AssertEqual("[Script]`nlevel = 1`n[script]`nlevel = 2`n[other]`nx = 3`n", Other["content"],
		"a row elsewhere still writes the file and keeps both twins")
	AssertThrows(_TTWIN_Build.Bind(Source, [{ Section: "script", Key: "level", Value: 3 }]),
		"changing the twin's own value is refused")
}
Test("toml writer twins: a twin refuses only the row that changes it (toml-writer-case-twins)",
	_TTWIN_UntouchedTwinStaysWritable)

_TTWIN_HeaderSpellingIsFollowed() {
	Result := _TTWIN_Build("[Script]`nlevel = 1`n", [{ Section: "script", Key: "level", Value: 2 }])
	AssertEqual("[Script]`nlevel = 2`n", Result["content"],
		"a single header in another spelling is the row's destination, so no twin is created")
	Deleted := _TTWIN_Build("[Script]`nlevel = 1`n", [{ Section: "script", Key: "level", Delete: 1 }])
	AssertTrue(Deleted["preserve_source"], "a deletion never reaches a member in another spelling")
}
Test("toml writer twins: one header in another spelling takes the write (toml-writer-case-twins)",
	_TTWIN_HeaderSpellingIsFollowed)

_TTWIN_ByteOrderMarkFollowsTheSource() {
	Row := [{ Section: "a", Key: "x", Value: 2 }]
	AssertEqual("[a]`nx = 2`n", _TTWIN_Build("[a]`nx = 1`n", Row)["content"], "the writer adds no byte order mark")
	AssertEqual(Chr(0xFEFF) . "[a]`nx = 2`n", _TTWIN_Build(Chr(0xFEFF) . "[a]`nx = 1`n", Row)["content"],
		"the writer keeps the source's byte order mark")
	AssertEqual("[a]`nx = 2`n", _TTWIN_Build("", Row)["content"], "a new file holds none")
}
Test("toml writer: the byte order mark follows the source (toml-writer-bom)", _TTWIN_ByteOrderMarkFollowsTheSource)

_TTWIN_ByteOrderMarkLessFileRoundTrips() {
	Path := A_Temp . "\ergopti_toml_nobom_" . A_TickCount . ".toml"
	Text := _CMJFixtureCurrentSource('[a]`nlabel = "é😀"`n')
	try {
		AssertFalse(SubStr(Text, 1, 1) == Chr(0xFEFF), "the fixture starts without a byte order mark")
		AssertTrue(FSWriteCreateDurable(Path, Text) == 1)
		AssertEqual("é😀", ParseTomlFile(Path)["a"]["label"], "the native reader decodes a BOM-less file as UTF-8")
		AssertEqual("é😀", TOML_ParseDocument(FSReadUtf8Exact(Path))["a"]["label"], "the semantic reader too")
		AssertEqual("current", ConfigMigrateBoot(Path)["status"], "the schema reader admits it")
		AssertTrue(TOML_ConfigBatchWrite(Path, [{ Section: "a", Key: "x", Value: 1 }]))
		Written := FSReadUtf8Exact(Path)
		AssertFalse(SubStr(Written, 1, 1) == Chr(0xFEFF), "the published bytes hold no byte order mark")
		AssertContains(Written, "é😀")
	} finally {
		_TOML_InvalidateParseCache(Path)
		FSDelete(Path)
	}
}
Test("toml writer: a file without a byte order mark reads and publishes as UTF-8 (toml-writer-bom)",
	_TTWIN_ByteOrderMarkLessFileRoundTrips)

; The profile the compiled-upgrade check starts from: what an older release left.
_TTWIN_OlderReleaseProfileStaysWritable() {
	Source := FileRead(A_ScriptDir . "\..\..\..\..\tools\test\fixtures\windows-upgrade-profile.toml", "UTF-8")
	Document := TOML_ParseDocument(Source)
	AssertTrue(Document.Count > 0, "the older profile parses")
	Same := _TTWIN_Build(Source, [])
	AssertTrue(Same["preserve_source"], "an empty batch leaves the older profile byte for byte")
	Changed := _TTWIN_Build(Source, [{ Section: "script", Key: "ergopti_writer_probe", Value: 1 }])
	AssertEqual(1, TOML_ParseDocument(Changed["content"])["script"]["ergopti_writer_probe"],
		"the older profile takes a new setting")
}
Test("toml writer: the older-release profile stays writable (toml-writer-older-release)",
	_TTWIN_OlderReleaseProfileStaysWritable)
