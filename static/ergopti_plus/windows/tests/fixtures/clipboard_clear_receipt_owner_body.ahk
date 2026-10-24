; tests/fixtures/clipboard_clear_receipt_owner_body.ahk

; ==============================================================================
; MODULE: Capture Clear Receipt Native Child
; DESCRIPTION:
; Real selection and region-save entry points delegate their default clear.
; A separate owned Windows process writes B at a controlled unlocked boundary.
; No physical copy chord, Snipping Tool, image worker or logical native ACK.
; ==============================================================================

#Requires AutoHotkey v2.0

class _CRCO_Errors {
	static Failure := 0
}

LoggerWarn(*) => 0
LoggerDebug(*) => 0
LoggerInfo(*) => 0
LoggerStart(*) => 0
LoggerSuccess(*) => 0

LoggerError(Tag, Message, Args*) {
	if !IsObject(_CRCO_Errors.Failure)
		_CRCO_Errors.Failure := Error("Actual capture error: " . Tag . " " . Message)
}

; Map.Get receives the genuine default chosen by the production caller. This
; preserves the default callback, native return and any future bound receipt.
; No CB_Write replacement or fixture-assigned ownership sequence exists here.
class _CRCO_Ports extends Map {
	Get(Key, Default := unset) {
		if Key == "clear" {
			_SICO_Require(IsSet(Default) && HasMethod(Default, "Call"), "The real producer must supply its callable default clear.")
			return _CRCO_Clear.Bind(Default)
		}
		return IsSet(Default) ? super.Get(Key, Default) : super.Get(Key)
	}
}

_CRCO_CheckFailure() {
	if IsObject(_CRCO_Errors.Failure)
		throw _CRCO_Errors.Failure
}

_CRCO_RequestCopy(Phase) {
	global _SICO
	_SICO_Require(!_SICO.Copied, "Only one controlled foreign copy is admitted.")
	_SICO_Publish(_SICO.Root . "\copy.request", Phase)
	Receipt := _SICO_Identity(_SICO_Wait(_SICO.Root . "\copy.receipt"), true)
	_SICO_Require(Receipt.Pid == _SICO.Writer.Pid && Receipt.Hwnd == _SICO.Writer.Hwnd,
		"The originally admitted independent actor must commit B.")
	Sample := _SICO_Sample(_SICO.Foreign)
	_SICO_Require(Sample.RawMatches && Sample.Text == _SICO.Foreign && Sample.Owner == Receipt.Hwnd
		&& Sample.Sequence == Receipt.Sequence && Receipt.Sequence > 0 && Receipt.Sequence != _SICO.ClearSequence,
		"PREREQUISITE: real foreign B bytes, owner and generation must be authenticated after writer Close.")
	_SICO.Copied := true, _SICO.WriterSequence := Receipt.Sequence, _SICO.Boundary := Phase
}

_CRCO_Clear(ActualDefault) {
	global _SICO
	try {
		_SICO.ClearCalls += 1
		Result := ActualDefault.Call()
		_CRCO_CheckFailure()
		if !Result
			return Result
		_SICO_Require(_SICO.ClearCalls == 1 && A_IsCritical > 0 && CBClipboardOwner.active.Count == 1
			&& !CBClipboardOwner.paste_transaction, "The real capture owns one non-paste clear under the bounded fixture poll fence.")
		_SICO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The successful default clear must admit an independent native read lease.")
		try {
			_SICO.ClearSequence := CB_GetSequenceNumber()
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Formats := DllCall("User32\CountClipboardFormats", "Int"), NativeError := A_LastError
			_SICO_Require(_SICO.ClearSequence > 0 && Formats == 0 && NativeError == 0
				&& DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"PREREQUISITE: the default callback must really publish an empty native clipboard under this HWND.")
		} finally {
			_SICO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The clear observer must close exactly its own read lease.")
		}
		if _SICO.Position == "before-receipt"
			_CRCO_RequestCopy("after-default-clear-before-caller-receipt")
		return Result
	} catch Any as Failure {
		if !IsObject(_CRCO_Errors.Failure)
			_CRCO_Errors.Failure := Failure
		throw Failure
	}
}

_CRCO_Send() {
	global _SICO
	_SICO.Sends += 1
}

_CRCO_Ready(*) {
	global _SICO
	_SICO.Deliveries += 1
}

_CRCO_RegionDone(Ok, Reason) {
	global _SICO
	_SICO.Terminals += 1
	if Ok
		_SICO.Successes += 1
}

_CRCO_Cancel() {
	global _SICO, _SelectionCaptureJob, _GestureRegionCapture
	Current := _SICO.Family == "selection" ? _SelectionCaptureJob : _GestureRegionCapture
	Timer := Current is Map ? Current.Get(_SICO.Family == "selection" ? "timer" : "poll_timer", 0) : 0
	if _SICO.Family == "selection"
		GetSelectionCancel()
	else
		GestureScreenshotCancelAll("private clear-receipt cancellation")
	; Region retirement leaves an inert one-shot poll. The fixture cancels that
	; exact retained callback after real cancellation, before restoring globals.
	if IsObject(Timer)
		SetTimer(Timer, 0)
}

_CRCO_Writer(Root, Mode) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt"), Copied := false
	_SICO_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount
	loop {
		if !Copied && FileExist(Root . "\copy.request") {
			A_Clipboard := "clear receipt external B é😀 " . Root
			Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
			_SICO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd
				&& DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
				"The private writer must publish and close its actual native clipboard.")
			_SICO_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_SICO_Require(TickElapsed64(Started) < 12000, "The exact private writer must settle within 12000 ms.")
		Sleep(10)
	}
	_SICO_Require(Copied == !InStr(Mode, "ordinary"), "The independent actor must perform the requested exact copy count.")
	FileAppend("PASS clear-receipt-writer " . Mode . " copies=" . Copied . "`n", "*", "UTF-8-RAW")
}

_CRCO_Subject(Root, Mode) {
	global _SICO, _SelectionCaptureJob, _GestureRegionCapture
	Parts := StrSplit(Mode, ":")
	_SICO := {Root: Root, Mode: Mode, Family: Parts[1], Position: Parts[2], Failure: 0,
		Seed: "clear receipt original A é😀 " . Root, Foreign: "clear receipt external B é😀 " . Root,
		Payload: "", Marker: "opaque clear receipt A é😀 " . Root, Format: 0,
		Copied: false, WriterSequence: 0, ClearSequence: 0, Boundary: "none", ClearCalls: 0,
		Sends: 0, Deliveries: 0, Terminals: 0, Successes: 0, Writer: 0}
	Snapshot := 0, HaveSnapshot := false, Primary := 0, Captured := 0, LateTimer := 0
	try {
		_SICO.Writer := _SICO_Identity(_SICO_Wait(Root . "\writer.ready"))
		_SICO_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.paste_transaction && !CBClipboardOwner.observer_active,
			"The isolated subject requires fresh actual clipboard ownership.")
		Snapshot := CB_SaveAll()
		_SICO_Require(!(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__"), "The incoming opaque snapshot must be saved.")
		HaveSnapshot := true
		_SICO_Require(CB_Write(_SICO.Seed) && _SICO_Sample(_SICO.Seed).RawMatches, "Private A must really exist before the producer snapshots it.")
		_SICO_AddOriginalFormat()
		_SICO_Require(_SICO_MarkerMatches(), "Private A includes a real extra non-text format.")
		Ports := _CRCO_Ports("send", _CRCO_Send)
		PreviousCritical := Critical("On")
		try {
			if _SICO.Family == "selection" {
				Started := GetSelectionAsync(_CRCO_Ready, Ports)
				Captured := _SelectionCaptureJob
				if Captured is Map
					LateTimer := Captured["timer"]
				Admitted := Captured is Map ? Captured["owned_sequence"] : 0
			} else {
				Started := GestureScreenshotRegion("save", _CRCO_RegionDone, Root . "\unused.png", 0, Ports)
				Captured := _GestureRegionCapture
				if Captured is Map
					LateTimer := Captured["poll_timer"]
				Admitted := Captured is Map ? Captured["clipboard_sequence"] : 0
			}
			_CRCO_CheckFailure()
			_SICO_Require(_SICO.ClearCalls == 1 && _SICO.ClearSequence > 0, "The actual default clear must complete once.")
			if _SICO.Position != "before-receipt"
				_SICO_Require(Started && _SICO.Sends == 1 && Admitted == _SICO.ClearSequence && IsObject(LateTimer),
					"PREREQUISITE: the current producer must admit its real clear, call its actual send port once and own its poll before the control stimulus.")
			if _SICO.Position == "after-receipt"
				_CRCO_RequestCopy("after-genuine-caller-receipt")
			_CRCO_Cancel()
		} finally Critical(PreviousCritical)
		_SICO_Settle()
		_CRCO_CheckFailure()
		Expected := _SICO.Position == "ordinary" ? _SICO.Seed : _SICO.Foreign
		Sample := _SICO_Sample(Expected)
		FileAppend("RECEIPT clear-receipt-owner mode=" . Mode . " started=" . Started . " default_calls=" . _SICO.ClearCalls
			. " clear_sequence=" . _SICO.ClearSequence . " admitted=" . Admitted . " boundary=" . _SICO.Boundary
			. " writer_pid=" . _SICO.Writer.Pid . " writer_hwnd=" . _SICO.Writer.Hwnd . " writer_sequence=" . _SICO.WriterSequence
			. " copies=" . _SICO.Copied . " final_sequence=" . Sample.Sequence . " final_owner=" . Sample.Owner
			. " raw_match=" . Sample.RawMatches . " raw_units=" . Sample.RawUnits . " sends=" . _SICO.Sends
			. " deliveries=" . _SICO.Deliveries . " terminals=" . _SICO.Terminals . " successes=" . _SICO.Successes
			. " active=" . CBClipboardOwner.active.Count . " debt=" . (CBClipboardOwner.restore_debt is Map) . "`n", "*", "UTF-8-RAW")
		if _SICO.Position == "ordinary"
			_SICO_Require(Sample.RawMatches && Sample.Text == _SICO.Seed && _SICO_MarkerMatches(),
				"Current capture cancellation must restore actual A and its original non-text format.")
		else
			_SICO_Require(_SICO.Copied && Sample.RawMatches && Sample.Text == _SICO.Foreign
				&& Sample.Sequence == _SICO.WriterSequence && Sample.Owner == _SICO.Writer.Hwnd,
				"The independent B copy must survive actual capture cancellation with its exact native image, owner and generation.")
		_SICO_Require(_SICO.Deliveries == 0 && _SICO.Successes == 0
			&& _SICO.Terminals == (_SICO.Family == "region" ? 1 : 0), "Cancellation cannot deliver a selection or successful region result.")
		if IsObject(LateTimer)
			LateTimer.Call()
		_CRCO_CheckFailure()
		Late := _SICO_Sample(Expected)
		_SICO_Require(Late.RawMatches && Late.Sequence == Sample.Sequence && Late.Owner == Sample.Owner,
			"A retained retired poll cannot mutate the settled native clipboard.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			_CRCO_Cancel()
			if HaveSnapshot
				_SICO_RestoreIncoming(Snapshot)
			_SICO_Require(!IsObject(_SelectionCaptureJob) && !IsObject(_GestureRegionCapture)
				&& GestureScreenshotWorkerState.jobs.Count == 0 && CBClipboardOwner.active.Count == 0
				&& !(CBClipboardOwner.restore_debt is Map), "All real capture timers, jobs and native restore debt must retire.")
			_CRCO_CheckFailure()
			FileAppend("CLEANUP clear-receipt-owner active=0 debt=0 jobs=0`n", "*", "UTF-8-RAW")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if Captured is Map {
				if Captured.Has("callback")
					Captured["callback"] := 0
				if Captured.Has("generation_fn")
					Captured["generation_fn"] := 0
			}
			LateTimer := 0, Captured := 0
			try _SICO_Publish(Root . "\subject.done", "done")
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS clear-receipt-owner " . Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_SICO_Require(A_Args.Length == 3 && RegExMatch(A_Args[3], "^(selection|region):(before-receipt|after-receipt|ordinary)$"),
		"Exactly one declared role, private root and capture mode are required.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_CRCO_Writer(A_Args[2], A_Args[3])
	else {
		_SICO_Require(A_Args[1] == "subject", "Only the subject and independent writer roles are declared.")
		_CRCO_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL clear-receipt-owner " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
