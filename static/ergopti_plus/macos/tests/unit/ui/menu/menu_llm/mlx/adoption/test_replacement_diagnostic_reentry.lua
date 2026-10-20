--- tests/unit/ui/menu/menu_llm/mlx/adoption/test_replacement_diagnostic_reentry.lua

--- ==============================================================================
--- MODULE: MLX Replacement Diagnostic Reentry
--- DESCRIPTION:
--- A real Logger sink can revoke a replacement or establish a newer one. The
--- resumed older request may not sign a stop against the current capability.
--- Native task and shell operations are recording ports and send no OS signals.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_adoption = require("tests.support.modules.llm.processes.mlx_adoption_fixture")

--- Pauses A at its replacement diagnostic while a real manager transition runs.
--- @param mode string Controlled reentry at the diagnostic sink.
--- @param scenario function Receives real manager and recording observations.
local function with_replacement(mode, scenario)
	with_adoption(function(obj, state, deps)
		state.start_b()
		local predecessor = state.b_task
		helpers.assert_true(state.b_accepted)
		helpers.assert_not_nil(predecessor)
		state.original_b = predecessor
		require("infra.logger").set_sink(function(line)
			if state.replacement_observed or not line:find("MLX server identity changed", 1, true) then return end
			state.replacement_observed = true
			if mode == "healthy" then return end
			if mode == "throw_only" then
				state.sink_threw = true
				error("controlled replacement diagnostic failure")
			end
			if mode == "revoked" or mode == "successor_revoked" then state.current_a = false end
			if mode == "revoked" then return end
			state.c_accepted = obj.start_server("Model-C", function() state.c_success = true end,
				function() state.c_cancelled = true end)
			if mode ~= "queued" then
				predecessor:complete(15)
				state.c_task, state.c_owner = deps.active_tasks.mlx_server, obj._server_lifecycle_owner
			end
			if mode == "completed" then
				state.c_stop_accepted = obj.stop_server_if_needed(function() state.c_stopped = true end)
				state.c_task:complete(15)
			elseif mode == "throw_after_successor" then
				state.sink_threw = true
				error("controlled replacement diagnostic failure after C")
			end
		end)
		state.a_accepted = state.start_a(true)
		helpers.assert_true(state.replacement_observed, "the real replacement diagnostic must run")
		scenario(obj, state, deps)
	end)
end

--- Verifies exact public stop acceptance and settlement without sending signals.
--- @param obj table Real manager.
--- @param state table Recording observations.
--- @param deps table Native task registry.
--- @param task table Exact current native capability.
local function stop_current(obj, state, deps, task)
	local owner, stopped = obj._server_lifecycle_owner, 0
	helpers.assert_true(obj.stop_server_if_needed(function() stopped = stopped + 1 end))
	helpers.assert_eq(task.terminate_calls, 1, "only the new explicit stop signs this capability")
	helpers.assert_eq(obj._server_lifecycle_owner, owner)
	helpers.assert_eq(deps.active_tasks.mlx_server, task)
	helpers.assert_eq(stopped, 0)
	task:complete(15)
	helpers.assert_eq(stopped, 1)
	helpers.assert_nil(deps.active_tasks.mlx_server)
	helpers.assert_nil(obj._server_lifecycle_owner)
end

helpers.describe("MLX replacement requires fresh diagnostic authority", function()
	for _, mode in ipairs({ "healthy", "throw_only" }) do
		helpers.it("keeps the authorized replacement healthy with diagnostic mode " .. mode, function()
			with_replacement(mode, function(obj, state)
				helpers.assert_true(state.a_accepted)
				helpers.assert_eq(state.original_b.terminate_calls, 1)
				helpers.assert_eq(state.a_success, 0)
				state.original_b:complete(15)
				helpers.assert_eq(obj._server_lifecycle_owner.identity.model, "Model-A")
				helpers.assert_eq(obj._server_ready, true)
				helpers.assert_eq(state.a_success, 1)
				helpers.assert_eq(state.a_cancel, 0)
				if mode == "throw_only" then helpers.assert_true(state.sink_threw) end
			end)
		end)
	end

	helpers.it("does not stop B when its replacement was revoked by the diagnostic", function()
		with_replacement("revoked", function(obj, state, deps)
			helpers.assert_eq(state.original_b.terminate_calls, 0, "revoked A cannot sign a stop")
			helpers.assert_eq(state.a_accepted, false)
			helpers.assert_eq(state.a_cancel, 1)
			helpers.assert_eq(state.a_success, 0)
			helpers.assert_eq(obj._server_lifecycle_owner.stop_requested, false)
			stop_current(obj, state, deps, state.original_b)
		end)
	end)

	for _, mode in ipairs({ "successor_revoked", "successor_current", "throw_after_successor" }) do
		helpers.it("does not stop the established C successor in mode " .. mode, function()
			with_replacement(mode, function(obj, state, deps)
				helpers.assert_true(state.c_accepted)
				helpers.assert_not_nil(state.c_task, "C must be established before the old frame resumes")
				helpers.assert_eq(state.c_owner.identity.model, "Model-C")
				helpers.assert_eq(state.original_b.terminate_calls, 1, "C's authorized predecessor stop remains exact")
				helpers.assert_eq(state.c_task.terminate_calls, 0, "old A cannot sign a stop against C")
				helpers.assert_eq(state.a_accepted, false)
				helpers.assert_eq(state.a_cancel, 1)
				helpers.assert_eq(state.a_success, 0)
				helpers.assert_eq(state.c_cancelled, nil)
				if mode == "throw_after_successor" then helpers.assert_true(state.sink_threw) end
				stop_current(obj, state, deps, state.c_task)
			end)
		end)
	end

	helpers.it("does not overwrite C's queued intent while B still owns native cleanup", function()
		with_replacement("queued", function(obj, state, deps)
			helpers.assert_true(state.c_accepted)
			helpers.assert_eq(state.c_cancelled, nil, "a newer queued successor cannot be cancelled by A")
			helpers.assert_eq(state.a_accepted, false)
			helpers.assert_eq(state.a_cancel, 1)
			helpers.assert_eq(state.original_b.terminate_calls, 1)
			state.original_b:complete(15)
			local successor = deps.active_tasks.mlx_server
			helpers.assert_not_nil(successor)
			helpers.assert_eq(obj._server_lifecycle_owner.identity.model, "Model-C")
			helpers.assert_eq(successor.terminate_calls, 0)
			stop_current(obj, state, deps, successor)
		end)
	end)

	helpers.it("does not resurrect A when both B and its newer C already completed", function()
		with_replacement("completed", function(obj, state, deps)
			helpers.assert_true(state.c_accepted)
			helpers.assert_true(state.c_stop_accepted)
			helpers.assert_true(state.c_stopped)
			helpers.assert_eq(state.original_b.terminate_calls, 1)
			helpers.assert_eq(state.c_task.terminate_calls, 1)
			helpers.assert_eq(state.a_accepted, false)
			helpers.assert_eq(state.a_cancel, 1)
			helpers.assert_eq(state.a_success, 0)
			helpers.assert_nil(obj._server_lifecycle_owner)
			helpers.assert_nil(deps.active_tasks.mlx_server)
			local stopped = 0
			helpers.assert_true(obj.stop_server_if_needed(function() stopped = stopped + 1 end, { kind = "shutdown" }))
			helpers.assert_eq(stopped, 1)
			helpers.assert_eq(#state.cleanup, 2, "only B and C required recorded listener cleanup")
		end)
	end)
end)
