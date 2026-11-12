; tests/unit/modules/llm/test_api_token_crypto_receiving.ahk

; ==============================================================================
; MODULE: Secret Storage Receiving Scenarios
; DESCRIPTION:
; The native receiving scenarios of the Windows crypto flow audit
; (docs/audits/platform-parity/2026-11-04-flows/windows-crypto), on the real
; Windows primitives of the signed-in account, never a recording port:
; 1. an API token round-trips through the real DPAPI, and an independent
;    process (Windows PowerShell's ProtectedData) reads the same envelope;
; 2. a tampered blob, a blob sealed with another entropy and a marker-shaped
;    plaintext are refused, and a refused envelope is never re-persisted;
; 3. the metrics text cipher seals raw typing that starts with its marker, or
;    copies a whole envelope, with the real MachineGuid key and CNG (WCR-001).
; A blob of another Windows account needs a second account and is not here.
; Registered as interactive: only the receiving runner selects them.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs a Windows PowerShell 5.1 command over DPAPI in a separate process.
; Input and output pass through files of the receiving profile, so no secret
; reaches a command line. Returns the output file's text.
_PWRC_PowerShell(Command, Input) {
	Dir := ReceivingScratchDir("dpapi")
	FileAppend(Input, Dir . "\in.txt", "UTF-8-RAW")
	Script := "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;"
		. "$in=[IO.File]::ReadAllText('" . Dir . "\in.txt');" . Command
		. ";[IO.File]::WriteAllText('" . Dir . "\out.txt',$out,[Text.UTF8Encoding]::new($false))"
	FileAppend(Script, Dir . "\dpapi.ps1", "UTF-8")
	ExitCode := RunWait('"' . A_WinDir . '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
		. Dir . '\dpapi.ps1"', Dir, "Hide")
	AssertEqual(0, ExitCode, "the independent DPAPI process succeeded")
	Out := FileRead(Dir . "\out.txt", "UTF-8")
	DirDelete(Dir, true)
	return Out
}

; 1. Real DPAPI round trip, read back by an independent process.
_PWRC_DpapiRoundTrip() {
	global LLM_API_TOKEN_DPAPI_PREFIX, LLM_API_TOKEN_DPAPI_ENTROPY
	ReceivingProfileRoot()
	Token := "sk-receiving-" . A_TickCount . "-é漢"
	Envelope := LLM_ApiToken_Encrypt(Token)
	AssertTrue(Envelope is String && SubStr(Envelope, 1, StrLen(LLM_API_TOKEN_DPAPI_PREFIX)) == LLM_API_TOKEN_DPAPI_PREFIX,
		"the token is sealed")
	AssertFalse(InStr(Envelope, "sk-receiving"), "the envelope does not carry the clear token")
	AssertTrue(LLM_ApiToken_IsValidEnvelope(Envelope), "this account can open its own envelope")
	AssertEqual(Token, LLM_ApiToken_Decrypt(Envelope), "the round trip is exact, non-ASCII included")
	Payload := SubStr(Envelope, StrLen(LLM_API_TOKEN_DPAPI_PREFIX) + 1)
	Read := _PWRC_PowerShell("$out=[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect("
		. "[Convert]::FromBase64String($in),[Text.Encoding]::UTF8.GetBytes('" . LLM_API_TOKEN_DPAPI_ENTROPY . "'),'CurrentUser'))", Payload)
	AssertEqual(Token, Read, "an independent process opens the same envelope with the same entropy")
	AssertEqual(Envelope, LLM_ApiToken_Encrypt(Envelope), "a valid envelope is kept, never wrapped twice")
}
Test("api token crypto receiving: a token round-trips through the real DPAPI and an independent reader (phys-w-receiving-dpapi)",
	_PWRC_DpapiRoundTrip, true)

; 2. Real DPAPI refusals: each refused envelope is kept as stored by the
; reader and refused by the writer, so a save can neither wipe it nor persist
; it as if it were usable.
_PWRC_DpapiRefusals() {
	global LLM_API_TOKEN_DPAPI_PREFIX
	ReceivingProfileRoot()
	Envelope := LLM_ApiToken_Encrypt("sk-receiving-tamper-" . A_TickCount)
	Blob := CryptoBase64Decode(SubStr(Envelope, StrLen(LLM_API_TOKEN_DPAPI_PREFIX) + 1))
	Middle := Blob.Size // 2
	NumPut("UChar", NumGet(Blob, Middle, "UChar") ^ 0xFF, Blob, Middle)
	Tampered := LLM_API_TOKEN_DPAPI_PREFIX . CryptoBase64Encode(Blob)
	Foreign := LLM_API_TOKEN_DPAPI_PREFIX . _PWRC_PowerShell("$out=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect("
		. "[Text.Encoding]::UTF8.GetBytes($in),[Text.Encoding]::UTF8.GetBytes('ergopti.receiving.other'),'CurrentUser'))", "sk-foreign")
	for Label, Stored in Map("tampered", Tampered, "foreign entropy", Foreign) {
		AssertTrue(LLM_ApiToken_IsEncrypted(Stored), "positive control: the " . Label . " envelope is well formed")
		AssertFalse(LLM_ApiToken_IsValidEnvelope(Stored), "DPAPI refuses the " . Label . " envelope")
		AssertEqual(Stored, LLM_ApiToken_Decrypt(Stored), "the reader keeps the " . Label . " envelope as stored")
		AssertFalse(LLM_ApiToken_Encrypt(Stored), "the writer refuses to persist the " . Label . " envelope")
	}
	Shaped := LLM_API_TOKEN_DPAPI_PREFIX . "not base64!"
	AssertFalse(LLM_ApiToken_Decrypt(Shaped), "a marker-shaped plaintext is a malformed envelope")
	AssertFalse(LLM_ApiToken_Encrypt(Shaped), "and is never sealed as if it were a token")
}
Test("api token crypto receiving: tampered, foreign and marker-shaped envelopes are refused by the real DPAPI (phys-w-receiving-dpapi)",
	_PWRC_DpapiRefusals, true)

; 3. The metrics text cipher with the machine's own key: raw typing that starts
; with the marker, or is a whole envelope, is sealed like any other text and
; decrypts back exactly (WCR-001).
_PWRC_KeystatsCipherSealsMarkerText() {
	global KL_ENC_MARKER, KL_ENC_SEPARATOR
	global KL_ENC_MachineIdOverrideActive, KL_ENC_KeyBuffer, KL_ENC_DerivationFailed
	ReceivingProfileRoot()
	WasEnabled := KL_Enc_IsEnabled()
	KL_ENC_MachineIdOverrideActive := false, KL_ENC_KeyBuffer := "", KL_ENC_DerivationFailed := false
	try {
		KL_Enc_SetEnabled(true)
		AssertTrue(KL_Enc_IsAvailable(), "the key derives from this machine's MachineGuid")
		Envelope := KL_Enc_Encrypt("receiving", "1", "plain")
		AssertTrue(KL_Enc_IsEncrypted(Envelope), "positive control: ordinary text is sealed")
		Prefixed := KL_ENC_MARKER . KL_ENC_SEPARATOR . "SENTINEL-PRIVATE-CONTENT"
		for Index, Raw in [Prefixed, Envelope] {
			Sealed := KL_Enc_Encrypt("receiving", String(Index + 1), Raw)
			AssertTrue(Sealed !== Raw, "raw text resembling an envelope is sealed, not stored as is")
			AssertFalse(InStr(Sealed, "SENTINEL"), "the sealed value does not carry the raw text")
			AssertEqual(Raw, KL_Enc_Decrypt(Sealed), "and decrypts back to exactly what was typed")
		}
	} finally {
		KL_Enc_SetEnabled(WasEnabled)
		KL_ENC_KeyBuffer := "", KL_ENC_DerivationFailed := false
	}
}
Test("api token crypto receiving: the metrics cipher seals marker-shaped typing with the real machine key (phys-w-receiving-dpapi)",
	_PWRC_KeystatsCipherSealsMarkerText, true)
