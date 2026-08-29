; tests/meta/test_crypto_djb2_fallback_logged.ahk

; ==============================================================================
; MODULE: CryptoSha256 Failure Sentinel Guard
; DESCRIPTION:
; Static companion to the behavioral provider-failure regression. It prevents
; a weaker fallback algorithm from being reintroduced behind a success-looking
; non-empty digest.
;
; ROOT CAUSE ENCODED:
; The shared Crypto port requires exactly 64 lowercase hexadecimal characters
; on success and "" on provider failure. Returning an 8-character DJB2 value
; violates both the algorithm and error-transparency guarantees.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaCryptoFailureUsesContractSentinel() {
	Boundary := _DriverFuncBody("_CryptoSha256WithProvider")
	Assert(Boundary != "", "CryptoSha256 must expose a testable provider boundary")
	Assert(InStr(Boundary, "LoggerError(") > 0 && InStr(Boundary, 'return ""') > 0,
		"provider failure must be observable and return the shared empty-string sentinel")
	Assert(InStr(Boundary, "h := 5381") = 0 && InStr(Boundary, "DJB2") = 0,
		"CryptoSha256 must never substitute a weaker digest after provider failure")
}
Test("adapters.crypto: SHA-256 failure uses the contract sentinel (sha256-failure-sentinel)",
	_MetaCryptoFailureUsesContractSentinel)
