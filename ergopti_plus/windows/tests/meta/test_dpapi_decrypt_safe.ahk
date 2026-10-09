; tests/meta/test_dpapi_decrypt_safe.ahk

; ==============================================================================
; MODULE: DPAPI Decrypt Safety Meta Test
; DESCRIPTION:
; Static source guard for the "DPAPI decrypt failure silently wipes token"
; finding (dpapi-decrypt-fail-wipes-token).
;
; modules/llm/api_token_crypto.ahk — LLM_ApiToken_Decrypt() — previously
; called _LLM_DPAPI_Unprotect and returned its result directly. When DPAPI
; fails (corrupted blob, domain account not available, key inaccessible) that
; primitive returns "". The caller (menu_api_entries.ahk) stores "" into the
; in-memory entry; on the next config save this overwrites the encrypted blob
; with an empty string, permanently destroying the token. The user then has to
; re-enter their paid-API key — a silent, destructive data loss.
;
; The fix: on DPAPI failure LLM_ApiToken_Decrypt must return the original
; stored value (the encrypted form) unchanged so the blob survives subsequent
; saves. Callers that use the result as an API key will receive a 401
; (recoverable via re-entry in the UI), which is far better than silent loss.
;
; These are meta-static tests because _LLM_DPAPI_Unprotect is a DllCall
; wrapper (Crypt32.dll) with no injectable seam — the failure path cannot be
; exercised from a headless script.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_DPAPI_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Safety assertions ======================
; ===================================================
; ===================================================

_DPAPI_DecryptDoesNotReturnUnprotectDirectly() {
	Src := _DPAPI_ReadSource("modules/llm/api_token_crypto.ahk")
	Seg := _DriverFuncBody("LLM_ApiToken_Decrypt")
	Assert(Seg != "", "LLM_ApiToken_Decrypt declaration must exist in api_token_crypto.ahk")
	; Old code ended with `return _LLM_DPAPI_Unprotect(b64)` — the direct return
	; meant any DPAPI failure silently returned "" and wiped the token on next save.
	Assert(InStr(Seg, "return _LLM_DPAPI_Unprotect") = 0,
		"LLM_ApiToken_Decrypt must NOT return _LLM_DPAPI_Unprotect directly — a failed decrypt must not become an empty string")
}
Test("api_token_crypto: LLM_ApiToken_Decrypt does not return _LLM_DPAPI_Unprotect result directly", _DPAPI_DecryptDoesNotReturnUnprotectDirectly)

_DPAPI_DecryptChecksForEmptyResult() {
	Src := _DPAPI_ReadSource("modules/llm/api_token_crypto.ahk")
	Seg := _DriverFuncBody("LLM_ApiToken_Decrypt")
	Assert(InStr(Seg, "result == ") > 0 or InStr(Seg, "result =  ") > 0 or InStr(Seg, "result =`t") > 0,
		"LLM_ApiToken_Decrypt must inspect the result of _LLM_DPAPI_Unprotect before returning it")
}
Test("api_token_crypto: LLM_ApiToken_Decrypt checks _LLM_DPAPI_Unprotect result before returning", _DPAPI_DecryptChecksForEmptyResult)

_DPAPI_DecryptPreservesStoredOnFailure() {
	Src := _DPAPI_ReadSource("modules/llm/api_token_crypto.ahk")
	Seg := _DriverFuncBody("LLM_ApiToken_Decrypt")
	; The failure branch must return `stored` (the encrypted form) not "".
	Assert(InStr(Seg, "return stored") > 0,
		"LLM_ApiToken_Decrypt must return stored (the encrypted form) on DPAPI failure to prevent token loss on next save")
}
Test("api_token_crypto: LLM_ApiToken_Decrypt returns stored form on DPAPI failure (no token wipe)", _DPAPI_DecryptPreservesStoredOnFailure)
