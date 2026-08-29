; infra/number.ahk

; ==============================================================================
; MODULE: Numeric Representation Boundaries
; DESCRIPTION:
; Shared fail-closed conversion helpers for decimal values parsed from external
; text formats. AutoHotkey wraps overflowing integers modulo 2^64 and represents
; overflowing floats as infinity, so callers must validate before publication.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Decimal Conversion =======
; =====================================
; =====================================

/** Parses a decimal integer only when it fits the signed 64-bit domain. */
NumberTryParseSignedInteger(Raw, &Value) {
	Value := ""
	if !RegExMatch(Raw, "^-?\d+$")
		return false
	Negative := SubStr(Raw, 1, 1) == "-"
	Digits := Negative ? SubStr(Raw, 2) : Raw
	Significant := LTrim(Digits, "0")
	if (Significant == "")
		Significant := "0"
	Limit := Negative ? "9223372036854775808" : "9223372036854775807"
	if (StrLen(Significant) > StrLen(Limit)
			or (StrLen(Significant) == StrLen(Limit)
			and StrCompare(Significant, Limit) > 0))
		return false
	Value := Integer(Raw)
	return true
}

/** Parses a decimal float only when AutoHotkey can represent it as finite. */
NumberTryParseFiniteFloat(Raw, &Value) {
	static MaxFinite := 1.7976931348623157e+308
	Value := ""
	try Candidate := Float(Raw)
	catch
		return false
	if !(Candidate >= -MaxFinite and Candidate <= MaxFinite)
		return false
	Value := Candidate
	return true
}
