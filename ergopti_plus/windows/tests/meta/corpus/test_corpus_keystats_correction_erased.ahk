; tests/meta/corpus/test_corpus_keystats_correction_erased.ahk

; ==============================================================================
; MODULE: Keystats Erased and Synthetic N-gram Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/keystats/correction_erased_vectors.json through
; the production KLW_WalkTypingEntry: which n-grams a Backspace flags as erased,
; that a Backspace never flags another Backspace, and that a synthetic
; correction carries its source (esrc) instead of counting as the user's
; mistake. Same exact comparison as _shared/lua/test/keystats_correction_erased_contract.lua.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Corpus and replay =======
; ====================================
; ====================================

; The vector count the contract was written for, as its Lua replays pin it.
global _KCE_VECTOR_COUNT := 6

_KCE_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\keystats\correction_erased_vectors.json", "UTF-8"))
	return Corpus
}

_KCE_Families() => ["ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
	"ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams"]

; One typing entry per flush, for one application, with a carried context.
_KCE_Replay(Vector) {
	Corpus := _KCE_Corpus()
	KLW_ResetBatch()
	KLW.ctx := Map()
	for Index, Flush in Vector["flushes"] {
		Events := []
		for Event in Flush
			Events.Push([Event["char"], Event["delay"], Event.Has("meta") ? Event["meta"] : Map()])
		KLW_WalkTypingEntry(Map("app", Corpus["app"], "timestamp", Corpus["timestamps"][Index], "events", Events))
	}
}

; Sorted "source=count" pairs, so two source maps compare as one text.
_KCE_Sources(Row) {
	Text := ""
	if !Row.Has("esrc")
		return Text
	Names := ""
	for Source, Count in Row["esrc"]
		Names .= (Names == "" ? "" : "`n") . Source . "=" . Count
	return Sort(Names)
}





; ============================
; ============================
; ======= 2/ The tests =======
; ============================
; ============================

_KCE_ReplayVector(Vector) {
	Corpus := _KCE_Corpus()
	Prefix := Corpus["date"] . Chr(1) . Corpus["app"] . Chr(1)
	_KCE_Replay(Vector)
	Rows := 0
	for Family in _KCE_Families() {
		Expected := Vector["expected"].Has(Family) ? Vector["expected"][Family] : Map()
		Seen := Map()
		Table := KLW.batch["ngram"].Has(Family) ? KLW.batch["ngram"][Family] : Map()
		for Key, Row in Table {
			if (SubStr(Key, 1, StrLen(Prefix)) != Prefix || (Row["c"] <= 0 && Row["e"] <= 0))
				continue
			Token := SubStr(Key, StrLen(Prefix) + 1)
			Label := Vector["id"] . ": " . Family . " " . Token
			AssertTrue(Expected.Has(Token), Label . " is counted and unexpected")
			Want := Expected[Token]
			AssertEqual(Want["c"], Row["c"], Label . " c")
			AssertEqual(Want["e"], Row["e"], Label . " e")
			AssertEqual(_KCE_Sources(Want), _KCE_Sources(Row), Label . " esrc")
			Seen[Token] := true
			Rows += 1
		}
		for Token in Expected
			AssertTrue(Seen.Has(Token), Vector["id"] . ": " . Family . " misses " . Token)
	}
	AssertTrue(Rows > 0, Vector["id"] . ": the walker must count n-grams")
}

_KCE_CountIsPinned() {
	global _KCE_VECTOR_COUNT
	AssertEqual(_KCE_VECTOR_COUNT, _KCE_Corpus()["vectors"].Length, "correction_erased_vectors.json changed size")
}
Test("keystats correction erased corpus: holds the pinned number of vectors", _KCE_CountIsPinned)

_KCE_RegisterVectors() {
	for Vector in _KCE_Corpus()["vectors"]
		Test("keystats correction erased corpus: " . Vector["id"], _KCE_ReplayVector.Bind(Vector))
}
_KCE_RegisterVectors()
