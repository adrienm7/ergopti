; static/ergopti_plus/windows/tests/unit/modules/keystats/test_keystats_text_cipher.ahk

; ==============================================================================
; MODULE: At-Rest Encryption Tests (Windows)
; DESCRIPTION:
; Regression coverage for the third driver's half of the at-rest encryption
; feature. The macOS "Chiffrement" entry used to be a no-op that ticked a box and
; encrypted nothing; Windows had no such feature at all. This proves the Windows
; backend actually encrypts, round-trips, and never falls back to plaintext.
;
; WHAT THIS ENCODES:
; 1. Real crypto, not a flag. Encrypt then decrypt must return the original
;    string — including non-ASCII, which exercises the UTF-8 path — and the
;    stored value must not contain the plaintext.
; 2. The envelope format matches the shared codec, so a row is portable in form
;    across the three drivers.
; 3. Each row gets its own IV: identical text in two rows must not produce
;    identical envelopes, or the storage would leak which rows share a prefix.
; 4. Disabled means untouched, and failure never yields plaintext.
; 5. Raw typed text is sealed even when it already looks like an envelope.
; ==============================================================================





; =====================================================
; =====================================================
; ======= 1/ Round-Trip Through Real CNG Crypto =======
; =====================================================
; =====================================================

_KLEnc_RoundTrip_Ascii() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	stored := KL_Enc_Encrypt("dev", 1, "hello world")
	AssertTrue(KL_Enc_IsEncrypted(stored), "the stored value must be an envelope")
	AssertEqual("hello world", KL_Enc_Decrypt(stored), "decrypt must recover the plaintext")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: round-trips an ASCII string through real CNG AES-256-CBC", _KLEnc_RoundTrip_Ascii)

_KLEnc_RoundTrip_Utf8() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	; Accented Latin, a curly quote, a euro sign and CJK — the UTF-8 path must
	; survive all of them, since the keystats stores whatever the user typed.
	secret := "héllo — wörld € 世界"
	stored := KL_Enc_Encrypt("dev", 2, secret)
	AssertEqual(secret, KL_Enc_Decrypt(stored), "decrypt must recover multi-byte UTF-8 unchanged")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: round-trips a multi-byte UTF-8 string", _KLEnc_RoundTrip_Utf8)

_KLEnc_StoresNoPlaintext() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	stored := KL_Enc_Encrypt("dev", 3, "my secret sentence")
	AssertTrue(!InStr(stored, "my secret sentence"), "the typed text must not survive in the stored value")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: the plaintext does not appear in the stored envelope", _KLEnc_StoresNoPlaintext)





; ==========================================
; ==========================================
; ======= 2/ Envelope And Per-Row IV =======
; ==========================================
; ==========================================

_KLEnc_EnvelopeFormat() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	stored := KL_Enc_Encrypt("dev", 4, "text")
	AssertContains(stored, "ergopti-enc-v1:", "the envelope must carry the shared version marker")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: the envelope uses the shared marker", _KLEnc_EnvelopeFormat)

_KLEnc_PerRowIv() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	a := KL_Enc_Encrypt("dev", 5, "same text")
	b := KL_Enc_Encrypt("dev", 6, "same text")
	AssertTrue(a != b, "identical text in two rows must not produce identical envelopes")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: each row gets its own IV", _KLEnc_PerRowIv)

; Raw typed text is never trusted as a stored envelope, whatever its bytes look
; like (WCR-001). Not double-wrapping STORED envelopes is the migration's rule,
; pinned by test_keystats_text_migration.ahk.
_KLEnc_SealsRawEnvelopeLookalike(Kind) {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	try {
		canary := "SENTINEL-PRIVATE-CONTENT"
		switch Kind {
			case "malformed":
				literal := KL_ENC_MARKER . KL_ENC_SEPARATOR . canary
			case "shaped":
				literal := KL_ENC_MARKER . KL_ENC_SEPARATOR . "00000000000000000000000000000000"
					. KL_ENC_SEPARATOR . canary
			case "genuine":
				literal := KL_Enc_Encrypt("dev", 70, canary)
			default:
				literal := KL_ENC_MARKER . KL_ENC_SEPARATOR . "'`n" . Chr(0xE9) . canary
		}
		stored := KL_Enc_Encrypt("dev", 7, literal)
		AssertTrue(stored !== literal, "raw text resembling an envelope must still be sealed")
		AssertTrue(KL_Enc_IsEncrypted(stored), "the sealed value must be an envelope")
		AssertTrue(!InStr(stored, canary), "the protected canary must not survive in the stored value")
		AssertEqual(literal, KL_Enc_Decrypt(stored), "decrypt must recover the literal typed text")
	} finally {
		KL_Enc_SetEnabled(false)
	}
}
Test("cipher-raw-ingress: seals a malformed marker prefix", _KLEnc_SealsRawEnvelopeLookalike.Bind("malformed"))
Test("cipher-raw-ingress: seals a valid-IV envelope lookalike", _KLEnc_SealsRawEnvelopeLookalike.Bind("shaped"))
Test("cipher-raw-ingress: seals a byte copy of a genuine envelope", _KLEnc_SealsRawEnvelopeLookalike.Bind("genuine"))
Test("cipher-raw-ingress: seals quotes, newline and non-ASCII after the marker",
	_KLEnc_SealsRawEnvelopeLookalike.Bind("mixed"))

; The actual typing SQL builder must not carry a marker-prefixed literal in clear.
_KLEnc_WriterSealsMarkerPrefixedText() {
	Keystats.next_event_id := 1
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	try {
		literal := KL_ENC_MARKER . KL_ENC_SEPARATOR . "SENTINEL-PRIVATE-CONTENT"
		entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", literal)
		rows := KL_BuildInserts(entry)
		AssertEqual(1, rows.Length, "an encryptable typing row must still be written")
		AssertTrue(!InStr(rows[1], "SENTINEL-PRIVATE-CONTENT"), "the literal must not appear in the INSERT")
		recovered := false
		pos := 1
		while (pos := RegExMatch(rows[1], "ergopti-enc-v1:[0-9a-f]{32}:[A-Za-z0-9+/=]+", &found, pos)) {
			if (KL_Enc_Decrypt(found[0]) == literal)
				recovered := true
			pos += found.Len
		}
		AssertTrue(recovered, "one stored envelope must decrypt to the literal typed text")
	} finally {
		KL_Enc_SetEnabled(false)
	}
}
Test("cipher-raw-ingress: KL_BuildInserts seals marker-prefixed typed text", _KLEnc_WriterSealsMarkerPrefixedText)





; ===================================================
; ===================================================
; ======= 3/ Disabled + Fail-Closed Behaviour =======
; ===================================================
; ===================================================

_KLEnc_DisabledPassthrough() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(false)
	AssertEqual("hello", KL_Enc_Encrypt("dev", 8, "hello"), "a disabled cipher must return the plaintext untouched")
}
Test("KL_Enc: disabled returns the plaintext unchanged", _KLEnc_DisabledPassthrough)

_KLEnc_DecryptPassthrough() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	; A value written before the feature existed is not an envelope and must read
	; back unchanged.
	AssertEqual("plain from before", KL_Enc_Decrypt("plain from before"),
		"a non-envelope value must pass through decryption unchanged")
}
Test("KL_Enc: decrypt passes a non-envelope value through", _KLEnc_DecryptPassthrough)

_KLEnc_FailClosed() {
	; An empty machine id makes the key underivable. Encryption is on, so encrypt
	; must return "" — never the plaintext the user asked to protect.
	KL_Enc_SetMachineIdOverride("")
	KL_Enc_SetEnabled(true)
	AssertFalse(KL_Enc_IsAvailable(), "no machine id must mean no key")
	AssertEqual("", KL_Enc_Encrypt("dev", 9, "my secret"),
		"encryption that cannot run must return empty, never the plaintext")
	KL_Enc_SetEnabled(false)
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
}
Test("KL_Enc: failure returns empty rather than plaintext", _KLEnc_FailClosed)





; ====================================================
; ====================================================
; ======= 4/ The Writer Drops Rather Than Leak =======
; ====================================================
; ====================================================

_KLEnc_WriterWithholdsPlaintextOnFailure() {
	Keystats.next_event_id := 1
	KL_Enc_SetMachineIdOverride("")   ; force derivation failure
	KL_Enc_SetEnabled(true)
	entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", "secret keystrokes")
	Sql := KL_BuildInsertTyping(entry, 1)
	AssertEqual("", Sql, "a refused builder must never return plaintext SQL")
	KL_Enc_SetEnabled(false)
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
}
Test("KL_BuildInsertTyping: encryption failure withholds plaintext SQL", _KLEnc_WriterWithholdsPlaintextOnFailure)

_KLEnc_WriterReportsEncryptionFailure() {
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	global KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive
	Saved := [KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed,
		KL_ENC_MachineIdOverride, KL_ENC_MachineIdOverrideActive, Keystats.next_event_id]
	try {
		KL_Enc_SetMachineIdOverride("")
		KL_Enc_SetEnabled(true)
		Entry := Map("type", "typing", "timestamp", "2026-01-01 12:00:00.000",
			"app", "fixture.exe", "text", "synthetic-private-marker")
		Failed := false
		try KL_BuildInserts(Entry)
		catch as Err {
			Failed := true
			Assert(!InStr(Err.Message, Entry["text"]), "failure diagnostics must withhold typing text")
		}
		Assert(Failed,
			"encryption refusal must abort SQL conversion so ingestion cannot commit an offset past an omitted typing row")
	} finally {
		KL_ENC_Enabled := Saved[1]
		KL_ENC_KeyBuffer := Saved[2]
		KL_ENC_DerivationFailed := Saved[3]
		KL_ENC_MachineIdOverride := Saved[4]
		KL_ENC_MachineIdOverrideActive := Saved[5]
		Keystats.next_event_id := Saved[6]
	}
}
Test("KL_BuildInserts: encryption refusal is a retryable conversion failure (typing-encryption-retry)",
	_KLEnc_WriterReportsEncryptionFailure)

_KLEnc_WriterEncryptsText() {
	Keystats.next_event_id := 1
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", "confidential")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "an encryptable typing row must still be written")
	AssertContains(rows[1], "ergopti-enc-v1:", "the text column must be stored as an envelope")
	AssertTrue(!InStr(rows[1], "confidential"), "the plaintext must not appear in the INSERT")
	KL_Enc_SetEnabled(false)
}
Test("KL_BuildInserts: encrypts the text column when encryption is on", _KLEnc_WriterEncryptsText)

_KLEnc_WriterPlaintextWhenOff() {
	Keystats.next_event_id := 1
	KL_Enc_SetEnabled(false)
	entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", "visible")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "with encryption off the row is written")
	AssertContains(rows[1], "visible", "with encryption off the text is stored in clear, as before")
}
Test("KL_BuildInserts: stores plaintext when encryption is off (unchanged default)", _KLEnc_WriterPlaintextWhenOff)


; Invalid stored IVs must use the same explicit refusal as a wrong-length IV.
; A cached key reaches hex conversion directly, without a missing-key shortcut.
_KLEnc_MalformedIv(IvHex) {
	global KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	SavedKey := KL_ENC_KeyBuffer
	SavedFailed := KL_ENC_DerivationFailed
	try {
		KL_ENC_KeyBuffer := Buffer(KL_ENC_KEY_BYTES, 0)
		KL_ENC_DerivationFailed := false
		Envelope := KL_ENC_MARKER . KL_ENC_SEPARATOR . IvHex . KL_ENC_SEPARATOR
			. "AAAAAAAAAAAAAAAAAAAAAA=="
		AssertEqual("", KL_Enc_Decrypt(Envelope),
			"malformed IVs must be refused before hex conversion can throw")
	} finally {
		KL_ENC_KeyBuffer := SavedKey
		KL_ENC_DerivationFailed := SavedFailed
	}
}
Test("cipher-malformed-iv: refuses nonhex letters", _KLEnc_MalformedIv.Bind("gggggggggggggggggggggggggggggggg"))
Test("cipher-malformed-iv: refuses a nonhex final byte", _KLEnc_MalformedIv.Bind("0000000000000000000000000000000g"))
Test("cipher-malformed-iv: refuses embedded punctuation", _KLEnc_MalformedIv.Bind("000000000000000000000000000000-1"))
Test("cipher-malformed-iv: keeps wrong-length refusal", _KLEnc_MalformedIv.Bind("000000000000000000000000000000"))


; Embedded NUL is data in an AHK string, not an empty-value or decode terminator.
_KLEnc_NulRoundTrip(Text, ExpectedHex) {
	global KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	Saved := [KL_ENC_Enabled, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed]
	try {
		ExpectedBytes := _KL_Enc_HexToBuffer(ExpectedHex)
		Encoded := _KL_Enc_Utf8Buffer(Text)
		AssertEqual(ExpectedBytes.Size, Encoded.UsedSize, "UTF-8 sizing must include every byte after NUL")
		loop ExpectedBytes.Size
			AssertEqual(NumGet(ExpectedBytes, A_Index - 1, "UChar"), NumGet(Encoded, A_Index - 1, "UChar"),
				"UTF-8 conversion must preserve byte " . A_Index)
		; A deterministic cached key isolates the AES/string boundary from PBKDF2.
		KL_ENC_KeyBuffer := Buffer(KL_ENC_KEY_BYTES, 0)
		KL_ENC_DerivationFailed := false
		KL_ENC_Enabled := true
		Stored := KL_Enc_Encrypt("nul-fixture", 1, Text)
		AssertTrue(KL_Enc_IsEncrypted(Stored), "a leading NUL must never bypass requested encryption")
		Actual := KL_Enc_Decrypt(Stored)
		AssertEqual(StrLen(Text), StrLen(Actual), "decryption must retain the complete string length")
		loop StrLen(Text)
			AssertEqual(NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"),
				NumGet(StrPtr(Actual), (A_Index - 1) * 2, "UShort"),
				"decryption must preserve UTF-16 unit " . A_Index)
	} finally {
		KL_ENC_Enabled := Saved[1]
		KL_ENC_KeyBuffer := Saved[2]
		KL_ENC_DerivationFailed := Saved[3]
	}
}
Test("cipher-nul-roundtrip: encrypts a NUL-only string", _KLEnc_NulRoundTrip.Bind(Chr(0), "00"))
Test("cipher-nul-roundtrip: encrypts after a leading NUL", _KLEnc_NulRoundTrip.Bind(Chr(0) . "hidden", "0068696464656e"))
Test("cipher-nul-roundtrip: preserves the suffix after NUL", _KLEnc_NulRoundTrip.Bind("before" . Chr(0) . "after", "6265666f7265006166746572"))
Test("cipher-nul-roundtrip: preserves a trailing NUL", _KLEnc_NulRoundTrip.Bind("suffix" . Chr(0), "73756666697800"))
Test("cipher-nul-roundtrip: retains multibyte Unicode around NUL", _KLEnc_NulRoundTrip.Bind("é" . Chr(0) . "界" . Chr(0x1F642), "c3a900e7958cf09f9982"))
