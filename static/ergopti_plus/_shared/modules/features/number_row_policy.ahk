; _shared/modules/features/number_row_policy.ahk

; ==============================================================================
; MODULE: Number Row Policy
; DESCRIPTION:
; Validates number-row intent and source-scoped capability. Native adapters retain
; physical descriptors, emission, persistence and lifecycle ownership.
; ==============================================================================

#Requires AutoHotkey v2.0




/** Returns canonical intent, or an empty string for an unclaimed value. */
NumberRowPolicyMode(Value) {
	if !(Value is String)
		return ""
	for Mode in ["native", "digits", "symbols"] {
		if StrCompare(Value, Mode, true) == 0
			return Mode
	}
	return ""
}

_NumberRowPolicyDescriptor(Value) {
	return Value is Map && Value.Get("Kind", "") is String && ((StrCompare(Value.Get("Kind", ""), "text", true) == 0
		&& Value.Get("Text", "") is String && Value.Get("Text", "") != "")
		|| (StrCompare(Value.Get("Kind", ""), "dead", true) == 0
		&& Value.Get("Action", "") is String && Value.Get("Action", "") != ""
		&& Value.Get("State", "") is String && Value.Get("State", "") != ""
		&& Value.Get("Text", "") is String && Value.Get("Text", "") != ""))
}

/** Returns {supported, shift}; emission still uses the original source index. */
NumberRowPolicySymbolsShift(Digit, Plain, Shifted) {
	Refused := Map("supported", false, "shift", false)
	if !(Digit is String) || !RegExMatch(Digit, "^[0-9]$")
			|| !_NumberRowPolicyDescriptor(Plain) || !_NumberRowPolicyDescriptor(Shifted)
		return Refused
	PlainDigit := StrCompare(Plain["Kind"], "text", true) == 0 && StrCompare(Plain["Text"], Digit, true) == 0
	ShiftDigit := StrCompare(Shifted["Kind"], "text", true) == 0 && StrCompare(Shifted["Text"], Digit, true) == 0
	return PlainDigit == ShiftDigit ? Refused : Map("supported", true, "shift", PlainDigit)
}

; What one level of a row key holds: "d" its own digit, "s" another character
; or a dead key, "n" nothing.
_NumberRowPolicyLevelClass(Digit, Value) {
	if !_NumberRowPolicyDescriptor(Value)
		return "n"
	return StrCompare(Value["Kind"], "text", true) == 0 && Value["Text"] == Digit ? "d" : "s"
}

/**
 * Which ordering options can make the row's base level differ from its Shift
 * level, from what the ten digit keys of the effective layout hold.
 * "digits" is usable only when every key has a symbol unshifted and its digit
 * on Shift, "symbols" only when every key has its digit unshifted and a symbol
 * on Shift. A row whose keys disagree is "mixed": no option can reorder all
 * ten keys, so both are refused. "native" (the layout as it is) is always valid.
 * @param {Array} Levels Ten Map("plain", descriptor, "shift", descriptor), keys 1 to 0.
 * @returns {Map} "digits" and "symbols": "" when usable, else the refusal reason:
 *   already_digits_first, already_symbols_first, digits_on_both,
 *   symbols_on_both, no_digits, incomplete or mixed.
 */
NumberRowPolicyAvailability(Levels) {
	if !(Levels is Array) || Levels.Length != 10
		throw ValueError("The number-row availability needs the ten digit keys.")
	Classes := Map()
	for Index, Key in Levels {
		Digit := Mod(Index, 10) . ""
		Plain := Key is Map ? Key.Get("plain", 0) : 0
		Shift := Key is Map ? Key.Get("shift", 0) : 0
		Classes[_NumberRowPolicyLevelClass(Digit, Plain) . _NumberRowPolicyLevelClass(Digit, Shift)] := true
	}
	if Classes.Count != 1
		return Map("digits", "mixed", "symbols", "mixed")
	for Class in Classes {
		switch Class, true {
			case "sd": return Map("digits", "", "symbols", "already_symbols_first")
			case "ds": return Map("digits", "already_digits_first", "symbols", "")
			case "dd": return Map("digits", "digits_on_both", "symbols", "digits_on_both")
			case "ss": return Map("digits", "symbols_on_both", "symbols", "symbols_on_both")
			case "dn", "nd": return Map("digits", "incomplete", "symbols", "incomplete")
		}
	}
	return Map("digits", "no_digits", "symbols", "no_digits")
}

/**
 * The ordering that applies on the effective layout: the stored choice, or
 * "native" while that choice cannot reorder this layout (it stays stored and
 * applies again on a layout where it can).
 * @param {String} Mode Stored choice.
 * @param {Map} Availability NumberRowPolicyAvailability result.
 * @returns {Map} "mode" effective ordering, "reason" why the choice is inert ("" when not).
 */
NumberRowPolicyEffective(Mode, Availability) {
	Mode := NumberRowPolicyMode(Mode)
	if Mode == "" || Mode == "native"
		return Map("mode", "native", "reason", "")
	Reason := Availability[Mode]
	return Reason == "" ? Map("mode", Mode, "reason", "") : Map("mode", "native", "reason", Reason)
}

NumberRowPolicyCapable(Platform, Mode, Symbols) {
	if !(Platform is String) || NumberRowPolicyMode(Mode) == ""
		return false
	if StrCompare(Mode, "native", true) == 0
		return StrCompare(Platform, "ahk", true) == 0 || StrCompare(Platform, "hs", true) == 0 || StrCompare(Platform, "linux", true) == 0
	return StrCompare(Platform, "ahk", true) == 0 && (StrCompare(Mode, "digits", true) == 0 || ((Symbols is Integer) && Symbols == true))
}

_NumberRowPolicySource(Value) {
	return IsObject(Value) || ((Value is String) && Value != "")
		|| ((Value is Integer) && Value != 0)
}

NumberRowPolicyReady(Snapshot, Value) {
	if !(Snapshot is Map) || !Snapshot.Has("owner") || !Snapshot.Has("source")
			|| !(Snapshot["owner"] is Map) || !(Snapshot.Get("native_owner", 0) is Map)
			|| !(_NumberRowPolicySource(Snapshot["source"]))
			|| NumberRowPolicyMode(Snapshot.Get("mode", "")) == "" || NumberRowPolicyMode(Value) == ""
		return false
	for Field in ["generation", "lifecycle"] {
		Number := Snapshot.Get(Field, -1)
		if !(Number is Integer) || (Number < 0 || Number > 9007199254740991)
			return false
	}
	if !(Snapshot.Get("hkl", 0) is Integer) || Snapshot["hkl"] == 0
		return false
	for Field in ["master", "paused", "symbols", "blocked", "caps"] {
		Bool := Snapshot.Get(Field, -1)
		if !(Bool is Integer) || (Bool != true && Bool != false)
			return false
	}
	return Snapshot["master"] && !Snapshot["paused"] && !Snapshot["blocked"]
		&& NumberRowPolicyCapable(Snapshot.Get("platform", ""), Value, Snapshot["symbols"])
}

NumberRowPolicyIntent(Expected, Current, Value) {
	if !NumberRowPolicyReady(Expected, Value) || !NumberRowPolicyReady(Current, Value)
		return false
	for Field in ["owner", "source", "native_owner", "generation", "lifecycle", "hkl", "platform", "mode", "symbols", "caps"] {
		Left := Expected[Field], Right := Current[Field]
		if Type(Left) != Type(Right) || ((Left is String) ? StrCompare(Left, Right, true) != 0 : Left != Right)
			return false
	}
	return true
}
