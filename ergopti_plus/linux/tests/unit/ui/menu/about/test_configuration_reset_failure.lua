--- tests/unit/ui/menu/about/test_configuration_reset_failure.lua

--- ==============================================================================
--- MODULE: Configuration Restore And Clear Failure Reason (Linux)
--- DESCRIPTION:
--- Clicks the real Configuration › « Restore recommended values » and
--- « Clear all » rows over a global scope that refuses, and checks the dialog
--- names the typed failure point of the refusal, as the Windows reset does.
---
--- ROOT CAUSE ENCODED:
--- Every refusal showed « The change could not be saved… It has been
--- reverted. », also when the rollback or the finalization was still pending,
--- so the dialog claimed a revert that had not taken place.
--- ==============================================================================

local helpers = require("tests.helpers")
local ResetFailure = require("config_reset_failure")

--- Runs `body` with zenity recorded, answering every dialog.
--- @param body function Clicks the rows under test.
--- @return table shown Every zenity command.
local function with_zenity(body)
	local execute, shown = os.execute, {}
	local previous_modal = package.loaded["ui.modal"]
	package.loaded["ui.modal"] = { run = function(callback) return callback() end }
	os.execute = function(command)
		if command:find("zenity", 1, true) then
			shown[#shown + 1] = command
			return 0
		end
		return execute(command)
	end
	local ok, err = pcall(body)
	os.execute = execute
	package.loaded["ui.modal"] = previous_modal
	if not ok then error(err, 0) end
	return shown
end

--- Builds the real tray and returns one row of the Configuration section.
--- @param ctx table Menu context.
--- @param row_key string i18n key of the row label.
--- @return table|nil row
local function configuration_row(ctx, row_key)
	local i18n = require("infra.i18n")
	package.loaded["ui.menu.menu_builder"] = nil
	for _, section in ipairs(require("ui.menu.menu_builder").build(ctx)) do
		if type(section.title) == "string"
			and section.title:find(i18n.get("menu.configuration.title"), 1, true) == 1 then
			for _, row in ipairs(section.menu or {}) do
				if row.title == i18n.get(row_key) then return row end
			end
		end
	end
	return nil
end

--- Clicks one Configuration row over a global scope answering `committed, report`.
--- @param row_key string i18n key of the row label.
--- @param committed boolean What the global scope answers.
--- @param report table The report it answers with.
--- @return table shown Every zenity command the click ran.
local function click(row_key, committed, report)
	local names = { "infra.global_scope", "ui.menu.menu_builder" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local shown
	local ok, err = pcall(function()
		package.loaded["infra.global_scope"] = {
			participants = function() return {} end,
			apply = function() return committed, report end,
		}
		local ctx = { _version = "test", on_quit = function() end, is_paused = function() return false end }
		local row = configuration_row(ctx, row_key)
		helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Configuration row " .. row_key)
		shown = with_zenity(function() row.fn() end)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
	return shown
end

--- The zenity --text argument of one command, unquoted.
--- @param command string
--- @return string text
local function zenity_text(command)
	return (command:match("%-%-text='(.-)' 2>/dev/null$") or ""):gsub("'\\''", "'")
end

helpers.describe("Configuration restore and clear failure reason (Linux)", function()
	local i18n = require("infra.i18n")
	local cases = {
		{ point = "rollback", kind = "rollback_pending", failed = "llm", reverted = false },
		{ point = "finalize", kind = "release_refused", failed = "gestures" },
		{ point = "commit", kind = "refused", failed = "shortcuts", reverted = true },
		{ point = "acquire", kind = "rollback_pending" },
	}
	for _, case in ipairs(cases) do
		for _, row_key in ipairs({ "common.restore_recommended", "common.clear_to_system" }) do
			helpers.it(row_key .. " names the " .. case.point .. " failure point", function()
				local report = { scope = "global", mode = "recommended", point = case.point, kind = case.kind,
					failed = case.failed, reverted = case.reverted, detail = "refused" }
				local shown = click(row_key, false, report)
				helpers.assert_eq(#shown, 1, "one error dialog")
				helpers.assert_true(shown[1]:find("zenity --error", 1, true) == 1, shown[1])
				local title, message = ResetFailure.message(report, i18n.get)
				helpers.assert_eq(zenity_text(shown[1]), message)
				helpers.assert_true(shown[1]:find(title, 1, true) ~= nil, "the reset failure title")
				helpers.assert_true(message ~= i18n.get("dialog.bulk_toggle.save_failed"))
			end)
		end
	end

	helpers.it("a committed restore shows nothing", function()
		helpers.assert_eq(click("common.restore_recommended", true, { scope = "global", applied = {} }), {})
	end)
end)
