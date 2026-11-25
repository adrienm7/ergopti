--- _shared/shortcuts/engine/workflows/runner.lua

--- ==============================================================================
--- MODULE: User Workflow Runner (Shared)
--- DESCRIPTION:
--- Drives the shared interpreter for the macOS and Linux drivers: each effect
--- goes to the driver's adapter with the deadline of the timing registry, its
--- answer feeds the next step, and the outcome reaches the driver once. A
--- workflow never runs twice at a time, and abort() stops a run at once.
---
--- FEATURES & RATIONALE:
--- 1. Every deadline comes from [workflows] of the timing registry; a late
---    answer, after its deadline or after an abort, is ignored, so a slow OS
---    call can never resume a stopped workflow.
--- 2. A trampoline: an adapter may answer synchronously (a clipboard read)
---    without growing the stack with the number of steps.
--- 3. The shell approval the interpreter obtained is stored through the
---    driver's approval port only after the user said yes, keyed by the
---    workflow id and bound to its shell digest.
--- 4. The driver owns every OS effect, the confirmation dialog, the notice
---    and the step highlight; this module owns none of them.
--- ==============================================================================

local Interpreter = require("shortcuts.engine.workflows.interpreter")
local Logger = require("core.logger.engine.shim")
local Timings = require("core.timing.engine.timings")

local M = {}

local LOG = "workflows"

--- The registry deadlines steps.json names, and the wait-for poll interval.
--- @return table
function M.registry_timeouts()
	return {
		step_timeout_ms = Timings.ms("workflows", "step_timeout_ms"),
		screen_step_timeout_ms = Timings.ms("workflows", "screen_step_timeout_ms"),
		shell_timeout_ms = Timings.ms("workflows", "shell_timeout_ms"),
		wait_max_ms = Timings.ms("workflows", "wait_max_ms"),
		wait_for_poll_ms = Timings.ms("workflows", "wait_for_poll_ms"),
	}
end

--- Builds one driver's runner.
--- @param ports table {
---   catalogue = decoded steps.json,
---   timeouts = table|nil the registry deadlines (default registry_timeouts()),
---   after = function(ms, fn) -> cancel function: one timer,
---   perform = function(effect, done): run one effect; done({ ok, value, reason }) once,
---   cancel = function(effect): stop a pending effect (abort or deadline), optional,
---   approvals = { get = function(id) -> digest|nil, set = function(id, digest) },
---   on_step = function(workflow, effect): a step starts (the editor's highlight), optional,
---   on_end = function(workflow, outcome): the run ended (notice on failure). }
--- @return table runner { start, abort, abort_all, is_running }
function M.new(ports)
	assert(type(ports) == "table", "a workflow runner needs its ports")
	for _, name in ipairs({ "after", "perform", "on_end" }) do
		assert(type(ports[name]) == "function", "a workflow runner needs the port " .. name)
	end
	assert(type(ports.catalogue) == "table", "a workflow runner needs the step catalogue")
	assert(type(ports.approvals) == "table" and type(ports.approvals.get) == "function"
		and type(ports.approvals.set) == "function", "a workflow runner needs the approval store")
	local timeouts = ports.timeouts or M.registry_timeouts()
	local running = {}
	local runner = {}

	local function finish(state, outcome)
		if state.cancel_timer then state.cancel_timer(); state.cancel_timer = nil end
		running[state.workflow.id] = nil
		if state.run.approved_now() then ports.approvals.set(state.workflow.id, state.run.digest) end
		if outcome.op == "done" then
			Logger.success(LOG, "Workflow %s finished.", state.workflow.id)
		elseif outcome.op == "aborted" then
			Logger.info(LOG, "Workflow %s stopped at step %s.", state.workflow.id, tostring(outcome.path))
		else
			Logger.warn(LOG, "Workflow %s failed at step %s (%s): %s.", state.workflow.id,
				tostring(outcome.path), tostring(outcome.kind), tostring(outcome.reason))
		end
		ports.on_end(state.workflow, outcome)
	end

	local function drive(state)
		if state.driving then state.again = true; return end
		state.driving = true
		repeat
			state.again = false
			if running[state.workflow.id] ~= state then break end
			local effect = state.run.next()
			if effect.op == "done" or effect.op == "failed" or effect.op == "aborted" then
				finish(state, effect)
				break
			end
			if effect.op == "wait_for" then effect.poll_ms = timeouts.wait_for_poll_ms end
			state.token = state.token + 1
			state.effect = effect
			local token = state.token
			if effect.deadline_ms then
				state.cancel_timer = ports.after(effect.deadline_ms, function()
					if state.token ~= token or running[state.workflow.id] ~= state then return end
					state.cancel_timer = nil
					if ports.cancel then ports.cancel(effect) end
					state.token = state.token + 1
					state.run.complete({ ok = false, reason = "timeout" })
					drive(state)
				end)
			end
			if ports.on_step then ports.on_step(state.workflow, effect) end
			ports.perform(effect, function(result)
				if state.token ~= token or running[state.workflow.id] ~= state then return end
				state.token = state.token + 1
				if state.cancel_timer then state.cancel_timer(); state.cancel_timer = nil end
				state.run.complete(type(result) == "table" and result or { ok = false })
				drive(state)
			end)
		until not state.again
		state.driving = false
	end

	--- Starts a workflow unless it is already running.
	--- @param workflow table A valid workflow.
	--- @return boolean started
	--- @return string|nil reason "already_running".
	function runner.start(workflow)
		assert(type(workflow) == "table" and type(workflow.id) == "string", "a workflow run needs a workflow")
		if running[workflow.id] then
			Logger.info(LOG, "Workflow %s is already running; the new trigger is ignored.", workflow.id)
			return false, "already_running"
		end
		Logger.start(LOG, "Running workflow %s…", workflow.id)
		local state = {
			workflow = workflow, token = 0,
			run = Interpreter.new({ workflow = workflow, catalogue = ports.catalogue, timeouts = timeouts,
				approved_digest = ports.approvals.get(workflow.id) }),
		}
		running[workflow.id] = state
		drive(state)
		return true
	end

	--- Stops one running workflow at once.
	--- @param id string
	--- @return boolean Whether a run was stopped.
	function runner.abort(id)
		local state = running[id]
		if not state then return false end
		state.token = state.token + 1
		if ports.cancel and state.effect then ports.cancel(state.effect) end
		state.run.abort()
		state.driving = false
		drive(state)
		return true
	end

	--- Stops every running workflow (Escape, the emergency stop).
	--- @return integer How many runs were stopped.
	function runner.abort_all()
		local ids = {}
		for id in pairs(running) do ids[#ids + 1] = id end
		table.sort(ids)
		for _, id in ipairs(ids) do runner.abort(id) end
		return #ids
	end

	--- @param id string|nil One workflow, or any when nil.
	--- @return boolean
	function runner.is_running(id)
		if id == nil then return next(running) ~= nil end
		return running[id] ~= nil
	end

	return runner
end

return M
