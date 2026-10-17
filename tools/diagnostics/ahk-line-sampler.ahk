; tools/diagnostics/ahk-line-sampler.ahk
;
; ==============================================================================
; MODULE: AHK Executed-Line Sampler
; DESCRIPTION:
; Poor man's profiler for a running AHK script, such as the test runner. Every
; 250 ms it asks the target's main window to refresh its "Lines most recently
; executed" view (ID_VIEW_LINES), reads it, skips the WM_COMMAND handler lines
; that the refresh itself runs, and counts the interrupted source line. The
; report lists the hottest file:line pairs, most frequent first. A thread held
; in Critical only processes the request when it leaves Critical, so a hot spot
; inside a Critical section shows up at its Critical(Previous) exit line.
;
; Usage (PowerShell, while the target runs):
;   AutoHotkey64.exe /ErrorStdOut tools\diagnostics\ahk-line-sampler.ahk <seconds> <report> [window title]
; The window title defaults to "run_all.ahk".
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
DetectHiddenWindows(true)
SetTitleMatchMode(2)

if A_Args.Length < 2 {
	FileAppend("Usage: ahk-line-sampler.ahk <seconds> <report> [window title]`n", "**")
	ExitApp(2)
}
Seconds := Integer(A_Args[1])
Report := A_Args[2]
Target := A_Args.Length >= 3 ? A_Args[3] : "run_all.ahk"
; Lines of the dispatcher that answers our own refresh request.
Handler := "i)MenuCommandOrigin|_MenuDispatchCallbacks|NotifyCode|ItemId :=|^Return$"
Deadline := A_TickCount + Seconds * 1000
Counts := Map()
Samples := 0
while A_TickCount < Deadline {
	Hwnd := WinExist(Target . " ahk_class AutoHotkey")
	if Hwnd {
		try SendMessage(0x111, 65406, 0, , "ahk_id " . Hwnd, , , , 2000)
		try {
			Lines := StrSplit(ControlGetText("Edit1", "ahk_id " . Hwnd), "`n", "`r")
			Index := Lines.Length
			SourceFile := ""
			Found := ""
			; Walk upward past the handler block to the interrupted code and its file.
			while Index > 0 {
				Line := Lines[Index]
				if RegExMatch(Line, "^(\d+):\s*(.*)$", &Match) {
					Body := Trim(Match[2])
					if Found == "" && !RegExMatch(Body, Handler)
						Found := Match[1] . ": " . SubStr(Body, 1, 110)
				} else if Found != "" && RegExMatch(Line, "^-+\s*(.+)$", &Header) {
					SourceFile := Header[1]
					break
				}
				Index -= 1
			}
			if Found != "" {
				Key := RegExReplace(SourceFile, ".*\\") . " | " . Found
				Counts[Key] := Counts.Get(Key, 0) + 1
			}
			Samples += 1
		}
	}
	Sleep(250)
}
Text := ""
for Key, Value in Counts
	Text .= Format("{:06d} {}", Value, Key) . "`n"
try FileDelete(Report)
FileAppend("samples=" . Samples . "`n" . Sort(Text, "R"), Report, "UTF-8")
ExitApp(0)
