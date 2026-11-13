; tests/unit/platform/input/test_one_shot_rearm_admission.ahk

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
	Code .= "#Include " . _DriverDir . "\_generated\config_keys.ahk`n"
	for Symbol in ["SIHO_StartOwned", "JsonParse", "TextCaseTitle"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the real admission dependency must have one owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["OneShotShift", "OneShotShiftFix", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys",
		"TapHoldNewOwner", "TapHoldOwnerCurrent", "TapHoldDispatchTap", "HotstringEndCharOfTap", "TapHoldTapInDispatch", "TapHoldShouldCancelTap", "_TH_TakePressTakenByCombination",
		"TapHoldReleaseSyntheticKeys", "TapCopyCheckStop", "_TH_MaskMenuModifierRelease", "_TH_SyntheticKeyList",
		"_TH_SyntheticReleaseStaysWithUser", "_TH_ForgetSyntheticKeyForUser", "_TH_MarkSyntheticKeyReleasePending",
		"_TH_RetrySyntheticKeyRelease", "_TH_SyntheticKeyLabel",
		"TapHoldForgetTrackedKey", "TapHoldTapIsCommand", "_TapHoldTapEndsCapsWord", "TapHoldDuration",
		"_TapHoldDurationValid", "TapHoldGlobalDuration",
		"TapHoldIsEnabled", "TapHoldEntryHasKnownAction", "TapHoldTapAction", "TapHoldConfiguredTapAction",
		"AiActionBlocked", "AiActionIsAi", "TapHoldHoldModifier", "TapHoldHoldLayer"] {
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

for _OSRA_Mode in ["natural", "incumbent-letter", "incumbent-special", "incumbent-disabled", "paused-during-start", "revoked-during-start", "successor-disabled-during-start", "activation-revoked", "activation-successor"]
	Test("one-shot rearm: " . _OSRA_Mode . " preserves current admission (one-shot-rearm-admission)", _OSRA_Case.Bind(_OSRA_Mode))

_BRPT_ChildSource(KeyId) {
	global _DriverDir, KEY_REPEAT_INITIAL_DELAY_MS, KEY_REPEAT_INTERVAL_MS
	Code := _OSRA_ChildSource()
	Fixture := FSReadStrict(_DriverDir . "\tests\fixtures\one_shot_rearm_admission_body.ahk")
	Entry := InStr(Fixture, "`ntry {`n`ttry _OSRA_Run()", true)
	AssertTrue(Entry > 0, "Only the original unrelated fixture entry may be removed")
	AssertEqual(Fixture, SubStr(Code, -StrLen(Fixture)), "The genuine ledger dependencies and inert fixture ports must remain unchanged")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Fixture)) . SubStr(Fixture, 1, Entry)
	Code := StrReplace(Code, "KS_IsDown(Name) {", "_BRP_UnusedOriginalHeldPort(Name) {", true, &Ports)
	AssertEqual(1, Ports, "Only the simulated physical held-state port may be replaced")
	Symbol := KeyId == "left_alt" ? "_LAltIsPlainBackspace" : "_RCtrlIsSpecialTap"
	Source := FSReadStrict(_DriverProductionFileForSymbol(Symbol))
	Marker := KeyId == "left_alt" ? '#HotIf _LAltIsPlainBackspace() and not LayerEnabled'
		: '#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "backspace" and TapHoldHoldModifier(TapHold, "right_ctrl") == "" and TapHoldHoldLayer(TapHold, "right_ctrl") == "" and not LayerEnabled'
	Start := InStr(Source, Marker, true)
	AssertTrue(Start > 0 && !InStr(Source, Marker, true, Start + 1), "The actual repeat owner criterion must be unique")
	Finish := InStr(Source, "`n#HotIf", true, Start + 1)
	AssertTrue(Finish > Start)
	Block := SubStr(Source, Start, Finish - Start)
	Newline := InStr(Block, "`n")
	Criterion := SubStr(Block, 8, Newline - 8)
	Masked := _DriverMaskNonCode(&Block)
	Open := InStr(Masked, "{")
	AssertTrue(Open > Newline && SubStr(Trim(Block), -1) == "}", "The complete genuine hotkey callback body must remain intact")
	Code .= "_BRP_Criterion() {`nreturn " . Criterion . "`n}`n_BRP_Producer() " . SubStr(Block, Open) . "`n"
	Code .= _DriverFuncBody("_LAltIsPlainBackspace") . "`n"
	Code .= "global KEY_REPEAT_INITIAL_DELAY_MS := " . KEY_REPEAT_INITIAL_DELAY_MS . "`n"
	Code .= "global KEY_REPEAT_INTERVAL_MS := " . KEY_REPEAT_INTERVAL_MS . "`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\backspace_repeat_epoch_body.ahk")
}
_BRPT_Case(KeyId, Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired private repeat owner prevents another probe")
	Root := A_Temp . "\ergopti_repeat_epoch_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The child scripts require an exclusively acquired private directory")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _BRPT_ChildSource(KeyId)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, _SharedDir, KeyId], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact private repeat owner must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 6000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# backspace-repeat-epoch " . KeyId . " " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS backspace-repeat-epoch " . KeyId . " " . Mode)
	} catch as Failure {
		Primary := Failure
	}
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if Created && !Retired
			RetirementDebt := {Root: Root, Handle: Handle}
		else if Created && Retired && !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
}
for _BRPT_Key in ["left_alt", "right_ctrl"]
	for _BRPT_Mode in ["current", "paused", "resume"]
		Test("plain backspace repeat lifecycle: " . _BRPT_Key . " " . _BRPT_Mode . " (backspace-repeat-native-epoch)", _BRPT_Case.Bind(_BRPT_Key, _BRPT_Mode))


_RMPT_ChildSource(KeyId := "right_ctrl") {
	global _DriverDir
	Code := _BRPT_ChildSource(KeyId)
	Fixture := FSReadStrict(_DriverDir . "\tests\fixtures\backspace_repeat_epoch_body.ahk")
	AssertEqual(Fixture, SubStr(Code, -StrLen(Fixture)), "Only the unrelated repeat fixture entry may be replaced")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Fixture))
	Code := StrReplace(Code, "TextPressKey(*) {", "_RMP_UnusedKeyboardPort(*) {", true, &Replacements)
	AssertEqual(1, Replacements, "The old refusing keyboard port must not mask the actual adapter")
	Owner := _DriverProductionFileForSymbol("HS_RunSyntheticInputTransaction")
	AssertTrue(Owner != "", "The real synthetic transaction must have an owner")
	Code .= "#Include " . Owner . "`n"
	for Name in ["TextPressKey", "_TextSenderNormalizeModifierKey", "_TextSenderModifierPrefix", "_TextSenderKeystroke",
		"_TextSenderModifierWords", "_TextSenderSustainedKey", "_TextSenderSendInput", "_TextSenderAtSendLevel",
		"_SendVerdictSucceeded", "HSE_WordResetFlagCurrent"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The actual unchanged sender dependency must exist: " . Name)
		Code .= Body . "`n"
	}
	if KeyId == "left_alt" {
		Body := _DriverFuncBody("BackSpaceLogic")
		AssertTrue(Body != "", "The actual LAlt modifier-aware producer must exist")
		Code .= Body . "`n"
	}
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\rctrl_modified_epoch_body.ahk")
}
_RMPT_Case(Mode, KeyId := "right_ctrl") {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired modified-key owner prevents another probe")
	Root := A_Temp . "\ergopti_rctrl_modified_epoch_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The native child requires an exclusively owned source directory")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _RMPT_ChildSource(KeyId)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, _SharedDir, KeyId], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact private modified-key owner must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 8000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# rctrl-modified-epoch " . KeyId . " " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS rctrl-modified-epoch " . Mode)
	} catch as Failure {
		Primary := Failure
	}
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if Created && !Retired
			RetirementDebt := {Root: Root, Handle: Handle}
		else if Created && Retired && !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact native owner must retire before source removal")
}
for _RMPT_Mode in ["current", "paused", "resume"]
	Test("RCtrl modified output lifecycle: " . _RMPT_Mode . " (rctrl-modified-native-epoch)", _RMPT_Case.Bind(_RMPT_Mode))

for _RMPT_LAltMode in ["current", "paused", "resume"]
	Test("LAlt modified output lifecycle: " . _RMPT_LAltMode . " (lalt-modified-native-epoch)", _RMPT_Case.Bind(_RMPT_LAltMode, "left_alt"))
