; tests/fixtures/clipboard_restore_debt_writer.ahk

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

; The real separate process attempts a native copy at the parent's comparison
; boundary. Receipts become visible only after their complete bytes are closed.
_CRDW_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_CRDW_Wait(Path) {
	Started := DllCall("Kernel32\GetTickCount64", "UInt64")
	while !FileExist(Path) && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 15000
		Sleep(10)
	_CRDW_Require(FileExist(Path) != "", "the parent did not publish its owned request")
}

_CRDW_Publish(Path, Text) {
	Pending := Path . ".pending"
	FileAppend(Text, Pending, "UTF-8-RAW")
	FileMove(Pending, Path)
}

_CRDW_Main() {
	Root := A_Args[1], Mode := A_Args[2], Foreign := A_Args[3]
	Held := false
	try {
		if Mode == "busy" {
			Held := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
			_CRDW_Require(Held, "the independent incumbent must hold its own native lock")
		}
		_CRDW_Publish(Root . "\ready", "ready")
		_CRDW_Wait(Root . "\before.request")
		if Mode == "borrowed"
			Receipt := "released"
		else if Held {
			_CRDW_Require(DllCall("User32\CloseClipboard", "Int"), "the incumbent must release its own lock")
			Held := false
			Receipt := "released"
		} else {
			Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
			if Opened {
				_CRDW_Require(DllCall("User32\CloseClipboard", "Int"), "the writer must release its probe")
				A_Clipboard := Foreign
				Receipt := "copied"
			} else
				Receipt := "busy"
		}
		_CRDW_Publish(Root . "\before.receipt", Receipt)
		_CRDW_Wait(Root . "\after.request")
		A_Clipboard := Foreign . " after"
		_CRDW_Publish(Root . "\after.receipt", "copied")
		FileAppend("PASS clipboard restore debt writer", "*")
	} finally {
		if Held
			DllCall("User32\CloseClipboard", "Int")
	}
}

try {
	_CRDW_Main()
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
