; tests/unit/test_toml_array_element_types.ahk

; ==============================================================================
; MODULE: TOML Array Element Type Tests
; DESCRIPTION:
; Whole-file writes preserve the distinct literal types of existing array
; elements. Public readers still expose native values instead of writer sentinels.
; ==============================================================================

#Requires AutoHotkey v2.0

_TAET_AssertElements(Items) {
	AssertTrue(Items is Array)
	AssertEqual(9, Items.Length)
	AssertTrue(Items[1] is Integer)
	AssertEqual(2, Items[1])
	AssertTrue(Items[2] is Float)
	AssertEqual(1.25, Items[2])
	AssertTrue(Items[3] is TOML_Bool)
	AssertFalse(Items[3].Value)
	AssertTrue(Items[4] is TOML_Bool)
	AssertTrue(Items[4].Value)
	AssertTrue(Items[5] is String)
	AssertEqual("001", Items[5])
	AssertEqual("a,b", Items[6])
	AssertEqual("", Items[7])
	AssertTrue(Items[8] is Integer)
	AssertEqual(0, Items[8])
	AssertTrue(Items[9] is Integer)
	AssertEqual(1, Items[9])
}

_TAET_PreserveExisting(Multiline, BuildOnly) {
	Path := _CTU_NewPath()
	Literal := Multiline
		? '[`n  2, 1.25, # numeric values`n  false, true,`n  "001", "a,b", "", 0, 1,`n]'
		: '[2, 1.25, false, true, "001", "a,b", "", 0, 1]'
	Original := "[sample]`nitems = " . Literal . "`nafter = 1`n"
	Updates := [{ Section: "sample", Key: "after", Value: 2 }]
	try {
		AssertTrue(FSWrite(Path, Original))
		if BuildOnly {
			Candidate := TOML_BuildUpdatedContent(Path, Updates)
			AssertEqual("ok", Candidate["status"])
			AssertEqual(Original, FSRead(Path))
			AssertTrue(FSWrite(Path, Candidate["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Typed := _ParseTomlFileImpl(Path, false, false, unset, true)
		_TAET_AssertElements(Typed["sample"]["items"])
		AssertEqual(2, Typed["sample"]["after"])
		Native := TOML_ParseFreshFile(Path)["sample"]["items"]
		AssertTrue(Native[3] is Integer)
		AssertFalse(Native[3])
		AssertTrue(Native[4] is Integer)
		AssertTrue(Native[4])
	} finally FSDelete(Path)
}
Test("TOML: existing array types survive write (toml-array-element-types-write)",
	_TAET_PreserveExisting.Bind(false, false))
Test("TOML: multiline array types survive write (toml-array-element-types-multiline)",
	_TAET_PreserveExisting.Bind(true, false))
Test("TOML: existing array types survive detached build (toml-array-element-types-build)",
	_TAET_PreserveExisting.Bind(false, true))
Test("TOML: multiline array types survive detached build (toml-array-element-types-build-multiline)",
	_TAET_PreserveExisting.Bind(true, true))

_TAET_NewArray() {
	Path := _CTU_NewPath()
	Items := [2, 1.25, TOML_Bool(false), TOML_Bool(true), "001", "a,b", "", 0, 1]
	try {
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "sample", Key: "items", Value: Items }]))
		_TAET_AssertElements(_ParseTomlFileImpl(Path, false, false, unset, true)["sample"]["items"])
		AssertTrue(Items[3] is TOML_Bool, "rendering must not mutate caller-owned items")
	} finally FSDelete(Path)
}
Test("TOML: new arrays retain caller element types (toml-array-element-types-new)", _TAET_NewArray)

_TAET_RecursiveRenderingRejectsCycles() {
	Child := ["a,b", TOML_Bool(false), 0]
	AssertEqual('[["a,b", false, 0], ["a,b", false, 0]]', TOML_RenderValue([Child, Child]),
		"shared children are not cycles")
	Cyclic := []
	Cyclic.Push(Cyclic)
	Refused := false
	try TOML_RenderValue(Cyclic)
	catch ValueError as Err {
		Refused := InStr(Err.Message, "reference cycle") > 0
	} finally Cyclic.Pop()
	AssertTrue(Refused, "cyclic input must fail before exhausting the call stack")
}
Test("TOML: recursive rendering rejects cycles but allows shared children (toml-array-element-types-cycle)",
	_TAET_RecursiveRenderingRejectsCycles)
