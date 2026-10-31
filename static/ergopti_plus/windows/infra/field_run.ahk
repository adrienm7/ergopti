; infra/field_run.ahk

; ==============================================================================
; MODULE: Developer Field Run (Windows)
; DESCRIPTION:
; Runs the driver's Debug tray checks for tools/dev/collect-windows-field-report.ps1
; with no person: the collector writes a request file in the clone's field run
; folder, this developer driver picks it up, runs each declared step without
; its window, writes one result per step and a done marker, and the collector
; copies them. The protocol (files, verdicts, refusal reasons, identifiers,
; required keys) is _shared/data/field_run_protocol.json, the one the macOS
; field run (macos/infra/field_run.lua) and the Linux one implement; the steps
; are windows/data/field_run_steps.json.
;
; FEATURES & RATIONALE:
; 1. Developer source mode only, like macOS: an installed driver never runs
;    checks a file in a folder asked for, and the composer check installs and
;    removes a layout.
; 2. One run at a time. A request arriving while a run is going is refused as
;    busy, a request whose results folder exists as a duplicate, and a request
;    that does not parse names its reason in refused.json.
; 3. Every step settles once: its own deadline (never past the request's) is a
;    timeout verdict, a late answer is logged and dropped, a step that raises
;    fails with the code "raised".
; 4. Closed values only: a code outside the protocol's code grammar is written
;    as "redacted", so no path, URL or user text reaches a result file.
; 5. Each file is replaced whole (a staged copy then one rename), so the
;    collector never reads half a result.
; ==============================================================================

#Requires AutoHotkey v2.0

; 0 until FieldRun_Start creates the session: the init guard of FieldRun_Stop.
global _FieldRun := 0

; Logger tag of every line the field run writes.
global FIELD_RUN_TAG := "FieldRun"

; A JSON value written as it is (true, false), which an AHK value cannot carry.
class FieldRunJsonLiteral {
	__New(Text) {
		this.Text := Text
	}
}





; ==============================
; ==============================
; ======= 1/ Declaration =======
; ==============================
; ==============================

/**
 * Reads and checks the shared protocol; a malformed one stops the caller.
 * @param {String} Path - field_run_protocol.json.
 * @returns {Map}
 */
FieldRun_LoadProtocol(Path) {
	Text := FSReadUtf8Exact(Path)
	if !(Text is String)
		throw Error("The field run protocol could not be read: " . Path)
	Spec := JsonParse(Text)
	if !(Spec is Map) || Spec.Get("schema", 0) != 1
		throw Error("The field run protocol has an unsupported shape.")
	for Key in ["files", "max_request_bytes", "request_id_pattern", "step_id_pattern", "code_pattern",
			"verdicts", "reasons", "step_kinds", "folder", "steps_file", "all_steps"]
		if !Spec.Has(Key)
			throw Error("The field run protocol lacks " . Key . ".")
	for Kind in ["ready", "request", "refused", "running", "results", "accepted", "done"]
		if !(Spec["files"] is Map) || !RegExMatch(Spec["files"].Get(Kind, ""), "^[A-Za-z0-9_.]+$")
			throw Error("The field run file " . Kind . " must be a plain name.")
	if !(Spec["max_request_bytes"] is Integer) || Spec["max_request_bytes"] < 128
		throw Error("The field run request bound must be an integer of at least 128 bytes.")
	Spec["verdict_set"] := _FieldRun_NameSet(Spec["verdicts"], "verdicts")
	Spec["reason_set"] := _FieldRun_NameSet(Spec["reasons"], "reasons")
	Spec["kind_set"] := _FieldRun_NameSet(Spec["step_kinds"], "step_kinds")
	for Verdict in ["pass", "fail", "timeout"]
		if !Spec["verdict_set"].Has(Verdict)
			throw Error("The field run verdict " . Verdict . " is not declared.")
	for Reason in ["malformed", "unknown_step", "bad_deadline", "busy", "duplicate_request"]
		if !Spec["reason_set"].Has(Reason)
			throw Error("The field run refusal reason " . Reason . " is not declared.")
	return Spec
}

; A set of unique nonempty names; a duplicate or empty name stops the caller.
_FieldRun_NameSet(Names, Label) {
	if !(Names is Array) || Names.Length == 0
		throw Error("The field run " . Label . " must be a nonempty list.")
	Set := Map()
	for Name in Names {
		if !(Name is String) || Name == "" || Set.Has(Name)
			throw Error("The field run " . Label . " hold an invalid or duplicate name.")
		Set[Name] := true
	}
	return Set
}

/**
 * Reads and checks this driver's steps; a step without a runner stops the caller.
 * @param {String} Path - windows/data/field_run_steps.json.
 * @param {Map} Spec - From FieldRun_LoadProtocol.
 * @param {Map} Runners - Check name -> runner.
 * @returns {Map} "steps" (Array of Map), "by_id" (Map), "deadline" (Map default, min, max).
 */
FieldRun_LoadSteps(Path, Spec, Runners) {
	Text := FSReadUtf8Exact(Path)
	if !(Text is String)
		throw Error("The field run steps could not be read: " . Path)
	Declared := JsonParse(Text)
	if !(Declared is Map) || !(Declared.Get("steps", 0) is Array) || Declared["steps"].Length == 0
		throw Error("The field run steps must be a nonempty list.")
	Deadline := Declared.Get("deadline_seconds", 0)
	if !(Deadline is Map)
		throw Error("The field run steps declare no request deadline.")
	for Key in ["default", "min", "max"]
		if !(Deadline.Get(Key, "") is Integer) || Deadline[Key] <= 0
			throw Error("The field run request deadline " . Key . " must be a positive integer.")
	if Deadline["min"] > Deadline["default"] || Deadline["default"] > Deadline["max"]
		throw Error("The field run request deadline default must lie between its min and max.")
	ById := Map()
	for Step in Declared["steps"] {
		Id := (Step is Map) ? Step.Get("id", "") : ""
		if !RegExMatch(Id, Spec["step_id_pattern"]) || Id == Spec["all_steps"] || ById.Has(Id)
			throw Error("The field run step identity " . Id . " is invalid or repeated.")
		if !Spec["kind_set"].Has(Step.Get("kind", "")) || Step["kind"] != "field_check"
			throw Error("The field run step " . Id . " has a kind this driver does not run.")
		if !Runners.Has(Step.Get("check", ""))
			throw Error("The field run step " . Id . " names a check without a runner.")
		if !(Step.Get("deadline_seconds", "") is Integer) || Step["deadline_seconds"] <= 0
			throw Error("The field run step " . Id . " has no positive deadline.")
		ById[Id] := Step
	}
	return Map("steps", Declared["steps"], "by_id", ById, "deadline", Deadline)
}

/**
 * Parses one request; a refusal sets Reason and returns 0.
 * @param {Map} Spec - The protocol.
 * @param {Map} Steps - From FieldRun_LoadSteps.
 * @param {Any} Text - The request file's text, or false when unreadable or too large.
 * @param {VarRef} Reason - Receives the refusal reason.
 * @param {VarRef} Echoed - Receives the request identifier when it is valid.
 * @returns {Map|Integer} "request_id", "steps" (Array of Map), "deadline_seconds"; 0 on a refusal.
 */
FieldRun_ParseRequest(Spec, Steps, Text, &Reason, &Echoed) {
	Reason := "malformed", Echoed := ""
	if !(Text is String) || Text == ""
		return 0
	try Request := JsonParse(Text)
	catch
		return 0
	if !(Request is Map)
		return 0
	Id := Request.Get("request_id", "")
	if (Id is String) && RegExMatch(Id, Spec["request_id_pattern"])
		Echoed := Id
	Names := Request.Get("steps", 0)
	if Request.Get("schema", 0) != Spec["schema"] || Echoed == "" || !(Names is Array) || Names.Length == 0
		return 0
	Deadline := Request.Has("deadline_seconds") ? Request["deadline_seconds"] : Steps["deadline"]["default"]
	if !(Deadline is Integer) || Deadline < Steps["deadline"]["min"] || Deadline > Steps["deadline"]["max"] {
		Reason := "bad_deadline"
		return 0
	}
	Chosen := []
	if Names.Length == 1 && Names[1] == Spec["all_steps"] {
		Chosen := Steps["steps"]
	} else {
		for Name in Names {
			if !(Name is String) || !Steps["by_id"].Has(Name) {
				Reason := "unknown_step"
				return 0
			}
			Chosen.Push(Steps["by_id"][Name])
		}
	}
	Reason := ""
	return Map("request_id", Echoed, "steps", Chosen, "deadline_seconds", Deadline)
}

/**
 * The code a check's report step becomes: id_state[:value], or "redacted".
 * @param {Map} Spec - The protocol.
 * @param {String} Text - The candidate code.
 * @returns {String}
 */
FieldRun_Code(Spec, Text) {
	return ((Text is String) && RegExMatch(Text, Spec["code_pattern"])) ? Text : "redacted"
}

; The verdict and codes of a finished tray check report (ComposerCheck_NewReport).
_FieldRun_ReportOutcome(Spec, Report, Done) {
	Codes := []
	for Step in Report["steps"]
		Codes.Push(FieldRun_Code(Spec, Step["id"] . "_" . Step["state"] . (Step["value"] != "" ? ":" . Step["value"] : "")))
	Done.Call(ComposerCheck_Passed(Report) ? "pass" : "fail", Codes)
}

/**
 * The runner of each declared check name: Runner(Spec, Done) calls
 * Done(Verdict, Codes) once, now or later.
 * @returns {Map}
 */
FieldRun_Runners() {
	return Map(
		"boot_cost", _FieldRun_RunBootCost,
		"network", (Spec, Done) => NetworkCheck_Run(_FieldRun_ReportOutcome.Bind(Spec, , Done))
			|| Done.Call("fail", ["busy"]),
		"composer", (Spec, Done) => ComposerCheck_Run(_FieldRun_ReportOutcome.Bind(Spec, , Done))
			|| Done.Call("fail", ["busy"]))
}

; The boot that started this driver, against [budgets] boot_total_ms.
_FieldRun_RunBootCost(Spec, Done) {
	Total := Round(BootProfile_TotalBootMs())
	Budget := TimingsGet("budgets", "boot_total_ms")
	Done.Call(Total <= Budget ? "pass" : "fail", ["boot_ms_" . Total, "budget_ms_" . Budget])
}





; ============================
; ============================
; ======= 2/ Documents =======
; ============================
; ============================

/**
 * Encodes a Map (in insertion order), an Array, a String, a number or a
 * FieldRunJsonLiteral as JSON.
 * @param {Any} Value
 * @returns {String}
 */
FieldRun_Json(Value) {
	if Value is FieldRunJsonLiteral
		return Value.Text
	if Value is Map {
		Parts := ""
		for Key, Item in Value
			Parts .= (Parts == "" ? "" : ",") . JsonStringLiteral(Key) . ":" . FieldRun_Json(Item)
		return "{" . Parts . "}"
	}
	if Value is Array {
		Parts := ""
		for Item in Value
			Parts .= (Parts == "" ? "" : ",") . FieldRun_Json(Item)
		return "[" . Parts . "]"
	}
	if Value is Number
		return String(Value)
	if Value is String
		return JsonStringLiteral(Value)
	throw TypeError("A field run document holds a value JSON cannot carry.")
}

; The current UTC time, as the macOS field run writes it.
_FieldRun_IsoNow() {
	return FormatTime(A_NowUTC, "yyyy-MM-dd") . "T" . FormatTime(A_NowUTC, "HH:mm:ss") . "Z"
}





; ==========================
; ==========================
; ======= 3/ Session =======
; ==========================
; ==========================

class FieldRunSession {
	/**
	 * @param {Map} Spec - The protocol.
	 * @param {Map} Steps - From FieldRun_LoadSteps.
	 * @param {String} Folder - The field run folder of the clone.
	 * @param {Integer} Pid - This process.
	 * @param {Map} Deps - "poll_ms", "runners".
	 */
	__New(Spec, Steps, Folder, Pid, Deps) {
		this.Spec := Spec
		this.Steps := Steps
		this.Folder := Folder
		this.Pid := Pid
		this.Deps := Deps
		this.Run := 0
		this.Timer := 0
		this.Started := false
	}

	Path(Kind) {
		return this.Folder . "\" . this.Spec["files"][Kind]
	}

	/** Prepares the folder, closes a run a reload cut short, then watches for requests. */
	Start() {
		if this.Started
			throw Error("The field run session cannot be started twice.")
		this.Started := true
		FSEnsureDirectoryStrict(this.Path("results"))
		this.CloseInterrupted()
		; A request left from an earlier session was written for a driver that is gone
		if FileExist(this.Path("request")) {
			LoggerWarn(FIELD_RUN_TAG, "A stale field run request was left by an earlier session; removed.")
			FSDelete(this.Path("request"))
		}
		this.Timer := ObjBindMethod(this, "Poll")
		SetTimer(this.Timer, this.Deps["poll_ms"])
		Ids := []
		for Step in this.Steps["steps"]
			Ids.Push(Step["id"])
		; Published last: it is the collector's readiness receipt
		this.Publish(this.Path("ready"), Map("schema", this.Spec["schema"], "driver", "windows",
			"pid", this.Pid, "steps", Ids))
	}

	/** Stops watching; a running run is closed as interrupted. */
	Stop() {
		if this.Timer
			SetTimer(this.Timer, 0)
		this.Timer := 0
		if IsObject(this.Run)
			this.Finish(true, "teardown")
		FSDelete(this.Path("ready"))
	}

	/** Closes the run an earlier session of this driver left open. */
	CloseInterrupted() {
		Path := this.Path("running")
		if !FileExist(Path)
			return
		Id := ""
		try {
			Running := JsonParse(FSReadUtf8Exact(Path))
			Id := (Running is Map) ? Running.Get("request_id", "") : ""
		}
		if (Id is String) && RegExMatch(Id, this.Spec["request_id_pattern"]) {
			Done := this.Path("results") . "\" . Id . "\" . this.Spec["files"]["done"]
			if DirExist(this.Path("results") . "\" . Id) && !FileExist(Done) {
				this.Publish(Done, Map("schema", this.Spec["schema"], "request_id", Id, "pid", this.Pid,
					"interrupted", FieldRunJsonLiteral("true"), "finished_at", _FieldRun_IsoNow(),
					"verdicts", Map(), "order", []))
				LoggerWarn(FIELD_RUN_TAG, "Field run {1} was cut short by a reload; closed as interrupted.", Id)
			}
		} else {
			LoggerWarn(FIELD_RUN_TAG, "An unreadable running marker was left by an earlier field run; removed.")
		}
		FSDelete(Path)
	}

	/** Timer: takes one request when no run is going. */
	Poll() {
		if IsObject(this.Run) || !FileExist(this.Path("request"))
			return
		try this.Handle()
		catch as Err
			LoggerError(FIELD_RUN_TAG, "The field run request could not be handled: {1}", Err.Message)
	}

	Handle() {
		Path := this.Path("request")
		Text := FSReadUtf8ExactBounded(Path, this.Spec["max_request_bytes"])
		FSDelete(Path)
		Request := FieldRun_ParseRequest(this.Spec, this.Steps, Text, &Reason, &Echoed)
		if !IsObject(Request)
			return this.Refuse(Echoed, Reason)
		Dir := this.Path("results") . "\" . Request["request_id"]
		if DirExist(Dir)
			return this.Refuse(Request["request_id"], "duplicate_request")
		DirCreate(Dir)
		this.Begin(Request, Dir)
	}

	Refuse(Id, Reason) {
		LoggerWarn(FIELD_RUN_TAG, "Field run request {1} refused: {2}.", Id == "" ? "without an identifier" : Id, Reason)
		this.Publish(this.Path("refused"), Map("schema", this.Spec["schema"], "request_id", Id, "reason", Reason))
	}

	Begin(Request, Dir) {
		Ids := []
		for Step in Request["steps"]
			Ids.Push(Step["id"])
		this.Run := {Request: Request, Dir: Dir, Index: 0, Verdicts: Map(), Order: [],
			StartedAt: _FieldRun_IsoNow(), StartTick: A_TickCount,
			DeadlineTick: A_TickCount + Request["deadline_seconds"] * 1000, ActiveStep: 0}
		this.Publish(this.Path("running"), Map("schema", this.Spec["schema"], "request_id", Request["request_id"]))
		this.Publish(Dir . "\" . this.Spec["files"]["accepted"], Map("schema", this.Spec["schema"],
			"request_id", Request["request_id"], "pid", this.Pid, "steps", Ids,
			"deadline_seconds", Request["deadline_seconds"], "started_at", this.Run.StartedAt))
		LoggerStart(FIELD_RUN_TAG, "Field run {1} started: {2} step(s) within {3} s.", Request["request_id"],
			Ids.Length, Request["deadline_seconds"])
		this.Next()
	}

	/** Starts the next step, or closes the run after the last one. */
	Next() {
		Active := this.Run
		if !IsObject(Active)
			return
		Active.Index += 1
		if Active.Index > Active.Request["steps"].Length
			return this.Finish(false)
		Step := Active.Request["steps"][Active.Index]
		LeftMs := Active.DeadlineTick - A_TickCount
		DeadlineMs := Min(Step["deadline_seconds"] * 1000, Max(LeftMs, 1))
		Token := {Step: Step, Settled: false, StartTick: A_TickCount, StartedAt: _FieldRun_IsoNow(),
			DeadlineMs: DeadlineMs, Timer: 0}
		Active.ActiveStep := Token
		LoggerInfo(FIELD_RUN_TAG, "Field run step {1}/{2} '{3}' started.", Active.Index, Active.Request["steps"].Length, Step["id"])
		if LeftMs <= 0
			return this.Settle(Token, "timeout", ["request_deadline"])
		Token.Timer := this.Settle.Bind(this, Token, "timeout", ["deadline_" . Floor(DeadlineMs / 1000) . "s"])
		SetTimer(Token.Timer, -DeadlineMs)
		Runner := this.Deps["runners"][Step["check"]]
		try Runner.Call(this.Spec, this.Settle.Bind(this, Token))
		catch as Err {
			LoggerError(FIELD_RUN_TAG, "Field run step '{1}' raised: {2}", Step["id"], Err.Message)
			this.Settle(Token, "fail", ["raised"])
		}
	}

	/** Records a step's verdict once, then starts the next step on a fresh thread. */
	Settle(Token, Verdict, Codes) {
		if Token.Settled {
			LoggerInfo(FIELD_RUN_TAG, "Field run step '{1}' answered {2} after it was settled; dropped.",
				Token.Step["id"], Verdict)
			return
		}
		Token.Settled := true
		if Token.Timer
			SetTimer(Token.Timer, 0)
		Active := this.Run
		if !IsObject(Active) || Active.ActiveStep !== Token
			return
		if !this.Spec["verdict_set"].Has(Verdict) {
			LoggerError(FIELD_RUN_TAG, "Field run step '{1}' gave an undeclared verdict {2}.", Token.Step["id"], Verdict)
			Verdict := "fail", Codes := ["undeclared_verdict"]
		}
		Clean := []
		for Code in (Codes is Array ? Codes : [])
			Clean.Push(FieldRun_Code(this.Spec, Code))
		Step := Token.Step
		this.Publish(Format("{1}\{2:02d}_{3}.json", Active.Dir, Active.Index, Step["id"]), Map(
			"schema", this.Spec["schema"], "request_id", Active.Request["request_id"], "index", Active.Index,
			"step", Step["id"], "kind", Step["kind"], "verdict", Verdict, "codes", Clean,
			"started_at", Token.StartedAt, "finished_at", _FieldRun_IsoNow(),
			"elapsed_ms", TickElapsed(Token.StartTick), "deadline_ms", Token.DeadlineMs))
		Active.Verdicts[Step["id"]] := Verdict
		Active.Order.Push(Step["id"])
		Joined := ""
		for Code in Clean
			Joined .= (Joined == "" ? "" : ",") . Code
		LoggerEvidence(FIELD_RUN_TAG, "Field run step result: step={1} verdict={2} codes={3}", Step["id"], Verdict,
			Joined == "" ? "none" : Joined)
		SetTimer(ObjBindMethod(this, "Next"), -1)
	}

	/** Publishes the done marker and frees the session for the next request. */
	Finish(Interrupted, Cause := "") {
		Active := this.Run
		this.Run := 0
		if Active.ActiveStep && Active.ActiveStep.Timer
			SetTimer(Active.ActiveStep.Timer, 0)
		Counts := Map()
		for _, Verdict in Active.Verdicts
			Counts[Verdict] := Counts.Get(Verdict, 0) + 1
		Done := Map("schema", this.Spec["schema"], "request_id", Active.Request["request_id"], "pid", this.Pid,
			"interrupted", FieldRunJsonLiteral(Interrupted ? "true" : "false"), "started_at", Active.StartedAt,
			"finished_at", _FieldRun_IsoNow(), "elapsed_ms", TickElapsed(Active.StartTick),
			"verdicts", Active.Verdicts, "counts", Counts, "order", Active.Order)
		if Interrupted
			Done["cause"] := Cause
		this.Publish(Active.Dir . "\" . this.Spec["files"]["done"], Done)
		FSDelete(this.Path("running"))
		if Interrupted
			LoggerWarn(FIELD_RUN_TAG, "Field run {1} cut short by a {2}; closed as interrupted.", Active.Request["request_id"], Cause)
		else
			LoggerSuccess(FIELD_RUN_TAG, "Field run {1} finished.", Active.Request["request_id"])
	}

	; Each file is replaced whole, so the collector never reads half a document.
	Publish(Target, Document) {
		Stage := Target . ".tmp-" . this.Pid
		if !FSWriteDurable(Stage, FieldRun_Json(Document) . "`n")
			throw Error("The field run file could not be staged: " . Target)
		if !FSAtomicMoveReplace(Stage, Target, &NativeError) {
			FSDelete(Stage)
			throw OSError(NativeError, -1, "The field run file could not be published: " . Target)
		}
	}
}





; ============================
; ============================
; ======= 4/ Lifecycle =======
; ============================
; ============================

/**
 * Starts the developer field run of a driver run from a clone.
 * @param {String} CloneRoot - DevSource_Root().
 */
FieldRun_Start(CloneRoot) {
	global _FieldRun, _SharedDir
	if IsObject(_FieldRun)
		throw Error("The field run already has an owner.")
	if !(CloneRoot is String) || CloneRoot == ""
		throw ValueError("The field run runs only in developer source mode.")
	LoggerStart(FIELD_RUN_TAG, "Starting the developer field run…")
	Spec := FieldRun_LoadProtocol(_SharedDir . "\data\field_run_protocol.json")
	Runners := FieldRun_Runners()
	Steps := FieldRun_LoadSteps(CloneRoot . "\" . StrReplace(Spec["steps_file"]["windows"], "/", "\"), Spec, Runners)
	Folder := CloneRoot . "\" . StrReplace(Spec["folder"]["clone"], "/", "\")
	Session := FieldRunSession(Spec, Steps, Folder, ProcessExist(),
		Map("poll_ms", TimingsGet("ui", "field_run_poll_ms"), "runners", Runners))
	_FieldRun := Session
	Session.Start()
	LoggerSuccess(FIELD_RUN_TAG, "Developer field run ready ({1} step(s)).", Steps["steps"].Length)
}

/** Retires the developer field run. */
FieldRun_Stop() {
	global _FieldRun
	if !IsObject(_FieldRun)
		return
	_FieldRun.Stop()
	_FieldRun := 0
	LoggerInfo(FIELD_RUN_TAG, "Developer field run retired.")
}
