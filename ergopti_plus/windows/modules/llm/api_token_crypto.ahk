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

; Marker prefix on encrypted blobs. A prefixed value still has to pass strict
; base64 and DPAPI validation; everything else is treated as cleartext for
; backwards-compat with pre-encryption configs.
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
 * On any failure (DPAPI unavailable, locked account, malformed envelope, …)
 * returns false. Callers must refuse the complete persistence transaction.
 * @param {string} cleartext - The raw API token.
 * @param {Func} ProtectFn - Optional injected DPAPI adapter for tests.
 * @returns {string|false} ``dpapi:<base64>`` or false on failure.
 */
LLM_ApiToken_Encrypt(cleartext, ProtectFn := 0) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	if !(cleartext is String)
		return false
	if (cleartext == "")
		return ""
	; An opaque envelope may have survived a failed decrypt. Preserve it only
	; when it is still usable by this identity; never double-wrap it or accept a
	; user token that merely resembles the persistence marker.
	if _LLM_ApiToken_HasPrefix(cleartext)
		return LLM_ApiToken_IsValidEnvelope(cleartext) ? cleartext : false
	try encrypted_b64 := HasMethod(ProtectFn, "Call")
		? ProtectFn.Call(cleartext) : _LLM_DPAPI_Protect(cleartext)
	catch as Err {
		try LoggerError("ApiTokenCrypto", "DPAPI encryption failed: {1}.", Err.Message)
		return false
	}
	if !(encrypted_b64 is String) || encrypted_b64 == ""
		return false
	Candidate := LLM_API_TOKEN_DPAPI_PREFIX . encrypted_b64
	if !LLM_ApiToken_IsValidEnvelope(Candidate)
		return false
	return Candidate
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
 * @returns {string|false} Cleartext on success, the original valid envelope
 * on DPAPI failure, or false for a malformed envelope.
 */
LLM_ApiToken_Decrypt(stored) {
	if (stored == "")
		return ""
	if !_LLM_ApiToken_HasPrefix(stored)
		return stored
	if !LLM_ApiToken_IsEncrypted(stored) {
		try LoggerError("ApiTokenCrypto", "Rejected a malformed DPAPI token envelope.")
		return false
	}
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
 * Returns true only for a canonical, nonempty base64 envelope. This structural
 * predicate does not claim that the current Windows identity can decrypt it.
 */
LLM_ApiToken_IsEncrypted(stored) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	if !_LLM_ApiToken_HasPrefix(stored)
		return false
	Payload := SubStr(stored, StrLen(LLM_API_TOKEN_DPAPI_PREFIX) + 1)
	if (Payload == "")
		return false
	Decoded := _LLM_Base64Decode(Payload)
	return (Decoded is Buffer) && Decoded.Size > 0
		&& _LLM_Base64Encode(Decoded) == Payload
}

; A persistence image is authorized only when DPAPI can recover a nonempty
; secret under the current Windows identity. This closes the gap between a
; marker-shaped string and a real at-rest encryption boundary.
LLM_ApiToken_IsValidEnvelope(stored) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	if !LLM_ApiToken_IsEncrypted(stored)
		return false
	Payload := SubStr(stored, StrLen(LLM_API_TOKEN_DPAPI_PREFIX) + 1)
	try Plaintext := _LLM_DPAPI_Unprotect(Payload)
	catch
		return false
	return (Plaintext is String) && Plaintext != ""
}

_LLM_ApiToken_HasPrefix(stored) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	return (stored is String) && stored != ""
		&& SubStr(stored, 1, StrLen(LLM_API_TOKEN_DPAPI_PREFIX))
			== LLM_API_TOKEN_DPAPI_PREFIX
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
; LocalFree. The error path returns ""; the public boundary converts it into
; transaction refusal so plaintext can never become a persistence fallback.

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
