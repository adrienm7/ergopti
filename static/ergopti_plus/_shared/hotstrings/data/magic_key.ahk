; _shared/hotstrings/data/magic_key.ahk

; ==============================================================================
; MODULE: Shared Magic Key Character Rules
; DESCRIPTION:
; Portable AHK twin of _shared/hotstrings/engine/magic_key.lua. The magic key
; is a configured character, never a physical key position (maintainer's
; decision of 2026-11-21): its default follows the layout that types (« ù » on
; AZERTY, « ; » on QWERTY, the manifest default elsewhere) and every
; user-facing text shows « ★ (configured character) ». Both implementations
; read _shared/hotstrings/data/magic_key.json and replay
; _shared/tests/corpus/hotstrings/magic_key_vectors.json.
; ==============================================================================





; ==================================
; ==================================
; ======= 1/ Data validation =======
; ==================================
; ==================================

/**
 * Validates the parsed magic_key.json and indexes its literal marker keys.
 * @param {Map} Data Parsed _shared/hotstrings/data/magic_key.json.
 * @returns {Map} "marker", "display_format", "layout_families" and "literal" (key → true).
 * @throws {TypeError} When a field is missing or malformed.
 */
MagicKeyRules(Data) {
	if !(Data is Map) || !(Data.Get("marker", "") is String) || Data.Get("marker", "") == ""
		throw TypeError("Magic key rules: the marker is missing.")
	Format := Data.Get("display_format", "")
	if !(Format is String) || !InStr(Format, "{char}", true)
		throw TypeError("Magic key rules: the display format lacks its {char} placeholder.")
	Families := Data.Get("layout_families", 0)
	if !(Families is Array)
		throw TypeError("Magic key rules: the layout families are missing.")
	for Family in Families {
		if !(Family is Map) || !(Family.Get("base", 0) is Map) || Family["base"].Count == 0
				|| !(Family.Get("default_char", "") is String) || Family["default_char"] == ""
			throw TypeError("Magic key rules: a layout family lacks its base keys or magic key.")
	}
	Keys := Data.Get("literal_marker_keys", 0)
	if !(Keys is Array)
		throw TypeError("Magic key rules: the literal marker keys are missing.")
	Literal := Map()
	for Key in Keys {
		if !(Key is String) || Key == ""
			throw TypeError("Magic key rules: a literal marker key is not a key.")
		Literal[Key] := true
	}
	return Map("marker", Data["marker"], "display_format", Format, "layout_families", Families,
		"literal", Literal)
}





; =================================
; =================================
; ======= 2/ Layout default =======
; =================================
; =================================

/**
 * The default magic key of the layout that types.
 * @param {Map} Rules Result of MagicKeyRules.
 * @param {Func} BaseTextOf (Code) → what the key types with no modifier, "" for nothing.
 * @param {String} Fallback The manifest default of hotstrings.trigger_char.
 * @returns {Map} "char" and "family" ("" for the fallback).
 */
MagicKeyLayoutDefault(Rules, BaseTextOf, Fallback) {
	if !(Fallback is String) || Fallback == ""
		throw TypeError("Magic key rules: the manifest default is missing.")
	for Family in Rules["layout_families"] {
		Matches := true
		for Code, Char in Family["base"] {
			if !(BaseTextOf.Call(Code) == Char) {
				Matches := false
				break
			}
		}
		if Matches
			return Map("char", Family["default_char"], "family", Family["id"])
	}
	return Map("char", Fallback, "family", "")
}





; ==========================
; ==========================
; ======= 3/ Display =======
; ==========================
; ==========================

/**
 * How the magic key is shown: the marker alone when it is the marker, else the
 * marker followed by the configured character.
 * @param {Map} Rules Result of MagicKeyRules.
 * @param {String} Char Configured magic key.
 * @returns {String}
 */
MagicKeyDisplay(Rules, Char) {
	if !(Char is String) || Char == ""
		throw TypeError("Magic key rules: the configured character is missing.")
	if Char == Rules["marker"]
		return Char
	return StrReplace(Rules["display_format"], "{char}", Char, true, , 1)
}

/**
 * Replaces every marker of a user-facing text by the magic key's display.
 * @param {Map} Rules Result of MagicKeyRules.
 * @param {String} Text Text written with the real marker.
 * @param {String} Char Configured magic key.
 * @param {String} Key Locale key of the text, "" for none; a literal marker key keeps its ★.
 * @returns {String}
 */
MagicKeyDisplayText(Rules, Text, Char, Key := "") {
	if Key != "" && Rules["literal"].Has(Key)
		return Text
	Shown := MagicKeyDisplay(Rules, Char)
	if Shown == Rules["marker"]
		return Text
	return StrReplace(Text, Rules["marker"], Shown, true)
}
