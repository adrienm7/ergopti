; diagnostics/ui/field_check/field_report.ahk

; ==============================================================================
; MODULE: In-App Field Report (Windows)
; DESCRIPTION:
; Débogage's « Lancer le field report (tous les tests) »: a click hands the
; driver's own field run session its field check steps in-process
; (diagnostics/engine/field_run/field_run.ahk SubmitInApp; the session is started on
; demand on the installed folder when no clone opened one), so the run is the
; field report's own, with no clone and no collector: the same steps,
; verdicts and result files. The shared progress window (_shared/ui/field_report/,
; FieldReportWindow below) shows each step as it goes; when the run ends it
; holds the report, opens its folder in Explorer, copies it and opens the
; GitHub issue form, and one evidence line goes to the log.
;
; FEATURES & RATIONALE:
; 1. The report reads as the macOS and Linux one
;    (_shared/diagnostics/engine/field_check/field_report.lua): the verdict
;    counts, each step's verdict, the steps not run here with their reason,
;    the Tests rows a person runs separately, and the folder of the result
;    files to attach to an issue. Windows has no field_todo_coverage.json yet,
;    so a step names no field point.
; 2. The window behaves as the macOS and Linux ones
;    (macos/diagnostics/ui/field_check/field_report_progress.lua,
;    linux/diagnostics/ui/field_check/field_report.lua): a page that loads late
;    gets the step states so far; the page names actions only; « Create a
;    GitHub issue » goes through HealthCheck_ReportFieldRun (the evidence line
;    in the form, the redacted report on the clipboard); closing the window
;    during the run cancels it (CancelInApp, closed as interrupted). Without
;    WebView2 the run goes on and its report opens in the one-click dialog.
; 3. Nothing is pushed or committed: the results stay in the session folder.
; 4. One run at a time: a click while it runs only says so.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Logger tag of every line the report writes.
global FIELD_REPORT_TAG := "FieldReport"

; Locale key of the row and of the report's title (the row's own label).
global FIELD_REPORT_TITLE := "menu.debug." . MenuCommand.FIELD_REPORT

; The verdicts of the shared protocol, in the order the counts read.
global FIELD_REPORT_VERDICTS := ["pass", "fail", "timeout", "skip", "needs_person", "needs_typing"]

; The Windows Tests rows and the field run check each runs alone, as the Debug
; menu wires them (_MI_BuildDebuggingMenu); a probe the field run has no step
; for maps to "". A row whose check no step of the run takes is run separately.
; The two input probes are steps since 2026-11-24 (maintainer), after a notice
; asking not to type.
FieldReport_RowChecks() {
	return Map(MenuCommand.FIELD_CHECK_NETWORK, "network", MenuCommand.COMPOSER_CHECK, "composer",
		MenuCommand.SEND_PROBE, "send_probe", MenuCommand.HOOK_PROBE, "hook_probe")
}





; ===========================
; ===========================
; ======= 2/ The text =======
; ===========================
; ===========================

; The mark of a verdict; an undeclared one is a defect of the caller.
_FieldReport_Mark(Verdict) {
	static Marks := Map("pass", "[OK]", "fail", "[X]", "timeout", "[T]", "skip", "[-]",
		"needs_person", "[?]", "needs_typing", "[K]")
	if !Marks.Has(Verdict)
		throw ValueError("Field report: undeclared verdict.", -1, Verdict)
	return Marks[Verdict]
}

/**
 * Builds the summary of one in-app run.
 * @param {Array} Results - The step results the observer received, in order.
 * @param {Array} NotRun - Maps "step", "reason" the session left out.
 * @param {Array} Steps - The steps the run took.
 * @param {Map} Done - "request_id", "interrupted".
 * @param {String} Dir - The results folder.
 * @returns {Map}
 */
FieldReport_Summary(Results, NotRun, Steps, Done, Dir) {
	Counts := Map(), Passed := !Done["interrupted"]
	for Result in Results {
		Counts[Result["verdict"]] := Counts.Get(Result["verdict"], 0) + 1
		if Result["verdict"] != "pass" && Result["verdict"] != "skip"
			Passed := false
	}
	Taken := Map()
	for Step in Steps
		Taken[Step["check"]] := Step["id"]
	Rows := Map(), Separate := []
	for Row, Check in FieldReport_RowChecks() {
		if Check != "" && Taken.Has(Check)
			Rows[Taken[Check]] := Row
		else
			Separate.Push(Row)
	}
	return Map("passed", Passed, "interrupted", Done["interrupted"], "counts", Counts, "results", Results,
		"not_run", NotRun, "separate", Separate, "rows", Rows, "dir", Dir, "request_id", Done["request_id"])
}

/**
 * The one evidence line, in the macOS and Linux grammar:
 * check=field_report verdict=fail request=app-… pass=2 fail=1 not_run=1 field_network=pass …
 * @param {Map} Summary - From FieldReport_Summary.
 * @returns {String}
 */
FieldReport_LogLine(Summary) {
	global FIELD_REPORT_VERDICTS
	Parts := ""
	for Verdict in FIELD_REPORT_VERDICTS
		if Summary["counts"].Has(Verdict)
			Parts .= " " . Verdict . "=" . Summary["counts"][Verdict]
	Parts .= " not_run=" . Summary["not_run"].Length
	for Result in Summary["results"]
		Parts .= " " . Result["step"] . "=" . Result["verdict"]
	Verdict := Summary["interrupted"] ? "interrupted" : Summary["passed"] ? "pass" : "fail"
	return "check=field_report verdict=" . Verdict . " request=" . Summary["request_id"] . Parts
}

/**
 * The window and clipboard text: the verdict and the counts, each step with its
 * own report beneath it, the steps not run with their reason, the rows to run
 * separately and the folder. A step a Tests row also runs alone reads as that
 * row's sentences; another step reads as its closed codes.
 * @param {Map} Summary - From FieldReport_Summary.
 * @param {Func} TranslateFn - Locale key -> text.
 * @returns {String}
 */
FieldReport_Text(Summary, TranslateFn) {
	global FIELD_REPORT_VERDICTS
	Indent := "    "
	Key := Summary["interrupted"] ? "field_check.all.interrupted"
		: Summary["passed"] ? "field_check.all.verdict_pass" : "field_check.all.verdict_fail"
	Counts := ""
	for Verdict in FIELD_REPORT_VERDICTS
		if Summary["counts"].Has(Verdict)
			Counts .= (Counts == "" ? "" : " · ") . _FieldReport_Mark(Verdict) . " " . Summary["counts"][Verdict]
	if Summary["not_run"].Length > 0
		Counts .= (Counts == "" ? "" : " · ") . "[-] " . Summary["not_run"].Length
	Text := TranslateFn.Call(Key) . "`n" . Counts
	for Result in Summary["results"] {
		Row := Summary["rows"].Get(Result["step"], "")
		Heading := Row == "" ? Result["step"] : TranslateFn.Call("menu.debug." . Row) . " — " . Result["step"]
		Text .= "`n`n" . _FieldReport_Mark(Result["verdict"]) . " " . Heading
		Report := Result["report"]
		if (Row != "") && (Report is Map) && Report.Has("steps") {
			; The row's own text, without its verdict line and the blank line after it
			Lines := StrSplit(ComposerCheck_Text(Report, TranslateFn), "`n")
			loop Lines.Length - 2
				Text .= "`n" . Indent . Lines[A_Index + 2]
		} else if Result["codes"].Length > 0 {
			Joined := ""
			for Code in Result["codes"]
				Joined .= (Joined == "" ? "" : ", ") . Code
			Text .= "`n" . Indent . Joined
		}
	}
	if Summary["not_run"].Length > 0 {
		Text .= "`n`n" . TranslateFn.Call("field_check.all.not_run_header")
		for Item in Summary["not_run"]
			Text .= "`n" . LabelValue("[-] " . Item["step"], TranslateFn.Call("field_check.all.reason." . Item["reason"]),
				TranslateFn)
	}
	if Summary["separate"].Length > 0 {
		Text .= "`n`n" . TranslateFn.Call("field_check.all.separate_header")
		for Row in Summary["separate"]
			Text .= "`n[-] " . TranslateFn.Call("menu.debug." . Row)
	}
	Text .= "`n`n" . StrReplace(TranslateFn.Call("field_check.all.saved_in"), "{1}", Summary["dir"])
	Text .= "`n" . TranslateFn.Call("field_check.all.attach")
	return Text
}





; ====================================
; ====================================
; ======= 3/ The page messages =======
; ====================================
; ====================================

; The actions the page may send.
global FIELD_REPORT_ACTIONS := Map("cancel", true, "close", true, "open_folder", true, "copy", true, "issue", true)

/**
 * The init message: the steps of the run with their state so far, the steps
 * not run here and the label of the open-folder button.
 * @param {Map} Run - "steps", "not_run" as SubmitInApp returns it.
 * @param {Map} States - Step id -> "running" or a verdict; absent is pending.
 * @param {Func} TitleFn - Step -> localized title, or "" for its id.
 * @returns {String} JSON.
 */
FieldReport_InitJson(Run, States, TitleFn) {
	Steps := ""
	for Step in Run["steps"] {
		Title := TitleFn.Call(Step)
		Steps .= (Steps == "" ? "" : ",") . '{"id":' . JsonStringLiteral(Step["id"]) . ',"title":'
			. JsonStringLiteral(Title == "" ? Step["id"] : Title) . ',"state":'
			. JsonStringLiteral(States.Get(Step["id"], "pending")) . "}"
	}
	NotRun := ""
	for Item in Run["not_run"]
		NotRun .= (NotRun == "" ? "" : ",") . '{"id":' . JsonStringLiteral(Item["step"]) . ',"reason":'
			. JsonStringLiteral(Item["reason"]) . "}"
	return '{"type":"init","steps":[' . Steps . '],"not_run":[' . NotRun
		. '],"open_key":"field_report.open_explorer"}'
}

; One step's new state ("running" or a verdict of the shared protocol).
FieldReport_StepJson(Id, State) {
	return '{"type":"step","id":' . JsonStringLiteral(Id) . ',"state":' . JsonStringLiteral(State) . "}"
}

; The end of the run: its verdict, its counts and its folder.
FieldReport_DoneJson(Summary) {
	Counts := ""
	for Verdict, Count in Summary["counts"]
		Counts .= (Counts == "" ? "" : ",") . JsonStringLiteral(Verdict) . ":" . Count
	return '{"type":"done","passed":' . (Summary["passed"] ? "true" : "false")
		. ',"interrupted":' . (Summary["interrupted"] ? "true" : "false")
		. ',"counts":{' . Counts . '},"folder":' . JsonStringLiteral(Summary["dir"]) . "}"
}

; The outcome of an action.
FieldReport_ActionJson(Action, Ok) {
	return '{"type":"action","action":' . JsonStringLiteral(Action) . ',"ok":' . (Ok ? "true" : "false") . "}"
}





; ===============================
; ===============================
; ======= 4/ The progress =======
; ===============================
; ===============================

; The progress of one in-app run as its window shows it: fed by the observer,
; replayed to a page that loads late, and the actions of its buttons.
class FieldReportProgress {
	/**
	 * @param {Map} Effects - "open_folder" (Dir) -> Boolean, "copy" (Text) -> Boolean,
	 *   "issue" (Line, Text) -> Boolean (HealthCheck_ReportFieldRun).
	 * @param {Func} TitleFn - Step -> localized title, or "".
	 * @param {Func} CancelFn - () -> Boolean, the session's CancelInApp.
	 */
	__New(Effects, TitleFn, CancelFn) {
		for Name in ["open_folder", "copy", "issue"]
			if !Effects.Has(Name)
				throw ValueError("Field report window: no effect.", -1, Name)
		this.Effects := Effects
		this.TitleFn := TitleFn
		this.CancelFn := CancelFn
		this.Run := 0
		this.States := Map()
		this.Done := ""
		this.Summary := 0
		this.Text := ""
		this.Window := 0
		this.Ready := false
	}

	; Records the run the session admitted.
	Attach(Run) {
		if IsObject(this.Run)
			throw Error("Field report window: a run is already attached.")
		this.Run := Run
	}

	; Gives the progress its window (Push(Json) -> Boolean, Close()).
	Bind(Window) {
		if IsObject(this.Window)
			throw Error("Field report window: a window is already bound.")
		this.Window := Window
	}

	; Forgets a window that never opened, without touching the run: the run
	; goes on and its report opens in the one-click dialog.
	Detach(Window) {
		if this.Window !== Window
			return
		this.Window := 0
		this.Ready := false
	}

	; Pushes one message when the page is up; it is replayed at ready otherwise.
	_Push(Json) {
		if !IsObject(this.Window) || !this.Ready
			return false
		return this.Window.Push(Json) ? true : false
	}

	Started(Step) {
		this.States[Step["id"]] := "running"
		this._Push(FieldReport_StepJson(Step["id"], "running"))
	}

	Recorded(Id, Verdict) {
		this.States[Id] := Verdict
		this._Push(FieldReport_StepJson(Id, Verdict))
	}

	Finished(Summary, Text) {
		this.Summary := Summary
		this.Text := Text
		this.Done := FieldReport_DoneJson(Summary)
		this._Push(this.Done)
	}

	; The page loaded: brings it up to date.
	OnReady() {
		if !IsObject(this.Run)
			return
		this.Ready := true
		this._Push(FieldReport_InitJson(this.Run, this.States, this.TitleFn))
		if this.Done != ""
			this._Push(this.Done)
	}

	; The window closed (its close box, its button or a replacement).
	OnClosed() {
		global FIELD_REPORT_TAG
		if !IsObject(this.Window)
			return
		this.Window := 0
		this.Ready := false
		if this._CancelRun()
			LoggerInfo(FIELD_REPORT_TAG, "The field report window closed during the run, which is cancelled.")
		LoggerInfo(FIELD_REPORT_TAG, "Field report window closed.")
	}

	; Cancels the run while it goes on.
	_CancelRun() {
		global FIELD_REPORT_TAG
		if (this.Done != "") || !IsObject(this.Run)
			return false
		Cancelled := this.CancelFn.Call() ? true : false
		if !Cancelled
			LoggerWarn(FIELD_REPORT_TAG, "The field report run could not be cancelled: it is not going on.")
		return Cancelled
	}

	/**
	 * One action of the page; an unknown one is refused, a failure answered.
	 * @param {String} Name
	 */
	OnAction(Name) {
		global FIELD_REPORT_ACTIONS, FIELD_REPORT_TAG
		if !(Name is String) || !FIELD_REPORT_ACTIONS.Has(Name) {
			LoggerWarn(FIELD_REPORT_TAG, "Refused a field report window message that is not one of its actions.")
			return
		}
		LoggerInfo(FIELD_REPORT_TAG, "Field report window action: {1}.", Name)
		try Ok := this._Perform(Name)
		catch as Err {
			LoggerError(FIELD_REPORT_TAG, "The field report window action '{1}' failed: {2}", Name, Err.Message)
			Ok := false
		}
		if !Ok || (Name != "cancel" && Name != "close")
			this._Push(FieldReport_ActionJson(Name, Ok))
	}

	_Perform(Name) {
		global FIELD_REPORT_TAG
		switch Name {
			case "cancel":
				this._CancelRun()
				return true
			case "close":
				Window := this.Window
				this.OnClosed()
				if IsObject(Window)
					Window.Close()
				return true
			case "open_folder":
				if !IsObject(this.Summary)
					throw Error("the run has no results folder yet")
				return this.Effects["open_folder"].Call(this.Summary["dir"]) ? true : false
			case "copy":
				if !IsObject(this.Summary)
					throw Error("the run has no report yet")
				Ok := this.Effects["copy"].Call(this.Text) ? true : false
				LoggerInfo(FIELD_REPORT_TAG, "Field report copy {1}.", Ok ? "done" : "refused")
				return Ok
			case "issue":
				if !IsObject(this.Summary)
					throw Error("the run has no report yet")
				Opened := this.Effects["issue"].Call(FieldReport_LogLine(this.Summary), this.Text) ? true : false
				if Opened
					LoggerSuccess(FIELD_REPORT_TAG, "Field report issue form opened.")
				else
					LoggerError(FIELD_REPORT_TAG, "The field report issue form could not be opened.")
				return Opened
		}
		throw Error("no handler for the action " . Name)
	}
}





; =============================
; =============================
; ======= 5/ The window =======
; =============================
; =============================

; The shared progress page in a WebView2 window: the WebViewHost base sizes it
; from the manifest entry, seeds the locale and tracks the reading choices
; (ReadingPrefs_Track). The page answers while paused: it only shows a run.
class FieldReportWindow extends WebViewHost {
	static Current := 0
	Owner := 0
	; Whether the window opened: one that never did is no close of the person's
	Opened := false

	/**
	 * Opens the window of one run; a window left open by a finished run is replaced.
	 * @param {FieldReportProgress} Owner
	 * @returns {Boolean} opened
	 */
	static Open(Owner) {
		global FIELD_REPORT_TAG
		Previous := FieldReportWindow.Current
		if IsObject(Previous) && !Previous.ResetDone
			Previous.Close()
		; Without WebView2 the user is told how to recover (maintainer decision 2026-11-21).
		if !WebView_RequireAvailable("field report window")
			return false
		LoggerStart(FIELD_REPORT_TAG, "Opening the field report window…")
		WebViewHost._LoadManifest()
		Host := FieldReportWindow()
		Host.AppId := "field_report" ; config-key-literal-ok: the window's app id, named like the menu row
		Host.Owner := Owner
		Host.Opts := Map("RunsWhilePaused", true,
			"OnReady", (ReadyHost) => ReadyHost._Owned("OnReady"),
			"OnMessage", (MessageHost, Message) => MessageHost._Owned("OnAction",
				(Message is Map) ? Message.Get("action", "") : ""))
		Owner.Bind(Host)
		FieldReportWindow.Current := Host
		try Built := Host._Build()
		catch as Err {
			LoggerError(FIELD_REPORT_TAG, "The field report window could not be created: {1}.", Err.Message)
			Built := false
		}
		if !Built {
			; The run goes on without it, and its report opens in the one-click dialog
			Owner.Detach(Host)
			Host.Close()
			LoggerError(FIELD_REPORT_TAG, "The field report window could not open.")
			return false
		}
		Host.Opened := true
		Host.Gui.OnEvent("Escape", (*) => Host._Owned("OnAction", "close"))
		LoggerSuccess(FIELD_REPORT_TAG, "Field report window opened.")
		return true
	}

	; Brings the open window back in front, for a click on the row while it runs.
	static BringToFront() {
		Current := FieldReportWindow.Current
		if !IsObject(Current) || Current.ResetDone || Current.CloseRequested || !Current.Gui
			return false
		WMPresentWindow(Current.Gui)
		return true
	}

	; Calls the owner while this window is still its own.
	_Owned(Method, Args*) {
		if !IsObject(this.Owner) || this.ResetDone || this.CloseRequested
			return
		this.Owner.%Method%(Args*)
	}

	; Pushes one message into this page.
	Push(Json) {
		if this.ResetDone || this.CloseRequested
			return false
		this.Eval("if(window.receiveFieldReport)window.receiveFieldReport(" . Json . ")")
		return true
	}

	; Closes the window and tells its owner once, whoever closed it; a window
	; that never opened tells nobody (the build's own cleanup closes it too).
	Close() {
		Owner := this.Owner
		this.Owner := 0
		if FieldReportWindow.Current == this
			FieldReportWindow.Current := 0
		if IsObject(Owner) && this.Opened
			Owner.OnClosed()
		super.Close()
	}
}





; ==========================
; ==========================
; ======= 6/ The run =======
; ==========================
; ==========================

; The real collaborators: the session, the notices, the window and its effects,
; and the one-click checks' dialog for a run without a window.
_FieldReport_DefaultDeps() {
	global FIELD_REPORT_TITLE
	return Map(
		"session", FieldRun_StartInApp,
		"notify", (Text) => NotifierSend(Text, Map("title", t(FIELD_REPORT_TITLE))),
		"busy", (Text) => Ui_MsgBox(Text, t(FIELD_REPORT_TITLE), "Icon!"),
		"window", (Owner) => FieldReportWindow.Open(Owner),
		"front", () => FieldReportWindow.BringToFront(),
		"show", 0,
		"effects", Map(
			"open_folder", _FieldReport_OpenFolder,
			"copy", CB_Write,
			"issue", (Line, Text) => HealthCheck_ReportFieldRun(Line, Text)))
}

; Opens the results folder in Explorer.
_FieldReport_OpenFolder(Dir) {
	global FIELD_REPORT_TAG
	try ShellRunner_OpenFolder(Dir)
	catch as Err {
		LoggerWarn(FIELD_REPORT_TAG, "Explorer could not open the results folder: {1}", Err.Message)
		return false
	}
	return true
}

; A step reads as the Tests row that also runs its check alone, else its id.
_FieldReport_StepTitle(Step) {
	Check := Step.Get("check", "")
	for Row, RowCheck in FieldReport_RowChecks()
		if (RowCheck != "") && (RowCheck == Check)
			return t("menu.debug." . Row)
	return ""
}

/**
 * Debug menu: « Lancer le field report (tous les tests) ». Hands the field run
 * session its steps and follows the run in the progress window.
 * @param {Map} Deps - Collaborators (tests) over the real ones: "session" (() ->
 *   session), "notify" (Text), "busy" (Text), "window" (Owner -> Boolean), "front"
 *   (() -> Boolean), "show" (Title, Text), "effects" (the window's).
 * @returns {Boolean} False when nothing started.
 */
FieldReport_Command(Deps := 0, *) {
	global FIELD_REPORT_TAG
	Real := _FieldReport_DefaultDeps()
	if (Deps is Map)
		for Key, Value in Deps
			Real[Key] := Value
	if _FieldReport_Busy() {
		LoggerWarn(FIELD_REPORT_TAG, "The field report refused: it is still running.")
		if !Real["front"].Call()
			Real["busy"].Call(t("field_check.busy"))
		return false
	}
	try Session := Real["session"].Call()
	catch as Err {
		LoggerError(FIELD_REPORT_TAG, "The field report cannot run: no field run session ({1}).", Err.Message)
		Real["busy"].Call(t("field_check.all.unavailable"))
		return false
	}
	State := {Results: [], Run: 0, Windowed: false}
	Progress := FieldReportProgress(Real["effects"], _FieldReport_StepTitle, () => Session.CancelInApp())
	Observer := Map(
		"step_started", (Index, Step) => Progress.Started(Step),
		"step_recorded", (Index, Step, Result) => (State.Results.Push(Result),
			Progress.Recorded(Result["step"], Result["verdict"])),
		"finished", _FieldReport_Finish.Bind(Real, Progress, State))
	_FieldReport_SetBusy(true)
	LoggerStart(FIELD_REPORT_TAG, "In-app field report started…")
	State.Run := Session.SubmitInApp(Observer, &Reason)
	if !IsObject(State.Run) {
		_FieldReport_SetBusy(false)
		LoggerWarn(FIELD_REPORT_TAG, "The field report refused by the field run session: {1}.", Reason)
		Real["busy"].Call(t(Reason == "busy" ? "field_check.busy" : "field_check.all.unavailable"))
		return false
	}
	Progress.Attach(State.Run)
	State.Windowed := Real["window"].Call(Progress) ? true : false
	if !State.Windowed {
		LoggerWarn(FIELD_REPORT_TAG, "The field report window could not open; the run goes on without it.")
		Real["notify"].Call(StrReplace(t("field_check.all.started"), "{1}", State.Run["steps"].Length))
	}
	return true
}

; Logs the evidence line and hands the report to the window once the run ended,
; or to the one-click checks' dialog when no window opened.
_FieldReport_Finish(Deps, Progress, State, Done, Dir) {
	global FIELD_REPORT_TAG, FIELD_REPORT_TITLE
	_FieldReport_SetBusy(false)
	Summary := FieldReport_Summary(State.Results, State.Run["not_run"], State.Run["steps"], Done, Dir)
	LoggerEvidence(FIELD_REPORT_TAG, "Field report result: {1}", FieldReport_LogLine(Summary))
	LoggerSuccess(FIELD_REPORT_TAG, "In-app field report finished: {1}.",
		Summary["interrupted"] ? "interrupted" : Summary["passed"] ? "pass" : "fail")
	Text := FieldReport_Text(Summary, t)
	Progress.Finished(Summary, Text)
	if !State.Windowed {
		LoggerWarn(FIELD_REPORT_TAG, "The field report window is not open; the report opens in a dialog.")
		ComposerCheck_ShowText(Text, Deps["show"], FIELD_REPORT_TITLE)
	}
}

/**
 * The busy flag of the one in-app run: true while it goes on. A re-entrancy
 * flag that starts false, held in this function rather than a module global,
 * so there is no initialization for a state guard to wait on.
 * @param {Boolean} Value - The new state; omitted, the flag is only read.
 * @returns {Boolean} The flag after the call.
 */
_FieldReport_Busy(Value := unset) {
	static Busy := false
	if IsSet(Value)
		Busy := Value
	return Busy
}

; Sets the busy flag of the one run.
_FieldReport_SetBusy(Value) {
	_FieldReport_Busy(Value)
}
