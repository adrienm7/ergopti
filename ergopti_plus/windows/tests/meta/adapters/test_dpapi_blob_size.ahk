; tests/meta/adapters/test_dpapi_blob_size.ahk

; ==============================================================================
; MODULE: DPAPI DATA_BLOB Buffer-Size Meta Test
; DESCRIPTION:
; Guards that all DATA_BLOB allocations in api_token_crypto.ahk use
; Buffer(A_PtrSize * 2, 0) (16 bytes on x64) rather than the old
; Buffer(4 + A_PtrSize, 0) (12 bytes on x64).
;
; WHY THIS MATTERS:
;   On 64-bit AHK (A_PtrSize = 8) Buffer(4 + A_PtrSize) = 12 bytes, but
;   NumPut("Ptr", ..., A_PtrSize) writes at offset 8 touching bytes 8-15 —
;   4 bytes past the end. AHK v2 bounds-checks Buffer writes and throws
;   "Invalid parameter(s)", so DPAPI encrypt/decrypt fail on every 64-bit host.
;   Fix: Buffer(A_PtrSize * 2) = 16 on x64, exactly the struct size.
; ==============================================================================

#Requires AutoHotkey v2.0
; (test_framework.ahk is provided once by run_all.ahk — do not re-include it here
; or the suite errors on duplicate definitions.)


; ===========================================================
; ===========================================================
; ======= 2/ Static source assertions =======================
; ===========================================================
; ===========================================================

_DPBZ_OldFormAbsent() {
	; Move-resilient: scan the llm module tree via the framework helper instead of
	; a pinned api_token_crypto path. Both Buffer forms are unique to that file
	; within modules/llm, so the scope stays meaningful.
	Src := _DriverDirConcat("modules/llm")
	Assert(InStr(Src, "Buffer(4 + A_PtrSize") = 0,
		"api_token_crypto.ahk must not contain Buffer(4 + A_PtrSize — use Buffer(A_PtrSize * 2) to cover 16 bytes on x64")
}
Test("api_token_crypto: old Buffer(4 + A_PtrSize) form is absent", _DPBZ_OldFormAbsent)

_DPBZ_NewFormPresent() {
	Src := _DriverDirConcat("modules/llm")
	Assert(InStr(Src, "Buffer(A_PtrSize * 2") > 0,
		"api_token_crypto.ahk must use Buffer(A_PtrSize * 2) for DATA_BLOB allocations")
}
Test("api_token_crypto: new Buffer(A_PtrSize * 2) form is present", _DPBZ_NewFormPresent)


; ===========================================================
; ===========================================================
; ======= 3/ Behavioral assertion ===========================
; ===========================================================
; ===========================================================

_DPAPI_BlobRoundTrip() {
	buf := Buffer(A_PtrSize * 2, 0)
	NumPut("UInt", 5, buf, 0)
	NumPut("Ptr", 12345678, buf, A_PtrSize)
	AssertEqual(NumGet(buf, A_PtrSize, "Ptr"), 12345678, "Ptr round-trip in 2*A_PtrSize buffer")
}
Test("api_token_crypto: A_PtrSize*2 buffer holds UInt+Ptr without throw", _DPAPI_BlobRoundTrip)

; Regression: DATA_BLOB pointer offset hardcoded to 8 -- wrong on x86 where pbData is at offset 4
; (modules/llm/api_token_crypto.ahk)
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
Test("dpapi: DPAPI DATA_BLOB pointer offset uses A_PtrSize (not hardcoded 8)", TestAuditV5_DpapiPtrSizeOffset)
