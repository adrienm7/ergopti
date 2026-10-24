; tests/unit/modules/gestures/test_microphone_endpoint_owner.ahk

; ==============================================================================
; MODULE: Microphone Endpoint Ownership Tests
; DESCRIPTION:
; Private native COM vtables exercise the actual SystemControl mute methods and
; public action without opening a physical microphone. A separate child owns
; every interface and callback; its real process tree must acknowledge exit.
; ==============================================================================

#Requires AutoHotkey v2.0

_MEOT_AdapterOwner() {
	global _DriverDir
	Found := "", Definitions := 0
	loop files _DriverDir . "\*.ahk", "FR" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Text := FSReadStrict(A_LoopFileFullPath), Code := _DriverMaskNonCode(&Text)
		Position := 1, Through := 1, Depth := 0
		while Position := RegExMatch(Code, "m)^[ \t]*class[ \t]+SystemControl\b", &Definition, Position) {
			Prefix := SubStr(Code, Through, Position - Through)
			StrReplace(Prefix, "{", , true, &Opens)
			StrReplace(Prefix, "}", , true, &Closes)
			Depth += Opens - Closes
			if Depth == 0 {
				Definitions += 1
				AssertEqual("", Found, "The system-control class must have one authentic whole owner.")
				Found := A_LoopFileFullPath
			}
			Through := Position, Position += Definition.Len
		}
	}
	AssertEqual(1, Definitions, "The system-control census must observe exactly one top-level class definition.")
	AssertTrue(Found != "", "The actual system-control class owner must be present.")
	return Found
}

_MEOT_Source() {
	global _DriverDir
	Adapter := _MEOT_AdapterOwner()
	Owner := _DriverProductionFileForSymbol("GestureSysMicMuteToggle", _DriverDir)
	Text := FSReadStrict(Owner)
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
		. "#Include " . Adapter . "`n"
	for Name in ["_GestureSys", "GestureSysMicMuteToggle"] {
		Definition := _DriverExtractFunctionBody(&Text, Name)
		AssertTrue(Definition != "", "The microphone child must retain its genuine public function: " . Name)
		Code := _DriverMaskNonCode(&Definition)
		AssertEqual(1, _DriverTopLevelDefinitionCount(&Code, Name), "Each public function must be present exactly once.")
		Source .= Definition . "`n"
	}
	return Chr(0xFEFF) . Source . "#Include " . _DriverDir . "\tests\fixtures\microphone_endpoint_owner_body.ahk`n"
}

_MEOT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_MEOT_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "An unretired microphone component prevents another native case.")
	Root := A_Temp . "\ergopti_microphone_endpoint_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, PreviousCritical := Critical("Off")
	try {
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _MEOT_Source()))
		_TestPrint("# microphone-endpoint source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode], _MEOT_Done.Bind(State))
		AssertTrue(Handle.start(), "The private native microphone component must really start.")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 8000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The private native COM component did not settle within 8000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
			if Retired
				DirDelete(Root, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				Debt := {Handle: Handle, Root: Root}
			Critical(PreviousCritical)
		}
	}
	ExportFailure := 0
	try {
		_TestPrint("# microphone-endpoint terminal calls=" . State.Calls . " code=" . State.Code
			. " tree_ack=" . Retired . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
		if State.Calls == 1 {
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# microphone-endpoint combined_native_capture " . Line)
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact private child tree must acknowledge retirement.")
	AssertEqual(1, AtDeadline.Calls, "One actual completion must arrive before the deadline: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The owned completion diagnostic must be empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The native endpoint toggle violated its behavioral contract: " . State.Output)
	AssertContains(AtDeadline.Output, "CLEANUP microphone-endpoint cleaned=1 callbacks=32")
	AssertContains(AtDeadline.Output, "PASS microphone-endpoint-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Microphone: current native endpoint toggles (microphone-endpoint-owner)", _MEOT_Case.Bind("current"))
Test("Microphone: switching to a muted endpoint still toggles (microphone-endpoint-owner)", _MEOT_Case.Bind("switch-to-muted"))
Test("Microphone: switching to an unmuted endpoint still toggles (microphone-endpoint-owner)", _MEOT_Case.Bind("switch-to-unmuted"))
