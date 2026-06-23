; tests/unit/test_json_number_misleading_error.ahk

; ==============================================================================
; MODULE: JSON Number Misleading-Error Regression Test
; DESCRIPTION:
; Behavioral regression for the "json-number-misleading-error" finding.
;
; _JsonParseNumber used to coerce its accumulated slice with ``s + 0`` without
; verifying it had consumed at least one digit. Because the value dispatch in
; _JsonParseValue routes ANY unrecognised leading char to the number branch, a
; bare "-", a lone "e", or a stray "x" reached that coercion and threw AHK's
; internal "Expected a Number but got a String." — instead of the parser's
; advertised descriptive JSON-position error. The fix validates the slice
; (``^-?\d``) and throws Error("JSON: invalid number at position ...") first.
;
; This is a behavioral test (it actually calls JsonParse) because lib/json.ahk
; is #Included by run_all.ahk and JsonParse is a pure function with no OS / COM
; / network / hotkey side effects. It captures the thrown message and asserts it
; names JSON and a position rather than the generic numeric-coercion message —
; before the fix the message contained "Number"/"String" and the test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Throw-message capture helper ==========
; ==================================================
; ==================================================

; Calls JsonParse(Input) and returns the thrown exception's Message, or "" when
; nothing was thrown. Lets the assertions inspect the diagnostic text — the
; standard AssertThrows hides the message.
_JNME_CaptureThrowMessage(Input) {
	try {
		JsonParse(Input)
	} catch as e {
		return e.Message
	}
	return ""
}




; ==================================================
; ==================================================
; ======= 2/ Descriptive-error assertions ==========
; ==================================================
; ==================================================

_JNME_BareMinusThrowsJsonError() {
	Msg := _JNME_CaptureThrowMessage("-")
	Assert(Msg != "", "JsonParse('-') must throw — a lone minus is not a valid JSON number")
	Assert(InStr(Msg, "JSON") > 0,
		"JsonParse('-') message must name JSON, not surface AHK's numeric-coercion error — got: " . Msg)
	Assert(InStr(Msg, "position") > 0,
		"JsonParse('-') message must carry a position for field triage — got: " . Msg)
}
Test("JSON parser: bare '-' throws descriptive JSON-position error (json-number-misleading-error)", _JNME_BareMinusThrowsJsonError)

_JNME_BareEThrowsJsonError() {
	Msg := _JNME_CaptureThrowMessage("e")
	Assert(Msg != "", "JsonParse('e') must throw — 'e' alone is not a valid token")
	Assert(InStr(Msg, "JSON") > 0,
		"JsonParse('e') message must name JSON, not surface AHK's numeric-coercion error — got: " . Msg)
	Assert(InStr(Msg, "position") > 0,
		"JsonParse('e') message must carry a position — got: " . Msg)
}
Test("JSON parser: bare 'e' throws descriptive JSON-position error (json-number-misleading-error)", _JNME_BareEThrowsJsonError)

_JNME_StrayCharThrowsJsonError() {
	Msg := _JNME_CaptureThrowMessage("x")
	Assert(Msg != "", "JsonParse('x') must throw — 'x' is not a valid JSON value")
	Assert(InStr(Msg, "JSON") > 0,
		"JsonParse('x') message must name JSON (the catch-all number branch must fail loudly) — got: " . Msg)
	Assert(InStr(Msg, "position") > 0,
		"JsonParse('x') message must carry a position — got: " . Msg)
}
Test("JSON parser: stray 'x' throws descriptive JSON-position error (json-number-misleading-error)", _JNME_StrayCharThrowsJsonError)

_JNME_ValidNumbersStillParse() {
	; The guard must not break genuine numbers — regression-proof the happy path.
	AssertEqual(42, JsonParse("42"), "JsonParse('42') must still parse to 42 after the validation guard")
	AssertEqual(-7, JsonParse("-7"), "JsonParse('-7') must still parse to -7 after the validation guard")
	AssertEqual(3.14, JsonParse("3.14"), "JsonParse('3.14') must still parse to 3.14 after full-regex guard")
}
Test("JSON parser: valid numbers still parse after number guard (json-number-misleading-error)", _JNME_ValidNumbersStillParse)

_JNME_MalformedMultiDotThrows() {
	Msg := _JNME_CaptureThrowMessage("[1.2.3]")
	Assert(Msg != "", "JsonParse('[1.2.3]') must throw — double decimal point is not valid JSON")
	Assert(InStr(Msg, "JSON") > 0,
		"Malformed '1.2.3' must throw a JSON-position error, not silently pass — got: " . Msg)
}
Test("JSON parser: malformed '1.2.3' throws JSON-position error (full-regex guard)", _JNME_MalformedMultiDotThrows)

_JNME_BareExponentThrows() {
	Msg := _JNME_CaptureThrowMessage("1e")
	Assert(Msg != "", "JsonParse('1e') must throw — exponent with no digits is not valid JSON")
	Assert(InStr(Msg, "JSON") > 0,
		"Malformed '1e' must throw a JSON-position error — got: " . Msg)
}
Test("JSON parser: malformed '1e' throws JSON-position error (full-regex guard)", _JNME_BareExponentThrows)
