; tests/meta/test_personal_combo_letters_guard.ahk

; ==============================================================================
; MODULE: Personal-info auto-combo guards the user-editable letters Map
; DESCRIPTION:
; CreateHotstringComboAuto builds fixed combos ("mm", "npdmmt", ...) that require
; the letters {m,n,p,a,d,t} to exist in PersonalInformationHotstrings. That Map is
; user-editable (personal_info.toml [letters]); removing a letter made the raw
; index throw UnsetItemError on the boot-critical registration thread, which the
; fatal-before-ready error net escalates to ExitApp(1) -- a persistent boot brick.
; The sibling Generate() already guards with .Has(); this asserts the auto variant
; does too, before its first raw index (F10, audit 2026-07-20).
; ==============================================================================

#Requires AutoHotkey v2.0

_PCLG_AutoComboGuardsMissingLetter() {
	Body := _DriverFuncBody("CreateHotstringComboAuto")
	Assert(Body != "",
		"CreateHotstringComboAuto must exist in modules/hotstrings/hotstrings_text_expansion.ahk")
	HasGuard := InStr(Body, "PersonalInformationHotstrings.Has(")
	FirstIndex := InStr(Body, "PersonalInformationHotstrings[")
	Assert(HasGuard > 0,
		"CreateHotstringComboAuto must guard the user-editable letters Map with .Has() before indexing")
	Assert(FirstIndex > 0,
		"CreateHotstringComboAuto must still index the letters Map to build the combo value")
	Assert(HasGuard < FirstIndex,
		"the .Has() guard must precede the first raw PersonalInformationHotstrings[...] index")
}
Test("personal-info auto-combos: missing letter skipped, never a boot-killing throw", _PCLG_AutoComboGuardsMissingLetter)
