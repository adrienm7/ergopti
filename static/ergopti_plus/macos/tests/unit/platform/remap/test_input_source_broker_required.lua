--- tests/unit/platform/remap/test_input_source_broker_required.lua

--- ==============================================================================
--- MODULE: Karabiner Input Source Broker Commitment
--- DESCRIPTION:
--- Guards the transitive initialization contract: Ergopti remapping may not
--- publish a running bridge when no layout-change observer was acquired.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Karabiner layout observation commitment", function()
	helpers.it("requires exact watcher success before initialization can return true", function()
		local source = helpers.read_driver_source("function M.init(file_system)")
		helpers.assert_true(source ~= nil, "platform.remap.init source must be locatable")
		local start_at = source:find("local input_source_watcher_started = timed", 1, true)
		local refuse_at = source:find("if input_source_watcher_started ~= true then", 1, true)
		local success_at = source:find("Karabiner bridge initialized", 1, true)
		helpers.assert_true(start_at ~= nil and refuse_at ~= nil and success_at ~= nil,
			"the required layout-watcher acquisition and refusal branch must exist")
		helpers.assert_true(start_at < refuse_at and refuse_at < success_at,
			"layout observation must commit before bridge initialization succeeds")
		local refusal = source:sub(refuse_at, refuse_at + 500)
		helpers.assert_true(refusal:find("_running = false", 1, true) ~= nil
			and refusal:find("_state.enabled = false", 1, true) ~= nil
			and refusal:find("return false", 1, true) ~= nil,
			"watcher refusal must fail closed before remapping can deploy")
	end)
end)
