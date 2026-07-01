--- tests/unit/llm/test_api_mlx_discovery_dead_constant_removed.lua

--- ==============================================================================
--- MODULE: Dead DISCOVERY_MODEL_ID_BYPASS_SEC constant removed (F-LOW-1)
--- DESCRIPTION:
--- DISCOVERY_MODEL_ID_BYPASS_SEC was carried over verbatim from the pre-split
--- monolithic api_mlx.lua, describing a model-ID-mismatch bypass mechanism
--- that was never wired up in api_mlx_discovery.lua — superseded by the
--- simpler "trust the --model launch argument, proceed straight to POST
--- probes" design actually implemented in do_poll(). The comment was
--- misleading (describing a mechanism the code no longer has), not the
--- surrounding logic; removed the dead constant and its comment.
--- ==============================================================================

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/llm/api_mlx_discovery.lua"
local fh = io.open(src_path, "r")
if not fh then error("api_mlx_discovery.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()




-- ==================================================================
-- ==================================================================
-- ======= 1/ F-LOW-1: dead DISCOVERY_MODEL_ID_BYPASS_SEC removed ==
-- ==================================================================
-- ==================================================================

helpers.describe("api_mlx_discovery.lua: dead constant removed (F-LOW-1)", function()

	helpers.it("DISCOVERY_MODEL_ID_BYPASS_SEC no longer appears anywhere in the file", function()
		helpers.assert_true(
			src:find("DISCOVERY_MODEL_ID_BYPASS_SEC", 1, true) == nil,
			"api_mlx_discovery.lua must not declare or reference the dead DISCOVERY_MODEL_ID_BYPASS_SEC constant (F-LOW-1)"
		)
	end)
end)
