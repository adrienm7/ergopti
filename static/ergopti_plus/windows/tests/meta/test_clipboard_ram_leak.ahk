; tests/meta/test_clipboard_ram_leak.ahk

#Requires AutoHotkey v2.0
#Include ../../lib/testing.ahk

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

_CRL_FuncBody(SourceCode, FuncDecl) {
	Lines := StrSplit(SourceCode, "`n", "`r")
	InFunc := false
	Body := ""
	BraceDepth := 0
	
	for Line in Lines {
		Trimmed := Trim(Line)
		if (!InFunc) {
			if (InStr(Trimmed, FuncDecl) == 1) {
				InFunc := true
				Body .= Trimmed . "`n"
				BraceDepth := 1
			}
		} else {
			Body .= Trimmed . "`n"
			if (InStr(Trimmed, "{"))
				BraceDepth++
			if (InStr(Trimmed, "}")) {
				BraceDepth--
				if (BraceDepth <= 0)
					return Body
			}
		}
	}
	return Body
}

_CRL_AssertNoAClipboardRef() {
    Src := _CRL_ReadSource("modules/keylogger/keylogger_clipboard.ahk")
    Body := _CRL_FuncBody(Src, "KL_Clip_OnChange(data_type) {")
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
    
    ; Test MAX_CHAR_COUNT clamping (defined as 10000 in keylogger_clipboard.ahk)
    ; 30000 bytes = 14999 chars -> clamped to 10000
    AssertEqual(_KL_Clip_CharCountFromByteSize(30000), 10000, "Must clamp to MAX_CHAR_COUNT (10000)")
}

Test("keylogger_clipboard: KL_Clip_OnChange does not materialise A_Clipboard into RAM (clipboard-reads-entire-clipboard-into-ram)", _CRL_AssertNoAClipboardRef)
Test("keylogger_clipboard: _KL_Clip_CharCountFromByteSize computes correct wide-char counts and clamps", _CRL_AssertCharCountLogic)
