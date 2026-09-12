; tests/unit/test_toml_float_roundtrip.ahk

; ==============================================================================
; MODULE: TOML Float Round-Trip Tests
; DESCRIPTION:
; Rendering preserves finite binary values and their Float type, including
; exponent notation and signed zero. Real whole-file updates retain neighbors.
; ==============================================================================

#Requires AutoHotkey v2.0

_TFR_AssertSame(Expected, Actual) {
	AssertTrue(Actual is Float, "a rendered Float must decode as Float")
	Bits := Buffer(16)
	NumPut("Double", Expected, Bits, 0)
	NumPut("Double", Actual, Bits, 8)
	AssertEqual(NumGet(Bits, 0, "Int64"), NumGet(Bits, 8, "Int64"),
		"round trips must preserve every bit, including the sign of zero")
}

_TFR_Render(Value) {
	Rendered := TOML_RenderValue(Value)
	for Coerce in [TOML_CoerceValue, TomlCoerceValue, TomlCoerceValueExt]
		_TFR_AssertSame(Value, Coerce.Call(Rendered))
}
for Value in [1.2345678901234567, 1.0, 0.0, -0.0, -1.0, 1.0e-20, 1.0e20,
	1.7976931348623157e308, 4.9406564584124654e-324]
	Test("TOML: Float bits survive " . Format("{:.17g}", Value) . " (toml-float-render)",
		_TFR_Render.Bind(Value))

_TFR_ExponentGrammar() {
	for Raw, Expected in Map("1e3", 1000.0, "-2E-2", -0.02, "+3.5e+2", 350.0) {
		AssertTrue(TOML_TryParseFloat(Raw, &Actual))
		_TFR_AssertSame(Expected, Actual)
	}
	for Raw in ["1e", "1e+", "1.e2", ".1e2", "1e309", "-1e309"] {
		AssertFalse(TOML_TryParseFloat(Raw, &Actual))
		AssertTrue(Actual is String)
		AssertEqual("", Actual)
	}
}
Test("TOML: exponent syntax retains finite-only admission (toml-float-exponent)",
	_TFR_ExponentGrammar)

_TFR_WholeFile(BuildOnly) {
	Path := _CTU_NewPath()
	Original := '[sample]`nprecise = 1.2345678901234567`nintegral = 1.0`n'
		. 'values = [1.25, 1.0e-20]`ntext = "1e20"`ninteger = 1`n'
	Updates := [{ Section: "sample", Key: "other", Value: 2 }]
	try {
		AssertTrue(FSWrite(Path, Original))
		if BuildOnly {
			Result := TOML_BuildUpdatedContent(Path, Updates)
			AssertTrue(Result is Map)
			AssertEqual("ok", Result["status"])
			AssertEqual(Original, FSRead(Path), "detached rendering must not publish")
			AssertTrue(FSWrite(Path, Result["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Parsed := TOML_ParseFreshFile(Path)["sample"]
		_TFR_AssertSame(1.2345678901234567, Parsed["precise"])
		_TFR_AssertSame(1.0, Parsed["integral"])
		AssertEqual(2, Parsed["values"].Length)
		_TFR_AssertSame(1.25, Parsed["values"][1])
		_TFR_AssertSame(1.0e-20, Parsed["values"][2])
		AssertTrue(Parsed["text"] is String)
		AssertEqual("1e20", Parsed["text"])
		AssertTrue(Parsed["integer"] is Integer)
		AssertEqual(1, Parsed["integer"])
		AssertEqual(2, Parsed["other"])
	} finally FSDelete(Path)
}
Test("TOML: writes preserve Float neighbors (toml-float-write)", _TFR_WholeFile.Bind(false))
Test("TOML: detached builds preserve Float neighbors (toml-float-build)", _TFR_WholeFile.Bind(true))

_TFR_NonFinite() {
	for Raw in ["1e309", "-1e309"] {
		Value := Float(Raw)
		Rejected := false
		try TOML_RenderValue(Value)
		catch ValueError
			Rejected := true
		AssertTrue(Rejected, "non-finite values must fail before serialization")
	}
}
Test("TOML: non-finite native Floats cannot be serialized (toml-float-nonfinite)", _TFR_NonFinite)

_TFR_RefuseNonFiniteWrite(Write) {
	Path := _CTU_NewPath()
	Original := '[sample]`nkept = "unchanged"`n'
	try {
		AssertTrue(FSWrite(Path, Original))
		Rejected := false
		try Write.Call(Path, [{ Section: "sample", Key: "invalid", Value: Float("1e309") }])
		catch ValueError
			Rejected := true
		AssertTrue(Rejected, "the writer must propagate invalid numeric state")
		AssertEqual(Original, FSRead(Path), "invalid numeric state must not change the file")
	} finally FSDelete(Path)
}
Test("TOML: writes refuse non-finite state before publication (toml-float-refuse-write)",
	_TFR_RefuseNonFiniteWrite.Bind(TOML_BatchWrite))
Test("TOML: builds refuse non-finite state before publication (toml-float-refuse-build)",
	_TFR_RefuseNonFiniteWrite.Bind(TOML_BuildUpdatedContent))
