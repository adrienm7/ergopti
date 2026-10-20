; tests/fixtures/suppressive_capture_unicode_body.ahk

; ==============================================================================
; MODULE: Explicit Native Unicode Capture Fixture
; DESCRIPTION:
; Receives native input through the genuine one-shot and dead-key owners,
; or an explicitly selected EndChars prototype. Application emitters are
; observers, and a native safety hook consumes the abandoned tail. This does
; not qualify application receiving or a native FIFO.
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
	"dead-key-a", true, "dead-key-AB", true, "dead-key-surrogate", true,
	"prototype-a", true, "prototype-AB", true, "prototype-surrogate", true, "prototype-open-brace", true,
	"prototype-close-brace", true, "prototype-punctuation", true, "prototype-enter", true,
	"one-shot-punctuation", true, "one-shot-open-brace", true, "one-shot-close-brace", true,
	"one-shot-enter", true, "one-shot-pair-B", true, "one-shot-magic-astral", true,
	"one-shot-disabled-surrogate", true, "one-shot-disabled-magic-astral", true,
	"dead-key-punctuation", true, "dead-key-open-brace", true, "dead-key-close-brace", true,
	"dead-key-enter", true, "dead-key-pair-B", true,
	"one-shot-backspace", true, "one-shot-delete", true, "dead-key-backspace", true, "dead-key-delete", true)
if !_UNC_Allowed.Has(A_Args[2]) {
	FileAppend("REFUSED: unknown native Unicode capture case.`n", "**")
	ExitApp(2)
}

; Reuses the existing explicit INPUT40 fixture's packet ABI, sender and owned
; Edit admission. All application emitters are observers. The older safety hook
; consumes the tail which the scalar capture stops owning, so no injected text reaches any app.
; These two test-local hooks have exact finally/exit owners, outside the product
; registry whose exclusive one-shot/dead-key admission is under test.
global _SharedDir := A_Args[3], _TapHoldOneShotCache := 0
global ScriptInformation := Map("MagicKey", Chr(0x2605))
global OneShotShiftEnabled := false, InDeadKeySequence := false
global _UNC := { Case: A_Args[2], Gui: 0, Edit: 0, Hwnd: 0, EditHwnd: 0, Thread: 0,
	Pid: DllCall("GetCurrentProcessId", "UInt"), Guard: 0, Observer: 0, Target: 0, Token: 0,
	Units: [], ExpectedObserved: 0, Observed: [], Tail: [], Emits: [], Controls: [], Ups: 0, UpVk: 0xE7, Calls: 0, Inserted: -1,
	PrototypeInjectedAt: 0,
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

Send(Keys) {
	global _UNC
	_UNC.Controls.Push(Keys)
}

LoggerWarn(*) {
	global _UNC
	_UNC.Logs += 1
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
	if Vk != _UNC.UpVk {
		_UNC.Error := Error("Unexpected native key entered the explicit fixture.")
		return
	}
	_UNC.Ups += 1
}

_UNC_Packets(Units, Vk := 0) {
	; Exact existing _LNTOC_PacketSerialize INPUT40 layout and marker. The
	; prototype also selects genuine named Enter down/up without Unicode flags.
	; No serializer/custody/backend is qualified.
	Packets := Buffer(Units.Length * 2 * 40, 0)
	for Index, Unit in Units {
		for Up in [false, true] {
			Offset := ((Index - 1) * 2 + (Up ? 1 : 0)) * 40
			NumPut("UInt", 1, Packets, Offset)
			; A named Enter control uses genuine virtual-key down/up packets.
			; The default Unicode path keeps the original INPUT40 representation.
			Flags := Vk ? (Up ? 2 : 0) : (Up ? 6 : 4)
			NumPut("UShort", Vk, "UShort", Vk ? 0 : Unit, "UInt", Flags, Packets, Offset + 8)
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
				ExpectedOwner := InStr(_UNC.Case, "prototype-") == 1 ? "scalar-prototype"
					: (InStr(_UNC.Case, "one-shot-") == 1 ? "one-shot-shift" : "dead-key")
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
			Packets := _UNC_Packets(_UNC.Units, _UNC.UpVk == 0xE7 ? 0 : _UNC.UpVk)
			_UNC_Admit()
			if InStr(_UNC.Case, "prototype-") == 1
				_UNC.PrototypeInjectedAt := _UNC_Qpc()
			if InStr(_UNC.Case, "one-shot-disabled-") == 1
				OneShotShiftFix()
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
	Expected := _UNC.ExpectedObserved is Array ? _UNC.ExpectedObserved : _UNC.Units
	while DllCall("GetTickCount64", "UInt64") - Started < 5000 {
		if _UNC.Inserted == _UNC.Units.Length * 2 && _UNC.Ups == _UNC.Units.Length
				&& _UNC_Same(_UNC.Observed, Expected) {
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

_UNC_OpenCapture() {
	global _UNC
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
}

; Construction/decoding now come from the canonical production helper.
; The independent set census and expected scalar vectors remain test-owned.
; Independently census the complete literal set outside the construction timing.
_UNC_PrototypeCheckEndKeys(Text) {
	Seen := Buffer(0x10000, 0)
	Cursor := 0, Count := 0, Units := StrLen(Text)
	while Cursor < Units {
		Unit := NumGet(StrPtr(Text), Cursor * 2, "UShort")
		if Unit == 0x7B {
			_UNC_Require(Cursor + 2 < Units, "The candidate cannot end in an incomplete brace escape.")
			Unit := NumGet(StrPtr(Text), (Cursor + 1) * 2, "UShort")
			_UNC_Require((Unit == 0x7B || Unit == 0x7D)
				&& NumGet(StrPtr(Text), (Cursor + 2) * 2, "UShort") == 0x7D,
				"Only the two genuine literal brace escapes belong to the candidate set.")
			Cursor += 3
		} else {
			_UNC_Require(Unit != 0x7D, "A closing brace cannot enter the native parser unescaped.")
			Cursor += 1
		}
		_UNC_Require(Unit > 0 && !(Unit >= 0xD800 && Unit <= 0xDBFF)
			&& NumGet(Seen, Unit, "UChar") == 0, "The candidate literal membership must exclude highs and duplicates.")
		NumPut("UChar", 1, Seen, Unit)
		Count += 1
	}
	_UNC_Require(Count == 0xFFFF - 0x400, "The complete nonzero ordinary and low-unit membership must be present.")
	loop 0xFFFF
		_UNC_Require(NumGet(Seen, A_Index, "UChar") == (A_Index >= 0xD800 && A_Index <= 0xDBFF ? 0 : 1),
			"The candidate literal set must cover every permitted unit, not only the sample vectors.")
}

_UNC_Qpc() {
	Value := 0
	_UNC_Require(DllCall("QueryPerformanceCounter", "Int64*", &Value, "Int") != 0,
		"Native performance counter read was refused.")
	return Value
}

_UNC_Csv(Values) {
	Text := ""
	for Value in Values
		Text .= (Text == "" ? "" : ",") . String(Value)
	return Text
}

_UNC_PrototypeMeasure() {
	global _UNC
	Frequency := 0
	_UNC_Require(DllCall("QueryPerformanceFrequency", "Int64*", &Frequency, "Int") != 0 && Frequency > 0,
		"The native performance frequency must be received.")
	Start := _UNC_Qpc()
	EndKeys := _SIHO_ScalarEndKeys()
	BuildTicks := _UNC_Qpc() - Start
	Start := _UNC_Qpc()
	_UNC_PrototypeCheckEndKeys(EndKeys)
	ValidationTicks := _UNC_Qpc() - Start
	ClockTicks := [], CacheTicks := [], ReferenceTicks := [], CandidateTicks := []
	Samples := 8
	loop Samples {
		Start := _UNC_Qpc()
		ClockTicks.Push(_UNC_Qpc() - Start)
		Start := _UNC_Qpc()
		Cached := _SIHO_ScalarEndKeys()
		CacheTicks.Push(_UNC_Qpc() - Start)
		_UNC_Require(Cached == EndKeys, "A cache hit must return the same complete immutable table.")
		; This small reference is not claimed as an entire production owner.
		; Both measurements include native destruction and the named Enter key.
		Start := _UNC_Qpc()
		Probe := InputHook("L1 T2", "{Enter}")
		Probe := 0
		ReferenceTicks.Push(_UNC_Qpc() - Start)
		Start := _UNC_Qpc()
		Probe := InputHook("L2 E C T2", EndKeys . "{Enter}")
		Probe := 0
		CandidateTicks.Push(_UNC_Qpc() - Start)
	}
	_UNC_Require(CacheTicks.Length == Samples
		&& ReferenceTicks.Length == Samples && CandidateTicks.Length == Samples,
		"Native per-hook allocation must not be disguised as a shared cached hook.")
	FileAppend("MEASURE case=" . _UNC.Case . " runtime=" . A_AhkVersion . " qpf=" . Frequency . " samples=" . Samples
		. " build_ticks=" . BuildTicks . " validation_ticks=" . ValidationTicks . " first_call_in_fresh_child=true cache_calls=" . Samples
		. " literal_units=" . StrLen(EndKeys) . " literal_bytes=" . ((StrLen(EndKeys) + 1) * 2)
		. " native_endchars_capacity_bytes=" . ((0xFFFF - 0x400 + 1) * 2)
		. " source_derived_capacity=true constructor_endkeys_units=" . StrLen(EndKeys . "{Enter}") . " constructor_named_key=Enter"
		. " clock_ticks=" . _UNC_Csv(ClockTicks) . " cache_ticks=" . _UNC_Csv(CacheTicks)
		. " reference_ctor_ticks=" . _UNC_Csv(ReferenceTicks) . " candidate_ctor_ticks=" . _UNC_Csv(CandidateTicks)
		. " constructor_order=reference_then_candidate includes_destruction=true hook_pooling=false`n", "*")
	return Frequency
}

_UNC_RunPrototype() {
	global _UNC
	Mode := SubStr(_UNC.Case, 11)
	ExpectedTail := [], ExpectedKind := "text", ExpectedName := ""
	switch Mode {
		case "a":
			_UNC.Units := [0x61], ExpectedScalar := [0x61]
		case "AB":
			_UNC.Units := [0x41, 0x42], ExpectedScalar := [0x41], ExpectedTail := [0x42]
		case "surrogate":
			_UNC.Units := [0xD83D, 0xDE00], ExpectedScalar := [0xD83D, 0xDE00]
		case "open-brace":
			_UNC.Units := [0x7B], ExpectedScalar := [0x7B]
		case "close-brace":
			_UNC.Units := [0x7D], ExpectedScalar := [0x7D]
		case "punctuation":
			_UNC.Units := [0x2E], ExpectedScalar := [0x2E]
		case "enter":
			; Genuine VK_RETURN is transcribed as LF by the pinned hook before
			; its named EndKey preempts CollectChar. It is not a Unicode packet.
			_UNC.Units := [0x0A], _UNC.UpVk := 0x0D
			ExpectedScalar := [], ExpectedKind := "control", ExpectedName := "Enter"
		default:
			throw Error("Unknown native EndChars prototype vector.")
	}
	Frequency := _UNC_PrototypeMeasure()
	_UNC_OpenCapture()
	Hook := InputHook("L2 E C T2", _SIHO_ScalarEndKeys() . "{Enter}")
	_UNC_Require(Hook.CaseSensitive && Hook.MinSendLevel == 0,
		"The real candidate hook must apply C and retain the default input admission.")
	Token := SIHO_StartOwned(Hook, "scalar-prototype", true)
	_UNC_Require(Token > 0, "The candidate requires its exact native registry owner.")
	_UNC.ArmedAt := DllCall("GetTickCount64", "UInt64")
	SetTimer(_UNC_Inject, -1)
	try {
		Hook.Wait()
	} finally {
		SetTimer(_UNC_Inject, 0)
		Settled := SIHO_StopOwned(Token, Hook)
	}
	_UNC_Require(_UNC.Injected && _UNC.Calls == 1, "The candidate must receive one exact native packet batch.")
	_UNC_Drain()
	CompletedAt := _UNC_Qpc()
	if IsObject(_UNC.Error)
		throw _UNC.Error
	_UNC_Admit()
	_UNC_Require(Settled && SIHO_Count() == 0 && !_SIHO_Owners.Has(Token) && !Hook.InProgress,
		"The candidate must retire the exact completed owner before decoding.")
	Result := _SIHO_ReadScalar(Hook, "{Enter}")
	Scalar := _UNC_Units(Result.Text)
	FileAppend("RECEIPT source_scope=parent_execution_manifest runtime=" . A_AhkVersion . " pid=" . _UNC.Pid . " case=" . _UNC.Case
		. " packet_kind=" . (_UNC.UpVk == 0xE7 ? "unicode" : "virtual_key") . " vk=" . Format("{:04X}", _UNC.UpVk)
		. " expected_chars=" . _UNC_Hex(_UNC.Units) . " observed=" . _UNC_Hex(_UNC.Observed)
		. " input_buffer=" . _UNC_Hex(_UNC_Units(Hook.Input)) . " end_key=" . _UNC_Hex(_UNC_Units(Hook.EndKey))
		. " end_reason=" . Hook.EndReason . " scalar=" . _UNC_Hex(Scalar) . " kind=" . Result.Kind . " tail=" . _UNC_Hex(_UNC.Tail)
		. " ups=" . _UNC.Ups . " native_calls=" . _UNC.Calls . " inserted=" . _UNC.Inserted
		. " qpf=" . Frequency . " injection_to_drain_ticks=" . (CompletedAt - _UNC.PrototypeInjectedAt)
		. " includes_callback_queue_and_drain_poll=true scope=native_endchars_prototype production_owner=false application_receiving=false`n", "*")
	_UNC_Require(_UNC_Same(Scalar, ExpectedScalar) && Result.Kind == ExpectedKind && Result.Name == ExpectedName,
		"The candidate must decode the independent scalar or named-control golden.")
	_UNC_Require(_UNC_Same(_UNC.Tail, ExpectedTail), "The candidate must leave only the second independent letter to the safety guard.")
	_UNC_Require(_UNC.Emits.Length == 0 && _UNC.Logs == 0 && _UNC.Activations == 0 && _UNC.Edit.Value == "",
		"The prototype must not qualify a production emitter or let native text escape into an application.")
}

_UNC_Run() {
	global _UNC, ScriptInformation
	OneShot := InStr(_UNC.Case, "one-shot-") == 1
	Kind := SubStr(_UNC.Case, 10)
	ExpectedTail := [], ExpectedControls := [], ExpectedActivations := 0
	switch Kind {
		case "a":
			_UNC.Units := [0x61], ExpectedTarget := [0x61]
		case "AB":
			_UNC.Units := [0x41, 0x42], ExpectedTarget := [0x41], ExpectedTail := [0x42]
		case "surrogate", "disabled-surrogate", "magic-astral", "disabled-magic-astral":
			_UNC.Units := [0xD83D, 0xDE00], ExpectedTarget := [0xD83D, 0xDE00]
		case "pair-B":
			_UNC.Units := [0xD83D, 0xDE00, 0x42], ExpectedTarget := [0xD83D, 0xDE00], ExpectedTail := [0x42]
		case "punctuation":
			_UNC.Units := [0x2E], ExpectedTarget := [0x2E]
		case "open-brace":
			_UNC.Units := [0x7B], ExpectedTarget := [0x7B]
		case "close-brace":
			_UNC.Units := [0x7D], ExpectedTarget := [0x7D]
		case "enter":
			_UNC.Units := [0x0A], _UNC.UpVk := 0x0D, ExpectedTarget := []
		case "backspace", "delete":
			; Backspace removes its translated backspace before OnChar;
			; Delete produces no text. Exact native Up still drains each batch.
			_UNC.Units := [0], _UNC.ExpectedObserved := [], ExpectedTarget := []
			_UNC.UpVk := Kind == "backspace" ? 0x08 : 0x2E
		default:
			throw Error("Unknown actual-owner scalar capture vector.")
	}
	NamedControl := Kind == "enter" ? "Enter" : (Kind == "backspace" ? "Backspace" : (Kind == "delete" ? "Delete" : ""))
	if InStr(Kind, "magic-astral")
		ScriptInformation["MagicKey"] := Chr(0x1F600)
	if OneShot {
		if NamedControl != "" {
			if Kind == "enter"
				ExpectedEmits := [[0x7B, 0x45, 0x6E, 0x74, 0x65, 0x72, 0x7D]]
			else if Kind == "backspace"
				ExpectedEmits := [[0x7B, 0x42, 0x61, 0x63, 0x6B, 0x73, 0x70, 0x61, 0x63, 0x65, 0x7D]]
			else
				ExpectedEmits := [[0x7B, 0x44, 0x65, 0x6C, 0x65, 0x74, 0x65, 0x7D]]
		}
		else if Kind == "punctuation"
			ExpectedEmits := [[0x20, 0x3A]], ExpectedActivations := 1
		else if Kind == "magic-astral"
			ExpectedEmits := [[0x4A]], ExpectedActivations := 1
		else if Kind == "a"
			ExpectedEmits := [[0x41]]
		else
			ExpectedEmits := [ExpectedTarget]
	} else {
		ExpectedEmits := Kind == "a" ? [[0xE4]] : [[0xA8], ExpectedTarget]
		if NamedControl != ""
			ExpectedControls := ["{" . NamedControl . "}"]
	}
	_UNC_Require(_TapHoldOneShotTable()["results"].Count > 0 && _UNC.Logs == 0,
		"The canonical shared JSON must load without fallback before capture.")
	_UNC_OpenCapture()
	_UNC.ArmedAt := DllCall("GetTickCount64", "UInt64")
	SetTimer(_UNC_Inject, -1)
	CaptureError := 0
	try {
		if OneShot
			OneShotShift()
		else
			DeadKey(Map("a", Chr(0x00E4), " ", Chr(0x00A8)))
	} catch as Err {
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
	; This oracle observes raw native fields independently of the production
	; reader. The separately declared goldens and actual emissions qualify it.
	InputUnits := _UNC_Units(_UNC.Target.Input), EndUnits := _UNC_Units(_UNC.Target.EndKey)
	TargetUnits := _UNC_Units(_UNC.Target.Input . (NamedControl != "" ? "" : _UNC.Target.EndKey))
	FileAppend("RECEIPT source_scope=parent_execution_manifest runtime=" . A_AhkVersion . " pid=" . _UNC.Pid . " case=" . _UNC.Case
		. " input=" . _UNC_Hex(_UNC.Units) . " observed=" . _UNC_Hex(_UNC.Observed)
		. " input_buffer=" . _UNC_Hex(InputUnits) . " end_key=" . _UNC_Hex(EndUnits)
		. " target=" . _UNC_Hex(TargetUnits) . " end_reason=" . _UNC.Target.EndReason . " tail=" . _UNC_Hex(_UNC.Tail)
		. " ups=" . _UNC.Ups . " native_calls=" . _UNC.Calls . " inserted=" . _UNC.Inserted
		. " scope=native_capture_and_observed_emission application_receiving=false`n", "*")
	for Index, Units in _UNC.Emits
		FileAppend("EMIT " . Index . " utf16=" . _UNC_Hex(Units) . "`n", "*")
	if IsObject(CaptureError)
		throw CaptureError
	_UNC_Require(_UNC.Target.EndReason == "EndKey" && !_UNC.Target.InProgress
		&& SIHO_Count() == 0 && !_SIHO_Owners.Has(_UNC.Token),
		"The real product owner must settle capture and retire its exact native token without timeout.")
	if NamedControl != ""
		_UNC_Require(_UNC.Target.EndKey == NamedControl && InputUnits.Length == 0, "A named control must stay outside literal scalar text.")
	_UNC_Require(_UNC_Same(TargetUnits, ExpectedTarget), "The native capture lost or over-consumed a UTF-16 unit.")
	_UNC_Require(_UNC_Same(_UNC.Tail, ExpectedTail), "Only the next independent BMP character may escape to the safety guard.")
	_UNC_Require(_UNC.Emits.Length == ExpectedEmits.Length, "The genuine owner emitted the wrong number of observed results.")
	for Index, Units in ExpectedEmits
		_UNC_Require(_UNC_Same(_UNC.Emits[Index], Units), "The genuine owner emitted an incomplete or incorrect Unicode result.")
	_UNC_Require(_UNC.Controls.Length == ExpectedControls.Length, "Only a genuine named control may invoke the key-send port.")
	for Index, Keys in ExpectedControls
		_UNC_Require(_UNC.Controls[Index] == Keys, "A named control must be replayed exactly once.")
	_UNC_Require(_UNC.Logs == 0 && _UNC.Activations == ExpectedActivations && _UNC.Edit.Value == "",
		"No hidden error or application text may qualify this capture, and only genuine special results activate hotstrings.")
}

FileAppend("BEGIN source_scope=parent_execution_manifest runtime=" . A_AhkVersion . " pid=" . _UNC.Pid . " case=" . _UNC.Case . "`n", "*")
try {
	Prototype := InStr(_UNC.Case, "prototype-") == 1
	if Prototype
		_UNC_RunPrototype()
	else
		_UNC_Run()
	FileAppend("PASS " . (Prototype ? "native-inputhook-endchars-prototype" : "native-inputhook-unicode-capture") . "`n", "*")
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
