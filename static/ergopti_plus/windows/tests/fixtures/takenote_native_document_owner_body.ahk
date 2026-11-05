; tests/fixtures/takenote_native_document_owner_body.ahk
; Real Notepad documents behind the genuine filename lookup and deferred note job.
#Requires AutoHotkey v2.0

class _TNDO_Ops extends _TakeNoteNative {
	static Errors := []
	static Warnings := []
	static Launches := []
	static Launch(Path) {
		; The only observed IO: retain the PID of the identical native command.
		Run('notepad.exe "' . Path . '"', , , &Pid)
		_TNDO_Ops.Launches.Push(Path)
		_TNDO_HoldProcess(Pid, true)
		return true
	}
	static ReportError(Message) => _TNDO_Ops.Errors.Push(Message)
	static WarnTimeout(Pattern, Waited) => _TNDO_Ops.Warnings.Push(Waited)
}
LoggerError(Args*) {
	FileAppend("DIAGNOSTIC unexpected logger error`n", "*")
}
LoggerWarn(Args*) {
	FileAppend("DIAGNOSTIC unexpected logger warning`n", "*")
}
t(Key) => Key
SendFinalResult(Args*) {
	throw Error("This document-identity probe never authorizes final text input.")
}
_TNDO_Require(Value, Message) {
	if !Value
		throw Error(Message)
}
_TNDO_HoldProcess(Pid, FromRun := false) {
	global _TNDO
	if _TNDO.Processes.Has(Pid)
		return _TNDO.Processes[Pid]
	Handle := DllCall("kernel32\OpenProcess", "UInt", 0x101001, "Int", false, "UInt", Pid, "Ptr")
	if !Handle {
		; A packaged Notepad launcher can exit before its document appears.
		_TNDO_Require(FromRun && !ProcessExist(Pid), "A live native Notepad process must expose an exact handle")
		return 0
	}
	try {
		Chars := 32768, ImageBuffer := Buffer(Chars * 2)
		_TNDO_Require(DllCall("kernel32\QueryFullProcessImageNameW", "Ptr", Handle, "UInt", 0,
			"Ptr", ImageBuffer, "UInt*", &Chars), "The native process image must be readable")
		Image := StrGet(ImageBuffer, Chars, "UTF-16"), Lower := StrLower(Image)
		Genuine := Lower == StrLower(A_WinDir . "\System32\notepad.exe")
			|| Lower == StrLower(A_WinDir . "\notepad.exe")
			|| (InStr(Lower, "\windowsapps\microsoft.windowsnotepad_") && SubStr(Lower, -12) == "\notepad.exe")
		_TNDO_Require(Genuine, "The launched document must belong to the actual Windows Notepad image")
		_TNDO_Require(DllCall("kernel32\GetProcessId", "Ptr", Handle, "UInt") == Pid,
			"The retained process handle must identify the observed PID")
		Receipt := {Pid: Pid, Handle: Handle, Image: Image, FromRun: FromRun}
		_TNDO.Processes[Pid] := Receipt
		Handle := 0
		return Receipt
	} finally {
		if Handle
			DllCall("kernel32\CloseHandle", "Ptr", Handle)
	}
}
_TNDO_ReadDocument(Hwnd) {
	; Classic Edit and the packaged RichEdit backend expose their actual text.
	for Control in WinGetControlsHwnd("ahk_id " . Hwnd) {
		ControlClass := WinGetClass("ahk_id " . Control)
		if !RegExMatch(ControlClass, "i)^(?:Edit|RichEdit.*)$")
			continue
		try return ControlGetText(Control)
	}
	return ""
}
_TNDO_ObserveWindows() {
	global _TNDO
	for Hwnd in WinGetList("ahk_exe notepad.exe") {
		try {
			Pid := WinGetPID("ahk_id " . Hwnd)
			Text := _TNDO_ReadDocument(Hwnd)
			Document := Text == _TNDO.CanaryA ? "A" : Text == _TNDO.CanaryB ? "B" : ""
			; A Run receipt owns its exact process. A broker-created process is
			; adopted only after its actual document proves the private canary.
			if Document == "" && !_TNDO.Processes.Has(Pid)
				continue
			Process := _TNDO_HoldProcess(Pid)
			if !IsObject(Process) || DllCall("kernel32\WaitForSingleObject", "Ptr", Process.Handle, "UInt", 0, "UInt") != 258
				continue
			if WinGetPID("ahk_id " . Hwnd) != Pid
				continue
			_TNDO.Windows[Hwnd] := {Hwnd: Hwnd, Process: Process, Document: Document}
		} catch as ObserveError {
			_TNDO.ObserveError := ObserveError.Message
		}
	}
}
_TNDO_WaitJob(JobId) {
	global _TakeNotePending
	_TNDO_Require(JobId > 0, "The public request must admit a real deferred job")
	Started := A_TickCount
	while _TakeNotePending.Has(JobId) && TickElapsed64(Started) < 12000 {
		_TNDO_ObserveWindows()
		Sleep(10)
	}
	_TNDO_ObserveWindows()
	_TNDO_Require(!_TakeNotePending.Has(JobId), "The real note job must reach its bounded terminal outcome")
	_TNDO_Require(_TNDO_Ops.Errors.Length == 0 && _TNDO_Ops.Warnings.Length == 0,
		"The actual window/focus path must complete without a technical refusal")
}
_TNDO_WindowCurrent(Receipt) {
	try return WinExist("ahk_id " . Receipt.Hwnd)
		&& WinGetPID("ahk_id " . Receipt.Hwnd) == Receipt.Process.Pid
		&& DllCall("kernel32\WaitForSingleObject", "Ptr", Receipt.Process.Handle, "UInt", 0, "UInt") == 258
	catch
		return false
}
_TNDO_Cleanup() {
	global _TNDO
	Clean := true
	TakeNoteRevokePending()
	_TNDO_ObserveWindows()
	for Hwnd, Receipt in _TNDO.Windows {
		if DllCall("kernel32\WaitForSingleObject", "Ptr", Receipt.Process.Handle, "UInt", 0, "UInt") != 258
			continue
		if _TNDO_WindowCurrent(Receipt) {
			try WinClose("ahk_id " . Hwnd)
		}
	}
	Started := A_TickCount
	while TickElapsed64(Started) < 2000 {
		Remaining := false
		for Hwnd, Receipt in _TNDO.Windows
			if _TNDO_WindowCurrent(Receipt)
				Remaining := true
		if !Remaining
			break
		Sleep(10)
	}
	for Pid, Process in _TNDO.Processes {
		try {
			if DllCall("kernel32\WaitForSingleObject", "Ptr", Process.Handle, "UInt", 0, "UInt") == 258 {
				; Every retained process has either the exact native Run receipt or
				; an authenticated private document. Never kill by executable name.
				if !DllCall("kernel32\TerminateProcess", "Ptr", Process.Handle, "UInt", 91)
					Clean := false
				else if DllCall("kernel32\WaitForSingleObject", "Ptr", Process.Handle, "UInt", 2000, "UInt") != 0
					Clean := false
			}
		} finally DllCall("kernel32\CloseHandle", "Ptr", Process.Handle)
	}
	for Hwnd in WinGetList("ahk_exe notepad.exe")
		if !_TNDO.Windows.Has(Hwnd)
			Clean := false
	return Clean
}

; Diagnostics only: no raw accessible text or unowned window is disclosed.
_TNDO_IdentityCurrent(Hwnd) {
	global _TNDO
	return Hwnd && _TNDO.Windows.Has(Hwnd) && _TNDO_WindowCurrent(_TNDO.Windows[Hwnd])
}
_TNDO_IdentityValue(Value) {
	global _TNDO
	if !(Value is String)
		return "<non-string>"
	Result := "units=" . StrLen(Value)
	for Label in ["A", "B"] {
		PrivatePath := _TNDO.Root . "\" . Label . "\Notes.txt"
		Canary := Label == "A" ? _TNDO.CanaryA : _TNDO.CanaryB
		if Value == PrivatePath
			Result .= ",exact_path=" . Label
		else if InStr(Value, PrivatePath, true)
			Result .= ",contains_path=" . Label
		if Value == Canary
			Result .= ",exact_canary=" . Label
	}
	; Only independently authored private identities are classified. Unknown
	; properties, document contents and surrounding text are never emitted.
	return Result
}
_TNDO_InspectDocumentIdentity(Hwnd, Phase) {
	global _TNDO
	try {
		if !_TNDO_IdentityCurrent(Hwnd)
			return
		RootElement := UIA.ElementFromHandle(Hwnd, , false)
		Walker := UIA.TreeWalkerTrue
		Pending := [{Element: RootElement, Depth: 0}], Count := 0
		while Pending.Length && Count < 96 {
			if !_TNDO_IdentityCurrent(Hwnd)
				return
			Item := Pending.Pop(), Element := Item.Element
			ElementPid := Element.GetPropertyValue("ProcessId")
			if !_TNDO_IdentityCurrent(Hwnd) || ElementPid != _TNDO.Windows[Hwnd].Process.Pid
				continue
			Count += 1
			Line := "IDENTITY takenote phase=" . Phase . " index=" . Count . " depth=" . Item.Depth
			for Property in ["ControlType", "AutomationId", "Name", "HelpText", "ItemStatus",
				"ValueValue", "LegacyIAccessibleValue", "LegacyIAccessibleDescription", "FullDescription", "SelectionItemIsSelected"] {
				if !_TNDO_IdentityCurrent(Hwnd)
					return
				try Value := Element.GetPropertyValue(Property)
				catch {
					Line .= " " . Property . "=<unavailable>"
					continue
				}
				if Property == "ControlType" && Value is Integer && Value >= 50000 && Value <= 50100
					Line .= " " . Property . "=" . Value
				else if Property == "SelectionItemIsSelected" && Value is Integer && (Value == 0 || Value == 1)
					Line .= " " . Property . "=" . Value
				else
					Line .= " " . Property . "=[" . _TNDO_IdentityValue(Value) . "]"
			}
			FileAppend(Line . "`n", "*")
			if Item.Depth < 8 {
				if !_TNDO_IdentityCurrent(Hwnd)
					return
				Child := Walker.TryGetFirstChildElement(Element)
				while IsObject(Child) && Pending.Length + Count < 96 {
					Pending.Push({Element: Child, Depth: Item.Depth + 1})
					if !_TNDO_IdentityCurrent(Hwnd)
						return
					Child := Walker.TryGetNextSiblingElement(Child)
				}
			}
		}
		FileAppend("IDENTITY takenote phase=" . Phase . " scanned=" . Count . "`n", "*")
	} catch Any {
		FileAppend("IDENTITY takenote phase=" . Phase . " inspection_failed=1`n", "*")
	}
}

_TNDO_Main() {
	global _TNDO, _TakeNotePending
	_TNDO_Require(A_Args.Length == 2, "A mode and exclusively owned directory are required")
	Mode := A_Args[1], Root := A_Args[2]
	_TNDO_Require(Mode == "same-folder" || Mode == "different-folder", "Unknown document mode")
	_TNDO_Require(!ProcessExist("notepad.exe") && WinGetList("ahk_exe notepad.exe").Length == 0,
		"A private Notepad probe cannot borrow an existing process or window")
	_TNDO := {Root: Root, Processes: Map(), Windows: Map(), CanaryA: "owned_note_A_" . A_ScriptHwnd,
		CanaryB: "owned_note_B_" . A_ScriptHwnd, ObserveError: ""}
	Clean := false
	try {
		DirCreate(Root . "\A"), DirCreate(Root . "\B")
		FileA := Root . "\A\Notes.txt", FileB := Root . "\B\Notes.txt"
		FileAppend(_TNDO.CanaryA, FileA, "UTF-8-RAW")
		FileAppend(_TNDO.CanaryB, FileB, "UTF-8-RAW")
		_TNDO_WaitJob(TakeNoteRequest(false, Root . "\A", false, _TNDO_Ops))
		First := WinActive("ahk_exe notepad.exe")
		_TNDO_Require(_TNDO_IdentityCurrent(First) && _TNDO_ReadDocument(First) == _TNDO.CanaryA,
			"The first genuine request must expose actual document A in its owned Notepad")
		_TNDO_InspectDocumentIdentity(First, "first-A")
		BeforeLaunches := _TNDO_Ops.Launches.Length
		Target := Mode == "same-folder" ? "A" : "B"
		_TNDO_WaitJob(TakeNoteRequest(false, Root . "\" . Target, false, _TNDO_Ops))
		Active := WinActive("ahk_exe notepad.exe")
		Text := _TNDO_IdentityCurrent(Active) ? _TNDO_ReadDocument(Active) : ""
		Actual := Text == _TNDO.CanaryA ? "A" : Text == _TNDO.CanaryB ? "B" : "unknown"
		if _TNDO_IdentityCurrent(Active)
			_TNDO_InspectDocumentIdentity(Active, "second-" . Target)
		FileAppend("OBSERVATION takenote-document mode=" . Mode . " target=" . Target . " actual=" . Actual
			. " first_hwnd=" . First . " active_hwnd=" . Active . " launches_before=" . BeforeLaunches
			. " launches_after=" . _TNDO_Ops.Launches.Length . " pending=" . _TakeNotePending.Count
			. " errors=" . _TNDO_Ops.Errors.Length . " warnings=" . _TNDO_Ops.Warnings.Length . "`n", "*")
		_TNDO_Require(Actual == Target, "The real TakeNote request must focus the requested directory's document")
		_TNDO_Require(FileRead(FileA, "UTF-8") == _TNDO.CanaryA && FileRead(FileB, "UTF-8") == _TNDO.CanaryB,
			"Both actual files must retain their exact owned contents")
		_TNDO_Require(Mode != "same-folder" || (Active == First && _TNDO_Ops.Launches.Length == BeforeLaunches),
			"Same-folder reuse must preserve the original native window without another launch")
	} finally {
		Clean := _TNDO_Cleanup()
		FileAppend("CLEANUP takenote-document retired=" . (Clean ? 1 : 0) . "`n", "*")
		_TNDO_Require(Clean, "Exact native document/process retirement must finish before directory cleanup")
	}
	FileAppend("PASS takenote-document " . Mode . "`n", "*")
}
try {
	_TNDO_Main()
	ExitApp(0)
} catch Any as _TNDO_EntryFailure {
	FileAppend("FAIL takenote-document " . _TNDO_EntryFailure.Message . "`n", "*")
	ExitApp(1)
}
