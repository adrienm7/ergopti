; tests/meta/test_personal_combo_letters_guard.ahk

; ==============================================================================
; MODULE: Personal-info combos guard the user-editable letters Map
; DESCRIPTION:
; The [letters] section of personal_info.toml is user-editable, and so is the
; field list it points into. Indexing either one raw throws UnsetItemError, and
; the combo path runs on the boot-critical registration thread where the
; fatal-before-ready error net escalates that to ExitApp(1) — a persistent boot
; brick from deleting one line of one's own config.
;
; WHY IT NO LONGER NAMES CreateHotstringComboAuto:
; that function was a hand-written list of thirty-one combos and is gone; every
; multi-letter combo is now resolved at fire time. The failure mode did not go
; with it — it MOVED, from the boot thread to the keystroke thread, where an
; UnsetItemError is thrown inside the InputHook callback. So the guard follows
; the code rather than being deleted with the function it used to name.
;
; Behavioural coverage of the same contract (an unknown letter or a blank field
; declines the combo instead of throwing) lives in
; tests/unit/test_personal_info_combo_resolver.ahk. What this file adds is that
; the guard cannot be removed while the tests keep passing on fixtures that
; happen to be complete.
; ==============================================================================

#Requires AutoHotkey v2.0

; The letters→fields resolver, shared by the bubble and the expansion.
_PCLG_TagResolverGuardsMissingLetter() {
	Body := _DriverFuncBody("_PIPreviewFieldsForTag")
	Assert(Body != "",
		"infra/personal_info_preview.ahk must define _PIPreviewFieldsForTag(Tag) — it is what turns @<letters> into a field list for BOTH the bubble and the fire-time resolver")
	HasGuard := InStr(Body, "PersonalInformationLetters.Has(")
	FirstIndex := InStr(Body, "PersonalInformationLetters[")
	Assert(HasGuard > 0,
		"_PIPreviewFieldsForTag must guard the user-editable letters Map with .Has() before indexing it")
	Assert(FirstIndex > 0,
		"and must still index it to build the field list")
	Assert(HasGuard < FirstIndex,
		"the .Has() guard must precede the first raw PersonalInformationLetters[...] index")
}
Test("personal-info combos: the letters Map is guarded before it is indexed", _PCLG_TagResolverGuardsMissingLetter)


; The fields Map, on the path that now runs per keystroke rather than at boot.
_PCLG_ResolverGuardsMissingField() {
	Body := _DriverFuncBody("HSE_TryPersonalInfoCombo")
	Assert(Body != "",
		"infra/hotstrings/hotstring_engine_main.ahk must define HSE_TryPersonalInfoCombo(MagicKey)")
	HasGuard := InStr(Body, "PersonalInformation.Has(")
	FirstIndex := InStr(Body, "PersonalInformation[")
	Assert(HasGuard > 0,
		"HSE_TryPersonalInfoCombo must guard PersonalInformation with .Has() before indexing: a letter can alias a field the user has not filled in, and this runs inside the InputHook callback where the throw is not merely a failed expansion")
	Assert(FirstIndex > 0,
		"and must still index it to build the replacement")
	Assert(HasGuard < FirstIndex,
		"the .Has() guard must precede the first raw PersonalInformation[...] index")
}
Test("personal-info combos: the fields Map is guarded on the keystroke path", _PCLG_ResolverGuardsMissingField)
