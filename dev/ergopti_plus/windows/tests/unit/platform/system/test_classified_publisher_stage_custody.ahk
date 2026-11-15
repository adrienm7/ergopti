; tests/unit/platform/system/test_classified_publisher_stage_custody.ahk

; ==============================================================================
; MODULE: Classified public filesystem publisher stage custody
; DESCRIPTION:
; The production classified writer and admitted writer retain independent
; stages. A refused real calibration observes the owner's actual monotone
; allocation, so the next exact stage is acquired without assuming its initial
; serial or replacing any filesystem function.
; ==============================================================================

#Requires AutoHotkey v2.0

_FPSC_Snapshot(Path) {
	File := FileOpen(Path, "r", "UTF-8-RAW")
	if !IsObject(File)
		throw Error("The independent classified-publication stage has no native identity.")
	try return FSHandleSnapshot(File.Handle)
	finally File.Close()
}

_FPSC_Case(Admitted, Collision, Relative := false) {
	static Sequence := 0
	Sequence += 1
	Root := A_Temp . "\ergopti_classified_stage_" . PLC_CurrentProcessId() . "_" . A_TickCount . "_" . Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	NativePath := Root . "\target.txt"
	Path := Relative ? "target.txt" : NativePath
	Prior := "prior independently created classified source`n"
	Candidate := "new classified publication é😀`n"
	Foreign := "independent pending classified stage é😀`n"
	Calibration := {Path: "", Calls: 0}
	Stage := ""
	PreviousDir := A_WorkingDir
	PreviousCritical := Critical("On")
	ObserveAndRefuse() {
		Calibration.Calls += 1
		Found := []
		Loop Files, NativePath . ".*.tmp", "F"
			Found.Push(A_LoopFileFullPath)
		AssertEqual(1, Found.Length, "the real refused publication must expose precisely its acquired stage")
		Calibration.Path := Found[1]
		return 0
	}
	try {
		if Relative
			SetWorkingDir(Root)
		AssertTrue(FSWriteCreateDurable(NativePath, Prior))
		Expected := FSReadWithStatus(NativePath)
		AssertEqual(FS_STATUS_OK, Expected["status"])
		Probe := FSWriteIfUnchangedAdmitted(Path, Candidate, Expected, 0, ObserveAndRefuse)
		AssertFalse(Probe["committed"], "the genuine calibration must refuse its final admission")
		AssertEqual(1, Calibration.Calls, "the real final publication boundary must have been reached")
		AssertFalse(FileExist(Calibration.Path), "the refused calibration must retire its own stage")
		AssertEqual(Prior, FSReadUtf8Exact(NativePath))
		AssertTrue(RegExMatch(Calibration.Path, "-([0-9]+)\.tmp$", &Allocated), "the actual owner must expose its monotone suffix")
		; Critical excludes another allocation in this interpreter. No external
		; process can advance this function's private StageSerial between calls.
		Stage := NativePath . "." . A_ScriptHwnd . "-" . (Integer(Allocated[1]) + 1) . ".tmp"
		if Collision {
			AssertTrue(FSWriteCreateDurable(Stage, Foreign), "CREATE_NEW must independently acquire exactly the next producer stage")
			Before := _FPSC_Snapshot(Stage)
			AssertTrue(Before["ok"])
		}
		Result := Admitted ? FSWriteIfUnchangedAdmitted(Path, Candidate, Expected, 0, () => 1)
			: FSWriteIfUnchanged(Path, Candidate, Expected)
		_TestPrint("# classified-stage admitted=" . Admitted . " collision=" . Collision . " relative=" . Relative
			. " calibration_calls=" . Calibration.Calls . " committed=" . Result["committed"]
			. " stage_present=" . !!FileExist(Stage) . " prior_target=" . (FSReadUtf8Exact(NativePath) == Prior))
		AssertEqual(!Collision, Result["committed"], "only an acquired stage may cross the actual public publication port")
		if Collision {
			AssertTrue(FileExist(Stage) != "", "the real public publisher must preserve an independent stage")
			AssertEqual(Foreign, FSReadUtf8Exact(Stage))
			After := _FPSC_Snapshot(Stage)
			AssertTrue(After["ok"])
			for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
				AssertEqual(Before[Key], After[Key], "the independent stage keeps its native " . Key)
			AssertEqual(Prior, FSReadUtf8Exact(NativePath), "a refused stage cannot change the classified source")
		} else {
			AssertEqual(Candidate, FSReadUtf8Exact(NativePath), "the same production port must publish the healthy candidate")
			AssertFalse(FileExist(Stage), "a healthy publication consumes only its own stage")
		}
	} finally {
		try {
			SetWorkingDir(PreviousDir)
			for Leaf in [NativePath, Stage, Calibration.Path]
				if Leaf != "" && !FSDelete(Leaf)
					throw Error("The private classified-publication fixture could not retire an owned leaf.")
			DirDelete(Root, false)
		} finally Critical(PreviousCritical)
	}
}

for _FPSC_Admitted in [false, true] {
	for _FPSC_Collision in [false, true]
		Test("classified public publisher: admitted=" . _FPSC_Admitted . " collision=" . _FPSC_Collision . " (classified-publisher-stage-custody)",
			_FPSC_Case.Bind(_FPSC_Admitted, _FPSC_Collision))
	Test("classified public publisher: admitted=" . _FPSC_Admitted . " retains relative basename compatibility (classified-publisher-relative)",
		_FPSC_Case.Bind(_FPSC_Admitted, false, true))
}

_FPSC_PreconditionCase(Mode) {
	static Sequence := 0
	Sequence += 1
	Root := A_Temp . "\ergopti_classified_control_" . PLC_CurrentProcessId() . "_" . A_TickCount . "_" . Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\target.txt"
	Prior := "prior classified control`n", Candidate := "candidate classified control é😀`n"
	Concurrent := "independent edit during final admission`n"
	State := {Calls: 0}
	Admit() {
		State.Calls += 1
		if Mode == "source-changed"
			AssertTrue(FSWriteDurable(Path, Concurrent), "the final native admission must genuinely change the classified source")
		return Mode == "admission-false" ? 0 : 1
	}
	try {
		Existing := Mode == "admission-false" || Mode == "source-changed"
		if Existing
			AssertTrue(FSWriteCreateDurable(Path, Prior))
		Expected := FSReadWithStatus(Path)
		AssertEqual(Existing ? FS_STATUS_OK : FS_STATUS_ABSENT, Expected["status"])
		Result := Mode == "absent-writer" ? FSWriteIfUnchanged(Path, Candidate, Expected)
			: FSWriteIfUnchangedAdmitted(Path, Candidate, Expected, 0, Admit)
		AssertEqual(!Existing, Result["committed"], "ordinary creation succeeds, final refusal or source replacement does not")
		AssertEqual(Mode == "absent-writer" ? 0 : 1, State.Calls, "the genuine final admission must run once when offered")
		ExpectedText := Mode == "source-changed" ? Concurrent : (Existing ? Prior : Candidate)
		AssertEqual(ExpectedText, FSReadUtf8Exact(Path), "the actual target must retain precisely the admitted or independent bytes")
		Remaining := 0
		Loop Files, Path . ".*.tmp", "F"
			Remaining += 1
		AssertEqual(0, Remaining, "owned native stages must settle after success and final refusal")
		_TestPrint("# classified-control mode=" . Mode . " committed=" . Result["committed"]
			. " admission_calls=" . State.Calls . " exact_target=" . (FSReadUtf8Exact(Path) == ExpectedText) . " stages=" . Remaining)
	} finally {
		if !FSDelete(Path)
			throw Error("The private classified-control fixture could not retire its owned leaf.")
		DirDelete(Root, false)
	}
}

for _FPSC_Mode in ["absent-writer", "absent-admitted", "admission-false", "source-changed"]
	Test("classified public publisher: " . _FPSC_Mode . " preserves source admission (classified-publisher-controls)",
		_FPSC_PreconditionCase.Bind(_FPSC_Mode))
