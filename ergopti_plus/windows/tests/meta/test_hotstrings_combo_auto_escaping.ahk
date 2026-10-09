; tests/meta/test_hotstrings_combo_auto_escaping.ahk

; ==============================================================================
; MODULE: Personal-Info Combo Escaping Meta Test
; DESCRIPTION:
; Static source guard: every path that turns a personal_info field into typed
; text must route the value through SendEscapeLiteral.
;
; ROOT CAUSE ENCODED:
; The combo expansion is registered with OnlyText:False (Send-key mode), so the
; value is interpreted, not typed. A "+" in an email address — a Gmail plus-tag
; such as user+tag@example.com — reads as Shift; a "^" reads as Ctrl; a "{"
; opens a key name. The value is the user's own data, so the failure is silent
; and personal: the wrong text lands in someone's form.
;
; WHY IT STILL EXISTS AFTER THE REWRITE:
; It used to guard CreateHotstringComboAuto, a hand-written list of thirty-one
; registrations that no longer exists — every multi-letter combo is now resolved
; at fire time by HSE_TryPersonalInfoCombo. The FUNCTION changed; the defect it
; guards did not, so the guard moved rather than being deleted. The escaping
; itself is exercised behaviourally in
; tests/unit/test_personal_info_combo_resolver.ahk; what this file adds is that
; no producer quietly stops calling it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Every producer routes through the escaper =======
; ============================================================
; ============================================================

_HSCAEscapingApplied() {
	; The fire-time resolver: the path every combo longer than
	; pattern_max_length now takes.
	FnBody := _DriverFuncBody("HSE_TryPersonalInfoCombo")
	Assert(FnBody != "",
		"infra/hotstrings/hotstring_engine_main.ahk must define HSE_TryPersonalInfoCombo(MagicKey) — it is the only thing that expands a multi-letter @-combo since the hand-written list was removed")
	Assert(InStr(FnBody, "SendEscapeLiteral(") > 0,
		"HSE_TryPersonalInfoCombo must pass each field value through SendEscapeLiteral: it registers the expansion with OnlyText:False, so a '+' in an email address is read as Shift and the user's own address is typed wrong")

	; The registration path for the short combos (pattern_max_length) still
	; exists and reaches the same Send-key mode, so it needs the same treatment.
	GenBody := _DriverFuncBody("Generate")
	Assert(GenBody != "",
		"modules/hotstrings/hotstrings_text_expansion.ahk must define Generate() — the registration path for combos up to pattern_max_length")
	Assert(InStr(GenBody, "EscapeSpecialChars(") > 0,
		"Generate() must escape the concatenated value before registering it (EscapeSpecialChars delegates to SendEscapeLiteral)")
}
Test("hotstrings: every personal-info combo producer escapes its field values (F17 regression)",
	_HSCAEscapingApplied)


; The delegation itself. EscapeSpecialChars keeping its own copy of the
; transform is how the two producers would drift apart again — one fixed, one
; not — which is the whole reason the body moved to infra/text_utils.ahk.
_HSCAEscapeIsSingleSourced() {
	FnBody := _DriverFuncBody("EscapeSpecialChars")
	Assert(FnBody != "",
		"modules/hotstrings/hotstrings_text_expansion.ahk must still define EscapeSpecialChars(text)")
	Assert(InStr(FnBody, "SendEscapeLiteral(") > 0,
		"EscapeSpecialChars must delegate to SendEscapeLiteral rather than reimplement the escaping — two copies is how the registration path and the fire-time path come to disagree about what a '{' means")
	Assert(!InStr(FnBody, "{Asc 94}"),
		"and it must not keep the old inline transform alongside the delegation: a second copy that is never called is a second copy someone will edit")
}
Test("hotstrings: the combo escaper is single-sourced in infra/text_utils.ahk",
	_HSCAEscapeIsSingleSourced)
