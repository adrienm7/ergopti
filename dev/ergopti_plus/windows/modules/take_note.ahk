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

	static WindowExists(Pattern) {
		PreviousMode := A_TitleMatchMode
		try {
			SetTitleMatchMode(2)
			return WMExists(Pattern)
		} finally {
			SetTitleMatchMode(PreviousMode)
		}
	}

	static Activate(Pattern) {
		PreviousMode := A_TitleMatchMode
		try {
			SetTitleMatchMode(2)
			return WMActivate(Pattern)
		} finally {
			SetTitleMatchMode(PreviousMode)
		}
	}

	static IsActive(Pattern) {
		PreviousMode := A_TitleMatchMode
		try {
			SetTitleMatchMode(2)
			return WinActive(Pattern) != 0
		} finally {
			SetTitleMatchMode(PreviousMode)
		}
	}

	static Maximize(Pattern) {
		PreviousMode := A_TitleMatchMode
		try {
			SetTitleMatchMode(2)
			WinMaximize(Pattern)
			return true
		} finally {
			SetTitleMatchMode(PreviousMode)
		}
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
		return _TakeNoteQueueFinalize(FilePath, Pattern,
			AppendNewlineOnLaunch, Ops)
	} catch as Err {
		try Ops.ReportError(Err.Message)
		return 0
	}
}


_TakeNoteQueueFinalize(FilePath, WinPattern, AppendNewlineOnLaunch, Ops := _TakeNoteNative) {
	global _TakeNotePending, _TakeNoteNextId
	global TAKE_NOTE_POLL_INTERVAL_MS, TAKE_NOTE_LAUNCH_TIMEOUT_MS
	JobId := ++_TakeNoteNextId
	TimerFn := _TakeNotePoll.Bind(JobId)
	_TakeNotePending[JobId] := Map(
		"phase", "queued",
		"file_path", FilePath,
		"pattern", WinPattern,
		"append_on_launch", AppendNewlineOnLaunch,
		"append_newline", false,
		"started_tick", Ops.NowTick(),
		"timeout_ms", TAKE_NOTE_LAUNCH_TIMEOUT_MS,
		"timer", TimerFn,
		"ops", Ops
	)
	try {
		if !Ops.Schedule(TimerFn, TAKE_NOTE_POLL_INTERVAL_MS)
			throw Error("initial timer scheduling was refused")
	} catch as Err {
		_TakeNotePending.Delete(JobId)
		throw Err
	}
	return JobId
}


_TakeNoteFinish(JobId) {
	global _TakeNotePending
	if _TakeNotePending.Has(JobId)
		_TakeNotePending.Delete(JobId)
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
		if Ops.IsSuspended() {
			_TakeNoteFinish(JobId)
			return
		}
		if TickExpired(Job["started_tick"], Job["timeout_ms"], Ops.NowTick()) {
			_TakeNoteExpire(JobId, Job)
			return
		}

		if Job["phase"] = "queued" {
			if !Ops.FileExists(Job["file_path"])
				and !Ops.CreateEmptyFile(Job["file_path"])
				throw Error("note file creation was refused")
			WindowAlreadyOpen := Ops.WindowExists(Job["pattern"])
			Job["append_newline"] := Job["append_on_launch"] and !WindowAlreadyOpen
			Job["phase"] := "waiting"
			if !WindowAlreadyOpen and !Ops.Launch(Job["file_path"])
				throw Error("Notepad launch was refused")
		}

		if !Ops.WindowExists(Job["pattern"]) {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if !Ops.Activate(Job["pattern"]) or !Ops.IsActive(Job["pattern"]) {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if !Ops.Maximize(Job["pattern"])
			throw Error("Notepad maximize was refused")
		if Job["append_newline"] and !Ops.SendFinal("^{End}{Enter}")
			throw Error("final note input was refused")
		_TakeNoteFinish(JobId)
	} catch as Err {
		_TakeNoteFinish(JobId)
		try Ops.ReportError(Err.Message)
	}
}
