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
global _TakeNoteGeneration := 0
global TAKE_NOTE_POLL_INTERVAL_MS := 50
global TAKE_NOTE_LAUNCH_TIMEOUT_MS := 7000
; The Windows 11 Notepad opens a launched file as a tab of its running window
; and switches to it a moment later. A selected tab that never changed after
; the launch is taken for the requested note only once this delay has passed:
; Notepad then kept it selected because the file was already open in it.
; "Hwnd|TabId" -> the lowercased full path of the note this module opened in
; that Notepad document; TabId is the UI Automation runtime id of the selected
; tab, or "" for the classic one-window-per-document Notepad. Notepad titles a
; document and names its tab by the file name alone, so two folders' Notes.txt
; read the same; this binding is what tells their documents apart.
global _TakeNoteDocumentWindows := Map()


_TakeNoteTitleMatchesFile(Title, FileName) {
	if !(Title is String) or !(FileName is String) or FileName == ""
		return false
	Title := Trim(Title)
	if SubStr(Title, 1, 1) == "*"
		Title := LTrim(SubStr(Title, 2))
	; Notepad appends its localized product label after the last separator: a
	; hyphen in the classic Notepad, an en dash in the Windows 11 Store Notepad
	; (« Notes.txt – Bloc-notes »). Taking the last one rejects prefixes, backup
	; extensions, and filenames that merely begin with the requested fixed
	; Notes*.txt basename.
	SeparatorPos := 0
	for Separator in [" - ", " " . Chr(0x2013) . " ", " " . Chr(0x2014) . " "]
		SeparatorPos := Max(SeparatorPos, InStr(Title, Separator, , -1))
	DocumentTitle := SeparatorPos > 0 ? SubStr(Title, 1, SeparatorPos - 1) : Title
	return StrLower(DocumentTitle) == StrLower(FileName)
}


; Injectable OS boundary. Tests replace this class with a deterministic clock
; and manually-driven timer queue, so they never launch or focus a real window.
class _TakeNoteNative {
	; Win32 paths are NUL-terminated; inspect the original counted units before
	; a query or effect could silently select the shorter prefix.
	static _HasNativeNul(Path) {
		if !(Path is String)
			return false
		loop StrLen(Path)
			if NumGet(StrPtr(Path), (A_Index - 1) * 2, "UShort") == 0
				return true
		return false
	}

	static NowTick() {
		return A_TickCount
	}

	static IsSuspended() {
		return A_IsSuspended
	}

	static FileExists(Path) {
		return !_TakeNoteNative._HasNativeNul(Path) && FileExist(Path) != ""
	}

	static CreateEmptyFile(Path) {
		if _TakeNoteNative._HasNativeNul(Path)
			throw ValueError("note path cannot contain a NUL code unit")
		FileAppend("", Path)
		return true
	}

	static Launch(Path) {
		if _TakeNoteNative._HasNativeNul(Path)
			throw ValueError("note path cannot contain a NUL code unit")
		Run('notepad.exe "' . Path . '"')
		return true
	}

	; @param Admits {Func|0} Admits(Hwnd) is false for a window that cannot stand
	;   for the requested note (one bound to another folder's note of that name).
	static FindWindow(FileName, Admits := 0) {
		try Hwnds := WinGetList("ahk_exe notepad.exe")
		catch
			return 0
		for Hwnd in Hwnds {
			try Title := WinGetTitle("ahk_id " . Hwnd)
			catch
				continue
			if _TakeNoteTitleMatchesFile(Title, FileName)
					&& (!HasMethod(Admits, "Call") || Admits.Call(Hwnd))
				return Hwnd
		}
		return 0
	}

	; The Windows 11 Notepad tab items expose only the file name and its saved
	; state (« Notes.txt. Non modifié. »), never the full path: the UIA runtime
	; id of a tab is the only identity that tells two same-named notes apart.
	; @returns {String|Integer} The UIA runtime id of the selected tab, "" for a
	;   classic Notepad window without tabs, or 0 while the tab is unknown.
	static SelectedTab(Hwnd) {
		; Without the optional vendored UIA library no tab can be read, which
		; leaves the classic window-level binding (see ErgoptiPlus.ahk).
		if !IsSet(UIA)
			return ""
		try Root := UIA.ElementFromHandle(Hwnd, , false)
		catch
			return 0
		; One provider query: this runs on the driver thread while it polls.
		try return Root.FindFirst({Type: "TabItem", SelectionItemIsSelected: true}).RuntimeId
		catch TargetError
			NoTabSelected := true
		catch
			return 0
		try HasTabs := IsObject(Root.FindFirst({Type: "TabItem"}))
		catch TargetError
			HasTabs := false
		catch
			return 0
		if HasTabs
			return 0
		; The packaged Notepad always shows its tab strip; an empty tree there
		; is one that is not built yet, not a classic window.
		try Image := ProcessGetPath(WinGetPID("ahk_id " . Hwnd))
		catch
			return 0
		return InStr(Image, "\WindowsApps\") ? 0 : ""
	}

	; Selects the tab whose UIA runtime id is TabId in the Notepad window Hwnd.
	; @returns {Boolean} false when that tab is no longer open there.
	static SelectTab(Hwnd, TabId) {
		if !IsSet(UIA) || !(TabId is String) || TabId == ""
			return false
		try Tabs := UIA.ElementFromHandle(Hwnd, , false).FindAll({Type: "TabItem"})
		catch
			return false
		for TabItem in Tabs {
			try {
				if TabItem.RuntimeId == TabId {
					TabItem.SelectionItemPattern.Select()
					return true
				}
			} catch
				return false
		}
		return false
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

	; @param Pattern {String} The awaited window.
	; @param Waited {String} What the job last lacked: "window" or "focus".
	static WarnTimeout(Pattern, Waited) {
		LoggerWarn("TakeNote", "Notepad window '{1}' missed the bounded launch deadline: it was waiting for {2}.", Pattern, Waited)
	}

	static ReportError(Message) {
		LoggerError("TakeNote", "Deferred note-window transaction failed: {1}", Message)
		try TrayTip(t("notify.take_note_failed"), "ErgoptiPlus", "Iconx Mute")
	}
}


_TakeNoteDocumentKey(Hwnd, TabId) => Hwnd . "|" . TabId

; Whether the document a Notepad window shows may stand for the job's note. A
; document this module opened for another folder's note of the same name never
; does. An unbound classic window does, as before tabs existed. An unbound tab
; does only once Notepad answered this job's own launch: it switched to another
; tab, or kept the same one past [ui] take_note_tab_settle_ms. Restored or foreign
; tabs carry the same name, and only Notepad maps the launched path to its tab.
; @param Job {Map} The job; its "tab" records the admitted tab.
; @param Hwnd {Integer} A Notepad window whose title names the note's file.
; @returns {Boolean}
_TakeNoteWindowAdmits(Job, Hwnd) {
	global _TakeNoteDocumentWindows
	TabId := Job["ops"].SelectedTab(Hwnd)
	if !(TabId is String)
		return false
	SeenTabs := Job["seen_tabs"]
	if !SeenTabs.Has(Hwnd)
		SeenTabs[Hwnd] := {Tab: TabId}
	FirstSeen := SeenTabs[Hwnd]
	Key := _TakeNoteDocumentKey(Hwnd, TabId)
	if _TakeNoteDocumentWindows.Has(Key)
		Admitted := _TakeNoteDocumentWindows[Key] == Job["path_key"]
	else if TabId == ""
		Admitted := true
	else if !Job["launched"]
		Admitted := false
	else if FirstSeen.Tab != TabId
		Admitted := true
	else {
		; The delay counts from the first unchanged sight after the launch, so
		; a cold Notepad start slower than the delay still gets all of it.
		Now := Job["ops"].NowTick()
		if !FirstSeen.HasOwnProp("Since")
			FirstSeen.Since := Now
		Admitted := TickExpired64(FirstSeen.Since, TimingsGet("ui", "take_note_tab_settle_ms"), Now)
	}
	if Admitted
		Job["tab"] := TabId
	return Admitted
}

; The document this module last bound to the note at PathKey.
; @returns {Object|0} {Key, Hwnd, Tab}, or 0 when the note has no binding.
_TakeNoteBoundDocument(PathKey) {
	global _TakeNoteDocumentWindows
	for Key, BoundPath in _TakeNoteDocumentWindows {
		if BoundPath == PathKey {
			Parts := StrSplit(Key, "|", , 2)
			return {Key: Key, Hwnd: Integer(Parts[1]), Tab: Parts[2]}
		}
	}
	return 0
}

; Records that the tab TabId of Hwnd shows the note at PathKey, once the job
; proved it focused. Notepad holds one document per path, so the note's earlier
; binding is retired.
_TakeNoteBindWindow(Hwnd, TabId, PathKey) {
	global _TakeNoteDocumentWindows
	if !(_TakeNoteDocumentWindows is Map)
		throw TypeError("The TakeNote window bindings are not a Map.")
	while IsObject(Previous := _TakeNoteBoundDocument(PathKey))
		_TakeNoteDocumentWindows.Delete(Previous.Key)
	_TakeNoteDocumentWindows[_TakeNoteDocumentKey(Hwnd, TabId)] := PathKey
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
	global _TakeNoteGeneration
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended
			return 0
		Generation := _TakeNoteGeneration
	} finally Critical(PreviousCritical)
	try {
		if !(DestinationFolder is String) or Trim(DestinationFolder) = ""
			throw ValueError("note destination folder must be a non-empty string")
		if _TakeNoteNative._HasNativeNul(DestinationFolder)
			throw ValueError("note destination folder cannot contain a NUL code unit")
		FileName := DatedNotes
			? "Notes_" . FormatTime(, "dd_MM_yyyy") . ".txt"
			: "Notes.txt"
		FilePath := RTrim(DestinationFolder, "\/") . "\" . FileName
		Pattern := FileName . " ahk_exe notepad.exe"
		return _TakeNoteQueueFinalize(FilePath, FileName, Pattern,
			AppendNewlineOnLaunch, Ops, Generation)
	} catch as Err {
		PreviousCritical := Critical("On")
		try Current := !A_IsSuspended && Generation == _TakeNoteGeneration
		finally Critical(PreviousCritical)
		if Current
			try Ops.ReportError(Err.Message)
		return 0
	}
}


_TakeNoteQueueFinalize(FilePath, FileName, WinPattern,
		AppendNewlineOnLaunch, Ops := _TakeNoteNative, Generation := unset) {
	global _TakeNotePending, _TakeNoteNextId, _TakeNoteGeneration
	global TAKE_NOTE_POLL_INTERVAL_MS, TAKE_NOTE_LAUNCH_TIMEOUT_MS
	if !IsSet(Generation) {
		PreviousCritical := Critical("On")
		try Generation := _TakeNoteGeneration
		finally Critical(PreviousCritical)
	}
	PathKey := StrLower(StrReplace(FilePath, "/", "\"))
	StartedTick := Ops.NowTick()
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || Generation != _TakeNoteGeneration
			return 0
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
		Job := Map(
			"phase", "queued",
			"file_path", FilePath,
			"path_key", PathKey,
			"file_name", FileName,
			"pattern", WinPattern,
			"append_on_launch", AppendNewlineOnLaunch,
			"append_newline", false,
			"waited", "window",
			"launched", false,
			"seen_tabs", Map(),
			"tab", "",
			"started_tick", StartedTick,
			"timeout_ms", TAKE_NOTE_LAUNCH_TIMEOUT_MS,
			"timer", TimerFn,
			"ops", Ops
		)
		_TakeNotePending[JobId] := Job
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if !Ops.Schedule(TimerFn, TAKE_NOTE_POLL_INTERVAL_MS)
			throw Error("initial timer scheduling was refused")
	} catch as Err {
		if !_TakeNoteFinish(JobId, Job)
			return 0
		throw Err
	}
	; A short one-shot may already have completed normally before Schedule
	; returns. Preserve its original ID unless the request's epoch was revoked.
	PreviousCritical := Critical("On")
	try CurrentGeneration := !A_IsSuspended && Generation == _TakeNoteGeneration
	finally Critical(PreviousCritical)
	return CurrentGeneration ? JobId : 0
}

; RAM-only revocation: the already scheduled one-shot callbacks retain no
; authority after this map is replaced, even when native Suspend resumes.
TakeNoteRevokePending() {
	global _TakeNotePending, _TakeNoteGeneration
	PreviousCritical := Critical("On")
	try {
		; Keep old jobs alive until the native scheduler is restored below.
		Retired := _TakeNotePending
		_TakeNoteGeneration += 1
		_TakeNotePending := Map()
	}
	finally Critical(PreviousCritical)
	return true
}

_TakeNoteCurrent(JobId, Job) {
	global _TakeNotePending
	PreviousCritical := Critical("On")
	try return _TakeNotePending.Has(JobId) && _TakeNotePending[JobId] == Job
	finally Critical(PreviousCritical)
}

_TakeNoteFinish(JobId, Job := unset) {
	global _TakeNotePending
	PreviousCritical := Critical("On")
	try {
		if !_TakeNotePending.Has(JobId) || (IsSet(Job) && _TakeNotePending[JobId] != Job)
			return false
		_TakeNotePending.Delete(JobId)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}


_TakeNoteExpire(JobId, Job) {
	if !_TakeNoteFinish(JobId, Job)
		return false
	try Job["ops"].WarnTimeout(Job["pattern"], Job["waited"])
	return true
}


_TakeNoteReschedule(JobId, Job) {
	global TAKE_NOTE_POLL_INTERVAL_MS
	Ops := Job["ops"]
	if _TakeNoteAbortIfUnavailable(JobId, Job)
		return false
	Scheduled := Ops.Schedule(Job["timer"], TAKE_NOTE_POLL_INTERVAL_MS)
	if !_TakeNoteCurrent(JobId, Job)
		return false
	if !Scheduled
		throw Error("poll timer scheduling was refused")
	return true
}


; A native file, process, focus, or window call may pump an AHK callback. Check
; the terminal conditions again before every later externally visible effect so
; a suspension or deadline that lands mid-tick cannot continue the transaction.
_TakeNoteAbortIfUnavailable(JobId, Job) {
	if !_TakeNoteCurrent(JobId, Job)
		return true
	Ops := Job["ops"]
	Suspended := Ops.IsSuspended()
	if !_TakeNoteCurrent(JobId, Job)
		return true
	if Suspended || A_IsSuspended {
		_TakeNoteFinish(JobId, Job)
		return true
	}
	Now := Ops.NowTick()
	if !_TakeNoteCurrent(JobId, Job)
		return true
	if A_IsSuspended {
		_TakeNoteFinish(JobId, Job)
		return true
	}
	if TickExpired64(Job["started_tick"], Job["timeout_ms"], Now) {
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
	PreviousCritical := Critical("On")
	try {
		if !_TakeNotePending.Has(JobId)
			return
		Job := _TakeNotePending[JobId]
	} finally Critical(PreviousCritical)
	Ops := Job["ops"]
	Admits := _TakeNoteWindowAdmits.Bind(Job)
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
			; A tabbed Notepad shows one tab at a time: bring the note's own tab
			; back before the lookup, which only reads the selected one.
			Bound := _TakeNoteBoundDocument(Job["path_key"])
			TabReselected := false
			if IsObject(Bound) && Bound.Tab != "" {
				TabReselected := Ops.SelectTab(Bound.Hwnd, Bound.Tab)
				if _TakeNoteAbortIfUnavailable(JobId, Job)
					return
			}
			WindowAlreadyOpen := TabReselected || Ops.FindWindow(Job["file_name"], Admits) != 0
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			Job["append_newline"] := Job["append_on_launch"] and !WindowAlreadyOpen
			Job["phase"] := "waiting"
			if !WindowAlreadyOpen {
				if !Ops.Launch(Job["file_path"])
					throw Error("Notepad launch was refused")
				Job["launched"] := true
			}
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
		}

		WindowHwnd := Ops.FindWindow(Job["file_name"], Admits)
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !WindowHwnd {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		Job["waited"] := "focus"
		Activated := Ops.Activate(WindowHwnd)
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if Activated {
			Active := Ops.IsActive(WindowHwnd)
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			Exact := Active ? Ops.IsExactWindow(WindowHwnd, Job["file_name"]) : false
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
		} else
			Active := false, Exact := false
		if !Activated || !Active || !Exact {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if !Ops.Maximize(WindowHwnd)
			throw Error("Notepad maximize was refused")
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		Active := Ops.IsActive(WindowHwnd)
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		Exact := Active ? Ops.IsExactWindow(WindowHwnd, Job["file_name"]) : false
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		if Exact {
			; The title names the file only: a switch to another same-named tab
			; since the lookup keeps it, so the admitted tab is checked again.
			SelectedTab := Ops.SelectedTab(WindowHwnd)
			if _TakeNoteAbortIfUnavailable(JobId, Job)
				return
			Exact := SelectedTab is String && SelectedTab == Job["tab"]
		}
		if !Active || !Exact {
			_TakeNoteReschedule(JobId, Job)
			return
		}
		if _TakeNoteAbortIfUnavailable(JobId, Job)
			return
		_TakeNoteBindWindow(WindowHwnd, Job["tab"], Job["path_key"])
		if Job["append_newline"] and !Ops.SendFinal("^{End}{Enter}")
			throw Error("final note input was refused")
		_TakeNoteFinish(JobId, Job)
	} catch as Err {
		if _TakeNoteFinish(JobId, Job)
			try Ops.ReportError(Err.Message)
	}
}
