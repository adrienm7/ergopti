; tests/meta/corpus/test_corpus_tap_hold_labels.ahk

; ==============================================================================
; MODULE: Key Combination Label Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/tap_hold/combination_labels.json through the real
; menu rows (KeyCombinationRows): a pair Windows offers sits in the list of its
; first key's hand, under that key's label, named by both keys' labels; a pair of
; another driver's keys is not offered.
; ==============================================================================

#Requires AutoHotkey v2.0



_CTHL_Vectors() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\tap_hold\combination_labels.json", "UTF-8"))
	return Corpus["vectors"]
}

_CTHL_OnWindows(Vector) {
	for Platform in Vector["platforms"]
		if Platform == "ahk"
			return true
	return false
}

; The rows of one hand under one first key's label; 0 when the list has no such key.
_CTHL_Items(Hand, FirstLabel) {
	for Row in KeyCombinationRows(Hand)
		if Row["label"] == FirstLabel
			return Row["items"]
	return 0
}

_CTHL_HasPair(Items, PairLabel) {
	for Item in Items
		if InStr(Item["label"], LabelValue(PairLabel, ""), true) == 1
			return true
	return false
}

_CTHL_Offered(Vector) {
	First := t(Vector["first_label"])
	Items := _CTHL_Items(Vector["hand"], First)
	Assert(Items is Array, Vector["first"] . " opens a list on its hand")
	Assert(_CTHL_HasPair(Items, First . " + " . t(Vector["second_label"])),
		Vector["first"] . " + " . Vector["second"] . " is named by both keys")
}

_CTHL_NotOffered(Vector) {
	First := t(Vector["first_label"])
	Second := t(Vector["second_label"])
	for Hand in ["left", "right"] {
		Items := _CTHL_Items(Hand, First)
		Assert(!(Items is Array) || !_CTHL_HasPair(Items, First . " + " . Second),
			Vector["first"] . " + " . Vector["second"] . " belongs to another driver")
	}
}

_CTHL_Register() {
	Replayed := 0
	for Vector in _CTHL_Vectors() {
		Replayed += 1
		Name := Vector["first"] . " + " . Vector["second"]
		if _CTHL_OnWindows(Vector)
			Test("corpus key combination labels: offers " . Name, _CTHL_Offered.Bind(Vector))
		else
			Test("corpus key combination labels: does not offer " . Name, _CTHL_NotOffered.Bind(Vector))
	}
	if Replayed != 7
		throw Error("The key combination label corpus changed: " . Replayed . " rows.")
}
_CTHL_Register()
