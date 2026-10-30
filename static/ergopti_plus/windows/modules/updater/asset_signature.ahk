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
; A bound on the published signature (base64 of 64 bytes is 88 characters).
global ASSET_SIGNATURE_BODY_LIMIT := 4096
; What each closed reason means, for the log. The wording of the Linux gate
; (linux/modules/updater/signature_gate.lua), with its verifier named.
global ASSET_SIGNATURE_REASON_TEXT := Map(
	"policy_off", "the signing policy is off",
	"no_signature", "the release publishes no signature for the executable",
	"malformed_signature", "the published signature is malformed",
	"bad_key", "the verification key of the signing policy is unusable",
	"no_native", "the Windows CNG provider cannot verify the signature",
	"mismatch", "the signature does not match the executable's size and digest",
	"bad_policy", "the signing policy file is invalid",
	"required_without_key", "the signing policy requires a signature but holds no key",
	"bad_asset", "the executable's name, size or digest cannot be signed",
	"fetch_failed", "the signature could not be downloaded")





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
	; The pattern above already refuses anything but canonical characters
	Bytes := CryptoBase64Decode(Text)
	return Bytes.Size == 0 ? 0 : Bytes
}

; The lowercase hexadecimal text of the first Count bytes of a Buffer.
_AssetSignature_Hex(Bytes, Count) {
	Text := ""
	Loop Count
		Text .= Format("{:02x}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Text
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
	Reason := CryptoEcdsaP256Verify(Spki, PrefixBytes + 1, ASSET_SIGNATURE_COMPONENT_BYTES, Record, Signature)
	return Map("ok", Reason == "", "reason", Reason)
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





; ==================================
; ==================================
; ======= 4/ The update gate =======
; ==================================
; ==================================

; The shared policy, as every verifier reads it.
; @returns {Map} The decoded asset_signing.json.
_AssetSignature_ReadPolicy() {
	global _SharedDir
	return JsonParse(FSReadStrict(_SharedDir . "\modules\updater\asset_signing.json"))
}

; Downloads a published signature, bounded, on the manual request's lifetime.
; @param Url {String} The authenticated repository URL of the signature asset.
; @param Request {Object} The install's request context.
; @returns {String} The signature text.
; @throws {Error} When the request gives no complete answer.
_AssetSignature_Fetch(Url, Request) {
	global ASSET_SIGNATURE_BODY_LIMIT, UPDATER_REQUEST_POLICY_ALLOW
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Started := A_TickCount
	Req := CurlAsyncRequest()
	Req.SetManagedRouting(0, () => _Updater_RequestPolicy(Request) == UPDATER_REQUEST_POLICY_ALLOW)
	Req.SetDeadline(Started, UPDATER_HTTP_RESOLVE_TIMEOUT_MS + UPDATER_HTTP_CONNECT_TIMEOUT_MS
		+ UPDATER_HTTP_SEND_TIMEOUT_MS + UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
	Req.Open("GET", Url, true)
	Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
	Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
		UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
	if !Req.Send() || !_HTTP_ManagedWait(Req)
		throw Error("the request did not complete")
	if (Req.Status != 200)
		throw Error("HTTP " . Req.Status)
	Text := Req.ResponseText
	if !Req.ResponseEncodingValid || StrLen(Text) > ASSET_SIGNATURE_BODY_LIMIT
		throw Error("the response is not a signature")
	return Text
}

/**
 * Decides whether an update may start, before anything is downloaded: the signed
 * record binds the name, the size and the digest the staging worker then enforces
 * on the downloaded bytes. A policy that cannot be read or admitted refuses
 * instead of skipping the check. With no key provisioned nothing is fetched.
 * @param {string} AssetName - The executable's asset name.
 * @param {Object} Asset - The authenticated asset: Size and Digest.
 * @param {Object} Release - The offered release: RawJson and Tag.
 * @param {Object} Request - The install's request context.
 * @param {Func|Integer} ReadPolicyFn - Replaces the policy read (tests only).
 * @param {Func|Integer} FetchFn - Replaces the download (tests only), called as (Url, Request).
 * @returns {Boolean} Whether the update may proceed.
 */
AssetSignature_AllowsInstall(AssetName, Asset, Release, Request, ReadPolicyFn := 0, FetchFn := 0) {
	global ASSET_SIGNATURE_REASON_TEXT
	Why := "bad_policy"
	try {
		Policy := IsObject(ReadPolicyFn) ? ReadPolicyFn.Call() : _AssetSignature_ReadPolicy()
		Why := AssetSignature_AdmitPolicy(Policy)
	} catch as Err
		try LoggerError("Updater", "The update signing policy could not be read: {1}.", Err.Message)
	if (Why != "") {
		try LoggerError("Updater", "Update refused: {1}.", ASSET_SIGNATURE_REASON_TEXT[Why])
		return false
	}
	Signature := "", FetchFailed := false
	if (Policy["public_key_spki_base64"] != "") {
		SignatureAsset := _Updater_FindAsset(Release.RawJson, AssetName . Policy["signature_suffix"], Release.Tag)
		if IsObject(SignatureAsset) {
			try Signature := Trim((IsObject(FetchFn) ? FetchFn : _AssetSignature_Fetch).Call(SignatureAsset.Url, Request),
				" `t`r`n")
			catch as Err {
				FetchFailed := true
				try LoggerWarn("Updater", "The update signature could not be downloaded: {1}.", Err.Message)
			}
		}
	}
	Result := AssetSignature_Evaluate(Policy, Map("name", AssetName, "size", Asset.Size, "sha256", Asset.Digest), Signature)
	Reason := Result["reason"]
	if (FetchFailed && Reason == "no_signature")
		Reason := "fetch_failed"
	switch Result["verdict"] {
		case "verified":
			try LoggerInfo("Updater", "Update signature verified.")
			return true
		case "not_enforced":
			try LoggerWarn("Updater", "Update signature not enforced: {1}.", ASSET_SIGNATURE_REASON_TEXT[Reason])
			return true
	}
	try LoggerError("Updater", "Update refused: {1}.", ASSET_SIGNATURE_REASON_TEXT[Reason])
	return false
}
