; tests/meta/test_toml_render_bool_sentinel.ahk

; ==============================================================================
; MODULE: TOML Boolean Sentinel Render Test
; DESCRIPTION:
; Regression guard for the TOML_Bool sentinel pattern in TOML_RenderValue.
;
; AHK v2 has no distinct boolean type: `true` IS integer 1 and `false` IS 0.
; IsNumber(true) returns a truthy value and String(true) returns "1". When
; TOML_RenderValue checked IsNumber() before the boolean branches, any caller
; passing a real AHK boolean got "1"/"0" in the output file instead of the
; TOML literals "true"/"false". This made config.toml non-canonical and broke
; consumers (macOS driver, user editor, spec-strict parsers) that expect
; proper TOML booleans.
;
; The fix adds a TOML_Bool sentinel class and checks `v is TOML_Bool` BEFORE
; the IsNumber() branch in TOML_RenderValue. Call sites that know a value is
; boolean (category_enabled entries, metrics flags) wrap it in TOML_Bool().
;
; This test asserts:
;   (a) TOML_Bool(true) renders as "true" and TOML_Bool(false) as "false".
;   (b) TOML_Bool(0) renders as "false" (coercion via AHK truthiness).
;   (c) Plain integer 0 (no wrapper) still renders as "0", not "false".
;   (d) Plain integer 1 still renders as "1", not "true".
;
; SCOPE: runtime exercise of TOML_RenderValue and TOML_Bool class.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Test implementations ================
; ================================================
; ================================================

_TRBS_CheckBoolTrueRendered() {
	Result := TOML_RenderValue(TOML_Bool(true))
	Assert(Result == "true",
		"TOML_Bool(true) must render as 'true' not '" . Result . "'")
}

_TRBS_CheckBoolFalseRendered() {
	Result := TOML_RenderValue(TOML_Bool(false))
	Assert(Result == "false",
		"TOML_Bool(false) must render as 'false' not '" . Result . "'")
}

_TRBS_CheckBoolZeroRendered() {
	Result := TOML_RenderValue(TOML_Bool(0))
	Assert(Result == "false",
		"TOML_Bool(0) must render as 'false' not '" . Result . "'")
}

_TRBS_CheckPlainIntPreserved() {
	Result0 := TOML_RenderValue(0)
	Assert(Result0 == "0",
		"Plain integer 0 must still render as '0' not '" . Result0 . "'")

	Result1 := TOML_RenderValue(1)
	Assert(Result1 == "1",
		"Plain integer 1 must still render as '1' not '" . Result1 . "'")
}


Test("toml_bool_sentinel: TOML_Bool(true) renders as TOML literal 'true'",
	_TRBS_CheckBoolTrueRendered)

Test("toml_bool_sentinel: TOML_Bool(false) renders as TOML literal 'false'",
	_TRBS_CheckBoolFalseRendered)

Test("toml_bool_sentinel: TOML_Bool(0) coerces to false and renders as 'false'",
	_TRBS_CheckBoolZeroRendered)

Test("toml_bool_sentinel: plain integer 0 and 1 still render as '0' and '1' without wrapper",
	_TRBS_CheckPlainIntPreserved)
