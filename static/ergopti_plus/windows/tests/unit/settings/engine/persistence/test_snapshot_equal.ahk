; tests/unit/settings/engine/persistence/test_snapshot_equal.ahk

; ==============================================================================
; MODULE: Configuration Snapshot Equality Tests
; DESCRIPTION:
; The snapshot comparison runs twice on every read of config.toml, so it skips
; per-node work. It must still give the verdict of the plain definition below
; on real snapshots and on every kind of change a consumer could make.
; ==============================================================================

#Requires AutoHotkey v2.0

; The comparison as it was before boot-snapshot-compare-2026-11-03: the oracle.
_CSE_PlainEqual(Left, Right) {
	if Type(Left) != Type(Right)
		return false
	if Left is Map {
		if ObjGetBase(Left) != Map.Prototype || ObjGetBase(Right) != Map.Prototype
			return false
		for Name in ObjOwnProps(Left)
			return false
		for Name in ObjOwnProps(Right)
			return false
		if Left.Count != Right.Count || Left.CaseSense != Right.CaseSense
			return false
		ExactRight := Map()
		ExactRight.CaseSense := "On"
		for Name, Value in Right
			ExactRight[Name] := Value
		for Name, Value in Left {
			if !ExactRight.Has(Name) || !_CSE_PlainEqual(Value, ExactRight[Name])
				return false
		}
		return true
	}
	if Left is Array {
		if ObjGetBase(Left) != Array.Prototype || ObjGetBase(Right) != Array.Prototype
			return false
		for Name in ObjOwnProps(Left)
			return false
		for Name in ObjOwnProps(Right)
			return false
		if Left.Length != Right.Length
			return false
		loop Left.Length {
			if !Left.Has(A_Index) || !Right.Has(A_Index)
					|| !_CSE_PlainEqual(Left[A_Index], Right[A_Index])
				return false
		}
		return true
	}
	if IsObject(Left) {
		ExpectedBase := Left is TOML_Bool ? TOML_Bool.Prototype : Object.Prototype
		if ObjGetBase(Left) != ExpectedBase || ObjGetBase(Right) != ExpectedBase
			return false
		LeftFields := Map(), RightFields := Map()
		LeftFields.CaseSense := "On", RightFields.CaseSense := "On"
		for Pair in [[Left, LeftFields], [Right, RightFields]] {
			Owner := Pair[1], Fields := Pair[2]
			for Name in ObjOwnProps(Owner) {
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
				if !Descriptor.HasOwnProp("Value")
					return false
				Fields[Name] := Descriptor.Value
			}
		}
		if LeftFields.Count != RightFields.Count
			return false
		if Left is TOML_Bool {
			return LeftFields.Count == 1 && LeftFields.Has("Value") && RightFields.Has("Value")
				&& (LeftFields["Value"] is Integer) && LeftFields["Value"] == RightFields["Value"]
		}
		for Name, Value in LeftFields {
			if !RightFields.Has(Name) || !_CSE_PlainEqual(Value, RightFields[Name])
				return false
		}
		return true
	}
	return Left is String ? StrCompare(Left, Right, true) == 0 : Left == Right
}

_CSE_Source() {
	return '[_meta]`nschema_version = 22`n`n[script]`nlog_level = "INFO"`n'
		. '[hotstrings]`nmagic_key = "★"`nexpansion_delay = 0.25`n'
		. '[llm]`nenabled = true`nuser_profiles = "v1:W10="`n'
		. '[llm.navigation]`nnav_modifiers = ["alt", "ctrl"]`n'
		. '[[hotstrings.personal_files]]`npath = "a.toml"`nenabled = false`n'
		. '[shortcuts.keyboard]`nmeta_a = "select_line"`n'
}

; Both comparisons on one pair: the same verdict, and the expected one.
_CSE_Agree(Left, Right, Expected, Label) {
	AssertEqual(Expected, _CSE_PlainEqual(Left, Right) ? 1 : 0, "oracle: " . Label)
	AssertEqual(Expected, _ConfigTomlSnapshotEqual(Left, Right) ? 1 : 0, Label)
	AssertEqual(Expected, _ConfigTomlSnapshotEqual(Right, Left) ? 1 : 0, "reversed: " . Label)
}

_CSE_Getter(*) {
	return "x"
}

_CSE_RealSnapshotsAgree() {
	Left := ConfigTomlDecodeSnapshot(_CSE_Source())
	Right := ConfigTomlDecodeSnapshot(_CSE_Source())
	_CSE_Agree(Left, Right, 1, "two decodes of one source are equal")
	Changed := ConfigTomlDecodeSnapshot(StrReplace(_CSE_Source(), "INFO", "info"))
	_CSE_Agree(Left, Changed, 0, "a value differing only by case differs")
	Changed := ConfigTomlDecodeSnapshot(StrReplace(_CSE_Source(), "0.25", "0.5"))
	_CSE_Agree(Left, Changed, 0, "a changed number differs")

	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Cache["llm"]["enabled"] := 0
	_CSE_Agree(Left, Mutated, 0, "a mutated cache value differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Document["script"]["log_level"] := "Info"
	_CSE_Agree(Left, Mutated, 0, "a document string changed by case differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Document["script"]["extra"] := "x"
	_CSE_Agree(Left, Mutated, 0, "an added document key differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Document["script"].Delete("log_level")
	Mutated.Document["script"]["LOG_LEVEL"] := "INFO"
	_CSE_Agree(Left, Mutated, 0, "a document key renamed by case differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Rows[1].Raw := Mutated.Rows[1].Raw . "!"
	_CSE_Agree(Left, Mutated, 0, "a mutated row field differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Rows[1].Extra := 1
	_CSE_Agree(Left, Mutated, 0, "an added row field differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Rows.Pop()
	_CSE_Agree(Left, Mutated, 0, "a removed row differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Rows[1].DefineProp("Section", { Get: _CSE_Getter })
	_CSE_Agree(Left, Mutated, 0, "a row field turned into a getter differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Cache.DefineProp("Tag", { Value: 1 })
	_CSE_Agree(Left, Mutated, 0, "an own property on a cache map differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Document["llm"]["enabled"] := 1
	_CSE_Agree(Left, Mutated, 0, "a Boolean replaced by its integer differs")
	Mutated := ConfigTomlDecodeSnapshot(_CSE_Source())
	Mutated.Document["llm"]["enabled"].Value := 0
	_CSE_Agree(Left, Mutated, 0, "a flipped Boolean differs")
}
Test("config snapshot: the fast comparison keeps the plain verdict on real snapshots (boot-snapshot-compare-2026-11-03)",
	_CSE_RealSnapshotsAgree)

_CSE_SyntheticCasesAgree() {
	Off := Map(), OffTwin := Map()
	Off.CaseSense := "Off", OffTwin.CaseSense := "Off"
	Off["Key"] := 1, OffTwin["key"] := 1
	_CSE_Agree(Off, OffTwin, 0, "case-insensitive maps compare their spellings exactly")
	OffSame := Map()
	OffSame.CaseSense := "Off"
	OffSame["Key"] := 1
	_CSE_Agree(Off, OffSame, 1, "case-insensitive maps with one spelling are equal")
	On := Map(), OnTwin := Map()
	On.CaseSense := "On", OnTwin.CaseSense := "On"
	On["a"] := "x", OnTwin["a"] := "x"
	_CSE_Agree(On, OnTwin, 1, "case-sensitive maps with the same entries are equal")
	_CSE_Agree(On, OffSame, 0, "maps with another case rule differ")
	OnTwin["a"] := 1
	_CSE_Agree(On, OnTwin, 0, "a string and an integer differ")
	_CSE_Agree(Map("a", 1), Map("a", 1.0), 0, "an integer and a float differ by type")
	_CSE_Agree(Map("a", "1"), Map("a", 1), 0, "a numeric string and its number differ")
	_CSE_Agree([1, "a", [2]], [1, "a", [2]], 1, "nested arrays with the same cells are equal")
	_CSE_Agree([1, "a", [2]], [1, "A", [2]], 0, "a cell changed by case differs")
	Sparse := [1, 2], Sparse.Delete(2)
	Full := [1, 2]
	_CSE_Agree(Sparse, Full, 0, "a missing cell differs")
	_CSE_Agree(Sparse, Sparse.Clone(), 0, "a missing cell is never equal, even to itself")
	_CSE_Agree({ A: 1 }, { a: 1 }, 0, "a field renamed by case differs")
	_CSE_Agree({ A: 1, B: "x" }, { B: "x", A: 1 }, 1, "the same fields in another order are equal")
	_CSE_Agree({ A: 1 }, { A: 1, B: 2 }, 0, "an extra field differs")
	_CSE_Agree(TOML_Bool(true), TOML_Bool(true), 1, "equal Booleans are equal")
	_CSE_Agree(TOML_Bool(true), TOML_Bool(false), 0, "opposite Booleans differ")
	Empty := TOML_Bool(true), Empty.DeleteProp("Value")
	Other := TOML_Bool(true), Other.DeleteProp("Value")
	_CSE_Agree(Empty, Other, 0, "a Boolean without its value is never equal")
	Extra := TOML_Bool(true), Extra.Note := 1
	ExtraTwin := TOML_Bool(true), ExtraTwin.Note := 1
	_CSE_Agree(Extra, ExtraTwin, 0, "a Boolean with a second field is never equal")
	_CSE_Agree({ A: 1 }, Map("A", 1), 0, "an object and a map differ")
}
Test("config snapshot: the fast comparison keeps the plain verdict on every node kind (boot-snapshot-compare-2026-11-03)",
	_CSE_SyntheticCasesAgree)
