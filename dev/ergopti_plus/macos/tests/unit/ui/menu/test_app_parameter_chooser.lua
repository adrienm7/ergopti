--- tests/unit/ui/menu/test_app_parameter_chooser.lua

--- ==============================================================================
--- MODULE: The app parameter is picked, not typed (macOS)
--- DESCRIPTION:
--- Binding open_app from the gestures menu or the shortcut editors opens the
--- /Applications chooser (dialog_util.choose_application) instead of a text
--- prompt; the chosen bundle is validated and stored against the binding, and
--- a cancelled chooser stores nothing.
---
--- ROOT CAUSE ENCODED:
--- open_app needs an application: a free-text prompt would leave the user to
--- guess an application's exact name or bundle identifier.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A gestures facade whose store records what it is given.
--- @param stored table Receives { binding, action, value } rows.
--- @return table
local function facade(stored)
	return {
		get_action_label = function(action) return action end,
		parameter_prompt = function() return "Application to open:" end,
		parameter_error = function() return "refused" end,
		get_action_parameter = function() return "" end,
		validate_action_parameter = function(_, value) return type(value) == "string" and value ~= "" end,
		set_action_parameter = function(binding, action, value)
			stored[#stored + 1] = { binding = binding, action = action, value = value }
			return true
		end,
	}
end

helpers.describe("open_app parameter chooser (macOS)", function()
	helpers.it("the chooser's application is stored against the binding", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")
		local dialog = package.loaded["infra.dialog_util"]
		local asked = {}
		dialog.choose_application = function(message)
			asked[#asked + 1] = message
			return "/Applications/Safari.app"
		end
		dialog.text_prompt = function() error("an application is never typed") end

		local stored = {}
		helpers.assert_eq(SU.prompt_action_parameter(facade(stored), "keyboard__cmd_1", "open_app", "app"), true)
		helpers.assert_eq(asked, { "Application to open:" })
		helpers.assert_eq(stored, { { binding = "keyboard__cmd_1", action = "open_app", value = "/Applications/Safari.app" } })
	end)

	helpers.it("choose_application opens /Applications on application bundles only", function()
		local calls = {}
		local answer = { ["1"] = "/Applications/Notes.app" }
		local Dialog = helpers.load_with_stubs("infra.dialog_util", {
			dialog = {
				chooseFileOrFolder = function(...)
					calls[#calls + 1] = table.pack(...)
					return answer
				end,
			},
		})
		helpers.assert_eq(Dialog.choose_application("Application to open:"), "/Applications/Notes.app")
		local call = calls[1]
		helpers.assert_eq({ call[1], call[2], call[3], call[4], call[5], call[7] },
			{ "Application to open:", "/Applications", true, false, false, true })
		helpers.assert_eq(call[6], { "app" }, "application bundles only")
		answer = nil
		helpers.assert_eq(Dialog.choose_application("Application to open:"), nil, "cancelled")
	end)

	helpers.it("a cancelled chooser stores nothing", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")
		package.loaded["infra.dialog_util"].choose_application = function() return nil end

		local stored = {}
		helpers.assert_eq(SU.prompt_action_parameter(facade(stored), "tap_3", "open_app", "app"), false)
		helpers.assert_eq(#stored, 0)
	end)
end)
