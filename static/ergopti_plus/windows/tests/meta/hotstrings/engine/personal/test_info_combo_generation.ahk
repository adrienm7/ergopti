; tests/meta/hotstrings/engine/personal/test_info_combo_generation.ahk

; ==============================================================================
; MODULE: Personal-info @letter combo generator iterates Map keys
; DESCRIPTION:
; GeneratePersonalInformationHotstrings seeds its combo alphabet from the
; PersonalInformationHotstrings MAP, whose KEYS are the alias letters (n, t, ...)
; and whose VALUES are the personal data. A mechanical `for _, k` (Array-style)
; rewrite once bound the VALUES into the letter list, so every @<letter> combo
; went dead and garbage triggers were built from personal data. The generator is
; a closure nested in modules/ (outside the run_all include graph), so this is a
; source-scan guard on the loop's variable order (F09, audit 2026-07-20).
; ==============================================================================

#Requires AutoHotkey v2.0

_PICG_SeedLoopIteratesMapKeys() {
	Body := _DriverFuncBody("GeneratePersonalInformationHotstrings")
	Assert(Body != "",
		"GeneratePersonalInformationHotstrings must exist in hotstrings/engine/catalogue/text_expansion.ahk")
	; The seeding loop must bind the KEY (first Map enumerator var) and push it.
	KeyForm := InStr(Body, "for k, _ in hotstrings")
	ValueForm := InStr(Body, "for _, k in hotstrings")
	Push := InStr(Body, "keys.Push(k)")
	Assert(KeyForm > 0,
		"combo alphabet must be seeded from Map KEYS (for k, _ in hotstrings), not values")
	Assert(ValueForm = 0,
		"the value-binding 'for _, k in hotstrings' rewrite re-introduces the dead-combo bug")
	Assert(Push > KeyForm,
		"keys.Push(k) must push the key bound by the first (key) loop variable")
}
Test("personal-info combos: alphabet seeded from Map keys, not values", _PICG_SeedLoopIteratesMapKeys)

; PIW-001: the eager generator used to join the raw values with {Tab} and escape
; the WHOLE string, which neutralised the separators as well (a literal
; LEFT{Tab}RIGHT in one field), and it registered a combo with a missing field.
; The fire-time resolver escapes each value and keeps the separator live, and it
; declines the whole combo when any field is empty.
_PICG_GeneratorEscapesEachValueAndDeclinesEmpty() {
	Body := _StripFullLineComments(_DriverFuncBody("Generate"))
	Assert(Body != "", "Generate() must exist in hotstrings/engine/catalogue/text_expansion.ahk")
	Assert(InStr(Body, "EscapeSpecialChars(hotstrings[A_LoopField])") > 0,
		"Generate() must escape each field value on its own")
	Assert(InStr(Body, "EscapeSpecialChars(value)") = 0,
		"Generate() must not escape the joined string: that also escapes the {Tab} separators")
	TabPos := InStr(Body, "{Tab}")
	EscapePos := InStr(Body, "EscapeSpecialChars(hotstrings[A_LoopField])")
	Assert(TabPos > 0 && TabPos < EscapePos,
		"the separator must be appended unescaped, before the next escaped value")
	Assert(InStr(Body, "hotstrings[A_LoopField] == " . Chr(34) . Chr(34)) > 0,
		"an empty field must decline the whole combo, as the fire-time resolver does")
	Assert(InStr(Body, "Complete := false") > 0 && InStr(Body, "if (Complete and value != " . Chr(34) . Chr(34) . ")") > 0,
		"an incomplete combo must not be registered")
}
Test("personal-info combos: registered compounds escape per value and decline empty fields (PIW-001)", _PICG_GeneratorEscapesEachValueAndDeclinesEmpty)
