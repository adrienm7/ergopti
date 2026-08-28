--- tests/unit/ui/test_menu_about_sparkle_ownership.lua

--- ==============================================================================
--- MODULE: Regression — Sparkle is the only macOS update installer
--- DESCRIPTION:
--- The About menu used to fetch the full archive into Lua memory, unzip it, and
--- rename the nested Hammerspoon bundle without authenticating the artifact.
--- The menu may now request a native check, but it must own no install primitive.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_about: Sparkle owns every update mutation", function()
	helpers.it("contains only the narrow native update command", function()
		local source = helpers.read_driver_source('require("adapters.update_launcher")')
		helpers.assert_true(source ~= nil, "menu_about.lua source must be locatable")
		local code = source:gsub("%-%-[^\n]*", "")

		helpers.assert_true(
			code:find("UpdateLauncher.request_check()", 1, true) ~= nil,
			"the menu action must delegate to the native Sparkle controller"
		)
		for _, forbidden in ipairs({
			"hs.http.asyncGet",
			"TaskLifecycle",
			"io.open",
			"os.rename",
			"hs.reload",
			"temporaryDirectory",
			"_active_tasks",
		}) do
			helpers.assert_true(
				code:find(forbidden, 1, true) == nil,
				"the Lua update menu must not retain installer primitive: " .. forbidden
			)
		end
	end)
end)
