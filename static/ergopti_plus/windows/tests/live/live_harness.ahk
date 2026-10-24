; tests/live/live_harness.ahk

; ==============================================================================
; MODULE: Live Driver Harness
; DESCRIPTION:
; Serves commands to a REAL ErgoptiPlus.ahk booted in an isolated profile by
; tools/maintainer/windows-live-checks.cjs. The driver reaches ready, calls the
; startup smoke's inspection hook (this file's LiveServe), and instead of
; exiting it keeps pumping messages while it executes one command at a time
; from a file the orchestrator writes. A command acts on the live process: it
; walks the real native tray tree, clicks a row with the same WM_COMMAND the
; shell sends, drives the dialogs and windows the click opens, and reports one
; line. Nothing here replaces a driver function with a stub.
;
; FEATURES & RATIONALE:
; 1. File protocol, no sockets: <dir>\live\cmd.txt holds "id<TAB>name<TAB>args";
;    the driver consumes it and writes <dir>\live\res-<id>.txt atomically. A
;    reload replaces the process, so the orchestrator waits for the successor's
;    <dir>\live\alive.txt (a new pid) and goes on with the same protocol.
; 2. A tray click that opens a modal dialog blocks the thread it started, and
;    the thread that was interrupted cannot resume meanwhile: the dialog is
;    therefore driven by a timer armed before the click (LiveDriveWindow).
; 3. The isolated profile is the startup smoke's: LOCALAPPDATA and the smoke
;    directory name a scratch folder, so no maintainer file is read or written.
; ==============================================================================

#Requires AutoHotkey v2.0

global LIVE_POLL_MS := 25
global LIVE_DEFAULT_TIMEOUT_MS := 20000
global _LiveCommands := Map()
global _LiveStopped := false





; ====================================
; ====================================
; ======= 1/ Files and results =======
; ====================================
; ====================================

/** The folder of the command protocol, created on first use. */
LiveDir() {
	Dir := EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\live"
	if !DirExist(Dir)
		DirCreate(Dir)
	return Dir
}

/** Replaces Path with Text through a staged file, so a reader never sees half of it. */
LiveWrite(Path, Text) {
	Stage := Path . ".tmp" . ProcessExist()
	File := FileOpen(Stage, "w", "UTF-8-RAW")
	File.Write(Text)
	File.Close()
	; The orchestrator may be reading the previous answer at this very moment.
	loop 40 {
		try {
			FileMove(Stage, Path, true)
			return
		} catch as Err {
			if A_Index == 40
				throw Err
			Sleep(50)
		}
	}
}

/** Appends one line to the harness trace the orchestrator keeps with its report. */
LiveTrace(Line) {
	FileAppend(FormatTime(, "HH:mm:ss") . " [" . ProcessExist() . "] " . Line . "`n",
		LiveDir() . "\trace.log", "UTF-8-RAW")
}

/** A value on one line: tabs, line breaks and the protocol's separators removed. */
LiveOneLine(Value) {
	return StrReplace(StrReplace(StrReplace(String(Value), "`t", " "), "`r", " "), "`n", " ")
}





; =============================
; =============================
; ======= 2/ Serve loop =======
; =============================
; =============================

/** Registers a command the orchestrator can run: Fn(Args) returns a detail string or throws. */
LiveRegister(Name, Fn) {
	global _LiveCommands
	if _LiveCommands.Has(Name)
		throw Error("The live command '" . Name . "' is already registered.")
	_LiveCommands[Name] := Fn
}

/** The startup smoke's inspection hook: serves commands until a stop file appears. */
LiveServe(*) {
	global _LiveStopped
	Dir := LiveDir()
	LiveWrite(Dir . "\alive.txt", ProcessExist() . "`n")
	LiveTrace("serving")
	while !_LiveStopped && !FileExist(Dir . "\stop.txt") {
		if FileExist(Dir . "\cmd.txt") {
			; A file another process holds for a moment must not end the loop: the
			; orchestrator would wait for a driver that no longer serves.
			try _LiveRunOne(Dir)
			catch as Err {
				LiveTrace("serve error: " . LiveOneLine(Err.Message))
				Sleep(100)
			}
		} else
			Sleep(LIVE_POLL_MS)
	}
	LiveTrace("stopped")
}

/**
 * The startup smoke's shell hook: the complete root is published and input is
 * not ready yet, which is the moment a user can click a row "during startup".
 * Runs the clicks the orchestrator staged in <dir>\live\shell.txt, one "click"
 * line (tab-separated path specifiers, see LiveRowByPath) each, and consumes the
 * file so the successor of a reload does not click again.
 */
LiveShellHook(*) {
	Dir := LiveDir()
	if !FileExist(Dir . "\shell.txt")
		return
	Lines := StrSplit(RTrim(FileRead(Dir . "\shell.txt", "UTF-8"), "`r`n"), "`n", "`r")
	FileDelete(Dir . "\shell.txt")
	Report := ""
	for Line in Lines {
		Parts := StrSplit(Line, "`t")
		if Parts.Length < 2 || Parts[1] != "click"
			continue
		Parts.RemoveAt(1)
		try {
			Row := LiveRowByPath(Parts)
			LiveClickRow(Row)
			Report .= "clicked`t" . Row.Caption . "`n"
		} catch as Err
			Report .= "failed`t" . LiveOneLine(Err.Message) . "`n"
		LivePump(150)
	}
	LiveWrite(Dir . "\shell-result.txt", Report)
}

_LiveRunOne(Dir) {
	global _LiveCommands
	Text := FileRead(Dir . "\cmd.txt", "UTF-8")
	FileDelete(Dir . "\cmd.txt")
	Parts := StrSplit(RTrim(Text, "`r`n"), "`t")
	Id := Parts[1]
	Name := Parts.Length >= 2 ? Parts[2] : ""
	Args := Parts.Length >= 3 ? Parts.Clone() : []
	if Args.Length >= 2
		Args.RemoveAt(1, 2)
	LiveTrace("command " . Id . " " . Name)
	try {
		if !_LiveCommands.Has(Name)
			throw Error("unknown live command '" . Name . "'")
		Detail := _LiveCommands[Name].Call(Args)
		Result := "ok`t" . LiveOneLine(Detail)
	} catch as Err {
		Result := "fail`t" . LiveOneLine(Err.Message . " @ " . Err.What . ":" . Err.Line)
	}
	LiveWrite(Dir . "\res-" . Id . ".txt", Result . "`n")
	LiveTrace("result " . Id . " " . SubStr(Result, 1, 160))
}





; ==========================
; ==========================
; ======= 3/ Waiting =======
; ==========================
; ==========================

/** Pumps messages until Predicate returns a truthy value; returns it, or throws on timeout. */
LiveWaitFor(Predicate, What, TimeoutMs := 0) {
	global LIVE_DEFAULT_TIMEOUT_MS
	Limit := TimeoutMs ? TimeoutMs : LIVE_DEFAULT_TIMEOUT_MS
	Started := A_TickCount
	loop {
		Value := Predicate.Call()
		if Value
			return Value
		if A_TickCount - Started > Limit
			throw Error("timed out after " . Limit . " ms waiting for " . What)
		Sleep(10)
	}
}

/** Pumps messages for Ms milliseconds so queued timers and menu commands run. */
LivePump(Ms) {
	Started := A_TickCount
	while A_TickCount - Started < Ms
		Sleep(5)
}

/**
 * Drives a window that a click is about to open, from a timer, because the
 * thread that opens a modal dialog cannot let this one resume until it closes.
 * @param {String|Func} Match WinTitle criteria of the window, or a function
 *     returning the handle of the window to drive (0 while there is none).
 * @param {Func} Action Called with the window's hwnd once it exists.
 * @param {Integer} TimeoutMs How long to wait for the window; the default when 0.
 * @param {Boolean} Optional True when the window may never come (not an error).
 * @returns {Object} State whose Done and Error members the caller waits on.
 */
LiveDriveWindow(Match, Action, TimeoutMs := 0, Optional := false) {
	global LIVE_DEFAULT_TIMEOUT_MS
	State := {Done: false, Error: "", Hwnd: 0, Started: A_TickCount, Optional: Optional,
		Limit: TimeoutMs ? TimeoutMs : LIVE_DEFAULT_TIMEOUT_MS}
	Tick := _LiveDriveTick.Bind(State, Match, Action)
	State.Tick := Tick
	SetTimer(Tick, 40)
	return State
}

_LiveDriveTick(State, Match, Action, *) {
	if State.Done {
		SetTimer(State.Tick, 0)
		return
	}
	if A_TickCount - State.Started > State.Limit {
		if !State.Optional
			State.Error := "no window matched '" . (HasMethod(Match, "Call") ? "the watched window" : Match)
				. "' within " . State.Limit . " ms"
		State.Done := true
		SetTimer(State.Tick, 0)
		return
	}
	Hwnd := HasMethod(Match, "Call") ? Match.Call() : WinExist(Match)
	if !Hwnd
		return
	SetTimer(State.Tick, 0)
	State.Hwnd := Hwnd
	try Action.Call(Hwnd)
	catch as Err
		State.Error := Err.Message
	State.Done := true
}

/** Waits for a LiveDriveWindow state to finish and throws what it recorded. */
LiveAwaitDrive(State, What) {
	LiveWaitFor(() => State.Done, What, State.Limit + 5000)
	if State.Error != ""
		throw Error(What . ": " . State.Error)
}





; ================================
; ================================
; ======= 4/ The tray tree =======
; ================================
; ================================

/**
 * Flattens the live native tray tree into rows, completing every deferred
 * submenu on the way as opening it would.
 * @returns {Array} Objects with Path (captions from the root), Caption, Id,
 *     Handle, Pos (zero-based), Flags, IsSub.
 */
LiveTrayRows() {
	Rows := []
	_LiveWalk(A_TrayMenu.Handle, [], Rows, Map())
	return Rows
}

_LiveWalk(Handle, Path, Rows, Seen) {
	global _MenuPopulationPublished
	if Seen.Has(Handle)
		return
	Seen[Handle] := true
	if IsSet(_MenuPopulationPublished) && _MenuPopulationPublished is MenuPopulation
		_MenuPopulationPublished.Complete(Handle, "live check")
	Count := TrayMenuHandleItemCount(Handle)
	loop Count {
		Pos := A_Index - 1
		Caption := TrayMenuHandleItemCaption(Handle, Pos)
		Flags := TrayMenuHandleItemState(Handle, Pos)
		Sub := TrayMenuSubmenuHandle(Handle, Pos)
		Row := {Path: _LiveAppend(Path, Caption), Caption: Caption, Id: TrayMenuHandleItemId(Handle, Pos),
			Handle: Handle, Pos: Pos, Flags: Flags, IsSub: Sub != 0}
		Rows.Push(Row)
		if Sub
			_LiveWalk(Sub, Row.Path, Rows, Seen)
	}
}

_LiveAppend(Path, Caption) {
	Copy := Path.Clone()
	Copy.Push(Caption)
	return Copy
}

/** The rows whose caption matches the regular expression, optionally under a path prefix. */
LiveFindRows(CaptionPattern, UnderPattern := "") {
	Found := []
	for Row in LiveTrayRows() {
		if Row.IsSub || Row.Caption == "" || !RegExMatch(Row.Caption, CaptionPattern)
			continue
		if UnderPattern != "" {
			Under := ""
			for Index, Part in Row.Path
				if Index < Row.Path.Length
					Under .= Part . " > "
			if !RegExMatch(Under, UnderPattern)
				continue
		}
		Found.Push(Row)
	}
	return Found
}

/** The one row that matches, or an error naming how many did. */
LiveOneRow(CaptionPattern, UnderPattern := "") {
	Found := LiveFindRows(CaptionPattern, UnderPattern)
	if Found.Length != 1
		throw Error(Found.Length . " tray rows match '" . CaptionPattern . "' under '" . UnderPattern . "'")
	return Found[1]
}

/**
 * The one leaf row a path of level specifiers reaches. A specifier is an exact
 * caption, "re:" followed by a regular expression, or "t:" followed by a locale key.
 */
LiveRowByPath(Specifiers) {
	Rows := LiveTrayRows()
	Matches := []
	for Row in Rows {
		if Row.IsSub || Row.Path.Length != Specifiers.Length
			continue
		Fits := true
		for Index, Part in Row.Path {
			if !_LiveSpecifierFits(Specifiers[Index], Part) {
				Fits := false
				break
			}
		}
		if Fits
			Matches.Push(Row)
	}
	if Matches.Length != 1
		throw Error(Matches.Length . " leaf rows match the path")
	return Matches[1]
}

_LiveSpecifierFits(Specifier, Caption) {
	if SubStr(Specifier, 1, 3) == "re:"
		return RegExMatch(Caption, SubStr(Specifier, 4))
	if SubStr(Specifier, 1, 2) == "t:"
		return Caption == t(SubStr(Specifier, 3))
	return Caption == Specifier
}

/** Clicks a leaf row with the WM_COMMAND the shell posts; the command runs on a new thread. */
LiveClickRow(Row) {
	if Row.IsSub || Row.Id == 0xFFFFFFFF || Row.Id == 0
		throw Error("'" . Row.Caption . "' is not a command row")
	if Row.Flags & 0x3
		throw Error("'" . Row.Caption . "' is disabled or grayed")
	; WM_COMMAND to the main window, which is hidden: a title search would not find it.
	if !DllCall("PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x111, "UPtr", Row.Id, "Ptr", 0, "Int")
		throw OSError(A_LastError, A_ThisFunc, "The tray command could not be posted.")
}

/** Whether a row is checked, read from the native menu. */
LiveRowChecked(Row) {
	return !!(TrayMenuHandleItemState(Row.Handle, Row.Pos) & 0x8)
}

/** The handle of a dialog of this process whose caption matches a regular expression, or 0. */
LiveDialogMatching(Pattern) {
	for Hwnd in WinGetList("ahk_class #32770 ahk_pid " . ProcessExist()) {
		if RegExMatch(WinGetTitle("ahk_id " . Hwnd), Pattern)
			return Hwnd
	}
	return 0
}

/** The visible, titled top-level windows of this process, keyed by handle. */
LiveVisibleWindows() {
	Seen := Map()
	for Hwnd in WinGetList("ahk_pid " . ProcessExist()) {
		if (WinGetStyle("ahk_id " . Hwnd) & 0x10000000) && WinGetTitle("ahk_id " . Hwnd) != ""
			Seen[Hwnd] := true
	}
	return Seen
}

/** The handle of a visible titled window that Before did not hold, or 0. */
LiveNewWindow(Before) {
	for Hwnd, _ in LiveVisibleWindows() {
		if !Before.Has(Hwnd)
			return Hwnd
	}
	return 0
}

/** The windows of this process that are dialogs or error windows, as "title|class" strings. */
LiveDialogs() {
	Found := []
	for Hwnd in WinGetList("ahk_pid " . ProcessExist()) {
		if WinGetClass("ahk_id " . Hwnd) == "#32770"
			Found.Push(WinGetTitle("ahk_id " . Hwnd))
	}
	return Found
}
