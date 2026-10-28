; tests/meta/suite/test_live_drive_failure_delivery.ahk

; ==============================================================================
; MODULE: Live Drive Failure Delivery
; DESCRIPTION: Compose the genuine live harness's window timer and public await
; into an isolated child. The fixtures must observe callback failures, including
; empty diagnoses, without leaving a live timer or granting a successful check.
; ==============================================================================

#Requires AutoHotkey v2.0

_LDF_ChildSource() {
	global _DriverDir
	Source := _DriverDirConcat("tests/live")
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
	for Name in ["LiveWaitFor", "LiveDriveWindow", "_LiveDriveTick", "LiveAwaitDrive"] {
		Definition := _DriverFindFunctionDefinition(&Source, Name)
		AssertTrue(IsObject(Definition), "The live fixture requires the genuine function: " . Name)
		AssertFalse(IsObject(_DriverFindFunctionDefinition(&Source, Name, Definition.OpenPos + 1)),
			"The live fixture requires one unambiguous native owner: " . Name)
		Code .= _DriverExtractDefinedBody(&Source, Definition) . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\live_drive_failure_body.ahk", "UTF-8")
}

_LDF_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A preceding live harness child must retire first.")
	Directory := A_Temp . "\ergopti-live-drive-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot acquire the owned live drive fixture directory")
	Child := Directory . "\probe.ahk"
	Observation := {Calls: 0, Code: -1, Output: "", Errors: ""}
	Handle := 0
	CanRetire := true
	Completed(Code, Output, Errors) {
		Observation.Calls += 1
		Observation.Code := Code
		Observation.Output := Output
		Observation.Errors := Errors
	}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(!!FSWriteCreateDurable(Child, Chr(0xFEFF) . _LDF_ChildSource()), "The private native fixture must publish completely.")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Child, Mode], Completed)
		AssertTrue(Handle.start(), "The genuine live timer child must start.")
		Started := A_TickCount
		while !Observation.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observation.Calls, "The exact child must publish one completion.")
		AssertEqual("", Observation.Errors, "Native transport and parse errors cannot qualify: " . Observation.Output)
		AssertEqual(0, Observation.Code, "The actual live window timer must satisfy its oracle: " . Observation.Output)
		AssertContains(Observation.Output, "PASS live-drive-failure " . Mode)
		AssertFalse(!!InStr(Observation.Output, "Warning:"), "The complete child must remain warning-free.")
	} finally {
		try {
			if IsObject(Handle) {
				CanRetire := Handle.terminate()
				if !CanRetire
					RetirementDebt := Handle
				AssertTrue(CanRetire, "The exact child must retire before its source is removed.")
			}
			if CanRetire {
				if FileExist(Child)
					FileDelete(Child)
				DirDelete(Directory)
			}
		} finally Critical(PreviousCritical)
	}
}

for _LDF_Mode in ["healthy", "empty-error", "message-error", "matcher-error", "optional", "required"]
	Test("live drive failure: " . _LDF_Mode . " preserves the real timer outcome (live-drive-failure)", _LDF_Case.Bind(_LDF_Mode))
