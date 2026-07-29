; static/ergopti_plus/windows/tests/unit/test_audit_v5_fixes.ahk
;
; DESCRIPTION:
; Static-source regression guards for the four bugs fixed from the expert audit
; report RAPPORT_AUDIT_EXPERT_V5.md:
;   1. CryptoSha256 included the 3-byte UTF-8 BOM in the hash input (crypto.ahk)
;   2. NI_ADAPTER_OFFSET_OPER_STATUS was hardcoded to 56 -- wrong on x64 (should be 104)
;      and wrong on x86 (should be 68) (network_info.ahk)
;   3. DATA_BLOB pointer offset hardcoded to 8 -- wrong on x86 where pbData is at offset 4
;      (modules/llm/api_token_crypto.ahk)
;   4. HookDispatcher.Unregister lacked a finally block -- inconsistent with Register
;      (lib/hook_dispatcher.ahk)

; (test_framework.ahk is provided once by run_all.ahk — do not re-include it here
; or the suite errors on duplicate definitions.)

_AuditV5_ReadSrc(RelPath) {
	Base := StrReplace(A_LineFile, "tests\unit\test_audit_v5_fixes.ahk", "")
	return FileRead(Base . RelPath, "UTF-8")
}




; =======================================================================
; ===== 1) crypto.ahk -- stream.Position := 3 skips the UTF-8 BOM
; =======================================================================

; The original invariant here — "the BOM must not end up in the hash input" — is
; still exactly right, but it was expressed as a source assertion about the ADODB
; implementation, and that implementation was later PROVEN unable to run at all:
; ADODB.Stream only permits a Type switch while Position is 0, so the very line
; this test demanded (`Position := 3` before `Type := 1`) raised 0x800A0C93 on
; every call and the adapter always fell through to the 8-char DJB2 fallback. The
; source form could therefore be satisfied by code that never executed.
;
; Restated behaviourally against the real digest, which is strictly stronger: if
; anything — a BOM, a terminating NUL, the wrong text encoding — were prepended
; or appended to the hash input, the digest would not match the canonical value.
TestAuditV5_CryptoBomSkip() {
	Got := CryptoSha256("hello")
	AssertTrue(
		Got = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
		"CryptoSha256('hello') must hash the UTF-8 bytes ALONE — a leading BOM, a trailing NUL "
		. "or a UTF-16 encoding all change the digest; got: " . Got
	)
}
Test("Audit-v5: CryptoSha256 hashes the bare UTF-8 bytes, with no BOM", TestAuditV5_CryptoBomSkip)




; =========================================================================
; ===== 2) network_info.ahk -- offsets are architecture-dynamic (A_PtrSize)
; =========================================================================

TestAuditV5_NetworkInfoDynamicOffsets() {
	Src := _AuditV5_ReadSrc("adapters\network_info.ahk")

	; The bug: NI_ADAPTER_OFFSET_OPER_STATUS := 56 is the DnsSuffix pointer on x64
	; (OperStatus is at offset 104). On x86 OperStatus is at 68. Both were wrong.
	; The fix: ternary expression based on A_PtrSize.
	AssertFalse(
		InStr(Src, "NI_ADAPTER_OFFSET_OPER_STATUS          := 56"),
		"NI_ADAPTER_OFFSET_OPER_STATUS must not be hardcoded to 56 (correct x64 offset is 104)"
	)
	AssertTrue(
		InStr(Src, "A_PtrSize == 8) ? 104 : 68"),
		"NI_ADAPTER_OFFSET_OPER_STATUS must use (A_PtrSize == 8) ? 104 : 68"
	)
	AssertTrue(
		InStr(Src, "A_PtrSize == 8) ? 72  : 40"),
		"NI_ADAPTER_OFFSET_FRIENDLY_NAME must use (A_PtrSize == 8) ? 72 : 40"
	)
}
Test("Audit-v5: NI_ADAPTER_OFFSET_OPER_STATUS and FRIENDLY_NAME are dynamic (A_PtrSize ternary)", TestAuditV5_NetworkInfoDynamicOffsets)




; =============================================================================
; ===== 3) api_token_crypto.ahk -- DATA_BLOB pointer offset uses A_PtrSize
; =============================================================================

TestAuditV5_DpapiPtrSizeOffset() {
	; Move-resilient: scan the whole driver source via the framework helper instead
	; of a pinned modules/llm/api_token_crypto.ahk read. The in_blob/A_PtrSize DPAPI
	; tokens below are unique to api_token_crypto.ahk, so the scope stays unambiguous.
	Src := _DriverSourceConcat()

	; The bug: NumPut("Ptr", ..., blob, 8) hardcoded offset 8 for pbData in DATA_BLOB.
	; On x86 A_PtrSize=4 and pbData sits at offset 4 -- hardcoded 8 writes to wrong memory.
	; The fix: use A_PtrSize as the pointer offset (4 on x86, 8 on x64).
	; Guard: in_blob with A_PtrSize offset (not 8) must be present in Protect.
	AssertFalse(
		InStr(Src, 'NumPut("Ptr",  bytes.Ptr, in_blob, 8)'),
		"_LLM_DPAPI_Protect must not use hardcoded offset 8 for in_blob pbData"
	)
	AssertFalse(
		InStr(Src, 'NumPut("Ptr",  in_buf.Ptr,  in_blob, 8)'),
		"_LLM_DPAPI_Unprotect must not use hardcoded offset 8 for in_blob pbData"
	)
	AssertTrue(
		InStr(Src, "in_blob, A_PtrSize)"),
		"DATA_BLOB pbData must be written at offset A_PtrSize (not hardcoded 8)"
	)
	AssertTrue(
		InStr(Src, 'out_blob, A_PtrSize, "Ptr")'),
		"DATA_BLOB output pointer must be read at offset A_PtrSize (not hardcoded 8)"
	)
}
Test("Audit-v5: DPAPI DATA_BLOB pointer offset uses A_PtrSize (not hardcoded 8)", TestAuditV5_DpapiPtrSizeOffset)




; ================================================================================
; ===== 4) hook_dispatcher.ahk -- Unregister uses finally like Register does
; ================================================================================

TestAuditV5_UnregisterFinally() {
	; Move-resilient: scan the whole driver source via the framework helper instead
	; of a pinned lib/hook_dispatcher.ahk read. The "static Unregister(...)" /
	; "static Dispatch(" anchors below are unique to hook_dispatcher.ahk, so the
	; block extractor stays scoped to the Unregister method.
	Src := _DriverSourceConcat()

	; The bug: Unregister() used bare try { } Critical("Off") -- fragile if a future
	; rethrow short-circuits the critical-off. Register() already used finally correctly.
	; The fix: add finally { Critical("Off") } to Unregister for consistency.
	UnregStart := InStr(Src, "static Unregister(event_type, callback_fn)")
	UnregEnd   := InStr(Src, "static Dispatch(", 1, UnregStart)
	UnregBlock := SubStr(Src, UnregStart, UnregEnd - UnregStart)

	AssertTrue(
		InStr(UnregBlock, "} finally {"),
		"HookDispatcher.Unregister must use a finally block to guarantee Critical release"
	)
	; The old manual early-return pattern had Critical("Off") directly before return
	; inside the try block -- verify that pattern is gone.
	AssertFalse(
		InStr(UnregBlock, "Critical(" . Chr(34) . "Off" . Chr(34) . ")" . "`n`t`t`t`treturn"),
		"Unregister must not call Critical-Off manually before an early return inside try"
	)
}
Test("Audit-v5: HookDispatcher.Unregister uses finally block to release Critical", TestAuditV5_UnregisterFinally)
