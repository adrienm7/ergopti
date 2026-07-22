; modules/llm/api_token_crypto.ahk

; ==============================================================================
; MODULE: API Token Crypto
; DESCRIPTION:
; At-rest encryption for API tokens stored in config.toml / api_entries.json.
; Uses Windows DPAPI (CryptProtectData / CryptUnprotectData) so the encrypted
; blob is bound to the current Windows user account: a different user on the
; same machine — or the same user on a different machine — cannot decrypt.
; The encrypted form is stored as a base64 string so the TOML / JSON writers
; keep working unchanged.
;
; FEATURES & RATIONALE:
; 1. DPAPI = Microsoft's recommended local-secret store on Windows. No new
;    dependencies; the API ships with the OS and AHK can call it via DllCall.
; 2. Stored cleartext was the previous default. A laptop that gets shared,
;    an LLM bug that prints config.toml to logs, or a backup tool that
;    syncs the file to the cloud unencrypted — any of those exposed the
;    user's paid-API key in cleartext. DPAPI fixes the on-disk version
;    without changing the runtime hot path.
; 3. Backwards-compat: when the value does NOT look like a DPAPI base64
;    blob (no ``dpapi:`` prefix), the loader treats it as cleartext and
;    re-encrypts on the next save. Migration is invisible.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================
; ====================================
; ======= 1/ Constants ================
; ====================================
; ====================================

; Marker prefix on encrypted blobs. Anything starting with this string is
; assumed to be base64-encoded DPAPI ciphertext; everything else is treated
; as cleartext for backwards-compat with pre-encryption configs.
global LLM_API_TOKEN_DPAPI_PREFIX := "dpapi:"

; Optional secondary entropy mixed into CryptProtectData. Strengthens the
; bind so even another process on the same user account can't trivially
; round-trip the value via a public DPAPI helper. Kept identical to the
; "encrypt with the same entropy or it won't decrypt" rule that the
; symmetric helpers below honour.
global LLM_API_TOKEN_DPAPI_ENTROPY := "ergopti.llm.token"




; ====================================
; ====================================
; ======= 2/ Public API ==============
; ====================================
; ====================================

/**
 * Returns an encrypted (DPAPI + base64) version of the given cleartext.
 * On any failure (DPAPI unavailable, locked account, …) returns the input
 * unchanged so the worst case is "still plaintext" — never "lost token".
 * @param {string} cleartext - The raw API token.
 * @returns {string} ``dpapi:<base64>`` or the cleartext on failure.
 */
LLM_ApiToken_Encrypt(cleartext) {
	if (cleartext == "")
		return ""
	; If the value already carries the prefix, treat it as already-encrypted
	; — re-encrypting would double-wrap and break round-trip.
	if LLM_ApiToken_IsEncrypted(cleartext)
		return cleartext
	encrypted_b64 := _LLM_DPAPI_Protect(cleartext)
	if (encrypted_b64 == "")
		return cleartext
	return LLM_API_TOKEN_DPAPI_PREFIX . encrypted_b64
}

/**
 * Returns the cleartext form of a token. Handles both the encrypted form
 * (``dpapi:<base64>``) and the cleartext form (legacy configs from before
 * the encryption landing). Caller never needs to know which.
 *
 * On DPAPI failure the ENCRYPTED form is returned unchanged rather than an empty string.
 * This prevents the caller from overwriting a valid encrypted blob with an empty
 * string on the next config save, which would permanently destroy the token.
 * Callers that use the result as an API key will get a 401 (recoverable); a
 * silently wiped token would require the user to re-enter it (destructive).
 * @param {string} stored - The value stored on disk.
 * @returns {string} Cleartext on success; the original stored value on DPAPI failure.
 */
LLM_ApiToken_Decrypt(stored) {
	if (stored == "")
		return ""
	if !LLM_ApiToken_IsEncrypted(stored)
		return stored
	b64 := SubStr(stored, StrLen(LLM_API_TOKEN_DPAPI_PREFIX) + 1)
	result := _LLM_DPAPI_Unprotect(b64)
	if (result == "") {
		; DPAPI failed (corrupted blob, different user session, key not available).
		; Return the encrypted form intact so the next config save does not wipe it.
		try LoggerError("ApiTokenCrypto", "DPAPI decryption failed — returning encrypted form to prevent token loss.")
		return stored
	}
	return result
}

/**
 * Returns true when a stored value carries the encryption prefix.
 * Cheap test used to decide whether to round-trip through CryptUnprotectData.
 */
LLM_ApiToken_IsEncrypted(stored) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	return (stored != "" and SubStr(stored, 1, StrLen(LLM_API_TOKEN_DPAPI_PREFIX)) == LLM_API_TOKEN_DPAPI_PREFIX)
}




; ====================================
; ====================================
; ======= 3/ DPAPI bindings ==========
; ====================================
; ====================================

; CryptProtectData / CryptUnprotectData are exposed by Crypt32.dll. Both
; take a DATA_BLOB (UInt cbData + Ptr pbData) for the input + entropy +
; output. We pack the input bytes into a Buffer, hand a pointer to it as
; pbData, and on success the API allocates a buffer we have to copy +
; LocalFree. The error path simply returns "" so the caller falls back to
; cleartext.

_LLM_DPAPI_Protect(cleartext) {
	global LLM_API_TOKEN_DPAPI_ENTROPY
	; UTF-8 encode the cleartext so non-ASCII tokens (rare but possible)
	; survive the round-trip.
	bytes := Buffer(StrPut(cleartext, "UTF-8"))
	StrPut(cleartext, bytes, "UTF-8")
	; Strip the trailing null StrPut wrote — DPAPI doesn't care about it
	; and excluding it makes the round-tripped string exact.
	in_size := bytes.Size - 1
	in_blob := Buffer(A_PtrSize * 2, 0)
	NumPut("UInt", in_size, in_blob, 0)
	NumPut("Ptr",  bytes.Ptr, in_blob, A_PtrSize)  ; pbData follows cbData at native pointer alignment

	ent := Buffer(StrPut(LLM_API_TOKEN_DPAPI_ENTROPY, "UTF-8"))
	StrPut(LLM_API_TOKEN_DPAPI_ENTROPY, ent, "UTF-8")
	ent_size := ent.Size - 1
	ent_blob := Buffer(A_PtrSize * 2, 0)
	NumPut("UInt", ent_size, ent_blob, 0)
	NumPut("Ptr",  ent.Ptr,  ent_blob, A_PtrSize)

	out_blob := Buffer(A_PtrSize * 2, 0)
	; CRYPTPROTECT_UI_FORBIDDEN = 0x1 — never prompt the user.
	ok := DllCall("Crypt32\CryptProtectData",
		"Ptr",  in_blob.Ptr,
		"Ptr",  0,           ; szDataDescr
		"Ptr",  ent_blob.Ptr,
		"Ptr",  0,           ; pvReserved
		"Ptr",  0,           ; pPromptStruct
		"UInt", 0x1,
		"Ptr",  out_blob.Ptr,
		"Int")
	if !ok
		return ""

	out_size := NumGet(out_blob, 0, "UInt")
	out_ptr  := NumGet(out_blob, A_PtrSize, "Ptr")
	if (out_size == 0 or out_ptr == 0)
		return ""

	; Copy out to a buffer we own, then LocalFree the DPAPI allocation.
	owned := Buffer(out_size, 0)
	DllCall("RtlMoveMemory", "Ptr", owned.Ptr, "Ptr", out_ptr, "UPtr", out_size)
	DllCall("Kernel32\LocalFree", "Ptr", out_ptr)
	return _LLM_Base64Encode(owned)
}

_LLM_DPAPI_Unprotect(b64) {
	global LLM_API_TOKEN_DPAPI_ENTROPY
	in_buf := _LLM_Base64Decode(b64)
	if (in_buf == "" or in_buf.Size == 0)
		return ""

	in_blob := Buffer(A_PtrSize * 2, 0)
	NumPut("UInt", in_buf.Size, in_blob, 0)
	NumPut("Ptr",  in_buf.Ptr,  in_blob, A_PtrSize)

	ent := Buffer(StrPut(LLM_API_TOKEN_DPAPI_ENTROPY, "UTF-8"))
	StrPut(LLM_API_TOKEN_DPAPI_ENTROPY, ent, "UTF-8")
	ent_size := ent.Size - 1
	ent_blob := Buffer(A_PtrSize * 2, 0)
	NumPut("UInt", ent_size, ent_blob, 0)
	NumPut("Ptr",  ent.Ptr,  ent_blob, A_PtrSize)

	out_blob := Buffer(A_PtrSize * 2, 0)
	ok := DllCall("Crypt32\CryptUnprotectData",
		"Ptr",  in_blob.Ptr,
		"Ptr",  0,
		"Ptr",  ent_blob.Ptr,
		"Ptr",  0,
		"Ptr",  0,
		"UInt", 0x1,
		"Ptr",  out_blob.Ptr,
		"Int")
	if !ok
		return ""

	out_size := NumGet(out_blob, 0, "UInt")
	out_ptr  := NumGet(out_blob, A_PtrSize, "Ptr")
	if (out_size == 0 or out_ptr == 0)
		return ""

	; Pull the UTF-8 bytes back into an AHK string.
	owned := Buffer(out_size + 1, 0)
	DllCall("RtlMoveMemory", "Ptr", owned.Ptr, "Ptr", out_ptr, "UPtr", out_size)
	NumPut("UChar", 0, owned, out_size)   ; null-terminate for StrGet
	DllCall("Kernel32\LocalFree", "Ptr", out_ptr)
	return StrGet(owned.Ptr, "UTF-8")
}




; ====================================
; ====================================
; ======= 4/ Base64 helpers ==========
; ====================================
; ====================================

; CryptBinaryToStringA / CryptStringToBinaryA give us standards-compliant
; base64 without a third-party dependency.

_LLM_Base64Encode(buf) {
	; 0x40000001 = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF — single line,
	; no CR/LF wrapping at 76 chars, so the output fits cleanly into TOML
	; / JSON values.
	flags := 0x40000001
	required := 0
	DllCall("Crypt32\CryptBinaryToStringW",
		"Ptr",   buf.Ptr,
		"UInt",  buf.Size,
		"UInt",  flags,
		"Ptr",   0,
		"UInt*", &required)
	if (required <= 0)
		return ""
	out := Buffer(required * 2, 0)
	DllCall("Crypt32\CryptBinaryToStringW",
		"Ptr",   buf.Ptr,
		"UInt",  buf.Size,
		"UInt",  flags,
		"Ptr",   out.Ptr,
		"UInt*", &required)
	return StrGet(out.Ptr, required, "UTF-16")
}

_LLM_Base64Decode(b64) {
	flags := 0x1   ; CRYPT_STRING_BASE64
	required := 0
	DllCall("Crypt32\CryptStringToBinaryW",
		"WStr",  b64,
		"UInt",  StrLen(b64),
		"UInt",  flags,
		"Ptr",   0,
		"UInt*", &required,
		"Ptr",   0,
		"Ptr",   0)
	if (required <= 0)
		return ""
	out := Buffer(required, 0)
	ok := DllCall("Crypt32\CryptStringToBinaryW",
		"WStr",  b64,
		"UInt",  StrLen(b64),
		"UInt",  flags,
		"Ptr",   out.Ptr,
		"UInt*", &required,
		"Ptr",   0,
		"Ptr",   0)
	if !ok
		return ""
	return out
}
