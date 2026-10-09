; infra/wrap_pair.ahk

; ==============================================================================
; MODULE: Wrap Pair Parameter
; DESCRIPTION:
; Resolves the wrap_pair parameter of the wrap_selection action to the left and
; right symbols it names: a symbol of the built-in catalogue
; (_shared/modules/wrap_symbols/wrap_symbols.json, opening or closing) or a
; custom pair written left|right. Pure, so the unit suite replays the shared
; corpus _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, which the
; macOS and Linux suites replay against _shared/lua/wrap_pair too.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Wrap pair parse =======
; ==================================
; ==================================

; The separator of a custom pair.
global WRAP_PAIR_SEPARATOR := "|"

; Whitespace a stored value is trimmed of, as Lua's %s does on the other drivers.
global WRAP_PAIR_TRIM := " `t`r`n`v`f"

; Resolves a stored value against the ordered catalogue pairs.
; @param {String} Value The stored parameter.
; @param {Array} Pairs Ordered catalogue pairs, each Map("left", ..., "right", ...).
; @returns {Map|String} Map("left", ..., "right", ...), or "" when the value names no pair.
WrapPairParse(Value, Pairs) {
	global WRAP_PAIR_SEPARATOR, WRAP_PAIR_TRIM
	if !(Value is String) || !(Pairs is Array)
		return ""
	Wanted := Trim(Value, WRAP_PAIR_TRIM)
	if (Wanted == "" || InStr(Wanted, "`n") || InStr(Wanted, "`r"))
		return ""
	for _, Field in ["left", "right"] {
		for _, Pair in Pairs {
			if (Pair is Map) && Pair.Has(Field) && Trim(Pair[Field], WRAP_PAIR_TRIM) == Wanted
				return Map("left", Pair["left"], "right", Pair["right"])
		}
	}
	At := InStr(Wanted, WRAP_PAIR_SEPARATOR, true)
	if (At = 0 || InStr(Wanted, WRAP_PAIR_SEPARATOR, true, At + 1))
		return ""
	Left := SubStr(Wanted, 1, At - 1)
	Right := SubStr(Wanted, At + 1)
	if (Trim(Left, WRAP_PAIR_TRIM) == "" || Trim(Right, WRAP_PAIR_TRIM) == "")
		return ""
	return Map("left", Left, "right", Right)
}

; The catalogue as one line of "left…right" samples, for the prompt that asks
; for the value.
; @param {Array} Pairs Ordered catalogue pairs.
; @returns {String}
WrapPairDescribe(Pairs) {
	global WRAP_PAIR_TRIM
	Text := ""
	for _, Pair in Pairs {
		if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
			continue
		Text .= (Text = "" ? "" : "   ")
			. Trim(Pair["left"], WRAP_PAIR_TRIM) . "…" . Trim(Pair["right"], WRAP_PAIR_TRIM)
	}
	return Text
}
