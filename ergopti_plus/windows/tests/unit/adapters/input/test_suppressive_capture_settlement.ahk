; tests/unit/adapters/input/test_suppressive_capture_settlement.ahk

_SICS_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	for Symbol in ["SIHO_StartOwned", "JsonParse"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the real capture dependency must have one owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["DeadKey", "OneShotShift", "OneShotShiftFix", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys"] {
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
	for Name in ["DeadKey", "OneShotShift", "OneShotShiftFix", "_TapHoldOneShotTable", "TapHoldOneShotResult", "TapHoldOneShotEndKeys", "_LLM_TerminalOutputSendInputNative",
		"MagicKeyEditor", "_MagicKeyEditorClose", "_MagicKeyEditorStopOwned"] {
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
		; Keep raw receipts on success too, including actual-owner completion.
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "MEASURE ") == 1 || InStr(Line, "RECEIPT ") == 1
				_TestPrint("# " . (Owner == "prototype" ? "endchars-prototype" : "scalar-capture") . " " . Line)
		AssertEqual(0, State.Code, "native capture refused or failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native parse/runtime errors must not be hidden: " . State.Output)
		if Owner == "prototype" {
			Series := "\d+(?:,\d+){7}"
			Measure := "m)^MEASURE case=" . CaseName . " runtime=2\.0\.26 qpf=[1-9]\d* samples=8"
				. " build_ticks=\d+ validation_ticks=\d+ first_call_in_fresh_child=true cache_calls=8 literal_units=64515 literal_bytes=129032 native_endchars_capacity_bytes=129024"
				. " source_derived_capacity=true constructor_endkeys_units=64522 constructor_named_key=Enter clock_ticks=" . Series . " cache_ticks=" . Series
				. " reference_ctor_ticks=" . Series . " candidate_ctor_ticks=" . Series
				. " constructor_order=reference_then_candidate includes_destruction=true hook_pooling=false\r?$"
			AssertTrue(RegExMatch(State.Output, Measure) > 0,
				"the native prototype must publish its complete unthresholded construction and cache measurements: " . State.Output)
		}
		AssertTrue(RegExMatch(State.Output, "m)^RECEIPT source_scope=parent_execution_manifest .*case=" . CaseName . " ") > 0,
			"the exact native case requires its UTF-16 capture receipt: " . State.Output)
		Ack := Owner == "prototype" ? "native-inputhook-endchars-prototype"
			: (Owner == "packet" ? "inputhook-control-packet-abi" : "native-inputhook-unicode-capture")
		AssertTrue(RegExMatch(State.Output, "m)^PASS " . Ack . "\r?$") > 0,
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

for _SICU_PrototypeMode in ["a", "AB", "surrogate", "open-brace", "close-brace", "punctuation", "enter"]
	Test("native EndChars prototype: " . _SICU_PrototypeMode . " keeps one scalar and reports cost (inputhook-endchars-prototype)",
		_SICU_Case.Bind("prototype", _SICU_PrototypeMode))

for _SICU_NewOwner in ["one-shot", "dead-key"]
	for _SICU_NewMode in ["punctuation", "open-brace", "close-brace", "enter", "backspace", "delete", "pair-B"]
		Test("scalar dispatch: " . _SICU_NewOwner . " " . _SICU_NewMode . " keeps text and controls distinct (inputhook-scalar-dispatch)",
			_SICU_Case.Bind(_SICU_NewOwner, _SICU_NewMode))
for _SICU_OneShotMode in ["magic-astral", "disabled-surrogate", "disabled-magic-astral"]
	Test("scalar dispatch: one-shot " . _SICU_OneShotMode . " preserves the complete scalar (inputhook-scalar-dispatch)",
		_SICU_Case.Bind("one-shot", _SICU_OneShotMode))

_SICS_RawUnits(Units*) {
	Bytes := Buffer((Units.Length + 1) * 2, 0)
	for Index, Unit in Units
		NumPut("UShort", Unit, Bytes, (Index - 1) * 2)
	return StrGet(Bytes, Units.Length, "UTF-16")
}

_SICS_DecodeCase(Name) {
	High := _SICS_RawUnits(0xD83D), Low := _SICS_RawUnits(0xDE00)
	Hook := { Input: "", EndKey: "", EndReason: "EndKey" }
	Kind := "invalid", Text := "", Control := "", Reason := "incomplete-scalar"
	NamedKeys := "{BackSpace}{Enter}{Delete}{Numlock}{Insert}"
	switch Name {
		case "BMP":
			Hook.EndKey := "a", Kind := "text", Text := "a", Reason := ""
		case "punctuation":
			Hook.EndKey := ".", Kind := "text", Text := ".", Reason := ""
		case "open-brace":
			Hook.EndKey := "{", Kind := "text", Text := "{", Reason := ""
		case "close-brace":
			Hook.EndKey := "}", Kind := "text", Text := "}", Reason := ""
		case "supplementary":
			Hook.Input := High, Hook.EndKey := Low, Kind := "text", Text := Chr(0x1F600), Reason := ""
		case "single-escape-list":
			NamedKeys := "{Escape}", Hook.EndKey := "Escape", Kind := "control", Control := "Escape", Reason := ""
		case "named-enter":
			Hook.EndKey := "Enter", Kind := "control", Control := "Enter", Reason := ""
		case "native-backspace-alias":
			Hook.EndKey := "Backspace", Kind := "control", Control := "Backspace", Reason := ""
		case "native-insert":
			Hook.EndKey := "Insert", Kind := "control", Control := "Insert", Reason := ""
		case "native-numlock-alias":
			Hook.EndKey := "NumLock", Kind := "control", Control := "NumLock", Reason := ""
		case "named-delete":
			Hook.EndKey := "Delete", Kind := "control", Control := "Delete", Reason := ""
		case "named-after-high":
			Hook.Input := High, Hook.EndKey := "BackSpace", Kind := "control", Control := "BackSpace", Reason := "incomplete-control-prefix"
		case "unknown-control":
			Hook.EndKey := "Escape", Reason := "unknown-end-key"
		case "joined-controls":
			Hook.EndKey := "Enter}{Delete", Reason := "unknown-end-key"
		case "empty-timeout":
			Hook.EndReason := "Timeout", Kind := "timeout", Reason := ""
		case "high-timeout":
			Hook.Input := High, Hook.EndReason := "Timeout", Kind := "timeout", Reason := "incomplete-timeout"
		case "low-alone":
			Hook.EndKey := Low
		case "high-alone":
			Hook.EndKey := High
		case "high-high":
			Hook.Input := High, Hook.EndKey := High
		case "high-BMP":
			Hook.Input := High, Hook.EndKey := "a"
		case "BMP-low":
			Hook.Input := "a", Hook.EndKey := Low
		case "long-prefix":
			Hook.Input := "ab", Hook.EndKey := "c"
		case "max-is-not-completion":
			Hook.Input := Chr(0x1F600), Hook.EndReason := "Max", Reason := "unexpected-end-reason"
		case "stopped-is-not-completion":
			Hook.Input := "a", Hook.EndReason := "Stopped", Reason := "unexpected-end-reason"
		case "empty-end-key":
			Hook.EndKey := ""
		default:
			throw Error("Unknown scalar decoder vector.")
	}
	Result := _SIHO_ReadScalar(Hook, NamedKeys)
	AssertEqual(Kind, Result.Kind, "completion kind must follow the independent vector")
	AssertEqual(Text, Result.Text, "only a complete scalar may enter text dispatch")
	AssertEqual(Control, Result.Name, "controls stay named and allowlisted")
	AssertEqual(Reason, Result.Reason, "partial/invalid text must remain visible without logging raw surrogate data")
}

for _SICS_DecodeName in ["BMP", "punctuation", "open-brace", "close-brace", "supplementary", "named-enter", "named-after-high",
	"native-backspace-alias", "native-insert", "native-numlock-alias", "named-delete", "unknown-control", "joined-controls", "empty-timeout", "high-timeout", "low-alone", "high-alone", "high-high", "high-BMP", "BMP-low",
	"long-prefix", "max-is-not-completion", "stopped-is-not-completion", "empty-end-key"]
	Test("scalar completion: " . _SICS_DecodeName . " validates units and named controls (inputhook-scalar-reader)",
		_SICS_DecodeCase.Bind(_SICS_DecodeName))

_SICS_PrewarmBeforeConfiguredAdmission() {
	global _DriverDir
	BootOwner := "", Entry := "", BootOwners := 0, EntryOwners := 0
	Loop Files, _DriverDir . "\*.ahk", "FR" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Source := FileRead(A_LoopFileFullPath, "UTF-8")
		Code := _DriverMaskNonCode(&Source)
		if RegExMatch(Code, "m)^TapHoldsLoadTimings\(\)\s*\n_SIHO_ScalarEndKeys\(\)\s*\nLLMApiLoadTimings\(\)") {
			BootOwner := A_LoopFileFullPath
			BootOwners += 1
		}
		if RegExMatch(Code, "m)^global TapHold := LoadTapHoldToml\(") {
			Entry := _StripFullLineComments(Source)
			EntryOwners += 1
		}
	}
	AssertEqual(1, BootOwners, "one actual shared-timings boot owner must warm the scalar cache")
	AssertEqual(1, EntryOwners, "the configured tap-hold admission must have one entry owner")
	RelativeOwner := StrReplace(SubStr(BootOwner, StrLen(_DriverDir) + 2), "\", "/")
	Boot := InStr(Entry, "#Include " . RelativeOwner, true)
	Admission := InStr(Entry, "global TapHold := LoadTapHoldToml(", true)
	AssertTrue(Boot > 0 && Admission > Boot, "the actual boot owner must run before configured static tap-hold criteria become eligible")
}
Test("scalar startup: existing boot warms the table before configured capture admission (inputhook-scalar-prewarm)",
	_SICS_PrewarmBeforeConfiguredAdmission)

for _SICS_InvalidOwner in ["one-shot", "dead-key"]
	for _SICS_InvalidMode in ["invalid-low", "invalid-high-BMP", "partial-timeout", "control-after-high"]
		Test("scalar refusal: " . _SICS_InvalidOwner . " " . _SICS_InvalidMode . " never emits partial text (inputhook-scalar-rejection)",
			_SICS_Case.Bind(_SICS_InvalidOwner, _SICS_InvalidMode))

Test("scalar control: dead-key uses native canonical Insert spelling (inputhook-scalar-rejection)",
	_SICS_Case.Bind("dead-key", "named-insert"))

for _SICU_EditorMode in ["a", "AB", "surrogate", "open-brace", "close-brace", "punctuation"]
	Test("Magic Key native scalar: " . _SICU_EditorMode . " captures through the genuine I1 editor (magic-key-native-scalar)",
		_SICU_Case.Bind("magic-editor", _SICU_EditorMode))

Test("scalar completion: single named Escape stays cancellation (inputhook-named-key-tokenization)",
	_SICS_DecodeCase.Bind("single-escape-list"))

for _SICU_PacketMode in ["delete", "enter", "backspace", "unicode"]
	Test("control packet ABI: " . _SICU_PacketMode . " preserves physical and Unicode identity (inputhook-control-packet-abi)",
		_SICU_Case.Bind("packet", _SICU_PacketMode))
