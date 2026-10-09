--- tests/unit/ui/test_configured_gesture_label.lua

--- ==============================================================================
--- MODULE: Configured Gesture Menu Label Tests
--- DESCRIPTION:
--- Exercises the real assignment and parameter owners used by the tray's
--- four-finger display label, including literal URL punctuation.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

helpers.describe("configured gesture menu label", function()
	helpers.it("replaces the marker on the four-finger label", function()
		local original = package.loaded["infra.i18n"]
		local manager_before = package.loaded["modules.gestures.manager"]
		local ok, failure = xpcall(function()
			local file = assert(io.open(helpers.driver_root() .. "/../_shared/data/locales/fr.json", "rb"))
			local strings = json.decode(file:read("*a"))
			file:close()
			package.loaded["infra.i18n"] = { get = function(key) return strings[key] or key end }
			local manager = helpers.load_module("modules.gestures.manager")
			manager.init({ persist = false })
			local url = "https://apple.com/?q=[x]&part=50%"
			helpers.assert_true(manager.set_action("tap_4", "open_url"))
			helpers.assert_true(manager.set_action_parameter("tap_4", "open_url", url))
			local prefix = assert(strings["sg_actions.open_url"]:match("^(.-)%[[^%[%]]*%]$"))
			helpers.assert_eq(manager.get_action_display_label("tap_4"), prefix .. "[" .. url .. "]")
		end, debug.traceback)
		package.loaded["infra.i18n"] = original
		package.loaded["modules.gestures.manager"] = manager_before
		assert(ok, failure)
	end)
end)
