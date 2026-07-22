; tests/meta/test_hotstrings_combo_auto_escaping.ahk

; ==============================================================================
; MODULE: Hotstrings CreateHotstringComboAuto Escaping Meta Test
; DESCRIPTION:
; Static source guard for the "CreateHotstringComboAuto missing per-field
; escaping" audit finding (F17) in modules/hotstrings.ahk.
;
; ROOT CAUSE ENCODED:
; CreateHotstringComboAuto built the expansion value by concatenating raw
; PersonalInformationHotstrings[ComboLetter] with "{Tab}" and registered the
; result with OnlyText:False (Send-key mode). No escaping was applied. A '+'
; in an email address (Gmail plus-tag such as user+tag@example.com) would be
; interpreted by AHK Send as a Shift modifier rather than a literal plus sign.
;
; The fix adds EscapeSpecialChars() around each field value inside the loop.
;
; This test verifies that the loop body in CreateHotstringComboAuto calls
; EscapeSpecialChars() on each field before concatenating it into Value.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================================================
; =======================================================================
; ======= 1/ CreateHotstringComboAuto contains EscapeSpecialChars =======
; =======================================================================
; =======================================================================

_HSCAEscapingApplied() {
	; Locate the CreateHotstringComboAuto function body and verify EscapeSpecialChars(
	; is applied to each field value inside it.
	FnBody := _DriverFuncBody("CreateHotstringComboAuto")
	Assert(FnBody != "", "modules/hotstrings.ahk must define CreateHotstringComboAuto(Combo)")

	Assert(InStr(FnBody, "EscapeSpecialChars(") > 0,
		"CreateHotstringComboAuto must call EscapeSpecialChars() on each field value (F17 regression guard)")
}
Test("hotstrings: CreateHotstringComboAuto applies EscapeSpecialChars per field  (F17 regression)", _HSCAEscapingApplied)
