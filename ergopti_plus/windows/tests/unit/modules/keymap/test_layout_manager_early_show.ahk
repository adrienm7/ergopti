; tests/unit/modules/keymap/test_layout_manager_early_show.ahk

; ==============================================================================
; MODULE: Layout Manager Native Show Ownership Regression
; DESCRIPTION:
; Actual native Show and Close messages precede SDK creation; public reopening
; must preserve the exact successor instead of publishing a retired window.
; ==============================================================================

_LMSO_Source(Root) {
	global _DriverDir
	Source := _LMOC_Source(Root)
	Source := StrReplace(Source, "_LMOC_", "_LMSO_")
	return StrReplace(Source, "layout_manager_open_generation_body.ahk", "layout_manager_early_show_body.ahk")
}

_LMSO_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "A previous unretired child prevents another component")
	Root := A_Temp . "\ergopti_layout_open_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_LMOC_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _LMSO_Source(Root)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _LMOC_Done.Bind(State))
		AssertTrue(Handle.start(), "The exact layout opening component must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The layout opening child did not settle within 15000 ms.")
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
	try {
		if Retired {
			_TestPrint("# layout-opening terminal calls=" . State.Calls . " code=" . State.Code
				. " capture_delivered=" . (State.Calls == 1) . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# layout-opening combined_native_capture " . Line)
			} else
				_TestPrint("# layout-opening combined_native_capture UNKNOWN")
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls, "The component must settle once: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The completion diagnostic must be empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The layout opening violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS layout-early-show " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}


for _LMSO_Mode in ["current", "close", "reopen"]
	Test("Layout native Show: " . _LMSO_Mode . " preserves exact window ownership (layout-early-show)", _LMSO_Case.Bind(_LMSO_Mode))
