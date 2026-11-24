--- _shared/tests/lua/debug_menu_layout_contract.lua

--- ==============================================================================
--- MODULE: Debug Menu Layout Contract
--- DESCRIPTION:
--- The assertions on a built Debug menu the macOS and Linux tests share. Each
--- driver hands over its own built rows; Windows asserts the same layout on its
--- native menu in test_debug_menu_layout.ahk.
--- ==============================================================================

local Ai = require("tests.lua.ai.menu_layout_contract")

local M = {}

--- Whether a built row is a separator.
--- @param row table
--- @return boolean
local function is_separator(row) return row.title == "-" end

--- The position of the row whose title is exactly a text.
--- @param rows table Built rows.
--- @param text string
--- @return number|nil
local function position_of(rows, text)
	for index, row in ipairs(rows) do
		if row.title == text then return index end
	end
	return nil
end

--- Asserts the Debug layout: the user-facing rows in their order before the
--- logs, then one separator, the field report row and the « Tests » submenu
--- closing the menu, which holds every check (in its titled groups) and nothing
--- else, and no separator out of place anywhere.
--- @param helpers table
--- @param rows table Built Debug rows.
--- @param captions table { diagnostics, report, suggest, logs, field_report, tests, checks }:
---   exact titles; `checks` lists the titles the Tests submenu holds, in order
---   (its group headers and separators included).
--- @param state string The state under test, for the failure message.
function M.assert_layout(helpers, rows, captions, state)
	Ai.assert_clean_separators(helpers, rows, state)
	local diagnostics = position_of(rows, captions.diagnostics)
	local report = position_of(rows, captions.report)
	local suggest = position_of(rows, captions.suggest)
	local logs = position_of(rows, captions.logs)
	helpers.assert_true(diagnostics and report and suggest and logs, state .. ": the user-facing rows are drawn")
	helpers.assert_true(diagnostics < report and report < suggest and suggest < logs,
		state .. ": diagnostics, report and suggest come first, then the logs")
	local tests = rows[#rows]
	helpers.assert_eq(tests.title, captions.tests, state .. ": the Tests submenu closes Debug")
	helpers.assert_eq(rows[#rows - 1].title, captions.field_report, state .. ": the field report row stands just before Tests")
	helpers.assert_true(is_separator(rows[#rows - 2]), state .. ": one separator sets the field report and Tests apart")
	helpers.assert_true(type(tests.menu) == "table" and #tests.menu > 0, state .. ": Tests is never empty")
	Ai.assert_clean_separators(helpers, tests.menu, state .. " (Tests)")
	local titles = {}
	for _, row in ipairs(tests.menu) do titles[#titles + 1] = row.title end
	helpers.assert_eq(titles, captions.checks, state .. ": Tests holds every check, in topic order")
	for _, check in ipairs(captions.checks) do
		if check ~= "-" then
			helpers.assert_nil(position_of(rows, check), state .. ": no check stays among the user rows: " .. check)
		end
	end
	local groups = 0
	for _, row in ipairs(rows) do
		if type(row.menu) == "table" and row.title ~= captions.tests then groups = groups + 1 end
	end
	helpers.assert_eq(groups, 1, state .. ": only the log level opens a submenu besides Tests")
end

return M
