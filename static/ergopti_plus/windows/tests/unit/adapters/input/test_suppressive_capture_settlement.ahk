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

; The passive settlement corpus above cannot prove native UTF-16 capture.
; Compose its real dependencies again without binding the InputHook Class.
_SICU_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["SIHO_StartOwned", "JsonParse"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the native capture dependency requires its real owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["DeadKey", "OneShotShift", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys", "_LLM_TerminalOutputSendInputNative"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the native capture function requires its genuine body: " . Name)
		Code .= Definition . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\suppressive_capture_unicode_body.ahk", "UTF-8")
}

_SICU_Case(Owner, Mode) {
	global _SharedDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("A previous native capture child remains unretired. Further native input is refused.")
	CaseName := Owner . "-" . Mode
	Script := A_Temp . "\ergopti_native_unicode_capture_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "the native capture child requires a fresh owned source")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SICU_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		; Explicit opt-in belongs to this tree-owned child on the isolated VM.
		; It is not inferred from an InputHook mock or a successful Send call.
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-user32-sendinput", CaseName, _SharedDir],
			_SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "the exact native capture child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 30000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the native child must settle once: " . State.ErrorText . State.Output)
		AssertEqual(0, State.Code, "native capture refused or failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native parse/runtime errors must not be hidden: " . State.Output)
		AssertTrue(RegExMatch(State.Output, "m)^RECEIPT source_scope=parent_execution_manifest .*case=" . CaseName . " ") > 0,
			"the exact native case requires its UTF-16 capture receipt: " . State.Output)
		AssertTrue(RegExMatch(State.Output, "m)^PASS native-inputhook-unicode-capture\r?$") > 0,
			"the complete scalar and independent-letter goldens must pass: " . State.Output)
		AssertTrue(RegExMatch(State.Output, "m)^NATURAL_EXIT code=0 native_input_debt=false\r?$") > 0,
			"the inserted native batch must drain before natural exit: " . State.Output)
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
	; Preserve the handle and source before any primary error escapes. The
	; next case must not inject while this parent's exact child can still run.
	if !Retired
		RetirementDebt := { handle: Handle, script: Script }
	try {
		if Retired && !IsObject(Primary)
			FileDelete(Script)
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the native child must retire before its source is removed")
}

for _SICU_Owner in ["one-shot", "dead-key"]
	for _SICU_Mode in ["a", "AB", "surrogate"]
		Test("Unicode scalar capture: " . _SICU_Owner . " " . _SICU_Mode . " (inputhook-unicode-capture)",
			_SICU_Case.Bind(_SICU_Owner, _SICU_Mode))
