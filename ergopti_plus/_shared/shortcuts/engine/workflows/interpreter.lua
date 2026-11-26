--- _shared/shortcuts/engine/workflows/interpreter.lua

--- ==============================================================================
--- MODULE: User Workflow Interpreter (Shared)
--- DESCRIPTION:
--- Runs one validated workflow as a pure state machine: next() returns the
--- effect the driver must perform (keys, text, a probe of the screen, a shell
--- command…), complete(result) feeds its outcome back, abort() stops it. The
--- macOS and Linux runner (runner.lua) drives it over timers; the AutoHotkey
--- port follows the same contract, and
--- _shared/tests/corpus/workflows/interpreter_vectors.json pins every effect
--- and outcome.
---
--- FEATURES & RATIONALE:
--- 1. No OS call and no clock here: each effect carries its deadline, read by
---    the caller from the timing registry, so the logic is replayed without a
---    desktop and a driver only maps effects to its own services.
--- 2. Errors are never silent: a failed effect, an unknown variable or a
---    refused shell step ends the run with a closed reason (steps.json
---    run_reasons) and the dotted path of the step, which the notice names.
--- 3. Shell steps: a workflow the user made or edited runs them; an imported
---    one (origin "import") stops at its first shell step until the editor
---    approved its shell digest (model.shell_digest), maintainer decision of
---    2026-11-25.
--- 4. A bounded run: every executed step counts toward limits.run_steps_max,
---    so nested repeats cannot spin for hours.
--- ==============================================================================

local Model = require("shortcuts.engine.workflows.model")

local M = {}

-- The step fields that receive an effect's value.
local INTO_FIELD = "into"

-- The fields of each step kind whose text takes {{placeholders}}, as
-- steps.json marks them; read from the catalogue at new().
local function placeholder_fields(catalogue, kind)
	local fields = {}
	for name, spec in pairs(catalogue.kinds[kind].fields) do
		if spec.type == "text" and spec.placeholders then fields[#fields + 1] = name end
	end
	table.sort(fields)
	return fields
end

-- Deep-copies a decoded JSON value into plain tables.
local copy = require("core.text.engine.table_util").deep_copy

--- Builds one run.
--- @param options table {
---   workflow = a valid workflow (model.validate_workflow),
---   catalogue = decoded steps.json,
---   timeouts = { [registry key] = ms } for every `timeout` steps.json names,
---   approved_digest = string|nil the digest an earlier approval covers,
---   variables = table|nil initial name -> string. }
--- @return table run { next, complete, abort, status, variables, digest }
function M.new(options)
	assert(type(options) == "table" and type(options.workflow) == "table" and type(options.catalogue) == "table"
		and type(options.timeouts) == "table", "a workflow run needs its workflow, catalogue and timeouts")
	local catalogue, workflow = options.catalogue, options.workflow
	for kind, declared in pairs(catalogue.kinds) do
		if declared.timeout ~= nil and type(options.timeouts[declared.timeout]) ~= "number" then
			error("a workflow run needs the timeout " .. tostring(declared.timeout) .. " of " .. kind, 2)
		end
	end
	local run_reasons = {}
	for _, reason in ipairs(catalogue.run_reasons) do run_reasons[reason] = true end

	local digest = Model.shell_digest(workflow)
	-- A workflow the user made or edited runs its shell steps; an imported one
	-- only once its shell digest was approved in the editor.
	local approved = workflow.origin ~= "import" or (digest ~= nil and options.approved_digest == digest)
	local variables = {}
	for name, value in pairs(options.variables or {}) do variables[name] = tostring(value) end
	local frames = { { steps = workflow.steps, index = 1, prefix = "", remaining = 0 } }
	local executed = 0
	local pending = nil
	local run = { status = "running", variables = variables, digest = digest }

	local function finish(status, reason, path, kind)
		if reason ~= nil and not run_reasons[reason] then error("undeclared workflow run reason " .. tostring(reason), 2) end
		run.status, run.reason, run.path, run.kind = status, reason, path, kind
		pending = nil
		frames = {}
		return { op = status, reason = reason, path = path, kind = kind }
	end

	local function timeout_of(kind)
		local key = catalogue.kinds[kind].timeout
		return key and options.timeouts[key] or nil
	end

	-- Expands one text, or ends the run on an unknown variable.
	local function expand(text, path, kind)
		local value, missing = Model.expand(text, variables)
		if value == nil then return nil, finish("failed", "unknown_variable", path, kind), missing end
		return value
	end

	local function expand_condition(condition, path)
		local out = copy(condition)
		for _, name in ipairs({ "app", "value" }) do
			if type(out[name]) == "string" then
				local value, ended = expand(out[name], path, "if")
				if not value then return nil, ended end
				out[name] = value
			end
		end
		if type(out.target) == "table" and out.target.type == "text" then
			local value, ended = expand(out.target.text, path, "if")
			if not value then return nil, ended end
			out.target.text = value
		end
		return out
	end

	--- Evaluates a condition the interpreter can answer itself.
	--- @param condition table
	--- @return boolean|nil nil when the driver must probe it.
	local function local_condition(condition)
		if condition.type ~= "matches" or condition.source ~= "variable" then return nil end
		local subject = variables[condition.variable] or ""
		if condition.op == "empty" then return subject == "" end
		if condition.op == "equals" then return subject == condition.value end
		if condition.op == "contains" then return subject:find(condition.value, 1, true) ~= nil end
		return subject:sub(1, #condition.value) == condition.value
	end

	local function enter_branch(steps, path, suffix)
		if steps and #steps > 0 then
			frames[#frames + 1] = { steps = steps, index = 1, prefix = path .. "." .. suffix .. ".", remaining = 0 }
		end
	end

	--- The next effect the driver performs, or the final outcome
	--- ({ op = "done" | "failed" | "aborted", reason, path, kind }).
	--- @return table
	function run.next()
		if run.status ~= "running" then return { op = run.status, reason = run.reason, path = run.path, kind = run.kind } end
		assert(pending == nil, "a workflow effect is still pending")
		while true do
			local frame = frames[#frames]
			if not frame then return finish("done") end
			if frame.index > #frame.steps then
				if frame.remaining > 0 then
					frame.remaining = frame.remaining - 1
					frame.index = 1
				else
					frames[#frames] = nil
				end
			else
				local step = frame.steps[frame.index]
				local path = frame.prefix .. frame.index
				executed = executed + 1
				if executed > catalogue.limits.run_steps_max then return finish("failed", "too_many_steps", path, step.kind) end
				if step.kind == "repeat" then
					frame.index = frame.index + 1
					if #step.steps > 0 then
						frames[#frames + 1] = { steps = step.steps, index = 1, prefix = path .. ".", remaining = step.count - 1 }
					end
				elseif step.kind == "set_variable" then
					local value, ended = expand(step.value, path, step.kind)
					if not value then return ended end
					variables[step.name] = value
					frame.index = frame.index + 1
				elseif step.kind == "if" then
					local condition, ended = expand_condition(step.condition, path)
					if not condition then return ended end
					local answer = local_condition(condition)
					if answer ~= nil then
						frame.index = frame.index + 1
						enter_branch(answer and step["then"] or step["else"], path, answer and "then" or "else")
					else
						pending = { step = step, path = path, frame = frame }
						return { op = "probe", condition = condition, path = path, kind = "if", deadline_ms = timeout_of("if") }
					end
				elseif step.kind == "shell" and not approved then
					return finish("failed", "shell_not_approved", path, step.kind)
				else
					local effect = { op = step.kind, path = path, kind = step.kind, deadline_ms = timeout_of(step.kind) }
					for name, value in pairs(step) do
						if name ~= "kind" and name ~= "note" then effect[name] = copy(value) end
					end
					for _, name in ipairs(placeholder_fields(catalogue, step.kind)) do
						if type(effect[name]) == "string" then
							local value, ended = expand(effect[name], path, step.kind)
							if not value then return ended end
							effect[name] = value
						end
					end
					if type(effect.target) == "table" and effect.target.type == "text" then
						local value, ended = expand(effect.target.text, path, step.kind)
						if not value then return ended end
						effect.target.text = value
					end
					if step.kind == "wait" then effect.deadline_ms = effect.deadline_ms + step.duration_ms end
					if step.kind == "wait_for" then effect.deadline_ms = effect.deadline_ms + step.timeout_ms end
					if step.kind == "shell" then effect.environment = copy(variables) end
					pending = { step = step, path = path, frame = frame }
					return effect
				end
			end
		end
	end

	--- Feeds back the outcome of the pending effect.
	--- @param result table { ok = boolean, value = any, reason = string|nil }
	function run.complete(result)
		if run.status ~= "running" then return end
		assert(pending ~= nil, "no workflow effect is pending")
		assert(type(result) == "table" and type(result.ok) == "boolean", "a workflow result needs ok")
		local current = pending
		pending = nil
		local step, path, frame = current.step, current.path, current.frame
		if not result.ok then
			finish("failed", result.reason or "step_failed", path, step.kind)
			return
		end
		frame.index = frame.index + 1
		if step.kind == "if" then
			local answer = result.value == true
			enter_branch(answer and step["then"] or step["else"], path, answer and "then" or "else")
		elseif type(step[INTO_FIELD]) == "string" then
			variables[step[INTO_FIELD]] = result.value == nil and "" or tostring(result.value)
		end
	end

	--- Stops the run at once (Escape, emergency stop, a closing editor).
	function run.abort()
		if run.status ~= "running" then return end
		local path = pending and pending.path or nil
		local kind = pending and pending.step.kind or nil
		finish("aborted", "aborted", path, kind)
	end

	return run
end

return M
