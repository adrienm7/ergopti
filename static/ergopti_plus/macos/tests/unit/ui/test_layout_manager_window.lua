--- tests/unit/ui/test_layout_manager_window.lua

--- ==============================================================================
--- MODULE: Layout Manager Window (macOS host)
--- DESCRIPTION:
--- The macOS host of the layout manager page sends the strings strings.json
--- declares, and a controller bound to a window pushes into that exact window
--- only, so a late callback of a closed window never writes into its successor
--- (layout-manager-bridge).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

helpers.describe("layout manager window (macOS)", function()
	helpers.it("sends every string the page declares, translated (layout-manager-bridge)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		local declared = Json.decode(assert(io.open(helpers.shared("ui/layout_manager/strings.json"), "rb")):read("*a"))
		local strings = Host._page_strings()
		local count = 0
		for _, key in ipairs(declared.keys) do
			helpers.assert_type(strings[key], "string", key .. " is sent to the page")
			count = count + 1
		end
		helpers.assert_true(count >= 35, "the page declares its strings")
	end)

	helpers.it("pushes only into the window it was created for (layout-manager-bridge)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		local refreshed = 0
		local saved = package.loaded["modules.keymap.layout_registry"]
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function(on_done) refreshed = refreshed + 1; on_done({}) end,
		}
		local evaluated = {}
		local stale = { evaluateJavaScript = function(_, js) evaluated[#evaluated + 1] = js end }
		local ok, err = pcall(function()
			local controller = Host._controller_for(stale)
			helpers.assert_true(controller.on_message({ action = "refresh" }) == true)
			helpers.assert_true(controller.on_message({ action = "ready" }) == true)
			helpers.assert_true(controller.on_message({ action = "ready" }) == false, "dual native/page readiness is deduplicated")
			helpers.assert_true(controller.on_message({ action = "refresh" }) == true, "explicit refresh remains available")
			local replacement = Host._controller_for(stale)
			helpers.assert_true(replacement.on_message({ action = "ready" }) == true, "new window owns new readiness")
		end)
		package.loaded["modules.keymap.layout_registry"] = saved
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(refreshed, 4, "each initial window refresh runs once, with explicit refreshes preserved")
		helpers.assert_eq(#evaluated, 0, "a window that is not the current one receives nothing")
	end)
end)
