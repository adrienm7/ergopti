; tests/unit/modules/keystats/test_buffer_snapshot_publication_owner.ahk

; ==============================================================================
; MODULE: Detached Snapshot Publication Lifecycle Tests
; DESCRIPTION:
; The real fire producer flushes public mouse counters through the genuine
; detached-snapshot and canonical append owners. Native pause/resume revokes
; the captured generation; privacy remains a terminal, independent decision.
; ==============================================================================

#Requires AutoHotkey v2.0

_KBSP_ChildSource() {
	global _DriverDir
	Source := _KFPO_ChildSource()
	Tail := "#Include " . _DriverDir . "\tests\fixtures\keylogger_fire_publication_owner_body.ahk`n"
	Source := StrReplace(Source, Tail, "", true, &Replaced)
	AssertEqual(1, Replaced, "Only the original fixture tail is replaced; real fire and append bodies stay intact")
	PrivacyOwner := _DriverProductionFileForSymbol("MF_ShouldFilter", _DriverDir)
	PrivacySource := FileRead(PrivacyOwner, "UTF-8")
	AssertFalse(RegExMatch(PrivacySource, "im)^#Include\b"),
		"Embedding relative imports requires explicit source composition")
	PrivacySource := StrReplace(PrivacySource, "MF_ShouldFilter() {", "_KBSP_NativeFilter() {", true, &Replaced)
	AssertEqual(1, Replaced, "The real classifier body must remain unchanged behind its scheduling alias")
	Source := StrReplace(Source, "#Include " . PrivacyOwner . "`n", PrivacySource . "`n", true, &Replaced)
	AssertEqual(1, Replaced, "Only the canonical privacy owner include is embedded")
	StateOwner := _DriverProductionFileForSymbol("KL_AppendLog", _DriverDir)
	StateSource := FileRead(StateOwner, "UTF-8")
	SplitPath(StateOwner, , &StateDirectory)
	AssertTrue(RegExMatch(StateSource, "m)^#Include ([^\r\n]+)", &ConstantsImport) > 0)
	ConstantsPath := StateDirectory . "\" . ConstantsImport[1]
	AssertTrue(RegExMatch(FileRead(ConstantsPath, "UTF-8"), "m)^class KeylogConst \{") > 0,
		"The real state owner's constants import must supply the genuine WPM limit")
	Source .= "#Include " . ConstantsPath . "`n"
	CategoryOwner := _DriverProductionFileForSymbol("KL_AppCat_Get", _DriverDir)
	AssertTrue(RegExMatch(FileRead(CategoryOwner, "UTF-8"), "ms)^class KLAppCat \{.*?^\}", &CategoryClass) > 0)
	Source .= CategoryClass[0] . "`n"
	for Symbol in ["_KL_PublishBufferSnapshot", "_KL_RestoreBufferSnapshot",
		"KL_AppCat_Get", "KL_AppCat_RequireInit", "_KL_AppCat_RecordLabel",
		"KL_SetSessionApp", "KL_SetSessionTitle", "KL_SetSessionLayout",
		"KL_SetSessionUrl", "KL_SetSessionFieldRole", "KL_BumpMouseClick"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every newly reached real dependency must have a body: " . Symbol)
		Source .= Body . "`n"
	}
	; The inherited real clock body keeps its original alias. Its public port
	; below is the only clock callout; neither port replaces the append verdict.
	return Source . "#Include " . _DriverDir . "\tests\fixtures\buffer_snapshot_publication_owner_body.ahk`n"
}

_KBSP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KBSP_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_snapshot_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KBSP_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KBSP_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact snapshot-publication child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# snapshot-publication-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS snapshot-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _KBSP_Mode in ["current", "paused", "resumed", "privacy-resumed"]
	Test("Keystats snapshots: " . _KBSP_Mode . " preserves detached publication (buffer-snapshot-publication-owner)",
		_KBSP_Case.Bind(_KBSP_Mode))
