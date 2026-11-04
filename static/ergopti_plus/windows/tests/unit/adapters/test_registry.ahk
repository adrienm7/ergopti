; static/ergopti_plus/windows/tests/unit/adapters/test_registry.ahk

; ==============================================================================
; MODULE: Windows Registry Abstraction Tests
; DESCRIPTION:
; Unit-tests for the fail-safe wrapper functions in infra/registry.ahk.
; System reads use well-known keys. Binary round-trips own a unique HKCU test
; key, removed in finally, and never modify any installed application state.
; ==============================================================================




; =============================================
; =============================================
; ======= 1/ Reg_Read =========================
; =============================================
; =============================================

_Reg_ReadKnownValueReturnsNonEmpty() {
	; HKLM\...\Windows NT\CurrentVersion\ProductName is present on every
	; Windows version since XP.  Any non-empty string is a passing result.
	Val := Reg_Read("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "ProductName")
	Assert(StrLen(Val) > 0, "Expected non-empty ProductName, got: " . Val)
}
Test("Reg_Read: known value returns non-empty string", _Reg_ReadKnownValueReturnsNonEmpty)


_Reg_ReadMissingValueReturnsEmptyDefault() {
	Val := Reg_Read("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "__ERGOPTI_NO_SUCH_VALUE__")
	AssertEqual("", Val)
}
Test("Reg_Read: missing value returns empty string fallback", _Reg_ReadMissingValueReturnsEmptyDefault)


_Reg_ReadMissingValueReturnsFallback() {
	Val := Reg_Read("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "__ERGOPTI_NO_SUCH_VALUE__", "FALLBACK")
	AssertEqual("FALLBACK", Val)
}
Test("Reg_Read: missing value returns caller-supplied fallback", _Reg_ReadMissingValueReturnsFallback)


_Reg_ReadMissingKeyReturnsEmptyDefault() {
	Val := Reg_Read("HKEY_LOCAL_MACHINE\SOFTWARE\__ERGOPTI_NO_SUCH_KEY__\Sub", "value")
	AssertEqual("", Val)
}
Test("Reg_Read: missing key returns empty string fallback", _Reg_ReadMissingKeyReturnsEmptyDefault)




; =============================================
; =============================================
; ======= 2/ Reg_ReadDword ====================
; =============================================
; =============================================

_Reg_ReadDwordKnownValue() {
	; HKCU\Control Panel\Desktop\WindowMetrics\MinWidth is a DWORD present
	; on all Windows versions. We only verify it does not crash.
	Val := Reg_ReadDword("HKCU\Control Panel\Desktop", "WallpaperStyle", -999)
	; WallpaperStyle may or may not exist; if absent, -999 is returned.
	Assert(Val >= -999, "Reg_ReadDword must return an integer >= fallback")
}
Test("Reg_ReadDword: returns integer or fallback without throwing", _Reg_ReadDwordKnownValue)


_Reg_ReadDwordMissingValueReturnsFallback() {
	Val := Reg_ReadDword("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "__ERGOPTI_NO_DWORD__", 42)
	AssertEqual(42, Val)
}
Test("Reg_ReadDword: missing value returns integer fallback", _Reg_ReadDwordMissingValueReturnsFallback)




; =============================================
; =============================================
; ======= 3/ Reg_KeyExists ====================
; =============================================
; =============================================

_Reg_KeyExistsKnownKey() {
	Result := Reg_KeyExists("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion")
	AssertTrue(Result)
}
Test("Reg_KeyExists: known system key returns true", _Reg_KeyExistsKnownKey)


_Reg_KeyExistsMissingKey() {
	Result := Reg_KeyExists("HKEY_LOCAL_MACHINE\SOFTWARE\__ERGOPTI_NO_SUCH_KEY_9x7y__")
	AssertFalse(Result)
}
Test("Reg_KeyExists: non-existent key returns false", _Reg_KeyExistsMissingKey)

_Reg_KeyExistsEmptyKey() {
	Path := "HKCU\Software\ErgoptiPlus_Test_Empty_" . A_TickCount
	try {
		RegWrite("temporary", "REG_SZ", Path, "value")
		RegDelete(Path, "value")
		AssertTrue(Reg_KeyExists(Path), "an empty but openable registry key must exist")
	} finally {
		try RegDelete(Path)
	}
}
Test("Reg_KeyExists: empty registry key returns true", _Reg_KeyExistsEmptyKey)




; =============================================
; =============================================
; ======= 4/ Reg_EnumValues ===================
; =============================================
; =============================================

_Reg_EnumValuesKnownKey() {
	Results := Reg_EnumValues("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion")
	Assert(Results.Length > 0, "Expected at least one value under CurrentVersion")
	; Verify the structure of the first entry
	First := Results[1]
	Assert(First.HasProp("name"), "Entry must have 'name' property")
	Assert(First.HasProp("type"), "Entry must have 'type' property")
	Assert(First.HasProp("data"), "Entry must have 'data' property")
}
Test("Reg_EnumValues: known key returns non-empty array of {name, type, data}", _Reg_EnumValuesKnownKey)


_Reg_EnumValuesMissingKey() {
	Results := Reg_EnumValues("HKEY_LOCAL_MACHINE\SOFTWARE\__ERGOPTI_NO_SUCH_KEY_9x7y__")
	AssertEqual(0, Results.Length)
}
Test("Reg_EnumValues: missing key returns empty array", _Reg_EnumValuesMissingKey)




; =============================================
; =============================================
; ======= 5/ Reg_EnumSubKeys ==================
; =============================================
; =============================================

_Reg_EnumSubKeysKnownKey() {
	Results := Reg_EnumSubKeys("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT")
	Assert(Results.Length > 0, "Expected at least one sub-key under Windows NT")
}
Test("Reg_EnumSubKeys: known parent key returns non-empty array", _Reg_EnumSubKeysKnownKey)


_Reg_EnumSubKeysMissingKey() {
	Results := Reg_EnumSubKeys("HKEY_LOCAL_MACHINE\SOFTWARE\__ERGOPTI_NO_SUCH_KEY_9x7y__")
	AssertEqual(0, Results.Length)
}
Test("Reg_EnumSubKeys: missing key returns empty array", _Reg_EnumSubKeysMissingKey)


_Reg_BinaryBufferRoundtrip() {
	Path := "HKCU\Software\ErgoptiTests\Binary_" . ProcessExist() . "_" . A_TickCount . "_" . Random(1000, 9999)
	try {
		RegWrite("00A9FF77", "REG_BINARY", Path, "native")
		Read := Reg_ReadBinary(Path, "native")
		AssertTrue(Read is Buffer, "the adapter exposes bytes, not native hexadecimal text")
		AssertEqual(4, Read.Size)
		Expected := [0, 0xA9, 0xFF, 0x77]
		for Index, Value in Expected
			AssertEqual(Value, NumGet(Read, Index - 1, "UChar"))
		AssertTrue(Reg_WriteBinary(Path, "roundtrip", Read))
		AssertEqual("00A9FF77", RegRead(Path, "roundtrip"), "native reading independently verifies encoded bytes")
		AssertTrue(Reg_WriteBinary(Path, "empty", Buffer(0)))
		AssertEqual("", RegRead(Path, "empty"))
		AssertEqual(0, Reg_ReadBinary(Path, "missing").Size)
		RegWrite(42, "REG_DWORD", Path, "number")
		AssertEqual(0, Reg_ReadBinary(Path, "number").Size, "a numeric registry value is not binary text")
		AssertFalse(Reg_WriteBinary(Path, "bad", "00AA"), "the adapter rejects a string where bytes are required")
	} finally {
		if Reg_KeyExists(Path)
			RegDeleteKey(Path)
	}
}
Test("registry: binary values round-trip Buffers (registry-binary-buffer-contract)", _Reg_BinaryBufferRoundtrip)
