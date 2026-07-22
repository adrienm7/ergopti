; tests/meta/test_clipboard_ram_leak.ahk

; ==============================================================================
; MODULE: Clipboard RAM Leak Meta Test
; DESCRIPTION:
; Static source guard for the "clipboard-reads-entire-clipboard-into-ram" finding.
;
; The clipboard hook used to call `StrLen(A_Clipboard)` which forces AHK to 
; allocate and copy the entire clipboard content into RAM just to count characters.
; This test verifies that A_Clipboard is no longer referenced in KL_Clip_OnChange 
; and that the _KL_Clip_CharCountFromByteSize helper is implemented correctly.
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
    Assert(InStr(Body, "_KL_Clip_CharCountFromByteSize"), "KL_Clip_OnChange must use the _KL_Clip_CharCountFromByteSize helper instead")
    Assert(InStr(Body, "GlobalSize"), "KL_Clip_OnChange must use DllCall GlobalSize to measure the payload")
}

_CRL_AssertCharCountLogic() {
    ; Test the helper itself
    AssertEqual(_KL_Clip_CharCountFromByteSize(0), 0, "0 bytes -> 0 chars")
    AssertEqual(_KL_Clip_CharCountFromByteSize(2), 0, "2 bytes (just null terminator) -> 0 chars")
    AssertEqual(_KL_Clip_CharCountFromByteSize(4), 1, "4 bytes (1 char + null) -> 1 char")
    AssertEqual(_KL_Clip_CharCountFromByteSize(200), 99, "200 bytes -> 99 chars")
    
    ; A payload under the cap returns the exact wide-char count.
    ; 30000 bytes = (30000 // 2) - 1 = 14999 chars, still below MAX_CHAR_COUNT.
    AssertEqual(_KL_Clip_CharCountFromByteSize(30000), 14999, "30000 bytes -> 14999 chars (still under the cap)")

    ; Above the cap the count clamps to MAX_CHAR_COUNT (read from the constant so
    ; this test cannot drift from the production value).
    ; 300000 bytes = 149999 chars -> clamped to MAX_CHAR_COUNT.
    AssertEqual(_KL_Clip_CharCountFromByteSize(300000), KLClipConst.MAX_CHAR_COUNT, "Above-cap byte size clamps to MAX_CHAR_COUNT")
}

Test("keylogger_clipboard: KL_Clip_OnChange does not materialise A_Clipboard into RAM (clipboard-reads-entire-clipboard-into-ram)", _CRL_AssertNoAClipboardRef)
Test("keylogger_clipboard: _KL_Clip_CharCountFromByteSize computes correct wide-char counts and clamps", _CRL_AssertCharCountLogic)
