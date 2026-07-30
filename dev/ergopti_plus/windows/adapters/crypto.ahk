; adapters/crypto.ahk

; ==============================================================================
; MODULE: Crypto Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Crypto port contract defined in
; static/ergopti_plus/_shared/core/ports/Crypto.spec.js. Provides a single canonical
; SHA-256 function backed by Windows CNG (bcrypt.dll) so domain modules can
; produce privacy hashes without coupling to AHK-specific plumbing.
;
; NAMING CONVENTION:
; Port method → AHK function name
;   sha256(data) → CryptoSha256(Data)
;
; RETURN:
; CryptoSha256() returns a 64-character lowercase hex string. If CNG is somehow
; unavailable it logs a WARNING and falls back to a DJB2 hash returning an
; 8-character hex string, so callers can detect degraded mode by length != 64.
;
; FAIL-SAFE:
; The body is wrapped in try/catch/finally: any failure degrades to the logged
; DJB2 path instead of propagating, and both CNG handles are released on every
; exit path.
;
; HISTORY:
; This adapter previously used ADODB.Stream + the .NET COM class SHA256Managed
; and could never once succeed — ADODB only allows a Type switch while Position
; is 0, so `Position := 3` before `Type := 1` threw 0x800A0C93 on every call and
; every "hash" in the product was really the 8-char DJB2 fallback.
; ==============================================================================

#Requires Autohotkey v2.0+

; CNG algorithm identifier and the two property names used to size the hash
; object and its digest. Named because a typo in any of them degrades the
; adapter to the DJB2 fallback rather than failing loudly.
global CRYPTO_BCRYPT_SHA256_ALG        := "SHA256"
global CRYPTO_BCRYPT_PROP_OBJECT_LENGTH := "ObjectLength"
global CRYPTO_BCRYPT_PROP_DIGEST_LENGTH := "HashDigestLength"




; =========================================
; =========================================
; ======= 1/ Crypto port implementation ===
; =========================================
; =========================================

; Computes the SHA-256 digest of a UTF-8 string and returns a 64-character
; lowercase hexadecimal string.
;
; Implementation notes:
;   - Uses Windows CNG (bcrypt.dll), a core OS component since Vista. The
;     previous implementation went through ADODB.Stream + the .NET COM class
;     System.Security.Cryptography.SHA256Managed and could NEVER succeed: ADODB
;     only permits a Type switch while Position is 0, so setting Position := 3
;     before Type := 1 raised 0x800A0C93 ("operation is not allowed in this
;     context") on every single call. Every digest silently came from the DJB2
;     fallback below — an 8-character, collision-prone hash standing in for a
;     privacy-preserving one. SHA256Managed is also absent unless .NET 3.5 COM
;     registration is enabled, so fixing only the ADODB order would still have
;     degraded on a default Windows install. CNG removes both dependencies.
;   - The input is hashed as UTF-8 WITHOUT a terminating NUL, which is what makes
;     the output match the canonical digest of the same string everywhere else.
CryptoSha256(Data) {
    hAlg := 0, hHash := 0
    try {
        if (DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", &hAlg,
            "Str", CRYPTO_BCRYPT_SHA256_ALG, "Ptr", 0, "UInt", 0, "UInt") != 0)
            throw Error("BCryptOpenAlgorithmProvider(SHA256) failed")

        Discarded := 0, ObjectLength := 0, DigestLength := 0
        DllCall("bcrypt\BCryptGetProperty", "Ptr", hAlg, "Str", CRYPTO_BCRYPT_PROP_OBJECT_LENGTH,
            "UInt*", &ObjectLength, "UInt", 4, "UInt*", &Discarded, "UInt", 0)
        DllCall("bcrypt\BCryptGetProperty", "Ptr", hAlg, "Str", CRYPTO_BCRYPT_PROP_DIGEST_LENGTH,
            "UInt*", &DigestLength, "UInt", 4, "UInt*", &Discarded, "UInt", 0)
        if (!ObjectLength or !DigestLength)
            throw Error("BCryptGetProperty returned no buffer sizes")

        HashObject := Buffer(ObjectLength, 0)
        Digest     := Buffer(DigestLength, 0)
        if (DllCall("bcrypt\BCryptCreateHash", "Ptr", hAlg, "Ptr*", &hHash, "Ptr", HashObject,
            "UInt", ObjectLength, "Ptr", 0, "UInt", 0, "UInt", 0, "UInt") != 0)
            throw Error("BCryptCreateHash failed")

        ; StrPut counts the terminating NUL; hashing it would change every digest.
        ByteCount := StrPut(Data, "UTF-8") - 1
        Utf8      := Buffer(ByteCount < 1 ? 1 : ByteCount, 0)
        if (ByteCount > 0)
            StrPut(Data, Utf8, ByteCount, "UTF-8")
        DllCall("bcrypt\BCryptHashData", "Ptr", hHash, "Ptr", Utf8, "UInt", ByteCount, "UInt", 0)
        DllCall("bcrypt\BCryptFinishHash", "Ptr", hHash, "Ptr", Digest, "UInt", DigestLength, "UInt", 0)

        out := ""
        loop DigestLength
            out .= Format("{:02x}", NumGet(Digest, A_Index - 1, "UChar"))
        return out
    } catch as Err {
        ; DJB2 fallback when CNG is unavailable — returns an 8-char hex string so
        ; callers can detect degraded mode by checking length != 64.
        ; This is a silent privacy downgrade (SSID hashes etc. become far weaker
        ; and collision-prone), so — unlike a routine recoverable failure — it
        ; must leave a log trace instead of degrading invisibly. bcrypt.dll ships
        ; with Windows, so reaching this now means something is genuinely wrong;
        ; it used to be the path EVERY call took.
        LoggerWarn("Crypto", "CryptoSha256: CNG SHA-256 unavailable ({1}) - falling back to degraded DJB2 hash (8 hex chars instead of 64).", Err.Message)
        h := 5381
        loop StrLen(Data) {
            h := ((h << 5) + h) + Ord(SubStr(Data, A_Index, 1))
            h := h & 0xFFFFFFFF
        }
        return Format("{:08x}", h)
    } finally {
        ; Both handles are OS resources; leaking one per hash would bleed the
        ; process. Ordered child-then-parent, and each guarded because the throw
        ; may have happened before either existed.
        if hHash
            DllCall("bcrypt\BCryptDestroyHash", "Ptr", hHash)
        if hAlg
            DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", hAlg, "UInt", 0)
    }
}

; Port dispatch map (ADAPTER_CRYPTO) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_CRYPTO := Map(
    "sha256", CryptoSha256
)
