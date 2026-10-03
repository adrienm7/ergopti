--- tests/unit/ui/menu/test_menu_init_hk_box_forward_declare.lua

--- The retired dashboard shortcut boxes and binders must never return to boot.
local helpers = require("tests.helpers")
local src = helpers.read_driver_source("local function safe_require")
helpers.assert_true(type(src) == "string" and #src > 0, "the actual menu owner must be readable")
helpers.describe("Metrics native binding retirement", function()
	helpers.it("removes both dedicated owners while keeping ordinary dashboard actions", function()
		for _, retired in ipairs({ "_metrics_hk_box", "_apps_time_hk_box", "apply_metrics_shortcut", "apply_apps_time_shortcut", "replace_managed_hotkey" }) do
			helpers.assert_nil(src:find(retired, 1, true), retired .. " is retired")
		end
		helpers.assert_true(src:find("open_metrics_typing", 1, true) ~= nil)
		helpers.assert_true(src:find("open_metrics_apps", 1, true) ~= nil)
	end)
end)
