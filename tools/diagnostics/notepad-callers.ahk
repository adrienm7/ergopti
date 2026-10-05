; tools/diagnostics/notepad-callers.ahk
;
; ==============================================================================
; MODULE: Owned Notepad Native Caller Receiving Diagnostic
; DESCRIPTION:
; Manual six-case receiving proof with literal full-document and DWORD carets.
; The supervisor generates the canonical headless include graph and owns every
; app/process. Controlled scheduling is not physical InputHook trigger evidence.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

if !IsSet(_OWNED_NOTEPAD_DIAGNOSTIC_RUNNER) || !_OWNED_NOTEPAD_DIAGNOSTIC_RUNNER {
	FileAppend("Use notepad-callers.ps1 -Interactive; direct execution is refused.`n", "**")
	ExitApp(2)
}

CallerFatal(Failure, Mode) {
	FileAppend("FATAL " . Type(Failure) . ": " . Failure.Message . "`n" . Failure.Stack . "`n", "**")
	ExitApp(1)
}

ProbeCheckOwner(Handle, Pid, Window, Control) {
	global _OWNED_NOTEPAD_SEED_NAME
	if DllCall("WaitForSingleObject", "Ptr", Handle, "UInt", 0, "UInt") != 258
		throw Error("Owned process is not live.")
	WindowPid := 0, ControlPid := 0
	DllCall("GetWindowThreadProcessId", "Ptr", Window, "UInt*", &WindowPid)
	DllCall("GetWindowThreadProcessId", "Ptr", Control, "UInt*", &ControlPid)
	if WindowPid != Pid || ControlPid != Pid || !DllCall("IsChild", "Ptr", Window, "Ptr", Control)
		throw Error("Owned window/control identity changed.")
	if WinGetClass("ahk_id " . Control) != "RichEditD2DPT"
		throw Error("Unexpected owned control class.")
	if !IsSet(_OWNED_NOTEPAD_SEED_NAME) || _OWNED_NOTEPAD_SEED_NAME == ""
			|| !InStr(WinGetTitle("ahk_id " . Window), _OWNED_NOTEPAD_SEED_NAME)
		throw Error("The exclusive synthetic document is no longer selected.")
}

ProbeSend(Handle, Pid, Window, Control, Message, WParam := 0, LParam := 0) {
	ProbeCheckOwner(Handle, Pid, Window, Control)
	; Synchronous pointer messages retain their RAM until the call returns.
	; They may block: parent retains all live owners, with no sender timeout kill.
	return DllCall("SendMessageW", "Ptr", Control, "UInt", Message, "Ptr", WParam, "Ptr", LParam, "Ptr")
}

ProbeSelection(Handle, Pid, Window, Control) {
	First := Buffer(4, 0), Last := Buffer(4, 0)
	ProbeSend(Handle, Pid, Window, Control, 0xB0, First.Ptr, Last.Ptr)
	return [NumGet(First, "UInt"), NumGet(Last, "UInt")]
}

ProbeSelect(Handle, Pid, Window, Control, First, Last) {
	ProbeSend(Handle, Pid, Window, Control, 0xB1, First, Last)
	Selected := ProbeSelection(Handle, Pid, Window, Control)
	if Selected[1] != First || Selected[2] != Last
		throw Error("Requested selection was not observed.")
}

ProbeReplace(Handle, Pid, Window, Control, Text) {
	Storage := Buffer(StrPut(Text, "UTF-16") * 2, 0)
	StrPut(Text, Storage, "UTF-16")
	ProbeSend(Handle, Pid, Window, Control, 0xC2, 1, Storage.Ptr)
}

ProbeRead(Handle, Pid, Window, Control) {
	Length := ProbeSend(Handle, Pid, Window, Control, 0xE)
	if Length < 0 || Length > 4095
		throw Error("Owned synthetic document exceeded read bound.")
	Storage := Buffer(4097 * 2, 0)
	Read := ProbeSend(Handle, Pid, Window, Control, 0xD, 4097, Storage.Ptr)
	if Read != Length || ProbeSend(Handle, Pid, Window, Control, 0xE) != Length
		throw Error("Owned document changed or read was truncated.")
	Text := StrGet(Storage, Read, "UTF-16")
	if StrLen(Text) != Length
		throw Error("Owned Unicode read length mismatch.")
	return Text
}

CoordinateSnapshot(Handle, Pid, Window, Control) {
	Advertised := ProbeSend(Handle, Pid, Window, Control, 0xE)
	if Advertised < 0 || Advertised > 70000
		throw Error("Characterization document is outside its synthetic bound.")
	Capacity := 70002
	Storage := Buffer(Capacity * 2, 0)
	Copied := ProbeSend(Handle, Pid, Window, Control, 0xD, Capacity, Storage.Ptr)
	if Copied < 0 || Copied >= Capacity
		throw Error("Characterization WM_GETTEXT count is invalid.")
	After := ProbeSend(Handle, Pid, Window, Control, 0xE)
	if After != Advertised
		throw Error("Characterization length changed during read.")
	Text := StrGet(Storage, Copied, "UTF-16")
	if StrLen(Text) != Copied
		throw Error("Characterization read count does not match UTF-16.")
	return { Advertised: Advertised, Copied: Copied, Text: Text }
}

CoordinateReset(Handle, Pid, Window, Control, Seed) {
	ProbeSend(Handle, Pid, Window, Control, 0xB1, 0, -1)
	Whole := ProbeSelection(Handle, Pid, Window, Control)
	if Whole[1] != 0 || Whole[2] > 70000
		throw Error("Synthetic whole-document selection was refused.")
	ProbeReplace(Handle, Pid, Window, Control, Seed)
	ProbeSend(Handle, Pid, Window, Control, 0xB1, 0, -1)
	Whole := ProbeSelection(Handle, Pid, Window, Control)
	if Whole[1] != 0 || Whole[2] > 70000
		throw Error("Synthetic native extent was refused.")
	return Whole[2]
}

WorkerFocus(Pid, Window, Control, Handle) {
	ProbeCheckOwner(Handle, Pid, Window, Control)
	WinActivate("ahk_id " . Window)
	if !WinWaitActive("ahk_id " . Window, , 2)
		throw Error("Owned Notepad activation was refused.")
	ControlFocus(Control, "ahk_id " . Window)
	if DllCall("GetForegroundWindow", "Ptr") != Window || ControlGetFocus("ahk_id " . Window) != Control
		throw Error("Owned editor focus was not observed.")
}

CallerNativeBegin(State, Owner) {
	State.Token := Owner.Token
	State.Active := true
	Result := DllCall(State.Begin, "UInt64", Owner.Token, "UInt64", Owner.Focus["hwnd"],
		"UInt64", Owner.Focus["control"], "UInt", Owner.Focus["pid"],
		"WStr", Owner.Opts.Get("deleted_text", ""), "WStr", Owner.Text, "Int")
	if Result != 0
		State.Active := false
	return Result
}

CallerNativePoll(State, Token) {
	Phase := 0, NativeError := 0
	Status := DllCall(State.Poll, "UInt64", Token, "UInt*", &Phase, "UInt*", &NativeError, "Int")
	if Status != 0
		throw Error("Actual caller native poll refused: " . Status)
	State.Phase := Phase
	return Map("phase", Phase, "os_error", NativeError)
}

CallerNativeClose(State, Token) {
	Status := DllCall(State.Close, "UInt64", Token, "Int")
	if Status == 0 {
		State.Active := false
		State.Closed += 1
	}
	return Status
}

CallerWait(State) {
	global _TEXT_NATIVE_OWNER
	Deadline := A_TickCount
	while _TEXT_NATIVE_OWNER {
		Critical("Off")
		State.Scheduled.Call()
		if A_TickCount - Deadline > 6000 {
			FileAppend("DEBT actual caller native owner did not settle`n", "**")
			loop
				Sleep(1000)
		}
		Sleep(10)
	}
	if State.Active
		throw Error("AHK caller completed before actual native retirement.")
}

CallerConfigureHost(Target) {
	OutputHostResolverConfigure(() => Map("Hwnd", Target.Window, "Pid", Target.Pid),
		(Hwnd, Pid) => Map("Exe", "notepad.exe", "Class", "Notepad"),
		(Hwnd, Pid) => Map("Ok", true, "Title", "owned synthetic", "TimedOut", false))
}

CallerSeed(Target, Text, Caret) {
	CoordinateReset(Target.Handle, Target.Pid, Target.Window, Target.Control, Text)
	ProbeSelect(Target.Handle, Target.Pid, Target.Window, Target.Control, Caret, Caret)
	WorkerFocus(Target.Pid, Target.Window, Target.Control, Target.Handle)
}

CallerAssertDocument(Target, Text, Caret) {
	Snapshot := CoordinateSnapshot(Target.Handle, Target.Pid, Target.Window, Target.Control)
	Selection := ProbeSelection(Target.Handle, Target.Pid, Target.Window, Target.Control)
	AssertEqual(Text, Snapshot.Text, "the actual receiving document must match the literal oracle")
	AssertEqual(Caret, Selection[1], "the actual receiving caret starts at the exact DWORD")
	AssertEqual(Caret, Selection[2], "the actual receiving caret is collapsed at the exact DWORD")
}

CallerLlm(Target, State, Scenario) {
	_LAIET_Run(_Body)
	_Body(Sent, Record) {
		global _LLM_Bridge_Buffer, _TEXT_NATIVE_OWNER
		CallerSeed(Target, Scenario.Seed, StrLen(Scenario.Seed))
		CallerConfigureHost(Target)
		_LLM_Bridge_Buffer := Scenario.Seed
		_LAIET_ConfigureRewrite(Record, Scenario.Inserted, Scenario.Deleted, Scenario.Seed, Scenario.Count)
		State.Closed := 0
		State.Phase := 0
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()), "actual LLM acceptance dispatches")
		AssertTrue(IsObject(_TEXT_NATIVE_OWNER), "actual LLM dispatch publishes its native owner")
		AssertEqual(Scenario.Seed, _LLM_Bridge_Buffer, "dispatch must not publish the replacement mirror")
		AssertEqual("claimed", Record.Lifecycle.Outcome, "dispatch is not completion")
		CallerWait(State)
		AssertEqual(4, State.Phase, "the actual native receiver verifies the LLM edit")
		AssertEqual(1, State.Closed, "the actual worker retires once")
		AssertEqual(0, Sent.Length, "the actual caller must not send keyboard or clipboard paste")
		AssertEqual(Scenario.Expected, _LLM_Bridge_Buffer, "actual LLM completion commits its exact mirror")
		AssertEqual("accepted", Record.Lifecycle.Outcome, "actual LLM completion accepts the offer")
		CallerAssertDocument(Target, Scenario.Expected, Scenario.Caret)
	}
}

CallerHse(Target, State, Trigger, Replacement, EndChar, Expected) {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer, _PrefixFocusedControlToken
		global HSE_CONSUMED_DELIMITERS, _HSE_FireLogQueue
		Seed := Trigger . EndChar
		CallerSeed(Target, Seed, StrLen(Seed))
		CallerConfigureHost(Target)
		HSE_Buffer := Seed
		_PrefixBuffer := Seed
		_LLM_Bridge_Buffer := Seed
		_PrefixFocusedControlToken := Target.Control
		Spec := _AHK04_NormalSpec()
		Spec.Trigger := StrLower(Trigger)
		Spec.Length := StrLen(Trigger)
		Spec.Replacement := Replacement
		Spec.Star := EndChar == ""
		Spec.CaseSensitive := false
		Spec.CaseConform := true
		State.Closed := 0
		State.Phase := 0
		SavedConsumed := HSE_CONSUMED_DELIMITERS
		try {
			if EndChar != ""
				HSE_CONSUMED_DELIMITERS := EndChar
			Owner := HSE_DispatchMatch(Spec, EndChar)
			AssertTrue((Owner is Map) && Owner["Pending"], "actual HSE dispatch transfers a pending native owner")
			AssertEqual(Seed, HSE_Buffer, "HSE dispatch cannot publish the replacement mirror")
			CallerWait(State)
			AssertEqual(4, State.Phase, "the actual native receiver verifies the HSE edit")
			AssertEqual(1, State.Closed, "HSE retires the actual native worker once")
			AssertTrue(Owner["FinalSucceeded"], "actual HSE completion commits the fire")
			AssertEqual(Expected, HSE_Buffer, "actual HSE completion commits its exact mirror")
			AssertEqual(Expected, _LLM_Bridge_Buffer, "the canonical LLM mirror follows the HSE replacement")
			AssertEqual(SubStr(Expected, -1), GetLastSentCharacterAt(-1), "the ring follows the visible replacement")
			AssertEqual(1, _HSE_FireLogQueue.Length, "only verified HSE completion queues one fire")
			CallerAssertDocument(Target, Expected, StrLen(Expected))
		} finally HSE_CONSUMED_DELIMITERS := SavedConsumed
	}
}

CallerMain() {
	global LAIET_HWND, LAIET_CONTROL, _TextSenderNativeTestPort
	global _OWNED_NOTEPAD_SEED_NAME
	if A_Args.Length != 7 || A_Args[1] != A_ScriptDir
		throw Error("Invalid owned caller arguments.")
	if !RegExMatch(A_Args[6], "^owned-notepad-[0-9a-f]{32}\.txt$")
		throw Error("Invalid exclusive synthetic document nonce.")
	_OWNED_NOTEPAD_SEED_NAME := A_Args[6]
	Target := {Pid: Integer(A_Args[2]), Window: Integer(A_Args[4]), Control: Integer(A_Args[5])}
	Target.Handle := DllCall("OpenProcess", "UInt", 0x101000, "Int", false, "UInt", Target.Pid, "Ptr")
	if !Target.Handle
		throw OSError(A_LastError, "OpenProcess actual caller target")
	Module := 0
	State := { Active: false, Token: 0, Scheduled: 0, Closed: 0, Phase: 0 }
	try {
		Birth := Buffer(8), Death := Buffer(8), Kernel := Buffer(8), UserTime := Buffer(8)
		if !DllCall("GetProcessTimes", "Ptr", Target.Handle, "Ptr", Birth, "Ptr", Death, "Ptr", Kernel, "Ptr", UserTime)
			throw OSError(A_LastError, "GetProcessTimes actual caller target")
		if NumGet(Birth, "UInt64") != Integer(A_Args[3])
			throw Error("Owned caller process creation changed.")
		ProbeCheckOwner(Target.Handle, Target.Pid, Target.Window, Target.Control)
		if !InStr(WinGetTitle("ahk_id " . Target.Window), A_Args[6])
			throw Error("Synthetic caller document title not admitted.")
		if ProbeRead(Target.Handle, Target.Pid, Target.Window, Target.Control) != "owned-fixture-ready"
			throw Error("Initial synthetic caller document differs.")
		Module := DllCall("LoadLibraryW", "WStr", A_Args[7], "Ptr")
		if !Module
			throw OSError(A_LastError, "LoadLibrary latest worker")
		for Name in ["Begin", "Poll", "Decide", "Close"] {
			State.%Name% := DllCall("GetProcAddress", "Ptr", Module, "AStr", "ErgoptiEditor_" . Name, "Ptr")
			if !State.%Name%
				throw Error("Native worker export missing: " . Name)
		}
		_TextSenderNativeTestPort := Map("focus", _TextSenderNativeFocus,
			"begin", CallerNativeBegin.Bind(State), "poll", CallerNativePoll.Bind(State),
			"decide", (Token, Commit) => DllCall(State.Decide, "UInt64", Token, "UInt", Commit, "Int"),
			"close", CallerNativeClose.Bind(State), "schedule", (Fn) => State.Scheduled := Fn)
		LAIET_HWND := Target.Window
		LAIET_CONTROL := Target.Control
		Scenarios := [
			{ Name: "llm-insertion", Seed: "déjà ", Deleted: "", Count: 0, Inserted: "célèbre", Expected: "déjà célèbre", Caret: 12 },
			{ Name: "llm-incident-16-50", Seed: "napéoléon is the", Deleted: "napéoléon is the", Count: 16, Inserted: "Napoleon is the greatest emperor in French history", Expected: "Napoleon is the greatest emperor in French history", Caret: 50 },
			{ Name: "llm-supplementary-tail", Seed: "Avant. Je sui😀", Deleted: "i😀", Count: 2, Inserted: "is déjà allé.", Expected: "Avant. Je suis déjà allé.", Caret: 25 }
		]
		FileAppend("1..6`n", "*")
		for Index, Scenario in Scenarios {
			CallerLlm(Target, State, Scenario)
			FileAppend("ok " . Index . " - " . Scenario.Name . " actual_caller=LLM phase=4 retired=1`n", "*")
		}
		CallerHse(Target, State, "ct★", "c’était", "", "c’était")
		FileAppend("ok 4 - hse-ct-star actual_caller=HSE phase=4 retired=1`n", "*")
		CallerHse(Target, State, "CT★", "c’était", "", "C’ÉTAIT")
		FileAppend("ok 5 - hse-uppercase actual_caller=HSE phase=4 retired=1`n", "*")
		CallerHse(Target, State, "ct", "c’était", " ", "c’était")
		FileAppend("ok 6 - hse-consumed-delimiter actual_caller=HSE phase=4 retired=1`n", "*")
	} finally {
		if State.Active {
			FileAppend("DEBT actual caller still owns native worker`n", "**")
			loop
				Sleep(1000)
		}
		if Module && !DllCall("FreeLibrary", "Ptr", Module)
			throw OSError(A_LastError, "FreeLibrary actual caller")
		if !DllCall("CloseHandle", "Ptr", Target.Handle)
			throw OSError(A_LastError, "CloseHandle actual caller target")
	}
}
try {
	CallerMain()
	ExitApp(0)
} catch as CallerFailure {
	FileAppend("FAIL " . Type(CallerFailure) . ": " . CallerFailure.Message . "`n" . CallerFailure.Stack . "`n", "**")
	ExitApp(1)
}