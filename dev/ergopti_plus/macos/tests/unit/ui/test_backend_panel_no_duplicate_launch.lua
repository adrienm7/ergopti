--- tests/unit/ui/test_backend_panel_no_duplicate_launch.lua

--- ==============================================================================
--- MODULE: Backend Panel — No Duplicate MLX Server Launch (regression)
--- DESCRIPTION:
--- Guards against the regression where switching to the MLX backend fired both
--- switch_model() (which calls models_mgr.check_requirements and starts the
--- server) AND a redundant force_mlx_check() 0.5 s later via hs.timer.doAfter.
--- The second call races the first and tries to spawn a second server process
--- against the same port. The fix removes the force_mlx_check call; switch_model
--- already handles the server start through check_requirements.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =====================================================================
-- =====================================================================
-- ======= 1/ Source-level duplicate-launch check ======================
-- =====================================================================
-- =====================================================================

helpers.describe("backend_panel: no duplicate MLX server launch on backend switch", function()

	helpers.it("source does not call force_mlx_check after switch_model", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/backend_panel.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("\"menu.llm.backend_ollama_suffix\"")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/backend_panel.lua source must be locatable")

		-- The fix removes the redundant force_mlx_check call that launched a second
		-- server immediately after switch_model already started one.
		helpers.assert_true(
			src:find("force_mlx_check", 1, true) == nil,
			"backend_panel.lua must not call force_mlx_check — switch_model already starts the server via check_requirements")
	end)

	helpers.it("source still calls switch_model for the MLX target model", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/backend_panel.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("\"menu.llm.backend_ollama_suffix\"")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/backend_panel.lua source must be locatable")

		helpers.assert_true(
			src:find("switch_model(target_model)", 1, true) ~= nil,
			"backend_panel.lua must still call switch_model(target_model) to start the server")
	end)

end)
