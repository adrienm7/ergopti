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
---    that port MUST come from the request's captured target_port identity.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the uniquely anchored server-lifecycle source through the relocatable helper.
--- @return string source
local function read_models_manager_source()
	local src = helpers.read_driver_source("local function same_server_identity")
	helpers.assert_true(type(src) == "string" and src ~= "",
		"could not locate the uniquely anchored MLX server lifecycle source")
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

	helpers.it("derives the launch port from the request's captured identity", function()
		local src = read_models_manager_source()
		local capture_at = src:find(
			"local target_port = pinned_port or ApiMlx.get_port()", 1, true)
		local launch_at = capture_at and src:find(
			'--port " .. target_port .. " --decode-concurrency 1', capture_at, true)
			or nil
		helpers.assert_true(
			capture_at ~= nil and launch_at ~= nil and capture_at < launch_at,
			"the --port value must come from the request-captured target_port identity"
		)
	end)
end)
