; tests/meta/test_personal_info_combo_generation.ahk

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
		"GeneratePersonalInformationHotstrings must exist in modules/hotstrings/hotstrings_text_expansion.ahk")
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
