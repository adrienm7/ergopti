; tests/fixtures/clipboardall_lock_observer.ahk

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

; A separate native process observes the actual global clipboard lock. It only
; reads formats, never replaces clipboard data or runs any parent test source.
_CALO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_CALO_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && A_TickCount - Started < 15000
		Sleep(10)
	_CALO_Require(FileExist(Path) != "", "the parent did not publish its owned handshake")
}

; A handshake becomes visible only after its complete receipt is closed.
_CALO_Publish(Path, Text) {
	Pending := Path . ".pending"
	FileAppend(Text, Pending, "UTF-8-RAW")
	FileMove(Pending, Path)
}

_CALO_Main() {
	Root := A_Args[1], CustomFormat := Integer(A_Args[2])
	_CALO_Publish(Root . "\ready", "ready")
	_CALO_Wait(Root . "\before.request")
	Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
	if Opened
		_CALO_Require(DllCall("User32\CloseClipboard", "Int"), "the observer must close its own before probe")
	_CALO_Publish(Root . "\before.receipt", Opened ? "open" : "busy")
	_CALO_Wait(Root . "\after.request")
	_CALO_Require(DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int"),
		"the AHK setter must release its internal clipboard open before the after probe")
	try {
		TextHandle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		_CALO_Require(TextHandle != 0, "the actual Unicode format must survive ClipboardAll restoration")
		TextPointer := DllCall("Kernel32\GlobalLock", "Ptr", TextHandle, "Ptr")
		_CALO_Require(TextPointer != 0, "the Unicode clipboard object must be readable")
		try Text := StrGet(TextPointer, "UTF-16")
		finally DllCall("Kernel32\GlobalUnlock", "Ptr", TextHandle)
		CustomHandle := DllCall("User32\GetClipboardData", "UInt", CustomFormat, "Ptr")
		_CALO_Require(CustomHandle != 0, "the actual private binary format must survive ClipboardAll restoration")
		_CALO_Require(DllCall("Kernel32\GlobalSize", "Ptr", CustomHandle, "UPtr") >= 8,
			"the complete binary payload must remain available")
		CustomPointer := DllCall("Kernel32\GlobalLock", "Ptr", CustomHandle, "Ptr")
		_CALO_Require(CustomPointer != 0, "the actual private binary format must be readable")
		try {
			Hex := ""
			loop 8
				Hex .= Format("{:02X}", NumGet(CustomPointer, A_Index - 1, "UChar"))
		} finally DllCall("Kernel32\GlobalUnlock", "Ptr", CustomHandle)
	} finally DllCall("User32\CloseClipboard", "Int")
	_CALO_Publish(Root . "\text.receipt", Text)
	_CALO_Publish(Root . "\binary.receipt", Hex)
	FileAppend("PASS clipboardall lock observer", "*")
}

try {
	_CALO_Main()
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
