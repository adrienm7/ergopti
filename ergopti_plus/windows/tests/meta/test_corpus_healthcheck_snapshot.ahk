; tests/meta/test_corpus_healthcheck_snapshot.ahk

; ==============================================================================
; MODULE: Healthcheck Snapshot Corpus Consumer (Windows / AHK)
; DESCRIPTION:
; Loads the cross-driver snapshot corpus
; (_shared/tests/corpus/healthcheck/snapshot_vectors.json) and replays its
; check_fields vectors through HealthCheck_CheckFields, the AHK copy of
; healthcheck.snapshot.check_fields: which fields a snapshot carries that the
; schema does not declare for its driver, and which declared synchronous fields
; are absent. The macOS and Linux suites replay the same vectors through the
; Lua function, and the page's model replays the format_uptime ones.
; ==============================================================================

#Requires AutoHotkey v2.0

; The corpus, parsed.
; @returns {Map}
_HCSC_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\healthcheck\snapshot_vectors.json", "UTF-8"))
}

; A list as one line, for a readable assertion.
_HCSC_Join(List) {
	Out := ""
	for Index, Item in List
		Out .= (Index > 1 ? ", " : "") . Item
	return Out
}

_HCSC_Integrity() {
	Data := _HCSC_Corpus()
	AssertTrue(Data.Has("vectors") && Data["vectors"].Length > 0, "the corpus must have vectors")
	AssertTrue(Data.Has("check_fields_schema"), "the corpus must carry the schema its check_fields vectors use")
	for V in Data["vectors"] {
		AssertTrue(V.Has("id") && V["id"] != "", "vector missing id")
		AssertTrue(V.Has("category"), V["id"] . ": vector missing category")
	}
}
Test("corpus:hc-snap: the corpus is readable and every vector is named and categorised", _HCSC_Integrity)

_HCSC_CheckFields() {
	Data := _HCSC_Corpus()
	Replayed := 0
	for V in Data["vectors"] {
		if (V["category"] != "check_fields")
			continue
		Result := HealthCheck_CheckFields(V["snapshot"], Data["check_fields_schema"])
		AssertEqual(_HCSC_Join(V["expected_undeclared"]), _HCSC_Join(Result["undeclared"]), V["id"] . ": undeclared")
		AssertEqual(_HCSC_Join(V["expected_missing"]), _HCSC_Join(Result["missing"]), V["id"] . ": missing")
		Replayed += 1
	}
	AssertTrue(Replayed > 0, "the corpus must carry check_fields vectors")
}
Test("corpus:hc-snap: check_fields vectors match golden values", _HCSC_CheckFields)
