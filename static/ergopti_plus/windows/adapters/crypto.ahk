; adapters/crypto.ahk

; ==============================================================================
; MODULE: Crypto Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Crypto port contract defined in
; static/ergopti_plus/_shared/core/ports/Crypto.spec.js. Provides a single canonical
; SHA-256 function backed by the .NET System.Security.Cryptography.SHA256Managed
; COM class so domain modules can produce privacy hashes without coupling to
; AHK-specific COM plumbing.
;
; NAMING CONVENTION:
; Port method → AHK function name
;   sha256(data) → CryptoSha256(Data)
;
; RETURN:
; CryptoSha256() returns a 64-character lowercase hex string on success, or ""
; when the COM class is unavailable (e.g., .NET not installed). The fallback
; path is a DJB2 hash that returns an 8-character hex string — callers may
; detect this by checking length < 64.
;
; FAIL-SAFE:
; The entire function body is wrapped in try/catch. An exception from any COM
; or buffer operation returns "" rather than propagating to the caller.
; ==============================================================================

#Requires Autohotkey v2.0+




; =========================================
; =========================================
; ======= 1/ Crypto port implementation ===
; =========================================
; =========================================

; Computes the SHA-256 digest of a UTF-8 string and returns a 64-character
; lowercase hexadecimal string. Returns "" when the COM SHA256 class is
; unavailable or any internal error occurs.
;
; Implementation notes:
;   - ADODB.Stream converts the AHK string to a binary byte array that the
;     SHA256Managed.ComputeHash_2() overload accepts as a COM-safe array.
;   - The stream is opened in text mode (Type=2), written, then switched to
;     binary mode (Type=1) before Read() — the documented COM idiom for string
;     to binary conversion via ADODB.
CryptoSha256(Data) {
    try {
        stream := ComObject("ADODB.Stream")
        stream.Open()
        stream.Type     := 2   ; text mode — write the string
        stream.Charset  := "utf-8"
        stream.WriteText(Data)
        stream.Position := 3   ; skip the 3-byte UTF-8 BOM ADODB.Stream prepends when Charset := "utf-8"
        stream.Type     := 1   ; binary mode — read back as byte array
        raw := stream.Read()
        stream.Close()

        sha       := ComObject("System.Security.Cryptography.SHA256Managed")
        hash_bytes := sha.ComputeHash_2(raw)
        out := ""
        for b in hash_bytes
            out .= Format("{:02x}", b)
        return out
    } catch as Err {
        ; DJB2 fallback when .NET COM classes are unavailable — returns an 8-char
        ; hex string so callers can detect degraded mode by checking length != 64.
        ; This is a silent privacy downgrade (SSID hashes etc. become far weaker
        ; and collision-prone), so — unlike a routine recoverable failure — it
        ; must leave a log trace instead of degrading invisibly.
        LoggerWarn("Crypto", "CryptoSha256: SHA-256 COM classes unavailable ({1}) - falling back to degraded DJB2 hash (8 hex chars instead of 64).", Err.Message)
        h := 5381
        loop StrLen(Data) {
            h := ((h << 5) + h) + Ord(SubStr(Data, A_Index, 1))
            h := h & 0xFFFFFFFF
        }
        return Format("{:08x}", h)
    }
}

; Port dispatch map (ADAPTER_CRYPTO) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_CRYPTO := Map(
    "sha256", CryptoSha256
)
