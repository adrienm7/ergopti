--- tests/unit/ui/menu/menu_llm/test_models_manager_mlx_port.lua

--- ==============================================================================
--- MODULE: models_manager_mlx — launcher must pass --port
--- DESCRIPTION:
--- Locks down the bug where the bash launcher started mlx_lm.server WITHOUT a
--- --port flag. mlx_lm.server then binds its own 8080 default, silently ignoring
--- the centralized port (_shared/modules/llm/mlx_server.json + the user override). Every
--- client (warmup, discovery, health probe, boot cleanup) reads the configured
--- port via api_mlx.get_port(), so without --port the server and its clients
--- disagree the moment the port is anything other than 8080 — the centralized
--- port variable becomes a lie and predictions silently never fire.
---
--- FEATURES & RATIONALE:
--- 1. Source assertion (same style as the updateMenu guard): the launch command is
---    built inside an integration-tier closure not exercised by the unit harness,
---    so we assert on the source text instead.
--- 2. Encodes the ROOT CAUSE — the mlx_lm server invocation MUST carry --port AND
---    that port MUST come from the resolved MLX_PORT variable, never a literal.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the models_manager_mlx_server.lua source via the active package.path so
--- the test is independent of the runner's working directory. The bash launcher
--- (and its --port flag) lives in the server-lifecycle sibling module since the
--- start_server extraction; this test follows it there.
local function read_models_manager_source()
	local path = package.searchpath("ui.menu.menu_llm.models_manager_mlx_server", package.path)
	helpers.assert_true(type(path) == "string" and path ~= "",
		"could not resolve ui.menu.menu_llm.models_manager_mlx_server on package.path")
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open models_manager_mlx_server.lua")
	local src = fh:read("*a")
	fh:close()
	return src
end




-- =====================================================
-- =====================================================
-- ======= 1/ Launcher passes the resolved port ========
-- =====================================================
-- =====================================================

helpers.describe("models_manager_mlx — launcher binds the configured port", function()
	helpers.it("invokes `mlx_lm server` with a --port flag", function()
		local src = read_models_manager_source()
		-- The launcher line that starts the server. Without --port, mlx_lm binds 8080.
		helpers.assert_true(
			src:find("-m mlx_lm server", 1, true) ~= nil,
			"expected the mlx_lm server launch command in the source"
		)
		helpers.assert_true(
			src:find("--port", 1, true) ~= nil,
			"the mlx_lm server launch MUST pass --port or it ignores the configured port and binds 8080"
		)
	end)

	helpers.it("derives the launch port from the resolved MLX_PORT variable, not a literal", function()
		local src = read_models_manager_source()
		-- The exact concatenation that injects the resolved port into the bash command.
		helpers.assert_true(
			src:find("--port \" .. MLX_PORT", 1, true) ~= nil,
			"the --port value must come from MLX_PORT (api_mlx.get_port()), not a hardcoded number"
		)
	end)
end)
