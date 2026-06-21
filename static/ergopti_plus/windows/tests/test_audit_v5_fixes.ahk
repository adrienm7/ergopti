; static/ergopti_plus/windows/tests/test_audit_v5_fixes.ahk
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

#Include %A_LineFile%\..\test_framework.ahk

_AuditV5_ReadSrc(RelPath) {
	Base := StrReplace(A_LineFile, "tests\test_audit_v5_fixes.ahk", "")
	return FileRead(Base . RelPath, "UTF-8")
}




; =======================================================================
; ===== 1) crypto.ahk -- stream.Position := 3 skips the UTF-8 BOM
; =======================================================================

TestAuditV5_CryptoBomSkip() {
	Src := _AuditV5_ReadSrc("adapters\crypto.ahk")

	; The bug: stream.Position := 0 before Type := 1 + Read() included the 3-byte
	; BOM that ADODB.Stream prepends when Charset := "utf-8", yielding a hash of
	; Chr(0xEF) Chr(0xBB) Chr(0xBF) + data instead of data alone.
	; The fix: advance the position past the 3-byte BOM before switching to binary mode.
	AssertFalse(
		InStr(Src, "stream.Position := 0"),
		"crypto.ahk must not reset stream.Position to 0 (includes the UTF-8 BOM in the hash input)"
	)
	AssertTrue(
		InStr(Src, "stream.Position := 3"),
		"crypto.ahk must set stream.Position := 3 to skip the ADODB.Stream UTF-8 BOM"
	)
}
Test("Audit-v5: CryptoSha256 skips ADODB UTF-8 BOM by setting stream.Position := 3", TestAuditV5_CryptoBomSkip)




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





; =======================================================================================
; =======================================================================================
; ======= 5/ graphics_renderer.ahk -- DrawFn throw is caught and gates the upload =======
; =======================================================================================
; =======================================================================================

TestAuditV5_GrDrawBitmapDrawFnCatch() {
	Src := _AuditV5_ReadSrc("adapters\graphics_renderer.ahk")

	; Locate GR_DrawBitmap so checks are scoped to that function only
	FnStart := InStr(Src, "GR_DrawBitmap(")
	; The next top-level function starts after the closing brace of the finally block
	FnEnd := InStr(Src, "`r`n}`r`n`r`n`r`n`r`n", FnStart)
	FnBlock := SubStr(Src, FnStart, FnEnd - FnStart)

	; The bug: bare "try DrawFn(...)" with no catch -- exceptions are silently swallowed.
	; The fix: a catch block captures the exception and logs it via OutputDebug.
	AssertFalse(
		RegExMatch(FnBlock, "try DrawFn\([^)]+\)\s*\r?\n\s*;"),
		"GR_DrawBitmap must not have a bare try DrawFn(...) with no catch block"
	)
	AssertTrue(
		InStr(FnBlock, "catch as Err"),
		"GR_DrawBitmap must have a catch block after try DrawFn(...)"
	)
	AssertTrue(
		InStr(FnBlock, "OutputDebug("),
		"GR_DrawBitmap catch block must call OutputDebug to surface the DrawFn error"
	)


	; =========================================================
	; ===== 5.1) UpdateLayeredWindow is inside if Painted =====
	; =========================================================

	; The fix also gates UpdateLayeredWindow on Painted so a failed paint does not
	; commit a partial or blank bitmap to the layered window.
	AssertTrue(
		InStr(FnBlock, "Painted := true"),
		"GR_DrawBitmap must set Painted := true before try DrawFn(...)"
	)
	AssertTrue(
		InStr(FnBlock, "Painted := false"),
		"GR_DrawBitmap catch block must set Painted := false"
	)

	; Verify UpdateLayeredWindow is subordinate to "if Painted {" by checking that
	; "if Painted {" appears before the UpdateLayeredWindow DllCall in the block.
	PaintedGuardPos := InStr(FnBlock, "if Painted {")
	UpdatePos       := InStr(FnBlock, "UpdateLayeredWindow")
	AssertTrue(
		PaintedGuardPos > 0 and UpdatePos > PaintedGuardPos,
		'UpdateLayeredWindow must appear after the "if Painted {" guard in GR_DrawBitmap'
	)
}
Test("Audit-v5 (F46): GR_DrawBitmap catches DrawFn exception and gates UpdateLayeredWindow on Painted", TestAuditV5_GrDrawBitmapDrawFnCatch)
