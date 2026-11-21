; tests/meta/corpus/test_corpus_key_combination_pair_rows.ahk

; ==============================================================================
; MODULE: Key Combination Pair Row Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/tap_hold/key_combination_pair_rows.json through
; KeyCombinationPairSummary, the summary every OS draws on a pair row
; (maintainer decision KCD-8), and checks the empty word it names.
; ==============================================================================

#Requires AutoHotkey v2.0



_CKPR_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\tap_hold\key_combination_pair_rows.json", "UTF-8"))
	return Corpus
}

; A null member is an empty slot; a null summary is the empty word.
_CKPR_Text(Vector, Name) {
	return Vector.Has(Name) && Vector[Name] is String ? Vector[Name] : ""
}

_CKPR_Replay(Vector) {
	Expected := _CKPR_Text(Vector, "summary")
	if Expected == ""
		Expected := t(_CKPR_Corpus()["empty_action_key"])
	Assert(KeyCombinationPairSummary(_CKPR_Text(Vector, "tap"), _CKPR_Text(Vector, "hold")) == Expected,
		"the pair summary follows the shared corpus")
}

_CKPR_Register() {
	Replayed := 0
	for Vector in _CKPR_Corpus()["summaries"] {
		Replayed += 1
		Test("(kcd-8) corpus key combination pair rows: summary " . Replayed, _CKPR_Replay.Bind(Vector))
	}
	if Replayed != 4
		throw Error("The key combination pair row corpus changed: " . Replayed . " rows.")
}
_CKPR_Register()
