--- tests/unit/ui/menu/menu_llm/mlx/adoption/test_start_diagnostic_reentry.lua

--- ==============================================================================
--- MODULE: MLX Cold Launch Diagnostic Reentry
--- DESCRIPTION:
--- A real logger sink may revoke a cold launch or establish another server
--- before native construction. The older frame cannot acquire its task or
--- replace the successor's registry. Native signal ports only record requests.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_adoption = require("tests.support.modules.llm.processes.mlx_adoption_fixture")

--- Counts real manager native-construction requests, excluding readiness probes.
--- @param state table Recording fixture.
--- @return integer count
local function server_count(state)
	local count = 0
	for _, task in ipairs(state.tasks) do
		if task.label == "MLX server launch" then count = count + 1 end
	end
	return count
end

--- Injects one external logger continuation into the actual cold-launch frame.
--- @param mode string Controlled logger action.
--- @param scenario function Assertions outside the logger's protected callback.
local function with_start(mode, scenario)
	with_adoption(function(obj, state, deps)
		local current_b = true
		state.b_cancel, state.b_success = 0, 0
		require("infra.logger").set_sink(function(line)
			if state.start_observed or not line:find("Starting MLX server process for model Model-B", 1, true) then return end
			state.start_observed = true
			if mode == "healthy" then return end
			if mode == "throw_only" then
				state.sink_threw = true
				error("controlled cold-start diagnostic failure")
			end
			if mode == "revoked" or mode == "successor_revoked" then current_b = false end
			if mode == "revoked" then return end
			state.c_accepted = obj.start_server("Model-C", function() end,
				function() state.c_cancelled = true end)
			state.c_task, state.c_owner = deps.active_tasks.mlx_server, obj._server_lifecycle_owner
			if mode == "completed" then
				state.c_stop_accepted = obj.stop_server_if_needed(function() state.c_stopped = true end)
				state.c_task:complete(15)
			elseif mode == "queued" then
				state.d_accepted = obj.start_server("Model-D", function() end,
					function() state.d_cancelled = true end)
			elseif mode == "throw_after_successor" then
				state.sink_threw = true
				error("controlled cold-start diagnostic failure after C")
			end
		end)
		state.b_accepted = obj.start_server("Model-B", function() state.b_success = state.b_success + 1 end,
			function() state.b_cancel = state.b_cancel + 1 end,
			{ is_current = function() return current_b end })
		helpers.assert_true(state.start_observed, "actual startup diagnostic must run")
		scenario(obj, state, deps)
	end)
end

--- Verifies that the next public stop owns precisely the latest native task.
--- @param obj table Real manager.
--- @param state table Fixture observations.
--- @param deps table Task registry.
--- @param task table Expected current native task.
local function stop_current(obj, state, deps, task)
	local completed = 0
	helpers.assert_true(obj.stop_server_if_needed(function() completed = completed + 1 end))
	helpers.assert_eq(task.terminate_calls, 1, "next public stop must reach the newer task")
	helpers.assert_eq(deps.active_tasks.mlx_server, task)
	helpers.assert_eq(completed, 0)
	task:complete(15)
	helpers.assert_eq(completed, 1)
	helpers.assert_nil(deps.active_tasks.mlx_server)
	helpers.assert_nil(obj._server_lifecycle_owner)
end

helpers.describe("MLX cold launch retains diagnostic authority", function()
	for _, mode in ipairs({ "healthy", "throw_only" }) do
		helpers.it("keeps authorized cold launch healthy in mode " .. mode, function()
			with_start(mode, function(obj, state, deps)
				helpers.assert_true(state.b_accepted)
				helpers.assert_eq(state.b_cancel, 0)
				helpers.assert_eq(server_count(state), 1)
				helpers.assert_eq(obj._server_lifecycle_owner.identity.model, "Model-B")
				if mode == "throw_only" then helpers.assert_true(state.sink_threw) end
				stop_current(obj, state, deps, deps.active_tasks.mlx_server)
			end)
		end)
	end

	helpers.it("does not construct a native task after diagnostic revocation", function()
		with_start("revoked", function(obj, state, deps)
			helpers.assert_eq(server_count(state), 0, "revoked launch must not acquire a task")
			helpers.assert_eq(state.b_accepted, false)
			helpers.assert_eq(state.b_cancel, 1)
			helpers.assert_eq(state.b_success, 0)
			helpers.assert_nil(obj._server_lifecycle_owner)
			helpers.assert_nil(deps.active_tasks.mlx_server)
			local completed = 0
			helpers.assert_true(obj.stop_server_if_needed(function() completed = completed + 1 end, { kind = "shutdown" }))
			helpers.assert_eq(completed, 1)
			helpers.assert_eq(#state.cleanup, 0)
		end)
	end)

	for _, mode in ipairs({ "successor_current", "successor_revoked", "throw_after_successor" }) do
		helpers.it("preserves the established C capability in mode " .. mode, function()
			with_start(mode, function(obj, state, deps)
				helpers.assert_true(state.c_accepted)
				helpers.assert_not_nil(state.c_task, "C must really exist before B resumes")
				stop_current(obj, state, deps, state.c_task)
				helpers.assert_eq(server_count(state), 1, "old B must not construct a second server")
				helpers.assert_eq(state.b_accepted, false)
				helpers.assert_eq(state.b_cancel, 1)
				helpers.assert_eq(state.b_success, 0)
				if mode == "throw_after_successor" then helpers.assert_true(state.sink_threw) end
			end)
		end)
	end

	helpers.it("does not replace C's queued D intent", function()
		with_start("queued", function(obj, state, deps)
			helpers.assert_true(state.c_accepted)
			helpers.assert_true(state.d_accepted)
			helpers.assert_eq(state.d_cancelled, nil)
			helpers.assert_eq(state.b_accepted, false)
			helpers.assert_eq(state.b_cancel, 1)
			helpers.assert_eq(server_count(state), 1)
			helpers.assert_eq(deps.active_tasks.mlx_server, state.c_task)
			helpers.assert_eq(state.c_task.terminate_calls, 1, "D alone owns the queued predecessor stop")
			state.c_task:complete(15)
			helpers.assert_eq(obj._server_lifecycle_owner.identity.model, "Model-D")
			helpers.assert_eq(server_count(state), 2)
			stop_current(obj, state, deps, deps.active_tasks.mlx_server)
		end)
	end)

	helpers.it("does not publish B after nested C already settled", function()
		with_start("completed", function(obj, state, deps)
			helpers.assert_true(state.c_accepted)
			helpers.assert_true(state.c_stop_accepted)
			helpers.assert_true(state.c_stopped)
			helpers.assert_eq(server_count(state), 1, "completed newer C still supersedes B")
			helpers.assert_eq(state.b_accepted, false)
			helpers.assert_eq(state.b_cancel, 1)
			helpers.assert_eq(state.b_success, 0)
			helpers.assert_nil(obj._server_lifecycle_owner)
			helpers.assert_nil(deps.active_tasks.mlx_server)
			local completed = 0
			helpers.assert_true(obj.stop_server_if_needed(function() completed = completed + 1 end, { kind = "shutdown" }))
			helpers.assert_eq(completed, 1)
			helpers.assert_eq(#state.cleanup, 1, "only C owned a native listener")
		end)
	end)
end)
