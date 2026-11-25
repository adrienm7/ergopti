; hotstrings/engine/matcher/action_entry.ahk

; ==============================================================================
; MODULE: Hotstring Action Entries (Windows)
; DESCRIPTION:
; The AutoHotkey port of _shared/hotstrings/engine/matcher/action_entry.lua. A
; hotstring entry may run an action (a parameterless built-in, or one of the
; user's workflows) instead of, or besides, typing its output:
;     ";wf1" = { output = "", action = "run_workflow", workflow = "wf_3f9a" }
;     "bonjour" = { action = "select_all", erase_trigger = false }
; This module checks those fields and decides the edit before the action
; runs: with erase_trigger (the default) the trigger is erased and the output
; typed, exactly as a text entry; without it the text stays as typed, end
; character included, and only the output is typed after it.
; _shared/tests/corpus/hotstrings/action_entry_vectors.json pins the rules
; the macOS and Linux engines read too.
;
; FEATURES & RATIONALE:
; 1. One plan for both erase modes, built on the injection plan
;    (HSE_PlanBuild), so the erase count and the replayed end character are
;    the text entries'.
; 2. A key the engine held back is typed back when the text is kept:
;    « exactly as typed » holds on every driver.
; 3. An action entry never chains; the matcher runs its action off the key
;    callback, through HSE_ActionEntryDispatch with the driver's executors.
; 4. Pure: no logger, no I/O; a loader logs and skips a refused entry.
; ==============================================================================

#Requires AutoHotkey v2.0

; An action id and a workflow id, as the shared module bounds them (64 bytes of ASCII).
global HSE_ACTION_ID_REGEX := "D)^[a-z][a-z0-9_]{0,63}$"
global HSE_WORKFLOW_ID_REGEX := "D)^[A-Za-z0-9_-]{1,64}$"

; @returns {Boolean} Whether a value is a decoded boolean (JSON_TRUE or JSON_FALSE).
_HSE_IsBooleanSentinel(Value) {
	global JSON_TRUE, JSON_FALSE
	return IsObject(Value) && (Value == JSON_TRUE || Value == JSON_FALSE)
}

/**
 * Checks the action fields of a parsed entry.
 * @param {Map} Entry The parsed entry: "action", "workflow" and "erase_trigger"
 *   when present, a boolean as JSON_TRUE or JSON_FALSE.
 * @param {String} Refusal Set to bad_action, bad_workflow,
 *   workflow_without_action or bad_erase_trigger, "" otherwise.
 * @returns {Map|Integer} Map("action", "workflow" when it has one,
 *   "erase_trigger" Boolean), or 0 for an entry that runs no action.
 */
HSE_ActionEntryFields(Entry, &Refusal := "") {
	global HSE_ACTION_ID_REGEX, HSE_WORKFLOW_ID_REGEX, JSON_FALSE
	if !(Entry is Map)
		throw TypeError("HSE_ActionEntryFields needs an entry Map.", -1)
	Refusal := ""
	HasErase := Entry.Has("erase_trigger")
	if !Entry.Has("action") {
		if Entry.Has("workflow")
			Refusal := "workflow_without_action"
		else if HasErase && !_HSE_IsBooleanSentinel(Entry["erase_trigger"])
			Refusal := "bad_erase_trigger"
		return 0
	}
	Action := Entry["action"]
	if !(Action is String) || !RegExMatch(Action, HSE_ACTION_ID_REGEX) {
		Refusal := "bad_action"
		return 0
	}
	Fields := Map("action", Action)
	if Action == "run_workflow" {
		Workflow := Entry.Get("workflow", 0)
		if !(Workflow is String) || !RegExMatch(Workflow, HSE_WORKFLOW_ID_REGEX) {
			Refusal := "bad_workflow"
			return 0
		}
		Fields["workflow"] := Workflow
	} else if Entry.Has("workflow") {
		Refusal := "workflow_without_action"
		return 0
	}
	if HasErase && !_HSE_IsBooleanSentinel(Entry["erase_trigger"]) {
		Refusal := "bad_erase_trigger"
		return 0
	}
	Fields["erase_trigger"] := !(HasErase && Entry["erase_trigger"] == JSON_FALSE)
	return Fields
}

/**
 * The edit an action entry makes before its action runs.
 * @param {Map} Spec "path", "trigger_len", "event_len", "event_on_screen",
 *   "event_text" (the event's characters, typed back when kept), "terminator",
 *   "consume_terminator", "nbsp_stripped", "output" and "erase_trigger".
 * @returns {Map} erase, text, tail, replay, buffer_suffix, final_result.
 */
HSE_ActionEntryPlan(Spec) {
	if !(Spec is Map) || !(Spec.Get("output", 0) is String)
		throw TypeError("HSE_ActionEntryPlan needs a spec with an output.", -1)
	if Spec.Get("erase_trigger", true) {
		Request := Map("replacement", Spec["output"], "final_result", true)
		for Key in ["path", "trigger_len", "event_len", "event_on_screen", "nbsp_stripped", "consume_terminator",
				"terminator"]
			if Spec.Has(Key)
				Request[Key] := Spec[Key]
		return HSE_PlanBuild(Request)
	}
	Held := Spec.Get("event_on_screen", true) ? "" : Spec.Get("event_text", "")
	Text := Held . Spec["output"]
	return Map("erase", 0, "text", Text, "tail", "", "replay", 0, "buffer_suffix", Text, "final_result", true)
}

/**
 * Runs an entry's action through the driver's executors, after the edit.
 * @param {Map} Fields "action", and "workflow" for run_workflow.
 * @param {Map} Ports "run_workflow" (Map("id")) -> Boolean, "execute" (Action)
 *   -> Boolean, "parameter_spec" (Action) -> its parameter kind or "".
 * @param {String} Refusal Set to parameterised_action when the action needs a
 *   value an entry cannot give.
 * @returns {Boolean} Ran.
 */
HSE_ActionEntryDispatch(Fields, Ports, &Refusal := "") {
	Refusal := ""
	if !(Fields is Map) || !(Fields.Get("action", 0) is String)
		throw TypeError("HSE_ActionEntryDispatch needs an action.", -1)
	; run_workflow alone takes a value, the workflow; every other action of an
	; entry is parameterless.
	if Fields["action"] == "run_workflow"
		return Ports["run_workflow"].Call(Map("id", Fields["workflow"])) == true
	if Ports["parameter_spec"].Call(Fields["action"]) != "" {
		Refusal := "parameterised_action"
		return false
	}
	return Ports["execute"].Call(Fields["action"]) !== false
}
