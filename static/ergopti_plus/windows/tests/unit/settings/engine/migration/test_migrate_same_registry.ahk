; tests/unit/settings/engine/migration/test_migrate_same_registry.ahk

; ==============================================================================
; MODULE: Registry Comparison Differential
; DESCRIPTION:
; ConfigMigrateSameRegistry decides whether a mutated live registry is refused,
; and it was rewritten for speed. These tests hold it to the plain node-by-node
; definition it replaced: one answer for every class of difference, in both
; directions, on small models and on the shipped registry.
; ==============================================================================

#Requires AutoHotkey v2.0





class _CMSR_MapChild extends Map {
}

class _CMSR_ArrayChild extends Array {
}

class _CMSR_BoolChild extends TOML_Bool {
}

_CMSR_Plain(Value, Prototype) {
	return IsObject(Value) && ObjGetBase(Value) == Prototype && !ObjOwnPropCount(Value)
}

; The original comparison, kept verbatim as the definition of the right answer.
_CMSR_Reference(Left, Right) {
	if Left is String
		return (Right is String) && Left == Right
	if Left is Integer || Left is Float
		return (Right is Integer || Right is Float) && Left = Right
	if Left is Map {
		if !_CMSR_Plain(Left, Map.Prototype) || !_CMSR_Plain(Right, Map.Prototype)
				|| Left.Count != Right.Count || Left.CaseSense != Right.CaseSense
			return false
		ExactRight := Right
		if Right.CaseSense != "On" {
			ExactRight := Map()
			ExactRight.CaseSense := "On"
			for Key, Value in Right
				ExactRight[Key] := Value
		}
		for Key, Value in Left {
			if !ExactRight.Has(Key) || !_CMSR_Reference(Value, ExactRight[Key])
				return false
		}
		return true
	}
	if Left is Array {
		if !_CMSR_Plain(Left, Array.Prototype) || !_CMSR_Plain(Right, Array.Prototype)
				|| Left.Length != Right.Length
			return false
		loop Left.Length {
			if !Left.Has(A_Index) || !Right.Has(A_Index)
					|| !_CMSR_Reference(Left[A_Index], Right[A_Index])
				return false
		}
		return true
	}
	if Left is TOML_Bool {
		if !IsObject(Right) || ObjGetBase(Left) != TOML_Bool.Prototype
				|| ObjGetBase(Right) != TOML_Bool.Prototype
			return false
		for Value in [Left, Right] {
			Count := 0
			for Name in ObjOwnProps(Value) {
				if Name != "Value"
					return false
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Value, Name)
				if !Descriptor.HasOwnProp("Value") || !(Descriptor.Value is Integer)
					return false
				Count += 1
			}
			if Count != 1
				return false
		}
		return Left.Value == Right.Value
	}
	return false
}

; Both comparisons, both directions, against the answer the case states.
_CMSR_Expect(Label, Expected, Left, Right) {
	for Pair in [[Left, Right], [Right, Left]] {
		AssertEqual(Expected, _CMSR_Reference(Pair[1], Pair[2]) ? 1 : 0, Label . ": the plain definition")
		AssertEqual(Expected, ConfigMigrateSameRegistry(Pair[1], Pair[2]) ? 1 : 0, Label . ": the rewritten walk")
	}
}

_CMSR_Model() {
	return Map("text", "abc", "number", 1, "float", 1.5, "flag", TOML_Bool(1),
		"list", ["x", 2, TOML_Bool(0), Map("inner", "value")], "map", Map("x", "y"))
}

_CMSR_Sparse(Length, Hole) {
	Cells := []
	Cells.Length := Length
	loop Length
		if A_Index != Hole
			Cells[A_Index] := "cell"
	return Cells
}

_CMSR_CaseInsensitive(Key, Value) {
	Row := Map()
	Row.CaseSense := "Off"
	Row[Key] := Value
	return Row
}

_CMSR_Scalars() {
	_CMSR_Expect("equal strings", 1, "abc", "abc")
	_CMSR_Expect("string case", 0, "abc", "ABC")
	_CMSR_Expect("string differs", 0, "abc", "abd")
	_CMSR_Expect("numeric twin strings", 0, "1", "1.0")
	_CMSR_Expect("string and its number", 0, "1", 1)
	_CMSR_Expect("float string and its number", 0, "1.5", 1.5)
	_CMSR_Expect("equal integers", 1, 7, 7)
	_CMSR_Expect("integer and equal float", 1, 1, 1.0)
	_CMSR_Expect("different numbers", 0, 1, 2)
	_CMSR_Expect("empty string and zero", 0, "", 0)
	_CMSR_Expect("scalar and map", 0, "abc", Map())
	_CMSR_Expect("number and array", 0, 1, [])
}
Test("registry comparison: scalars keep their type and case rules", _CMSR_Scalars)

_CMSR_Maps() {
	_CMSR_Expect("equal models", 1, _CMSR_Model(), _CMSR_Model())
	_CMSR_Expect("empty maps", 1, Map(), Map())
	_CMSR_Expect("map and array", 0, Map(), [])
	_CMSR_Expect("map and plain object", 0, Map(), {})
	_CMSR_Expect("plain objects", 0, {}, {})
	_CMSR_Expect("map child class", 0, Map(), _CMSR_MapChild())
	_CMSR_Expect("two map child classes", 0, _CMSR_MapChild(), _CMSR_MapChild())
	Changes := Map(
		"string value", (M) => M["text"] := "abd",
		"string value case", (M) => M["text"] := "ABC",
		"string into number", (M) => M["number"] := "1",
		"number value", (M) => M["number"] := 2,
		"float value", (M) => M["float"] := 1.25,
		"flag value", (M) => M["flag"] := TOML_Bool(0),
		"flag into integer", (M) => M["flag"] := 1,
		"added key", (M) => M["extra"] := "abc",
		"removed key", (M) => M.Delete("text"),
		"nested value", (M) => M["map"]["x"] := "z",
		"list cell", (M) => M["list"][1] := "other",
		"nested list map", (M) => M["list"][4]["inner"] := "other",
		"nested map child", (M) => M["map"] := _CMSR_MapChild(),
		"list own property", (M) => M["list"].DefineProp("extra", {Value: 1}),
		"map own property", (M) => M.DefineProp("extra", {Value: 1}),
		"nested map own property", (M) => M["map"].DefineProp("extra", {Value: 1}),
		"replaced key, same count", (M) => (M.Delete("text"), M["TEXT"] := "abc")
	)
	for Label, Change in Changes {
		Changed := _CMSR_Model()
		Change.Call(Changed)
		_CMSR_Expect(Label, 0, _CMSR_Model(), Changed)
	}
	_CMSR_Expect("integer key and its string", 0, Map(1, "v"), Map("1", "v"))
	Equal := _CMSR_Model()
	Equal["number"] := 1.0
	_CMSR_Expect("a float equal to the integer", 1, _CMSR_Model(), Equal)
}
Test("registry comparison: every map difference is refused and equal models pass", _CMSR_Maps)

_CMSR_MapCaseRules() {
	_CMSR_Expect("same case-insensitive key", 1, _CMSR_CaseInsensitive("Key", "v"), _CMSR_CaseInsensitive("Key", "v"))
	_CMSR_Expect("case-insensitive key spelled differently", 0, _CMSR_CaseInsensitive("Key", "v"), _CMSR_CaseInsensitive("KEY", "v"))
	_CMSR_Expect("case-insensitive value case", 0, _CMSR_CaseInsensitive("Key", "v"), _CMSR_CaseInsensitive("Key", "V"))
	Sensitive := Map("Key", "v")
	_CMSR_Expect("case rule differs", 0, Sensitive, _CMSR_CaseInsensitive("Key", "v"))
	_CMSR_Expect("sensitive key case", 0, Map("Key", "v"), Map("KEY", "v"))
}
Test("registry comparison: a case-insensitive map still needs exact keys", _CMSR_MapCaseRules)

_CMSR_Arrays() {
	_CMSR_Expect("equal arrays", 1, ["a", 1, TOML_Bool(1)], ["a", 1, TOML_Bool(1)])
	_CMSR_Expect("empty arrays", 1, [], [])
	_CMSR_Expect("length differs", 0, ["a"], ["a", "b"])
	_CMSR_Expect("order differs", 0, ["a", "b"], ["b", "a"])
	_CMSR_Expect("array child class", 0, [], _CMSR_ArrayChild())
	_CMSR_Expect("one hole", 0, _CMSR_Sparse(3, 2), _CMSR_Sparse(3, 0))
	_CMSR_Expect("holes elsewhere", 0, _CMSR_Sparse(3, 1), _CMSR_Sparse(3, 3))
	_CMSR_Expect("the same hole on both sides", 0, _CMSR_Sparse(3, 2), _CMSR_Sparse(3, 2))
	_CMSR_Expect("no holes", 1, _CMSR_Sparse(3, 0), _CMSR_Sparse(3, 0))
	Owned := ["a"]
	Owned.DefineProp("extra", {Value: 1})
	_CMSR_Expect("array with an own property", 0, ["a"], Owned)
}
Test("registry comparison: arrays stay dense, ordered and plain", _CMSR_Arrays)

_CMSR_Bools() {
	_CMSR_Expect("equal flags", 1, TOML_Bool(1), TOML_Bool(1))
	_CMSR_Expect("flags differ", 0, TOML_Bool(1), TOML_Bool(0))
	_CMSR_Expect("flag and integer", 0, TOML_Bool(1), 1)
	_CMSR_Expect("flag child class", 0, TOML_Bool(1), _CMSR_BoolChild(1))
	_CMSR_Expect("two flag child classes", 0, _CMSR_BoolChild(1), _CMSR_BoolChild(1))
	Extra := TOML_Bool(1)
	Extra.DefineProp("extra", {Value: 1})
	_CMSR_Expect("flag with an extra property", 0, TOML_Bool(1), Extra)
	Textual := TOML_Bool(1)
	Textual.DefineProp("Value", {Value: "1"})
	_CMSR_Expect("flag with a string value", 0, TOML_Bool(1), Textual)
	Computed := TOML_Bool(1)
	Computed.DefineProp("Value", {Get: (*) => 1})
	_CMSR_Expect("flag with a computed value", 0, TOML_Bool(1), Computed)
}
Test("registry comparison: flags stay exact TOML booleans", _CMSR_Bools)

; The nodes a registry walk meets, in order, so a change can be placed anywhere.
_CMSR_CollectHolders(Value, Holders) {
	if Value is Map {
		Holders.Push(Value)
		for , Child in Value
			_CMSR_CollectHolders(Child, Holders)
	} else if Value is Array {
		for Child in Value
			_CMSR_CollectHolders(Child, Holders)
	}
}

_CMSR_ShippedRegistry() {
	Registry := ManifestCloneValue(ConfigMigrateShippedRegistry())
	Twin := ManifestCloneValue(Registry)
	_CMSR_Expect("the shipped registry and its copy", 1, Registry, Twin)
	Holders := []
	_CMSR_CollectHolders(Registry, Holders)
	; A squashed registry may hold a single step: probe every node up to six.
	Probes := Min(6, Holders.Length)
	Assert(Probes >= 3, "the shipped registry must be large enough to probe")
	Stride := Holders.Length // Probes
	Probed := 0
	loop Probes {
		Holder := Holders[A_Index * Stride]
		for Key, Value in Holder {
			if Value is String {
				Holder[Key] := StrUpper(Value) . "#"
				_CMSR_Expect("a shipped string changed at node " . A_Index, 0, Registry, Twin)
				Holder[Key] := Value
				Probed += 1
				break
			}
		}
	}
	Assert(Probed > 0, "at least one probe must change a shipped string")
	_CMSR_Expect("the shipped registry once every probe is undone", 1, Registry, Twin)
}
Test("registry comparison: the shipped registry refuses a change wherever it sits", _CMSR_ShippedRegistry)

; A foreign comparison must not be able to answer for the private one.
_CMSR_ReplacedOwnerRefuses() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := _CMJ_CurrentSource()
	AssertFalse(Object.Prototype.HasOwnProp.Call(ConfigMigrateSameRegistry, "Call"))
	AssertTrue(FSWriteDurable(Path, Source))
	AssertEqual("current", ConfigMigrateBoot(Path)["status"])
	Guard := ConfigMigrateBoot(Path, "capture_noop")
	AssertTrue(Guard.Call(Source, 1), "the intact comparison admits the intact registry")
	Calls := {count: 0}
	try {
		ConfigMigrateSameRegistry.DefineProp("Call", {Call: (*) => (Calls.count += 1, true)})
		AssertFalse(Guard.Call(Source, 1), "a replaced comparison withdraws the owner")
		AssertEqual(0, Calls.count, "the replacement is never asked")
	} finally
		ConfigMigrateSameRegistry.DeleteProp("Call")
	AssertTrue(Guard.Call(Source, 1), "restoring the comparison restores the guard")
}
Test("registry comparison: a replaced comparison owner refuses every liveness check", _CMSR_ReplacedOwnerRefuses)
