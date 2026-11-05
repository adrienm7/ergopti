; infra/number.ahk

; ==============================================================================
; MODULE: Numeric Representation Boundaries
; DESCRIPTION:
; Shared fail-closed conversion helpers for numeric values parsed from external
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

/**
 * Parses the native integer-input grammar without accepting its modulo wrap.
 * Leading sign/whitespace, hexadecimal and decimal zero padding stay valid;
 * the magnitude must fit the signed native domain before Integer is called.
 */
NumberTryParseInputInteger(Raw, &Value) {
	Value := ""
	if Raw is Integer {
		Value := Raw
		return true
	}
	if !(Raw is String) || !IsInteger(Raw)
		return false
	Text := Trim(Raw, " `t`r`n`v`f")
	Negative := SubStr(Text, 1, 1) == "-"
	if Negative || SubStr(Text, 1, 1) == "+"
		Text := SubStr(Text, 2)
	if !RegExMatch(Text, "i)^0x([0-9a-f]+)$", &Hex)
		return NumberTryParseSignedInteger((Negative ? "-" : "") . Text, &Value)
	Digits := StrUpper(LTrim(Hex[1], "0"))
	if Digits == ""
		Digits := "0"
	Limit := Negative ? "8000000000000000" : "7FFFFFFFFFFFFFFF"
	if StrLen(Digits) > StrLen(Limit)
			|| (StrLen(Digits) == StrLen(Limit) && StrCompare(Digits, Limit, true) > 0)
		return false
	Value := Integer((Negative ? "-" : "") . "0x" . Digits)
	return true
}
