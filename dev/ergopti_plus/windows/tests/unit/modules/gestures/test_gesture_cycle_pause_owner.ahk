; tests/unit/modules/gestures/test_gesture_cycle_pause_owner.ahk

; ==============================================================================
; MODULE: Native Gesture Window-Cycle Pause Ownership Tests
; DESCRIPTION:
; Reuses the existing genuine gesture child composer, preserving its old cases.
; Only native enumeration is restricted to two exact private GUI candidates;
; dispatch, logger, Suspend timer and foreground activation remain production.
; ==============================================================================

#Requires AutoHotkey v2.0

_GCFO_Source(Owners) {
	global _DriverDir
	Code := _GPO_Source(Owners)
	OldBody := FSReadStrict(_DriverDir . "\tests\fixtures\gesture_pause_admission_body.ahk")
	Start := StrLen(Code) - StrLen(OldBody) + 1
	AssertTrue(Start > 0 && SubStr(Code, Start) == OldBody, "the complete original fixture suffix must be exact")
	Code := SubStr(Code, 1, Start - 1)
	; Restore the original native mouse transport sites; this route requires no
	; held mouse button and must not inherit a modeled mouse-success boundary.
	Code := RegExReplace(Code, "(?<![\w])_GPO_Click\(", "Click(", &MouseSites)
	Code := StrReplace(Code, "_GPO_Stop(Hook)", "Hook.Stop()", true, &StopSites)
	AssertEqual(6, MouseSites)
	AssertEqual(1, StopSites)
	for Symbol in ["FSReadBytesStrict", "WMForceForeground"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the genuine additional native owner must resolve")
		Code .= "#Include " . Owner . "`n"
		Owners[Symbol] := CryptoSha256Bytes(FSReadBytesStrict(Owner))
	}
	CycleOwner := _DriverProductionFileForSymbol("GestureCycleWindows")
	Cycle := FSReadStrict(CycleOwner)
	CodeOnly := _DriverMaskNonCode(&Cycle)
	StrReplace(CodeOnly, "Ids := WMGetList()", "", true, &NativeListSites)
	AssertEqual(1, NativeListSites, "only the actual native enumeration call may be sandboxed")
	Cycle := StrReplace(Cycle, "Ids := WMGetList()", "Ids := _GCFC_OwnedWindowList()", true, &Bindings)
	AssertEqual(1, Bindings)
	RegistryOwner := _DriverProductionFileForSymbol("GestureTranslateContext")
	Registry := FSReadStrict(RegistryOwner)
	for Name in ["_GestureWinOrder", "_GestureCycling", "_GestureWinHook", "_GestureSelfActivated",
			"GESTURE_SELF_ACTIVATE_TTL_MS", "GESTURE_WIN_ORDER_MAX"] {
		Found := RegExMatch(Registry, "m)^global " . Name . "[ \t]*:=[^`r`n]+", &Declaration)
		AssertTrue(Found != 0, "the cold tracker must use its genuine global initializer: " . Name)
		Code .= Declaration[0] . "`n"
	}
	Owners["cycle_owner_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(CycleOwner))
	Owners["cycle_enumeration_bindings"] := Bindings
	Fixture := _DriverDir . "\tests\fixtures\gesture_cycle_pause_owner_body.ahk"
	Owners["fixture_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(Fixture))
	return Code . Cycle . "`n#Include " . Fixture . "`n"
}

_GCFO_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_GCFO_Case(Family, Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "an unretired native child forbids another focus case")
	Root := A_Temp . "\ergopti_gesture_cycle_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Owners := Map(), Handle := 0, Primary := 0, ExportFailure := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _GCFO_Source(Owners)))
		Hash := CryptoSha256Bytes(FSReadBytesStrict(Script)), RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
		_TestPrint("# gesture-cycle-source " . KL_JsonEncode(Map("family", Family, "mode", Mode,
			"source_sha256", Hash, "runtime_sha256", RuntimeHash, "owners", Owners,
			"enumeration", "real-os-list-filtered-to-private-hwnds", "activation", "real-native")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Family, Mode, Root, Hash, RuntimeHash], _GCFO_Done.Bind(State))
		AssertTrue(Handle.start(), "the exact native focus child must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		State.AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if !State.Calls
			Primary := Error("The native gesture cycle child must settle within 15000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		if !Retired
			Debt := {Handle: Handle, Root: Root}
		Critical(PreviousCritical)
	}
	try {
		_TestPrint("# gesture-cycle-terminal family=" . Family . " mode=" . Mode . " calls=" . State.Calls
			. " code=" . State.Code . " retired=" . Retired . " capture_delivered=" . (State.Calls == 1))
		if Retired && State.Calls == 1 {
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# gesture-cycle combined_native_capture " . Line)
		} else
			_TestPrint("# gesture-cycle combined_native_capture UNKNOWN")
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the exact native child and all private GUIs must physically retire")
	AssertEqual(1, State.AtDeadline.Calls)
	AssertEqual("", State.AtDeadline.ErrorText)
	AssertEqual(0, State.AtDeadline.Code, "the genuine gesture cycle route failed: " . State.AtDeadline.Output)
	AssertContains(State.AtDeadline.Output, "PASS gesture-cycle-pause " . Family . " " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	DirDelete(Root, true)
}

for _GCFO_Family in ["windows", "apps"]
	for _GCFO_Mode in ["current", "during-logger", "paused-entry"]
		Test("Native gesture cycle: " . _GCFO_Family . " " . _GCFO_Mode . " (gesture-cycle-pause-owner)",
			_GCFO_Case.Bind(_GCFO_Family, _GCFO_Mode))
