; tests/meta/test_crypto_djb2_fallback_logged.ahk

; ==============================================================================
; MODULE: CryptoSha256 DJB2 Fallback Logging Guard
; DESCRIPTION:
; Static source guard ensuring the DJB2 degraded-mode fallback in
; adapters/crypto.ahk logs a WARNING before returning the weaker 8-char hash.
;
; ROOT CAUSE ENCODED:
; The original catch block silently fell back to DJB2 with zero log trace — a
; silent privacy downgrade (SSID hashes etc. become far weaker and
; collision-prone) indistinguishable in the logs from a completely healthy run.
; CryptoSha256 has no dependency-injection seam for its COM objects (the
; existing behavioral test, tests/unit/test_adapter_contract_vectors.ahk,
; already hedges "64 (COM) or 8 (DJB2 fallback) hex chars" because it cannot
; force either path at runtime), so this is a source-scan test rather than a
; forced-failure behavioral one — matching the precedent already established
; by tests/meta/test_http_cancel_aborts.ahk for the same class of adapter fix.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaCryptoDjb2FallbackLogged() {
	Body := _DriverFuncBody("CryptoSha256")
	Assert(Body != "", "CryptoSha256 must be defined in adapters/crypto.ahk")

	CatchPos := InStr(Body, "catch")
	Assert(CatchPos > 0, "CryptoSha256 must have a catch block for the DJB2 fallback")

	WarnPos := InStr(Body, "LoggerWarn(", , CatchPos)
	Assert(WarnPos > 0,
		"CryptoSha256's DJB2 fallback (catch block) must call LoggerWarn to record the degraded-mode privacy downgrade")

	Djb2Pos := InStr(Body, "h := 5381", , CatchPos)
	Assert(Djb2Pos > 0, "CryptoSha256's DJB2 fallback body must be present")
	Assert(WarnPos < Djb2Pos,
		"CryptoSha256 must log the WARNING BEFORE computing the DJB2 fallback hash")
}
Test("adapters.crypto: CryptoSha256's DJB2 fallback logs a WARNING before degrading", _MetaCryptoDjb2FallbackLogged)
