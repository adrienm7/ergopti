--- tests/unit/ui/test_menu_keyboard_slots_input_source_warning.lua

--- ==============================================================================
--- MODULE: Keyboard Slot Input-Source Warning (input-source-conflict)
--- DESCRIPTION:
--- Binding a chord macOS's input-source shortcut still owns warns once, with a
--- button that opens the Keyboard settings; a free chord shows nothing.
---
--- ROOT CAUSE ENCODED:
--- A Ctrl+Space binding did nothing while macOS kept Ctrl+Space for "Select the
--- previous input source", and nothing told the user where to change it.
--- ==============================================================================

local helpers = require("tests.helpers")

local DISPLACED = {
	"infra.deferred_work",
	"infra.dialog_util",
	"modules.shortcuts.input_source_conflict",
	"ui.menu.menu_keyboard_slots",
}

--- Loads the menu over a conflict answer, an immediate deferral, a dialog that
--- clicks `answer` and a recording opener, then restores every module.
--- @param ids table What the conflict check reports.
--- @param answer string|nil The dialog button to click; nil clicks OK.
--- @param body function(ui, seen)
local function with_menu(ids, answer, body)
	local prior = {}
	for _, name in ipairs(DISPLACED) do prior[name] = package.loaded[name] end
	local prior_shell_runner = package.loaded["adapters.shell_runner"]
	local seen = { dialogs = {}, opened = {} }
	package.loaded["infra.deferred_work"] = { after = function(_, fn) fn() return true end }
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, message, first)
			seen.dialogs[#seen.dialogs + 1] = { title = title, message = message }
			return answer == "open" and first or "OK"
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		open = function(target) seen.opened[#seen.opened + 1] = target return true end,
	}
	package.loaded["modules.shortcuts.input_source_conflict"] = {
		SETTINGS_URL = "x-apple.systempreferences:test",
		check = function(_, _, on_result) on_result(ids) return true end,
	}
	package.loaded["ui.menu.menu_keyboard_slots"] = nil
	local ok, err = pcall(function()
		body(helpers.load_with_stubs("ui.menu.menu_keyboard_slots"), seen)
	end)
	for _, name in ipairs(DISPLACED) do package.loaded[name] = prior[name] end
	package.loaded["adapters.shell_runner"] = prior_shell_runner
	if not ok then error(err, 0) end
end

helpers.describe("keyboard slot input-source warning (input-source-conflict)", function()
	helpers.it("warns about a chord macOS still owns and opens the settings on request", function()
		with_menu({ "60" }, "open", function(ui, seen)
			ui.warn_if_input_source_conflict("hs_ctrl_space")
			helpers.assert_eq(#seen.dialogs, 1, "the conflict must be shown once")
			helpers.assert_eq(seen.opened[1], "x-apple.systempreferences:test",
				"the button must open the Keyboard settings")
		end)
	end)

	helpers.it("shows nothing for a chord macOS does not own", function()
		with_menu({}, "open", function(ui, seen)
			ui.warn_if_input_source_conflict("hs_ctrl_space")
			helpers.assert_eq(#seen.dialogs, 0)
			helpers.assert_eq(#seen.opened, 0)
		end)
	end)

	helpers.it("opens nothing when the user only acknowledges", function()
		with_menu({ "60" }, nil, function(ui, seen)
			ui.warn_if_input_source_conflict("hs_ctrl_space")
			helpers.assert_eq(#seen.dialogs, 1)
			helpers.assert_eq(#seen.opened, 0)
		end)
	end)
end)

return true
