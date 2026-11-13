; tests/unit/gestures/engine/test_takenote_native_document_owner.ahk
;
; ==============================================================================
; MODULE: TakeNote Native Document Identity Probes
; DESCRIPTION:
; Two real private Notes.txt documents must remain distinct through the genuine
; deferred job and the Windows Notepad window lookup. No lookup is simulated.
; ==============================================================================

#Requires AutoHotkey v2.0+

_TNDO_Source() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
	Source .= "#Include " . _DriverDir . "\vendor\UIA.ahk`n"
	for Symbol in ["TickElapsed64", "TakeNoteRequest"] {
		OwnerPath := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(OwnerPath != "", "The probe must use the actual production owner of " . Symbol)
		Source .= "#Include " . OwnerPath . "`n"
	}
	for Symbol in ["_WMResolveSpec", "WMActivate"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "The native activation graph must include " . Symbol)
		Source .= Body . "`n"
	}
	; The tab settle comes from the timing registry; the child binds that one
	; key to the registry's own value, so a tabbed Notepad reaches it too.
	Settle := TimingsGet("ui", "take_note_tab_settle_ms")
	Source .= 'TimingsGet(Section, Key) {`n`tif (Section != "ui" || Key != "take_note_tab_settle_ms")`n'
		. '`t`tthrow ValueError("Only the tab settle timing is bound: " . Section . "." . Key)`n`treturn ' . Settle . '`n}`n'
	return Source . "#Include " . _DriverDir . "\tests\fixtures\takenote_native_document_owner_body.ahk`n"
}
_TNDO_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}
_TNDO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A prior native document owner must retire before its successor")
	Directory := A_Temp . "\ergopti_takenote_documents_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, PhysicalClean := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created)
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _TNDO_Source()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _TNDO_Done.Bind(State))
		AssertTrue(Handle.start())
		Start := A_TickCount
		while !State.Calls && TickElapsed64(Start) < 45000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# takenote-document mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		PhysicalClean := InStr(State.Output, "CLEANUP takenote-document retired=1") > 0
		AssertEqual(1, State.Calls)
		; A load warning names a symbol the child lacks; only a tabbed Notepad
		; reaches some of them, so the warning itself is the host-free witness.
		AssertFalse(InStr(State.Output, "==> Warning:"), State.Output)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS takenote-document " . Mode)
		AssertTrue(PhysicalClean)
	} catch Any as Failure
		Primary := Failure
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if Created && (!Retired || !PhysicalClean)
			RetirementDebt := {Directory: Directory, Handle: Handle, Output: State.Output}
		else if Created && Retired && !IsObject(Primary)
			DirDelete(Directory, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired && PhysicalClean, "Exact child and Notepad owners must retire before private cleanup")
}
for _TNDO_Mode in ["same-folder", "different-folder"]
	Test("TakeNote native document: " . _TNDO_Mode . " selects the actual private file (takenote-native-document-owner)",
		_TNDO_Case.Bind(_TNDO_Mode))
