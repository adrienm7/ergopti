; tests/support/argv_echo.ahk

; ==============================================================================
; MODULE: Native Argument Echo Fixture
; DESCRIPTION:
; Reports received argument count and exact UTF-8 bytes without loading a driver.
; Hex framing preserves empty strings and makes Unicode transport unambiguous.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

ReceiptPath := A_Args.RemoveAt(1)
if FileExist(ReceiptPath) || FileExist(ReceiptPath . ".writing")
	throw Error("Argument receipt path is already occupied.")
Receipt := A_Args.Length . "`n"
for Arg in A_Args {
	ByteCount := StrPut(Arg, "UTF-8") - 1
	Bytes := Buffer(ByteCount + 1)
	StrPut(Arg, Bytes, ByteCount + 1, "UTF-8")
	Hex := ""
	loop ByteCount
		Hex .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	Receipt .= Hex . "`n"
}
FileAppend(Receipt, ReceiptPath . ".writing", "UTF-8-RAW")
FileMove(ReceiptPath . ".writing", ReceiptPath)
FileAppend(Receipt, "*")
ExitApp(0)
