; apps/encryptor_core.ahk

; ==============================================================================
; MODULE: Encryptor Core (Windows)
; DESCRIPTION:
; The Windows Encryptor's container and conversion: the port of macOS's
; encryptor_convert.sh. The container is _shared/data/encryptor/format.json,
; OpenSSL's enc envelope, so a file encrypted here opens with the macOS and
; Linux Encryptors (and `openssl enc -d`), and the other way round.
;
; FEATURES & RATIONALE:
; 1. CNG through adapters/crypto.ahk (the PBKDF2 and AES-CBC the keystats
;    cipher already relies on): no OpenSSL to ship, and the password never
;    leaves this process, so no command line or file ever holds it.
; 2. Every constant is read from the shared format file.
; 3. The result is written next to the destination and renamed over it only
;    once complete, so a wrong password leaves an approved destination intact.
; ==============================================================================

#Requires AutoHotkey v2.0+




; ==================================
; ==================================
; ======= 1/ Format ================
; ==================================
; ==================================

/**
 * Reads the shared container format.
 * @param {String} SharedDir The _shared folder.
 * @returns {Map}
 */
Encryptor_LoadFormat(SharedDir) {
	Envelope := JsonParse(FileRead(SharedDir . "\data\encryptor\format.json", "UTF-8"))
	for Key in ["magic", "salt_bytes", "cipher", "kdf", "kdf_digest", "iterations", "key_bytes", "iv_bytes",
			"encrypted_extension", "decrypted_fallback_suffix"] {
		if !Envelope.Has(Key)
			throw ValueError("The shared Encryptor format lacks " . Key . ".")
	}
	; CNG is driven for exactly this cipher and digest; any other format is refused.
	if Envelope["cipher"] != "aes-256-cbc" || Envelope["kdf"] != "pbkdf2" || Envelope["kdf_digest"] != "sha256"
		throw ValueError("The shared Encryptor format names a cipher this driver does not implement.")
	return Envelope
}

/**
 * The conversion a source path gets and where its result goes, as macOS's
 * main.applescript decides it (the extension test ignores case).
 * @param {Map} Envelope The shared container format (format.json).
 * @param {String} Source
 * @returns {Map} mode ("encrypt" or "decrypt") and destination.
 */
Encryptor_Destination(Envelope, Source) {
	Ext := Envelope["encrypted_extension"]
	if StrLen(Source) < StrLen(Ext) || SubStr(Source, -StrLen(Ext)) != Ext
		return Map("mode", "encrypt", "destination", Source . Ext)
	Stripped := SubStr(Source, 1, StrLen(Source) - StrLen(Ext))
	Last := SubStr(Stripped, -1)
	if Stripped == "" || Last == "\" || Last == "/"
		return Map("mode", "decrypt", "destination", Source . Envelope["decrypted_fallback_suffix"])
	return Map("mode", "decrypt", "destination", Stripped)
}




; ==================================
; ==================================
; ======= 2/ Container =============
; ==================================
; ==================================

/**
 * Derives the key and IV from a password and a salt.
 * @returns {Map} key and iv Buffers.
 */
_Encryptor_Derive(Envelope, Password, SaltPtr) {
	if !(Password is String) || Password == "" || RegExMatch(Password, "[\r\n]")
		throw ValueError("An Encryptor password is one non-empty line.")
	Length := StrPut(Password, "UTF-8") - 1
	Bytes := Buffer(Length, 0)
	StrPut(Password, Bytes, Length, "UTF-8")
	Material := CryptoPbkdf2Sha256(Bytes.Ptr, Length, SaltPtr, Envelope["salt_bytes"], Envelope["iterations"],
		Envelope["key_bytes"] + Envelope["iv_bytes"])
	CryptoWipe(Bytes)
	if !(Material is Buffer)
		throw OSError(0, -1, "The Encryptor key could not be derived.")
	Key := Buffer(Envelope["key_bytes"])
	Iv := Buffer(Envelope["iv_bytes"])
	BundledAppsNative_Copy(Key.Ptr, Material.Ptr, Key.Size)
	BundledAppsNative_Copy(Iv.Ptr, Material.Ptr + Key.Size, Iv.Size)
	CryptoWipe(Material)
	return Map("key", Key, "iv", Iv)
}

/**
 * Seals plaintext bytes into a container.
 * @param {Map} Envelope The shared container format (format.json).
 * @param {Buffer} Plain
 * @param {String} Password
 * @param {Buffer} Salt Optional fixed salt (the vectors); random otherwise.
 * @returns {Buffer}
 */
Encryptor_Seal(Envelope, Plain, Password, Salt := "") {
	if !(Salt is Buffer)
		Salt := BundledAppsNative_RandomBytes(Envelope["salt_bytes"])
	if Salt.Size != Envelope["salt_bytes"]
		throw ValueError("The Encryptor salt has the wrong size.")
	Secret := _Encryptor_Derive(Envelope, Password, Salt.Ptr)
	Cipher := CryptoAesCbc(Secret["key"], Secret["iv"], Plain.Ptr, Plain.Size, true)
	CryptoWipe(Secret["key"])
	if !(Cipher is Buffer)
		throw OSError(0, -1, "The Encryptor could not encrypt.")
	Magic := Envelope["magic"]
	Header := StrLen(Magic) + Salt.Size
	Out := Buffer(Header + Cipher.UsedSize)
	loop parse Magic
		NumPut("UChar", Ord(A_LoopField), Out, A_Index - 1)
	BundledAppsNative_Copy(Out.Ptr + StrLen(Magic), Salt.Ptr, Salt.Size)
	BundledAppsNative_Copy(Out.Ptr + Header, Cipher.Ptr, Cipher.UsedSize)
	return Out
}

/**
 * Opens a container.
 * @param {Map} Envelope The shared container format (format.json).
 * @param {Buffer} Container
 * @param {String} Password
 * @returns {Buffer|String} The plaintext, or "" for a wrong password or a foreign file.
 */
Encryptor_Open(Envelope, Container, Password) {
	Magic := Envelope["magic"]
	Header := StrLen(Magic) + Envelope["salt_bytes"]
	Body := Container.Size - Header
	; AES-CBC output is whole blocks, and an AES block is the IV's size.
	if Body <= 0 || Mod(Body, Envelope["iv_bytes"]) != 0
		return ""
	loop parse Magic {
		if NumGet(Container, A_Index - 1, "UChar") != Ord(A_LoopField)
			return ""
	}
	Secret := _Encryptor_Derive(Envelope, Password, Container.Ptr + StrLen(Magic))
	Plain := CryptoAesCbc(Secret["key"], Secret["iv"], Container.Ptr + Header, Body, false)
	CryptoWipe(Secret["key"])
	if !(Plain is Buffer)
		return ""
	Out := Buffer(Plain.UsedSize)
	BundledAppsNative_Copy(Out.Ptr, Plain.Ptr, Plain.UsedSize)
	CryptoWipe(Plain)
	return Out
}




; ==================================
; ==================================
; ======= 3/ Conversion ============
; ==================================
; ==================================

/**
 * Converts one file, replacing Output only on success.
 * @param {Map} Envelope The shared container format (format.json).
 * @param {String} Mode "encrypt" or "decrypt".
 * @param {String} Input
 * @param {String} Output
 * @param {String} Password
 * @returns {Boolean} False for a wrong password or a foreign file.
 */
Encryptor_ConvertFile(Envelope, Mode, Input, Output, Password) {
	if Mode != "encrypt" && Mode != "decrypt"
		throw ValueError("Unknown Encryptor mode: " . Mode)
	Source := FileRead(Input, "RAW")
	if !(Source is Buffer)
		Source := Buffer(0)
	Result := Mode == "encrypt" ? Encryptor_Seal(Envelope, Source, Password) : Encryptor_Open(Envelope, Source, Password)
	if !(Result is Buffer)
		return false
	SplitPath(Output, &Name, &Folder)
	Stage := (Folder == "" ? "" : Folder . "\") . "." . Name . "." . A_TickCount . ".tmp"
	try {
		File := FileOpen(Stage, "w-")
		if !IsObject(File)
			throw OSError(A_LastError, -1, "Cannot create the stage next to the output.")
		try File.RawWrite(Result, Result.Size)
		finally File.Close()
		if !BundledAppsNative_ReplaceFile(Stage, Output)
			throw OSError(A_LastError, -1, "Cannot publish the converted file.")
	} catch as Err {
		if FileExist(Stage)
			FileDelete(Stage)
		throw Err
	}
	if Mode == "decrypt"
		CryptoWipe(Result)
	return true
}
