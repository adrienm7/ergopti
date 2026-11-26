; modules/shortcuts/workflows/interpreter.ahk

; ==============================================================================
; MODULE: User Workflow Interpreter (Windows)
; DESCRIPTION:
; The AutoHotkey port of _shared/shortcuts/engine/workflows/interpreter.lua:
; one validated workflow run as a pure state machine. Next() returns the
; effect the driver must perform (keys, text, a probe of the screen, a shell
; command…), Complete(Result) feeds its outcome back, Abort() stops it.
; _shared/tests/corpus/workflows/interpreter_vectors.json pins every effect
; and outcome, as it does for the macOS and Linux runner.
;
; FEATURES & RATIONALE:
; 1. No OS call and no clock here: each effect carries its deadline_ms, read
;    by the caller from the timing registry, so the suite replays the logic
;    without a desktop.
; 2. Errors are never silent: a failed effect, an unknown variable or a
;    refused shell step ends the run with a closed run reason and the dotted
;    path of the step (3.then.2), which the notice names.
; 3. Shell steps: a workflow the user made or edited runs them; an imported
;    one (origin "import") stops at its first shell step until the editor
;    approved its shell digest (maintainer decision of 2026-11-25).
; 4. A bounded run: every executed step counts toward limits.run_steps_max.
; ==============================================================================

#Requires AutoHotkey v2.0

; The run outcomes Next() returns once a run ended.
global WORKFLOW_FINAL_OPS := Map("done", true, "failed", true, "aborted", true)

; Deep-copies a decoded JSON value: Maps and Arrays are new, scalars shared.
_WorkflowCopy(Value) {
	if Value is Map {
		Out := Map()
		for Key, Item in Value
			Out[Key] := _WorkflowCopy(Item)
		return Out
	}
	if Value is Array {
		Out := []
		for Item in Value
			Out.Push(_WorkflowCopy(Item))
		return Out
	}
	return Value
}

/**
 * One run of one validated workflow.
 */
class WorkflowRun {
	/**
	 * @param {Map} Options "workflow" (valid), "catalogue" (decoded steps.json),
	 *   "timeouts" (registry key -> ms for every timeout steps.json names), and
	 *   optionally "approved_digest" and "variables" (name -> string).
	 */
	__New(Options) {
		if !(Options is Map) || !(Options.Get("workflow", 0) is Map) || !(Options.Get("catalogue", 0) is Map)
				|| !(Options.Get("timeouts", 0) is Map)
			throw TypeError("A workflow run needs its workflow, catalogue and timeouts.", -1)
		this.Catalogue := Options["catalogue"]
		this.Timeouts := Options["timeouts"]
		for Kind, Declared in this.Catalogue["kinds"] {
			Key := Declared.Get("timeout", "")
			if (Key is String) && !(this.Timeouts.Get(Key, "") is Number)
				throw ValueError("A workflow run needs the timeout " . Key . " of " . Kind . ".", -1)
		}
		this.RunReasons := Map()
		for Reason in this.Catalogue["run_reasons"]
			this.RunReasons[Reason] := true
		Workflow := Options["workflow"]
		this.Workflow := Workflow
		this.Digest := WorkflowShellDigest(Workflow)
		Approved := Options.Get("approved_digest", "")
		; A workflow the user made or edited runs its shell steps; an imported one
		; only once its shell digest was approved in the editor.
		this.ShellApproved := Workflow["origin"] !== "import"
			|| (this.Digest != "" && (Approved is String) && Approved == this.Digest)
		this.Variables := Map()
		for Name, Value in Options.Get("variables", Map())
			this.Variables[Name] := String(Value)
		this.Frames := [Map("steps", Workflow["steps"], "index", 1, "prefix", "", "remaining", 0)]
		this.Executed := 0
		this.Pending := 0
		this.Status := "running"
		this.Reason := ""
		this.Path := ""
		this.Kind := ""
	}

	; The final outcome, as Next() returns it once the run ended.
	Outcome() {
		Out := Map("op", this.Status)
		for Key, Value in Map("reason", this.Reason, "path", this.Path, "kind", this.Kind)
			if Value != ""
				Out[Key] := Value
		return Out
	}

	Finish(Status, Reason := "", Path := "", Kind := "") {
		if Reason != "" && !this.RunReasons.Has(Reason)
			throw ValueError("Undeclared workflow run reason " . Reason . ".", -1)
		this.Status := Status, this.Reason := Reason, this.Path := Path, this.Kind := Kind
		this.Pending := 0
		this.Frames := []
		return this.Outcome()
	}

	TimeoutOf(Kind) {
		Key := this.Catalogue["kinds"][Kind].Get("timeout", "")
		return (Key is String) ? this.Timeouts[Key] : ""
	}

	; Expands one text; Ended receives the failure outcome on an unknown variable.
	Expand(Text, Path, Kind, &Ended) {
		Value := WorkflowExpand(Text, this.Variables, &Missing)
		if Value is String
			return Value
		Ended := this.Finish("failed", "unknown_variable", Path, Kind)
		return 0
	}

	; Expands the text fields of a target in place.
	ExpandTarget(Effect, Path, Kind, &Ended) {
		if !(Effect.Get("target", 0) is Map) || Effect["target"]["type"] !== "text"
			return true
		Value := this.Expand(Effect["target"]["text"], Path, Kind, &Ended)
		if !(Value is String)
			return false
		Effect["target"]["text"] := Value
		return true
	}

	ExpandCondition(Condition, Path, &Ended) {
		Out := _WorkflowCopy(Condition)
		for Name in ["app", "value"] {
			if Out.Has(Name) && (Out[Name] is String) {
				Value := this.Expand(Out[Name], Path, "if", &Ended)
				if !(Value is String)
					return 0
				Out[Name] := Value
			}
		}
		if !this.ExpandTarget(Out, Path, "if", &Ended)
			return 0
		return Out
	}

	; Answers a condition the interpreter can evaluate itself: 1 or 0, or -1 when
	; the driver must probe it.
	LocalCondition(Condition) {
		if Condition["type"] !== "matches" || Condition["source"] !== "variable"
			return -1
		Subject := this.Variables.Get(Condition["variable"], "")
		return WorkflowMatches(Subject, Condition)
	}

	EnterBranch(Step, Answer, Path) {
		Name := Answer ? "then" : "else"
		Steps := Step.Get(Name, [])
		if Steps.Length > 0
			this.Frames.Push(Map("steps", Steps, "index", 1, "prefix", Path . "." . Name . ".", "remaining", 0))
	}

	/**
	 * The next effect the driver performs, or the final outcome
	 * (Map "op" done | failed | aborted, "reason", "path", "kind").
	 * @returns {Map}
	 */
	Next() {
		if this.Status != "running"
			return this.Outcome()
		if IsObject(this.Pending)
			throw Error("A workflow effect is still pending.", -1)
		loop {
			if this.Frames.Length == 0
				return this.Finish("done")
			Frame := this.Frames[this.Frames.Length]
			if Frame["index"] > Frame["steps"].Length {
				if Frame["remaining"] > 0 {
					Frame["remaining"] -= 1
					Frame["index"] := 1
				} else
					this.Frames.Pop()
				continue
			}
			Step := Frame["steps"][Frame["index"]]
			Kind := Step["kind"]
			Path := Frame["prefix"] . Frame["index"]
			this.Executed += 1
			if this.Executed > this.Catalogue["limits"]["run_steps_max"]
				return this.Finish("failed", "too_many_steps", Path, Kind)
			Ended := 0
			if Kind == "repeat" {
				Frame["index"] += 1
				if Step["steps"].Length > 0
					this.Frames.Push(Map("steps", Step["steps"], "index", 1, "prefix", Path . ".",
						"remaining", Step["count"] - 1))
				continue
			}
			if Kind == "set_variable" {
				Value := this.Expand(Step["value"], Path, Kind, &Ended)
				if !(Value is String)
					return Ended
				this.Variables[Step["name"]] := Value
				Frame["index"] += 1
				continue
			}
			if Kind == "if" {
				Condition := this.ExpandCondition(Step["condition"], Path, &Ended)
				if !(Condition is Map)
					return Ended
				Answer := this.LocalCondition(Condition)
				if Answer != -1 {
					Frame["index"] += 1
					this.EnterBranch(Step, Answer == 1, Path)
					continue
				}
				this.Pending := Map("step", Step, "path", Path, "frame", Frame)
				return Map("op", "probe", "condition", Condition, "path", Path, "kind", "if",
					"deadline_ms", this.TimeoutOf("if"))
			}
			if Kind == "shell" && !this.ShellApproved
				return this.Finish("failed", "shell_not_approved", Path, Kind)
			Effect := Map("op", Kind, "path", Path, "kind", Kind)
			Deadline := this.TimeoutOf(Kind)
			if Deadline != ""
				Effect["deadline_ms"] := Deadline
			for Name, Value in Step
				if Name !== "kind" && Name !== "note"
					Effect[Name] := _WorkflowCopy(Value)
			for Name, Spec in this.Catalogue["kinds"][Kind]["fields"] {
				if Spec["type"] !== "text" || !_WorkflowFlag(Spec, "placeholders") || !(Effect.Get(Name, 0) is String)
					continue
				Value := this.Expand(Effect[Name], Path, Kind, &Ended)
				if !(Value is String)
					return Ended
				Effect[Name] := Value
			}
			if !this.ExpandTarget(Effect, Path, Kind, &Ended)
				return Ended
			if Kind == "wait"
				Effect["deadline_ms"] += Step["duration_ms"]
			if Kind == "wait_for"
				Effect["deadline_ms"] += Step["timeout_ms"]
			if Kind == "shell"
				Effect["environment"] := _WorkflowCopy(this.Variables)
			this.Pending := Map("step", Step, "path", Path, "frame", Frame)
			return Effect
		}
	}

	/**
	 * Feeds back the outcome of the pending effect.
	 * @param {Map} Result "ok" (Boolean), and optionally "value" and "reason".
	 */
	Complete(Result) {
		if this.Status != "running"
			return
		if !IsObject(this.Pending)
			throw Error("No workflow effect is pending.", -1)
		if !(Result is Map) || !Result.Has("ok")
			throw TypeError("A workflow result needs ok.", -1)
		Current := this.Pending
		this.Pending := 0
		Step := Current["step"], Path := Current["path"], Frame := Current["frame"]
		if !Result["ok"] {
			Reason := Result.Get("reason", "")
			this.Finish("failed", Reason != "" ? Reason : "step_failed", Path, Step["kind"])
			return
		}
		Frame["index"] += 1
		if Step["kind"] == "if" {
			Value := Result.Get("value", false)
			this.EnterBranch(Step, (Value is Integer) && Value == 1, Path)
		} else if Step.Has("into") && (Step["into"] is String)
			; The step field that receives an effect's value.
			this.Variables[Step["into"]] := Result.Has("value") ? String(Result["value"]) : ""
	}

	; Stops the run at once (Escape, the pause, a closing editor).
	Abort() {
		if this.Status != "running"
			return
		Path := IsObject(this.Pending) ? this.Pending["path"] : ""
		Kind := IsObject(this.Pending) ? this.Pending["step"]["kind"] : ""
		this.Finish("aborted", "aborted", Path, Kind)
	}
}

/**
 * Compares a subject with a « matches » condition literally: equals,
 * contains, starts with, or empty. Never a regular expression, whose dialects
 * differ between the drivers.
 * @param {String} Subject The clipboard or the variable.
 * @param {Map} Condition Its "op" and "value".
 * @returns {Boolean}
 */
WorkflowMatches(Subject, Condition) {
	Value := Condition.Get("value", "")
	switch Condition["op"], true {
		case "empty":
			return Subject == ""
		case "equals":
			return Subject == Value
		case "contains":
			return Value == "" || InStr(Subject, Value, true) > 0
		case "starts_with":
			return SubStr(Subject, 1, StrLen(Value)) == Value
	}
	throw ValueError("No workflow condition operator " . Condition["op"] . ".", -1)
}
