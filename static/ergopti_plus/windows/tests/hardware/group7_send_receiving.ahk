; tests/hardware/group7_send_receiving.ahk
;
; ==============================================================================
; MODULE: Group 7 Native Send Receiving Measurement
; DESCRIPTION:
; Measures exact native Edit receiving and capture replay with the real DLL hook.
; Hook installation sequences describe requests, never prove physical hook order.
; Primitive measurements do not qualify production TextSender, HSE or LLM paths.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

global ProbeDll := ""
global ProbeStarted := false
global ProbeToken := 0
global ProbeClipboard := ClipboardAll()
global ProbeClipboardChanged := false
global ProbeClipboardSequence := 0
global ProbeGui := 0
global ProbeEditor := 0
OnError(ProbeFatal)
OnExit(ProbeRetire)

ProbeFatal(Failure, Mode) {
	FileAppend("FATAL " . Type(Failure) . ": " . Failure.Message . "`n", "**")
	ExitApp(1)
}

ProbeClose(*) {
	ExitApp(1)
	; A refused exit retains the visible receiving window for safe debt retry.
	return true
}

ProbeNative(Name, Arguments*) {
	global ProbeDll
	Arguments.Push("CDecl Int")
	Status := DllCall(ProbeDll . "\ErgoptiNav_" . Name, Arguments*)
	if Status != 0
		throw Error("Native " . Name . " refused with status " . Status . ".")
}

ProbeRetire(Reason, Code) {
	global ProbeDll, ProbeStarted, ProbeToken, ProbeClipboard
	global ProbeClipboardChanged, ProbeClipboardSequence, ProbeGui, ProbeEditor
	if ProbeStarted {
		if ProbeToken {
			if !IsObject(ProbeGui) || !IsObject(ProbeEditor)
					|| DllCall("GetForegroundWindow", "Ptr") != ProbeGui.Hwnd
					|| DllCall("GetFocus", "Ptr") != ProbeEditor.Hwnd {
				FileAppend("RETAINED capture debt: reacquire owned receiver/focus before Exit.`n", "**")
				return 1
			}
			for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"] {
				if GetKeyState(Key, "P") {
					FileAppend("RETAINED capture debt: release physical modifiers before Exit.`n", "**")
					return 1
				}
			}
			Status := DllCall(ProbeDll . "\ErgoptiNav_AbortTerminalCapture",
				"UInt64", ProbeToken, "CDecl Int")
			if Status != 0 {
				FileAppend("RETAINED native capture debt status=" . Status . "`n", "**")
				return 1
			}
			ProbeToken := 0
		}
		Status := DllCall(ProbeDll . "\ErgoptiNav_Stop", "CDecl Int")
		if Status != 0 {
			FileAppend("RETAINED native stop debt status=" . Status . "`n", "**")
			return 1
		}
		ProbeStarted := false
	}
	if ProbeClipboardChanged {
		if DllCall("GetClipboardSequenceNumber", "UInt") == ProbeClipboardSequence
			A_Clipboard := ProbeClipboard
		else
			FileAppend("Foreign clipboard update retained; original not restored.`n", "**")
		ProbeClipboardChanged := false
	}
	if IsObject(ProbeGui) {
		ProbeGui.Destroy()
		ProbeGui := 0
	}
	return 0
}

ProbeClock() {
	Counter := 0
	if !DllCall("QueryPerformanceCounter", "Int64*", &Counter)
		throw OSError()
	return Counter
}

ProbeForeground(Editor) {
	global ProbeGui
	if !WinActive("ahk_id " . ProbeGui.Hwnd)
		throw Error("Owned receiving window lost foreground admission.")
	if DllCall("GetFocus", "Ptr") != Editor.Hwnd
		throw Error("Owned receiving control lost focus admission.")
	for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"] {
		if GetKeyState(Key, "P")
			throw Error("Release physical modifiers before a sample.")
	}
}

ProbeEmit(Backend, Payload, Paste) {
	global ProbeClipboardChanged, ProbeClipboardSequence
	SendLevel(0)
	if Paste {
		A_Clipboard := Payload
		ProbeClipboardChanged := true
		if !ClipWait(2)
			throw Error("Synthetic clipboard payload was not admitted.")
		ProbeClipboardSequence := DllCall("GetClipboardSequenceNumber", "UInt")
		Keys := "^v"
	} else {
		Keys := "{Text}" . Payload
	}
	if Backend == "SendEvent"
		SendEvent(Keys)
	else
		SendInput(Keys)
}

if A_Args.Length != 4 || A_AhkVersion != "2.0.26" || A_PtrSize != 8
	throw Error("Use the supervisor with pinned AutoHotkey 2.0.26 x64.")
ProbeDll := A_Args[1]
InstallSequence := A_Args[2]
Physical := A_Args[3] == "physical"
Samples := Integer(A_Args[4])
if !FileExist(ProbeDll) || (InstallSequence != "ahk-before-native"
		&& InstallSequence != "native-before-ahk") || Samples < 3 || Samples > 100
	throw Error("Invalid measurement arguments.")
if A_Args[3] != "idle" && !Physical
	throw Error("Invalid observation mode.")
ProbeGui := Gui("", "Ergopti Group 7 owned native receiving fixture")
ProbeGui.OnEvent("Close", ProbeClose)
ProbeGui.AddText("w660", Physical
	? "During each countdown, type exactly xyz once. Do not press modifiers."
	: "Keep the keyboard idle. Only this synthetic owned document is measured.")
Editor := ProbeGui.AddEdit("w660 r8")
ProbeEditor := Editor
ProbeGui.Show()
WinActivate("ahk_id " . ProbeGui.Hwnd)
if !WinWaitActive("ahk_id " . ProbeGui.Hwnd, , 3)
	throw Error("Owned receiving window could not acquire foreground.")
Editor.Focus()
if InstallSequence == "ahk-before-native"
	InstallKeybdHook()
ProbeNative("Start", "UInt64", A_ScriptHwnd, "UInt", 0x8057)
ProbeStarted := true
if InstallSequence == "native-before-ahk"
	InstallKeybdHook()
; Compare these explicit primitive settings without changing production policy.
SetKeyDelay(-1, -1)
Frequency := 0
if !DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	throw OSError()
FileAppend("backend,case,sample,send_ms,receive_ms,queued,replayed,mode,install_sequence`n", "*")
LongPayload := ""
Loop 128
	LongPayload .= "0123456789 abcdefghijklmnopqrstuvwxyz "
Cases := [
	{ Name: "long-text", Payload: LongPayload, Paste: false },
	{ Name: "unicode-text", Payload: "Ergopti café Ω 中文 😀 done", Paste: false },
	{ Name: "clipboard-paste", Payload: "Owned clipboard café Ω 😀 done", Paste: true }]
NextToken := 0
for Backend in ["SendEvent", "SendInput"] {
	for CaseRecord in Cases {
		Loop Samples {
			Editor.Value := ""
			Editor.Focus()
			ProbeForeground(Editor)
			NextToken += 1
			Token := NextToken
			if Physical {
				ProbeNative("BeginTerminalCapture", "UInt64", Token)
				ProbeToken := Token
				ToolTip("Type exactly xyz now. Capture ends in 3 seconds.")
				Sleep(3000)
				ToolTip()
				ProbeForeground(Editor)
				if Editor.Value != ""
					throw Error("Capture leaked physical input before commit.")
			}
			Before := ProbeClock()
			ProbeEmit(Backend, CaseRecord.Payload, CaseRecord.Paste)
			AfterSend := ProbeClock()
			Queued := 0, Replayed := 0
			if Physical {
				ProbeForeground(Editor)
				Captured := Buffer(28, 0)
				ProbeNative("GetTerminalCapture", "UInt64", Token, "Ptr", Captured)
				Queued := NumGet(Captured, 12, "UInt")
				ProbeNative("CommitTerminalCapture", "UInt64", Token)
				Snapshot := Buffer(28, 0)
				ProbeNative("GetTerminalCapture", "UInt64", Token, "Ptr", Snapshot)
				Replayed := NumGet(Snapshot, 16, "UInt")
				if NumGet(Snapshot, 8, "UInt") != 0 || NumGet(Snapshot, 12, "UInt") != 0
						|| Queued < 6 || Replayed != Queued
					throw Error("Physical capture lacks complete balanced replay evidence.")
				ProbeToken := 0
			}
			Expected := CaseRecord.Payload . (Physical ? "xyz" : "")
			Deadline := A_TickCount + 5000
			while Editor.Value != Expected && A_TickCount < Deadline {
				ProbeForeground(Editor)
				Sleep(1)
			}
			AfterReceive := ProbeClock()
			ProbeForeground(Editor)
			if Editor.Value != Expected
				throw Error("Exact receiving failed for " . Backend . "/" . CaseRecord.Name . ".")
			; A settled observation catches late duplicate/interleaved delivery.
			Sleep(100)
			if Editor.Value != Expected
				throw Error("Settled receiving changed after exact match.")
			SendMs := (AfterSend - Before) * 1000 / Frequency
			ReceiveMs := (AfterReceive - Before) * 1000 / Frequency
			FileAppend(Backend . "," . CaseRecord.Name . "," . A_Index . ","
				. Format("{:.4f},{:.4f}", SendMs, ReceiveMs) . "," . Queued . ","
				. Replayed . "," . A_Args[3] . "," . InstallSequence . "`n", "*")
		}
	}
}
if ProbeRetire("Completed", 0) == 1
	throw Error("Native retirement remains pending; completion refused.")
FileAppend("COMPLETE exact native Edit receiving; production and physical hook order remain unqualified.`n", "*")
ExitApp(0)
