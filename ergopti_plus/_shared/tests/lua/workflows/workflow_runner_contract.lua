--- _shared/tests/lua/workflows/workflow_runner_contract.lua

--- ==============================================================================
--- MODULE: User Workflow Runner Contract
--- DESCRIPTION:
--- Drives the shared runner with recording ports on the macOS and Linux
--- runtimes: the registry deadlines, a step past its deadline, a workflow that
--- is triggered twice, an abort that cancels the pending effect, an answer
--- that arrives too late, and the shell steps of a local and an imported run.
---
--- ROOT CAUSE ENCODED:
--- Without one runner, a slow OS call could resume a stopped workflow, a
--- second trigger could interleave two runs of one workflow, and a step could
--- wait for ever.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")
local Runner = require("shortcuts.engine.workflows.runner")

local M = {}

--- Builds a runner over recording ports.
--- @param catalogue table
--- @param overrides table|nil Port replacements.
--- @return table runner, table world
local function harness(catalogue, overrides)
	local world = { timers = {}, effects = {}, pending = {}, cancelled = {}, ends = {}, approvals = {} }
	local ports = {
		catalogue = catalogue,
		timeouts = { step_timeout_ms = 10, screen_step_timeout_ms = 20, shell_timeout_ms = 30,
			wait_max_ms = 600000, wait_for_poll_ms = 5 },
		after = function(ms, fn)
			local timer = { ms = ms, fn = fn, live = true }
			world.timers[#world.timers + 1] = timer
			return function() timer.live = false end
		end,
		perform = function(effect, done)
			world.effects[#world.effects + 1] = effect
			world.pending[#world.pending + 1] = done
		end,
		cancel = function(effect) world.cancelled[#world.cancelled + 1] = effect.path end,
		approvals = {
			get = function(id) return world.approvals[id] end,
		},
		on_end = function(workflow, outcome) world.ends[#world.ends + 1] = { id = workflow.id, outcome = outcome } end,
	}
	for key, value in pairs(overrides or {}) do ports[key] = value end
	return Runner.new(ports), world
end

--- @param timer table
local function fire(timer) if timer.live then timer.live = false; timer.fn() end end

--- Registers the runner checks.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local file = assert(io.open(shared_path(Model.CATALOGUE_PATH), "rb"))
	local catalogue = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
	local function workflow(steps, origin)
		return { id = "wf_1", name = "T", origin = origin or "local", steps = steps }
	end

	helpers.describe("workflows: runner", function()
		helpers.it("workflows: the deadlines are the registry's", function()
			local timeouts = Runner.registry_timeouts()
			for _, key in ipairs({ "step_timeout_ms", "screen_step_timeout_ms", "shell_timeout_ms", "wait_max_ms",
				"wait_for_poll_ms" }) do
				helpers.assert_true(type(timeouts[key]) == "number" and timeouts[key] > 0, key)
			end
		end)

		helpers.it("workflows: each answer runs the next step, the end is told once", function()
			local runner, world = harness(catalogue)
			helpers.assert_eq(runner.start(workflow({ { kind = "notify", text = "a" }, { kind = "wait", duration_ms = 5 } })), true)
			helpers.assert_eq(world.effects[1].op, "notify")
			helpers.assert_eq(world.timers[1].ms, 10)
			world.pending[1]({ ok = true })
			helpers.assert_eq(world.effects[2].op, "wait")
			helpers.assert_eq(world.timers[2].ms, 15)
			helpers.assert_eq(world.timers[1].live, false)
			world.pending[2]({ ok = true })
			helpers.assert_eq(#world.ends, 1)
			helpers.assert_eq(world.ends[1].outcome.op, "done")
			helpers.assert_eq(runner.is_running("wf_1"), false)
		end)

		helpers.it("workflows: a synchronous answer does not recurse per step", function()
			local count = 0
			local runner, world = harness(catalogue, { perform = function(_, done) count = count + 1; done({ ok = true }) end })
			runner.start(workflow({ { kind = "repeat", count = 1000, steps = { { kind = "wait", duration_ms = 0 } } } }))
			helpers.assert_eq(count, 1000)
			helpers.assert_eq(world.ends[1].outcome.op, "done")
		end)

		helpers.it("workflows: a step past its deadline stops the run and is cancelled", function()
			local runner, world = harness(catalogue)
			runner.start(workflow({ { kind = "focus_app", app = "A" }, { kind = "notify", text = "never" } }))
			fire(world.timers[1])
			helpers.assert_eq(world.cancelled[1], "1")
			helpers.assert_eq(world.ends[1].outcome.reason, "timeout")
			helpers.assert_eq(world.ends[1].outcome.path, "1")
			world.pending[1]({ ok = true })
			helpers.assert_eq(#world.effects, 1, "a late answer resumes nothing")
			helpers.assert_eq(#world.ends, 1)
		end)

		helpers.it("workflows: a second trigger of a running workflow is refused", function()
			local runner, world = harness(catalogue)
			local steps = { { kind = "wait", duration_ms = 5 } }
			helpers.assert_eq(runner.start(workflow(steps)), true)
			local started, reason = runner.start(workflow(steps))
			helpers.assert_eq(started, false)
			helpers.assert_eq(reason, "already_running")
			helpers.assert_eq(#world.effects, 1)
		end)

		helpers.it("workflows: abort stops at once and cancels the pending effect", function()
			local runner, world = harness(catalogue)
			runner.start(workflow({ { kind = "wait", duration_ms = 5 }, { kind = "notify", text = "never" } }))
			helpers.assert_eq(runner.abort_all(), 1)
			helpers.assert_eq(world.cancelled[1], "1")
			helpers.assert_eq(world.ends[1].outcome.op, "aborted")
			world.pending[1]({ ok = true })
			fire(world.timers[1])
			helpers.assert_eq(#world.effects, 1)
			helpers.assert_eq(#world.ends, 1)
			helpers.assert_eq(runner.abort("wf_1"), false)
		end)

		helpers.it("workflows: a local shell step runs at once, an approved import too", function()
			local steps = { { kind = "shell", command = "true" } }
			local runner, world = harness(catalogue)
			runner.start(workflow(steps))
			helpers.assert_eq(world.effects[1].op, "shell")
			world.pending[1]({ ok = true, value = "" })
			helpers.assert_eq(world.ends[1].outcome.op, "done")
			world.approvals.wf_1 = Model.shell_digest(workflow(steps))
			runner.start(workflow(steps, "import"))
			helpers.assert_eq(world.effects[2].op, "shell")
		end)

		helpers.it("workflows: an imported shell step without approval asks nothing", function()
			local runner, world = harness(catalogue)
			runner.start(workflow({ { kind = "shell", command = "true" } }, "import"))
			helpers.assert_eq(#world.effects, 0)
			helpers.assert_eq(world.ends[1].outcome.reason, "shell_not_approved")
		end)
	end)
end

return M
