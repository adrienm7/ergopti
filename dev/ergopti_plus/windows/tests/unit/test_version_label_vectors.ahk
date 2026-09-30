; static/ergopti_plus/windows/tests/unit/test_version_label_vectors.ahk

; ==============================================================================
; MODULE: About Version Row Vectors
; DESCRIPTION:
; Replays the shared _shared/modules/updater/version_label_vectors.json through
; the AHK port of the version row formatter (Updater_VersionRowLabel). The
; macOS and Linux suites replay the same file through the shared Lua module, so
; the three drivers cannot word the version row differently: the same locale
; keys, the same placeholders, an unknown commit spelled by its own key, and
; values substituted once and literally.
; ==============================================================================

_VLV_Vectors() {
	Path := A_ScriptDir . "\..\..\_shared\modules\updater\version_label_vectors.json"
	AssertTrue(FileExist(Path) != "", "version label vectors must exist at: " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; The vectors' fake templates, so the replay pins the formatter, not a wording.
_VLV_Translate(Templates, Key) {
	AssertTrue(Templates.Has(Key), "no vector template for " . Key)
	return Templates[Key]
}

_VLV_KeysAreTheContracts() {
	global UPDATER_VERSION_ROW_KEYS, UPDATER_UNKNOWN_COMMIT_KEY
	Keys := _VLV_Vectors()["keys"]
	AssertEqual(4, Keys.Count, "three kinds and the unknown commit")
	AssertEqual(3, UPDATER_VERSION_ROW_KEYS.Count, "one key per build kind")
	for Kind, Key in UPDATER_VERSION_ROW_KEYS
		AssertEqual(Keys[Kind], Key, "the key of the " . Kind . " row")
	AssertEqual(Keys["unknown_commit"], UPDATER_UNKNOWN_COMMIT_KEY)
}
Test("version label: the AHK port uses the contract's locale keys", _VLV_KeysAreTheContracts)

_VLV_FormatsEveryVector() {
	Data := _VLV_Vectors()
	Translate := _VLV_Translate.Bind(Data["templates"])
	Vectors := Data["vectors"]
	AssertTrue(Vectors.Length >= 8, "version label vectors: >=8 expected, got " . Vectors.Length)
	for _, V in Vectors
		AssertEqual(V["expected"], Updater_VersionRowLabel(V["kind"], V["version"], V["commit"], Translate),
			"vector " . V["id"])
}
Test("version label: the AHK port formats every shared vector", _VLV_FormatsEveryVector)

_VLV_RefusesInvalidRows() {
	Translate := _VLV_Translate.Bind(_VLV_Vectors()["templates"])
	AssertThrows(() => Updater_VersionRowLabel("nightly", "1.0.0", "abc", Translate),
		"an unknown kind is a programming error")
	AssertThrows(() => Updater_VersionRowLabel("release", "", "abc", Translate),
		"a release row without its version is a programming error")
}
Test("version label: an unknown kind or a versionless release is refused", _VLV_RefusesInvalidRows)
