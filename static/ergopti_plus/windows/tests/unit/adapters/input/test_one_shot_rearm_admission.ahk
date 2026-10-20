; tests/unit/adapters/input/test_one_shot_rearm_admission.ahk

_OSRA_RouteSource(Symbol, KeyId, HotkeyName, FunctionName) {
	Owner := _DriverProductionFileForSymbol(Symbol)
	AssertTrue(Owner != "", "the physical route must have a unique production owner")
	Source := FileRead(Owner, "UTF-8")
	Marker := '#HotIf TapHoldTapAction(TapHold, "' . KeyId . '") == "one_shot_shift"'
	Start := InStr(Source, Marker, true)
	AssertTrue(Start > 0 && !InStr(Source, Marker, true, Start + 1), "the one-shot physical route must be unique")
	Finish := InStr(Source, "`n#HotIf", true, Start + 1)
	AssertTrue(Finish > Start, "the real route must end at its own HotIf boundary")
	Block := SubStr(Source, Start, Finish - Start)
	Newline := InStr(Block, "`n")
	Criterion := SubStr(Block, 8, Newline - 8)
	Declaration := HotkeyName . ":: {"
	Body := Trim(SubStr(Block, Newline + 1), " `t`r`n")
	AssertTrue(InStr(Body, Declaration, true) == 1, "the actual physical hotkey identity must be retained")
	Body := RegExReplace(SubStr(Body, StrLen(Declaration) + 1), "m)^\s*;[^\n]*$", "")
	Body := Trim(Body, " `t`r`n")
	AssertEqual("}", SubStr(Body, -1), "the complete genuine hotkey body must be extracted")
	return FunctionName . "Criterion() {`nreturn " . Criterion . "`n}`n" . FunctionName . "() {`n" . Body . "`n"
}

_OSRA_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	for Symbol in ["SIHO_StartOwned", "JsonParse"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the real admission dependency must have one owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["OneShotShift", "OneShotShiftFix", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys",
		"TapHoldDispatchTap", "TapHoldTapInDispatch", "TapHoldShouldCancelTap", "_TH_TakePressTakenByCombination",
		"TapHoldForgetTrackedKey", "TapHoldTapIsCommand", "_TapHoldTapEndsCapsWord", "TapHoldDuration",
		"TapHoldIsEnabled", "TapHoldEntryHasKnownAction", "TapHoldTapAction", "TapHoldHoldModifier", "TapHoldHoldLayer"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the genuine route dependency must exist: " . Name)
		if Name == "OneShotShift" {
			FactoryAt := InStr(Definition, "InputHook(", true)
			AssertTrue(FactoryAt > 0 && !InStr(Definition, "InputHook(", true, FactoryAt + 1), "bind exactly one native constructor")
			Definition := StrReplace(Definition, "InputHook(", "_OSRA_CreateHook(", true, &Bindings)
			AssertEqual(1, Bindings, "only the class construction boundary may be bound")
			AssertTrue(InStr(Definition, "_OSRA_CreateHook(") > 0, "the passive factory must reach the actual owner")
		}
		Code .= Definition . "`n"
	}
	Code .= _OSRA_RouteSource("_LAltIsSpecialTap", "left_alt", "SC038", "_OSRA_FirstRoute")
	Code .= _OSRA_RouteSource("_RCtrlIsSpecialTap", "right_ctrl", "*SC11D", "_OSRA_SecondRoute")
	return Code . FileRead(_DriverDir . "\tests\fixtures\one_shot_rearm_admission_body.ahk", "UTF-8")
}

_OSRA_Case(Mode) {
	global _SharedDir
	Script := A_Temp . "\ergopti_one_shot_rearm_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "the rearm child requires a fresh owned path")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _OSRA_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, _SharedDir], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "the genuine one-shot admission child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact child must settle once")
		AssertEqual(0, State.Code, "the admission child refused: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native diagnostics must remain visible")
		AssertEqual("PASS one-shot-rearm-admission", State.Output)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Result := Handle.terminate()
				Retired := (Result is Integer) && Result == 1
				if Retired || TickElapsed(Started) >= 5000
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
	AssertTrue(Retired, "the exact child must retire before its source is removed")
}

for _OSRA_Mode in ["natural", "incumbent-letter", "incumbent-special", "incumbent-disabled", "paused-during-start", "revoked-during-start", "successor-disabled-during-start"]
	Test("one-shot rearm: " . _OSRA_Mode . " preserves current admission (one-shot-rearm-admission)", _OSRA_Case.Bind(_OSRA_Mode))
