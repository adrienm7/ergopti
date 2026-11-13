; tests/fixtures/ai/agent_native_tool_input.ahk

; ==============================================================================
; MODULE: Agent Native Tool Input Receiver
; DESCRIPTION:
; The genuine connector copies this file into its private agent_tools directory
; and launches it as an ordinary AHK tool. Receipts come from actual A_Args and
; the current process FILETIME. A stop file or parent exit ends the exact child.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

_AntiNulToolPublish(Root, Name, Text) {
	FileAppend(Text, Root . "\" . Name . ".pending", "UTF-8-RAW")
	FileMove(Root . "\" . Name . ".pending", Root . "\" . Name)
}

try {
	SplitPath(A_ScriptDir, , &Root)
	ParentPid := Integer(FileRead(Root . "\parent", "UTF-8"))
	Parent := DllCall("Kernel32\OpenProcess", "UInt", 0x100000,
		"Int", false, "UInt", ParentPid, "Ptr")
	if !Parent
		throw Error("SETUP: the native tool cannot retain its parent")
	Times := Buffer(32, 0)
	if !DllCall("Kernel32\GetProcessTimes", "Ptr", DllCall("Kernel32\GetCurrentProcess", "Ptr"),
		"Ptr", Times, "Ptr", Times.Ptr + 8, "Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24, "Int")
		throw OSError(A_LastError)
	Receipt := String(A_Args.Length)
	for Arg in A_Args {
		Receipt .= "|" . StrLen(Arg) . ":"
		Loop StrLen(Arg)
			Receipt .= Format("{:04X}", NumGet(StrPtr(Arg), (A_Index - 1) * 2, "UShort"))
	}
	_AntiNulToolPublish(Root, "argv", Receipt)
	_AntiNulToolPublish(Root, "ready", ProcessExist() . "|" . NumGet(Times, 0, "Int64"))
	loop {
		if FileExist(Root . "\stop")
				|| DllCall("Kernel32\WaitForSingleObject", "Ptr", Parent, "UInt", 0, "UInt") == 0
			break
		Sleep(10)
	}
	if !DllCall("Kernel32\CloseHandle", "Ptr", Parent, "Int")
		throw OSError(A_LastError)
	_AntiNulToolPublish(Root, "done", "done")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**", "UTF-8-RAW")
	ExitApp(1)
}
