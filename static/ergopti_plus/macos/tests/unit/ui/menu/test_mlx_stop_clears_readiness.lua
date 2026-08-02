--- tests/unit/ui/menu/test_mlx_stop_clears_readiness.lua

--- ==============================================================================
--- MODULE: Regression — stopping the MLX server clears readiness intrinsically
--- DESCRIPTION:
--- Audit finding F-L15. stop_mlx_server_if_needed cleared only the in-process task
--- handle, not MLX _is_ready / _server_target. The invariant "MLX active => _is_ready
--- reflects the live server" held only because the leave path also killed the
--- process (forcing a cold relaunch + reset on return). If the kill lost the race
--- or a future change adopted a surviving process, a stale-true _is_ready with an
--- old _server_target would dispatch predictions to a not-yet-warmed server — the
--- MLX twin of the Ollama bug. Fix: clear _server_target and call ApiMlx.reset_endpoints
--- on stop. The factory + real ApiMlx are heavy to drive; the teardown is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("stop_mlx_server_if_needed resets readiness intrinsically", function()
	helpers.it("clears _server_target and calls api_mlx.reset_endpoints", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/models_manager.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_actual_model_name")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/models_manager.lua source must be locatable")
		local idx = src:find("function obj.stop_mlx_server_if_needed", 1, true)
		helpers.assert_true(idx ~= nil, "models_manager must define stop_mlx_server_if_needed")
		local body = src:sub(idx, idx + 700)
		helpers.assert_true(body:find("obj._server_target = nil", 1, true) ~= nil,
			"stop must clear the server identity so readiness cannot describe a dead server")
		helpers.assert_true(body:find("api_mlx", 1, true) ~= nil and body:find("reset_endpoints", 1, true) ~= nil,
			"stop must call api_mlx.reset_endpoints() to force a fresh readiness verdict")
	end)
end)
