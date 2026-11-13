; tests/unit/layouts/engine/composer/test_keylayout_canonical_form.ahk

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


_KCF_NumericFixture(Attribute := "", Raw := "", Entity := "A") {
 DefaultIndex := Attribute == "defaultIndex" ? Raw : "0"
 MapIndex := Attribute == "mapIndex" ? Raw : "0"
 Index := Attribute == "index" ? Raw : "0"
 BaseIndex := Attribute == "baseIndex" ? Raw : "0"
 Code := Attribute == "code" ? Raw : "3"
 Key := Attribute == "baseIndex" ? "" : '<key code="' . Code . '" output="' . Entity . '"/>'
 return '<keyboard name="Private numeric layout"><layouts><layout first="0" modifiers="mods" mapSet="maps"/></layouts>'
  . '<modifierMap id="mods" defaultIndex="' . DefaultIndex . '"><keyMapSelect mapIndex="' . MapIndex . '"><modifier keys=""/></keyMapSelect></modifierMap>'
  . '<keyMapSet id="maps"><keyMap index="' . Index . '" baseMapSet="base" baseIndex="' . BaseIndex . '">' . Key . '</keyMap></keyMapSet>'
  . '<keyMapSet id="base"><keyMap index="0"><key code="3" output="B"/></keyMap><keyMap index="3"><key code="3" output="B"/></keyMap></keyMapSet></keyboard>'
}
_KCF_RequireNumericRefusal(Text, Boundary) {
 for Parser in [Keylayout_ParseCanonical, Keylayout_Parse] {
  Refused := false
  try Parser.Call(Text)
  catch ValueError as Failure {
   AssertContains(Failure.Message, Boundary, "The actual numeric boundary must explain refusal")
   Refused := true
  }
  AssertTrue(Refused, "The complete external numeric lexeme must not become a different native integer")
 }
}
_KCF_AttributeIntegerDomain(Attribute) {
 Ordinary := Attribute == "code" || Attribute == "baseIndex" ? "3" : "0"
 Text := _KCF_NumericFixture(Attribute, Ordinary)
 Expected := Attribute == "baseIndex" ? "B" : "A"
 AssertEqual(Expected, Keylayout_Step(Keylayout_Parse(Text), "none", 0, 3)["Output"], "The genuine model must still type the ordinary control")
 Raw := Ordinary == "3" ? "18446744073709551619" : "18446744073709551616"
 Text := _KCF_NumericFixture(Attribute, Raw)
 try {
  Model := Keylayout_Parse(Text)
  Step := Keylayout_Step(Model, "none", 0, 3)
  _TestPrint("# keylayout numeric attribute=" . Attribute . " raw=" . Raw . " unintended_output=" . Step["Output"])
 } catch ValueError {
  ; Refusal is required below from both complete public parsers.
 }
 _KCF_RequireNumericRefusal(Text, Attribute)
 Hex := Ordinary == "3" ? "0x10000000000000003" : "0x10000000000000000"
 _KCF_RequireNumericRefusal(_KCF_NumericFixture(Attribute, Hex), Attribute)
}
for _KCF_NumericAttribute in ["code", "defaultIndex", "mapIndex", "index", "baseIndex"]
 Test("Keylayout numeric attribute refuses modulo aliases: " . _KCF_NumericAttribute . " (keylayout-integer-attribute-domain)", _KCF_AttributeIntegerDomain.Bind(_KCF_NumericAttribute))

_KCF_EntityIntegerDomain(Hex) {
 Ordinary := Hex ? "&#x41" : "&#65"
 Text := _KCF_NumericFixture("", "", Ordinary . Chr(59))
 AssertEqual("A", Keylayout_Step(Keylayout_Parse(Text), "none", 0, 3)["Output"], "The ordinary XML character reference must still type its scalar")
 Raw := Hex ? "&#x10000000000000041" : "&#18446744073709551681"
 Text := _KCF_NumericFixture("", "", Raw . Chr(59))
 try {
  Model := Keylayout_Parse(Text)
  Step := Keylayout_Step(Model, "none", 0, 3)
  _TestPrint("# keylayout numeric entity=" . Raw . " unintended_output=" . Step["Output"])
 } catch ValueError {
  ; A large entity must be refused before it becomes an ordinary A.
 }
 _KCF_RequireNumericRefusal(Text, "character reference")
}
for _KCF_NumericHex in [false, true]
 Test("Keylayout numeric entity refuses modulo alias: " . (_KCF_NumericHex ? "hexadecimal" : "decimal") . " (keylayout-entity-integer-domain)", _KCF_EntityIntegerDomain.Bind(_KCF_NumericHex))


_KCF_EntityScalarDomain(Hex) {
 for Vector in [["0", "0", Chr(0)], ["16", "10", Chr(16)], ["55295", "D7FF", Chr(0xD7FF)], ["57344", "E000", Chr(0xE000)], ["1114111", "10FFFF", Chr(0x10FFFF)]] {
  Entity := (Hex ? "&#x" . Vector[2] : "&#" . Vector[1]) . Chr(59)
  Parsed := Keylayout_ParseCanonical(_KCF_NumericFixture("", "", Entity))
  Actual := Parsed["key_map_sets"][1]["key_maps"][1]["keys"][1]["output"]
  AssertEqual(StrLen(Vector[3]), StrLen(Actual), "A scalar edge must preserve its explicit UTF-16 length, including NUL")
  Units := ""
  Loop StrLen(Vector[3]) {
   ExpectedUnit := NumGet(StrPtr(Vector[3]), (A_Index - 1) * 2, "UShort")
   ActualUnit := NumGet(StrPtr(Actual), (A_Index - 1) * 2, "UShort")
   AssertEqual(ExpectedUnit, ActualUnit, "Every stored scalar code unit must survive XML decoding")
   Units .= (A_Index == 1 ? "" : ",") . Format("{:04X}", ActualUnit)
  }
  _TestPrint("# keylayout scalar hex=" . Hex . " entity=" . (Hex ? Vector[2] : Vector[1]) . " units=" . Units)
  AssertEqual(Vector[3], Actual, "Valid scalar edges and shipped control placeholders retain exact output")
 }
 for Vector in [["4294967361", "100000041"], ["1114112", "110000"], ["55296", "D800"], ["57343", "DFFF"]] {
  Entity := (Hex ? "&#x" . Vector[2] : "&#" . Vector[1]) . Chr(59)
  _KCF_RequireNumericRefusal(_KCF_NumericFixture("", "", Entity), "character reference")
 }
}
for _KCF_ScalarHex in [false, true]
 Test("Keylayout numeric entity enforces scalar bounds: " . (_KCF_ScalarHex ? "hexadecimal" : "decimal") . " (keylayout-entity-scalar-domain)", _KCF_EntityScalarDomain.Bind(_KCF_ScalarHex))
