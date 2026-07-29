; tests/unit/test_crypto_sha256_is_real.ahk

; ==============================================================================
; MODULE: CryptoSha256 Real-Digest Regression Test
; DESCRIPTION:
; CryptoSha256 could never once produce a SHA-256 digest. It built its byte array
; with ADODB.Stream, which only permits a Type switch while Position is 0 — and
; the code set `Position := 3` (to skip the UTF-8 BOM) BEFORE `Type := 1`, so
; every call raised 0x800A0C93 and fell through to the DJB2 fallback. Every
; "privacy hash" the product produced was therefore an 8-character, highly
; collision-prone value, not a 64-character digest.
;
; It survived because the contract vector accepted "64 OR 8" characters and hid
; the canonical-digest comparison behind `if (StrLen(Out) = 64)`, a branch that
; never ran. The suite certified the defect.
;
; FEATURES & RATIONALE:
; 1. Known-answer vectors, computed independently (verified against .NET's
;    SHA256 implementation), so the test pins the ALGORITHM rather than whatever
;    the adapter happens to return.
; 2. A multibyte vector ("é" = C3 A9) pins the UTF-8 encoding contract, and the
;    empty-string vector pins that the terminating NUL is not hashed — the two
;    ways a byte-marshalling rewrite silently changes every digest.
; 3. A source guard rejects the two COM dependencies that made the old path
;    unreachable, so a revert to ADODB/SHA256Managed fails here.
; ==============================================================================

#Requires AutoHotkey v2.0

; input -> canonical SHA-256, UTF-8 encoded, no trailing NUL.
global _SHA_VECTORS := Map(
	"",      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	"hello", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
	"é",     "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"
)

_SHA_KnownAnswerVectors() {
	global _SHA_VECTORS
	for Input, Expected in _SHA_VECTORS {
		Got := CryptoSha256(Input)
		Assert(StrLen(Got) = 64,
			"CryptoSha256('" . Input . "') must be 64 hex chars — 8 means the DJB2 fallback ran; got "
			. StrLen(Got) . " (" . Got . ")")
		Assert(Got = Expected,
			"CryptoSha256('" . Input . "') must equal the canonical SHA-256 digest`n  expected: "
			. Expected . "`n  got:      " . Got)
	}
}
Test("crypto: SHA-256 matches canonical known-answer vectors", _SHA_KnownAnswerVectors)

; The empty string is the vector that catches a marshalling rewrite hashing the
; terminating NUL: hashing one extra 0x00 byte changes the digest completely.
_SHA_EmptyStringDoesNotHashTheNul() {
	Got := CryptoSha256("")
	Assert(Got = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"CryptoSha256('') must equal the canonical digest of ZERO bytes — a different value means "
		. "the terminating NUL is being hashed, which shifts every digest the product produces")
}
Test("crypto: the empty string hashes zero bytes, not a NUL", _SHA_EmptyStringDoesNotHashTheNul)

; Root-cause guard: neither COM dependency may come back.
_SHA_NoUnreachableComPath() {
	Body := _DriverFuncBody("CryptoSha256")
	Assert(Body != "", "CryptoSha256 must be defined")
	Assert(InStr(Body, "ADODB.Stream") = 0,
		"CryptoSha256 must not use ADODB.Stream — it only allows a Type switch at Position 0, so "
		. "the BOM-skipping order used before threw 0x800A0C93 on every call")
	Assert(InStr(Body, "SHA256Managed") = 0,
		"CryptoSha256 must not depend on the .NET COM class SHA256Managed — it is absent unless "
		. ".NET 3.5 COM registration is enabled, so it degrades on a default Windows install")
	Assert(InStr(Body, "BCryptFinishHash") > 0,
		"CryptoSha256 must compute the digest through Windows CNG (bcrypt), which ships with the OS")
}
Test("crypto: SHA-256 does not depend on an unreachable COM path", _SHA_NoUnreachableComPath)

; CNG handles are OS resources; hashing in a loop must not leak them.
_SHA_HandlesAreReleased() {
	Body := _DriverFuncBody("CryptoSha256")
	Assert(InStr(Body, "finally") > 0,
		"CryptoSha256 must release its CNG handles in a finally block, or every hash leaks two "
		. "OS handles")
	Assert(InStr(Body, "BCryptDestroyHash") > 0 && InStr(Body, "BCryptCloseAlgorithmProvider") > 0,
		"both the hash handle and the algorithm provider must be released")
	; Exercised for real: a leak would show up as a failure to keep hashing.
	loop 200
		Digest := CryptoSha256("ergopti-" . A_Index)
	Assert(StrLen(Digest) = 64, "the 200th consecutive digest must still be a real SHA-256")
}
Test("crypto: CNG handles are released on every path", _SHA_HandlesAreReleased)
