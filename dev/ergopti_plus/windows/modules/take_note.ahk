; modules/take_note.ahk

; ==============================================================================
; MODULE: Shared Asynchronous Take-Note Action
; DESCRIPTION:
; Owns the complete Notepad transaction for every action entry point. Dispatch
; callbacks only enqueue a one-shot timer; file, process, focus, maximise, and
; final-send work is performed by the bounded, suspend-aware job.
; ==============================================================================

#Requires AutoHotkey v2.0+

global _TakeNotePending := Map()
global _TakeNoteNextId := 0
global TAKE_NOTE_POLL_INTERVAL_MS := 50
global TAKE_NOTE_LAUNCH_TIMEOUT_MS := 7000


_TakeNoteTitleMatchesFile(Title, FileName) {
	if !(Title is String) or !(FileName is String) or FileName == ""
		return false
	Title := Trim(Title)
	if SubStr(Title, 1, 1) == "*"
		Title := LTrim(SubStr(Title, 2))
	; Notepad appends its localized product label after the last " - ". Taking
	; the last separator rejects prefixes, backup extensions, and filenames that
	; merely begin with the requested fixed Notes*.txt basename.
	SeparatorPos := InStr(Title, " - ", , -1)
	DocumentTitle := SeparatorPos > 0 ? SubStr(Title, 1, SeparatorPos - 1) : Title
	return StrLower(DocumentTitle) == StrLower(FileName)
}


; Injectable OS boundary. Tests replace this class with a deterministic clock
; and manually-driven timer queue, so they never launch or focus a real window.
class _TakeNoteNative {
	static NowTick() {
		return A_TickCount
	}

	static IsSuspended() {
		return A_IsSuspended
	}

	static FileExists(Path) {
		return FileExist(Path) != ""
	}

	static CreateEmptyFile(Path) {
		FileAppend("", Path)
		return true
	}

	static Launch(Path) {
		Run('notepad.exe "' . Path . '"')
		return true
	}

	static FindWindow(FileName) {
		try Hwnds := WinGetList("ahk_exe notepad.exe")
		catch
			return 0
		for Hwnd in Hwnds {
			try Title := WinGetTitle("ahk_id " . Hwnd)
			catch
				continue
			if _TakeNoteTitleMatchesFile(Title, FileName)
				return Hwnd
		}
		return 0
	}

	static Activate(Hwnd) {
		return WMActivate(Hwnd)
	}

	static IsActive(Hwnd) {
		return WinActive("ahk_id " . Hwnd) != 0
	}

	static IsExactWindow(Hwnd, FileName) {
		try Title := WinGetTitle("ahk_id " . Hwnd)
		catch
			return false
		return _TakeNoteTitleMatchesFile(Title, FileName)
	}

	static Maximize(Hwnd) {
		WinMaximize("ahk_id " . Hwnd)
		return true
	}

	static SendFinal(Keys) {
		return SendFinalResult(Keys)
	}

	static Schedule(Callback, DelayMs) {
		SetTimer(Callback, -Max(1, DelayMs))
		return true
	}

	static WarnTimeout(Pattern) {
		LoggerWarn("TakeNote", "Notepad window '{1}' did not appear or take focus before the bounded launch deadline.", Pattern)
	}

	static ReportError(Message) {
		LoggerError("TakeNote", "Deferred note-window transaction failed: {1}", Message)
		try TrayTip(t("notify.take_note_failed"), "ErgoptiPlus", "Iconx Mute")
	}
}


; Resolve the feature settings once, without performing any OS or file work.
; Both the Win+N shortcut and the gesture action call this same entry seam.
_TakeNoteQueueFromFeatures(AppendNewlineOnLaunch := true, Ops := _TakeNoteNative) {
	global Features
	DatedNotes := false
	DestinationFolder := A_Desktop
	try {
		if IsSet(Features) and Features.Has("shortcuts")
			and Features["shortcuts"].Has("take_note")
			and IsObject(Features["shortcuts"]["take_note"]) {
			Settings := Features["shortcuts"]["take_note"]
			if Settings.Has("dated_notes") {
				DatedValue := Settings["dated_notes"]
				DatedNotes := (DatedValue is Integer) and DatedValue != 0
			}
			if Settings.Has("destination_folder")
				and Settings["destination_folder"] is String
				and Settings["destination_folder"] != ""
				DestinationFolder := Settings["destination_folder"]
		}
		return TakeNoteRequest(DatedNotes, DestinationFolder,
			AppendNewlineOnLaunch, Ops)
	} catch as Err {
		try Ops.ReportError(Err.Message)
		return 0
	}
}


; Public shortcut callback. It deliberately contains no file, shell, window, or
; send primitive: those operations start only after this callback has returned.
TakeNote(*) {
	return _TakeNoteQueueFromFeatures(true)
}


; Build and enqueue one note job. Scheduling is the only side effect before the
; caller returns; even FileExist and Run belong to the deferred state machine.
TakeNoteRequest(DatedNotes, DestinationFolder, AppendNewlineOnLaunch := true, Ops := _TakeNoteNative) {
	try {
		if !(DestinationFolder is String) or Trim(DestinationFolder) = ""
			throw ValueError("note destination folder must be a non-empty string")
		FileName := DatedNotes
			? "Notes_" . FormatTime(, "dd_MM_yyyy") . ".txt"
			: "Notes.txt"
		FilePath := RTrim(DestinationFolder, "\/") . "\" . FileName
		Pattern := FileName . " ahk_exe notepad.exe"
		return _TakeNoteQueueFinalize(FilePath, FileName, Pattern,
			AppendNewlineOnLaunch, Ops)
	} catch as Err {
		try Ops.ReportError(Err.Message)
		return 0
	}
}


_TakeNoteQueueFinalize(FilePath, FileName, WinPattern,
		AppendNewlineOnLaunch, Ops := _TakeNoteNative) {
	global _TakeNotePending, _TakeNoteNextId
	global TAKE_NOTE_POLL_INTERVAL_MS, TAKE_NOTE_LAUNCH_TIMEOUT_MS
	PathKey := StrLower(StrReplace(FilePath, "/", "\"))
	PreviousCritical := Critical("On")
	try {
		; One exact note path owns at most one launch/focus transaction. Without
		; this admission gate, two rapid shortcut/gesture callbacks both observe
		; the pre-window state, launch Notepad twice, then inject into the same
		; first matching window.
		for PendingId, PendingJob in _TakeNotePending {
			if PendingJob["path_key"] == PathKey
				return PendingId
		}
		JobId := ++_TakeNoteNextId
		TimerFn := _TakeNotePoll.Bind(JobId)
		_TakeNotePending[JobId] := Map(
			"phase", "queued",
			"file_path", FilePath,
			"path_key", PathKey,
			"file_name", FileName,
			"pattern", WinPattern,
			"append_on_launch", AppendNewlineOnLaunch,
			"append_newline", false,
			"started_tick", Ops.NowTick(),
			"timeout_ms", TAKE_NOTE_LAUNCH_TIMEOUT_MS,
			"timer", TimerFn,
			"ops", Ops
		)
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if !Ops.Schedule(TimerFn, TAKE_NOTE_POLL_INTERVAL_MS)
			throw Error("initial timer scheduling was refused")
	} catch as Err {
		_TakeNoteFinish(JobId)
		throw Err
	}
	return JobId
}


_TakeNoteFinish(JobId) {
	global _TakeNotePending
	PreviousCritical := Critical("On")
	try {
		if _TakeNotePending.Has(JobId)
			_TakeNotePending.Delete(JobId)
	} finally {
		Critical(PreviousCritical)
	}
}


_TakeNoteExpire(JobId, Job) {
	try Job["ops"].WarnTimeout(Job["pattern"])
	_TakeNoteFinish(JobId)
}


_TakeNoteReschedule(JobId, Job) {
	global TAKE_NOTE_POLL_INTERVAL_MS
	Ops := Job["ops"]
	if TickExpired(Job["started_tick"], Job["timeout_ms"], Ops.NowTick()) {
		_TakeNoteExpire(JobId, Job)
		return false
	}
	if !Ops.Schedule(Job["timer"], TAKE_NOTE_POLL_INTERVAL_MS)
		throw Error("poll timer scheduling was refused")
	return true
}


; A native file, process, focus, or window call may pump an AHK callback. Check
; the terminal conditions again before every later externally visible effect so
; a suspension or deadline that lands mid-tick cannot continue the transaction.
_TakeNoteAbortIfUnavailable(JobId, Job) {
	Ops := Job["ops"]
	if Ops.IsSuspended() {
		_TakeNoteFinish(JobId)
		return true
	}
	if TickExpired(Job["started_tick"], Job["timeout_ms"], Ops.NowTick()) {
		_TakeNoteExpire(JobId, Job)
		return true
	}
	return false
}


; Deferred state machine. The timeout is checked before every expensive phase,
; suspension cancels without publication, and focus is observed before maximise
; or final input so a stale/foreign window never receives the action.
_TakeNotePoll(JobId) {
	global _TakeNotePending
	if !_TakeNotePending.Has(JobId)
		return
	Job := _TakeNotePending[JobId]
	Ops := Job["ops"]
	try {
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return

		if Job["phase"] = "queued" {
			FileExists := Ops.FileExists(Job["file_path"])
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			if !FileExists
				and !Ops.CreateEmptyFile(Job["file_path"])
				throw Error("note file creation was refused")
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			WindowAlreadyOpen := Ops.FindWindow(Job["file_name"]) != 0
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			Job["append_newline"] := Job["append_on_launch"] and !WindowAlreadyOpen
			Job["phase"] := "waiting"
			if !WindowAlreadyOpen and !Ops.Launch(Job["file_path"])
				throw Error("Notepad launch was refused")
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
		}

		WindowHwnd := Ops.FindWindow(Job["file_name"])
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !WindowHwnd {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		Activated := Ops.Activate(WindowHwnd)
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !Activated or !Ops.IsActive(WindowHwnd)
			or !Ops.IsExactWindow(WindowHwnd, Job["file_name"]) {
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !Ops.Maximize(WindowHwnd)
			throw Error("Notepad maximize was refused")
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !Ops.IsActive(WindowHwnd)
			or !Ops.IsExactWindow(WindowHwnd, Job["file_name"]) {
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if Job["append_newline"] and !Ops.SendFinal("^{End}{Enter}")
			throw Error("final note input was refused")
		_TakeNoteFinish(JobId)
	} catch as Err {
		_TakeNoteFinish(JobId)
		try Ops.ReportError(Err.Message)
	}
}
