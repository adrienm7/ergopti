; tests/unit/modules/shortcuts/workflows/test_workflow_interpreter.ahk

; ==============================================================================
; MODULE: User Workflow Interpreter (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/workflows/interpreter_vectors.json, which the
; macOS and Linux suites replay through the shared Lua interpreter
; (_shared/tests/lua/workflows/workflow_interpreter_contract.lua), through
; modules/shortcuts/workflows/interpreter.ahk: the effects of a run in order,
; their paths and deadlines, the branches an « if » takes, the repeat count,
; the variables, the shell rules and the outcome of a failure or an abort.
; Each corpus workflow is first held valid by the Windows model. The corpus
; helpers are those of test_workflow_model.ahk.
;
; ROOT CAUSE ENCODED:
; A workflow could not run on Windows; a hand-written interpreter would take
; another branch, keep other variables or run a shell step an imported
; workflow was never approved for.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Interpreter vectors =============
; ============================================
; ============================================

_TWFM_InterpreterVectors() {
	global WORKFLOW_FINAL_OPS, JSON_NULL, JSON_TRUE
	Catalogue := _TWFM_Catalogue()
	Corpus := _TWFM_Shared("tests\corpus\workflows\interpreter_vectors.json", true)
	Timeouts := Corpus["timeouts"]
	Timings := Map("wait_max_ms", TimingsGet("workflows", "wait_max_ms"))
	Count := 0
	for Vector in Corpus["vectors"] {
		Count += 1
		Id := Vector["id"]
		Valid := WorkflowValidate(Vector["workflow"], Catalogue, Timings)
		AssertTrue(Valid["ok"], Id . " is not a valid workflow: " . _TWFM_Show(Valid))
		Digest := WorkflowShellDigest(Vector["workflow"])
		Options := Map("workflow", Vector["workflow"], "catalogue", _TWFM_WithLimits(Catalogue, Vector.Get("limits", 0)),
			"timeouts", Timeouts)
		if Vector.Has("approved_digest")
			Options["approved_digest"] := _TWFM_Resolve(Vector["approved_digest"], Digest)
		if Vector.Has("variables")
			Options["variables"] := Vector["variables"]
		WfRun := WorkflowRun(Options)
		Results := Vector.Get("results", [])
		Effects := Vector["effects"]
		Seen := 0
		Final := 0
		loop Effects.Length + 2 {
			Effect := WfRun.Next()
			if WORKFLOW_FINAL_OPS.Has(Effect["op"]) {
				Final := Effect
				break
			}
			Seen += 1
			AssertTrue(Seen <= Effects.Length, Id . ": unexpected effect " . _TWFM_Show(Effect))
			for Key, Value in _TWFM_Resolve(Effects[Seen], Digest) {
				Label := Id . " effect " . Seen . " " . Key . ": " . _TWFM_Show(Effect)
				if IsObject(Value) && Value == JSON_NULL
					AssertFalse(Effect.Has(Key), Label)
				else
					AssertTrue(Effect.Has(Key) && _TWFM_Equal(Value, Effect[Key]), Label)
			}
			if Vector.Get("abort_at", 0) == Seen {
				WfRun.Abort()
				continue
			}
			Answer := Results.Length >= Seen ? Results[Seen] : Map("ok", JSON_TRUE)
			Result := Map("ok", _TWFM_Plain(Answer["ok"]))
			if Answer.Has("value")
				Result["value"] := _TWFM_Plain(Answer["value"])
			if Answer.Has("reason")
				Result["reason"] := Answer["reason"]
			WfRun.Complete(Result)
		}
		AssertEqual(Effects.Length, Seen, Id . ": effect count")
		AssertTrue(IsObject(Final), Id . ": the run did not end")
		for Key in ["op", "reason", "path", "kind"]
			AssertEqual(Vector["expected"].Get(Key, ""), Final.Get(Key, ""), Id . " outcome " . Key)
	}
	AssertTrue(Count >= 30, "the interpreter corpus lost its vectors: " . Count)
}
Test("workflows: the interpreter vectors replay through the Windows run (workflow-model)", _TWFM_InterpreterVectors)

_TWFM_InterpreterGuards() {
	Catalogue := _TWFM_Catalogue()
	AssertThrows(() => WorkflowRun(Map("workflow", Map("id", "a", "origin", "local", "steps", []),
		"catalogue", Catalogue, "timeouts", Map())), "a run without a registry timeout refuses to start")
	Timeouts := Map()
	for Key in ["step_timeout_ms", "screen_step_timeout_ms", "shell_timeout_ms"]
		Timeouts[Key] := TimingsGet("workflows", Key)
	WfRun := WorkflowRun(Map("workflow", Map("id", "a", "origin", "local", "steps", []), "catalogue", Catalogue,
		"timeouts", Timeouts))
	AssertEqual("done", WfRun.Next()["op"], "an empty workflow is done")
	WfRun.Complete(Map("ok", false))
	WfRun.Abort()
	AssertEqual("done", WfRun.Status, "completing or aborting a finished run changes nothing")
}
Test("workflows: a run needs its registry deadlines and ends once (workflow-model)", _TWFM_InterpreterGuards)
