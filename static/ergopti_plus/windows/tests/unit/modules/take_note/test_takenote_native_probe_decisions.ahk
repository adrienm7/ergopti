; tests/unit/modules/take_note/test_takenote_native_probe_decisions.ahk

; ==============================================================================
; MODULE: TakeNote Native Probe Decision Tests
; DESCRIPTION:
; Drives the private Notepad probe's decisions over fake window ports shaped
; like a Windows 11 Notepad that restored earlier sessions: several tabs, each
; with its own RichEdit control, only the selected one visible. No Notepad is
; launched, read or closed here.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\fixtures\takenote_native_document_owner_lib.ahk

; Control ports over a fake window: Controls lists {Class, Visible, Text}.
_TNPD_ControlPorts(Controls) {
	return {
		Controls: (Self, Hwnd) => Controls,
		ClassOf: (Self, Control) => Control.Class,
		Visible: (Self, Control) => Control.Visible,
		Text: (Self, Control) => Control.Text
	}
}

_TNPD_ReadsTheSelectedTab() {
	; Notepad lists the restored tabs' controls before the launched one's.
	Restored := {Class: "RichEditD2DPT", Visible: false, Text: "restored earlier note"}
	TabStrip := {Class: "Button", Visible: true, Text: "Notes.txt"}
	Selected := {Class: "RichEditD2DPT", Visible: true, Text: "owned_note_A"}
	AssertEqual("owned_note_A",
		_TNDO_SelectedDocumentText(1, _TNPD_ControlPorts([Restored, TabStrip, Selected])),
		"The probe must read the selected tab's document, not the first restored tab's")
	Classic := {Class: "Edit", Visible: true, Text: "classic note"}
	AssertEqual("classic note", _TNDO_SelectedDocumentText(1, _TNPD_ControlPorts([Classic])),
		"A classic one-document Notepad keeps its single Edit control")
	AssertEqual("", _TNDO_SelectedDocumentText(1, _TNPD_ControlPorts([Restored])),
		"A window whose selected document is not built yet shows no document")
	Twice := {Class: "RichEditD2DPT", Visible: true, Text: "other"}
	AssertThrows(() => _TNDO_SelectedDocumentText(1, _TNPD_ControlPorts([Selected, Twice])),
		"Two visible document controls make the selected tab ambiguous")
}
Test("TakeNote probe: the document read is the selected tab's, not a restored tab's (takenote-probe-selected-tab)",
	_TNPD_ReadsTheSelectedTab)

_TNPD_OwnsRestoredWindows() {
	; Window 11 is a restored window of the probe's Notepad (PID 7) listed before
	; window 12, whose selected tab is the canary; window 13 is another Notepad.
	Documents := Map(11, "restored earlier note", 12, "owned_note_A", 13, "someone else's note")
	Pids := Map(11, 7, 12, 7, 13, 9)
	State := {Processes: Map(), Windows: Map(), CanaryA: "owned_note_A", CanaryB: "owned_note_B", ObserveError: ""}
	Ports := {
		List: (Self) => [11, 12, 13],
		Pid: (Self, Hwnd) => Pids[Hwnd],
		Document: (Self, Hwnd) => Documents[Hwnd],
		Hold: (Self, Pid) => State.Processes[Pid] := {Pid: Pid},
		Alive: (Self, Receipt) => true
	}
	_TNDO_ObserveWindowsWith(Ports, State)
	AssertTrue(State.Processes.Has(7) && !State.Processes.Has(9), "Only the canary's process is proved")
	AssertTrue(State.Windows.Has(11), "A restored window of the proved process is the probe's, not foreign")
	AssertEqual("A", State.Windows[12].Document)
	AssertEqual("", State.Windows[11].Document)
	AssertFalse(State.Windows.Has(13), "Another Notepad's window is never adopted")
	Foreign := _TNDO_ForeignWindows([11, 12, 13], State.Windows)
	AssertTrue(Foreign.Length == 1 && Foreign[1] == 13, "Only the unproved window counts as foreign at cleanup")
	; A window of a proved process whose document cannot be read is still owned.
	Documents[11] := 0
	Ports.Document := _TNPD_ThrowingDocument.Bind(Documents)
	State.Windows := Map()
	_TNDO_ObserveWindowsWith(Ports, State)
	AssertTrue(State.Windows.Has(11), "An unreadable document does not disown its proved window")
	AssertEqual("the document control vanished", State.ObserveError)
}
_TNPD_ThrowingDocument(Documents, Self, Hwnd) {
	if Documents[Hwnd] == 0
		throw Error("the document control vanished")
	return Documents[Hwnd]
}
Test("TakeNote probe: windows of the proved Notepad, restored ones included, are not foreign (takenote-probe-restored-session)",
	_TNPD_OwnsRestoredWindows)

_TNPD_Outcome(Body, Cleanup, &Emitted) {
	Lines := []
	try {
		_TNDO_RunThenCleanup(Body, Cleanup, (Line) => Lines.Push(Line))
		Outcome := "passed"
	} catch Any as Failure
		Outcome := "failed: " . Failure.Message
	Emitted := Lines
	return Outcome
}
_TNPD_ReportsTheFirstError() {
	Fails := (Message) => (*) => _TNPD_Throw(Message)
	AssertEqual("failed: the selected tab is not the note", _TNPD_Outcome(Fails("the selected tab is not the note"),
		() => false, &Emitted), "The body's failure must not be masked by the cleanup's")
	AssertEqual(1, Emitted.Length)
	AssertEqual("CLEANUP takenote-document retired=0", Emitted[1], "The cleanup still runs and reports")
	AssertEqual("failed: the selected tab is not the note", _TNPD_Outcome(Fails("the selected tab is not the note"),
		Fails("TerminateProcess refused"), &Emitted), "A throwing cleanup does not mask the body's failure either")
	AssertEqual("CLEANUP takenote-document retired=0 cleanup_error=[TerminateProcess refused]", Emitted[1])
	AssertEqual("failed: Exact native document/process retirement must finish before directory cleanup",
		_TNPD_Outcome(() => 0, () => false, &Emitted), "An unretired cleanup fails a body that passed")
	AssertEqual("failed: TerminateProcess refused", _TNPD_Outcome(() => 0, Fails("TerminateProcess refused"), &Emitted))
	AssertEqual("passed", _TNPD_Outcome(() => 0, () => true, &Emitted))
	AssertEqual("CLEANUP takenote-document retired=1", Emitted[1])
}
_TNPD_Throw(Message) {
	throw Error(Message)
}
Test("TakeNote probe: the first failure is reported, not the cleanup's (takenote-probe-first-error)",
	_TNPD_ReportsTheFirstError)
