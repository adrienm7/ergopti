; tests/unit/ai/api/test_rs256_signer.ahk

; ==============================================================================
; MODULE: RS256 Signer Corpus (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/crypto/rs256_vectors.json through the CNG signer:
; SHA-256 digests, RSASSA-PKCS1-v1_5 signatures made by an independent
; implementation under PKCS#8 and PKCS#1 test keys of 2048 and 3072 bits, and the
; keys refused with their reasons. macOS and Linux replay the same corpus through
; the pure-Lua signer.
;
; ROOT CAUSE ENCODED:
; A Google service-account key needs its assertion signed RS256, and CNG alone
; would sign under a key file whose CRT values disagree, which the other drivers
; refuse: the signer checks them itself.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Fixtures ===========
; ===============================
; ===============================

_LTE_ReadJson(Relative) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\" . Relative, "UTF-8"))
}

_LTE_Rs256Corpus() {
	return _LTE_ReadJson("tests\corpus\crypto\rs256_vectors.json")
}

; A PEM block from a label and its armorless Base64 body.
_LTE_Pem(Label, Body) {
	Lines := "", At := 1
	while (At <= StrLen(Body)) {
		Lines .= SubStr(Body, At, 64) . "`n"
		At += 64
	}
	Armour := "-----"
	return Armour . "BEGIN " . Label . Armour . "`n" . Lines . Armour . "END " . Label . Armour . "`n"
}

_LTE_Hex(Bytes) {
	Hex := ""
	loop Bytes.Size
		Hex .= Format("{:02x}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}

_LTE_Unhex(Text) {
	Bytes := Buffer(StrLen(Text) // 2)
	loop Bytes.Size
		NumPut("UChar", Integer("0x" . SubStr(Text, A_Index * 2 - 1, 2)), Bytes, A_Index - 1)
	return Bytes
}




; ===============================
; ===============================
; ======= 2/ The corpus =========
; ===============================
; ===============================

_LTE_Sha256() {
	Rows := _LTE_Rs256Corpus()["sha256"]
	AssertTrue(Rows.Length >= 4, "the corpus holds digests")
	for Row in Rows
		AssertEqual(Row["digest"], _LTE_Hex(LLM_Rs256_Sha256(_LTE_Unhex(Row["hex_message"]))),
			StrLen(Row["hex_message"]) // 2 . " bytes")
}
Test("RS256: the SHA-256 digests of the corpus", _LTE_Sha256)

_LTE_Signatures() {
	Corpus := _LTE_Rs256Corpus()
	AssertTrue(Corpus["signatures"].Length >= 12, "signatures under three keys")
	for Row in Corpus["signatures"] {
		Spec := Corpus["keys"][Row["key"]]
		Signature := LLM_Rs256_Sign(_LTE_Pem(Spec["label"], Spec["body"]), Row["message"], &Reason)
		AssertEqual("", Reason, Row["key"])
		AssertEqual(Row["signature"], _LTE_Hex(Signature), Row["key"] . " of " . StrLen(Row["message"]) . " byte(s)")
	}
}
Test("RS256: every signature of the corpus, byte for byte, PKCS#8 and PKCS#1, 2048 and 3072 bits", _LTE_Signatures)

_LTE_Refusals() {
	Corpus := _LTE_Rs256Corpus()
	AssertTrue(Corpus["refusals"].Length >= 6, "the corpus holds refusals")
	for Row in Corpus["refusals"] {
		Expected := Row.Has("sign_reason") ? Row["sign_reason"] : Row["reason"]
		AssertEqual("", LLM_Rs256_Sign(_LTE_Pem(Row["label"], Row["body"]), "abc", &Reason), Row["name"] . ": no signature")
		AssertEqual(Expected, Reason, Row["name"])
		AssertFalse(InStr(Reason, SubStr(Row["body"], 1, 16), true), Row["name"] . ": the reason never quotes the key")
	}
}
Test("RS256: the corpus's refused keys, with their reasons", _LTE_Refusals)

_LTE_NoArmour() {
	AssertEqual("", LLM_Rs256_Sign(_LTE_Rs256Corpus()["keys"]["rsa2048_pkcs8"]["body"], "abc", &Reason))
	AssertEqual("the private key is no PEM block", Reason)
	AssertEqual("", LLM_Rs256_Sign("", "abc", &Reason))
	AssertEqual("the private key is empty", Reason)
}
Test("RS256: a key without its PEM armour is refused", _LTE_NoArmour)

; Value mod Divisor against an independent answer, the carry cases of the division.
_LTE_Reduce() {
	Limbs := (Text) => _LLM_Rs256_LimbsOf(_LTE_Unhex(Text), 0, StrLen(Text) // 2)
	; 2^32 is -15 here, so 2^64 + 5 is 225 + 5; the divisor's top limb is small
	AssertEqual(230, _LLM_Rs256_Reduce(Limbs("010000000000000005"), Limbs("010000000F"))[1], "2^64 + 5 mod 2^32 + 15")
	AssertEqual(0, _LLM_Rs256_Reduce(Limbs("FFFF0000FFFF0000"), Limbs("FFFF0000")).Length,
		"an exact multiple leaves nothing")
	AssertTrue(_LLM_Rs256_ProductIsOne(Limbs("03"), Limbs("05"), Limbs("0E")), "3 * 5 mod 14 is 1")
	AssertFalse(_LLM_Rs256_ProductIsOne(Limbs("03"), Limbs("04"), Limbs("0E")), "3 * 4 mod 14 is 12")
}
Test("RS256: the consistency check's division", _LTE_Reduce)

; The signature must not hold the driver's only thread for a noticeable time.
_LTE_SignCost() {
	Spec := _LTE_Rs256Corpus()["keys"]["rsa2048_pkcs8"]
	Pem := _LTE_Pem(Spec["label"], Spec["body"])
	Best := 0x7FFFFFFF
	loop 3 {
		Start := A_TickCount
		LLM_Rs256_Sign(Pem, "cost", &Reason)
		Best := Min(Best, A_TickCount - Start)
	}
	AssertEqual("", Reason)
	AssertTrue(Best < 150, "a 2048-bit signature stays under 150 ms (took " . Best . ")")
}
Test("RS256: a signature is short enough for a one-shot timer", _LTE_SignCost)
