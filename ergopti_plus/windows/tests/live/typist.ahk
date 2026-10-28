; tests/live/typist.ahk

; ==============================================================================
; MODULE: Live Typist
; DESCRIPTION:
; A separate, hook-free AutoHotkey process that types into whatever window has
; the keyboard focus, for the live checks that need real keystrokes from
; outside the driver under test (tools/maintainer/windows-live-checks.cjs).
; Input sent by another process reaches the driver's hotkeys and InputHooks the
; way a person's does, which input the driver sends to itself does not.
;
; USAGE:
;   AutoHotkey64.exe typist.ahk <script file>
; Each line of the script is "<kind><TAB><argument>": key (a Send key string),
; text (literal text), wait (milliseconds), gap (default milliseconds after each
; key or character), level (the SendLevel of what follows), mode ("input" or
; "event", the Send primitive) and mouse (left, right, middle, x1, x2, wheel or
; move, over the focused window). The process exits when the script ends.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

if A_Args.Length != 1
	ExitApp(2)
TypistRun(A_Args[1])
ExitApp(0)

/** Sends with the primitive the script chose: "input" (SendInput) or "event" (SendEvent). */
TypistSend(Mode, Keys) {
	if Mode == "event"
		SendEvent(Keys)
	else
		SendInput(Keys)
}

/**
 * One pointer action over the focused window: left, right, middle, x1, x2 (a
 * click), wheel (one notch) or move (a few pixels).
 */
TypistMouse(Kind) {
	CoordMode("Mouse", "Window")
	WinGetPos(, , &Width, &Height, "A")
	MouseMove(Width // 2, Height // 2, 0)
	switch Kind {
		case "left", "right", "middle", "x1", "x2":
			Click(Kind)
		case "wheel":
			Click("WheelDown")
		case "move":
			MouseMove(Width // 2 + 12, Height // 2 + 12, 0, "R")
		default:
			FileAppend("typist: unknown pointer action '" . Kind . "'`n", "**", "UTF-8-RAW")
			ExitApp(3)
	}
}

/** Runs one typist script. */
TypistRun(Path) {
	Gap := 40
	Mode := "input"
	for Line in StrSplit(RTrim(FileRead(Path, "UTF-8"), "`r`n"), "`n", "`r") {
		Parts := StrSplit(Line, "`t", , 2)
		if Parts.Length < 1 || Parts[1] == ""
			continue
		Kind := Parts[1]
		Argument := Parts.Length >= 2 ? Parts[2] : ""
		switch Kind {
			case "gap":
				Gap := Integer(Argument)
			case "wait":
				Sleep(Integer(Argument))
			case "level":
				SendLevel(Integer(Argument))
			case "mode":
				Mode := Argument
			case "mouse":
				TypistMouse(Argument)
				Sleep(Gap)
			case "key":
				TypistSend(Mode, Argument)
				Sleep(Gap)
			case "text":
				for Character in StrSplit(Argument) {
					TypistSend(Mode, "{Text}" . Character)
					Sleep(Gap)
				}
			default:
				FileAppend("typist: unknown line kind '" . Kind . "'`n", "**", "UTF-8-RAW")
				ExitApp(3)
		}
	}
}
