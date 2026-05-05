--- tests/unit/modules/llm/test_api_mlx.lua

--- ==============================================================================
--- MODULE: llm.api_mlx Unit Tests
--- DESCRIPTION:
--- Smoke-tests the side-effect-free portions of the MLX controller surface:
--- restart-hook registration, server PGID accessor, and readiness flag default.
--- The networked discover_endpoints / fetch_* paths are deferred to integration
--- testing — they require hs.task with a live MLX server.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local ApiMlx = helpers.load_with_stubs("modules.llm.api_mlx")




-- =====================================
-- =====================================
-- ======= 1/ Module surface ===========
-- =====================================
-- =====================================

helpers.describe("ApiMlx module surface", function()
	helpers.it("exposes core public functions", function()
		helpers.assert_eq(type(ApiMlx.is_ready), "function")
		helpers.assert_eq(type(ApiMlx.set_restart_hook), "function")
		helpers.assert_eq(type(ApiMlx.set_active_server_pgid), "function")
		helpers.assert_eq(type(ApiMlx.cancel_streaming), "function")
		helpers.assert_eq(type(ApiMlx.warmup), "function")
		helpers.assert_eq(type(ApiMlx.fetch_batch), "function")
		helpers.assert_eq(type(ApiMlx.fetch_parallel), "function")
		helpers.assert_eq(type(ApiMlx.fetch_sequential), "function")
	end)

	helpers.it("is_ready defaults to false", function()
		helpers.assert_eq(ApiMlx.is_ready(), false)
	end)

	helpers.it("set_restart_hook accepts a function or nil", function()
		ApiMlx.set_restart_hook(function() end)
		ApiMlx.set_restart_hook(nil)
	end)

	helpers.it("set_active_server_pgid accepts numeric and nil", function()
		ApiMlx.set_active_server_pgid(12345)
		ApiMlx.set_active_server_pgid(nil)
	end)

	helpers.it("cancel_streaming is a no-op when nothing is in flight", function()
		ApiMlx.cancel_streaming()
	end)
end)
