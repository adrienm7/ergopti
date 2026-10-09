; tests/support/updater_parent_gate.ahk

; ==============================================================================
; MODULE: Updater Fixture Parent Gate
; DESCRIPTION: Retain a real parent process until its owner signals native exit.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

if A_Args.Length != 1
	ExitApp(2)
Handle := DllCall("OpenEventW", "UInt", 0x00100000, "Int", false, "Str", A_Args[1], "Ptr")
if !Handle
	ExitApp(3)
try Result := DllCall("WaitForSingleObject", "Ptr", Handle, "UInt", 0xFFFFFFFF, "UInt")
finally DllCall("CloseHandle", "Ptr", Handle, "Int")
ExitApp(Result = 0 ? 0 : 4)
