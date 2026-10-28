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
; number and array identities. Every case agrees, or is pinned in _LIR_PENDING
; with the reason, so a fix forces the inventory to shrink.
; ==============================================================================

#Requires AutoHotkey v2.0

; Cases where the Windows record path disagrees with the shared Lua law. Both
; reasons await a maintainer decision (which rule the drivers should share).
global _LIR_SIZE := "Windows admits an installed row only with a size, because LayoutRegistry_Verify checks"
	. " the local copy's byte count; the shared rule needs id, sha256 and version, so a size-less row"
	. " stays outdated here and cannot be updated in place or uninstalled"
global _LIR_OWNED := "a Windows update owns and records only LAYOUT_CATALOGUE_RECORD_FIELDS; the shared law"
	. " also owns languages, variants, platforms, source_url, source_sha256, licence_file and xkb, so their"
	. " stale values survive an update here"
global _LIR_PENDING := Map(
	"installed_record_preservation:remove-preserves-complete-unowned-model", _LIR_SIZE,
	"installed_record_preservation:chained-builders-retain-source-only-values", _LIR_SIZE,
	"installed_record_preservation:verified-replacement-does-not-resurrect-obsolete-row", _LIR_SIZE,
	"installed_record_preservation:source-outdated-member-is-not-runtime-classification", _LIR_SIZE,
	"installed_record_updates:update-keeps-omitted-future-models", _LIR_SIZE,
	"installed_record_updates:supplied-values-win-with-detached-future-neighbors", _LIR_SIZE . "; " . _LIR_OWNED,
	"installed_record_updates:owned-extension-to-base-removes-only-owned-container", _LIR_SIZE,
	"installed_record_updates:known-optional-index-fields-do-not-resurrect", _LIR_OWNED,
	"installed_record_updates:chained-update-remove-preserves-neighbors-not-owned-id", _LIR_SIZE)
; Each extension case's removal targets the size-less entry its install wrote.
for _LIR_Id in ["null", "false", "number", "string", "array", "object", "bad-checksum", "empty-name",
		"invalid-pack-id", "null-files", "object-files", "empty-files", "scalar-file", "array-file", "unsafe-path",
		"negative-size", "fractional-size", "bad-file-checksum", "duplicate-file", "missing-manifest"]
	_LIR_PENDING["installed_record_extensions:" . _LIR_Id . " remove"] := _LIR_SIZE

; Cases that model in-memory builders. Windows rereads the file for every
; operation, so there is no builder record to mutate between them.
global _LIR_NOT_APPLICABLE := Map(
	"installed_record_preservation:builder-edits-do-not-rewrite-source-only-provenance",
	"mutate_builder edits a Lua builder record between two operations")

_LIR_Corpus(Name) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\" . Name . ".json", "UTF-8"))
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

; Runs one case and holds a pending case to its recorded disagreement.
_LIR_Check(Corpus, Id, Source, Operations, Expected) {
	global _LIR_PENDING
	Key := Corpus . ":" . Id
	Difference := _LIR_ModelDifference(Expected, _LIR_Replay(Source, Operations), Id)
	if _LIR_PENDING.Has(Key)
		AssertTrue(Difference != "", Key . " now agrees: remove it from _LIR_PENDING")
	else
		AssertEqual("", Difference, Key)
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

Test("installed-record corpora: every pending case names a corpus case (installed-record-corpora)", () => (
	_LIR_AssertPendingNamesCases()
))

_LIR_AssertPendingNamesCases() {
	global _LIR_PENDING, _LIR_NOT_APPLICABLE
	Known := Map()
	for Name in ["installed_record_preservation", "installed_record_updates"]
		for Vector in _LIR_Corpus(Name)["cases"]
			Known[Name . ":" . Vector["id"]] := true
	for Vector in _LIR_Corpus("installed_record_extensions")["cases"] {
		Known["installed_record_extensions:" . Vector["id"]] := true
		Known["installed_record_extensions:" . Vector["id"] . " remove"] := true
	}
	for Key, Reason in _LIR_PENDING {
		AssertTrue(Known.Has(Key), "stale pending entry: " . Key)
		AssertTrue(Reason is String && Reason != "", "a pending entry states its reason: " . Key)
	}
	for Key, Reason in _LIR_NOT_APPLICABLE {
		AssertTrue(Known.Has(Key), "stale exclusion: " . Key)
		AssertFalse(_LIR_PENDING.Has(Key), "a case is either excluded or pending: " . Key)
	}
}
