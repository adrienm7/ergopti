; tests/unit/test_toml_inline_tables.ahk

; ==============================================================================
; MODULE: TOML Inline Table Preservation Tests
; DESCRIPTION:
; Unrelated saves retain object members and types; invalid objects cannot publish.
; ==============================================================================

#Requires AutoHotkey v2.0

_TIT_Literal() {
	return '[{ name = "x", count = 2, active = false, child = { "a,b=#" = [1, { value = "x}#,y" }] }, empty = {} }]'
}

_TIT_AssertItems(Items) {
	AssertTrue(Items is Array)
	AssertEqual(1, Items.Length, "one inline table must remain one array element")
	Item := Items[1]
	AssertTrue(Item is Map)
	AssertEqual(5, Item.Count)
	AssertEqual("x", Item["name"])
	AssertTrue(Item["count"] is Integer)
	AssertEqual(2, Item["count"])
	AssertTrue(Item["active"] is Integer)
	AssertFalse(Item["active"])
	AssertTrue(Item["empty"] is Map)
	AssertEqual(0, Item["empty"].Count)
	Child := Item["child"]["a,b=#"]
	AssertTrue(Child is Array)
	AssertEqual(2, Child.Length)
	AssertEqual(1, Child[1])
	AssertEqual("x}#,y", Child[2]["value"])
}

_TIT_Preserve(BuildOnly) {
	Path := _CTU_NewPath()
	Source := "[sample]`nitems = " . _TIT_Literal() . "`nafter = 1`n"
	Updates := [{ Section: "sample", Key: "after", Value: 2 }]
	try {
		AssertTrue(FSWrite(Path, Source))
		if BuildOnly {
			Candidate := TOML_BuildUpdatedContent(Path, Updates)
			AssertEqual("ok", Candidate["status"])
			AssertEqual(Source, FSRead(Path))
			AssertTrue(FSWrite(Path, Candidate["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Parsed := TOML_ParseFreshFile(Path)
		AssertEqual(2, Parsed["sample"]["after"])
		_TIT_AssertItems(Parsed["sample"]["items"])
		AssertTrue(InStr(FSRead(Path), "active = false") > 0,
			"native Boolean coercion must not turn the saved literal into 0")
	} finally FSDelete(Path)
}
Test("TOML: objects survive unrelated saves (toml-inline-tables-write)", _TIT_Preserve.Bind(false))
Test("TOML: objects survive detached builds (toml-inline-tables-build)", _TIT_Preserve.Bind(true))

_TIT_Decode(Coerce) {
	_TIT_AssertItems(Coerce.Call(_TIT_Literal()))
	Item := Coerce.Call('{ A = 1, a = 2, nested.first = 3, nested.second = 4, "nested.first" = 5 }')
	AssertEqual(4, Item.Count)
	AssertEqual(1, Item["A"])
	AssertEqual(2, Item["a"])
	AssertEqual(3, Item["nested"]["first"])
	AssertEqual(4, Item["nested"]["second"])
	AssertEqual(5, Item["nested.first"])
}
Test("TOML: fresh decoder retains object members (toml-inline-tables-fresh)", _TIT_Decode.Bind(TOML_CoerceValue))
Test("TOML: feature decoder retains object members (toml-inline-tables-feature)", _TIT_Decode.Bind(TomlCoerceValueExt))
Test("TOML: shortcut decoder retains object members (toml-inline-tables-shortcut)", _TIT_Decode.Bind(CS_CoerceValue))

_TIT_Invalid(BuildOnly) {
	for Literal in ['{ x = 1, x = 2 }', '{ x = 1, }', '{ x = 1', '{ x = [1, 2 }',
		'{ x }', '{ x = }', '{ x = 1, x.y = 2 }', '{ x = {}, x.y = 2 }'] {
		Path := _CTU_NewPath()
		Source := "[sample]`nitem = " . Literal . "`nafter = 1`n"
		try {
			AssertTrue(FSWrite(Path, Source))
			Refused := false
			try {
				Updates := [{ Section: "sample", Key: "after", Value: 2 }]
				if BuildOnly
					TOML_BuildUpdatedContent(Path, Updates)
				else
					TOML_BatchWrite(Path, Updates)
			} catch ValueError {
				Refused := true
			}
			AssertTrue(Refused, "invalid object must raise before publication: " . Literal)
			AssertEqual(Source, FSRead(Path))
		} finally FSDelete(Path)
	}
}
Test("TOML: invalid objects cannot publish (toml-inline-tables-invalid-write)", _TIT_Invalid.Bind(false))
Test("TOML: invalid objects cannot build (toml-inline-tables-invalid-build)", _TIT_Invalid.Bind(true))

_TIT_Render() {
	Child := Map("flag", TOML_Bool(false), "count", 2, "text", "001")
	Expected := '[{count = 2, flag = false, text = "001"}, {count = 2, flag = false, text = "001"}]'
	AssertEqual(Expected, TOML_RenderValue([Child, Child]))
	AssertTrue(Child["flag"] is TOML_Bool, "rendering must not mutate caller objects")
	Cyclic := Map()
	Cyclic["child"] := [Cyclic]
	Refused := false
	try TOML_RenderValue(Cyclic)
	catch ValueError as Err {
		Refused := InStr(Err.Message, "reference cycle") > 0
	} finally Cyclic.Delete("child")
	AssertTrue(Refused, "mixed array/object cycles must fail before stack exhaustion")
}
Test("TOML: object rendering preserves types and rejects cycles (toml-inline-tables-render)", _TIT_Render)

_TIT_LiteralStrings(BuildOnly) {
	Path := _CTU_NewPath()
	Source := "[sample]`nitems = [{ 'a.b' = 'x,#]=y', A = 1, a = 2 }]`nafter = 1`n"
	try {
		AssertTrue(FSWrite(Path, Source))
		Updates := [{ Section: "sample", Key: "after", Value: 2 }]
		if BuildOnly {
			Candidate := TOML_BuildUpdatedContent(Path, Updates)
			AssertEqual("ok", Candidate["status"])
			AssertEqual(Source, FSRead(Path))
			AssertTrue(FSWrite(Path, Candidate["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Item := TOML_ParseFreshFile(Path)["sample"]["items"][1]
		AssertEqual(3, Item.Count)
		AssertEqual("x,#]=y", Item["a.b"])
		AssertEqual(1, Item["A"])
		AssertEqual(2, Item["a"])
	} finally FSDelete(Path)
}
Test("TOML: literal object strings survive writes (toml-inline-tables-literal-write)", _TIT_LiteralStrings.Bind(false))
Test("TOML: literal object strings survive builds (toml-inline-tables-literal-build)", _TIT_LiteralStrings.Bind(true))
