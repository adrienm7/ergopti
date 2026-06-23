; tests/meta/test_dpapi_blob_size.ahk

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
