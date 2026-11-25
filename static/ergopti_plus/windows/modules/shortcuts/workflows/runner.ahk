; modules/shortcuts/workflows/runner.ahk

; ==============================================================================
; MODULE: User Workflow Store, Runner and Owner (Windows)
; DESCRIPTION:
; The AutoHotkey port of _shared/shortcuts/engine/workflows/store.lua,
; runner.lua and owner.lua: workflows.json and workflow_approvals.json in the
; config folder, each checked by the model; the run of one workflow at a time
; with the registry deadline of every effect; and the owner the run_workflow
; action, the binding editors and the editor window talk to, which tells each
; failure in a translated notice naming the step.
;
; FEATURES & RATIONALE:
; 1. Fail fast, never a silent default: an absent file is an empty list, an
;    unreadable or invalid one is a refusal the caller shows (the model's
;    reason and JSON Pointer), so a typo never makes workflows vanish.
; 2. A late answer, after its deadline or after an abort, is ignored (a token
;    per effect), so a slow OS call can never resume a stopped workflow.
; 3. A trampoline: a port may answer synchronously (a clipboard read) without
;    growing the stack with the number of steps.
; 4. Every OS effect, the file I/O and the timers are ports (effects.ahk), so
;    the suite drives a run with recorders and no desktop.
; ==============================================================================

#Requires AutoHotkey v2.0

; The only approvals schema version this store reads and writes.
global WORKFLOW_APPROVALS_VERSION := 1
global WORKFLOW_DIGEST_REGEX := "D)^[0-9a-f]{64}$"

global WORKFLOW_LOG := "Workflows"

; Raises unless a ports Map holds every named callable.
_WorkflowRequirePorts(Ports, Names, Owner) {
	if !(Ports is Map)
		throw TypeError(Owner . " needs its ports.", -2)
	for Name in Names
		if !HasMethod(Ports.Get(Name, 0), "Call")
			throw ValueError(Owner . " needs the port " . Name . ".", -2)
}

; Replaces {1}, {2}… in one pass: an inserted name or reason may itself hold a
; {n}, which must stay text.
WorkflowFill(Text, Values) {
	Out := ""
	Index := 1
	while RegExMatch(Text, "\{(\d+)\}", &Found, Index) {
		Slot := Integer(Found[1])
		Out .= SubStr(Text, Index, Found.Pos - Index)
		Out .= (Slot >= 1 && Slot <= Values.Length) ? String(Values[Slot]) : Found[0]
		Index := Found.Pos + Found.Len
	}
	return Out . SubStr(Text, Index)
}

; The step path as a person reads it: 3.then.2 -> 3 › ✓ 2, 3.else.1 -> 3 › ✗ 1.
WorkflowReadablePath(Path) {
	if !(Path is String) || Path == ""
		return "?"
	return StrReplace(StrReplace(StrReplace(Path, ".then.", " › ✓ "), ".else.", " › ✗ "), ".", " › ")
}




; ===================================
; ===================================
; ======= 1/ Store ==================
; ===================================
; ===================================

/**
 * The user's workflows and shell approvals, as store.lua reads and writes them.
 */
class WorkflowStore {
	/**
	 * @param {Map} Ports "path" (Name) -> absolute path in the config folder,
	 *   "read" (Path) -> String, or 0 when the file does not exist (raises on any
	 *   other failure), "write" (Path, Text) writing atomically (raises on
	 *   failure), "catalogue" (decoded steps.json), "timings" (Map wait_max_ms).
	 */
	__New(Ports) {
		_WorkflowRequirePorts(Ports, ["path", "read", "write"], "A workflow store")
		if !(Ports.Get("catalogue", 0) is Map) || !(Ports.Get("timings", 0) is Map)
			throw ValueError("A workflow store needs the catalogue and the check timings.", -1)
		this.Ports := Ports
		this.Catalogue := Ports["catalogue"]
		this.Timings := Ports["timings"]
	}

	; The workflows file and the approvals file of the config folder (store.lua).
	WorkflowsPath() {
		return this.Ports["path"].Call("workflows.json")
	}

	ApprovalsPath() {
		return this.Ports["path"].Call("workflow_approvals.json")
	}

	; The empty document an absent file stands for.
	Empty() {
		return Map("schema_version", this.Catalogue["schema_version"], "workflows", [])
	}

	/**
	 * The decoded, valid workflows document.
	 * @param {Map} Refusal Set to Map("reason", "path") when the file is invalid.
	 * @returns {Map|Integer} The document, or 0 with Refusal set.
	 */
	Load(&Refusal := 0) {
		Refusal := 0
		Text := this.Ports["read"].Call(this.WorkflowsPath())
		if !(Text is String)
			return this.Empty()
		if WorkflowUtf8Bytes(Text) > this.Catalogue["limits"]["file_bytes"] {
			Refusal := Map("reason", "too_long", "path", "")
			return 0
		}
		try Doc := JsonParseLossless(Text)
		catch {
			; The decoder's own message names a position, never the user's text.
			Refusal := Map("reason", "not_object", "path", "")
			return 0
		}
		Result := WorkflowValidateFile(Doc, this.Catalogue, this.Timings)
		if !Result["ok"] {
			Refusal := Map("reason", Result["reason"], "path", Result["path"])
			return 0
		}
		return Doc
	}

	/**
	 * One workflow by id.
	 * @returns {Map|Integer} The workflow, or 0 (Refusal set when the file is invalid).
	 */
	Find(Id, &Refusal := 0) {
		Doc := this.Load(&Refusal)
		if !(Doc is Map)
			return 0
		for Workflow in Doc["workflows"]
			if Workflow["id"] == Id
				return Workflow
		return 0
	}

	/**
	 * The choices a binding editor offers, in file order.
	 * @returns {Array|Integer} Maps ("value" id, "label" name), or 0 with Refusal set.
	 */
	Choices(&Refusal := 0) {
		Doc := this.Load(&Refusal)
		if !(Doc is Map)
			return 0
		Choices := []
		for Workflow in Doc["workflows"]
			Choices.Push(Map("value", Workflow["id"], "label", Workflow["name"]))
		return Choices
	}

	/**
	 * Writes a whole workflows document after checking it.
	 * @param {Map} Doc Decoded with JsonParseLossless (the editor's save).
	 * @returns {Boolean} Saved; Refusal is set when it was refused.
	 */
	Save(Doc, &Refusal := 0) {
		Refusal := 0
		Result := WorkflowValidateFile(Doc, this.Catalogue, this.Timings)
		if !Result["ok"] {
			Refusal := Map("reason", Result["reason"], "path", Result["path"])
			return false
		}
		this.Ports["write"].Call(this.WorkflowsPath(), WorkflowJsonEncode(Doc))
		return true
	}

	LoadApprovals() {
		global WORKFLOW_APPROVALS_VERSION, WORKFLOW_DIGEST_REGEX
		Text := this.Ports["read"].Call(this.ApprovalsPath())
		if !(Text is String)
			return Map("approvals", Map(), "schema_version", WORKFLOW_APPROVALS_VERSION)
		Broken := Error("The workflow approvals file is not a valid approvals file.", -1)
		try Doc := JsonParseLossless(Text)
		catch
			throw Broken
		if !(Doc is Map) || Doc.Count != 2 || !(Doc.Get("schema_version", "") is Integer)
				|| Doc["schema_version"] != WORKFLOW_APPROVALS_VERSION || !(Doc.Get("approvals", 0) is Map)
			throw Broken
		for Id, Digest in Doc["approvals"]
			if !WorkflowIsId(Id) || !(Digest is String) || !RegExMatch(Digest, WORKFLOW_DIGEST_REGEX)
				throw Broken
		return Doc
	}

	; The digest the user approved for a workflow, or "".
	Approval(Id) {
		return this.LoadApprovals()["approvals"].Get(Id, "")
	}

	; Records an approval of a workflow's shell digest (WorkflowShellDigest).
	Approve(Id, Digest) {
		global WORKFLOW_DIGEST_REGEX
		if !(Digest is String) || !RegExMatch(Digest, WORKFLOW_DIGEST_REGEX) || !WorkflowIsId(Id)
			throw ValueError("A workflow approval needs a workflow id and its shell digest.", -1)
		Doc := this.LoadApprovals()
		Doc["approvals"][Id] := Digest
		this.Ports["write"].Call(this.ApprovalsPath(), WorkflowJsonEncode(Doc))
	}
}




; ===================================
; ===================================
; ======= 2/ Runner =================
; ===================================
; ===================================

/**
 * Drives the interpreter: each effect goes to the perform port with its
 * registry deadline, its answer feeds the next step, the end is told once.
 */
class WorkflowRunner {
	/**
	 * @param {Map} Ports "catalogue", "timeouts" (the registry deadlines),
	 *   "after" (Ms, Fn) -> cancel callable, "perform" (Effect, Done, Workflow),
	 *   "cancel" (Effect), "approval" (Id) -> digest or "", "on_step"
	 *   (Workflow, Effect), "on_end" (Workflow, Outcome).
	 */
	__New(Ports) {
		_WorkflowRequirePorts(Ports, ["after", "perform", "cancel", "approval", "on_step", "on_end"], "A workflow runner")
		if !(Ports.Get("catalogue", 0) is Map) || !(Ports.Get("timeouts", 0) is Map)
			throw ValueError("A workflow runner needs the step catalogue and the registry deadlines.", -1)
		this.Ports := Ports
		this.Running := Map()
	}

	Finish(State, Outcome) {
		global WORKFLOW_LOG
		this.CancelTimer(State)
		if this.Running.Get(State.Workflow["id"], 0) == State
			this.Running.Delete(State.Workflow["id"])
		Id := State.Workflow["id"]
		if Outcome["op"] == "done"
			LoggerSuccess(WORKFLOW_LOG, "Workflow {1} finished.", Id)
		else if Outcome["op"] == "aborted"
			LoggerInfo(WORKFLOW_LOG, "Workflow {1} stopped at step {2}.", Id, Outcome.Get("path", "?"))
		else
			LoggerWarn(WORKFLOW_LOG, "Workflow {1} failed at step {2} ({3}): {4}.", Id, Outcome.Get("path", "?"),
				Outcome.Get("kind", "?"), Outcome.Get("reason", ""))
		this.Ports["on_end"].Call(State.Workflow, Outcome)
	}

	CancelTimer(State) {
		Cancel := State.CancelTimer
		State.CancelTimer := 0
		if HasMethod(Cancel, "Call")
			Cancel.Call()
	}

	Current(State) {
		return this.Running.Get(State.Workflow["id"], 0) == State
	}

	Drive(State) {
		global WORKFLOW_FINAL_OPS
		if State.Driving {
			State.Again := true
			return
		}
		State.Driving := true
		try {
			loop {
				State.Again := false
				if !this.Current(State)
					break
				Effect := State.Run.Next()
				if WORKFLOW_FINAL_OPS.Has(Effect["op"]) {
					this.Finish(State, Effect)
					break
				}
				if Effect["op"] == "wait_for"
					Effect["poll_ms"] := this.Ports["timeouts"]["wait_for_poll_ms"]
				State.Token += 1
				State.Effect := Effect
				Token := State.Token
				if Effect.Has("deadline_ms")
					State.CancelTimer := this.Ports["after"].Call(Effect["deadline_ms"],
						ObjBindMethod(this, "Expire", State, Token, Effect))
				this.Ports["on_step"].Call(State.Workflow, Effect)
				this.Ports["perform"].Call(Effect, ObjBindMethod(this, "Answer", State, Token), State.Workflow)
				if !State.Again
					break
			}
		} finally State.Driving := false
	}

	; A step past its deadline: the pending effect is cancelled and the run fails with timeout.
	Expire(State, Token, Effect) {
		if State.Token != Token || !this.Current(State)
			return
		State.CancelTimer := 0
		this.Ports["cancel"].Call(Effect)
		State.Token += 1
		State.Run.Complete(Map("ok", false, "reason", "timeout"))
		this.Drive(State)
	}

	; The answer of the pending effect; a late one is ignored.
	Answer(State, Token, Result) {
		if State.Token != Token || !this.Current(State)
			return
		State.Token += 1
		this.CancelTimer(State)
		State.Run.Complete((Result is Map) ? Result : Map("ok", false))
		this.Drive(State)
	}

	/**
	 * Starts a workflow unless it is already running.
	 * @param {Map} Workflow A valid workflow.
	 * @returns {Boolean} Started.
	 */
	Start(Workflow) {
		global WORKFLOW_LOG
		Id := Workflow["id"]
		if this.Running.Has(Id) {
			LoggerInfo(WORKFLOW_LOG, "Workflow {1} is already running; the new trigger is ignored.", Id)
			return false
		}
		LoggerStart(WORKFLOW_LOG, "Running workflow {1}…", Id)
		State := { Workflow: Workflow, Token: 0, Driving: false, Again: false, CancelTimer: 0, Effect: 0 }
		State.Run := WorkflowRun(Map("workflow", Workflow, "catalogue", this.Ports["catalogue"],
			"timeouts", this.Ports["timeouts"], "approved_digest", this.Ports["approval"].Call(Id)))
		this.Running[Id] := State
		this.Drive(State)
		return true
	}

	; Stops one running workflow at once. @returns {Boolean} Whether a run was stopped.
	Abort(Id) {
		State := this.Running.Get(Id, 0)
		if !IsObject(State)
			return false
		State.Token += 1
		if IsObject(State.Effect)
			this.Ports["cancel"].Call(State.Effect)
		State.Run.Abort()
		State.Driving := false
		this.Drive(State)
		return true
	}

	; Stops every running workflow (Escape, the pause). @returns {Integer} How many.
	AbortAll() {
		Ids := []
		for Id in this.Running
			Ids.Push(Id)
		for Id in Ids
			this.Abort(Id)
		return Ids.Length
	}

	; @param {String} Id One workflow, or "" for any.
	IsRunning(Id := "") {
		return Id == "" ? this.Running.Count > 0 : this.Running.Has(Id)
	}
}




; ===================================
; ===================================
; ======= 3/ Owner ==================
; ===================================
; ===================================

/**
 * The one object the driver holds for user workflows (owner.lua).
 */
class WorkflowOwner {
	/**
	 * @param {Map} Ports "store" (the WorkflowStore ports), "effects" (a
	 *   performer with Perform and Cancel), "after", "translate" (Key) -> text,
	 *   "notify" (Text), "timeouts" (the registry deadlines).
	 */
	__New(Ports) {
		_WorkflowRequirePorts(Ports, ["after", "translate", "notify"], "A workflow owner")
		if !(Ports.Get("store", 0) is Map) || !IsObject(Ports.Get("effects", 0)) || !(Ports.Get("timeouts", 0) is Map)
			throw ValueError("A workflow owner needs its store, effect and deadline ports.", -1)
		this.Ports := Ports
		this.Store := WorkflowStore(Ports["store"])
		this.Listeners := Map()
		Effects := Ports["effects"]
		this.Runner := WorkflowRunner(Map("catalogue", this.Store.Catalogue, "timeouts", Ports["timeouts"],
			"after", Ports["after"],
			"perform", ObjBindMethod(Effects, "Perform"), "cancel", ObjBindMethod(Effects, "Cancel"),
			"approval", ObjBindMethod(this.Store, "Approval"),
			"on_step", ObjBindMethod(this, "OnStep"), "on_end", ObjBindMethod(this, "OnEnd")))
	}

	Tell(Key, Values) {
		this.Ports["notify"].Call(WorkflowFill(this.Ports["translate"].Call(Key), Values))
	}

	TellInvalid(Refusal) {
		this.Tell("workflows.notice.file_invalid", [Refusal["reason"], Refusal["path"] == "" ? "/" : Refusal["path"]])
	}

	OnStep(Workflow, Effect) {
		Listener := this.Listeners.Get(Workflow["id"], 0)
		if (Listener is Map) && Listener.Has("on_step")
			Listener["on_step"].Call(Effect)
	}

	OnEnd(Workflow, Outcome) {
		Listener := this.Listeners.Get(Workflow["id"], 0)
		if this.Listeners.Has(Workflow["id"])
			this.Listeners.Delete(Workflow["id"])
		if Outcome["op"] == "failed" {
			Translate := this.Ports["translate"]
			this.Tell("workflows.notice.failed", [Workflow["name"], WorkflowReadablePath(Outcome.Get("path", "")),
				Translate.Call("workflows.step." . Outcome.Get("kind", "")),
				Translate.Call("workflows.reason." . Outcome.Get("reason", ""))])
		} else if Outcome["op"] == "aborted"
			this.Tell("workflows.notice.aborted", [Workflow["name"]])
		if (Listener is Map) && Listener.Has("on_end")
			Listener["on_end"].Call(Outcome)
	}

	Begin(Workflow, Listener) {
		if IsObject(Listener)
			this.Listeners[Workflow["id"]] := Listener
		Started := this.Runner.Start(Workflow)
		if !Started && this.Listeners.Has(Workflow["id"])
			this.Listeners.Delete(Workflow["id"])
		return Started
	}

	/**
	 * Starts a workflow by id, telling the user why when it cannot.
	 * @param {String} Id
	 * @param {Map} Listener "on_step" (Effect) and "on_end" (Outcome), or 0.
	 * @returns {Boolean} Started.
	 */
	Start(Id, Listener := 0) {
		global WORKFLOW_LOG
		Workflow := this.Store.Find(Id, &Refusal)
		if IsObject(Refusal) {
			LoggerError(WORKFLOW_LOG, "workflows.json is invalid ({1} at {2}): workflow {3} not run.",
				Refusal["reason"], Refusal["path"], Id)
			this.TellInvalid(Refusal)
			return false
		}
		if !IsObject(Workflow) {
			LoggerWarn(WORKFLOW_LOG, "Workflow {1} is assigned but no longer exists.", Id)
			this.Tell("workflows.notice.missing", [Id])
			return false
		}
		if this.Runner.IsRunning(Id) {
			LoggerInfo(WORKFLOW_LOG, "Workflow {1} is already running; this trigger is ignored.", Id)
			return false
		}
		return this.Begin(Workflow, Listener)
	}

	/**
	 * Test-runs a workflow the editor holds, saved or not, through the same runner.
	 * @param {Map} Workflow Decoded with JsonParseLossless.
	 * @returns {Boolean} Started; Refusal is set when the workflow is invalid.
	 */
	TestRun(Workflow, Listener, &Refusal := 0) {
		Refusal := 0
		Result := WorkflowValidate(Workflow, this.Store.Catalogue, this.Store.Timings)
		if !Result["ok"] {
			Refusal := Map("reason", Result["reason"], "path", Result["path"])
			return false
		}
		if this.Runner.IsRunning(Workflow["id"])
			return false
		return this.Begin(Workflow, Listener)
	}

	/**
	 * The run_workflow action: a decoded parameter Map("id").
	 * @returns {Boolean} Started.
	 */
	RunAction(Fields) {
		global WORKFLOW_LOG
		if !(Fields is Map) || !WorkflowIsId(Fields.Get("id", 0)) {
			LoggerWarn(WORKFLOW_LOG, "run_workflow ignored: no valid workflow is stored for the binding.")
			return false
		}
		return this.Start(Fields["id"])
	}

	; The binding editors' choices, or 0 after a notice.
	Choices() {
		Choices := this.Store.Choices(&Refusal)
		if IsObject(Refusal) {
			this.TellInvalid(Refusal)
			return 0
		}
		return Choices
	}

	AbortAll() {
		return this.Runner.AbortAll()
	}

	IsRunning(Id := "") {
		return this.Runner.IsRunning(Id)
	}

	; Stops every run before the driver releases the owner.
	Stop() {
		global WORKFLOW_LOG
		Stopped := this.Runner.AbortAll()
		LoggerInfo(WORKFLOW_LOG, "Workflow owner stopped; {1} running workflow(s) aborted.", Stopped)
	}
}
