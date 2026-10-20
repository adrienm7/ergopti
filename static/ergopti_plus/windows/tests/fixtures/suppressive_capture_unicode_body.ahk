; tests/fixtures/suppressive_capture_unicode_body.ahk

; ==============================================================================
; MODULE: Explicit Native Unicode Capture Fixture
; DESCRIPTION:
; Receives real VK_PACKET input through the genuine one-shot and dead-key
; owners. Application emitters are observers, and a native safety hook consumes
; the abandoned tail. This does not qualify application receiving or FIFO.
; ==============================================================================

if A_Args.Length != 3 || A_Args[1] != "--allow-explicit-user32-sendinput" {
	FileAppend("REFUSED: explicit native input opt-in, known case and shared path are required.`n", "**")
	ExitApp(2)
}
if A_AhkVersion != "2.0.26" || A_PtrSize != 8 {
	FileAppend("REFUSED: pinned AutoHotkey 2.0.26 64-bit Windows is required.`n", "**")
	ExitApp(2)
}
_UNC_Allowed := Map("one-shot-a", true, "one-shot-AB", true, "one-shot-surrogate", true,
	"dead-key-a", true, "dead-key-AB", true, "dead-key-surrogate", true)
if !_UNC_Allowed.Has(A_Args[2]) {
	FileAppend("REFUSED: unknown native Unicode capture case.`n", "**")
	ExitApp(2)
}

; Reuses the existing explicit INPUT40 fixture's packet ABI, sender and owned
; Edit admission. All application emitters are observers. The older safety hook
; consumes the tail which L1 stops owning, so no injected text reaches any app.
; These two test-local hooks have exact finally/exit owners, outside the product
; registry whose exclusive one-shot/dead-key admission is under test.
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605))
global OneShotShiftEnabled := false, InDeadKeySequence := false
global _UNC := { Case: A_Args[2], Gui: 0, Edit: 0, Hwnd: 0, EditHwnd: 0, Thread: 0,
	Pid: DllCall("GetCurrentProcessId", "UInt"), Guard: 0, Observer: 0, Target: 0, Token: 0,
	Units: [], Observed: [], Tail: [], Emits: [], Ups: 0, Calls: 0, Inserted: -1,
	Debt: false, Injected: false, Cancelled: false, Error: 0, Logs: 0, Activations: 0, ArmedAt: 0 }
OnExit(_UNC_Exit)

_UNC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_UNC_Units(Text) {
	Units := []
	Loop StrLen(Text)
		Units.Push(NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Units
}

_UNC_Hex(Units) {
	Out := ""
	for Unit in Units
		Out .= (Out == "" ? "" : ",") . Format("{:04X}", Unit)
	return Out == "" ? "empty" : Out
}

_UNC_Same(First, Second) {
	if First.Length != Second.Length
		return false
	for Index, Value in First
		if Value != Second[Index]
			return false
	return true
}

LoggerError(*) {
	global _UNC
	_UNC.Logs += 1
}

ActivateHotstrings() {
	global _UNC
	_UNC.Activations += 1
}

SendNewResult(Text, *) {
	global _UNC
	_UNC.Emits.Push(_UNC_Units(Text))
}

Send(*) {
	throw Error("No control-key emit belongs to this native Unicode capture vector.")
}

_UNC_Identity(Hwnd) {
	Pid := 0
	Thread := DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &Pid, "UInt")
	return Map("thread", Thread, "pid", Pid)
}

_UNC_Admit() {
	global _UNC
	Owner := _UNC_Identity(_UNC.Hwnd), Child := _UNC_Identity(_UNC.EditHwnd)
	_UNC_Require(IsObject(_UNC.Gui) && IsObject(_UNC.Edit) && _UNC.Hwnd && _UNC.EditHwnd,
		"Owned receiving objects disappeared.")
	_UNC_Require(_UNC.Gui.Hwnd == _UNC.Hwnd && _UNC.Edit.Hwnd == _UNC.EditHwnd
		&& Owner["pid"] == _UNC.Pid && Child["pid"] == _UNC.Pid
		&& Owner["thread"] == _UNC.Thread && Child["thread"] == _UNC.Thread
		&& DllCall("GetForegroundWindow", "Ptr") == _UNC.Hwnd
		&& DllCall("GetFocus", "Ptr") == _UNC.EditHwnd && !A_IsSuspended,
		"Owned PID/thread/foreground/focus admission was withdrawn.")
	for Key, Vk in Map("LCtrl", 0xA2, "RCtrl", 0xA3, "LAlt", 0xA4, "RAlt", 0xA5,
		"LShift", 0xA0, "RShift", 0xA1, "LWin", 0x5B, "RWin", 0x5C)
		_UNC_Require(!GetKeyState(Key, "P") && !(DllCall("GetAsyncKeyState", "Int", Vk, "Short") & 0x8000),
			"Release physical modifiers and keep the explicit native fixture idle.")
}

_UNC_Observed(Hook, Text) {
	global _UNC
	for Unit in _UNC_Units(Text)
		_UNC.Observed.Push(Unit)
}

_UNC_Tail(Hook, Text) {
	global _UNC
	for Unit in _UNC_Units(Text)
		_UNC.Tail.Push(Unit)
}

_UNC_Up(Hook, Vk, Sc) {
	global _UNC
	if Vk != 0xE7 {
		_UNC.Error := Error("Unexpected non-VK_PACKET input entered the explicit fixture.")
		return
	}
	_UNC.Ups += 1
}

_UNC_Packets(Units) {
	; Exact existing _LNTOC_PacketSerialize INPUT40 layout and marker. Only the
	; literal unit vector differs. No serializer/custody/backend is qualified.
	Packets := Buffer(Units.Length * 2 * 40, 0)
	for Index, Unit in Units {
		for Up in [false, true] {
			Offset := ((Index - 1) * 2 + (Up ? 1 : 0)) * 40
			NumPut("UInt", 1, Packets, Offset)
			NumPut("UShort", 0, "UShort", Unit, "UInt", Up ? 6 : 4, Packets, Offset + 8)
			NumPut("UInt64", 0x4552475054524D31, Packets, Offset + 24)
		}
	}
	return Packets
}

_UNC_Inject() {
	global _UNC, _SIHO_Owners
	if _UNC.Injected || _UNC.Cancelled
		return
	try {
		if SIHO_Count() != 1 {
			_UNC_Require(DllCall("GetTickCount64", "UInt64") - _UNC.ArmedAt < 5000,
				"The actual product capture never acquired its owner.")
			SetTimer(_UNC_Inject, -5)
			return
		}
		PreviousCritical := Critical("On")
		try {
			for Token, Record in _SIHO_Owners {
				_UNC.Token := Token, _UNC.Target := Record["hook"]
				ExpectedOwner := InStr(_UNC.Case, "one-shot-") == 1 ? "one-shot-shift" : "dead-key"
				_UNC_Require(Record["owner"] == ExpectedOwner && Record["exclusive"]
					&& _UNC.Target is InputHook && _UNC.Target.InProgress && _UNC.Target.MinSendLevel == 0,
					"The real registered native product InputHook must own injection.")
			}
			; Newest and visible: observe every packet before the product consumes
			; its prefix. The older suppressive guard owns any remaining tail.
			_UNC.Observer := InputHook("V L0")
			_UNC.Observer.KeyOpt("{All}", "N")
			_UNC.Observer.OnChar := _UNC_Observed
			_UNC.Observer.OnKeyUp := _UNC_Up
			_UNC.Observer.Start()
			Packets := _UNC_Packets(_UNC.Units)
			_UNC_Admit()
			_UNC.Debt := true, _UNC.Injected := true, _UNC.Calls += 1
			_UNC.Inserted := _LLM_TerminalOutputSendInputNative(_UNC.Units.Length * 2, Packets, 40)
			_UNC_Require(_UNC.Inserted == _UNC.Units.Length * 2, "The native primitive refused part of the exact INPUT40 vector.")
		} finally Critical(PreviousCritical)
	} catch as Err {
		_UNC.Error := Err
		try SIHO_StopAll()
		catch as CleanupErr
			FileAppend("CLEANUP_FAILED " . CleanupErr.Message . "`n", "**")
	}
}

_UNC_Drain() {
	global _UNC
	Started := DllCall("GetTickCount64", "UInt64")
	while DllCall("GetTickCount64", "UInt64") - Started < 5000 {
		if _UNC.Inserted == _UNC.Units.Length * 2 && _UNC.Ups == _UNC.Units.Length
				&& _UNC_Same(_UNC.Observed, _UNC.Units) {
			_UNC.Debt := false
			return
		}
		Sleep(10)
	}
	throw Error("Exact packet chars/Up notifications were not drained. Keep native hooks owned until external child retirement.")
}

_UNC_Close(*) {
	global _UNC
	if _UNC.Debt
		return true
	_UNC.Cancelled := true
	SIHO_StopAll()
	return true
}

_UNC_Exit(Reason, Code) {
	global _UNC
	if _UNC.Debt {
		FileAppend("RETAINED pid=" . _UNC.Pid . " case=" . _UNC.Case . " native_input_debt=true natural_exit=false`n", "**")
		return 1
	}
	Failures := []
	try SetTimer(_UNC_Inject, 0)
	catch as Err
		Failures.Push(Err)
	try SIHO_StopAll()
	catch as Err
		Failures.Push(Err)
	for Hook in [_UNC.Observer, _UNC.Guard] {
		if !IsObject(Hook)
			continue
		try Hook.Stop()
		catch as Err
			Failures.Push(Err)
	}
	if Failures.Length {
		for Err in Failures
			FileAppend("RETAINED cleanup_failure=" . Err.Message . " external_owned_retirement_required=true`n", "**")
		return 1
	}
	if IsObject(_UNC.Gui) {
		try _UNC.Gui.Destroy()
		catch as Err {
			FileAppend("RETAINED gui_cleanup_failure=" . Err.Message . " external_owned_retirement_required=true`n", "**")
			return 1
		}
	}
	FileAppend("NATURAL_EXIT code=" . Code . " native_input_debt=false`n", "*")
	return 0
}

_UNC_Run() {
	global _UNC
	OneShot := InStr(_UNC.Case, "one-shot-") == 1
	Kind := SubStr(_UNC.Case, 10)
	_UNC.Units := Kind == "a" ? [0x61] : (Kind == "AB" ? [0x41, 0x42] : [0xD83D, 0xDE00])
	_UNC_Require(_TapHoldOneShotTable()["results"].Count > 0 && _UNC.Logs == 0,
		"The canonical shared JSON must load without fallback before capture.")
	_UNC.Gui := Gui("", "Ergopti explicit native InputHook Unicode capture")
	_UNC.Gui.OnEvent("Close", _UNC_Close)
	_UNC.Gui.OnEvent("Escape", _UNC_Close)
	_UNC.Edit := _UNC.Gui.AddEdit("w480 r3")
	_UNC.Hwnd := _UNC.Gui.Hwnd, _UNC.EditHwnd := _UNC.Edit.Hwnd
	_UNC.Thread := _UNC_Identity(_UNC.Hwnd)["thread"]
	_UNC.Gui.Show()
	WinActivate("ahk_id " . _UNC.Hwnd)
	_UNC_Require(WinWaitActive("ahk_id " . _UNC.Hwnd, , 3), "The exact owned Edit could not activate.")
	_UNC.Edit.Focus()
	_UNC_Admit()
	InstallKeybdHook()
	_UNC.Guard := InputHook("L0")
	_UNC.Guard.OnChar := _UNC_Tail
	_UNC.Guard.Start()
	_UNC_Require(SIHO_Count() == 0, "Only the actual product hook joins the product's exclusive registry.")
	_UNC.ArmedAt := DllCall("GetTickCount64", "UInt64")
	SetTimer(_UNC_Inject, -1)
	CaptureError := 0
	try {
		if OneShot
			OneShotShift()
		else
			DeadKey(Map("a", Chr(0x00E4), " ", Chr(0x00A8)))
	} catch as Err {
		; A failure after native capture must not hide the captured code units
		; or bypass draining the inserted batch under the still-owned guard.
		CaptureError := Err
	} finally SetTimer(_UNC_Inject, 0)
	_UNC_Require(_UNC.Injected && _UNC.Calls == 1, "The real native capture must receive exactly one native packet batch.")
	try _UNC_Drain()
	catch as DrainError {
		if IsObject(CaptureError)
			FileAppend("OWNER_FAILURE " . CaptureError.Message . "`n" . CaptureError.Stack . "`n", "**")
		throw DrainError
	}
	if IsObject(_UNC.Error)
		throw _UNC.Error
	_UNC_Admit()
	TargetUnits := _UNC_Units(_UNC.Target.Input)
	ExpectedTarget := Kind == "a" ? [0x61] : (Kind == "AB" ? [0x41] : [0xD83D, 0xDE00])
	ExpectedTail := Kind == "AB" ? [0x42] : []
	ExpectedEmits := OneShot ? [Kind == "surrogate" ? [0xD83D, 0xDE00] : [0x41]]
		: (Kind == "a" ? [[0xE4]] : [[0xA8], ExpectedTarget])
	FileAppend("RECEIPT source_scope=parent_execution_manifest runtime=" . A_AhkVersion . " pid=" . _UNC.Pid . " case=" . _UNC.Case
		. " input=" . _UNC_Hex(_UNC.Units) . " observed=" . _UNC_Hex(_UNC.Observed)
		. " target=" . _UNC_Hex(TargetUnits) . " end_reason=" . _UNC.Target.EndReason . " tail=" . _UNC_Hex(_UNC.Tail)
		. " ups=" . _UNC.Ups . " native_calls=" . _UNC.Calls . " inserted=" . _UNC.Inserted
		. " scope=native_capture_and_observed_emission application_receiving=false`n", "*")
	for Index, Units in _UNC.Emits
		FileAppend("EMIT " . Index . " utf16=" . _UNC_Hex(Units) . "`n", "*")
	if IsObject(CaptureError)
		throw CaptureError
	_UNC_Require(_UNC.Target.EndReason != "" && _UNC.Target.EndReason != "Timeout" && !_UNC.Target.InProgress
		&& SIHO_Count() == 0 && !_SIHO_Owners.Has(_UNC.Token),
		"The real product owner must settle capture and retire its exact native token without timeout.")
	_UNC_Require(_UNC_Same(TargetUnits, ExpectedTarget), "The native capture lost or over-consumed a UTF-16 unit.")
	_UNC_Require(_UNC_Same(_UNC.Tail, ExpectedTail), "Only a second independent BMP character may escape to the safety guard.")
	_UNC_Require(_UNC.Emits.Length == ExpectedEmits.Length, "The genuine owner emitted the wrong number of observed results.")
	for Index, Units in ExpectedEmits
		_UNC_Require(_UNC_Same(_UNC.Emits[Index], Units), "The genuine owner emitted an incomplete or incorrect Unicode result.")
	_UNC_Require(_UNC.Logs == 0 && _UNC.Activations == 0 && _UNC.Edit.Value == "",
		"No hidden error, special-key branch or application text may qualify this capture.")
}

FileAppend("BEGIN source_scope=parent_execution_manifest runtime=" . A_AhkVersion . " pid=" . _UNC.Pid . " case=" . _UNC.Case . "`n", "*")
try {
	_UNC_Run()
	FileAppend("PASS native-inputhook-unicode-capture`n", "*")
	ExitApp(0)
} catch as Err {
	FileAppend("FAIL " . Err.Message . "`n" . Err.Stack . "`n", "**")
	if _UNC.Debt {
		FileAppend("RETAINED pid=" . _UNC.Pid . " case=" . _UNC.Case . " input_debt=true external_owned_retirement_required=true`n", "**")
		Persistent()
		return
	}
	ExitApp(1)
}
