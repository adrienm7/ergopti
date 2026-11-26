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

; An absent slot of a vector's labels is an empty slot.
_CKPR_Text(Labels, Slot) {
	return Labels.Has(Slot) ? Labels[Slot] : ""
}

_CKPR_Join(Items) {
	Joined := ""
	for _, Item in Items
		Joined .= (Joined == "" ? "" : ",") . Item
	return Joined
}

_CKPR_Replay(Vector) {
	Corpus := _CKPR_Corpus()
	AssertEqual("tap,hold,chord", _CKPR_Join(Corpus["slot_order"]), "the slots KeyCombinationPairSummary joins")
	AssertEqual(" / ", Corpus["separator"], "the separator KeyCombinationPairSummary joins with")
	Expected := Vector["expected"] == Corpus["empty"] ? t(Corpus["empty"]) : Vector["expected"]
	Labels := Vector["labels"]
	AssertEqual(Expected, KeyCombinationPairSummary(_CKPR_Text(Labels, "tap"), _CKPR_Text(Labels, "hold"),
		_CKPR_Text(Labels, "chord")), Vector["name"])
}

_CKPR_Register() {
	Replayed := 0
	for Vector in _CKPR_Corpus()["summaries"] {
		Replayed += 1
		Test("(kcd-8) corpus key combination pair rows: " . Vector["name"], _CKPR_Replay.Bind(Vector))
	}
	if Replayed != 8
		throw Error("The key combination pair row corpus changed: " . Replayed . " rows.")
}
_CKPR_Register()
