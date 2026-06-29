; static/ergopti_plus/windows/tests/meta/test_b7_3_dead_fns_absent.ahk

; ==============================================================================
; MODULE: B7.3 Dead Function Absence Guard
; DESCRIPTION:
; Regression guard ensuring the four zero-caller functions deleted in B7.3 have
; not been re-introduced into the codebase. Re-introducing any of them would
; violate §5.6 (No Unused Fallback Code).
;
; Functions removed:
;   KL_FileExists     — thin wrapper around FileExist(), 0 callers in keylogger/*.
;   KL_ReadAll        — thin file-read wrapper, 0 callers in keylogger/*.
;   _KL_RegexEscape   — regex metachar escaper tied to a dead SQL literal path.
;   LLM_RemoteGenerate — sync blocking HTTP variant; async _Async is the live path.
; ==============================================================================


; ===========================================================
; ===========================================================
; ======= 1/ Keylogger dead helpers absent (B7.3) ===========
; ===========================================================
; ===========================================================

_B73_KL_FileExists_Absent() {
	Src := _DriverDirConcat("modules/keylogger")
	AssertTrue(!RegExMatch(Src, "m)^KL_FileExists\("),
		"KL_FileExists must not be defined — dead helper removed in B7.3 (§5.6)")
}
Test("B7.3: KL_FileExists is absent from modules/keylogger source", _B73_KL_FileExists_Absent)


; ===========================================================
; ===========================================================
; ======= 2/ Keylogger dead helpers absent (B7.3) ===========
; ===========================================================
; ===========================================================

_B73_KL_ReadAll_Absent() {
	Src := _DriverDirConcat("modules/keylogger")
	AssertTrue(!RegExMatch(Src, "m)^KL_ReadAll\("),
		"KL_ReadAll must not be defined — dead helper removed in B7.3 (§5.6)")
}
Test("B7.3: KL_ReadAll is absent from modules/keylogger source", _B73_KL_ReadAll_Absent)


; ===========================================================
; ===========================================================
; ======= 3/ Keylogger dead helpers absent (B7.3) ===========
; ===========================================================
; ===========================================================

_B73_KL_RegexEscape_Absent() {
	Src := _DriverDirConcat("modules/keylogger")
	AssertTrue(!RegExMatch(Src, "m)^_KL_RegexEscape\("),
		"_KL_RegexEscape must not be defined — dead helper removed in B7.3 (§5.6)")
}
Test("B7.3: _KL_RegexEscape is absent from modules/keylogger source", _B73_KL_RegexEscape_Absent)


; ============================================================
; ============================================================
; ======= 4/ LLM_RemoteGenerate sync absent (B7.3) ===========
; ============================================================
; ============================================================

_B73_LLMRemoteGenerate_Absent() {
	; Verify the ASYNC variant still exists (it is live and must not be removed).
	AsyncBody := _DriverFuncBody("LLM_RemoteGenerate_Async")
	AssertTrue(StrLen(AsyncBody) > 0, "LLM_RemoteGenerate_Async must still be defined")

	; The SYNC variant (zero callers) must be gone from the full LLM source tree.
	Src := _DriverDirConcat("modules/llm")
	AssertTrue(!RegExMatch(Src, "m)^LLM_RemoteGenerate\("),
		"LLM_RemoteGenerate (sync, 0 callers) must not be defined — dead code removed in B7.3 (§5.6)")
}
Test("B7.3: LLM_RemoteGenerate sync is absent from modules/llm source", _B73_LLMRemoteGenerate_Absent)
