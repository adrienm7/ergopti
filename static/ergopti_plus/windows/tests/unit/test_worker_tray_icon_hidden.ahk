; tests/unit/test_worker_tray_icon_hidden.ahk

; ==============================================================================
; MODULE: Detached Worker Tray Icon Regression Test
; DESCRIPTION:
; The driver re-runs its own entry point (or its compiled executable) with a
; worker flag for the keylogger prefetch and UIA selection workers. That process
; used to keep the tray icon AutoHotkey creates for every script, so a second
; "ErgoptiPlus" entry with the default green H icon appeared beside the real
; driver for as long as the worker lived (worker-tray-icon-2026-09-25).
;
; The test launches the REAL entry as a UIA selection worker parented to this
; runner, waits for the worker's ready message (proof that its main is running)
; and asks the shell whether that process owns a notification-area icon. A
; control script with an ordinary icon proves the probe can see icons at all,
; so a hidden verdict can never come from a blind probe.
; ==============================================================================

#Requires AutoHotkey v2.0

; AutoHotkey registers its tray icon with uID AHK_NOTIFYICON (WM_USER + 4).
global _WTIH_AHK_NOTIFYICON_ID := 1028
global _WTIH_READY_TIMEOUT_MS := 30000

; Returns true when the shell reports a notification icon for (Hwnd, uID).
_WTIH_ShellHasIcon(Hwnd) {
	global _WTIH_AHK_NOTIFYICON_ID
	; NOTIFYICONIDENTIFIER: cbSize, hWnd, uID, guidItem.
	Ident := Buffer(A_PtrSize = 8 ? 40 : 28, 0)
	NumPut("UInt", Ident.Size, Ident, 0)
	NumPut("Ptr", Hwnd, Ident, A_PtrSize = 8 ? 8 : 4)
	NumPut("UInt", _WTIH_AHK_NOTIFYICON_ID, Ident, A_PtrSize = 8 ? 16 : 8)
	Rect := Buffer(16, 0)
	return DllCall("shell32\Shell_NotifyIconGetRect", "Ptr", Ident, "Ptr", Rect, "Int") = 0
}

; Waits for the AutoHotkey main window owned by Pid and returns its handle.
_WTIH_ScriptWindow(Pid, TimeoutMs) {
	PreviousDetect := A_DetectHiddenWindows
	DetectHiddenWindows(true)
	try return WinWait("ahk_class AutoHotkey ahk_pid " . Pid, , TimeoutMs / 1000)
	finally DetectHiddenWindows(PreviousDetect)
}

_WTIH_ControlProbeSeesAnOrdinaryIcon() {
	Script := A_Temp . "\ergopti_wtih_control_" . A_TickCount . ".ahk"
	Pid := 0
	try {
		FileAppend(Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
			. "Persistent()`nSetTimer(() => ExitApp(0), -20000)`n", Script, "UTF-8-RAW")
		Run('"' . A_AhkPath . '" /force "' . Script . '"', , , &Pid)
		Hwnd := _WTIH_ScriptWindow(Pid, 10000)
		Assert(Hwnd != 0, "the control script must create its main window")
		Seen := false
		Started := A_TickCount
		while !Seen && (A_TickCount - Started) < 5000 {
			Seen := _WTIH_ShellHasIcon(Hwnd)
			if !Seen
				Sleep(50)
		}
		Assert(Seen, "the shell must report the control script's tray icon; "
			. "otherwise this environment cannot observe tray icons and a hidden verdict proves nothing")
	} finally {
		if Pid
			try ProcessClose(Pid)
		try FileDelete(Script)
	}
}

_WTIH_WorkerShowsNoTrayIcon() {
	global _WTIH_READY_TIMEOUT_MS
	_WTIH_ControlProbeSeesAnOrdinaryIcon()

	SplitPath(A_ScriptDir, , &WindowsDir)
	Entry := WindowsDir . "\ErgoptiPlus.ahk"
	Assert(FileExist(Entry), "the driver entry point must exist beside the tests folder")

	ReadyFrom := 0
	; The worker announces readiness with WM_COPYDATA whose wParam is its own
	; script window. Run first and never claim the message, so any production
	; handler registered by another test still sees it.
	_WTIH_OnCopyData(wParam, lParam, Msg, Hwnd) {
		ReadyFrom := wParam
	}
	OnMessage(0x004A, _WTIH_OnCopyData, -1)
	Pid := 0
	try {
		; /force keeps #SingleInstance Force from closing a live driver that runs
		; this same entry; the production spawn passes it for the same reason.
		Run('"' . A_AhkPath . '" /force /ErrorStdOut "' . Entry
			. '" --uia-selection-worker ' . A_ScriptHwnd . ' 1', , "Hide", &Pid)
		WorkerHwnd := _WTIH_ScriptWindow(Pid, _WTIH_READY_TIMEOUT_MS)
		Assert(WorkerHwnd != 0, "the worker must start and create its script window")
		Started := A_TickCount
		while (ReadyFrom != WorkerHwnd) && (A_TickCount - Started) < _WTIH_READY_TIMEOUT_MS
			Sleep(50)
		Assert(ReadyFrom = WorkerHwnd,
			"the worker must reach its main and announce readiness to this runner")
		; Observe for a while: the worker lives until its parent window goes away.
		loop 10 {
			Assert(!_WTIH_ShellHasIcon(WorkerHwnd),
				"a detached worker must never show a tray icon of its own (it read as a second driver)")
			Sleep(100)
		}
	} finally {
		OnMessage(0x004A, _WTIH_OnCopyData, 0)
		if Pid
			try ProcessClose(Pid)
	}
}
Test("boot: a detached worker re-running the entry shows no tray icon (worker-tray-icon-2026-09-25)",
	_WTIH_WorkerShowsNoTrayIcon)
