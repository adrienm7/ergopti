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






; =========================================
; =========================================
; ======= 2/ AES + PBKDF2 primitives ======
; =========================================
; =========================================

; These back the keylogger's at-rest encryption. They live here, in the crypto
; adapter, because the OS-purity ratchet requires every DllCall to sit inside
; adapters/ — and CNG is exactly the kind of OS primitive an adapter exists to
; wrap. The envelope format and the orchestration live in
; modules/keylogger/keylogger_text_cipher.ahk, which calls these and holds no
; DllCall of its own.

; BCRYPT_ALG_HANDLE_HMAC_FLAG — the SHA-256 provider must be opened with this to
; drive PBKDF2.
global CRYPTO_BCRYPT_HMAC_FLAG := 0x8

; BCRYPT_BLOCK_PADDING — PKCS7, matching `openssl enc -aes-256-cbc`.
global CRYPTO_BCRYPT_BLOCK_PADDING := 0x1

; Derives bytes with PBKDF2-HMAC-SHA256. With dkLen = 32 the output is exactly
; the first block openssl derives, so the same password yields the same AES-256
; key across the three drivers.
; @param passPtr   Ptr    Password bytes (UTF-8, no NUL).
; @param passLen   UInt   Password length in bytes.
; @param saltPtr   Ptr    Salt bytes.
; @param saltLen   UInt   Salt length in bytes.
; @param iterations Integer Iteration count.
; @param dkLen     UInt   Desired key length in bytes.
; @return Buffer|"" The derived bytes, or "" on failure.
CryptoPbkdf2Sha256(passPtr, passLen, saltPtr, saltLen, iterations, dkLen) {
    hAlg := 0
    try {
        if (DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", &hAlg,
            "Str", "SHA256", "Ptr", 0, "UInt", CRYPTO_BCRYPT_HMAC_FLAG, "UInt") != 0)
            throw Error("BCryptOpenAlgorithmProvider(SHA256, HMAC) failed")
        out := Buffer(dkLen, 0)
        status := DllCall("bcrypt\BCryptDeriveKeyPBKDF2", "Ptr", hAlg,
            "Ptr", passPtr, "UInt", passLen,
            "Ptr", saltPtr, "UInt", saltLen,
            "Int64", iterations,
            "Ptr", out.Ptr, "UInt", dkLen, "UInt", 0)
        if (status != 0)
            throw Error("BCryptDeriveKeyPBKDF2 failed (" . status . ")")
        return out
    } catch as Err {
        LoggerError("Crypto", "CryptoPbkdf2Sha256 failed: {1}", Err.Message)
        return ""
    } finally {
        if (hAlg)
            DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", hAlg, "UInt", 0)
    }
}

; Runs AES-256-CBC with PKCS7 padding.
; @param keyBuf  Buffer 32 bytes.
; @param ivBuf   Buffer 16 bytes (not modified: a private copy is used).
; @param dataPtr Ptr    Input bytes.
; @param dataLen UInt   Input length.
; @param encrypt Bool   True to encrypt, false to decrypt.
; @return Buffer|"" Output bytes with a .UsedSize field, or "" on failure.
CryptoAesCbc(keyBuf, ivBuf, dataPtr, dataLen, encrypt) {
    hAlg := 0, hKey := 0
    try {
        if (DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", &hAlg,
            "Str", "AES", "Ptr", 0, "UInt", 0, "UInt") != 0)
            throw Error("BCryptOpenAlgorithmProvider(AES) failed")

        mode := "ChainingModeCBC"
        modeBuf := Buffer((StrLen(mode) + 1) * 2, 0)
        StrPut(mode, modeBuf, "UTF-16")
        if (DllCall("bcrypt\BCryptSetProperty", "Ptr", hAlg, "Str", "ChainingMode",
            "Ptr", modeBuf.Ptr, "UInt", modeBuf.Size, "UInt", 0, "UInt") != 0)
            throw Error("BCryptSetProperty(CBC) failed")

        objLen := 0, discarded := 0
        DllCall("bcrypt\BCryptGetProperty", "Ptr", hAlg, "Str", "ObjectLength",
            "UInt*", &objLen, "UInt", 4, "UInt*", &discarded, "UInt", 0)
        keyObj := Buffer(objLen, 0)

        if (DllCall("bcrypt\BCryptGenerateSymmetricKey", "Ptr", hAlg, "Ptr*", &hKey,
            "Ptr", keyObj.Ptr, "UInt", objLen, "Ptr", keyBuf.Ptr, "UInt", keyBuf.Size,
            "UInt", 0, "UInt") != 0)
            throw Error("BCryptGenerateSymmetricKey failed")

        fn := encrypt ? "BCryptEncrypt" : "BCryptDecrypt"

        ; BCrypt updates the IV in place for chaining, so a fresh copy is passed —
        ; and re-copied before the second call, since the sizing call touches it.
        ivWork := Buffer(ivBuf.Size, 0)
        DllCall("RtlMoveMemory", "Ptr", ivWork.Ptr, "Ptr", ivBuf.Ptr, "UPtr", ivBuf.Size)

        outLen := 0
        if (DllCall("bcrypt\" . fn, "Ptr", hKey, "Ptr", dataPtr, "UInt", dataLen,
            "Ptr", 0, "Ptr", ivWork.Ptr, "UInt", ivBuf.Size,
            "Ptr", 0, "UInt", 0, "UInt*", &outLen, "UInt", CRYPTO_BCRYPT_BLOCK_PADDING, "UInt") != 0)
            throw Error(fn . " sizing failed")

        out := Buffer(outLen, 0)
        DllCall("RtlMoveMemory", "Ptr", ivWork.Ptr, "Ptr", ivBuf.Ptr, "UPtr", ivBuf.Size)
        result := 0
        if (DllCall("bcrypt\" . fn, "Ptr", hKey, "Ptr", dataPtr, "UInt", dataLen,
            "Ptr", 0, "Ptr", ivWork.Ptr, "UInt", ivBuf.Size,
            "Ptr", out.Ptr, "UInt", outLen, "UInt*", &result, "UInt", CRYPTO_BCRYPT_BLOCK_PADDING, "UInt") != 0)
            throw Error(fn . " failed")

        out.UsedSize := result
        return out
    } catch as Err {
        LoggerError("Crypto", "CryptoAesCbc failed: {1}", Err.Message)
        return ""
    } finally {
        if (hKey)
            DllCall("bcrypt\BCryptDestroyKey", "Ptr", hKey, "UInt", 0)
        if (hAlg)
            DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", hAlg, "UInt", 0)
    }
}

; Base64-encodes a Buffer, single line (no CR/LF), matching openssl -base64 -A.
; @param buf Buffer
; @return String
CryptoBase64Encode(buf) {
    flags := 0x40000001   ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    required := 0
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf.Ptr, "UInt", buf.Size,
        "UInt", flags, "Ptr", 0, "UInt*", &required)
    if (required <= 0)
        return ""
    out := Buffer(required * 2, 0)
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf.Ptr, "UInt", buf.Size,
        "UInt", flags, "Ptr", out.Ptr, "UInt*", &required)
    return StrGet(out.Ptr, required, "UTF-16")
}

; Base64-decodes to a Buffer.
; @param b64 String
; @return Buffer (size 0 on failure).
CryptoBase64Decode(b64) {
    flags := 0x1   ; CRYPT_STRING_BASE64
    required := 0
    DllCall("Crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", StrLen(b64),
        "UInt", flags, "Ptr", 0, "UInt*", &required, "Ptr", 0, "Ptr", 0)
    if (required <= 0)
        return Buffer(0, 0)
    out := Buffer(required, 0)
    ok := DllCall("Crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", StrLen(b64),
        "UInt", flags, "Ptr", out.Ptr, "UInt*", &required, "Ptr", 0, "Ptr", 0)
    return ok ? out : Buffer(0, 0)
}




; Port dispatch map (ADAPTER_CRYPTO) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_CRYPTO := Map(
    "sha256", CryptoSha256
)
