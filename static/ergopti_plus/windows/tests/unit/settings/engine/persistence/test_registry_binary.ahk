; tests/unit/settings/engine/persistence/test_registry_binary.ahk

; ==============================================================================
; MODULE: Registry Binary Read Behaviour Tests
; DESCRIPTION:
; Replaces a source read of Reg_ReadBinary. The AHK v1 form passed REG_BINARY
; as a third RegRead argument, which AHK v2 reads as the default value, so a
; real binary value was never decoded. The real reader decodes a value written
; under a private HKCU key, and a missing value returns an empty buffer.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Reading a REG_BINARY value =======
; =============================================
; =============================================

_TRB_ReadsTheWrittenBytes() {
	Key := "HKCU\Software\ErgoptiTests\RegistryBinary_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	try {
		RegWrite("0001FFAB", "REG_BINARY", Key, "Blob")
		Bytes := Reg_ReadBinary(Key, "Blob")
		AssertTrue(Bytes is Buffer, "a binary read returns a Buffer")
		AssertEqual(4, Bytes.Size, "every written byte is read back")
		for Index, Expected in [0x00, 0x01, 0xFF, 0xAB]
			AssertEqual(Expected, NumGet(Bytes, Index - 1, "UChar"), "byte " . Index . " is decoded from the registry")
		AssertEqual(0, Reg_ReadBinary(Key, "Missing").Size, "a missing value reads as an empty buffer")
	} finally {
		AssertTrue(Reg_DeleteKey(Key), "the private test key must be removed")
	}
}
Test("registry: Reg_ReadBinary decodes a real REG_BINARY value (regread-no-type-arg)", _TRB_ReadsTheWrittenBytes)
