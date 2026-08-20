--- tests/unit/modules/gestures/test_script_quit_revokes_karabiner_lease.lua

--- ==============================================================================
--- MODULE: script_quit Waits for the Exact Karabiner Lease Fence
--- DESCRIPTION:
--- Drives the user-facing gesture action and proves it delegates one deferred
--- exit transaction. The root coordinator, not the gesture callback, owns the
--- fence, sibling teardown and process exit.
---
--- ROOT CAUSE ENCODED: the old action called platform.remap.shutdown and then
--- scheduled os.exit without waiting for STOPPED. It also dismantled keylogger
--- and MLX siblings inline, so managed F17 output could outlive its consumers.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local quit_spy = { count = 0, result = true }
package.loaded["infra.termination_coordinator"] = {
	request_exit = function(reason, code)
		quit_spy.count = quit_spy.count + 1
		quit_spy.reason = reason
		quit_spy.code = code
		return quit_spy.result
	end,
}
local Actions = helpers.load_with_stubs("modules.gestures.actions")

helpers.describe("gestures.actions: script_quit exact-fence transaction", function()
	helpers.it("leaves the gesture stack before requesting one coordinated exit", function()
		quit_spy = { count = 0, result = true }
		local saved_do_after = _G.hs.timer.doAfter
		local scheduled_delay, scheduled_callback
		_G.hs.timer.doAfter = function(delay, callback)
			scheduled_delay, scheduled_callback = delay, callback
			return { stop = function() end }
		end

		local ok, dispatched = pcall(Actions.execute_single, "script_quit")
		helpers.assert_true(ok, "executing script_quit must not raise: " .. tostring(dispatched))
		helpers.assert_true(dispatched ~= nil, "execute_single must report dispatch")
		helpers.assert_eq(quit_spy.count, 0,
			"the eventtap/gesture stack must return before lifecycle teardown starts")
		helpers.assert_eq(scheduled_delay, 0)
		helpers.assert_true(type(scheduled_callback) == "function")

		scheduled_callback()
		_G.hs.timer.doAfter = saved_do_after
		helpers.assert_eq(quit_spy.count, 1)
		helpers.assert_eq(quit_spy.reason, "script_quit")
		helpers.assert_eq(quit_spy.code, 0)
	end)

	helpers.it("does not bypass a rejected fence with a direct exit", function()
		quit_spy = { count = 0, result = false }
		local saved_do_after = _G.hs.timer.doAfter
		local scheduled_callback
		_G.hs.timer.doAfter = function(_delay, callback)
			scheduled_callback = callback
			return { stop = function() end }
		end

		local saved_exit = os.exit
		local direct_exits = 0
		os.exit = function() direct_exits = direct_exits + 1 end
		local ok, dispatched = pcall(Actions.execute_single, "script_quit")
		helpers.assert_true(ok, "executing script_quit must not raise: " .. tostring(dispatched))
		scheduled_callback()
		os.exit = saved_exit
		_G.hs.timer.doAfter = saved_do_after

		helpers.assert_eq(quit_spy.count, 1)
		helpers.assert_eq(direct_exits, 0,
			"only the coordinator may exit after proving the exact fence")
	end)

	helpers.it("falls back to the coordinator when timer scheduling throws or returns no handle", function()
		local saved_do_after = _G.hs.timer.doAfter
		local saved_exit = os.exit
		local direct_exits = 0
		local results = {}
		os.exit = function() direct_exits = direct_exits + 1 end

		for _, case in ipairs({
			{ label = "throw", schedule = function() error("timer scheduling fault") end },
			{ label = "nil", schedule = function() return nil end },
			{ label = "false", schedule = function() return false end },
		}) do
			quit_spy = { count = 0, result = true }
			_G.hs.timer.doAfter = case.schedule
			local ok, dispatched = pcall(Actions.execute_single, "script_quit")
			results[#results + 1] = {
				label = case.label,
				ok = ok,
				dispatched = dispatched,
				count = quit_spy.count,
				reason = quit_spy.reason,
				code = quit_spy.code,
			}
		end

		_G.hs.timer.doAfter = saved_do_after
		os.exit = saved_exit
		for _, result in ipairs(results) do
			helpers.assert_true(result.ok,
				result.label .. " scheduling failure must not escape script_quit: "
				.. tostring(result.dispatched))
			helpers.assert_eq(result.count, 1,
				result.label .. " scheduling failure must request the controlled exit directly")
			helpers.assert_eq(result.reason, "script_quit")
			helpers.assert_eq(result.code, 0)
		end
		helpers.assert_eq(direct_exits, 0,
			"timer scheduling failure must never bypass the coordinator with os.exit")
	end)
end)

helpers.describe("menu_llm.terminate_orphan_mlx_server reaps the detached server", function()
	helpers.it("source: defines terminate_orphan_mlx_server with the pgrep + lsof sweep", function()
		local src = helpers.read_driver_source("local function format_shortcut_title")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/init.lua source must be locatable")
		local idx = src:find("function M.terminate_orphan_mlx_server", 1, true)
		helpers.assert_true(idx ~= nil, "menu_llm must define terminate_orphan_mlx_server")
		local body = src:sub(idx, idx + 600)
		helpers.assert_true(body:find("pgrep -f 'mlx_lm.*server'", 1, true) ~= nil,
			"must pgrep-kill the detached mlx_lm.server")
		helpers.assert_true(body:find("lsof -tiTCP:", 1, true) ~= nil,
			"must free the MLX listening port via lsof")
		helpers.assert_true(body:find("get_port", 1, true) ~= nil,
			"must read the port from the single source api_mlx.get_port()")
	end)

	helpers.it("source: root teardown delegates to the shared helper", function()
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")
		helpers.assert_true(src:find("terminate_orphan_mlx_server", 1, true) ~= nil,
			"root teardown must call the shared terminate_orphan_mlx_server")
	end)
end)
