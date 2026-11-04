; static/ergopti_plus/windows/tests/unit/modules/keymap/test_layout_installed_record_corpora.ahk

; ==============================================================================
; MODULE: Installed Record Corpus Consumer (AHK)
; DESCRIPTION:
; Replays the preservation, update and extension installed-record corpora of
; _shared/tests/corpus/layouts/ through the Windows read and write path the
; layout catalogue uses: each operation reads the record, installs an entry the
; way LayoutCatalogue_Install records it or deletes one the way
; LayoutCatalogue_Uninstall does, and writes the record back. The written JSON
; is compared with the corpus model member by member, keeping null, Boolean,
; number and array identities. Every case agrees with the shared Lua law.
; ==============================================================================

#Requires AutoHotkey v2.0

; Cases that model in-memory builders. Windows rereads the file for every
; operation, so there is no builder record to mutate between them.
global _LIR_NOT_APPLICABLE := Map(
	"installed_record_preservation:builder-edits-do-not-rewrite-source-only-provenance",
	"mutate_builder edits a Lua builder record between two operations")

_LIR_Corpus(Name) {
	global _SharedDir
	; An entry's Boolean stays typed, so the record writes it as the corpus spells it.
	return _TCV_Revive(_TCV_ParseTyped(FileRead(_SharedDir . "\tests\corpus\layouts\" . Name . ".json", "UTF-8")))
}

_LIR_TempDir() {
	Dir := A_Temp . "\ergopti_installed_corpora_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

_LIR_Write(Path, Text) {
	F := FileOpen(Path, "w", "UTF-8-RAW")
	F.Write(Text)
	F.Close()
}

; Returns "" when both JSON texts hold the same model, else the first difference.
_LIR_ModelDifference(Expected, Actual, Label) {
	Expected := Trim(Expected, " `t`r`n"), Actual := Trim(Actual, " `t`r`n")
	Kind := SubStr(Expected, 1, 1)
	if (Kind != SubStr(Actual, 1, 1))
		return Label . ": " . Expected . " became " . Actual
	if (Kind == "{") {
		Left := JsonObjectMemberSpans(Expected), Right := JsonObjectMemberSpans(Actual)
		for Key, Span in Left {
			if !Right.Has(Key)
				return Label . "." . Key . ": missing"
			Difference := _LIR_ModelDifference(Span["text"], Right[Key]["text"], Label . "." . Key)
			if (Difference != "")
				return Difference
		}
		for Key in Right
			if !Left.Has(Key)
				return Label . "." . Key . ": extra member"
		return ""
	}
	if (Kind == "[") {
		Left := JsonArrayElementSpans(Expected), Right := JsonArrayElementSpans(Actual)
		if (Left.Length != Right.Length)
			return Label . ": " . Left.Length . " elements became " . Right.Length
		for Index, Span in Left {
			Difference := _LIR_ModelDifference(Span["text"], Right[Index]["text"], Label . "[" . Index . "]")
			if (Difference != "")
				return Difference
		}
		return ""
	}
	if (Kind == '"')
		return JsonParse(Expected) == JsonParse(Actual) ? "" : Label . ": " . Expected . " became " . Actual
	return (Expected == Actual) ? "" : Label . ": " . Expected . " became " . Actual
}

; Applies the operations through the production read and write path.
_LIR_Replay(Source, Operations) {
	Dir := _LIR_TempDir()
	Path := Dir . LayoutRegistry_Settings()["installed_file"]
	try {
		_LIR_Write(Path, Source)
		for Operation in Operations {
			Installed := LayoutCatalogue_ReadInstalled(Dir)
			if (Operation["kind"] == "install") {
				Entry := Operation["entry"]
				Installed[Entry["id"]] := _LayoutCatalogueRecordEntry(Entry)
			} else {
				; LayoutCatalogue_Uninstall refuses an id outside the runtime map.
				if !Installed.Has(Operation["id"])
					continue
				Installed.Delete(Operation["id"])
			}
			LayoutCatalogue_WriteInstalled(Dir, Installed)
		}
		return FileRead(Path, "UTF-8-RAW")
	} finally
		DirDelete(Dir, true)
}

; Runs one case.
_LIR_Check(Corpus, Id, Source, Operations, Expected) {
	AssertEqual("", _LIR_ModelDifference(Expected, _LIR_Replay(Source, Operations), Id), Corpus . ":" . Id)
}

_LIR_RegisterRecordCases(Name) {
	global _LIR_NOT_APPLICABLE
	for Vector in _LIR_Corpus(Name)["cases"]
		if !_LIR_NOT_APPLICABLE.Has(Name . ":" . Vector["id"])
			Test("[corpus:installed-record:" . Name . ":" . Vector["id"] . "] (installed-record-corpora)",
				_LIR_Check.Bind(Name, Vector["id"], Vector["source"], Vector["operations"], Vector["expected"]))
}

_LIR_RegisterExtensionCases() {
	Install := [Map("kind", "install", "entry", Map("id", "sample", "sha256", "verified", "version", "2"))]
	for Vector in _LIR_Corpus("installed_record_extensions")["cases"] {
		Test("[corpus:installed-record:installed_record_extensions:" . Vector["id"] . "] install (installed-record-corpora)",
			_LIR_Check.Bind("installed_record_extensions", Vector["id"], Vector["source"], Install,
				Vector["expected_after_install"]))
		Test("[corpus:installed-record:installed_record_extensions:" . Vector["id"] . "] remove (installed-record-corpora)",
			_LIR_Check.Bind("installed_record_extensions", Vector["id"] . " remove", Vector["expected_after_install"],
				[Map("kind", "remove", "id", "sample")], Vector["source"]))
	}
}

_LIR_RegisterRecordCases("installed_record_preservation")
_LIR_RegisterRecordCases("installed_record_updates")
_LIR_RegisterExtensionCases()

Test("installed-record corpora: every exclusion names a corpus case (installed-record-corpora)", () => (
	_LIR_AssertExclusionsNameCases()
))

_LIR_AssertExclusionsNameCases() {
	global _LIR_NOT_APPLICABLE
	Known := Map()
	for Name in ["installed_record_preservation", "installed_record_updates"]
		for Vector in _LIR_Corpus(Name)["cases"]
			Known[Name . ":" . Vector["id"]] := true
	for Key, Reason in _LIR_NOT_APPLICABLE
		AssertTrue(Known.Has(Key), "stale exclusion: " . Key)
}

; A size-less row is a real installed layout: its copy is verified by checksum.
_LIR_SizelessRowIsInstalled() {
	Dir := _LIR_TempDir()
	Text := "<keyboard/>"
	try {
		_LIR_Write(Dir . LayoutRegistry_Settings()["installed_file"], '{"schema_version":1,"layouts":{"sample":{"id":"sample","sha256":"'
			. CryptoSha256(Text) . '","version":"1"}}}')
		_LIR_Write(Dir . "sample.keylayout", Text)
		AssertEqual(Text, LayoutRegistry_ReadLocal("sample", Dir)["Text"], "the checksum alone vouches for the copy")
		_LIR_Write(Dir . "sample.keylayout", "<tampered/>")
		AssertThrows(LayoutRegistry_ReadLocal.Bind("sample", Dir), "a copy the checksum refuses stays refused")
	} finally
		DirDelete(Dir, true)
}
Test("installed-record corpora: a row without a size is verified by its checksum (installed-record-sizeless)",
	_LIR_SizelessRowIsInstalled)
