; tests/unit/modules/keymap/test_keylayout_canonical_form.ahk

; ==============================================================================
; MODULE: Keylayout Canonical Form Replay
; DESCRIPTION:
; Replays _shared/tests/corpus/keylayout on the AutoHotkey reader: the hand-checked
; edge fixtures, the real composer layout and the inputs of the conversion vectors.
; The macOS, Linux and Python readers replay the same files, so all of them read
; a layout into one form (PAR-76 R23). Windows used to have its own grammar: a
; single-quoted attribute or an unreadable <key> tag silently lost keys there.
; ==============================================================================

#Requires AutoHotkey v2.0

; Structural equality over plain data, reporting the first path that differs.
_KCF_Difference(Expected, Actual, Path := "") {
	if Expected is Map {
		if !(Actual is Map)
			return Path . ": expected an object"
		if Expected.Count != Actual.Count
			return Path . ": " . Expected.Count . " field(s) expected, got " . Actual.Count
		for Key, Value in Expected {
			if !Actual.Has(Key)
				return Path . "." . Key . " is missing"
			Found := _KCF_Difference(Value, Actual[Key], Path . "." . Key)
			if Found != ""
				return Found
		}
		return ""
	}
	if Expected is Array {
		if !(Actual is Array)
			return Path . ": expected an array"
		if Expected.Length != Actual.Length
			return Path . ": " . Expected.Length . " item(s) expected, got " . Actual.Length
		for Index, Value in Expected {
			Found := _KCF_Difference(Value, Actual[Index], Path . "[" . Index . "]")
			if Found != ""
				return Found
		}
		return ""
	}
	if IsObject(Actual) || Type(Expected) != Type(Actual) || !(Expected == Actual)
		return Path . ": expected <" . Expected . ">, got <" . (IsObject(Actual) ? Type(Actual) : Actual) . ">"
	return ""
}

_KCF_Corpus(Name) {
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\keylayout\" . Name, "UTF-8"))
}

_KCF_RefusedVector(Vector) {
	AssertThrows(() => Keylayout_ParseCanonical(Vector["keylayout"]), Vector["name"] . " is refused")
	AssertThrows(() => Keylayout_Parse(Vector["keylayout"]), Vector["name"] . " is refused by the model too")
}

_KCF_EdgeFixturesReplay() {
	Vectors := _KCF_Corpus("edge_cases.json")["vectors"]
	Assert(Vectors.Length >= 8, "the corpus holds its fixtures")
	Refused := 0
	for Vector in Vectors {
		if Vector.Has("error") {
			Refused += 1
			_KCF_RefusedVector(Vector)
			continue
		}
		AssertEqual("", _KCF_Difference(Vector["canonical"], Keylayout_ParseCanonical(Vector["keylayout"])), Vector["name"])
	}
	Assert(Refused >= 5 && Refused < Vectors.Length, "both verdicts must be exercised")
}
Test("keylayout canonical form: every edge fixture parses to its form or is refused (PAR-76)", _KCF_EdgeFixturesReplay)

_KCF_RealComposerLayoutReplays() {
	Text := FileRead(_SharedDir . "\tests\corpus\layouts\composer\composed.keylayout", "UTF-8")
	AssertEqual("", _KCF_Difference(_KCF_Corpus("composed.canonical.json")["canonical"], Keylayout_ParseCanonical(Text)))
}
Test("keylayout canonical form: the real composer layout reads to the pinned form (PAR-76)", _KCF_RealComposerLayoutReplays)

; Their conversion to XKB belongs to Linux; what Windows owes them is a complete
; read, down to the chained dead keys they exist for.
_KCF_ConversionVectorInputsRead() {
	Vectors := _KCF_Corpus("xkb_conversion_vectors.json")["vectors"]
	Assert(Vectors.Length >= 2, "the corpus holds its layouts")
	for Vector in Vectors {
		Canonical := Keylayout_ParseCanonical(Vector["keylayout"])
		Assert(Canonical["key_map_sets"].Length > 0, Vector["name"] . " reads its keys")
		Assert(Canonical["actions"].Length > 0, Vector["name"] . " reads its dead keys")
		Model := Keylayout_Parse(Vector["keylayout"])
		for Action in Canonical["actions"]
			Assert(Model["Actions"].Has(Action["id"]), Vector["name"] . " indexes " . Action["id"])
	}
}
Test("keylayout canonical form: the inputs of the conversion vectors read completely (PAR-76)", _KCF_ConversionVectorInputsRead)

; The keystroke path reads the Model: a single-quoted key must reach it.
_KCF_SingleQuotedKeyReachesTheKeystrokePath() {
	for Vector in _KCF_Corpus("edge_cases.json")["vectors"] {
		if !InStr(Vector["name"], "single-quoted")
			continue
		Model := Keylayout_Parse(Vector["keylayout"])
		AssertEqual('"x"', Keylayout_Resolve(Model, 0, 0)["Text"], "the double quote inside single quotes")
		AssertEqual("y", Keylayout_Resolve(Model, 0, 1)["Text"])
		AssertEqual("Mini's", Model["Name"])
		return
	}
	Assert(false, "the corpus must hold the single-quoted fixture")
}
Test("keylayout canonical form: a single-quoted key reaches the keystroke path (PAR-76)", _KCF_SingleQuotedKeyReachesTheKeystrokePath)

_KCF_ModelFollowsTheFirstOfEachDuplicate() {
	for Vector in _KCF_Corpus("edge_cases.json")["vectors"] {
		if !InStr(Vector["name"], "everything")
			continue
		Model := Keylayout_Parse(Vector["keylayout"])
		AssertEqual("a", Keylayout_Resolve(Model, 0, 0)["Text"], "the first key of a code wins")
		AssertEqual("a", Keylayout_Resolve(Model, 0, 4)["Text"], "the first action of an id wins")
		AssertEqual("acute", Keylayout_Step(Model, "none", 0, 1)["Next"], "the dead key enters its state")
		AssertEqual(Chr(0xE9), Keylayout_Step(Model, "acute", 0, 1)["Output"], "the first when of a state wins")
		AssertEqual(Chr(0xB4), Model["Terminators"]["acute"], "the first terminator wins")
		AssertEqual(1, Model["Bases"]["set1"][2][2], "a repeated baseIndex replaces the earlier one")
		AssertEqual(1, Keylayout_KeyMapIndex(Model, Map("shift", true, "caps", true)), "anyShift caps? selects")
		AssertEqual(2, Keylayout_KeyMapIndex(Model, Map("option", true)), "rightOption folds onto option")
		return
	}
	Assert(false, "the corpus must hold the everything fixture")
}
Test("keylayout canonical form: the keystroke model follows the form's duplicate rules (PAR-76)", _KCF_ModelFollowsTheFirstOfEachDuplicate)
