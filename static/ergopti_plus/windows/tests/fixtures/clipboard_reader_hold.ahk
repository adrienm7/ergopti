; tests/fixtures/clipboard_reader_hold.ahk

; ==============================================================================
; MODULE: Known Clipboard Reader
; DESCRIPTION:
; A separate process stands in for the readers Windows wakes after every
; clipboard change (explorer.exe, clipboard history): it holds the global lock
; for a fixed time, then closes it. It never changes clipboard data.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

_CRH_Main() {
	if A_Args.Length != 3
		throw Error("a root, a hold time and the settle bound are required")
	Root := A_Args[1], HoldMs := Integer(A_Args[2])
	; The desktop's own readers may hold the lock when this one starts. This
	; process does not load the test framework, so the parent passes its
	; TEST_NATIVE_SETTLE_TIMEOUT_MS to bound that wait.
	SettleMs := Integer(A_Args[3])
	if SettleMs <= 0
		throw Error("the parent must pass its positive settle bound")
	Started := A_TickCount
	while !DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") {
		if A_TickCount - Started >= SettleMs
			throw Error("the known reader could not open the clipboard")
		Sleep(5)
	}
	try {
		; The receipt names this lock's window, published only once it is held.
		FileAppend(String(A_ScriptHwnd), Root . "\held.pending", "UTF-8-RAW")
		FileMove(Root . "\held.pending", Root . "\held")
		DllCall("Kernel32\Sleep", "UInt", HoldMs)
	} finally {
		if !DllCall("User32\CloseClipboard", "Int")
			throw Error("the known reader must close its own lock")
	}
	FileAppend("PASS clipboard reader hold", "*")
}

try {
	_CRH_Main()
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
