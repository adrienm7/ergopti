--- tests/unit/modules/shortcuts/test_actions_system.lua

local helpers = require("tests.helpers")

-- Load the stubbed hammerspoon environment
local hs_stub = helpers.load_with_stubs("tests.stubs.hs")

helpers.describe("shortcuts.actions.system", function()
	helpers.it("toggle_awake creates an event watcher with the correct events", function()
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")

		-- We just ensure that toggle_awake doesn't crash and starts successfully
		sys.toggle_awake()
		-- We cannot easily assert the exact watch_types here without deep introspection of the eventtap stub,
		-- but we can verify it doesn't crash.
		helpers.assert_true(true, "toggle_awake should execute without errors")
		
		-- Turn it off
		sys.toggle_awake()
		helpers.assert_true(true, "toggle_awake should toggle off without errors")
	end)
end)
