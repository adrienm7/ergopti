--- tests/unit/modules/llm/mlx/test_mlx_warmup_stop_pending_discovery.lua

--- ==============================================================================
--- MODULE: MLX warmup stop while a discovery poll awaits its native exit
--- DESCRIPTION:
--- Issue #104: turning the AI off after a failed MLX bootstrap logged
--- "Warmup discovery cancellation retained exact cleanup debt", "MLX warmup
--- owner remains unsettled after logical revocation" and "LLM settlement 'MLX
--- warmup stop' did not commit". The only debt was a poll task whose SIGTERM
--- awaited its native exit, which discovery keeps and fences. The warmup stop
--- commits then; a real discovery refusal still fails it
--- (mlx-warmup-stop-pending-discovery).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real api_mlx against a discovery double answering `stop`.
--- @param stop function Discovery stop double.
--- @return boolean settled stop_warmup() result.
--- @return string rendered Log lines written meanwhile.
local function stop_with(stop)
	local saved = package.loaded["modules.llm.api_mlx_discovery"]
	local saved_api = package.loaded["modules.llm.api_mlx"]
	local result, rendered
	local ok, err = xpcall(function()
		package.loaded["modules.llm.api_mlx_discovery"] = {
			init = function() end, reset = function() return true end, stop = stop,
			resume = function() return true end, is_active = function() return false end,
			set_base_url = function() end, is_discovered = function() return false end,
			discover = function() return true end, mark_undiscovered = function() end,
			set_expected_model_id = function() end, onSettled = function() return true end,
		}
		package.loaded["modules.llm.api_mlx"] = nil
		local ApiMlx = helpers.load_with_stubs("modules.llm.api_mlx")
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local call_ok, settled = pcall(ApiMlx.stop_warmup)
		Logger.set_sink(nil)
		if not call_ok then error(settled, 0) end
		result, rendered = settled, table.concat(lines, "\n")
	end, debug.traceback)
	package.loaded["modules.llm.api_mlx_discovery"] = saved
	package.loaded["modules.llm.api_mlx"] = saved_api
	if not ok then error(err, 0) end
	return result, rendered
end

helpers.describe("MLX warmup stop with a pending discovery exit (mlx-warmup-stop-pending-discovery)", function()
	helpers.it("commits when only a poll task's native exit is outstanding", function()
		local settled, rendered = stop_with(function() return false, "pending" end)
		helpers.assert_eq(settled, true, rendered)
		helpers.assert_true(rendered:find("[ERROR]", 1, true) == nil, rendered)
	end)

	helpers.it("still fails on a real discovery refusal", function()
		local settled, rendered = stop_with(function() return false end)
		helpers.assert_eq(settled, false)
		helpers.assert_contains(rendered, "Warmup discovery cancellation retained exact cleanup debt")
	end)
end)
