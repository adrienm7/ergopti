; tests/fixtures/agent_delayed_ics_reader.ahk
; A private, finite owned process models a handler that opens its input later.
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
Root := A_Args[1], Target := A_Args[2]
try {
	FileAppend(String(ProcessExist()), Root . "\ready.pending", "UTF-8-RAW")
	FileMove(Root . "\ready.pending", Root . "\ready")
	Started := A_TickCount
	while !FileExist(Root . "\release") && A_TickCount - Started < 20000
		Sleep(10)
	if !FileExist(Root . "\release")
		throw Error("release deadline elapsed")
	if !FileExist(Target)
		Outcome := "MISSING"
	else {
		FileCopy(Target, Root . "\received.ics")
		Outcome := "READ"
	}
	FileAppend(Outcome, Root . "\result.pending", "UTF-8-RAW")
	FileMove(Root . "\result.pending", Root . "\result")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**", "UTF-8-RAW")
	ExitApp(1)
}
