; ai/engine/api/rs256_signer.ahk

; ==============================================================================
; MODULE: RS256 Signer (Windows CNG)
; DESCRIPTION:
; Signs bytes with RSASSA-PKCS1-v1_5 and SHA-256 (JWT RS256) under an unencrypted
; PEM private key, PKCS#8 or PKCS#1: the Windows twin of the pure-Lua
; _shared/core/crypto/engine/rsa_pkcs1.lua, replaying the same corpus and refusing with
; the same refusals (_shared/tests/corpus/crypto/rs256_vectors.json).
;
; FEATURES & RATIONALE:
; 1. CNG signs a 2048-bit key in about 2 ms, so nothing is sliced over timer ticks
;    as the Lua signer must be; the caller only runs it off the requesting thread.
; 2. The DER is read here rather than by CryptDecodeObjectEx: its PKCS#8 and
;    CNG_RSA_PRIVATE_KEY_BLOB structures cannot tell the refusals apart, and the
;    blob they give drops the CRT values the corpus requires checked.
; 3. CNG recomputes the CRT values from the primes, so a wrong dq still signs
;    correctly here. The other drivers would produce a bad signature from such a
;    file, so it is refused here too: the same key behaves alike on every OS.
; 4. No key material reaches a refusal. Every buffer and limb array holding it is
;    zeroed before return; the PEM text itself is the caller's immutable string.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Constants ==========
; ===============================
; ===============================

; Modulus sizes taken, in bits: below is unsafe, above is no key Google issues
global LLM_RS256_MIN_MODULUS_BITS := 2048
global LLM_RS256_MAX_MODULUS_BITS := 4096

global LLM_RS256_LABEL_PKCS8 := "PRIVATE KEY"
global LLM_RS256_LABEL_PKCS1 := "RSA PRIVATE KEY"
; DER of the rsaEncryption object identifier, 1.2.840.113549.1.1.1
global LLM_RS256_RSA_OID := "2A864886F70D010101"

global LLM_RS256_DER_INTEGER := 0x02
global LLM_RS256_DER_OCTET_STRING := 0x04
global LLM_RS256_DER_OID := 0x06
global LLM_RS256_DER_SEQUENCE := 0x30

; BCRYPT_RSAFULLPRIVATE_MAGIC
global LLM_RS256_FULL_PRIVATE_MAGIC := 0x33415352

global LLM_RS256_VALUES_DISAGREE := "the private key values disagree: the signature does not verify"




; ===============================
; ===============================
; ======= 2/ Public API =========
; ===============================
; ===============================

/**
 * The RSASSA-PKCS1-v1_5 SHA-256 signature of a text.
 * @param {String} Pem PKCS#8 (PRIVATE KEY) or PKCS#1 (RSA PRIVATE KEY) PEM block.
 * @param {String} Message The signed text, as UTF-8 without a NUL.
 * @param {VarRef} Refusal Receives why it is refused, "" when signed; never the key.
 * @returns {Buffer|String} The signature, as long as the modulus; "" when refused.
 */
LLM_Rs256_Sign(Pem, Message, &Refusal := "") {
	Refusal := ""
	Der := _LLM_Rs256_PemToDer(Pem, &Refusal, &Label)
	if !(Der is Buffer)
		return ""
	Values := 0
	try {
		Values := _LLM_Rs256_ReadValues(Der, Label, &Refusal)
		if !(Values is Map)
			return ""
		Refusal := _LLM_Rs256_CheckValues(Values)
		if (Refusal != "")
			return ""
		return _LLM_Rs256_SignNative(Values, Message, &Refusal)
	} finally {
		_LLM_Rs256_Zero(Der)
		if Values is Map
			_LLM_Rs256_WipeValues(Values)
	}
}

/**
 * The SHA-256 digest of some bytes, through CNG's one-shot hash.
 * @param {Buffer} Data The bytes.
 * @returns {Buffer} 32 bytes.
 */
LLM_Rs256_Sha256(Data) {
	return CryptoSha256Digest(Data)
}




; ===============================
; ===============================
; ======= 3/ Key Reading ========
; ===============================
; ===============================

; The DER of a PEM block, refused with rsa_pkcs1.lua's refusals.
; @param {String} Pem The PEM text.
; @param {VarRef} Refusal Why it is refused.
; @param {VarRef} Label The block's label.
; @returns {Buffer|String} The DER, "" when refused.
_LLM_Rs256_PemToDer(Pem, &Refusal, &Label) {
	global LLM_RS256_LABEL_PKCS8, LLM_RS256_LABEL_PKCS1
	Label := ""
	if !(Pem is String) || (Pem == "") {
		Refusal := "the private key is empty"
		return ""
	}
	if !RegExMatch(Pem, "s)^\s*-----BEGIN ([A-Z ]+)-----(.*?)-----END ([A-Z ]+)-----\s*$", &Block) {
		Refusal := "the private key is no PEM block"
		return ""
	}
	Label := Block[1]
	if (Label !== LLM_RS256_LABEL_PKCS8 && Label !== LLM_RS256_LABEL_PKCS1) {
		Refusal := "the private key is a " . Label . ", not an unencrypted RSA key"
		return ""
	}
	if (Block[3] !== Label) {
		Refusal := "the private key PEM labels differ"
		return ""
	}
	; CryptStringToBinary skips what is no Base64, so a bad body is refused here
	Body := RegExReplace(Block[2], "\s")
	if (StrLen(Body) == 0 || Mod(StrLen(Body), 4) != 0 || !RegExMatch(Body, "^[A-Za-z0-9+/]+={0,2}$")) {
		Refusal := "the private key is no Base64"
		return ""
	}
	Der := CryptoBase64Decode(Body)
	if (Der.Size == 0) {
		Refusal := "the private key is no Base64"
		return ""
	}
	return Der
}

; Reads one DER element.
; @param {Buffer} Der The bytes.
; @param {Integer} At Offset of its tag.
; @param {Integer} End Offset after the enclosing content.
; @returns {Map|String} "tag", "at" (content offset), "size", "next"; "" when malformed.
_LLM_Rs256_DerElement(Der, At, End) {
	if (At + 2 > End)
		return ""
	Tag := NumGet(Der, At, "UChar")
	Size := NumGet(Der, At + 1, "UChar")
	Content := At + 2
	if (Size >= 128) {
		Count := Size - 128
		if (Count < 1 || Count > 3 || Content + Count > End)
			return ""
		Size := 0
		loop Count
			Size := Size * 256 + NumGet(Der, Content + A_Index - 1, "UChar")
		Content += Count
	}
	if (Content + Size > End)
		return ""
	return Map("tag", Tag, "at", Content, "size", Size, "next", Content + Size)
}

; The elements of a DER content.
; @returns {Array|String} The elements, "" when one is malformed.
_LLM_Rs256_DerChildren(Der, At, End) {
	Children := []
	while (At < End) {
		Child := _LLM_Rs256_DerElement(Der, At, End)
		if !(Child is Map)
			return ""
		Children.Push(Child)
		At := Child["next"]
	}
	return Children
}

; The uppercase hexadecimal of a DER element's content.
_LLM_Rs256_DerHex(Der, Element) {
	Hex := ""
	loop Element["size"]
		Hex .= Format("{:02X}", NumGet(Der, Element["at"] + A_Index - 1, "UChar"))
	return Hex
}

; Reads the RSA values of a key, PKCS#8 unwrapped first.
; @returns {Map|String} The values (_LLM_Rs256_ReadPkcs1), "" when refused.
_LLM_Rs256_ReadValues(Der, Label, &Refusal) {
	global LLM_RS256_LABEL_PKCS1, LLM_RS256_RSA_OID, LLM_RS256_DER_INTEGER, LLM_RS256_DER_OCTET_STRING
	global LLM_RS256_DER_OID, LLM_RS256_DER_SEQUENCE
	Outer := _LLM_Rs256_DerElement(Der, 0, Der.Size)
	if !(Outer is Map) || Outer["tag"] != LLM_RS256_DER_SEQUENCE || Outer["next"] != Der.Size {
		Refusal := "the private key is no DER sequence"
		return ""
	}
	if (Label == LLM_RS256_LABEL_PKCS1)
		return _LLM_Rs256_ReadPkcs1(Der, 0, Der.Size, &Refusal)
	; PrivateKeyInfo: version, AlgorithmIdentifier, OCTET STRING privateKey
	Items := _LLM_Rs256_DerChildren(Der, Outer["at"], Outer["next"])
	if !(Items is Array) || Items.Length < 3 || Items[1]["tag"] != LLM_RS256_DER_INTEGER
			|| _LLM_Rs256_DerHex(Der, Items[1]) != "00" {
		Refusal := "the private key is no PKCS#8 key"
		return ""
	}
	Algorithm := Items[2]["tag"] == LLM_RS256_DER_SEQUENCE
		? _LLM_Rs256_DerChildren(Der, Items[2]["at"], Items[2]["next"]) : ""
	if !(Algorithm is Array) || Algorithm.Length < 1 || Algorithm[1]["tag"] != LLM_RS256_DER_OID
			|| _LLM_Rs256_DerHex(Der, Algorithm[1]) != LLM_RS256_RSA_OID {
		Refusal := "the private key is no RSA key"
		return ""
	}
	if (Items[3]["tag"] != LLM_RS256_DER_OCTET_STRING) {
		Refusal := "the private key is no PKCS#8 key"
		return ""
	}
	return _LLM_Rs256_ReadPkcs1(Der, Items[3]["at"], Items[3]["next"], &Refusal)
}

; Reads a PKCS#1 RSAPrivateKey.
; @param {Buffer} Der The bytes.
; @param {Integer} At Offset of its SEQUENCE.
; @param {Integer} End Offset after it.
; @returns {Map|String} "n", "e", "d", "p", "q", "dp", "dq", "qinv" as limb arrays,
;     "bits" the modulus size; "" when refused.
_LLM_Rs256_ReadPkcs1(Der, At, End, &Refusal) {
	global LLM_RS256_DER_SEQUENCE, LLM_RS256_DER_INTEGER, LLM_RS256_MIN_MODULUS_BITS, LLM_RS256_MAX_MODULUS_BITS
	Outer := _LLM_Rs256_DerElement(Der, At, End)
	if !(Outer is Map) || Outer["tag"] != LLM_RS256_DER_SEQUENCE || Outer["next"] != End {
		Refusal := "the private key is no DER sequence"
		return ""
	}
	Items := _LLM_Rs256_DerChildren(Der, Outer["at"], Outer["next"])
	if !(Items is Array) || Items.Length != 9 {
		Refusal := "the private key is no two-prime RSA key"
		return ""
	}
	for Item in Items {
		if (Item["tag"] != LLM_RS256_DER_INTEGER) {
			Refusal := "the private key holds a field that is no integer"
			return ""
		}
	}
	if (_LLM_Rs256_DerHex(Der, Items[1]) != "00") {
		Refusal := "the private key has an unknown version"
		return ""
	}
	Values := Map()
	for Index, Name in ["n", "e", "d", "p", "q", "dp", "dq", "qinv"] {
		Item := Items[Index + 1]
		if (Item["size"] > 0 && NumGet(Der, Item["at"], "UChar") >= 128) {
			_LLM_Rs256_WipeValues(Values)
			Refusal := "the private key holds a negative integer"
			return ""
		}
		Values[Name] := _LLM_Rs256_LimbsOf(Der, Item["at"], Item["size"])
	}
	Bits := _LLM_Rs256_BitLength(Values["n"])
	if (Bits < LLM_RS256_MIN_MODULUS_BITS || Bits > LLM_RS256_MAX_MODULUS_BITS) {
		_LLM_Rs256_WipeValues(Values)
		Refusal := "the private key modulus is not between 2048 and 4096 bits"
		return ""
	}
	Values["bits"] := Bits
	P := Values["p"], Q := Values["q"], N := Values["n"]
	if (P.Length == 0 || Q.Length == 0 || !(P[1] & 1) || !(Q[1] & 1) || !(N[1] & 1)) {
		_LLM_Rs256_WipeValues(Values)
		Refusal := "the private key primes are invalid"
		return ""
	}
	Product := _LLM_Rs256_Multiply(P, Q)
	Same := _LLM_Rs256_Compare(Product, N) == 0
	_LLM_Rs256_WipeLimbs(Product)
	if !Same {
		_LLM_Rs256_WipeValues(Values)
		Refusal := "the private key primes do not multiply to its modulus"
		return ""
	}
	return Values
}





; ===============================
; ===============================
; ======= 4/ Big Integers =======
; ===============================
; ===============================

; A big integer is an Array of 16-bit limbs, least significant first, without a
; leading zero limb; zero is the empty Array. Every product stays far below 2^63.

; A big integer from big-endian bytes.
_LLM_Rs256_LimbsOf(Bytes, At, Size) {
	Limbs := []
	Limbs.Capacity := Size // 2 + 1
	Position := At + Size - 1
	while (Position >= At) {
		Limb := NumGet(Bytes, Position, "UChar")
		if (Position > At)
			Limb += NumGet(Bytes, Position - 1, "UChar") * 256
		Limbs.Push(Limb)
		Position -= 2
	}
	return _LLM_Rs256_Trim(Limbs)
}

_LLM_Rs256_Trim(Limbs) {
	while (Limbs.Length > 0 && Limbs[Limbs.Length] == 0)
		Limbs.Pop()
	return Limbs
}

; The bytes a big integer needs, without a leading zero byte.
_LLM_Rs256_ByteLength(Limbs) {
	if (Limbs.Length == 0)
		return 0
	return (Limbs.Length - 1) * 2 + (Limbs[Limbs.Length] >= 256 ? 2 : 1)
}

_LLM_Rs256_BitLength(Limbs) {
	if (Limbs.Length == 0)
		return 0
	Top := Limbs[Limbs.Length], Bits := 0
	while (Top > 0)
		Bits += 1, Top >>= 1
	return (Limbs.Length - 1) * 16 + Bits
}

; @returns {Integer} -1, 0 or 1.
_LLM_Rs256_Compare(A, B) {
	if (A.Length != B.Length)
		return A.Length < B.Length ? -1 : 1
	Index := A.Length
	while (Index >= 1) {
		if (A[Index] != B[Index])
			return A[Index] < B[Index] ? -1 : 1
		Index -= 1
	}
	return 0
}

_LLM_Rs256_Multiply(A, B) {
	Out := []
	Out.Length := A.Length + B.Length
	loop Out.Length
		Out[A_Index] := 0
	for I, Left in A {
		Carry := 0
		for J, Right in B {
			Value := Out[I + J - 1] + Left * Right + Carry
			Out[I + J - 1] := Value & 0xFFFF
			Carry := Value >> 16
		}
		Out[I + B.Length] += Carry
	}
	return _LLM_Rs256_Trim(Out)
}

; Value - Divisor * Factor * Base^Shift in place; the caller keeps it non-negative.
_LLM_Rs256_SubtractScaled(Value, Divisor, Factor, Shift) {
	Borrow := 0
	for Index, Limb in Divisor {
		Diff := Value[Index + Shift] - Limb * Factor - Borrow
		Value[Index + Shift] := Diff & 0xFFFF
		Borrow := -(Diff >> 16)
	}
	Index := Divisor.Length + Shift + 1
	while (Borrow > 0) {
		Diff := Value[Index] - Borrow
		Value[Index] := Diff & 0xFFFF
		Borrow := -(Diff >> 16)
		Index += 1
	}
	_LLM_Rs256_Trim(Value)
}

; The two limbs of a value from a position down, as one integer.
_LLM_Rs256_Top(Limbs, Index) {
	High := (Index >= 1 && Index <= Limbs.Length) ? Limbs[Index] : 0
	Low := (Index >= 2 && Index - 1 <= Limbs.Length) ? Limbs[Index - 1] : 0
	return High * 0x10000 + Low
}

; Value mod Divisor, consuming Value: long division on limbs. Each factor is read
; from the top limbs against a rounded-up divisor, so it never overshoots and a
; further pass takes what it left.
; @returns {Array} Value, now the remainder.
_LLM_Rs256_Reduce(Value, Divisor) {
	Length := Divisor.Length
	DivisorTop := _LLM_Rs256_Top(Divisor, Length) + 1
	while (_LLM_Rs256_CompareShifted(Value, Divisor, 0) >= 0) {
		Shift := Value.Length - Length
		if (_LLM_Rs256_CompareShifted(Value, Divisor, Shift) < 0)
			Shift -= 1
		Index := Length + Shift
		Head := _LLM_Rs256_Top(Value, Index)
		if (Index < Value.Length)
			Head += Value[Index + 1] * 0x100000000
		_LLM_Rs256_SubtractScaled(Value, Divisor, Max(Head // DivisorTop, 1), Shift)
	}
	return Value
}

; Compares Value with Divisor * Base^Shift.
_LLM_Rs256_CompareShifted(Value, Divisor, Shift) {
	Length := Divisor.Length + Shift
	if (Value.Length != Length)
		return Value.Length < Length ? -1 : 1
	Index := Divisor.Length
	while (Index >= 1) {
		Limb := Value[Index + Shift]
		if (Limb != Divisor[Index])
			return Limb < Divisor[Index] ? -1 : 1
		Index -= 1
	}
	Index := Shift
	while (Index >= 1) {
		if (Value[Index] != 0)
			return 1
		Index -= 1
	}
	return 0
}

; A big integer minus one, for an odd prime: its lowest limb only changes.
_LLM_Rs256_MinusOne(Limbs) {
	Out := Limbs.Clone()
	Out[1] -= 1
	return _LLM_Rs256_Trim(Out)
}

; Whether (A * B) mod Modulus is 1.
_LLM_Rs256_ProductIsOne(A, B, Modulus) {
	Rest := _LLM_Rs256_Reduce(_LLM_Rs256_Multiply(A, B), Modulus)
	IsOne := Rest.Length == 1 && Rest[1] == 1
	_LLM_Rs256_WipeLimbs(Rest)
	return IsOne
}




; ===============================
; ===============================
; ======= 5/ Signature ==========
; ===============================
; ===============================

; The check CNG does not make: rsa_pkcs1.lua signs through dp, dq and qinv, so a
; key whose CRT values disagree is refused there, and must be here.
; @returns {String} The refusal, "" when the values agree.
_LLM_Rs256_CheckValues(Values) {
	global LLM_RS256_VALUES_DISAGREE
	PLess := _LLM_Rs256_MinusOne(Values["p"])
	QLess := _LLM_Rs256_MinusOne(Values["q"])
	try {
		if (Values["e"].Length == 0 || PLess.Length == 0 || QLess.Length == 0)
			return LLM_RS256_VALUES_DISAGREE
		if (_LLM_Rs256_Compare(Values["dp"], Values["p"]) >= 0 || _LLM_Rs256_Compare(Values["dq"], Values["q"]) >= 0
				|| _LLM_Rs256_Compare(Values["qinv"], Values["p"]) >= 0 || _LLM_Rs256_Compare(Values["d"], Values["n"]) >= 0)
			return LLM_RS256_VALUES_DISAGREE
		if !_LLM_Rs256_ProductIsOne(Values["e"], Values["dp"], PLess)
				|| !_LLM_Rs256_ProductIsOne(Values["e"], Values["dq"], QLess)
				|| !_LLM_Rs256_ProductIsOne(Values["qinv"], Values["q"], Values["p"])
			return LLM_RS256_VALUES_DISAGREE
		return ""
	} finally {
		_LLM_Rs256_WipeLimbs(PLess)
		_LLM_Rs256_WipeLimbs(QLess)
	}
}

; Writes a big integer big-endian, left-padded to Width, at Offset.
_LLM_Rs256_PutLimbs(Blob, Offset, Limbs, Width) {
	for Index, Limb in Limbs {
		Low := Offset + Width - (Index - 1) * 2 - 1
		NumPut("UChar", Limb & 0xFF, Blob, Low)
		if (Limb >= 256)
			NumPut("UChar", Limb >> 8, Blob, Low - 1)
	}
}

; The BCRYPT_RSAKEY_BLOB of a full private key: the header, then e, n, p, q, dp,
; dq, qinv and d. CheckValues has bounded every value by its field's width.
_LLM_Rs256_FullBlob(Values) {
	global LLM_RS256_FULL_PRIVATE_MAGIC
	Exponent := _LLM_Rs256_ByteLength(Values["e"])
	Modulus := _LLM_Rs256_ByteLength(Values["n"])
	Prime1 := _LLM_Rs256_ByteLength(Values["p"])
	Prime2 := _LLM_Rs256_ByteLength(Values["q"])
	Blob := Buffer(24 + Exponent + Modulus * 2 + Prime1 * 3 + Prime2 * 2, 0)
	NumPut("UInt", LLM_RS256_FULL_PRIVATE_MAGIC, Blob, 0)
	NumPut("UInt", Values["bits"], Blob, 4)
	NumPut("UInt", Exponent, Blob, 8)
	NumPut("UInt", Modulus, Blob, 12)
	NumPut("UInt", Prime1, Blob, 16)
	NumPut("UInt", Prime2, Blob, 20)
	At := 24
	for Field in [["e", Exponent], ["n", Modulus], ["p", Prime1], ["q", Prime2], ["dp", Prime1], ["dq", Prime2],
			["qinv", Prime1], ["d", Modulus]] {
		_LLM_Rs256_PutLimbs(Blob, At, Values[Field[1]], Field[2])
		At += Field[2]
	}
	return Blob
}

; Signs through CNG and opens the signature again, as rsa_pkcs1.lua does.
; @returns {Buffer|String} The signature, "" with Refusal set.
_LLM_Rs256_SignNative(Values, Message, &Refusal) {
	global LLM_RS256_VALUES_DISAGREE
	Blob := _LLM_Rs256_FullBlob(Values)
	try {
		Data := Buffer(StrPut(Message, "UTF-8") - 1)
		if (Data.Size > 0)
			StrPut(Message, Data, Data.Size, "UTF-8")
		Signature := CryptoRsaPkcs1SignSha256(Blob, LLM_Rs256_Sha256(Data), _LLM_Rs256_ByteLength(Values["n"]))
		if Signature is Buffer
			return Signature
		Refusal := (Signature == CRYPTO_RSA_NO_PROVIDER) ? "the system has no RSA provider" : LLM_RS256_VALUES_DISAGREE
		return ""
	} finally {
		_LLM_Rs256_Zero(Blob)
	}
}




; ===============================
; ===============================
; ======= 6/ Wiping =============
; ===============================
; ===============================

; RtlZeroMemory as a call the compiler of this script cannot drop.
_LLM_Rs256_Zero(Bytes) {
	CryptoWipe(Bytes)
}

_LLM_Rs256_WipeLimbs(Limbs) {
	loop Limbs.Length
		Limbs[A_Index] := 0
}

_LLM_Rs256_WipeValues(Values) {
	for Name, Value in Values {
		if Value is Array
			_LLM_Rs256_WipeLimbs(Value)
	}
}
