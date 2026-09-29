--- tests/unit/ui/test_llm_menu_prediction_count.lua

--- ==============================================================================
--- MODULE: The AI Suggestion Count Rows (Linux tray)
--- DESCRIPTION:
--- The count rows (1 to 10 suggestions) read one locale key per plural form,
--- menu.llm.prediction_count_label_one for one and _other for every other count,
--- as macOS and Windows do. Linux showed bare numbers, and the two other drivers
--- injected an "s" after one shared key, a plural only French and English form.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the tray around an enabled LLM double.
--- @return table items
local function build()
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		_version = "0.0.0-dev.12",
		llm = { is_enabled = function() return true end, toggle = function() return true end },
		on_quit = function() end,
		on_menu_changed = function() end,
	})
end

--- The AI submenu's rows.
--- @param items table Top-level tray rows.
--- @return table rows
local function ai_rows(items)
	local label = require("infra.i18n").get("menu.llm.title")
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	error("the tray has no AI submenu")
end

--- The row that opens the suggestion count choices, and its index.
--- @param rows table AI submenu rows.
--- @return table row, number index
local function count_row(rows)
	local current = require("modules.llm.profile_settings").get("num_predictions")
	local label = string.format(require("infra.i18n").get("menu.llm.num_predictions_label"), current)
	for index, row in ipairs(rows) do
		if row.title == label then return row, index end
	end
	error("the AI submenu has no suggestion count row labelled " .. label)
end

helpers.describe("tray (linux): the AI suggestion count", function()

	helpers.it("labels each count with the one/other plural keys (llm-count-plural)", function()
		local i18n = require("infra.i18n")
		local one = i18n.get("menu.llm.prediction_count_label_one")
		local other = i18n.get("menu.llm.prediction_count_label_other")
		helpers.assert_true(one:find("%d", 1, true) ~= nil, "the singular key must resolve, got: " .. one)
		helpers.assert_true(other:find("%d", 1, true) ~= nil, "the plural key must resolve, got: " .. other)
		local row = count_row(ai_rows(build()))
		helpers.assert_eq(type(row.menu), "table", "the count row opens its choices")
		helpers.assert_eq(#row.menu, 10, "one choice per count from 1 to 10")
		helpers.assert_eq(row.menu[1].title, string.format(one, 1), "one reads the singular key")
		for count = 2, 10 do
			helpers.assert_eq(row.menu[count].title, string.format(other, count),
				"every other count reads the plural key")
		end
	end)

end)
