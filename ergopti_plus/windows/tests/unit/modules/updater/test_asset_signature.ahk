; tests/unit/modules/updater/test_asset_signature.ahk

; ==============================================================================
; MODULE: Update Asset Signature Tests (Windows)
; DESCRIPTION:
; The Windows verifier (modules/updater/asset_signature.ahk, CNG ECDSA P-256)
; replays the vectors shared with the reference tool and the Linux verifier:
; 1. the valid record verifies, and each tampered record (size, name, digest) is
;    refused with the same signature;
; 2. a missing, malformed or truncated signature and an unusable key are closed
;    refusals, never a pass or a raised error;
; 3. the policy decides: off reports "not enforced", required refuses everything
;    that does not verify, and a policy that requires a key without one is
;    refused at admission.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_TAS_Vectors() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\updater\asset_signature_vectors.json", "UTF-8"))
}

_TAS_Record(Vectors, Entry) {
	return AssetSignature_Record(Vectors["record_header"], Entry["name"], Entry["size"], Entry["sha256"])
}

_TAS_Policy(Vectors, Enforcement := "required", Key := unset) {
	return Map("schema_version", 1, "algorithm", "ecdsa-p256-sha256", "signature_bytes", 64,
		"record_header", Vectors["record_header"], "signature_suffix", ".sig",
		"public_key_spki_base64", IsSet(Key) ? Key : Vectors["public_key_spki_base64"],
		"enforcement", Enforcement)
}





; ==============================
; ==============================
; ======= 2/ The vectors =======
; ==============================
; ==============================

_TAS_ValidVerifies() {
	V := _TAS_Vectors()
	Record := _TAS_Record(V, V["valid"])
	AssertEqual(V["record_header"] . "`n" . V["valid"]["name"] . "`n" . V["valid"]["size"] . "`n" . V["valid"]["sha256"] . "`n", Record)
	Result := AssetSignature_Verify(V["public_key_spki_base64"], Record, V["valid"]["signature_base64"])
	AssertTrue(Result["ok"], "the valid vector is refused: " . Result["reason"])
}

Test("AssetSignature: the shared valid vector verifies through CNG (asset-signature)", _TAS_ValidVerifies)


_TAS_TamperedRefused() {
	V := _TAS_Vectors()
	Assert(V["tampered"].Length >= 3, "the shared tampered vectors are missing")
	for Entry in V["tampered"] {
		Result := AssetSignature_Verify(V["public_key_spki_base64"], _TAS_Record(V, Entry), V["valid"]["signature_base64"])
		AssertFalse(Result["ok"], Entry["why"] . " must not verify")
		AssertEqual("mismatch", Result["reason"], Entry["why"])
	}
}

Test("AssetSignature: every tampered record is refused with the valid signature (asset-signature)", _TAS_TamperedRefused)


_TAS_ClosedRefusals() {
	V := _TAS_Vectors()
	Record := _TAS_Record(V, V["valid"])
	Signature := V["valid"]["signature_base64"]
	Cases := [["", "no_signature"], ["not base64!", "malformed_signature"], ["AAAA", "malformed_signature"],
		[SubStr(Signature, 1, StrLen(Signature) - 4), "malformed_signature"], [Signature . "AA==", "malformed_signature"]]
	for Pair in Cases {
		Result := AssetSignature_Verify(V["public_key_spki_base64"], Record, Pair[1])
		AssertFalse(Result["ok"])
		AssertEqual(Pair[2], Result["reason"])
	}
	Result := AssetSignature_Verify("", Record, Signature)
	AssertEqual("bad_key", Result["reason"], "an empty key")
	Result := AssetSignature_Verify("AAAA", Record, Signature)
	AssertEqual("bad_key", Result["reason"], "bytes that are not a public key")
	AssertEqual("", AssetSignature_Record(V["record_header"], "..\x", 1, V["valid"]["sha256"]), "a path is not an asset name")
	AssertEqual("", AssetSignature_Record(V["record_header"], "x", -1, V["valid"]["sha256"]))
	AssertEqual("", AssetSignature_Record(V["record_header"], "x", 1, StrUpper(V["valid"]["sha256"])))
}

Test("AssetSignature: a missing, malformed or truncated signature is a closed refusal (asset-signature)", _TAS_ClosedRefusals)





; =============================
; =============================
; ======= 3/ The policy =======
; =============================
; =============================

_TAS_PolicyAdmission() {
	V := _TAS_Vectors()
	AssertEqual("", AssetSignature_AdmitPolicy(_TAS_Policy(V)))
	AssertEqual("", AssetSignature_AdmitPolicy(_TAS_Policy(V, "off", "")))
	AssertEqual("required_without_key", AssetSignature_AdmitPolicy(_TAS_Policy(V, "required", "")))
	AssertEqual("bad_policy", AssetSignature_AdmitPolicy(_TAS_Policy(V, "maybe")))
	AssertEqual("bad_policy", AssetSignature_AdmitPolicy(0))
}

Test("AssetSignature: the policy admits only what it can honour (asset-signature)", _TAS_PolicyAdmission)


_TAS_Enforcement() {
	V := _TAS_Vectors()
	Asset := Map("name", V["valid"]["name"], "size", V["valid"]["size"], "sha256", V["valid"]["sha256"])
	Moved := Map("name", V["valid"]["name"], "size", V["valid"]["size"] + 1, "sha256", V["valid"]["sha256"])
	Signature := V["valid"]["signature_base64"]
	Required := _TAS_Policy(V)
	AssertEqual("verified", AssetSignature_Evaluate(Required, Asset, Signature)["verdict"])
	Missing := AssetSignature_Evaluate(Required, Asset, "")
	AssertEqual("refused", Missing["verdict"])
	AssertEqual("no_signature", Missing["reason"])
	Crossed := AssetSignature_Evaluate(Required, Moved, Signature)
	AssertEqual("refused", Crossed["verdict"])
	AssertEqual("mismatch", Crossed["reason"])
	Off := _TAS_Policy(V, "off")
	AssertEqual("no_signature", AssetSignature_Evaluate(Off, Asset, "")["reason"])
	AssertEqual("not_enforced", AssetSignature_Evaluate(Off, Asset, "")["verdict"])
	AssertEqual("verified", AssetSignature_Evaluate(Off, Asset, Signature)["verdict"])
	Reported := AssetSignature_Evaluate(Off, Moved, Signature)
	AssertEqual("not_enforced", Reported["verdict"])
	AssertEqual("mismatch", Reported["reason"], "a bad signature is reported although the policy is off")
	Unprovisioned := AssetSignature_Evaluate(_TAS_Policy(V, "off", ""), Asset, "")
	AssertEqual("policy_off", Unprovisioned["reason"])
}

Test("AssetSignature: required refuses what does not verify, off only reports it (asset-signature)", _TAS_Enforcement)
