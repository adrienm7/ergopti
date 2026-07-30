; modules/keylogger/keylogger_text_cipher.ahk

; ==============================================================================
; MODULE: Typed-Text Cipher (AutoHotkey)
; DESCRIPTION:
; Windows counterpart of linux/modules/keylogger/text_cipher.lua and
; macos/modules/keylogger/text_cipher.lua. Encrypts the columns that hold
; literal typed text (events_typing.text and events_json) with a key derived
; once from this machine's GUID.
;
; WHY CNG RATHER THAN A SUBPROCESS:
; The other two drivers shell out to openssl. Windows has no openssl by default,
; so the AES and PBKDF2 primitives come from bcrypt.dll — wrapped in
; adapters/crypto.ahk, since the OS-purity ratchet keeps every DllCall inside
; adapters/. That spawns no process at all, which makes this the fastest of the
; three — and it produces the SAME bytes: PBKDF2 with a 32-byte output is exactly
; the first block openssl derives, so the same machine id yields the same key,
; and AES-256-CBC with PKCS7 padding is what `openssl enc -aes-256-cbc` writes.
; The stored envelope is therefore identical in format across the three drivers,
; which the parity gate pins.
;
; PERFORMANCE:
; The key derivation runs 600 000 PBKDF2 iterations, so it is done ONCE and the
; 32-byte key is cached for the session. Every per-value call reuses it and costs
; only the AES itself — no derivation, no process.
;
; THREAT MODEL — STATED PLAINLY:
; The key derives from the machine GUID, so it can never be lost, but that also
; means anyone who can run code on the machine can derive it. This protects
; against OFF-machine disclosure — a stolen disk, a backup, a synced folder — not
; against code running on the machine itself. Durability was chosen over secrecy
; on purpose: a key that can be lost turns every stored log into garbage.
; ==============================================================================

; ==============================================================================
; ==============================================================================
; ======= 1/ Constants =========================================================
; ==============================================================================
; ==============================================================================

; Envelope format. MUST match _shared/lua/keylogger/text_crypto.lua; the parity
; gate tools/test/test-text-crypto-envelope-parity.cjs fails if they drift.
global KL_ENC_MARKER      := "ergopti-enc-v1"
global KL_ENC_SEPARATOR   := ":"

; PBKDF2 parameters. The salt is the ASCII of "ergopti-metrics1" (16 bytes); a
; fixed salt because a stored one could be lost, which is the whole point.
global KL_ENC_KDF_ITERATIONS := 600000
global KL_ENC_KDF_SALT_HEX   := "6572676f7074692d6d65747269637331"

; AES-256 sizes, in bytes.
global KL_ENC_KEY_BYTES := 32
global KL_ENC_IV_BYTES  := 16




; ==============================================================================
; ==============================================================================
; ======= 2/ State =============================================================
; ==============================================================================
; ==============================================================================

; Whether at-rest encryption is active. Off by default, matching the shared
; manifest's metrics.encrypt.
global KL_ENC_Enabled := false

; Cached 32-byte key as a Buffer, and a flag so a failed derivation is not
; retried (600 000 iterations) on every flush.
global KL_ENC_KeyBuffer := ""
global KL_ENC_DerivationFailed := false

; Test seam: forces the machine id. A separate "active" flag is required so the
; empty string can be forced too — otherwise "" would be indistinguishable from
; "no override" and fall back to the registry.
global KL_ENC_MachineIdOverride := ""
global KL_ENC_MachineIdOverrideActive := false




; ==============================================================================
; ==============================================================================
; ======= 3/ Byte / Hex Helpers ================================================
; ==============================================================================
; ==============================================================================

; Converts a hex string to a Buffer of its bytes.
_KL_Enc_HexToBuffer(hex) {
    n := StrLen(hex) // 2
    buf := Buffer(n, 0)
    loop n {
        byte := ("0x" . SubStr(hex, (A_Index - 1) * 2 + 1, 2)) + 0
        NumPut("UChar", byte, buf, A_Index - 1)
    }
    return buf
}

; UTF-8 bytes of a string, WITHOUT the terminating NUL, as a Buffer whose
; .UsedSize is the byte length.
_KL_Enc_Utf8Buffer(text) {
    n := StrPut(text, "UTF-8") - 1
    buf := Buffer(n < 1 ? 1 : n, 0)
    if (n > 0)
        StrPut(text, buf, n, "UTF-8")
    buf.UsedSize := n
    return buf
}




; ==============================================================================
; ==============================================================================
; ======= 4/ Key Derivation ====================================================
; ==============================================================================
; ==============================================================================

; Reads this machine's GUID. Stable across reboots and OS upgrades.
_KL_Enc_MachineId() {
    if (KL_ENC_MachineIdOverrideActive)
        return KL_ENC_MachineIdOverride
    try {
        return RegRead("HKLM\SOFTWARE\Microsoft\Cryptography", "MachineGuid")
    } catch {
        return ""
    }
}

; Derives the 32-byte key with PBKDF2-HMAC-SHA256, ONCE, and caches it.
; @return Buffer|"" The key, or "" when it cannot be derived.
_KL_Enc_EnsureKey() {
    global KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
    if (KL_ENC_KeyBuffer != "")
        return KL_ENC_KeyBuffer
    if (KL_ENC_DerivationFailed)
        return ""

    machineId := _KL_Enc_MachineId()
    if (machineId = "") {
        KL_ENC_DerivationFailed := true
        LoggerError("Keylogger", "At-rest encryption: no MachineGuid available - staying off.")
        return ""
    }

    pass := _KL_Enc_Utf8Buffer(machineId)
    salt := _KL_Enc_HexToBuffer(KL_ENC_KDF_SALT_HEX)
    key  := CryptoPbkdf2Sha256(pass.Ptr, pass.UsedSize, salt.Ptr, salt.Size,
        KL_ENC_KDF_ITERATIONS, KL_ENC_KEY_BYTES)
    if (key = "") {
        KL_ENC_DerivationFailed := true
        LoggerError("Keylogger", "At-rest key derivation failed - encryption unavailable.")
        return ""
    }

    KL_ENC_KeyBuffer := key
    return key
}




; ==============================================================================
; ==============================================================================
; ======= 5/ Envelope ==========================================================
; ==============================================================================
; ==============================================================================

; True when a stored value is one of our envelopes.
KL_Enc_IsEncrypted(value) {
    if (Type(value) != "String")
        return false
    return SubStr(value, 1, StrLen(KL_ENC_MARKER) + 1) = KL_ENC_MARKER . KL_ENC_SEPARATOR
}

; Derives the per-row IV hex from (device_id, event_id) — unique by construction,
; so no randomness is needed and identical text in two rows never collides.
_KL_Enc_IvHex(deviceId, eventId) {
    digest := CryptoSha256(deviceId . KL_ENC_SEPARATOR . eventId)
    if (StrLen(digest) < KL_ENC_IV_BYTES * 2)
        return ""
    return SubStr(digest, 1, KL_ENC_IV_BYTES * 2)
}




; ==============================================================================
; ==============================================================================
; ======= 6/ Public API ========================================================
; ==============================================================================
; ==============================================================================

; Turns at-rest encryption on or off.
KL_Enc_SetEnabled(enabled) {
    global KL_ENC_Enabled
    KL_ENC_Enabled := (enabled = true || enabled = 1)
    LoggerDebug("Keylogger", "At-rest encryption: {1}.", KL_ENC_Enabled ? "on" : "off")
}

; Whether at-rest encryption is active.
KL_Enc_IsEnabled() {
    return KL_ENC_Enabled
}

; Whether a usable key can be derived on this machine. The menu refuses to tick
; the box when this is false.
KL_Enc_IsAvailable() {
    return _KL_Enc_EnsureKey() != ""
}

; Encrypts one value for storage.
; @return String|"" The envelope, the untouched plaintext when disabled, or ""
;   when encryption is enabled but impossible — the caller must NOT store the
;   plaintext in that case.
KL_Enc_Encrypt(deviceId, eventId, plaintext) {
    if (!KL_ENC_Enabled)
        return plaintext
    if (Type(plaintext) != "String" || plaintext = "")
        return plaintext
    if (KL_Enc_IsEncrypted(plaintext))
        return plaintext

    key := _KL_Enc_EnsureKey()
    if (key = "")
        return ""   ; caller must drop the row, never store the plaintext

    ivHex := _KL_Enc_IvHex(deviceId, eventId)
    if (ivHex = "") {
        LoggerError("Keylogger", "At-rest encryption: cannot derive an IV - refusing to store plaintext.")
        return ""
    }

    ivBuf := _KL_Enc_HexToBuffer(ivHex)
    data  := _KL_Enc_Utf8Buffer(plaintext)
    cipher := CryptoAesCbc(key, ivBuf, data.Ptr, data.UsedSize, true)
    if (cipher = "")
        return ""

    cipher.Size := cipher.UsedSize
    return KL_ENC_MARKER . KL_ENC_SEPARATOR . ivHex . KL_ENC_SEPARATOR . CryptoBase64Encode(cipher)
}

; Decrypts one stored value. A value that is not an envelope is returned
; unchanged, so databases written before the feature still read.
KL_Enc_Decrypt(value) {
    if (!KL_Enc_IsEncrypted(value))
        return value

    rest   := SubStr(value, StrLen(KL_ENC_MARKER) + StrLen(KL_ENC_SEPARATOR) + 1)
    sepPos := InStr(rest, KL_ENC_SEPARATOR)
    if (!sepPos)
        return ""
    ivHex := SubStr(rest, 1, sepPos - 1)
    b64   := SubStr(rest, sepPos + StrLen(KL_ENC_SEPARATOR))
    if (StrLen(ivHex) != KL_ENC_IV_BYTES * 2)
        return ""

    key := _KL_Enc_EnsureKey()
    if (key = "") {
        LoggerWarn("Keylogger", "Encrypted row cannot be read: no key on this machine.")
        return ""
    }

    ivBuf  := _KL_Enc_HexToBuffer(ivHex)
    cipher := CryptoBase64Decode(b64)
    if (cipher.Size = 0)
        return ""
    plain := CryptoAesCbc(key, ivBuf, cipher.Ptr, cipher.Size, false)
    if (plain = "")
        return ""
    return StrGet(plain.Ptr, plain.UsedSize, "UTF-8")
}

; Test seam: forces the machine id and clears the cached key. Pass "" to force
; the "no machine id" failure path.
KL_Enc_SetMachineIdOverride(id) {
    global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
    global KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
    KL_ENC_MachineIdOverride := id
    KL_ENC_MachineIdOverrideActive := true
    KL_ENC_KeyBuffer := ""
    KL_ENC_DerivationFailed := false
}
