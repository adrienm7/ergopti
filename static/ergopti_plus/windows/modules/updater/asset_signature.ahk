; modules/updater/asset_signature.ahk

; ==============================================================================
; MODULE: Update Asset Signature Verification (Windows)
; DESCRIPTION:
; Verifies the detached signature of the Windows update asset against the key in
; _shared/modules/updater/asset_signing.json with the Windows CNG provider
; (ECDSA P-256, SHA-256). The signed record binds the asset name, its size and
; its SHA-256, so verification needs the digest the updater already holds, not
; the archive. tools/build/update-asset-signature.cjs signs; the shared vectors
; (_shared/tests/corpus/updater/asset_signature_vectors.json) are replayed by
; every verifier.
;
; FEATURES & RATIONALE:
; 1. Fail closed. Anything that is not a valid signature of exactly this record
;    (a malformed signature, a key that is not a P-256 SubjectPublicKeyInfo, a
;    CNG refusal) is a refusal with a closed reason, never a pass.
; 2. Enforcement is the policy's, stated and not silent: AssetSignature_Evaluate
;    returns "not_enforced" while the policy is off, and the caller logs it on
;    every update; "required" refuses everything that does not verify.
; 3. CNG, because it ships with every supported Windows: no binary and no
;    PowerShell. P-256 and not Ed25519 because CNG only gained Ed25519 recently.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; The fixed DER prefix of a P-256 SubjectPublicKeyInfo, up to the 0x04 marker of
; the uncompressed point (26 bytes), then 0x04, X (32) and Y (32): 91 bytes.
global ASSET_SIGNATURE_SPKI_PREFIX := "3059301306072a8648ce3d020106082a8648ce3d030107034200"
global ASSET_SIGNATURE_SPKI_BYTES := 91
global ASSET_SIGNATURE_COMPONENT_BYTES := 32





; =============================
; =============================
; ======= 2/ The record =======
; =============================
; =============================

/**
 * The canonical record a signature covers.
 * @param {string} Header - Policy record_header.
 * @param {string} Name - Asset file name.
 * @param {Integer} Size - Size in bytes.
 * @param {string} Sha256 - Lowercase hexadecimal digest.
 * @returns {string} "" when an input is not canonical.
 */
AssetSignature_Record(Header, Name, Size, Sha256) {
	if !(Header is String) || Header == "" || !(Name is String) || !RegExMatch(Name, "^[A-Za-z0-9._-]{1,128}$")
		return ""
	if !(Size is Integer) || Size < 0
		return ""
	if !(Sha256 is String) || !RegExMatch(Sha256, "^[0-9a-f]{64}$")
		return ""
	return Header . "`n" . Name . "`n" . Size . "`n" . Sha256 . "`n"
}





; ===============================
; ===============================
; ======= 3/ Verification =======
; ===============================
; ===============================

; Decodes canonical base64 into a Buffer, or returns 0.
_AssetSignature_Base64(Text) {
	if !(Text is String) || Text == "" || !RegExMatch(Text, "^[A-Za-z0-9+/]+=*$")
		return 0
	Size := 0
	; CRYPT_STRING_BASE64 (1) | CRYPT_STRING_STRICT_BASE64 is not needed: the
	; pattern above already refuses anything but canonical characters
	if !DllCall("Crypt32\CryptStringToBinaryW", "WStr", Text, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &Size,
		"Ptr", 0, "Ptr", 0, "Int") || Size == 0
		return 0
	Bytes := Buffer(Size)
	if !DllCall("Crypt32\CryptStringToBinaryW", "WStr", Text, "UInt", 0, "UInt", 1, "Ptr", Bytes, "UInt*", &Size,
		"Ptr", 0, "Ptr", 0, "Int")
		return 0
	Bytes.Size := Size
	return Bytes
}

; The lowercase hexadecimal text of the first Count bytes of a Buffer.
_AssetSignature_Hex(Bytes, Count) {
	Text := ""
	Loop Count
		Text .= Format("{:02x}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Text
}

; Closes the CNG handles opened by a verification.
_AssetSignature_Close(Key, KeyAlg, HashAlg) {
	if Key
		DllCall("bcrypt\BCryptDestroyKey", "Ptr", Key, "UInt")
	if KeyAlg
		DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", KeyAlg, "UInt", 0, "UInt")
	if HashAlg
		DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", HashAlg, "UInt", 0, "UInt")
}

/**
 * Verifies a signature of a record.
 * @param {string} SpkiBase64 - The policy's verification key.
 * @param {string} Record - The canonical record.
 * @param {string} SignatureBase64 - The published signature.
 * @returns {Map} "ok" (boolean) and "reason" ("" or no_signature, malformed_signature,
 *   bad_key, no_native, mismatch).
 */
AssetSignature_Verify(SpkiBase64, Record, SignatureBase64) {
	global ASSET_SIGNATURE_SPKI_PREFIX, ASSET_SIGNATURE_SPKI_BYTES, ASSET_SIGNATURE_COMPONENT_BYTES
	if !(SignatureBase64 is String) || SignatureBase64 == ""
		return Map("ok", false, "reason", "no_signature")
	Signature := _AssetSignature_Base64(SignatureBase64)
	if !(Signature is Buffer) || Signature.Size != 2 * ASSET_SIGNATURE_COMPONENT_BYTES
		return Map("ok", false, "reason", "malformed_signature")
	Spki := _AssetSignature_Base64(SpkiBase64)
	PrefixBytes := StrLen(ASSET_SIGNATURE_SPKI_PREFIX) // 2
	if !(Spki is Buffer) || Spki.Size != ASSET_SIGNATURE_SPKI_BYTES
			|| _AssetSignature_Hex(Spki, PrefixBytes) != ASSET_SIGNATURE_SPKI_PREFIX
			|| NumGet(Spki, PrefixBytes, "UChar") != 4
		return Map("ok", false, "reason", "bad_key")
	; BCRYPT_ECCKEY_BLOB: magic 'ECS1', the component size, then X and Y
	Blob := Buffer(8 + 2 * ASSET_SIGNATURE_COMPONENT_BYTES)
	NumPut("UInt", 0x31534345, Blob, 0)
	NumPut("UInt", ASSET_SIGNATURE_COMPONENT_BYTES, Blob, 4)
	DllCall("RtlMoveMemory", "Ptr", Blob.Ptr + 8, "Ptr", Spki.Ptr + PrefixBytes + 1,
		"UPtr", 2 * ASSET_SIGNATURE_COMPONENT_BYTES)
	KeyAlg := 0, HashAlg := 0, Key := 0
	Reason := "no_native"
	Verified := false
	try {
		if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", &KeyAlg, "WStr", "ECDSA_P256", "Ptr", 0, "UInt", 0, "UInt")
			throw Error("no ECDSA provider")
		if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", &HashAlg, "WStr", "SHA256", "Ptr", 0, "UInt", 0, "UInt")
			throw Error("no SHA-256 provider")
		Reason := "bad_key"
		if DllCall("bcrypt\BCryptImportKeyPair", "Ptr", KeyAlg, "Ptr", 0, "WStr", "ECCPUBLICBLOB", "Ptr*", &Key,
			"Ptr", Blob, "UInt", Blob.Size, "UInt", 0, "UInt")
			throw Error("key refused")
		Message := Buffer(StrPut(Record, "UTF-8") - 1)
		StrPut(Record, Message, Message.Size, "UTF-8")
		Hash := Buffer(32)
		Reason := "no_native"
		if DllCall("bcrypt\BCryptHash", "Ptr", HashAlg, "Ptr", 0, "UInt", 0, "Ptr", Message, "UInt", Message.Size,
			"Ptr", Hash, "UInt", Hash.Size, "UInt")
			throw Error("hash refused")
		Status := DllCall("bcrypt\BCryptVerifySignature", "Ptr", Key, "Ptr", 0, "Ptr", Hash, "UInt", Hash.Size,
			"Ptr", Signature, "UInt", Signature.Size, "UInt", 0, "UInt")
		Verified := (Status == 0)
		Reason := Verified ? "" : "mismatch"
	} catch {
		Verified := false
	}
	_AssetSignature_Close(Key, KeyAlg, HashAlg)
	return Map("ok", Verified, "reason", Reason)
}

/**
 * Admits the shared policy.
 * @param {Map} Policy - Decoded asset_signing.json.
 * @returns {string} "" when admitted, otherwise bad_policy or required_without_key.
 */
AssetSignature_AdmitPolicy(Policy) {
	if !(Policy is Map) || Policy.Get("schema_version", 0) != 1 || Policy.Get("algorithm", "") != "ecdsa-p256-sha256"
			|| Policy.Get("signature_bytes", 0) != 64 || !(Policy.Get("record_header", 0) is String)
			|| !(Policy.Get("signature_suffix", 0) is String) || !(Policy.Get("public_key_spki_base64", 0) is String)
			|| !(Policy.Get("enforcement", "") = "off" || Policy.Get("enforcement", "") = "required")
		return "bad_policy"
	if Policy["enforcement"] = "required" && Policy["public_key_spki_base64"] == ""
		return "required_without_key"
	return ""
}

/**
 * Decides what an update does with an asset's signature.
 * @param {Map} Policy - An admitted policy.
 * @param {Map} Asset - name, size, sha256.
 * @param {string} SignatureBase64 - The published signature, "" when none was published.
 * @returns {Map} "verdict" (verified, not_enforced or refused) and "reason".
 */
AssetSignature_Evaluate(Policy, Asset, SignatureBase64) {
	Required := (Policy["enforcement"] = "required")
	Record := AssetSignature_Record(Policy["record_header"], Asset["name"], Asset["size"], Asset["sha256"])
	if Record == ""
		return Map("verdict", Required ? "refused" : "not_enforced", "reason", "bad_asset")
	if !Required && Policy["public_key_spki_base64"] == ""
		return Map("verdict", "not_enforced", "reason", "policy_off")
	if !Required && SignatureBase64 == ""
		return Map("verdict", "not_enforced", "reason", "no_signature")
	Check := AssetSignature_Verify(Policy["public_key_spki_base64"], Record, SignatureBase64)
	if Check["ok"]
		return Map("verdict", "verified", "reason", "")
	return Map("verdict", Required ? "refused" : "not_enforced", "reason", Check["reason"])
}
