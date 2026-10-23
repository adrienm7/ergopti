; tests/fixtures/clipboard_native_open_owner_body.ahk

; ==============================================================================
; MODULE: Native Clipboard Open Characterization Child
; DESCRIPTION:
; Two genuine processes observe OpenClipboard nesting and exact caller release.
; No clipboard format is read, rendered, cleared or written. Nested return values
; are measurements, not an assumed refusal or a logical native lease ticket.
; ==============================================================================

#Requires AutoHotkey v2.0

_CNOC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_CNOC_Wait(Root, Name) {
	Started := DllCall("Kernel32\GetTickCount64", "UInt64")
	while !FileExist(Root . "\" . Name) && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 3000
		Sleep(10)
	_CNOC_Require(FileExist(Root . "\" . Name), "The exact native role handshake must arrive: " . Name)
	return FileRead(Root . "\" . Name, "UTF-8")
}

_CNOC_Publish(Root, Name, Value) {
	Temporary := Root . "\" . Name . ".pending"
	FileAppend(String(Value), Temporary, "UTF-8-RAW")
	FileMove(Temporary, Root . "\" . Name)
}

_CNOC_State() {
	return {Held: false, OpenResult: 0, OpenError: 0, CloseResult: 0, CloseError: 0, Window: 0, Attempts: 0}
}

_CNOC_Open(State, Target) {
	DllCall("Kernel32\SetLastError", "UInt", 0)
	State.OpenResult := DllCall("User32\OpenClipboard", "Ptr", Target, "Int")
	State.OpenError := A_LastError
	if State.OpenResult
		State.Held := true
	State.Window := DllCall("User32\GetOpenClipboardWindow", "Ptr")
	State.Attempts += 1
	return State.OpenResult != 0
}

_CNOC_Close(State) {
	DllCall("Kernel32\SetLastError", "UInt", 0)
	State.CloseResult := DllCall("User32\CloseClipboard", "Int")
	State.CloseError := A_LastError
	if State.CloseResult
		State.Held := false
	State.Window := DllCall("User32\GetOpenClipboardWindow", "Ptr")
	_CNOC_Require(State.CloseResult != 0, "The exact caller must receive its native Close ACK.")
}

_CNOC_Trace(Stage, State) {
	FileAppend("NATIVE_OPEN stage=" . Stage . " open=" . State.OpenResult . " open_error=" . State.OpenError
		. " close=" . State.CloseResult . " close_error=" . State.CloseError . " getopen=" . State.Window
		. " held=" . State.Held . " attempts=" . State.Attempts . "`n", "*", "UTF-8")
}

_CNOC_Acquire(State, Timeout, Retry) {
	Started := DllCall("Kernel32\GetTickCount64", "UInt64")
	loop {
		if _CNOC_Open(State, A_ScriptHwnd)
			return true
		if DllCall("Kernel32\GetTickCount64", "UInt64") - Started >= Timeout
			return false
		Sleep(Retry)
	}
}

_CNOC_Probe(Root, Name, ExpectOpen, Timeout, Retry) {
	Probe := _CNOC_State(), Primary := 0, Observed := false
	try {
		Observed := ExpectOpen ? _CNOC_Acquire(Probe, Timeout, Retry) : _CNOC_Open(Probe, A_ScriptHwnd)
		_CNOC_Trace(Name, Probe)
	} catch Any as Failure {
		Primary := Failure
	} finally {
		if Probe.Held {
			try _CNOC_Close(Probe)
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	_CNOC_Publish(Root, Name, Observed ? "open" : "busy")
	if IsObject(Primary)
		throw Primary
	_CNOC_Require(Observed == ExpectOpen, "The independent native probe violated its observed lock boundary: " . Name)
}

_CNOC_Subject(Mode, Root, State, Timeout, Retry) {
	_CNOC_Wait(Root, "observer.ready")
	if Mode == "foreign-holder" {
		_CNOC_Require(!_CNOC_Open(State, A_ScriptHwnd), "Another native process must exclude this subject.")
		_CNOC_Trace("foreign-blocked", State)
		_CNOC_Publish(Root, "subject.checked", "blocked")
		_CNOC_Wait(Root, "observer.released")
		_CNOC_Require(_CNOC_Acquire(State, Timeout, Retry), "The current positive must acquire after exact foreign release.")
		_CNOC_Trace("foreign-fresh", State)
		_CNOC_Close(State)
		_CNOC_Publish(Root, "subject.done", "closed")
		return
	}
	Target := Mode == "null-to-own" ? 0 : A_ScriptHwnd
	if Target {
		_CNOC_Require(_CNOC_Acquire(State, Timeout, Retry), "The original own-HWND caller must acquire its native lease.")
	} else {
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !_CNOC_Open(State, 0) && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < Timeout
			Sleep(Retry)
		_CNOC_Require(State.Held, "The original NULL caller must acquire its native lease.")
	}
	_CNOC_Trace("original", State)
	_CNOC_Require(State.Window == Target, "The native opening HWND observation must match the actual original call.")
	_CNOC_Publish(Root, "subject.held", "held")
	_CNOC_Require(_CNOC_Wait(Root, "probe.before") == "busy", "The first distinct PID must observe the caller's held lock.")
	; This deliberately records BOTH possible native results. A successful
	; nested Open never creates an inner Close right in this characterization.
	_CNOC_Open(State, A_ScriptHwnd)
	_CNOC_Trace("nested", State)
	_CNOC_Publish(Root, "subject.nested", "measured")
	_CNOC_Require(_CNOC_Wait(Root, "probe.nested") == "busy", "Nested observation must preserve the original caller's lock.")
	_CNOC_Close(State)
	_CNOC_Trace("original-close", State)
	_CNOC_Publish(Root, "subject.released", "closed")
	_CNOC_Require(_CNOC_Wait(Root, "probe.after") == "open", "After one native caller Close the distinct probe must open.")
	_CNOC_Publish(Root, "subject.done", "complete")
}

_CNOC_Observer(Mode, Root, State, Timeout, Retry) {
	if Mode == "foreign-holder" {
		_CNOC_Require(_CNOC_Acquire(State, Timeout, Retry), "The independent native holder must acquire its own HWND.")
		_CNOC_Trace("foreign-held", State)
		_CNOC_Publish(Root, "observer.ready", "held")
		_CNOC_Wait(Root, "subject.checked")
		_CNOC_Close(State)
		_CNOC_Publish(Root, "observer.released", "closed")
	} else {
		_CNOC_Publish(Root, "observer.ready", "ready")
		_CNOC_Wait(Root, "subject.held")
		_CNOC_Probe(Root, "probe.before", false, Timeout, Retry)
		_CNOC_Wait(Root, "subject.nested")
		_CNOC_Probe(Root, "probe.nested", false, Timeout, Retry)
		_CNOC_Wait(Root, "subject.released")
		_CNOC_Probe(Root, "probe.after", true, Timeout, Retry)
	}
	_CNOC_Wait(Root, "subject.done")
}

_CNOC_Main() {
	if A_Args.Length != 7
		ExitApp(2)
	Mode := A_Args[1], Role := A_Args[2], Root := A_Args[3]
	Timeout := Integer(A_Args[4]), Retry := Integer(A_Args[5])
	State := _CNOC_State(), Primary := 0
	try {
		_CNOC_Require(Mode == "null-to-own" || Mode == "own-to-own" || Mode == "foreign-holder", "A declared native mode is required.")
		_CNOC_Require(Role == "subject" || Role == "observer", "An exact owned role is required.")
		_CNOC_Require(Timeout > 0 && Retry > 0 && Retry <= Timeout, "Canonical native bounds must be positive.")
		_CNOC_Require(DllCall("User32\IsWindow", "Ptr", A_ScriptHwnd, "Int"), "Every role must use its actual native HWND.")
		_CNOC_Require(_CryptoSha256Cng(FSReadBytesStrict(A_ScriptFullPath)) == A_Args[6]
			&& _CryptoSha256Cng(FSReadBytesStrict(A_LineFile)) == A_Args[7], "The actual child source and fixture must match their frozen inputs.")
		FileAppend("NATIVE_OPEN_ROLE mode=" . Mode . " role=" . Role . " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
			. " tid=" . DllCall("Kernel32\GetCurrentThreadId", "UInt") . " hwnd=" . A_ScriptHwnd
			. " runtime=" . A_AhkVersion . " architecture=" . A_PtrSize * 8 . " windows=" . A_OSVersion
			. " source=" . A_Args[6] . " body=" . A_Args[7] . "`n", "*", "UTF-8")
		if Role == "subject"
			_CNOC_Subject(Mode, Root, State, Timeout, Retry)
		else
			_CNOC_Observer(Mode, Root, State, Timeout, Retry)
	} catch Any as Failure {
		Primary := Failure
	} finally {
		if State.Held {
			try _CNOC_Close(State)
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary) {
		FileAppend("FAIL native-open " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS clipboard-native-open " . Mode . " " . Role . "`n", "*", "UTF-8")
	ExitApp(0)
}

_CNOC_Main()
