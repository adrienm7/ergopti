; tests/meta/test_clipboard_ram_leak.ahk

; ==============================================================================
; MODULE: Clipboard RAM Leak Meta Test
; DESCRIPTION:
; Static source guard for the "clipboard-reads-entire-clipboard-into-ram" finding.
;
; The clipboard hook used to call `StrLen(A_Clipboard)` which forces AHK to 
; allocate and copy the entire clipboard content into RAM just to count characters.
; This test verifies that A_Clipboard is no longer referenced in KL_Clip_OnChange 
; and that the bounded UTF-16 scanner reports text length rather than HGLOBAL
; allocation capacity.
; ==============================================================================

_CRL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_CRL_AssertNoAClipboardRef() {
    Src := _CRL_ReadSource("modules/keylogger/keylogger_clipboard.ahk")
    Body := _DriverFuncBody("KL_Clip_OnChange")
    Assert(Body != "", "KL_Clip_OnChange must exist in keylogger_clipboard.ahk")
    
    Assert(!InStr(Body, "A_Clipboard"), "KL_Clip_OnChange must NOT reference A_Clipboard to avoid materialising large payloads into RAM (clipboard-reads-entire-clipboard-into-ram)")
    Assert(InStr(Body, "_KL_Clip_CharCountFromBuffer"), "KL_Clip_OnChange must use the bounded UTF-16 helper instead")
    Assert(InStr(Body, "GlobalSize"), "KL_Clip_OnChange must use DllCall GlobalSize to measure the payload")
}

_CRL_Buffer(Text, Capacity := 0) {
	Required := StrPut(Text, "UTF-16") * 2
	Buf := Buffer(Max(Required, Capacity), 0x7F)
	StrPut(Text, Buf, "UTF-16")
	return Buf
}

_CRL_AssertCharCountLogic() {
	Empty := _CRL_Buffer("", 4096)
	AssertEqual(0, _KL_Clip_CharCountFromBuffer(Empty.Ptr, Empty.Size),
		"an empty string must remain empty regardless of allocation capacity")

	Tiny := _CRL_Buffer("a", 4096)
	AssertEqual(1, _KL_Clip_CharCountFromBuffer(Tiny.Ptr, Tiny.Size),
		"a 4096-byte allocation containing a must report one character")

	Unicode := _CRL_Buffer("été " . Chr(0x1F642), 128)
	AssertEqual(StrLen("été " . Chr(0x1F642)), _KL_Clip_CharCountFromBuffer(Unicode.Ptr, Unicode.Size),
		"the scanner must count UTF-16 code units through the first terminator")

	NoTerminator := Buffer(8, 0x41)
	AssertEqual(4, _KL_Clip_CharCountFromBuffer(NoTerminator.Ptr, NoTerminator.Size),
		"a malformed unterminated payload must never be read past its allocation")

	Capped := Buffer((KLClipConst.MAX_CHAR_COUNT + 2) * 2, 0x41)
	AssertEqual(KLClipConst.MAX_CHAR_COUNT, _KL_Clip_CharCountFromBuffer(Capped.Ptr, Capped.Size),
		"unterminated text must remain capped at the privacy limit")

	AssertEqual(0, _KL_Clip_CharCountFromBuffer(0, 4096), "a null data pointer must report zero")
	AssertEqual(0, _KL_Clip_CharCountFromBuffer(Tiny.Ptr, 1), "an incomplete UTF-16 unit must report zero")
}

Test("keylogger_clipboard: KL_Clip_OnChange does not materialise A_Clipboard into RAM (clipboard-reads-entire-clipboard-into-ram)", _CRL_AssertNoAClipboardRef)
Test("keylogger_clipboard: bounded UTF-16 scan reports text length rather than allocation capacity (ahk-042)", _CRL_AssertCharCountLogic)
