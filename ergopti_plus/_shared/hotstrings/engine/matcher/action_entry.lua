--- _shared/hotstrings/engine/matcher/action_entry.lua

--- ==============================================================================
--- MODULE: Hotstring Action Entries
--- DESCRIPTION:
--- A hotstring entry may run an action (a built-in parameterless action, or one
--- of the user's workflows) instead of, or besides, typing its output:
---     ";wf1" = { output = "", action = "run_workflow", workflow = "wf_3f9a" }
---     "bonjour" = { action = "select_all", erase_trigger = false }
--- This module checks those fields and decides the edit before the action runs:
--- with erase_trigger (the default) the trigger is erased and the output typed,
--- exactly as a text entry; without it the text stays as typed, end character
--- included, and only the output is typed after it. The macOS and Linux engines
--- apply the plan, the AutoHotkey port reads the same rules, and
--- _shared/tests/corpus/hotstrings/action_entry_vectors.json pins them.
---
--- FEATURES & RATIONALE:
--- 1. One plan for both erase modes, built on the shared injection plan, so
---    the erase count and the replayed end character are the text entries'.
--- 2. A key the engine held back (it never reached the application) is typed
---    back when the text is kept: « exactly as typed » holds on every driver.
--- 3. An action entry never chains (cascade) and never leaves a buffer the
---    engine could match again: the action changes the context.
--- 4. Pure: no logger, no I/O; a loader logs and skips a refused entry.
--- ==============================================================================

local InjectionPlan = require("hotstrings.engine.matcher.injection_plan")

local M = {}

--- Whether the trigger is erased when the entry does not say.
M.ERASE_TRIGGER_DEFAULT = true

--- The action that runs one of the user's workflows; it alone takes a value
--- (the workflow field), every other action of an entry is parameterless.
M.WORKFLOW_ACTION = "run_workflow"

--- Why an entry's action fields are refused (closed list, the corpus's).
M.REFUSALS = {
	bad_action = "bad_action",
	bad_workflow = "bad_workflow",
	workflow_without_action = "workflow_without_action",
	bad_erase_trigger = "bad_erase_trigger",
}

--- The grammar of an action catalogue id, which a workflow's run_action step
--- also checks (shortcuts.engine.workflows.model).
M.ACTION_MAX_BYTES = 64
M.ACTION_PATTERN = "^[a-z][a-z0-9_]*$"

local WORKFLOW_MAX_BYTES = 64

--- Checks the action fields of a parsed entry.
--- @param entry table A parsed entry (trigger, output, action, workflow, erase_trigger).
--- @return table|nil fields { action, workflow, erase_trigger } or nil when the
---   entry runs no action.
--- @return string|nil refusal One of M.REFUSALS.
function M.fields(entry)
	assert(type(entry) == "table", "action_entry.fields needs an entry")
	local action, workflow, erase = entry.action, entry.workflow, entry.erase_trigger
	if action == nil then
		if workflow ~= nil then return nil, M.REFUSALS.workflow_without_action end
		if erase ~= nil and type(erase) ~= "boolean" then return nil, M.REFUSALS.bad_erase_trigger end
		return nil
	end
	if type(action) ~= "string" or #action > M.ACTION_MAX_BYTES or not action:match(M.ACTION_PATTERN) then
		return nil, M.REFUSALS.bad_action
	end
	if action == M.WORKFLOW_ACTION then
		if type(workflow) ~= "string" or #workflow > WORKFLOW_MAX_BYTES or not workflow:match("^[A-Za-z0-9_%-]+$") then
			return nil, M.REFUSALS.bad_workflow
		end
	elseif workflow ~= nil then
		return nil, M.REFUSALS.workflow_without_action
	end
	if erase ~= nil and type(erase) ~= "boolean" then return nil, M.REFUSALS.bad_erase_trigger end
	return { action = action, workflow = workflow, erase_trigger = erase ~= false }
end

--- Whether an action entry erases its trigger, nil for a text entry (no
--- `x and y or nil` idiom: a false would read as nil).
--- @param entry table A mapping or parsed entry.
--- @return boolean|nil
function M.erase_of(entry)
	if entry.action == nil then return nil end
	return entry.erase_trigger ~= false
end

--- The edit an action entry makes before its action runs.
--- @param spec table {
---   path = InjectionPlan.PATH_AUTO | PATH_TERMINATOR,
---   trigger_len = codepoints of the trigger as typed,
---   event_len = codepoints of the event that completed the match,
---   event_on_screen = whether that event already reached the application,
---   event_text = the event's text (its characters), typed back when kept,
---   terminator = the end character on the terminator path, or nil,
---   consume_terminator = the entry consumes its end character (erase mode),
---   nbsp_stripped = a no-break space was stripped (erase mode),
---   output = the entry's output (may be ""),
---   erase_trigger = boolean }
--- @return table plan { erase, text, tail, replay, buffer_suffix, final_result }
function M.plan(spec)
	assert(type(spec) == "table" and type(spec.output) == "string", "action_entry.plan needs a spec with an output")
	if spec.erase_trigger ~= false then
		return InjectionPlan.build({
			path = spec.path, trigger_len = spec.trigger_len, event_len = spec.event_len,
			event_on_screen = spec.event_on_screen, nbsp_stripped = spec.nbsp_stripped,
			consume_terminator = spec.consume_terminator, terminator = spec.terminator,
			replacement = spec.output, final_result = true,
		})
	end
	local held = spec.event_on_screen and "" or (spec.event_text or "")
	local text = held .. spec.output
	return { erase = 0, text = text, tail = nil, replay = nil, buffer_suffix = text, final_result = true }
end

--- Runs an entry's action through the driver's executors, after the edit.
--- @param fields table { action, workflow } of a match result.
--- @param ports table {
---   run_workflow = function({ id }) -> boolean,
---   execute = function(action) -> boolean: a parameterless catalogue action,
---   parameter_spec = function(action) -> string|nil: its parameter kind }
--- @return boolean ran
--- @return string|nil refusal "parameterised_action" when the action needs a
---   value an entry cannot give.
function M.dispatch(fields, ports)
	assert(type(fields) == "table" and type(fields.action) == "string", "action_entry.dispatch needs an action")
	if fields.action == M.WORKFLOW_ACTION then return ports.run_workflow({ id = fields.workflow }) == true end
	if ports.parameter_spec(fields.action) ~= nil then return false, "parameterised_action" end
	return ports.execute(fields.action) ~= false
end

return M
