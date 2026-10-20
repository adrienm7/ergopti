--- tests/unit/ui/menu/menu_llm/mlx/adoption/test_adoption_diagnostic_reentry.lua

--- ==============================================================================
--- MODULE: MLX Adoption Diagnostic Reentry
--- DESCRIPTION:
--- Drives the real server mixin and logger. A diagnostic sink can dispatch a
--- successor while the older adoption is paused; only that successor may own
--- the next stop. Native task/shell ports record requests without any OS signals.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_adoption = require("tests.support.modules.llm.processes.mlx_adoption_fixture")

--- Proves the following public stop still sees the successor's exact capability.
--- @param obj table Real server manager.
--- @param state table Fixture observations.
--- @param deps table Native task registry.
local function stop_successor(obj, state, deps)
	local stopped = 0
	local accepted = obj.stop_server_if_needed(function() stopped = stopped + 1 end)
	helpers.assert_eq(accepted, true, "next stop must remain operational after adoption reentry")
	helpers.assert_eq(state.b_task.terminate_calls, 1, "only the exact B capability receives the stop")
	helpers.assert_eq(obj._server_lifecycle_owner, state.b_owner)
	helpers.assert_eq(deps.active_tasks.mlx_server, state.b_task)
	helpers.assert_eq(stopped, 0, "acceptance is not native completion")
	state.b_task:complete(15)
	helpers.assert_eq(stopped, 1)
	helpers.assert_nil(deps.active_tasks.mlx_server)
	helpers.assert_nil(obj._server_lifecycle_owner)
	helpers.assert_eq(#state.cleanup, 1, "recorded listener absence proof follows B completion")
end

helpers.describe("MLX adoption diagnostic reentry", function()
	helpers.it("keeps healthy adoption task-free", function()
		with_adoption(function(obj, state, deps)
			helpers.assert_true(state.start_a(true))
			helpers.assert_eq(state.a_success, 1)
			helpers.assert_eq(state.a_cancel, 0)
			helpers.assert_nil(deps.active_tasks.mlx_server)
			helpers.assert_eq(obj._server_lifecycle_owner.phase, "adopted")
			helpers.assert_eq(obj._server_ready, true, "healthy adopted model is ready for the next caller")
			helpers.assert_eq(#state.tasks, 0)
		end)
	end)

	helpers.it("keeps healthy adoption after a diagnostic observer throws", function()
		with_adoption(function(obj, state)
			state.on_adopt = function() error("controlled observer error") end
			helpers.assert_true(state.start_a(true))
			helpers.assert_eq(#state.callback_errors, 1)
			helpers.assert_eq(state.a_success, 1)
			helpers.assert_eq(state.a_cancel, 0)
			helpers.assert_eq(obj._server_lifecycle_owner.identity.model, "Model-A")
		end)
	end)

	for _, guarded in ipairs({ true, false }) do
		helpers.it("preserves the next stop after successor dispatch with caller guard " .. tostring(guarded), function()
			with_adoption(function(obj, state, deps)
				state.on_adopt = function() state.current_a = false; state.start_b() end
				state.start_a(guarded)
				helpers.assert_true(state.b_accepted)
				helpers.assert_eq(#state.callback_errors, 0)
				stop_successor(obj, state, deps)
				helpers.assert_eq(state.a_success, 0)
				helpers.assert_eq(state.a_cancel, 1)
				helpers.assert_eq(state.owner_at_cancel, state.b_owner)
			end)
		end)
	end

	helpers.it("does not resurrect A after the nested B already completed", function()
		with_adoption(function(obj, state, deps)
			state.on_adopt = function() state.start_b(); state.b_task:complete(15) end
			state.start_a(false)
			helpers.assert_eq(#state.callback_errors, 0)
			helpers.assert_nil(deps.active_tasks.mlx_server)
			helpers.assert_nil(obj._server_lifecycle_owner, "completed B still supersedes the old adoption")
			helpers.assert_eq(state.a_success, 0)
			helpers.assert_eq(state.a_cancel, 1)
		end)
	end)

	helpers.it("preserves B when the diagnostic observer throws after dispatch", function()
		with_adoption(function(obj, state, deps)
			state.on_adopt = function() state.start_b(); error("after B dispatch") end
			state.start_a(false)
			helpers.assert_eq(#state.callback_errors, 1)
			stop_successor(obj, state, deps)
			helpers.assert_eq(state.a_success, 0)
			helpers.assert_eq(state.a_cancel, 1)
		end)
	end)
end)
