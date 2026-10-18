; tests/unit/infra/toml/test_toml_nested_arrays.ahk

; ==============================================================================
; MODULE: TOML Nested Array Boundary Tests
; DESCRIPTION:
; All array decoders retain nested boundaries. Multiline continuation gives
; valid array values priority over ambiguous section-looking lines.
; ==============================================================================

#Requires AutoHotkey v2.0

_TNA_Equal(Expected, Actual) {
	AssertEqual(Type(Expected), Type(Actual), "array structure and scalar types must survive")
	if Expected is Array {
		AssertEqual(Expected.Length, Actual.Length)
		for Index, Value in Expected
			_TNA_Equal(Value, Actual[Index])
	} else {
		AssertEqual(Expected, Actual)
	}
}

_TNA_Decoder(Coerce) {
	Raw := '[[1, 2], ["a,b", "x]y", "a\\", "a\",b"], [], [true]]'
	Expected := [[1, 2], ["a,b", "x]y", "a\", 'a",b'], [], [true]]
	_TNA_Equal(Expected, Coerce.Call(Raw))
}
Test("TOML: fresh decoder retains nested item boundaries (toml-nested-array-coerce)",
	_TNA_Decoder.Bind(TOML_CoerceValue))
Test("TOML: feature decoder retains nested item boundaries (toml-nested-array-feature)",
	_TNA_Decoder.Bind(TomlCoerceValueExt))
Test("TOML: shortcut decoder retains nested item boundaries (toml-nested-array-shortcut)",
	_TNA_Decoder.Bind(CS_CoerceValue))

_TNA_Multiline(Literal, Expected) {
	Path := _CTU_NewPath()
	Source := "[sample]`nitems = [`n" . Literal . "`n]`n[later]`nflag = true`n"
	try {
		AssertTrue(FSWrite(Path, Source))
		Parsed := TOML_ParseFreshFile(Path)
		AssertTrue(Parsed["sample"].Has("items"),
			"a nested value must not be reinterpreted as a section header")
		_TNA_Equal([Expected], Parsed["sample"]["items"])
		AssertTrue(Parsed["later"]["flag"])
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "later", Key: "other", Value: 2 }]))
		Parsed := TOML_ParseFreshFile(Path)
		_TNA_Equal([Expected], Parsed["sample"]["items"])
		AssertTrue(Parsed["later"]["flag"])
		AssertEqual(2, Parsed["later"]["other"])
	} finally FSDelete(Path)
}
Test("TOML: numeric continuation remains an array (toml-nested-array-number)",
	_TNA_Multiline.Bind("[1]", [1]))
Test("TOML: quoted continuation remains an array (toml-nested-array-string)",
	_TNA_Multiline.Bind('["a"]', ["a"]))
Test("TOML: literal continuation remains an array (toml-literal-array-recovery)",
	_TNA_Multiline.Bind("['a']", ["a"]))
Test("TOML: Boolean continuation remains an array (toml-nested-array-boolean)",
	_TNA_Multiline.Bind("[true]", [true]))
Test("TOML: empty continuation remains an array (toml-nested-array-empty)",
	_TNA_Multiline.Bind("[]", []))
Test("TOML: incomplete nested opener remains a value (toml-nested-array-opener)",
	_TNA_Multiline.Bind("[`n[2, 3]`n]", [[2, 3]]))

_TNA_RecoveryBoundary() {
	for Header in ["[later_section]", "[a.b]", '[a."quoted.key"]', "[[later_section]]",
		'["later"."section"]', '[[ "later"."section" ]]',
		'["a[b]".section]', '[["a]b".section]]',
		"[later.'section']", "['later'.section]", "[[ 'later'.'section' ]]",
		"[later.'quoted.key']", "[later.'a]b']", "[later.'a[b']"] {
		AssertTrue(TOML_ArrayRecoveryHeader(Header), "unambiguous headers must remain recoverable")
		Source := "[sample]`nitems = [`n" . Header . "`nflag = true`n"
		Parsed := _ParseTomlFileImpl("nested-recovery-fixture", false, false, Source)
		AssertEqual(2, Parsed.Count)
		AssertFalse(Parsed["sample"].Has("items"))
		Recovered := false
		for Section, Values in Parsed {
			if Section != "sample"
				Recovered := Values.Has("flag") && Values["flag"] == true
		}
		AssertTrue(Recovered)
	}
	for ValueLine in ["[", "[]", "[1]", "[true]", '["a"]', "[[2]]",
		"[1e3]", "[0xff]", "[+inf]", "[nan]", "[2020-01-01]", '["a", "b"],',
		'["a]"]', '["a[b]"]', "['a']", "[ 'a]b' ]", "['a[b']"] {
		AssertFalse(TOML_ArrayRecoveryHeader(ValueLine),
			"value-shaped continuations must not discard the pending array: " . ValueLine)
	}
}
Test("TOML: continuation priority preserves section recovery (toml-nested-array-recovery)",
	_TNA_RecoveryBoundary)

_TNA_MetadataOrder(Raw, Expected) {
	global _TomlFileCache
	Path := _CTU_NewPath()
	try {
		; The payload is deliberately outside the metadata reader's ownership.
		AssertTrue(FSWrite(Path, "[_meta]`nsections_order = " . Raw
			. " # authored order`n[[code]]`nnot a parsed metadata assignment`n"))
		_TNA_Equal(Expected, ReadTomlSectionsOrder("", Path))
	} finally {
		if _TomlFileCache.Has(Path)
			_TomlFileCache.Delete(Path)
		FSDelete(Path)
	}
}
Test("TOML: section order decodes Unicode names (toml-section-order-codec)",
	_TNA_MetadataOrder.Bind('["\u0063ode", "-", "\u0065mail"]', ["code", "-", "email"]))
Test("TOML: section order retains quoted boundaries (toml-section-order-codec)",
	_TNA_MetadataOrder.Bind('["first,part", "quote\"key", "path\\key"]',
		["first,part", 'quote"key', "path\key"]))
Test("TOML: section order retains numeric-looking names (toml-section-order-codec)",
	_TNA_MetadataOrder.Bind('["001", "0", "1"]', ["001", "0", "1"]))
Test("TOML: section order accepts trailing commas (toml-section-order-codec)",
	_TNA_MetadataOrder.Bind('["code", "email", ]', ["code", "email"]))
Test("TOML: section order preserves empty arrays (toml-section-order-codec)",
	_TNA_MetadataOrder.Bind("[]", []))
