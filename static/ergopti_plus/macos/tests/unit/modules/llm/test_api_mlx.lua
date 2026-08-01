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

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local ApiMlx = helpers.load_with_stubs("modules.llm.api_mlx")




-- =====================================
-- =====================================
-- ======= 1/ Module surface ===========
-- =====================================
-- =====================================

helpers.describe("ApiMlx module surface", function()
	helpers.it("exposes core public functions", function()
		helpers.assert_eq(type(ApiMlx.is_ready), "function")
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

	-- set_restart_hook was removed with the code that called it: api_mlx_discovery
	-- records that reading data[1].id as the loaded model and "fixing" mismatches
	-- with zombie kills and forced restarts was chasing a phantom. The registration
	-- side outlived its only invoker. The case that stood here asserted nothing
	-- anyway — it called the setter twice and checked no result.
	helpers.it("no longer exposes the restart hook, whose only caller was removed", function()
		helpers.assert_eq(ApiMlx.set_restart_hook, nil,
			"a registration API with no invoker is dead code that reads as a safety net")
	end)

	helpers.it("set_active_server_pgid accepts numeric and nil", function()
		ApiMlx.set_active_server_pgid(12345)
		ApiMlx.set_active_server_pgid(nil)
	end)

	helpers.it("cancel_streaming is a no-op when nothing is in flight", function()
		ApiMlx.cancel_streaming()
	end)
end)
