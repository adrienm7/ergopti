; tests/support/legacy_exit_code_child.ahk

; ==============================================================================
; MODULE: Legacy Exit Code Child Fixture
; DESCRIPTION:
; Exits immediately after publishing a marker, without retaining a second native
; process handle that could hide collection of the launcher's process capability.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

if A_Args.Length != 1
	throw Error("Exactly one exit code is required.")
Code := Integer(A_Args[1])
FileAppend("legacy-exit-" . Code, "*")
ExitApp(Code)
