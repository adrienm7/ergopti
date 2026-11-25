; tests/unit/modules/shortcuts/test_text_target.ahk

; ==============================================================================
; MODULE: Text Targets (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/keep_awake/text_target_vectors.json, which the
; macOS and Linux suites replay through _shared/shortcuts/engine/text_target.lua,
; through modules/shortcuts/text_target.ahk.
;
; ROOT CAUSE ENCODED:
; A caption is compared after folding case, accents and punctuation. A port
; that lowered with StrLower, counted UTF-16 units or chose another run of
; words would click another button, or none, than macOS and Linux for the same
; recognised words.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTT_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\keep_awake\text_target_vectors.json"
	AssertTrue(FileExist(Path) != "", "the corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_TTT_Normalize() {
	Checked := 0
	for Vector in _TTT_Corpus()["normalize"] {
		AssertEqual(Vector["expect"], TextTargetNormalize(Vector["text"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 8, "expected the normalisation vectors, found " . Checked)
	AssertEqual(1, TextTargetDistance("a" . Chr(0x1F600), "a" . Chr(0x1F601)), "a surrogate pair is one character")
}
Test("text target: the port normalises every corpus text (text-target-vectors)", _TTT_Normalize)

_TTT_FindVector(Vector) {
	Hit := TextTargetFind(Vector["words"], Vector["target"])
	Expect := Vector["expect"]
	if Expect == JSON_NULL {
		AssertFalse(IsObject(Hit), Vector["id"] . " must not match")
		return
	}
	AssertTrue(IsObject(Hit), Vector["id"] . " must match")
	for Key in ["x", "y", "width", "height", "distance", "variant"]
		AssertEqual(Expect[Key], Hit[Key], Vector["id"] . " " . Key)
}

_TTT_Find() {
	Checked := 0
	for Vector in _TTT_Corpus()["find"] {
		_TTT_FindVector(Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 9, "expected the find vectors, found " . Checked)
}
Test("text target: the port finds every corpus caption (text-target-vectors)", _TTT_Find)
