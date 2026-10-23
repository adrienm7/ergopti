--- tests/meta/lua_safety/test_mlx_orphan_kill_resolves_port.lua

--- ==============================================================================
--- MODULE: MLX orphan kill resolves its port (meta)
--- DESCRIPTION:
--- The MLX orphan kill must resolve the port through get_port, never hard-code it.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("MLX orphan kill resolves its port", function()

	-- =========================================
	-- ===== 1) MLX port — no hardcoded 49317
	-- =========================================

	helpers.it("the MLX orphan kill must not hard-code port 49317 (resolved via get_port)", function()
		-- The bug: lsof -tiTCP:49317 regardless of user-configured port.
		-- The fix: resolve port via api_mlx.get_port(). The sweep moved into the shared
		-- menu_llm.terminate_orphan_mlx_server() (called by BOTH the shutdown callback
		-- and script_quit) so the two quit paths cannot drift (F-M7).
		local init_src = read_source("local function has_common_hotstring_groups") -- init.lua
		assert(init_src, "init.lua must be readable")
		assert(not init_src:find("tiTCP:49317", 1, true),
			"init.lua: must not hard-code port 49317")
		assert(init_src:find("terminate_orphan_mlx_server", 1, true),
			"init.lua: shutdownCallback must delegate to the shared terminate_orphan_mlx_server")

		local menu_src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		assert(menu_src, "menu_llm/init.lua must be readable")
		assert(not menu_src:find("tiTCP:49317", 1, true),
			"menu_llm: terminate_orphan_mlx_server must not hard-code port 49317")
		assert(menu_src:find("get_port", 1, true),
			"menu_llm: terminate_orphan_mlx_server must resolve the live MLX port via get_port()")
	end)

end)
