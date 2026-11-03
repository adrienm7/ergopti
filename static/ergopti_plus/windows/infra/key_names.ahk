; infra/key_names.ahk

; ==============================================================================
; MODULE: Key Names
; DESCRIPTION:
; Names a keyboard key or modifier in visible text, from the one table every
; driver shares (_shared/data/keycodes/key_names.json, its windows column
; projected to _generated/key_names.ahk). Port of
; _shared/lua/keycodes/key_names.lua. A row used to print the id itself
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
