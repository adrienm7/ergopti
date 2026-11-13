; infra/key_names.ahk

; ==============================================================================
; MODULE: Key Names
; DESCRIPTION:
; Names a keyboard key or modifier in visible text, from the one table every
; driver shares (_shared/layouts/data/keycodes/key_names.json, its windows column
; projected to _generated/key_names.ahk). Port of
; _shared/platform/input/keycodes/key_names.lua. A row used to print the id itself
; (`lalt`, `caps_lock`) or an abbreviation no locale translated (`LCtrl`).
;
; FEATURES & RATIONALE:
; 1. One id, every spelling: `left_control`, `lctrl` and `LCtrl` all name
;    left_ctrl, matched without regard to case.
; 2. Fail fast: an unknown id or an empty text throws, so a row never falls
;    back to the id it was meant to hide.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\key_names.ahk

; The key id a spelling names, or "" when the table has none.
; @param Spelling {String} Any id or alias, in any case.
; @returns {String}
KeyNameCanonical(Spelling) {
	if !(Spelling is String)
		return ""
	Lower := StrLower(Spelling)
	Data := KeyNamesData()
	if Data["keys"].Has(Lower)
		return Lower
	return Data["aliases"].Has(Lower) ? Data["aliases"][Lower] : ""
}

; The locale key naming one key on Windows.
; @param Spelling {String} Any id or alias.
; @returns {String}
KeyNameI18n(Spelling) {
	Id := KeyNameCanonical(Spelling)
	if (Id == "")
		throw ValueError("The key name table has no such key.", -1, Spelling)
	return KeyNamesData()["keys"][Id]
}

; The translated name of one key.
; @param Spelling {String} Any id or alias.
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNameLabel(Spelling, Translate := "") {
	; A catalogue miss comes back as the dotted key, like every other label (t()
	; logs it): the locale gates and the tray walk refuse it, never the id.
	Key := KeyNameI18n(Spelling)
	Text := Translate == "" ? t(Key) : Translate.Call(Key)
	if (Text == "")
		throw ValueError("A key name has no text.", -1, Key)
	return Text
}

; The translated names of a combination such as "ctrl+shift", joined with
; " + " in the order written.
; @param Combo {String} Ids or aliases joined with "+".
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNameComboLabel(Combo, Translate := "") {
	Out := ""
	for _, Part in StrSplit(Combo, "+") {
		Clean := Trim(Part)
		if (Clean == "")
			continue
		Out .= (Out == "" ? "" : " + ") . KeyNameLabel(Clean, Translate)
	}
	if (Out == "")
		throw ValueError("An empty key combination has no name.", -1, Combo)
	return Out
}

; How one modifier-chord action of modifier_chords.json reads: its modifiers'
; names, then its key (« Ctrl + Maj + Entrée »). A key the table names carries
; key_name; any other prints its legend (A, 1, .), the same in every language.
; Port of key_names.lua chord_label.
; @param Modifiers {Array} Ids or aliases, in display order.
; @param KeyDef {Map} A key of modifier_chords.json, with key_name or label.
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNameChordLabel(Modifiers, KeyDef, Translate := "") {
	if !(Modifiers is Array) || (Modifiers.Length == 0)
		throw ValueError("A modifier set must not be empty.", -1)
	if !(KeyDef is Map)
		throw ValueError("A chord needs its key.", -1)
	if KeyDef.Has("key_name")
		KeyText := KeyNameLabel(KeyDef["key_name"], Translate)
	else if KeyDef.Has("label") && (KeyDef["label"] is String) && (KeyDef["label"] != "")
		KeyText := KeyDef["label"]
	else
		throw ValueError("A chord key has neither key_name nor label.", -1, KeyDef.Has("id") ? KeyDef["id"] : "")
	return KeyNameModifiersLabel(Modifiers, Translate) . " + " . KeyText
}

; The translated names of a set of modifiers, joined with " + " in the order
; given (« Ctrl + Maj »). Port of key_names.lua modifiers_label.
; @param Modifiers {Array} Ids or aliases, in display order.
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNameModifiersLabel(Modifiers, Translate := "") {
	if !(Modifiers is Array) || (Modifiers.Length == 0)
		throw ValueError("A modifier set must not be empty.", -1)
	Out := ""
	for _, Modifier in Modifiers
		Out .= (Out == "" ? "" : " + ") . KeyNameLabel(Modifier, Translate)
	return Out
}

; Fills the {1} of a translated template with one value. A catalogue miss
; comes back as the dotted key, like every other label, so the locale gates and
; the tray walk refuse it; a template without {1} throws.
; @param Key {String} The locale key of the template.
; @param Value {String} The text {1} stands for.
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNameFill(Key, Value, Translate := "") {
	if !(Value is String) || (Value == "")
		throw ValueError("A key name template needs a value.", -1, Key)
	Template := Translate == "" ? t(Key) : Translate.Call(Key)
	if (Template == Key)
		return Template
	if !InStr(Template, "{1}")
		throw ValueError("A key name template does not hold {1}.", -1, Key)
	return StrReplace(Template, "{1}", Value)
}

; How one physical position reads in a row: KeyA as A, Digit1 as 1, F5 as F5,
; a sign position as its legend, a numpad position as « Pavé num. 7 », any
; other code as the key it names. Port of key_names.lua physical_label.
; @param Code {String} A W3C code of physical_keys.json.
; @param Translate {Func} The lookup, when a caller injects one; t by default.
; @returns {String}
KeyNamePhysicalLabel(Code, Translate := "") {
	if !(Code is String)
		throw TypeError("A physical code must be a string.", -1)
	if RegExMatch(Code, "^Key([A-Z])$", &Letter) || RegExMatch(Code, "^Digit(\d)$", &Letter)
		return Letter[1]
	if RegExMatch(Code, "^F\d\d?$")
		return Code
	Legends := KeyNamesData()["legends"]
	Legend := Legends.Has(Code) ? Legends[Code] : ""
	if RegExMatch(Code, "^Numpad(.+)$", &Pad) {
		Inner := RegExMatch(Pad[1], "^\d$") ? Pad[1] : Legend
		if (Inner == "" && KeyNameCanonical(Pad[1]) != "")
			Inner := KeyNameLabel(Pad[1], Translate)
		if (Inner == "")
			throw ValueError("The key name table has no name for this physical key.", -1, Code)
		Template := KeyNamesData()["numpad"]
		Text := Translate == "" ? t(Template) : Translate.Call(Template)
		; A catalogue miss shows its dotted key, like every other label.
		if (Text == Template)
			return Text . " " . Inner
		if !InStr(Text, "{1}")
			throw ValueError("A key name template does not hold {1}.", -1, Template)
		return StrReplace(Text, "{1}", Inner)
	}
	if (Legend != "")
		return Legend
	if (KeyNameCanonical(Code) == "")
		throw ValueError("The key name table has no name for this physical key.", -1, Code)
	return KeyNameLabel(Code, Translate)
}
