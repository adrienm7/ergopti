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
