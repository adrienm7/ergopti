; tests/unit/adapters/input/test_suppressive_capture_settlement.ahk

_SICS_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	for Symbol in ["SIHO_StartOwned", "JsonParse"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the real capture dependency must have one owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["DeadKey", "OneShotShift", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the genuine capture function must exist: " . Name)
		if Name == "DeadKey" || Name == "OneShotShift" {
			; InputHook is a built-in Class, so only bind its constructor call.
			; Declaring a same-name function prevents the child from parsing.
			FactoryAt := InStr(Definition, "InputHook(", true)
			AssertTrue(FactoryAt > 0 && !InStr(Definition, "InputHook(", true, FactoryAt + 1),
				Name . " must expose exactly one native construction boundary")
			Definition := StrReplace(Definition, "InputHook(", "_SIC_CreateHook(", true, &Bindings)
			AssertEqual(1, Bindings, "only the native factory may be bound for " . Name)
			AssertTrue(InStr(Definition, "_SIC_CreateHook(") > 0,
				"the passive factory must be wired into the genuine capture: " . Name)
		}
		Code .= Definition . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\suppressive_capture_settlement_body.ahk", "UTF-8")
}

_SICS_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_SICS_Case(Owner, Mode) {
	global _SharedDir
	Script := A_Temp . "\ergopti_capture_settlement_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "the capture child source requires a fresh owned path")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SICS_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Owner, Mode, _SharedDir],
			_SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "the genuine capture child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact child must settle once")
		AssertEqual(0, State.Code, "the capture child refused: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "no native child failure may be hidden")
		AssertEqual("PASS suppressive-capture-settlement", State.Output)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			RetireStarted := A_TickCount
			loop {
				Result := Handle.terminate()
				Retired := (Result is Integer) && Result == 1
				if Retired || TickElapsed(RetireStarted) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if Retired && !IsObject(Primary)
			FileDelete(Script)
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the child must retire before its source is removed")
}

for _SICS_Owner in ["one-shot", "dead-key"]
	for _SICS_Mode in ["text", "end-key", "timeout", "stopped-resumed", "completed-revoked", "stop-reentrant", "stop-refusal"]
		Test("capture settlement: " . _SICS_Owner . " " . _SICS_Mode . " keeps exact admission (suppressive-capture-settlement)",
			_SICS_Case.Bind(_SICS_Owner, _SICS_Mode))
