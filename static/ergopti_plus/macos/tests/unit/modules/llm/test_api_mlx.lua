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

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end




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
		helpers.assert_eq(ApiMlx.cancel_streaming(), true)
	end)

	helpers.it("retains a timeout whose native cancellation failed", function()
		local stream = get_upvalue(ApiMlx.cancel_streaming, "_stream")
		local scheduler = get_upvalue(ApiMlx.cancel_streaming, "TimerScheduler")
		helpers.assert_not_nil(stream)
		helpers.assert_not_nil(scheduler)
		local previous_cancel = scheduler.cancel
		local handle = { timer = {} }
		stream.timeout = handle
		stream.task = nil
		scheduler.cancel = function(candidate)
			helpers.assert_eq(candidate, handle)
			return false
		end

		helpers.assert_eq(ApiMlx.cancel_streaming(), false)
		helpers.assert_eq(stream.timeout, handle,
			"a failed stop must retain the exact timer capability for retry")
		scheduler.cancel = function() return true end
		helpers.assert_eq(ApiMlx.cancel_streaming(), true)
		helpers.assert_eq(stream.timeout, nil)
		scheduler.cancel = previous_cancel
	end)

	helpers.it("retains a task whose native termination raises, then retries it", function()
		local stream = get_upvalue(ApiMlx.cancel_streaming, "_stream")
		local calls = 0
		local task = {
			terminate = function()
				calls = calls + 1
				error("native terminate failed")
			end,
		}
		stream.timeout = nil
		stream.task = task
		helpers.assert_eq(ApiMlx.cancel_streaming(), false)
		helpers.assert_eq(stream.task, task)

		task.terminate = function() calls = calls + 1; return true end
		helpers.assert_eq(ApiMlx.cancel_streaming(), true)
		helpers.assert_eq(stream.task, nil)
		helpers.assert_eq(calls, 2)
	end)
end)
