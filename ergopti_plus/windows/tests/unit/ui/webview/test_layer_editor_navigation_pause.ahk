; tests/unit/ui/webview/test_layer_editor_navigation_pause.ahk

; ==============================================================================
; MODULE: Layer Editor Navigation Pause Tests
; DESCRIPTION:
; Real navigation and safety callbacks run under native Suspend before the real
; resume reactor. Safety alone must never authorize the private init projection.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRNT_ChildSource() {
	global _DriverDir
	Code := _LRDT_ChildSource()
	Fixture := _DriverDir . "\tests\fixtures\layer_editor_ready_delivery_body.ahk"
	Tail := "#Include " . Fixture . "`n"
	AssertEqual(Tail, SubStr(Code, StrLen(Code) - StrLen(Tail) + 1), "Only the delivered fixture tail may be replaced")
	Definitions := FSReadStrict(Fixture)
	Definitions := RegExReplace(Definitions, "m)^_LRDS_Main\(\)`n?\z", "", &Count)
	AssertEqual(1, Count, "Only the old fixture's unique EOF invocation may be removed; all helper bodies remain real")
	NextFixture := _DriverDir . "\tests\fixtures\layer_editor_navigation_pause_body.ahk"
	AssertTrue(FileExist(NextFixture), "The separate navigation-pause fixture must exist")
	return SubStr(Code, 1, StrLen(Code) - StrLen(Tail)) . Definitions . "`n#Include " . NextFixture . "`n"
}

_LRNT_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier layer editor child must retire first")
	Directory := A_Temp . "\ergopti_layer_navigation_pause_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _LRNT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, _SharedDir], _LRDT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public layer editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 20000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact layer editor child did not settle within 20000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# layer-navigation-pause terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# layer-navigation-pause combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# layer-navigation-pause completion_error " . Line)
			} else
				_TestPrint("# layer-navigation-pause combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact layer editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real layer editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS layer-navigation-pause " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _LRNT_Mode in ["paused-navigation", "late-navigation", "retired-navigation"]
	Test("Layer editor navigation pause: " . _LRNT_Mode . " retains only valid initialization (layer-editor-navigation-pause-owner)",
		_LRNT_Case.Bind(_LRNT_Mode))
