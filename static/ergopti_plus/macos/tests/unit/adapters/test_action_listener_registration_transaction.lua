--- tests/unit/adapters/test_action_listener_registration_transaction.lua

--- ==============================================================================
--- MODULE: Synthetic Action Listener Registration Transaction
--- DESCRIPTION:
--- A native delayed-timer allocation failure must not consume one of the fixed
--- listener slots. The same adapter instance must accept the full advertised
--- capacity afterwards and release every registration cleanly.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_with_third_timer_failure()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local real_new = hs_stub.timer.delayed.new
	local creations = 0
	hs_stub.timer.delayed.new = function(...)
		creations = creations + 1
		-- synthetic_input creates two lifecycle dispatchers at module load. The
		-- third delayed timer is the lazily allocated action-listener dispatcher.
		if creations == 3 then error("action dispatcher allocation failed") end
		return real_new(...)
	end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.synthetic_input"] = nil
	return require("adapters.synthetic_input")
end


local function load_with_first_dispatch_start_failure()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local real_new = hs_stub.timer.delayed.new
	local creations = 0
	hs_stub.timer.delayed.new = function(...)
		creations = creations + 1
		local handle = real_new(...)
		if creations == 3 then
			local real_start = handle.start
			local first = true
			handle.start = function(self, ...)
				if first then first = false; return false end
				return real_start(self, ...)
			end
		end
		return handle
	end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.synthetic_input"] = nil
	return require("adapters.synthetic_input")
end


helpers.describe("synthetic action listener registration is transactional", function()
	helpers.it("does not leak a capacity slot when dispatcher creation throws", function()
		local SyntheticInput = load_with_third_timer_failure()
		local ok = pcall(SyntheticInput.register_action_listener,
			"failed", function() end)
		helpers.assert_eq(ok, false,
			"the control must exercise the native dispatcher allocation failure")

		for index = 1, SyntheticInput.CONSUMER_LIMIT do
			helpers.assert_true(SyntheticInput.register_action_listener(
				"listener-" .. index, function() end))
		end
		for index = 1, SyntheticInput.CONSUMER_LIMIT do
			helpers.assert_true(SyntheticInput.unregister_action_listener(
				"listener-" .. index))
		end

		helpers.assert_true(SyntheticInput.register_action_listener(
			"post-cleanup", function() end),
			"all slots must be reusable after exact unregister")
		helpers.assert_true(SyntheticInput.unregister_action_listener("post-cleanup"))
	end)

	helpers.it("rolls back an unscheduled catch-up listener and permits retry", function()
		local SyntheticInput = load_with_first_dispatch_start_failure()
		local stale_epoch = {}
		helpers.assert_eq(SyntheticInput.register_action_listener(
			"keymap", function() end, stale_epoch), false,
			"a listener needing catch-up is not committed without a live dispatcher")
		helpers.assert_eq(SyntheticInput.unregister_action_listener("keymap"), false,
			"the failed registration must leave no hidden listener behind")

		helpers.assert_true(SyntheticInput.register_action_listener(
			"keymap", function() end, stale_epoch),
			"the retained native dispatcher must make the next attempt recoverable")
		helpers.assert_true(SyntheticInput.unregister_action_listener("keymap"))
	end)
end)

return true
