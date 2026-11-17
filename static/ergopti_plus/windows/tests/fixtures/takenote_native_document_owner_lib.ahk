; tests/fixtures/takenote_native_document_owner_lib.ahk

; ==============================================================================
; MODULE: TakeNote Native Document Probe Decisions
; DESCRIPTION:
; The decisions of the private Notepad probe, behind injected window ports so
; the suite can drive them without a real Notepad. Windows 11 Notepad restores
; the tabs of its earlier sessions when it starts, each with its own hidden
; RichEdit control, so the probe reads the selected tab's control, owns every
; window of a process it proved, and reports its first failure before cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0

; Text of the document the selected tab shows. Every tab of a tabbed Notepad
; keeps its own RichEdit control and only the selected one is visible; the first
; control in z-order belongs to whichever tab was created first.
; @param Hwnd {Integer} A Notepad top-level window.
; @param Ports {Object} Controls(Hwnd), ClassOf(Control), Visible(Control) and
;   Text(Control) over that window's child controls.
; @returns {String} "" while no document control is visible yet.
_TNDO_SelectedDocumentText(Hwnd, Ports) {
	Shown := []
	for Control in Ports.Controls(Hwnd) {
		if !RegExMatch(Ports.ClassOf(Control), "i)^(?:Edit|RichEdit.*)$")
			continue
		if Ports.Visible(Control)
			Shown.Push(Control)
	}
	if Shown.Length > 1
		throw Error("Notepad shows " . Shown.Length . " document controls at once, so its selected tab is ambiguous")
	return Shown.Length ? Ports.Text(Shown[1]) : ""
}

; Records every window of a proved Notepad process. A process is proved by its
; Run receipt or by a window whose selected document is a private canary; its
; other windows, restored tabs of earlier sessions included, are then the
; probe's to retire. The proof is collected over all windows first, so a
; restored window listed before the canary is not left out as foreign.
; @param Ports {Object} List(), Pid(Hwnd), Document(Hwnd), Hold(Pid) and
;   Alive(Receipt). Hold adds the process to State.Processes or returns 0.
; @param State {Object} Processes (Pid -> receipt), Windows (Hwnd -> record),
;   CanaryA, CanaryB and ObserveError, the last observation failure.
_TNDO_ObserveWindowsWith(Ports, State) {
	Seen := []
	for Hwnd in Ports.List() {
		try Pid := Ports.Pid(Hwnd)
		catch Any as ObserveError {
			State.ObserveError := ObserveError.Message
			continue
		}
		Document := ""
		try {
			Text := Ports.Document(Hwnd)
			Document := Text == State.CanaryA ? "A" : Text == State.CanaryB ? "B" : ""
			; A broker-created process is adopted only after its actual document
			; proves the private canary; a Run receipt owns its exact process.
			if Document != ""
				Ports.Hold(Pid)
		} catch Any as ObserveError
			State.ObserveError := ObserveError.Message
		Seen.Push({Hwnd: Hwnd, Pid: Pid, Document: Document})
	}
	for Item in Seen {
		if !State.Processes.Has(Item.Pid)
			continue
		Process := State.Processes[Item.Pid]
		try {
			if !Ports.Alive(Process) || Ports.Pid(Item.Hwnd) != Item.Pid
				continue
		} catch Any as ObserveError {
			State.ObserveError := ObserveError.Message
			continue
		}
		State.Windows[Item.Hwnd] := {Hwnd: Item.Hwnd, Process: Process, Document: Item.Document}
	}
}

; The Notepad windows still listed after cleanup that the probe never proved.
; @param Listed {Array} The Notepad windows that remain.
; @param Windows {Map} The probe's proved windows.
; @returns {Array}
_TNDO_ForeignWindows(Listed, Windows) {
	Foreign := []
	for Hwnd in Listed
		if !Windows.Has(Hwnd)
			Foreign.Push(Hwnd)
	return Foreign
}

; Runs Body, then Cleanup whatever Body did, and emits the cleanup outcome. The
; body's failure is the one thrown: a cleanup that cannot retire what a failed
; body left behind would otherwise replace the failure that explains it.
; @param Body {Func} The probe itself.
; @param Cleanup {Func} Returns true once every owned document has retired.
; @param Emit {Func} Receives the CLEANUP line.
_TNDO_RunThenCleanup(Body, Cleanup, Emit) {
	Primary := 0, CleanupFailure := 0, Clean := false
	try Body.Call()
	catch Any as Failure
		Primary := Failure
	try Clean := Cleanup.Call()
	catch Any as Failure
		CleanupFailure := Failure
	Retired := Clean is Integer && Clean == 1 && !IsObject(CleanupFailure)
	Emit.Call("CLEANUP takenote-document retired=" . (Retired ? 1 : 0)
		. (IsObject(CleanupFailure) ? " cleanup_error=[" . CleanupFailure.Message . "]" : ""))
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
	if !Retired
		throw Error("Exact native document/process retirement must finish before directory cleanup")
}
