; tests/meta/test_disable_password_fields_gate.ahk

; ==============================================================================
; MODULE: disable_password_fields Gate Meta Test
; DESCRIPTION:
; Regression guard for MED-02: fix-disable-password-fields-gate-unwired.
;
; The LLM prediction engine stored the disable_password_fields flag from config
; but never consulted SFD_IsSecureField() at prediction time. A user enabling
; the option via the tray menu had no effect — predictions still fired in
; password inputs.
;
; The fix adds a gate at the top of LLM_Engine_FirePrediction: when
; disable_password_fields is true and SFD_IsSecureField() returns true, the
; function returns early (prediction suppressed).
;
; A companion fix (LOW-02) adds a Win32-class guard in SFD_IsSecureField so
; that ES_PASSWORD (0x20) is only checked for Edit/RichEdit controls, not
; arbitrary controls whose style bits happen to overlap.
;
; This test asserts:
;   (a) LLM_Engine_FirePrediction body checks _LLM_Engine["disable_password_fields"]
;       AND calls SFD_IsSecureField before the first API/cache path.
;   (b) SFD_IsSecureField body checks control class (Edit/RichEdit) before
;       testing the style bit.
;
; SCOPE: source introspection of modules/llm/prediction_engine.ahk
;        and adapters/secure_field_detector.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_DPFG_CheckFirePredictionGate() {
	; Move-resilient: find the function body across the whole driver source
	Body := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(Body != "", "LLM_Engine_FirePrediction must be present in prediction_engine.ahk")

	; (a) Gate must check disable_password_fields flag
	Assert(InStr(Body, "disable_password_fields"),
		"LLM_Engine_FirePrediction must read _LLM_Engine[" . Chr(34) . "disable_password_fields" . Chr(34) . "] to gate on the flag (MED-02)")

	; (b) Gate must call SFD_IsSecureField
	Assert(InStr(Body, "SFD_IsSecureField()"),
		"LLM_Engine_FirePrediction must call SFD_IsSecureField() when disable_password_fields is enabled (MED-02)")

	; (c) Gate must appear before the first LLM API/cache dispatch path
	GatePos   := InStr(Body, "disable_password_fields")
	CachePos  := InStr(Body, "last_ctx")
	ApiPos    := InStr(Body, "LLM_Ollama")
	FirstPath := (CachePos > 0 && ApiPos > 0) ? Min(CachePos, ApiPos) : Max(CachePos, ApiPos)
	Assert(GatePos > 0 && FirstPath > 0 && GatePos < FirstPath,
		"disable_password_fields gate must appear before the first API/cache path in LLM_Engine_FirePrediction (MED-02)")
}

_DPFG_CheckSFDClassGuard() {
	; Move-resilient: find the function body across the whole driver source
	Body := _DriverFuncBody("SFD_IsSecureField")
	Assert(Body != "", "SFD_IsSecureField must be present in adapters/secure_field_detector.ahk")

	; ES_PASSWORD bit test position
	BitTestPos := InStr(Body, "0x20")
	Assert(BitTestPos > 0, "SFD_IsSecureField must test ES_PASSWORD bit 0x20 (LOW-02)")

	; Class check must precede the bit test
	ClassCheckPos := InStr(Body, "Edit")
	Assert(ClassCheckPos > 0,
		"SFD_IsSecureField must verify the focused control is an Edit class before testing ES_PASSWORD (LOW-02)")
	Assert(ClassCheckPos < BitTestPos,
		"Edit class guard must appear before ES_PASSWORD bit test in SFD_IsSecureField (LOW-02)")
}


Test("meta fix-disable-password-fields-gate: LLM_Engine_FirePrediction checks disable_password_fields and calls SFD_IsSecureField",
	_DPFG_CheckFirePredictionGate)

Test("meta fix-sfd-class-guard: SFD_IsSecureField checks Edit class before ES_PASSWORD bit",
	_DPFG_CheckSFDClassGuard)
