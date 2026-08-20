; static/ergopti_plus/windows/tests/unit/test_keylogger_text_cipher.ahk

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
	; survive all of them, since the keylogger stores whatever the user typed.
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

_KLEnc_NoDoubleWrap() {
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
	KL_Enc_SetEnabled(true)
	once := KL_Enc_Encrypt("dev", 7, "text")
	twice := KL_Enc_Encrypt("dev", 7, once)
	AssertEqual(once, twice, "re-encrypting an envelope would make it undecryptable in one pass")
	KL_Enc_SetEnabled(false)
}
Test("KL_Enc: does not double-wrap an already-encrypted value", _KLEnc_NoDoubleWrap)





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

_KLEnc_WriterDropsOnFailure() {
	Keylogger.next_event_id := 1
	KL_Enc_SetMachineIdOverride("")   ; force derivation failure
	KL_Enc_SetEnabled(true)
	entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", "secret keystrokes")
	rows := KL_BuildInserts(entry)
	AssertEqual(0, rows.Length, "a typing row must be dropped when encryption is on but cannot run")
	KL_Enc_SetEnabled(false)
	KL_Enc_SetMachineIdOverride("00000000-0000-0000-0000-000000000001")
}
Test("KL_BuildInserts: drops the typing row rather than storing plaintext when encryption fails", _KLEnc_WriterDropsOnFailure)

_KLEnc_WriterEncryptsText() {
	Keylogger.next_event_id := 1
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
	Keylogger.next_event_id := 1
	KL_Enc_SetEnabled(false)
	entry := Map("type", "typing", "timestamp", "2026-07-02 10:00:00.000", "app", "TestApp", "text", "visible")
	rows := KL_BuildInserts(entry)
	AssertEqual(1, rows.Length, "with encryption off the row is written")
	AssertContains(rows[1], "visible", "with encryption off the text is stored in clear, as before")
}
Test("KL_BuildInserts: stores plaintext when encryption is off (unchanged default)", _KLEnc_WriterPlaintextWhenOff)
