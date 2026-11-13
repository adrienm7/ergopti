; tests/fixtures/clipboard/clipboardall_foreign_reader.ahk

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

; Holds the global clipboard lock for a moment, as clipboard history does right
; after every change, then lets it go. It reads and replaces nothing.
Marker := A_Args[1], HoldMs := Integer(A_Args[2])
Started := A_TickCount
while !(Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int")) && A_TickCount - Started < 5000
	Sleep(5)
if !Opened
	ExitApp(3)
FileAppend("held", Marker . ".pending", "UTF-8-RAW")
FileMove(Marker . ".pending", Marker)
Sleep(HoldMs)
ExitApp(DllCall("User32\CloseClipboard", "Int") ? 0 : 4)
