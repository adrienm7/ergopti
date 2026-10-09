; tests/unit/test_text_case_vectors.ahk

; ==============================================================================
; MODULE: Selection Case Actions Replay the Shared Vectors (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/text_case/vectors.json, the corpus the macOS and
; Linux suites replay too, through the transform each case action id is bound
; to in GestureCaseTransforms(), the map the gesture registry is built from.
;
; ROOT CAUSES ENCODED:
; 1. The uppercase toggle detected lowercase with [a-zà-ÿ], so a Cyrillic
;    selection ("привет мир") was lowercased instead of uppercased.
; 2. The title toggle used Format("{:T}"), which capitalizes after a digit
;    ("3e" -> "3E") but not after a hyphen ("jean-pierre" -> "Jean-pierre"),
;    and decided whether the text was already titled with an ASCII-and-French
;    pattern. Replayed on the old code, the corpus failed those three vectors.
; 3. No explicit uppercase / lowercase / title-case action existed.
; ==============================================================================

#Requires AutoHotkey v2.0

; @returns {Map} The decoded corpus.
_TCV_Corpus() {
	global _SharedDir
	AssertTrue(IsSet(_SharedDir), "the harness must expose _SharedDir")
	Path := _SharedDir . "\tests\corpus\text_case\vectors.json"
	AssertTrue(FileExist(Path) != "", "the text-case corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; @param {Map} Vector
; @returns {Boolean} Whether the vector applies to the Windows driver.
_TCV_AppliesHere(Vector) {
	if !Vector.Has("drivers")
		return true
	for _, Driver in Vector["drivers"]
		if (Driver = "ahk")
			return true
	return false
}

_TCV_ReplayCorpus() {
	static ActionByField := Map(
		"upper", "selection_uppercase",
		"lower", "selection_lowercase",
		"title", "selection_titlecase",
		"toggle_upper", "uppercase_selection",
		"toggle_title", "titlecase_selection",
	)
	Transforms := GestureCaseTransforms()
	Corpus := _TCV_Corpus()
	Applied := 0
	Checked := 0
	for _, Vector in Corpus["vectors"] {
		if !_TCV_AppliesHere(Vector)
			continue
		Applied += 1
		for Field, ActionId in ActionByField {
			AssertTrue(Vector.Has(Field), Vector["id"] . " must state " . Field)
			AssertTrue(Transforms.Has(ActionId), "no case transform is bound to " . ActionId)
			AssertEqual(Vector[Field], Transforms[ActionId].Call(Vector["input"]),
				Vector["id"] . ": " . ActionId)
			Checked += 1
		}
	}
	AssertTrue(Applied >= 10, "expected at least 10 Windows vectors, found " . Applied)
	AssertEqual(Applied * ActionByField.Count, Checked, "every applicable vector field must be replayed")
}
Test("text case: the case actions replay the shared corpus", _TCV_ReplayCorpus)

_TCV_EveryTransformIsAGestureAction() {
	global GESTURE_ACTIONS
	Count := 0
	for ActionId in GestureCaseTransforms() {
		AssertTrue(GESTURE_ACTIONS.Has(ActionId), ActionId . " must be registered as a gesture action")
		Count += 1
	}
	AssertEqual(5, Count, "the five case actions must all have a transform")
}
Test("text case: every case transform is a registered action", _TCV_EveryTransformIsAGestureAction)
